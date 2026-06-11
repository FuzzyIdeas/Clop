//
//  ClopShortcuts.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.07.2023.
//

import AppIntents
import Defaults
import Foundation
import Lowtech
import os
import PDFKit
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "ClopShortcuts")

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

/// Map a Shortcuts compression factor parameter to the unified per-run compression override.
func shortcutCompression(_ factor: Int?) -> CompressionQuality? {
    guard let factor else { return nil }
    return CompressionQuality(tier: .custom, factor: max(5, min(100, factor)))
}

struct ChangePlaybackSpeedOptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Change video playback speed"
    static var description = IntentDescription("Optimises a video received as input and changes its playback speed by the specific factor.", categoryName: "Optimisation")

    static var parameterSummary: some ParameterSummary {
        When(\.$playbackSpeedFactor, ComparableComparisonOperator.greaterThanOrEqualTo, 1.0, {
            Summary("Speed up \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$removeAudio
            }
        }, otherwise: {
            Summary("Slow down \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$removeAudio
            }
        })
    }

    @Parameter(title: "Video")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Takes priority over aggressive optimisation. Leave empty to use the app's compression settings.")
    var compressionFactor: Int?

    @Parameter(title: "Playback speed factor", default: 1.5)
    var playbackSpeedFactor: Double

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

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

    %P	Source file path (without name)
    %f	Source file name (without extension)
    %e	Source file extension

    %x	Playback speed factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f @ %xx` on a file like `~/Desktop/video.mp4` will generate the file `~/Desktop/video @ 2x.mp4`.

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
                compression: shortcutCompression(compressionFactor),
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: false, source: .shortcuts,
                output: output,
                removeAudio: removeAudio
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
            log.error("\(error.localizedDescription)")
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

enum ImageFormat: String, CaseIterable, Equatable, AppEnum {
    case avif, heic, jpeg, jxl, png, webp

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Image Format"
    }

    static var caseDisplayRepresentations: [ImageFormat: DisplayRepresentation] {
        [
            .avif: "avif", .heic: "heic", .jpeg: "jpeg", .jxl: "jxl", .png: "png", .webp: "webp",
        ]
    }

    var utType: UTType? {
        switch self {
        case .avif: .avif
        case .heic: .heic
        case .jpeg: .jpeg
        case .jxl: .jxl
        case .png: .png
        case .webp: .webP
        }
    }
}

struct ConvertImageIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Convert image to…"
    static var description = IntentDescription("Convert an image received as input to a different format such as WEBP, AVIF or JPEG XL.", categoryName: "Conversion")

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$image) to \(\.$format)") {
            \.$output
            \.$aggressiveOptimisation
            \.$compressionFactor
            \.$hideFloatingResult
        }
    }

    @Parameter(title: "Image")
    var image: IntentFile

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Leave empty to use the app's image compression setting.")
    var compressionFactor: Int?

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Show converted image as result")
    var addFloatingResult: Bool

    @Parameter(title: "Delete original image")
    var deleteOriginal: Bool

    @Parameter(title: "Format", default: .webp)
    var format: ImageFormat

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to placing the converted file in the same folder as the original).

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

    %P	Source file path (without name)
    %f	Source file name (without extension)
    %e	Source file extension

    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f[converted-from-%e]` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image[converted-from-png].webp`.
    The extension of the conversion format is automatically added.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let path = image.url.existingFilePath, let img = Image(path: path, retinaDownscaled: false),
              let type = format.utType, let ext = type.preferredFilenameExtension, let stem = path.stem
        else {
            throw IntentError.message("Couldn't load image")
        }
        guard type != img.type else {
            return .result(value: image)
        }
        var convertedImage = try img.convert(to: type, asTempFile: true, cq: shortcutCompression(compressionFactor))
        if type == .png || type == .jpeg {
            convertedImage = await (try? runImagePipeline(convertedImage, actions: [.optimise], hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: .shortcuts)) ?? convertedImage
        }

        var outFilePath: FilePath =
            if let output, let outPath = output.filePath {
                try generateFilePath(template: outPath, for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber], mkdir: true)
            } else {
                path.removingLastComponent().appending(stem)
            }
        outFilePath = FilePath("\(outFilePath.string).\(ext)")

        try convertedImage.path.move(to: outFilePath, force: true)

        if deleteOriginal {
            try path.delete()
        }

        if addFloatingResult {
            let opt = OM.optimiser(id: convertedImage.path.string, type: .image(type), operation: "Converting to \(format.rawValue)", source: .shortcuts, indeterminateProgress: true)
            opt.running = false
        }

        return .result(value: IntentFile(data: convertedImage.data, filename: outFilePath.name.string, type: type))
    }
}

struct CropOptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Crop image or video"
    static var description = IntentDescription("Resizes and does a smart crop on an image or video received as input. Use 0 for width or height to have it calculated automatically while keeping the original aspect ratio.", categoryName: "Optimisation")

    static var parameterSummary: some ParameterSummary {
        When(\.$longEdge, .equalTo, true, {
            Summary("Crop \(\.$item) to \(\.$size) over the longest edge and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$copyToClipboard
                \.$longEdge
                \.$removeAudio
            }
        }, otherwise: {
            When(\.$isAspectRatio, .equalTo, true, {
                Summary("Crop \(\.$item) to \(\.$isAspectRatio) \(\.$width):\(\.$height) and optimise") {
                    \.$output
                    \.$hideFloatingResult
                    \.$aggressiveOptimisation
                    \.$compressionFactor
                    \.$copyToClipboard
                    \.$longEdge
                    \.$removeAudio
                }
            }, otherwise: {
                Summary("Crop \(\.$item) to \(\.$isAspectRatio) \(\.$width)×\(\.$height) and optimise") {
                    \.$output
                    \.$hideFloatingResult
                    \.$aggressiveOptimisation
                    \.$compressionFactor
                    \.$copyToClipboard
                    \.$longEdge
                    \.$removeAudio
                }
            })
        })
    }

    @Parameter(title: "Video, image or PDF file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Takes priority over aggressive optimisation. Leave empty to use the app's compression settings.")
    var compressionFactor: Int?

    @Parameter(title: "Size or aspect ratio toggle", default: false, displayName: .init(true: "aspect ratio", false: "size"))
    var isAspectRatio: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

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

    %P	Source file path (without name)
    %f	Source file name (without extension)
    %e	Source file extension

    %z	Crop size
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f @ %zpx` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image @ 128px.png`.

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
                cropTo: CropSize(width: (longEdge ? size : width) ?? 0, height: (longEdge ? size : height) ?? 0, longEdge: longEdge, isAspectRatio: isAspectRatio),
                aggressiveOptimisation: aggressiveOptimisation,
                compression: shortcutCompression(compressionFactor),
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: .shortcuts,
                output: output,
                removeAudio: removeAudio
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
            log.error("\(error.localizedDescription)")
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
    static var description = IntentDescription("Crops a PDF for a specific device, paper size or aspect ratio.", categoryName: "PDF")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            When(\.$usePaperSize, .equalTo, true, {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$paperSize) and \(\.$overwrite)") { \.$pageLayout; \.$extend }
            }, otherwise: {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$device) and \(\.$overwrite)") { \.$pageLayout; \.$extend }
            })
        }, otherwise: {
            When(\.$usePaperSize, .equalTo, true, {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$paperSize) and \(\.$overwrite) \(\.$output)") { \.$pageLayout; \.$extend }
            }, otherwise: {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$device) and \(\.$overwrite) \(\.$output)") { \.$pageLayout; \.$extend }
            })
        })
    }

    @Parameter(title: "PDF")
    var item: IntentFile

    @Parameter(title: "Paper size or device", displayName: .init(true: "to paper size", false: "for device"))
    var usePaperSize: Bool

    @Parameter(title: "Page layout", description: """
    Allows forcing a page layout on all PDF pages:
        auto: Crop pages based on their longest edge, so that horizontal pages stay horizontal and vertical pages stay vertical
        portrait: Force all pages to be cropped to vertical or portrait layout
        landscape: Force all pages to be cropped to horizontal or landscape layout
    """, default: PageLayout.auto)
    var pageLayout: PageLayout

    @Parameter(title: "Paper", default: PaperSize.a4)
    var paperSize: PaperSize?

    @Parameter(title: "Device", default: Device.iPadAir)
    var device: Device?

    @Parameter(title: "Output path", description: "Where to save the cropped PDF (defaults to modifying the PDF in place).")
    var output: String?

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @Parameter(
        title: "Extend instead of clipping",
        description: "Grows pages with empty paper instead of cutting content away, so everything stays visible (e.g. fit a book to a phone screen without cutting off text).",
        default: false
    )
    var extend: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let aspectRatio = usePaperSize ? paperSize?.aspectRatio : device?.aspectRatio else {
            throw IntentError.message("Invalid aspect ratio")
        }

        let url = item.url
        guard let pdf = PDFDocument(url: url) else {
            throw IntentError.message("Couldn't parse PDF")
        }

        var outputURL = (overwrite ? nil : output?.filePath?.url) ?? pdf.documentURL ?? url
        if outputURL.filePath!.isDir {
            outputURL = outputURL.appendingPathComponent(url.lastPathComponent)
        }

        log.debug("\(extend ? "Extending" : "Cropping") \(pdf.documentURL?.path ?? "PDF") to aspect ratio \(aspectRatio)")
        if extend {
            pdf.extendTo(aspectRatio: aspectRatio, alwaysPortrait: pageLayout == .portrait, alwaysLandscape: pageLayout == .landscape)
        } else {
            pdf.cropTo(aspectRatio: aspectRatio, alwaysPortrait: pageLayout == .portrait, alwaysLandscape: pageLayout == .landscape)
        }

        log.debug("Writing PDF to \(outputURL.path)")
        pdf.write(to: outputURL)

        let file = IntentFile(fileURL: outputURL, filename: outputURL.lastPathComponent)
        return .result(value: file)
    }
}

struct OptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise file (image, video, PDF or audio)"
    static var description = IntentDescription("Optimises an image, video, PDF or audio file received as input.", categoryName: "Optimisation")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            Summary("Optimise \(\.$item) and \(\.$overwrite)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$audioBitrate
                \.$pdfDpi
                \.$downscaleFactor
                \.$copyToClipboard
                \.$removeAudio
            }
        }, otherwise: {
            Summary("Optimise \(\.$item) and \(\.$overwrite) \(\.$output)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$audioBitrate
                \.$pdfDpi
                \.$downscaleFactor
                \.$copyToClipboard
                \.$removeAudio
            }
        })
    }

    @Parameter(title: "Video, image, PDF or audio file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Takes priority over aggressive optimisation. Leave empty to use the app's compression settings.")
    var compressionFactor: Int?

    @Parameter(title: "Audio bitrate (kbps)", description: "Target bitrate in kbps for audio files (e.g. 128). Takes priority over the compression factor. Never upscales, snaps to the allowed bitrates of the output format.")
    var audioBitrate: Int?

    @Parameter(title: "PDF DPI", description: "Rendering DPI for PDF optimisation: adaptive picks the best DPI per document, lower DPI means smaller files. Leave empty to use the app's setting.")
    var pdfDpi: PDFDPIOption?

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

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

    %P	Source file path (without name)
    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image_optimised.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        if let audioBitrate, audioBitrate <= 0 {
            throw IntentError.message("Invalid audio bitrate, must be greater than 0")
        }
        let clip = ClipboardType.fromURL(item.url)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                pdfDPI: pdfDpi?.dpi,
                compression: shortcutCompression(compressionFactor),
                audioBitrate: audioBitrate,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: .shortcuts,
                output: overwrite ? nil : output,
                removeAudio: removeAudio
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
            log.error("\(error.localizedDescription)")
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

struct DownscaleFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Downscale image, video or audio"
    static var description = IntentDescription("Downscales an image or video received as input. For audio files, lowers the bitrate by the same factor.", categoryName: "Optimisation")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            Summary("Downscale \(\.$item) to \(\.$downscaleFactor)x and \(\.$overwrite)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$copyToClipboard
                \.$removeAudio
            }
        }, otherwise: {
            Summary("Downscale \(\.$item) to \(\.$downscaleFactor)x and \(\.$overwrite) \(\.$output)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$compressionFactor
                \.$copyToClipboard
                \.$removeAudio
            }
        })
    }

    @Parameter(title: "Video, image or audio file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Takes priority over aggressive optimisation. Leave empty to use the app's compression settings.")
    var compressionFactor: Int?

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

    @Parameter(title: "Downscale factor", description: "Makes the image or video smaller by a certain amount (1.0 means no change, 0.5 means half the size, or half the bitrate for audio)", default: 0.5, controlStyle: .field, inclusiveRange: (0.1, 1.0))
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

    %P	Source file path (without name)
    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image_optimised.png`.

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
                compression: shortcutCompression(compressionFactor),
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: .shortcuts,
                output: overwrite ? nil : output,
                removeAudio: removeAudio
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
            log.error("\(error.localizedDescription)")
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

    static var title: LocalizedStringResource = "Download and optimise file (image, video, PDF or audio)"
    static var description = IntentDescription("Optimises an image, video, PDF or audio file that can be downloaded from a provided URL.", categoryName: "Optimisation")

    static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$item) and save to \(\.$output)") {
            \.$hideFloatingResult
            \.$aggressiveOptimisation
            \.$compressionFactor
            \.$audioBitrate
            \.$downscaleFactor
            \.$copyToClipboard
            \.$removeAudio
        }
    }

    @Parameter(title: "URL")
    var item: URL

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Takes priority over aggressive optimisation. Leave empty to use the app's compression settings.")
    var compressionFactor: Int?

    @Parameter(title: "Audio bitrate (kbps)", description: "Target bitrate in kbps for audio files (e.g. 128). Takes priority over the compression factor. Never upscales, snaps to the allowed bitrates of the output format.")
    var audioBitrate: Int?

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

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

    %P	Source file path (without name)
    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised` on an URL like `https://example.com/image.png` will generate the file `~/Desktop/image_optimised.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        if let audioBitrate, audioBitrate <= 0 {
            throw IntentError.message("Invalid audio bitrate, must be greater than 0")
        }
        let clip = ClipboardType.fromURL(item)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                compression: shortcutCompression(compressionFactor),
                audioBitrate: audioBitrate,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: .shortcuts,
                output: output,
                removeAudio: removeAudio
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
            log.error("\(error.localizedDescription)")
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

enum PDFDPIOption: String, CaseIterable, AppEnum {
    case adaptive
    case dpi300, dpi250, dpi200, dpi150, dpi100, dpi72, dpi48

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "PDF DPI"
    }

    static var caseDisplayRepresentations: [PDFDPIOption: DisplayRepresentation] {
        [
            .adaptive: DisplayRepresentation(title: "Adaptive", subtitle: "Pick the best DPI per document"),
            .dpi300: "300", .dpi250: "250", .dpi200: "200", .dpi150: "150", .dpi100: "100", .dpi72: "72", .dpi48: "48",
        ]
    }

    var dpi: Int {
        switch self {
        case .adaptive: PDF_DPI_ADAPTIVE
        case .dpi300: 300
        case .dpi250: 250
        case .dpi200: 200
        case .dpi150: 150
        case .dpi100: 100
        case .dpi72: 72
        case .dpi48: 48
        }
    }
}

/// Run a pipeline (saved name or inline DSL) on a file through the same code path
/// as the CLI `clop pipeline run` and `clop convert` commands.
@MainActor func runShortcutsPipeline(
    url: URL,
    pipeline: String,
    hideFloatingResult: Bool,
    compression: CompressionQuality? = nil,
    audioBitrate: Int? = nil
) async throws -> IntentFile {
    let req = OptimisationRequest(
        id: url.absoluteString,
        urls: [url],
        size: nil,
        downscaleFactor: nil,
        changePlaybackSpeedFactor: nil,
        hideFloatingResult: hideFloatingResult,
        copyToClipboard: false,
        aggressiveOptimisation: false,
        adaptiveOptimisation: nil,
        source: "shortcuts",
        compression: compression,
        audioBitrate: audioBitrate,
        pipeline: pipeline
    )

    do {
        let response = try await processPipelineRequestURL(req, url: url)
        let path = FilePath(response.path)
        guard path.exists else {
            throw IntentError.message("Couldn't find file at \(path)")
        }
        return IntentFile(fileURL: path.url, filename: path.name.string)
    } catch let error as ClopError {
        throw IntentError.message(error.description)
    } catch let error as IntentError {
        throw error
    } catch {
        log.error("\(error.localizedDescription)")
        throw IntentError.message(error.localizedDescription)
    }
}

enum VideoConversionFormat: String, CaseIterable, AppEnum {
    case mp4, gif, webm, hevc, x265, av1

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Video Format"
    }

    static var caseDisplayRepresentations: [VideoConversionFormat: DisplayRepresentation] {
        [
            .mp4: DisplayRepresentation(title: "mp4", subtitle: "H.264"),
            .gif: DisplayRepresentation(title: "gif", subtitle: "Animated GIF"),
            .webm: DisplayRepresentation(title: "webm", subtitle: "VP9"),
            .hevc: DisplayRepresentation(title: "hevc", subtitle: "Hardware H.265"),
            .x265: DisplayRepresentation(title: "x265", subtitle: "Software H.265"),
            .av1: DisplayRepresentation(title: "av1", subtitle: "SVT-AV1 in MKV"),
        ]
    }
}

struct ConvertVideoIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Convert video to…"
    static var description = IntentDescription("Convert a video received as input to a different format or codec such as GIF, WEBM (VP9), H.265 or AV1.", categoryName: "Conversion")

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$video) to \(\.$format)") {
            \.$compressionFactor
            \.$hideFloatingResult
        }
    }

    @Parameter(title: "Video")
    var video: IntentFile

    @Parameter(title: "Format", default: .mp4)
    var format: VideoConversionFormat

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Only applies to mp4 (H.264); the other codecs use tuned fixed settings.")
    var compressionFactor: Int?

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let file = try await runShortcutsPipeline(
            url: video.url,
            pipeline: "convert(to: \(format.rawValue))",
            hideFloatingResult: hideFloatingResult,
            compression: shortcutCompression(compressionFactor)
        )
        return .result(value: file)
    }
}

enum AudioConversionFormat: String, CaseIterable, AppEnum {
    case aac, mp3, opus, flac, wav, aiff

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Audio Format"
    }

    static var caseDisplayRepresentations: [AudioConversionFormat: DisplayRepresentation] {
        [
            .aac: DisplayRepresentation(title: "aac", subtitle: "AAC (M4A)"),
            .mp3: DisplayRepresentation(title: "mp3", subtitle: "MP3"),
            .opus: DisplayRepresentation(title: "opus", subtitle: "Opus (OGG)"),
            .flac: DisplayRepresentation(title: "flac", subtitle: "FLAC (lossless)"),
            .wav: DisplayRepresentation(title: "wav", subtitle: "WAV (uncompressed)"),
            .aiff: DisplayRepresentation(title: "aiff", subtitle: "AIFF (uncompressed)"),
        ]
    }
}

struct ConvertAudioIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Convert audio to…"
    static var description = IntentDescription("Convert an audio file received as input to a different format such as AAC, MP3 or Opus.", categoryName: "Conversion")

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$audio) to \(\.$format)") {
            \.$compressionFactor
            \.$bitrate
            \.$hideFloatingResult
        }
    }

    @Parameter(title: "Audio")
    var audio: IntentFile

    @Parameter(title: "Format", default: .aac)
    var format: AudioConversionFormat

    @Parameter(title: "Compression factor", description: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file), mapped to a bitrate for the target format. Leave empty to use the app's audio compression setting.")
    var compressionFactor: Int?

    @Parameter(title: "Audio bitrate (kbps)", description: "Target bitrate in kbps (e.g. 128). Takes priority over the compression factor. Never upscales, snaps to the allowed bitrates of the target format.")
    var bitrate: Int?

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        if let bitrate, bitrate <= 0 {
            throw IntentError.message("Invalid audio bitrate, must be greater than 0")
        }
        let file = try await runShortcutsPipeline(
            url: audio.url,
            pipeline: "convert(to: \(format.rawValue))",
            hideFloatingResult: hideFloatingResult,
            compression: shortcutCompression(compressionFactor),
            audioBitrate: bitrate
        )
        return .result(value: file)
    }
}

struct PipelineEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Clop Pipeline"
    static var defaultQuery = PipelineEntityQuery()

    let id: String
    let name: String
    let steps: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(steps)")
    }
}

extension Pipeline {
    var shortcutsEntity: PipelineEntity? {
        guard let name, !name.isEmpty else { return nil }
        return PipelineEntity(id: id, name: name, steps: displayText)
    }
}

struct PipelineEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PipelineEntity] {
        Defaults[.savedPipelines].filter { identifiers.contains($0.id) }.compactMap(\.shortcutsEntity)
    }

    func entities(matching string: String) async throws -> [PipelineEntity] {
        Defaults[.savedPipelines].compactMap(\.shortcutsEntity).filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [PipelineEntity] {
        Defaults[.savedPipelines].compactMap(\.shortcutsEntity)
    }
}

struct RunPipelineIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Run pipeline on file"
    static var description = IntentDescription("""
    Runs a pipeline on an image, video, PDF or audio file: either a pipeline saved in the Clop app, or custom inline steps like `crop(width: 1600) -> convert(to: webp)`.

    Inline steps run exactly as written (no implicit optimisation pass); add an explicit `optimise` step if you want one. Saved pipelines keep their "skip optimisation" setting: when off, the file is optimised before the steps run.
    """, categoryName: "Pipelines")

    static var parameterSummary: some ParameterSummary {
        When(\.$useCustomSteps, .equalTo, true, {
            Summary("Run \(\.$useCustomSteps) \(\.$steps) on \(\.$item)") {
                \.$hideFloatingResult
            }
        }, otherwise: {
            Summary("Run \(\.$useCustomSteps) \(\.$pipeline) on \(\.$item)") {
                \.$hideFloatingResult
            }
        })
    }

    @Parameter(title: "Image, video, PDF or audio file")
    var item: IntentFile

    @Parameter(title: "Pipeline type", default: false, displayName: .init(true: "custom steps", false: "saved pipeline"))
    var useCustomSteps: Bool

    @Parameter(title: "Pipeline")
    var pipeline: PipelineEntity?

    @Parameter(title: "Steps", description: """
    Inline pipeline steps separated by `->`, e.g. `crop(width: 1600) -> convert(to: webp)`.

    Steps: optimise, downscale, lowerBitrate, convert, crop, extractPagesAsImages,
    copy, move, rename, delete, if, ifNot, removeAudio, changeSpeed, runScript,
    runShortcut, copyToClipboard, copyLinkForSending, shelveWith, uploadWith, openWith
    """)
    var steps: String?

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let pipelineArg: String
        if useCustomSteps {
            guard let steps, !steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw $steps.needsValueError()
            }
            pipelineArg = steps
        } else {
            guard let pipeline else {
                throw $pipeline.needsValueError()
            }
            pipelineArg = pipeline.name
        }

        let file = try await runShortcutsPipeline(url: item.url, pipeline: pipelineArg, hideFloatingResult: hideFloatingResult)
        return .result(value: file)
    }
}

extension PageLayout: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Page Layout"
    }

    static var caseDisplayRepresentations: [PageLayout: DisplayRepresentation] {
        [
            .auto: DisplayRepresentation(
                title: "Auto",
                subtitle: "Crop pages based on their longest edge",
                image: .init(systemName: "sparkles.rectangle.stack.fill")
            ),
            .portrait: DisplayRepresentation(
                title: "Portrait",
                subtitle: "Force all pages to be vertical",
                image: .init(systemName: "rectangle.portrait.arrowtriangle.2.inward")
            ),
            .landscape: DisplayRepresentation(
                title: "Landscape",
                subtitle: "Force all pages to be horizontal",
                image: .init(systemName: "rectangle.arrowtriangle.2.inward")
            ),
        ]
    }
}

extension Device: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Device"
    }

    static var caseDisplayRepresentations: [Device: DisplayRepresentation] {
        [
            .iPhone17ProMax: "iPhone 17 Pro Max", .iPhone17Pro: "iPhone 17 Pro", .iPhone17: "iPhone 17", .iPhone17e: "iPhone 17e",
            .iPhoneAir: "iPhone Air",
            .iPadProM513Inch: "iPad Pro M5 13inch", .iPadProM511Inch: "iPad Pro M5 11inch",
            .iPadProM413Inch: "iPad Pro M4 13inch", .iPadProM411Inch: "iPad Pro M4 11inch",
            .iPadAirM413Inch: "iPad Air M4 13inch", .iPadAirM411Inch: "iPad Air M4 11inch",
            .iPadAirM313Inch: "iPad Air M3 13inch", .iPadAirM311Inch: "iPad Air M3 11inch",
            .iPadAirM213Inch: "iPad Air M2 13inch", .iPadAirM211Inch: "iPad Air M2 11inch",
            .iPad11: "iPad 11", .iPadMini7: "iPad mini 7", .iPadMini1: "iPad mini 1",
            .iPhone16e: "iPhone 16e",
            .iPhone16ProMax: "iPhone 16 Pro Max", .iPhone16Pro: "iPhone 16 Pro", .iPhone16Plus: "iPhone 16 Plus", .iPhone16: "iPhone 16",
            .iPhone15ProMax: "iPhone 15 Pro Max", .iPhone15Pro: "iPhone 15 Pro", .iPhone15Plus: "iPhone 15 Plus", .iPhone15: "iPhone 15",
            .iPadPro: "iPad Pro", .iPadPro6129Inch: "iPad Pro 6 12.9inch", .iPadPro611Inch: "iPad Pro 6 11inch",
            .iPad: "iPad", .iPad10: "iPad 10",
            .iPhone14Plus: "iPhone 14 Plus", .iPhone14ProMax: "iPhone 14 Pro Max", .iPhone14Pro: "iPhone 14 Pro", .iPhone14: "iPhone 14",
            .iPhoneSe3: "iPhone SE 3",
            .iPadAir: "iPad Air", .iPadAir5: "iPad Air 5",
            .iPhone13: "iPhone 13", .iPhone13Mini: "iPhone 13 mini", .iPhone13ProMax: "iPhone 13 Pro Max", .iPhone13Pro: "iPhone 13 Pro",
            .iPad9: "iPad 9", .iPadPro5129Inch: "iPad Pro 5 12.9inch", .iPadPro511Inch: "iPad Pro 5 11inch", .iPadAir4: "iPad Air 4",
            .iPhone12: "iPhone 12", .iPhone12Mini: "iPhone 12 mini", .iPhone12ProMax: "iPhone 12 Pro Max", .iPhone12Pro: "iPhone 12 Pro",
            .iPad8: "iPad 8",
            .iPhoneSe2: "iPhone SE 2",
            .iPadPro4129Inch: "iPad Pro 4 12.9inch", .iPadPro411Inch: "iPad Pro 4 11inch",
            .iPad7: "iPad 7",
            .iPhone11ProMax: "iPhone 11 Pro Max", .iPhone11Pro: "iPhone 11 Pro", .iPhone11: "iPhone 11",
            .iPodTouch7: "iPod touch 7",
            .iPadMini: "iPad mini", .iPadMini6: "iPad mini 6", .iPadMini5: "iPad mini 5", .iPadAir3: "iPad Air 3", .iPadPro3129Inch: "iPad Pro 3 12.9inch", .iPadPro311Inch: "iPad Pro 3 11inch",
            .iPhoneXr: "iPhone XR", .iPhoneXsMax: "iPhone XS Max", .iPhoneXs: "iPhone XS",
            .iPad6: "iPad 6",
            .iPhoneX: "iPhone X", .iPhone8Plus: "iPhone 8 Plus", .iPhone8: "iPhone 8",
            .iPadPro2129Inch: "iPad Pro 2 12.9inch",
            .iPadPro2105Inch: "iPad Pro 2 10.5inch",
            .iPad5: "iPad 5",
            .iPhone7Plus: "iPhone 7 Plus",
            .iPhone7: "iPhone 7",
            .iPhoneSe1: "iPhone SE 1",
            .iPadPro197Inch: "iPad Pro 1 9.7inch",
            .iPadPro1129Inch: "iPad Pro 1 12.9inch",
            .iPhone6SPlus: "iPhone 6s Plus",
            .iPhone6S: "iPhone 6s",
            .iPadMini4: "iPad mini 4",
            .iPodTouch6: "iPod touch 6",
            .iPadAir2: "iPad Air 2",
            .iPadMini3: "iPad mini 3",
            .iPhone6Plus: "iPhone 6 Plus",
            .iPhone6: "iPhone 6",
            .iPadMini2: "iPad mini 2",
            .iPadAir1: "iPad Air 1",
            .iPhone5C: "iPhone 5C",
            .iPhone5S: "iPhone 5S",
            .iPad4: "iPad 4",
            .iPodTouch5: "iPod touch 5",
            .iPhone5: "iPhone 5",
            .iPad3: "iPad 3",
            .iPhone4S: "iPhone 4S",
            .iPad2: "iPad 2",
            .iPodTouch4: "iPod touch 4",
            .iPhone4: "iPhone 4",
        ]
    }
}

extension PaperSize: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Paper Size"
    }

    static var caseDisplayRepresentations: [PaperSize: DisplayRepresentation] {
        [
            .a0: "A0", .a1: "A1", .a2: "A2", .a3: "A3", .a4: "A4", .a5: "A5", .a6: "A6", .a7: "A7", .a8: "A8", .a9: "A9", .a10: "A10", .a11: "A11", .a12: "A12", .a13: "A13",
            ._2A0: "2A0", ._4A0: "4A0", .a0plus: "A0+", .a1plus: "A1+", .a3plus: "A3+",
            .b0: "B0", .b1: "B1", .b2: "B2", .b3: "B3", .b4: "B4", .b5: "B5", .b6: "B6", .b7: "B7", .b8: "B8", .b9: "B9", .b10: "B10", .b11: "B11", .b12: "B12", .b13: "B13",
            .b0plus: "B0+", .b1plus: "B1+", .b2plus: "B2+", .letter: "Letter",
            .legal: "Legal", .tabloid: "Tabloid", .ledger: "Ledger", .juniorLegal: "Junior Legal", .halfLetter: "Half Letter", .governmentLetter: "Government Letter", .governmentLegal: "Government Legal",
            .ansiA: "ANSI A", .ansiB: "ANSI B", .ansiC: "ANSI C", .ansiD: "ANSI D", .ansiE: "ANSI E", .archA: "Arch A",
            .archB: "Arch B", .archC: "Arch C", .archD: "Arch D", .archE: "Arch E", .archE1: "Arch E1", .archE2: "Arch E2", .archE3: "Arch E3", .passport: "Passport",
            ._2R: "2R", .ldDsc: "LD, DSC", ._3RL: "3R, L", .lw: "LW", .kgd: "KGD", ._4RKg: "4R, KG", ._2LdDscw: "2LD, DSCW", ._5R2L: "5R, 2L", ._2Lw: "2LW", ._6R: "6R", ._8R6P: "8R, 6P", .s8R6Pw: "S8R, 6PW", ._11R: "11R",
            .a3SuperB: "A3+ Super B",
            .berliner: "Berliner", .broadsheet: "Broadsheet", .usBroadsheet: "US Broadsheet", .britishBroadsheet: "British Broadsheet", .southAfricanBroadsheet: "South African Broadsheet",
            .ciner: "Ciner", .compact: "Compact", .nordisch: "Nordisch", .rhenish: "Rhenish", .swiss: "Swiss",
            .newspaperTabloid: "Newspaper Tabloid", .canadianTabloid: "Canadian Tabloid", .norwegianTabloid: "Norwegian Tabloid", .newYorkTimes: "New York Times", .wallStreetJournal: "Wall Street Journal",
            .folio: "Folio", .quarto: "Quarto", .imperialOctavo: "Imperial Octavo", .superOctavo: "Super Octavo", .royalOctavo: "Royal Octavo", .mediumOctavo: "Medium Octavo", .octavo: "Octavo", .crownOctavo: "Crown Octavo",
            ._12Mo: "12mo", ._16Mo: "16mo", ._18Mo: "18mo", ._32Mo: "32mo", ._48Mo: "48mo", ._64Mo: "64mo",
            .aFormat: "A Format", .bFormat: "B Format", .cFormat: "C Format",
        ]
    }
}
