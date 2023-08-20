//
//  ClopShortcuts.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.07.2023.
//

import AppIntents
import Foundation

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case general
    case message(_ message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .message(message): return "Error: \(message)"
        case .general: return "Error"
        }
    }
}

var shortcutsOptimisationCount = 0

struct OptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise video or image"
    static var description = IntentDescription("Optimises an image or video received as input.")

    static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$item)") {
            \.$hideFloatingResult
            \.$aggressiveOptimisation
            \.$downscaleFactor
        }
    }

    @Parameter(title: "Video or image path, URL or base64 data")
    var item: String

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Downscale fraction", description: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)", default: 1.0, controlStyle: .field, inclusiveRange: (0.1, 1.0))
    var downscaleFactor: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        let clip = ClipboardType.fromString(item)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(clip, id: item, hideFloatingResult: hideFloatingResult, downscaleTo: downscaleFactor, aggressiveOptimisation: aggressiveOptimisation, optimisationCount: &shortcutsOptimisationCount)
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            print(error)
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
