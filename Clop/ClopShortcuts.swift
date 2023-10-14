//
//  ClopShortcuts.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.07.2023.
//

import AppIntents
import Foundation
import Lowtech

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

    static var title: LocalizedStringResource = "Speed up or slow down video"
    static var description = IntentDescription("Optimises a video received as input and changes its playback speed by the specific factor.")

    static var parameterSummary: some ParameterSummary {
        When(\.$playbackSpeedFactor, ComparableComparisonOperator.greaterThanOrEqualTo, 1.0, {
            Summary("Speed up \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
            }
        }, otherwise: {
            Summary("Slow down \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
            }
        })
    }

    @Parameter(title: "Video")
    var item: String

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Playback speed factor", default: 1.5)
    var playbackSpeedFactor: Double

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromString(item)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: item,
                hideFloatingResult: hideFloatingResult,
                changePlaybackSpeedBy: playbackSpeedFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: false, source: "shortcuts"
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

    static var title: LocalizedStringResource = "Crop and optimise video or image"
    static var description = IntentDescription("Resizes and does a smart crop on an image or video received as input. Use 0 for width or height to have it calculated automatically while keeping the original aspect ratio.")

    static var parameterSummary: some ParameterSummary {
        When(\.$longEdge, .equalTo, true, {
            Summary("Crop \(\.$item) to \(\.$size) over the longest edge and optimise") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$copyToClipboard
                \.$longEdge
            }
        }, otherwise: {
            Summary("Crop \(\.$item) to \(\.$width)x\(\.$height) and optimise") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$copyToClipboard
                \.$longEdge
            }
        })
    }

    @Parameter(title: "Video or image path, URL or base64 data")
    var item: String

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

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        if longEdge, (size ?? 0) == 0 {
            throw $size.needsValueError()
        }
        if !longEdge, (width ?? 0) == 0, (height ?? 0) == 0 {
            throw IntentError.message("You need to specify at least one non-zero width or height")
        }

        let clip = ClipboardType.fromString(item)
        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: item,
                hideFloatingResult: hideFloatingResult,
                cropTo: CropSize(width: (longEdge ? size : width) ?? 0, height: (longEdge ? size : height) ?? 0, longEdge: longEdge),
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts"
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

struct OptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise video or image"
    static var description = IntentDescription("Optimises an image or video received as input.")

    static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$item)") {
            \.$hideFloatingResult
            \.$aggressiveOptimisation
            \.$downscaleFactor
            \.$copyToClipboard
        }
    }

    @Parameter(title: "Video or image path, URL or base64 data")
    var item: String

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Downscale fraction", description: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)", default: 1.0, controlStyle: .field, inclusiveRange: (0.1, 1.0))
    var downscaleFactor: Double

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromString(item)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: item,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts"
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
