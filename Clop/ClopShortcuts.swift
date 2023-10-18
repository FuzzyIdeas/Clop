//
//  ClopShortcuts.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.07.2023.
//

import AppIntents
import Foundation
import Lowtech
import PDFKit

extension IntentFile {
    var url: URL {
        if let fileURL {
            return fileURL
        }

        var fileURL = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: fm.homeDirectoryForCurrentUser, create: true)) ?? fm.temporaryDirectory
        fileURL.append(path: filename)
        fm.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case general
    case message(_ message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .message(message): "Error: \(message)"
        case .general: "Error"
        }
    }
}

var shortcutsOptimisationCount = 0

struct ChangePlaybackSpeedOptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Change video playback speed"
    static var description = IntentDescription("Optimises a video received as input and changes its playback speed by the specific factor.")

    static var parameterSummary: some ParameterSummary {
        When(\.$playbackSpeedFactor, ComparableComparisonOperator.greaterThanOrEqualTo, 1.0, {
            Summary("Speed up \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
            }
        }, otherwise: {
            Summary("Slow down \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
            }
        })
    }

    @Parameter(title: "Video")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Playback speed factor", default: 1.5)
    var playbackSpeedFactor: Double

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to overwriting the original file).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %x	Playback speed factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f @ %xx.%e` on a file like `~/Desktop/video.mp4` will generate the file `~/Desktop/video @ 2x.mp4`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromURL(item.url)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                changePlaybackSpeedBy: playbackSpeedFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: false, source: "shortcuts",
                output: output
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't change playback speed for \(item)")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

struct CropOptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Crop image or video"
    static var description = IntentDescription("Resizes and does a smart crop on an image or video received as input. Use 0 for width or height to have it calculated automatically while keeping the original aspect ratio.")

    static var parameterSummary: some ParameterSummary {
        When(\.$longEdge, .equalTo, true, {
            Summary("Crop \(\.$item) to \(\.$size) over the longest edge and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$copyToClipboard
                \.$longEdge
            }
        }, otherwise: {
            Summary("Crop \(\.$item) to \(\.$width)x\(\.$height) and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$copyToClipboard
                \.$longEdge
            }
        })
    }

    @Parameter(title: "Video, image or PDF file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Resize over long edge")
    var longEdge: Bool

    @Parameter(title: "Width")
    var width: Int?

    @Parameter(title: "Height")
    var height: Int?

    @Parameter(title: "Size")
    var size: Int?

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to overwriting the original file).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %z	Crop size
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f @ %zpx.%e` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image @ 128px.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        if longEdge, (size ?? 0) == 0 {
            throw $size.needsValueError()
        }
        if !longEdge, (width ?? 0) == 0, (height ?? 0) == 0 {
            throw IntentError.message("You need to specify at least one non-zero width or height")
        }

        let clip = ClipboardType.fromURL(item.url)
        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                cropTo: CropSize(width: (longEdge ? size : width) ?? 0, height: (longEdge ? size : height) ?? 0, longEdge: longEdge),
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts",
                output: output
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't crop \(item)")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

struct CropPDFIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Crop PDF"
    static var description = IntentDescription("Crops a PDF for a specific device, paper size or aspect ratio.")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            Summary("Crop \(\.$item) for \(\.$aspectRatio) and \(\.$overwrite)") {
                \.$hideFloatingResult
            }
        }, otherwise: {
            Summary("Crop \(\.$item) for \(\.$aspectRatio) and \(\.$overwrite) \(\.$output)") {
                \.$hideFloatingResult
            }
        })
    }

    @Parameter(title: "PDF")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Aspect ratio")
    var aspectRatio: Double

    @Parameter(title: "Output path", description: "Where to save the cropped PDF (defaults to modifying the PDF in place).")
    var output: String?

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let url = item.url
        guard let pdf = PDFDocument(url: url) else {
            throw IntentError.message("Couldn't parse PDF")
        }

        var outputURL = (overwrite ? nil : output?.filePath?.url) ?? pdf.documentURL ?? url
        if outputURL.filePath.isDir {
            outputURL = outputURL.appendingPathComponent(url.lastPathComponent)
        }

        log.debug("Cropping \(pdf.documentURL?.path ?? "PDF") to aspect ratio \(aspectRatio)")
        pdf.cropTo(aspectRatio: aspectRatio)

        log.debug("Writing PDF to \(outputURL.path)")
        pdf.write(to: outputURL)

        let file = IntentFile(fileURL: outputURL, filename: outputURL.lastPathComponent)
        return .result(value: file)
    }
}

struct OptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise file"
    static var description = IntentDescription("Optimises an image, video or PDF received as input.")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            Summary("Optimise \(\.$item) and \(\.$overwrite)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$downscaleFactor
                \.$copyToClipboard
            }
        }, otherwise: {
            Summary("Optimise \(\.$item) and \(\.$overwrite) \(\.$output)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$downscaleFactor
                \.$copyToClipboard
            }
        })
    }

    @Parameter(title: "Video, image or PDF file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Downscale factor", description: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)", default: 1.0, controlStyle: .field, inclusiveRange: (0.1, 1.0))
    var downscaleFactor: Double

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to overwriting the original file).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised.%e` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image_optimised.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromURL(item.url)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts",
                output: overwrite ? nil : output
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't optimise item")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

struct OptimiseURLIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise URL"
    static var description = IntentDescription("Optimises an image, video or PDF that can be downloaded from a provided URL.")

    static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$item) and save to \(\.$output)") {
            \.$hideFloatingResult
            \.$aggressiveOptimisation
            \.$downscaleFactor
            \.$copyToClipboard
        }
    }

    @Parameter(title: "URL")
    var item: URL

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Downscale factor", description: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)", default: 1.0, controlStyle: .field, inclusiveRange: (0.1, 1.0))
    var downscaleFactor: Double

    @Parameter(title: "Output path (or temporary folder)", description: """
    Output file path or template (defaults to saving to a temporary folder).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised.%e` on an URL like `https://example.com/image.png` will generate the file `~/Desktop/image_optimised.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromURL(item)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts",
                output: output
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't optimise item")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}
