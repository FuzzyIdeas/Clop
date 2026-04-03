import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Pipeline")

// MARK: - Pipeline Action

/// A discrete action in the optimisation pipeline.
enum PipelineAction: CustomStringConvertible {
    case convert(format: UTType)
    case optimise
    case downscale(factor: Double?, cropSize: CropSize?)
    case changePlaybackSpeed(factor: Double)
    case removeAudio
    case runShortcut(Shortcut)

    var description: String {
        switch self {
        case let .convert(format):
            "convert(\(format.preferredFilenameExtension ?? "?"))"
        case .optimise:
            "optimise"
        case let .downscale(factor, cropSize):
            if cropSize != nil { "downscale(crop)" }
            else if let factor { "downscale(\((factor * 100).intround)%)" }
            else { "downscale" }
        case let .changePlaybackSpeed(factor):
            "changePlaybackSpeed(\(factor)x)"
        case .removeAudio:
            "removeAudio"
        case let .runShortcut(shortcut):
            "runShortcut(\(shortcut.name))"
        }
    }

    var isDownscale: Bool {
        if case .downscale = self { return true }
        return false
    }

    var isOptimise: Bool {
        if case .optimise = self { return true }
        return false
    }

    var isConvert: Bool {
        if case .convert = self { return true }
        return false
    }

    var isChangePlaybackSpeed: Bool {
        if case .changePlaybackSpeed = self { return true }
        return false
    }

    var isRemoveAudio: Bool {
        if case .removeAudio = self { return true }
        return false
    }
}

// MARK: - Pipeline Step Data Model

enum EncoderQuality: String, Codable, CaseIterable, Defaults.Serializable {
    case aggressive, medium, lossless
}

enum VideoEncoderQuality: String, Codable, CaseIterable, Defaults.Serializable {
    case efficient, highQuality, lossless
}

enum VideoCodec: String, Codable, CaseIterable, Defaults.Serializable {
    case hevcVideoToolbox = "hevc_videotoolbox"
    case libx265
    case libsvtav1
}

enum ClipboardCopyFormat: String, Codable, CaseIterable, Defaults.Serializable {
    case path, imageData, markdown
}

enum StepLocation: String, Codable, CaseIterable, Defaults.Serializable {
    case inPlace, sameFolder, temporaryFolder
}

// MARK: - FilterCondition

struct FilterCondition: Codable, Hashable, Defaults.Serializable {
    var types: [String]?
    var regex: String?
    var nameContains: String?
    var nameIs: String?
    var fileSizeGreaterThan: Int?
    var fileSizeLowerThan: Int?
    var widthGreaterThan: Int?
    var widthLowerThan: Int?
    var heightGreaterThan: Int?
    var heightLowerThan: Int?

    var isEmpty: Bool {
        let noText: Bool = types == nil && regex == nil && nameContains == nil && nameIs == nil
        let noSize: Bool = fileSizeGreaterThan == nil && fileSizeLowerThan == nil
        let noDims: Bool = widthGreaterThan == nil && widthLowerThan == nil && heightGreaterThan == nil && heightLowerThan == nil
        return noText && noSize && noDims
    }

    func evaluate(file: FilePath, context: TemplateContext) -> (matches: Bool, captures: [String]) {
        let name = file.lastComponent?.string ?? ""
        var captures: [String] = []

        if let types, !types.isEmpty {
            let ext = file.extension ?? ""
            let fileUTType = UTType(filenameExtension: ext)
            let matchesType = types.contains { typeStr in
                guard let uttype = UTType(typeStr) else { return false }
                return fileUTType?.conforms(to: uttype) ?? false
            }
            if !matchesType { return (false, []) }
        }

        if let regex, !regex.isEmpty {
            guard let re = try? NSRegularExpression(pattern: regex) else { return (false, []) }
            let range = NSRange(name.startIndex..., in: name)
            guard let match = re.firstMatch(in: name, range: range) else { return (false, []) }
            for i in 1 ..< match.numberOfRanges {
                if let r = Range(match.range(at: i), in: name) {
                    captures.append(String(name[r]))
                }
            }
        }

        if let nameContains, !nameContains.isEmpty {
            if !name.localizedCaseInsensitiveContains(nameContains) { return (false, []) }
        }

        if let nameIs, !nameIs.isEmpty {
            if name != nameIs { return (false, []) }
        }

        if let fileSizeGreaterThan {
            guard let size = file.fileSize(), size > fileSizeGreaterThan else { return (false, []) }
        }

        if let fileSizeLowerThan {
            guard let size = file.fileSize(), size < fileSizeLowerThan else { return (false, []) }
        }

        if let widthGreaterThan {
            guard let w = imageWidth(file), w > widthGreaterThan else { return (false, []) }
        }

        if let widthLowerThan {
            guard let w = imageWidth(file), w < widthLowerThan else { return (false, []) }
        }

        if let heightGreaterThan {
            guard let h = imageHeight(file), h > heightGreaterThan else { return (false, []) }
        }

        if let heightLowerThan {
            guard let h = imageHeight(file), h < heightLowerThan else { return (false, []) }
        }

        return (true, captures)
    }
}

private func imageWidth(_ file: FilePath) -> Int? {
    guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int
    else { return nil }
    return w
}

private func imageHeight(_ file: FilePath) -> Int? {
    guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return h
}

// MARK: - PipelineStep

enum PipelineStep: Codable, Hashable, Identifiable, Defaults.Serializable {
    // Processing steps (explicit, no implicit optimisation)
    case optimise(encoder: EncoderQuality = .medium, adaptive: Bool = false, videoEncoder: VideoEncoder? = nil)
    case downscale(factor: Double, location: String = "inPlace")
    case convert(to: String, location: String = "sameFolder")
    case crop(width: Int? = nil, height: Int? = nil, keepAspectRatio: Bool = true, longEdge: Int? = nil, location: String = "inPlace")

    // File path operations (template vars supported)
    case copy(to: String)
    case move(to: String)
    case rename(to: String)
    case delete(path: String = "sourceFile")

    // Filters (pipeline stops silently if condition fails)
    case filterIf(FilterCondition)
    case filterIfNot(FilterCondition)

    // Media-specific
    case removeAudio
    case changeSpeed(factor: Double)

    // Generic actions
    case runScript(path: String)
    case runShortcut(Shortcut)
    case copyToClipboard(format: ClipboardCopyFormat = .path, relativeTo: String? = nil)

    var id: String {
        switch self {
        case let .optimise(encoder, adaptive, videoEncoder): "optimise-\(videoEncoder?.rawValue ?? encoder.rawValue)-\(adaptive)"
        case let .downscale(factor, location): "downscale-\(factor)-\(location)"
        case let .convert(to, location): "convert-\(to)-\(location)"
        case let .crop(width, height, _, longEdge, location): "crop-\(longEdge ?? width ?? 0)-\(height ?? 0)-\(location)"
        case let .copy(to): "copy-\(to)"
        case let .move(to): "move-\(to)"
        case let .rename(to): "rename-\(to)"
        case let .delete(path): "delete-\(path)"
        case .filterIf: "filterIf"
        case .filterIfNot: "filterIfNot"
        case .removeAudio: "removeAudio"
        case let .changeSpeed(factor): "changeSpeed-\(factor)"
        case let .runScript(path): "runScript-\(path)"
        case let .runShortcut(shortcut): "runShortcut-\(shortcut.name)"
        case let .copyToClipboard(format, relativeTo): "copyToClipboard-\(format.rawValue)-\(relativeTo ?? "")"
        }
    }

    var stepName: String {
        switch self {
        case .optimise: "optimise"
        case .downscale: "downscale"
        case .convert: "convert"
        case .crop: "crop"
        case .copy: "copy"
        case .move: "move"
        case .rename: "rename"
        case .delete: "delete"
        case .filterIf: "if"
        case .filterIfNot: "ifNot"
        case .removeAudio: "removeAudio"
        case .changeSpeed: "changeSpeed"
        case .runScript: "runScript"
        case .runShortcut: "runShortcut"
        case .copyToClipboard: "copyToClipboard"
        }
    }

    var displayString: String {
        switch self {
        case let .optimise(encoder, adaptive, videoEncoder):
            var params = ["encoder: \(videoEncoder?.rawValue ?? encoder.rawValue)"]
            if adaptive { params.append("adaptive: true") }
            return "optimise(\(params.joined(separator: ", ")))"
        case let .downscale(factor, location):
            var params = ["factor: \(factor)"]
            if location != "inPlace" { params.append("location: \(location)") }
            return "downscale(\(params.joined(separator: ", ")))"
        case let .convert(to, location):
            var params = ["to: \(to)"]
            if location != "sameFolder" { params.append("location: \(location)") }
            return "convert(\(params.joined(separator: ", ")))"
        case let .crop(width, height, keepAspectRatio, longEdge, location):
            var params: [String] = []
            if let longEdge { params.append("longEdge: \(longEdge)") }
            if let width { params.append("width: \(width)") }
            if let height { params.append("height: \(height)") }
            if !keepAspectRatio { params.append("keepAspectRatio: false") }
            if location != "inPlace" { params.append("location: \(location)") }
            return "crop(\(params.joined(separator: ", ")))"
        case let .copy(to): return "copy(to: \(to))"
        case let .move(to): return "move(to: \(to))"
        case let .rename(to): return "rename(to: \(to))"
        case let .delete(path): return "delete(path: \(path))"
        case let .filterIf(condition): return "if(\(condition.displayString))"
        case let .filterIfNot(condition): return "ifNot(\(condition.displayString))"
        case .removeAudio: return "removeAudio"
        case let .changeSpeed(factor): return "changeSpeed(factor: \(factor))"
        case let .runScript(path): return "runScript(path: \(path))"
        case let .runShortcut(shortcut): return "runShortcut(name: \(shortcut.name))"
        case let .copyToClipboard(format, relativeTo):
            var params = ["format: \(format.rawValue)"]
            if let relativeTo { params.append("relativeTo: \(relativeTo)") }
            return "copyToClipboard(\(params.joined(separator: ", ")))"
        }
    }

    var isProcessingStep: Bool {
        switch self {
        case .optimise, .downscale, .convert, .crop: true
        default: false
        }
    }

    var isFileOperation: Bool {
        switch self {
        case .copy, .move, .rename, .delete: true
        default: false
        }
    }

    var isFilter: Bool {
        switch self {
        case .filterIf, .filterIfNot: true
        default: false
        }
    }

    var category: StepCategory {
        switch self {
        case .optimise, .downscale, .convert, .crop: .processing
        case .copy, .move, .rename, .delete: .fileOperation
        case .filterIf, .filterIfNot: .filter
        case .removeAudio, .changeSpeed: .mediaSpecific
        case .runScript, .runShortcut, .copyToClipboard: .action
        }
    }
}

enum StepCategory {
    case processing, fileOperation, filter, mediaSpecific, action

    var nsColor: NSColor {
        switch self {
        case .processing: .systemBlue
        case .fileOperation: .systemGreen
        case .filter: .systemOrange
        case .mediaSpecific: .systemTeal
        case .action: .systemIndigo
        }
    }
}

extension PipelineStep {
    var categoryNSColor: NSColor { category.nsColor }
}

extension FilterCondition {
    var displayString: String {
        var parts: [String] = []
        if let types, !types.isEmpty {
            parts.append("types: \(types.joined(separator: ", "))")
        }
        if let regex { parts.append("regex: \(regex)") }
        if let nameContains { parts.append("nameContains: \(nameContains)") }
        if let nameIs { parts.append("nameIs: \(nameIs)") }
        if let fileSizeGreaterThan { parts.append("size > \(fileSizeGreaterThan)") }
        if let fileSizeLowerThan { parts.append("size < \(fileSizeLowerThan)") }
        if let widthGreaterThan { parts.append("width > \(widthGreaterThan)") }
        if let widthLowerThan { parts.append("width < \(widthLowerThan)") }
        if let heightGreaterThan { parts.append("height > \(heightGreaterThan)") }
        if let heightLowerThan { parts.append("height < \(heightLowerThan)") }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
}

// MARK: - Pipeline

struct Pipeline: Codable, Hashable, Identifiable, Defaults.Serializable {
    init(id: String = UUID().uuidString, steps: [PipelineStep], name: String? = nil, rawText: String? = nil, skipOptimisation: Bool = false, libraryID: String? = nil, fileType: ClopFileType? = nil) {
        self.id = id
        self.steps = steps
        self.name = name
        self.rawText = rawText
        self.skipOptimisation = skipOptimisation
        self.libraryID = libraryID
        self.fileType = fileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        steps = try container.decodeIfPresent([PipelineStep].self, forKey: .steps) ?? []
        name = try container.decodeIfPresent(String.self, forKey: .name)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        skipOptimisation = try container.decodeIfPresent(Bool.self, forKey: .skipOptimisation) ?? false
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        fileType = try container.decodeIfPresent(ClopFileType.self, forKey: .fileType)

        // Re-parse rawText when steps is empty -- rawText parsing handles all step types
        // correctly while auto-Codable can lose data for some step types.
        if steps.isEmpty, let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps = Self.parseSteps(from: rawText)
        }
    }

    var id: String = UUID().uuidString
    var steps: [PipelineStep]
    var name: String?
    var rawText: String?
    var skipOptimisation = false
    var libraryID: String?
    var fileType: ClopFileType?

    var isEmpty: Bool { steps.isEmpty && (rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && libraryID == nil }

    var isLibraryReference: Bool { libraryID != nil }

    /// Resolve library references: if this pipeline points to a saved pipeline, return that one.
    /// Falls back to self if the library entry was deleted (graceful degradation).
    var resolved: Pipeline {
        guard let libraryID else { return self }
        return Defaults[.savedPipelines].first(where: { $0.id == libraryID }) ?? self
    }

    var displayText: String {
        if isLibraryReference {
            let r = resolved
            return r.name ?? r.rawText ?? r.steps.map(\.displayString).joined(separator: " -> ")
        }
        return rawText ?? steps.map(\.displayString).joined(separator: " -> ")
    }

    /// Create a lightweight reference pipeline pointing to a library pipeline.
    static func reference(to lib: Pipeline) -> Pipeline {
        Pipeline(id: UUID().uuidString, steps: [], libraryID: lib.id)
    }

    static func parseSteps(from text: String) -> [PipelineStep] {
        text.components(separatedBy: "->")
            .flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { parsePipelineStep($0) }
    }

    mutating func updateFromText(_ text: String) {
        rawText = text
        steps = Self.parseSteps(from: text)
    }

}

// MARK: - TemplateContext

struct TemplateContext {
    let sourceFile: FilePath
    var regexCaptures: [String] = []

    var sourceFolder: String {
        sourceFile.removingLastComponent().string
    }

    var sourceFileName: String {
        sourceFile.stem ?? ""
    }

    var sourceFileExtension: String {
        sourceFile.extension ?? ""
    }

    func resolve(_ template: String) -> String {
        var result = template

        // Strip surrounding quotes if present
        if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }

        // Resolve % tokens using the same system as CLI output templates.
        // generateFileName always appends the source file extension, but pipeline steps
        // handle extensions separately (e.g. convert changes the format), so strip it.
        if result.contains("%") {
            var num = 0
            result = generateFileName(template: result, for: sourceFile, autoIncrementingNumber: &num, safe: false)
            if let ext = sourceFile.extension, result.hasSuffix(".\(ext)") {
                result = String(result.dropLast(ext.count + 1))
            }
        }

        // Resolve $1, $2 etc. from regex captures
        for (i, capture) in regexCaptures.enumerated() {
            result = result.replacingOccurrences(of: "$\(i + 1)", with: capture)
        }

        // Expand tilde
        if result.hasPrefix("~/") {
            result = HOME.string + result.dropFirst(1)
        }

        return result
    }
}

// MARK: - Build Pipeline

/// Build a pipeline from the parameters that callers currently pass to `optimiseItem` / `optimiseURL`.
///
/// The returned actions follow the existing mutual-exclusivity rules:
///  - downscale OR changePlaybackSpeed OR optimise (never more than one of these)
///  - removeAudio and runShortcut can be appended to any of the above
@MainActor func buildPipeline(
    scalingFactor: Double? = nil,
    cropSize: CropSize? = nil,
    changePlaybackSpeedFactor: Double? = nil,
    removeAudio: Bool? = nil
) -> [PipelineAction] {
    var actions: [PipelineAction] = []

    if cropSize != nil || (scalingFactor != nil && scalingFactor! < 1) {
        actions.append(.downscale(factor: scalingFactor, cropSize: cropSize))
    } else if let changePlaybackSpeedFactor, changePlaybackSpeedFactor != 1, changePlaybackSpeedFactor != 0 {
        actions.append(.changePlaybackSpeed(factor: changePlaybackSpeedFactor))
    } else {
        actions.append(.optimise)
    }

    if removeAudio == true {
        actions.append(.removeAudio)
    }

    return actions
}

// MARK: - Shared Helpers

/// Apply conversion behaviour settings when an image is converted to a different format.
///
/// Handles backup of original (for `.inPlace`) and copying converted file to the original directory (for non-`.temporary`).
/// Returns the image to use going forward (possibly with updated path) and sets `originalPath` if the original was preserved.
@MainActor func applyImageConversionBehaviour(original img: Image, converted: Image, originalPath: inout FilePath?) throws -> Image {
    guard img.path.dir != FilePath.images else {
        return converted
    }

    let behaviour = Defaults[.convertedImageBehaviour]
    if behaviour == .inPlace, let backupPath = img.path.clopBackupPath {
        img.path.backup(path: backupPath, force: true, operation: .move)
    }
    if behaviour != .temporary {
        try converted.path.setOptimisationStatusXattr("pending")
        let path = try converted.path.copy(to: img.path.dir, force: true)
        originalPath = img.path
        return Image(data: converted.data, path: path, nsImage: converted.image, type: converted.type, optimised: converted.optimised, retinaDownscaled: converted.retinaDownscaled)
    }
    return converted
}

/// Compute the downscale factor for an image, handling auto-decrement when no explicit factor is given.
@MainActor func computeImageDownscaleFactor(id: String?, factor: Double?, cropSize: CropSize?, imageSize: NSSize) -> Double {
    if let cropSize {
        return cropSize.factor(from: imageSize)
    }
    if let factor {
        return factor
    }
    let pathID = id ?? ""
    if let currentFactor = opt(pathID)?.downscaleFactor {
        return max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    }
    if let current = OM.current, current.id == pathID {
        let f = max(current.downscaleFactor > 0.5 ? current.downscaleFactor - 0.25 : current.downscaleFactor - 0.1, 0.1)
        current.downscaleFactor = f
        return f
    }
    return max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
}

/// Compute the downscale factor for a video.
@MainActor func computeVideoDownscaleFactor(id: String?, factor: Double?, cropSize: CropSize?, videoSize: CGSize) -> Double {
    if let cropSize {
        return cropSize.factor(from: videoSize)
    }
    if let factor {
        return factor
    }
    if let currentFactor = opt(id ?? "")?.downscaleFactor {
        return max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    }
    return max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
}

/// Compute the speed change factor for a video.
@MainActor func computeSpeedFactor(id: String?, factor: Double?) -> Double {
    if let factor {
        return factor
    }
    if let currentFactor = opt(id ?? "")?.changePlaybackSpeedFactor {
        return min(currentFactor < 2 ? currentFactor + 0.25 : currentFactor + 1.0, 10)
    }
    return 1.25
}

/// Build the operation label for the optimiser UI.
@MainActor func operationLabel(
    for actions: [PipelineAction],
    filename: String,
    imageSize: NSSize? = nil,
    videoSize: CGSize? = nil,
    aggressive: Bool
) -> String {
    let showFilename = !Defaults[.showImages]

    if let downscale = actions.first(where: \.isDownscale), case let .downscale(factor, cropSize) = downscale {
        let size = imageSize ?? videoSize ?? .zero
        let scaleString = if let cs = cropSize?.computedSize(from: size) {
            "\(cs.width > 0 ? cs.width.i.s : "Auto")×\(cs.height > 0 ? cs.height.i.s : "Auto")"
        } else if let factor {
            "\((factor * 100).intround)%"
        } else {
            "?"
        }
        return "Scaling to \(scaleString)" + (aggressive ? " (aggressive)" : "")
    }

    if let speed = actions.first(where: \.isChangePlaybackSpeed), case let .changePlaybackSpeed(factor) = speed {
        let label = if factor > 1 {
            "Speeding up by \(factor < 2 ? factor.str(decimals: 2) : factor.i.s)x"
        } else if factor == 1 {
            "Reverting to original speed"
        } else {
            "Slowing down to \(factor != 0.5 ? factor.str(decimals: 2) : "0.5")x"
        }
        return label + (aggressive ? " (aggressive)" : "")
    }

    let base = showFilename ? "Optimising \(filename)" : "Optimising"
    return base + (aggressive ? " (aggressive)" : "")
}

// MARK: - Image Pipeline

/// Unified image pipeline replacing `optimiseImage()` and `downscaleImage()`.
///
/// Handles: auto-conversion from settings, cache lookup, debouncing, backup creation,
/// sequential action execution (convert → optimise → downscale → shortcut),
/// error handling, finalization, clipboard copy, and cache update.
@discardableResult
@MainActor func runImagePipeline(
    _ img: Image,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    saveTo savePath: FilePath? = nil,
    copyToClipboard: Bool = false,
    allowTiff: Bool? = nil,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    adaptiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil
) async throws -> Image? {
    let path = img.path
    var img = img

    // Guard: already optimised
    guard !img.optimised else {
        throw ClopError.alreadyOptimised(path)
    }
    var pathString = path.string

    // Guard: TIFF setting
    guard img.type != .tiff || (allowTiff ?? Defaults[.optimiseTIFF]) else {
        log.debug("Skipping image \(pathString) because TIFF optimisation is disabled")
        throw ClopError.skippedType("TIFF optimisation is disabled")
    }

    // Guard: clipboard pause
    if id == Optimiser.IDs.clipboardImage, pauseForNextClipboardEvent {
        log.debug("Skipping image \(pathString) because it was paused")
        pauseForNextClipboardEvent = false
        throw ClopError.optimisationPaused(path)
    }

    var allowLarger = allowLarger
    var originalPath: FilePath?

    let hasDownscale = actions.contains(where: \.isDownscale)

    // Auto-detect conversion from settings (unless explicit .convert action exists)
    let hasExplicitConvert = actions.contains(where: \.isConvert)
    let autoConversionFormat: UTType? = if hasExplicitConvert {
        nil
    } else {
        Defaults[.formatsToConvertToJPEG].contains(img.type)
            ? .jpeg
            : (Defaults[.formatsToConvertToPNG].contains(img.type) ? .png : nil)
    }

    if let autoConversionFormat {
        let converted = try img.convert(to: autoConversionFormat, asTempFile: true)
        img = try applyImageConversionBehaviour(original: img, converted: converted, originalPath: &originalPath)
        pathString = img.path.string
        allowLarger = true
    } else if !hasExplicitConvert, !hasDownscale, let optImg = try getCachedOptimisedImage(img: img, id: id, retinaDownscaled: false) {
        log.debug("Using cached optimised image \(optImg.path)")
        return optImg
    }

    // Compute effective downscale factor (including auto-decrement for repeated presses)
    var effectiveDownscaleFactor: Double?
    if hasDownscale, case let .downscale(factor, cropSize) = actions.first(where: \.isDownscale)! {
        effectiveDownscaleFactor = computeImageDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: cropSize, imageSize: img.size)
        scalingFactor = effectiveDownscaleFactor!
    }

    let aggressive = aggressiveOptimisation ?? opt(id ?? pathString)?.aggressive ?? false

    // Build operation label
    var effectiveActions = actions
    if let effectiveDownscaleFactor, hasDownscale {
        // Replace downscale action with computed factor
        effectiveActions = actions.map { action in
            if case let .downscale(_, cropSize) = action {
                return .downscale(factor: effectiveDownscaleFactor, cropSize: cropSize)
            }
            return action
        }
    }
    let opLabel = operationLabel(for: effectiveActions, filename: img.path.lastComponent?.string ?? "", imageSize: img.size, aggressive: aggressive)

    // Set up optimiser
    let optimiser = OM.optimiser(
        id: id ?? pathString, type: .image(img.type),
        operation: opLabel,
        hidden: hideFloatingResult, source: source, indeterminateProgress: true
    )
    if !hideFloatingResult {
        optimiser.thumbnail = img.image
    }
    if hasDownscale {
        optimiser.downscaleFactor = effectiveDownscaleFactor ?? scalingFactor
        optimiser.remover = nil
        optimiser.inRemoval = false
        optimiser.stop(remove: false)
    } else {
        optimiser.downscaleFactor = 1.0
    }
    optimiser.newSize = nil
    optimiser.newBytes = -1
    if let url = originalPath?.url {
        optimiser.convertedFromURL = url
    }

    var done = false
    var result: Image?

    // Cancel existing debouncers for this path
    imageOptimiseDebouncers[pathString]?.cancel()
    imageResizeDebouncers[pathString]?.cancel()

    let workItem = mainAsyncAfter(ms: debounceMS) {
        if !hasDownscale {
            scalingFactor = 1.0
        }
        optimiser.stop(remove: false)
        optimiser.operation = opLabel
        optimiser.originalURL = img.path.backup(path: img.path.clopBackupPath, force: false, operation: .copy)?.url ?? img.path.url
        optimiser.url = (savePath ?? img.path).url
        if id == Optimiser.IDs.clipboardImage {
            optimiser.startingURL = optimiser.url
        }
        if !hideFloatingResult {
            OM.current = optimiser
        }

        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let img = img
        let pathString = pathString
        let allowLarger = allowLarger
        let effectiveActions = effectiveActions
        var previouslyCached = true

        imageOptimisationQueue.addOperation {
            defer {
                mainActor { done = true }
            }

            var currentImage: Image? = img
            var shortcutChanged = false
            do {
                log.debug("Running image pipeline \(effectiveActions) for \(pathString)")

                for action in effectiveActions {
                    guard let ci = currentImage else { break }

                    switch action {
                    case let .convert(format):
                        let converted = try ci.convert(to: format, asTempFile: true)
                        currentImage = converted
                        mainActor {
                            optimiser.operation = "Converting to \(format.preferredFilenameExtension?.uppercased() ?? "?")"
                        }

                    case .optimise:
                        mainActor {
                            let base = Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)"
                            optimiser.operation = base + (aggressive ? " (aggressive)" : "")
                        }
                        currentImage = try ci.optimise(
                            optimiser: optimiser,
                            allowLarger: allowLarger,
                            aggressiveOptimisation: aggressiveOptimisation,
                            adaptiveSize: adaptiveOptimisation ?? Defaults[.adaptiveImageSize]
                        )
                        if currentImage!.type == img.type {
                            currentImage = try currentImage?.copyWithPath(currentImage!.path.copy(to: img.path, force: true))
                        } else {
                            mainActor {
                                optimiser.url = currentImage!.path.url
                                optimiser.type = .image(currentImage!.type)
                            }
                        }

                    case let .downscale(_, cropSize):
                        if let cropSize, cropSize.width > 0, cropSize.height > 0 {
                            currentImage = try ci.resize(
                                toSize: cropSize,
                                optimiser: optimiser,
                                aggressiveOptimisation: aggressive,
                                adaptiveSize: adaptiveOptimisation ?? false
                            )
                        } else {
                            if let s = cropSize?.ns {
                                scalingFactor = s.width == 0 ? s.height / ci.size.height : s.width / ci.size.width
                            }
                            currentImage = try ci.resize(
                                toFraction: effectiveDownscaleFactor ?? scalingFactor,
                                optimiser: optimiser,
                                aggressiveOptimisation: aggressive,
                                adaptiveSize: adaptiveOptimisation ?? false
                            )
                        }
                        // Copy result to target path
                        if id != Optimiser.IDs.clipboardImage, currentImage!.type == img.type {
                            let newURL = try (currentImage!.path.copy(to: savePath ?? img.path, force: true)).url
                            mainActor {
                                optimiser.url = newURL
                                optimiser.type = .image(currentImage!.type)
                            }
                        }

                    case let .runShortcut(shortcut):
                        if let changedImage = try? ci.runThroughShortcut(
                            shortcut: shortcut, optimiser: optimiser,
                            allowLarger: allowLarger,
                            aggressiveOptimisation: aggressive,
                            source: source
                        ) {
                            currentImage = changedImage
                            mainActor {
                                optimiser.url = changedImage.path.url
                                optimiser.type = .image(changedImage.type)
                            }
                            shortcutChanged = true
                        }

                    default:
                        break // skip video-only actions
                    }
                }

                // Save optimised image path to cache to avoid re-optimising it after it is saved to file
                if let currentImage {
                    mainActor {
                        if OM.optimisedFilesByHash[img.hash] == nil {
                            previouslyCached = false
                            OM.optimisedFilesByHash[img.hash] = currentImage.path
                        }
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in image pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger,
                ClopError.alreadyOptimised, ClopError.alreadyResized
            {
                if currentImage == nil { currentImage = img }
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in image pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in image pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard let optimisedImage = currentImage else { return }

            mainActor {
                if !hideFloatingResult {
                    OM.current = optimiser
                }
                optimiser.finish(
                    oldBytes: img.data.count, newBytes: optimisedImage.data.count,
                    oldSize: img.size, newSize: optimisedImage.size,
                    removeAfterMs: id == Optimiser.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
                )

                if id == Optimiser.IDs.clipboardImage, Defaults[.copyImageFilePath], Defaults[.useCustomNameTemplateForClipboardImages] {
                    optimiser.rename(to: generateFileName(template: Defaults[.customNameTemplateForClipboardImages] ?! DEFAULT_NAME_TEMPLATE, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber]))
                    if let path = optimiser.path {
                        result = Image(data: optimisedImage.data, path: path, nsImage: optimisedImage.image, type: optimisedImage.type, optimised: optimisedImage.optimised, retinaDownscaled: optimisedImage.retinaDownscaled)
                    } else {
                        result = optimisedImage
                    }
                } else {
                    result = optimisedImage
                }

                if copyToClipboard {
                    if Defaults[.appendClipboardResults], Defaults[.copyConsecutiveClipboardImages] {
                        OM.copyAllClipboardImagesToClipboard()
                    } else {
                        (result ?? optimisedImage).copyToClipboard()
                    }
                }
                if !shortcutChanged, !previouslyCached {
                    OM.optimisedFilesByHash[img.hash] = (result ?? optimisedImage).path
                }
            }
        }
    }

    imageOptimiseDebouncers[pathString] = workItem
    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}

// MARK: - Video Pipeline

/// Unified video pipeline replacing `optimiseVideo()`, `downscaleVideo()`, and `changePlaybackSpeedVideo()`.
///
/// Actions are "compiled" into parameters for one `Video.optimise()` call (since ffmpeg can do
/// resize + speed change + audio removal + encoding in a single pass).
@discardableResult
@MainActor func runVideoPipeline(
    _ video: Video,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    originalPath: FilePath? = nil,
    copyToClipboard: Bool = false,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    videoEncoderOverride: VideoEncoder? = nil,
    ffmpegEncoderOverride: [String]? = nil,
    outputExtension: String? = nil,
    source: OptimisationSource? = nil
) async throws -> Video? {
    let path = video.path
    let pathString = path.string
    let itemType = ItemType.from(filePath: path)

    let hasDownscale = actions.contains(where: \.isDownscale)
    let hasSpeedChange = actions.contains(where: \.isChangePlaybackSpeed)

    // Compile actions into Video.optimise() parameters
    var resizeTo: CGSize?
    var cropTo: CropSize?
    var speedFactor: Double?
    var removeAudio: Bool?
    var shortcutAction: Shortcut?

    for action in actions {
        switch action {
        case let .downscale(factor, cropSize):
            cropTo = cropSize
            if let resolution = video.size {
                let effectiveFactor: Double = if let cropSize {
                    computeVideoDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: cropSize, videoSize: resolution)
                } else {
                    computeVideoDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: nil, videoSize: resolution)
                }
                scalingFactor = effectiveFactor
                resizeTo = cropSize?.computedSize(from: resolution) ?? resolution.scaled(by: effectiveFactor)
            }
        case let .changePlaybackSpeed(factor):
            speedFactor = computeSpeedFactor(id: id ?? pathString, factor: factor)
        case .removeAudio:
            removeAudio = true
        case let .runShortcut(shortcut):
            shortcutAction = shortcut
        default:
            break // .optimise and .convert handled below
        }
    }

    // Determine forceMP4 from settings (auto-conversion)
    let forceMP4 = actions.contains(where: \.isConvert) || Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie)

    let resolution = video.size
    let aggressive = aggressiveOptimisation ?? opt(id ?? pathString)?.aggressive ?? false

    // Build operation label
    var labelActions = actions
    if hasDownscale, resizeTo != nil, resolution != nil {
        labelActions = actions.map { action in
            if case let .downscale(_, cropSize) = action {
                return .downscale(factor: scalingFactor, cropSize: cropSize)
            }
            return action
        }
    }
    if hasSpeedChange, let speedFactor {
        labelActions = labelActions.map { action in
            if case .changePlaybackSpeed = action {
                return .changePlaybackSpeed(factor: speedFactor)
            }
            return action
        }
    }
    let opLabel = if debounceMS > 0, !hasDownscale, !hasSpeedChange {
        "Waiting for video to be ready"
    } else {
        operationLabel(for: labelActions, filename: path.lastComponent?.string ?? "", videoSize: resolution, aggressive: aggressive)
    }

    // Set up optimiser
    let optimiser = OM.optimiser(id: id ?? pathString, type: itemType, operation: opLabel, hidden: hideFloatingResult, source: source)
    if optimiser.oldBytes == 0 {
        optimiser.oldBytes = video.fileSize
    }
    if optimiser.oldSize == nil {
        optimiser.oldSize = resolution
    }
    if optimiser.url == nil {
        optimiser.url = path.url
    }
    if hasDownscale {
        optimiser.downscaleFactor = scalingFactor
        optimiser.remover = nil
        optimiser.inRemoval = false
        optimiser.stop(remove: false)
    }
    if hasSpeedChange {
        optimiser.changePlaybackSpeedFactor = speedFactor ?? 1.0
        optimiser.remover = nil
        optimiser.inRemoval = false
        optimiser.stop(remove: false)
    }

    // If this is a re-downscale or speed-change, inherit the other setting
    if hasDownscale, !hasSpeedChange {
        speedFactor = optimiser.changePlaybackSpeedFactor != 1.0 ? optimiser.changePlaybackSpeedFactor : nil
    }
    if hasSpeedChange, !hasDownscale {
        if let existingSize = optimiser.newSize {
            resizeTo = existingSize
        }
    }

    // Compute originalPath for backup (used by Video.optimise)
    let effectiveOriginalPath: FilePath? = if hasDownscale || hasSpeedChange {
        [.cli, .finder, .service, .dropZone].contains(source) ? video.path : originalPath
    } else {
        nil
    }

    var done = false
    var result: Video?

    videoOptimiseDebouncers[pathString]?.cancel()

    let workItem = mainAsyncAfter(ms: debounceMS) {
        let finalOpLabel = operationLabel(for: labelActions, filename: optimiser.filename, videoSize: resolution, aggressive: aggressive)
        optimiser.operation = finalOpLabel
        if !hasDownscale, !hasSpeedChange {
            optimiser.originalURL = path.url
        }
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let fileSize = video.fileSize
        var previouslyCached = true

        videoOptimisationQueue.addOperation {
            var optimisedVideo: Video?
            defer {
                mainActor { done = true }
            }

            do {
                if !hideFloatingResult {
                    mainActor { OM.current = optimiser }
                }

                log.debug("Running video pipeline \(actions) for \(pathString)")

                optimisedVideo = try video.optimise(
                    optimiser: optimiser,
                    forceMP4: forceMP4,
                    outputExtension: outputExtension,
                    resizeTo: resizeTo,
                    cropTo: cropTo,
                    changePlaybackSpeedBy: speedFactor,
                    originalPath: effectiveOriginalPath,
                    aggressiveOptimisation: aggressive,
                    removeAudio: removeAudio,
                    encoderOverride: ffmpegEncoderOverride,
                    videoEncoderOverride: videoEncoderOverride
                )

                // Move result to original location if same extension but different path
                if optimisedVideo!.path.extension == video.path.extension, optimisedVideo!.path != video.path {
                    let newPath = try optimisedVideo!.path.move(to: video.path, force: true)
                    optimisedVideo = optimisedVideo?.copyWithPath(newPath)
                }

                // Size check: only for plain optimise (no resize/speed change)
                if !hasDownscale, !hasSpeedChange,
                   optimisedVideo!.convertedFrom == nil,
                   optimisedVideo!.fileSize >= fileSize, !allowLarger
                {
                    video.path.restore(backupPath: video.path.clopBackupPath, force: true)
                    mainActor {
                        optimiser.oldBytes = fileSize
                        optimiser.url = video.path.url
                    }
                    throw ClopError.videoSizeLarger(path)
                }

                // Save to cache (only for plain optimise)
                if !hasDownscale, !hasSpeedChange {
                    mainActor {
                        if OM.optimisedFilesByHash[video.hash] == nil {
                            previouslyCached = false
                            OM.optimisedFilesByHash[video.hash] = optimisedVideo!.path
                        }
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in video pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedVideo = video
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in video pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in video pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard var optimisedVideo else { return }

            // Run shortcut if present
            var shortcutChangedVideo = false
            if let shortcutAction, let changedVideo = try? optimisedVideo.runThroughShortcut(
                shortcut: shortcutAction, optimiser: optimiser,
                allowLarger: allowLarger,
                aggressiveOptimisation: aggressive,
                source: source
            ) {
                optimisedVideo = changedVideo
                mainActor { optimiser.url = changedVideo.path.url }
                shortcutChangedVideo = true
            }

            mainActor {
                result = optimisedVideo
                optimiser.url = optimisedVideo.path.url
                if let ext = optimisedVideo.path.extension, let utType = UTType(filenameExtension: ext) {
                    optimiser.type = .video(utType)
                }
                if !hideFloatingResult {
                    OM.current = optimiser
                }

                if hasDownscale {
                    optimiser.finish(
                        oldBytes: fileSize, newBytes: optimisedVideo.fileSize,
                        oldSize: resolution, newSize: resizeTo,
                        removeAfterMs: hideFilesAfter
                    )
                } else {
                    optimiser.finish(
                        oldBytes: fileSize, newBytes: optimisedVideo.fileSize,
                        removeAfterMs: hideFilesAfter
                    )
                }

                if copyToClipboard {
                    optimiser.copyToClipboard()
                }

                if !shortcutChangedVideo, !previouslyCached, !hasDownscale, !hasSpeedChange {
                    OM.optimisedFilesByHash[video.hash] = optimisedVideo.path
                }
            }
        }
    }
    videoOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}

// MARK: - PDF Pipeline

/// Unified PDF pipeline replacing `optimisePDF()`.
@discardableResult
@MainActor func runPDFPipeline(
    _ pdf: PDF,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    copyToClipboard: Bool = false,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil
) async throws -> PDF? {
    let path = pdf.path
    let pathString = path.string

    let aggressive = aggressiveOptimisation ?? false
    let opLabel = if debounceMS > 0 {
        "Waiting for PDF to be ready"
    } else {
        operationLabel(for: actions, filename: path.lastComponent?.string ?? "", aggressive: aggressive)
    }

    let optimiser = OM.optimiser(id: id ?? pathString, type: .pdf, operation: opLabel, hidden: hideFloatingResult, source: source)

    // Extract crop size and shortcut from actions
    var cropSize: CropSize?
    var shortcutAction: Shortcut?
    for action in actions {
        if case let .downscale(_, cs) = action { cropSize = cs }
        if case let .runShortcut(s) = action { shortcutAction = s }
    }

    var done = false
    var result: PDF?

    pdfOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        let finalOpLabel = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressive ? " (aggressive)" : "")
        optimiser.operation = finalOpLabel
        optimiser.originalURL = path.url
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let fileSize = pdf.fileSize
        var previouslyCached = true

        pdfOptimisationQueue.addOperation {
            var optimisedPDF: PDF?
            defer {
                mainActor {
                    pdfOptimiseDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }
            do {
                if !hideFloatingResult {
                    mainActor { OM.current = optimiser }
                }

                log.debug("Running PDF pipeline \(actions) for \(pathString)")

                let backupPath = pdf.path.clopBackupPath
                optimisedPDF = try pdf.optimise(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation)
                if let cropSize {
                    optimisedPDF!.cropTo(aspectRatio: cropSize.longEdge ? cropSize.fractionalAspectRatio : cropSize.aspectRatio)
                }
                if !allowLarger, cropSize == nil, optimisedPDF!.fileSize >= fileSize {
                    pdf.path.restore(backupPath: backupPath ?? pdf.path.clopBackupPath, force: true)
                    mainActor {
                        optimiser.oldBytes = fileSize
                        optimiser.url = pdf.path.url
                    }
                    throw ClopError.pdfSizeLarger(path)
                }

                // Save optimised PDF path to cache to avoid re-optimising it after it is saved to file
                mainActor {
                    if OM.optimisedFilesByHash[pdf.hash] == nil {
                        previouslyCached = false
                        OM.optimisedFilesByHash[pdf.hash] = optimisedPDF!.path
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in PDF pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedPDF = pdf
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in PDF pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in PDF pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard var optimisedPDF else { return }

            var shortcutChangedPDF = false
            if let shortcutAction, let changedPDF = try? optimisedPDF.runThroughShortcut(
                shortcut: shortcutAction, optimiser: optimiser,
                allowLarger: allowLarger,
                aggressiveOptimisation: aggressive,
                source: source
            ) {
                optimisedPDF = changedPDF
                mainActor { optimiser.url = changedPDF.path.url }
                shortcutChangedPDF = true
            }

            mainActor {
                result = optimisedPDF
                optimiser.url = optimisedPDF.path.url
                optimiser.finish(oldBytes: fileSize, newBytes: optimisedPDF.fileSize, oldSize: optimisedPDF.size, removeAfterMs: hideFilesAfter)

                if copyToClipboard {
                    optimiser.copyToClipboard()
                }

                if !shortcutChangedPDF, !previouslyCached {
                    OM.optimisedFilesByHash[pdf.hash] = optimisedPDF.path
                }
            }
        }
    }
    pdfOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}

@discardableResult
@MainActor func runAudioPipeline(
    _ audio: Audio,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    copyToClipboard: Bool = false,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    source: OptimisationSource? = nil
) async throws -> Audio? {
    let path = audio.path
    let pathString = path.string

    let audioType = path.url.utType() ?? .mp3
    let opLabel = if debounceMS > 0 {
        "Waiting for audio to be ready"
    } else {
        operationLabel(for: actions, filename: path.lastComponent?.string ?? "", aggressive: false)
    }

    let optimiser = OM.optimiser(id: id ?? pathString, type: .audio(audioType), operation: opLabel, hidden: hideFloatingResult, source: source)

    var done = false
    var result: Audio?

    audioOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        let finalOpLabel = Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)"
        optimiser.operation = finalOpLabel
        optimiser.originalURL = path.url
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let fileSize = audio.fileSize

        audioOptimisationQueue.addOperation {
            var optimisedAudio: Audio?
            defer {
                mainActor {
                    audioOptimiseDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }
            do {
                if !hideFloatingResult {
                    mainActor { OM.current = optimiser }
                }

                log.debug("Running audio pipeline \(actions) for \(pathString)")
                optimisedAudio = try audio.optimise(optimiser: optimiser)

                if !allowLarger, optimisedAudio!.fileSize >= fileSize {
                    audio.path.restore(backupPath: audio.path.clopBackupPath, force: true)
                    mainActor {
                        optimiser.oldBytes = fileSize
                        optimiser.url = audio.path.url
                    }
                    throw ClopError.audioSizeLarger(path)
                }

                mainActor {
                    if OM.optimisedFilesByHash[audio.hash] == nil {
                        OM.optimisedFilesByHash[audio.hash] = optimisedAudio!.path
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in audio pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.audioSizeLarger {
                optimisedAudio = audio
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in audio pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in audio pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard var optimisedAudio else { return }

            // Move optimised file to the correct location based on user preference
            let behaviour = Defaults[.optimisedAudioBehaviour]
            if optimisedAudio.path.dir == FilePath.audios {
                let destPath: FilePath? = switch behaviour {
                case .inPlace:
                    path.dir.appending("\(path.stem!).\(Defaults[.audioFormat].fileExtension)")
                case .sameFolder:
                    path.dir / generateFileName(template: Defaults[.sameFolderNameTemplateAudio], for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber])
                case .specificFolder:
                    try? generateFilePath(template: Defaults[.specificFolderNameTemplateAudio], for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber], mkdir: true)
                case .temporary:
                    nil
                }

                if let destPath, destPath != optimisedAudio.path {
                    if let movedPath = try? optimisedAudio.path.move(to: destPath, force: true) {
                        try? movedPath.setOptimisationStatusXattr("true")
                        optimisedAudio = optimisedAudio.copyWithPath(movedPath)
                    }
                }

                if behaviour == .inPlace, path.extension?.lowercased() != Defaults[.audioFormat].fileExtension {
                    try? fm.removeItem(at: path.url)
                }
            }

            let hideFilesAfter = Defaults[.autoHideFloatingResultsAfter] * 1000
            mainActor {
                result = optimisedAudio
                optimiser.url = optimisedAudio.path.url
                optimiser.audio = optimisedAudio
                if let outputType = Defaults[.audioFormat].utType {
                    optimiser.type = .audio(outputType)
                }
                optimiser.finish(oldBytes: fileSize, newBytes: optimisedAudio.fileSize, removeAfterMs: hideFilesAfter)

                if copyToClipboard {
                    optimiser.copyToClipboard()
                }
            }
        }
    }
    audioOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}

// MARK: - Pipeline Execution Engine

/// Look up user-configured pipelines for a given file type and source.
func pipelinesFor(type: ItemType, source: OptimisationSource) -> [Pipeline] {
    guard let key = type.pipelineKey else {
        log.debug("Pipeline: no pipeline key for type \(String(describing: type))")
        return []
    }
    let all = Defaults[key]
    let sourceStr = source.string
    let pipelines = all[sourceStr] ?? []
    log.debug("Pipeline: lookup type=\(String(describing: type)) source='\(sourceStr)' found \(pipelines.count) pipelines (available keys: \(all.keys.joined(separator: ", ")))")
    return pipelines.map(\.resolved)
}

/// Execute a user-configured pipeline on a file that has already been processed (or not).
///
/// Each step receives the current file path and returns a (possibly changed) path for the next step.
/// When a step uses a non-inPlace location, make a temp copy of the input file
/// so that runImagePipeline/runVideoPipeline don't overwrite the original.
func tempCopyIfNeeded(_ file: FilePath, location: String) -> FilePath {
    guard location != "inPlace" else { return file }
    let tempDir = FilePath.images
    let dest = tempDir.appending("pipeline-\(UUID().uuidString.prefix(8))-\(file.lastComponent?.string ?? "file")")
    return (try? file.copy(to: dest, force: true)) ?? file
}

/// Remove a temp file created by `tempCopyIfNeeded` if it differs from the original.
func cleanupTempFile(_ tempFile: FilePath, original: FilePath) {
    guard tempFile != original, tempFile.string.contains("pipeline-") else { return }
    try? fm.removeItem(atPath: tempFile.string)
}

/// Apply a location parameter to a result file: inPlace (no-op), sameFolder, temporaryFolder, or a template path.
/// Returns the final file path after copying/moving.
func applyLocation(_ location: String, to resultFile: FilePath, original: FilePath, context: TemplateContext) -> FilePath {
    switch location {
    case "inPlace":
        // If the result ended up in a different directory (e.g. format conversion
        // changed the extension so the tool wrote to a temp path), move it next
        // to the original with the correct filename.
        if resultFile.dir != original.dir, let filename = resultFile.lastComponent?.string {
            let dest = original.dir.appending(filename)
            if let moved = try? resultFile.move(to: dest, force: true) {
                // Conversion produced a valid file with a different extension;
                // trash the original input file since the caller asked for inPlace.
                if moved.extension != original.extension, original.exists, (moved.fileSize() ?? 0) > 0 {
                    try? fm.trashItem(at: original.url, resultingItemURL: nil)
                }
                return moved
            }
        }
        return resultFile
    case "sameFolder":
        var filename = resultFile.lastComponent?.string ?? resultFile.name.string
        // Strip the pipeline-<UUID>- prefix added by tempCopyIfNeeded
        if let range = filename.range(of: #"^pipeline-[A-F0-9]{8}-"#, options: .regularExpression) {
            filename = String(filename[range.upperBound...])
        }
        let dest = original.dir.appending(filename)
        if dest != resultFile, let copied = try? resultFile.copy(to: dest, force: true) {
            return copied
        }
        return resultFile
    case "temporaryFolder":
        return resultFile
    default:
        // Template path: resolve % variables and $1/$2 captures
        let resolved = context.resolve(location)
        guard !resolved.isEmpty else { return resultFile }

        // If resolved is just a filename (no /), put it in the same folder as the original
        let destPath: FilePath
        if !resolved.contains("/") {
            let ext = resultFile.extension ?? original.extension ?? ""
            let nameWithExt = resolved.contains(".") ? resolved : "\(resolved).\(ext)"
            destPath = original.dir.appending(nameWithExt)
        } else if let fp = resolved.filePath {
            destPath = fp
        } else {
            return resultFile
        }

        let destDir = destPath.removingLastComponent()
        try? fm.createDirectory(atPath: destDir.string, withIntermediateDirectories: true)
        if let copied = try? resultFile.copy(to: destPath, force: true) {
            log.info("Pipeline: location template '\(location)' resolved to \(copied.string)")
            return copied
        }
        return resultFile
    }
}

/// Filter steps stop the pipeline silently if the condition fails.
/// File operation steps resolve template variables before acting.
@MainActor func executePipeline(
    _ pipeline: Pipeline,
    file: FilePath,
    source: OptimisationSource,
    optimiser: Optimiser,
    fileType: ClopFileType
) async throws -> (file: FilePath, shownVisibleResult: Bool) {
    var currentFile = file
    var context = TemplateContext(sourceFile: file)
    /// Whether the current file is a temp pipeline artifact that should not show a floating result.
    var isIntermediateTempFile: Bool { currentFile.string.contains("/pipeline-") }
    /// Track whether any pipeline step showed a visible floating result.
    var shownVisibleResult = false

    log.debug("Pipeline: executing \(pipeline.steps.count) steps on \(file.string)")

    // For video, compile consecutive processing/media steps into a single ffmpeg pass
    var stepIndex = 0
    while stepIndex < pipeline.steps.count {
        let step = pipeline.steps[stepIndex]

        if optimiser.inRemoval {
            log.debug("Pipeline: step \(stepIndex) skipped, optimiser removed")
            break
        }

        // Collect consecutive processing/media steps for compiled execution
        let isEncodable = step.isProcessingStep || step.category == .mediaSpecific
        if isEncodable, fileType == .video || fileType == .image {
            var batch: [PipelineStep] = [step]
            var peekIdx = stepIndex + 1
            while peekIdx < pipeline.steps.count {
                let next = pipeline.steps[peekIdx]
                if next.isProcessingStep || next.category == .mediaSpecific {
                    batch.append(next)
                    peekIdx += 1
                } else {
                    break
                }
            }

            if batch.count > 1 {
                let batchDesc = batch.map(\.displayString).joined(separator: " + ")
                log.info("Pipeline: steps[\(stepIndex)...\(peekIdx - 1)] compiled: \(batchDesc) on \(currentFile.string)")

                let actions = optimiser.compilePipelineActions(from: batch)
                let hide = isIntermediateTempFile

                // Extract video encoder and ffmpeg encoder overrides
                let videoEncoderOvr: VideoEncoder? = batch.compactMap { s in
                    if case let .optimise(_, _, ve) = s { return ve }; return nil
                }.last
                var ffmpegEncoder: [String]?
                var outExt: String?
                for s in batch {
                    if case let .convert(fmt, _) = s {
                        switch fmt {
                        case "hevc": ffmpegEncoder = ["-vcodec", "hevc_videotoolbox", "-q:v", "40", "-tag:v", "hvc1"]; outExt = "mp4"
                        case "x265": ffmpegEncoder = ["-vcodec", "libx265", "-crf", "28", "-tag:v", "hvc1", "-preset", "medium"]; outExt = "mp4"
                        case "av1": ffmpegEncoder = ["-vcodec", "libsvtav1"]; outExt = "mkv"
                        default: break
                        }
                    }
                }
                let aggressive = batch.contains { if case let .optimise(enc, _, _) = $0 { return enc == .aggressive }; return false }

                if fileType == .video {
                    let vid = await (try? Video.byFetchingMetadata(path: currentFile)) ?? Video(currentFile)
                    let vidSize = vid.size ?? .zero

                    // Filter out crop/downscale actions that would upscale the video
                    let filteredActions = actions.filter { action in
                        guard case let .downscale(factor, cropSize) = action, factor == nil, let cropSize else {
                            return true
                        }
                        if cropSize.longEdge {
                            return cropSize.width > 0 && max(vidSize.width, vidSize.height) > cropSize.width.d
                        }
                        return (cropSize.width > 0 && vidSize.width > cropSize.width.d) || (cropSize.height > 0 && vidSize.height > cropSize.height.d)
                    }

                    if let result = try? await runVideoPipeline(
                        vid, actions: filteredActions,
                        allowLarger: true,
                        hideFloatingResult: hide,
                        aggressiveOptimisation: aggressive ? true : nil,
                        videoEncoderOverride: videoEncoderOvr,
                        ffmpegEncoderOverride: ffmpegEncoder,
                        outputExtension: outExt,
                        source: source
                    ) {
                        currentFile = result.path
                        if !hide { shownVisibleResult = true }
                    }
                } else if fileType == .image, let data = try? Data(contentsOf: currentFile.url) {
                    let img = Image(data: data, path: currentFile, retinaDownscaled: false)

                    // Filter out crop/downscale actions that would upscale the image
                    let filteredActions = actions.filter { action in
                        guard case let .downscale(factor, cropSize) = action, factor == nil, let cropSize else {
                            return true
                        }
                        let imgW = img.size.width
                        let imgH = img.size.height
                        if cropSize.longEdge {
                            return cropSize.width > 0 && max(imgW, imgH) > cropSize.width.d
                        }
                        return (cropSize.width > 0 && imgW > cropSize.width.d) || (cropSize.height > 0 && imgH > cropSize.height.d)
                    }

                    if let result = try? await runImagePipeline(
                        img, actions: filteredActions,
                        allowLarger: true,
                        hideFloatingResult: hide,
                        aggressiveOptimisation: aggressive,
                        source: source
                    ) {
                        currentFile = result.path
                        if !hide { shownVisibleResult = true }
                    }
                }

                stepIndex = peekIdx
                continue
            }
        }

        log.info("Pipeline: step[\(stepIndex)] \(step.displayString) on \(currentFile.string)")

        switch step {
        // MARK: Processing steps

        case let .optimise(encoder, adaptive, videoEncoder):
            let aggressive = encoder == .aggressive
            switch fileType {
            case .image:
                if let data = try? Data(contentsOf: currentFile.url) {
                    let img = Image(data: data, path: currentFile, retinaDownscaled: false)
                    let hide = isIntermediateTempFile
                    if let result = try? await runImagePipeline(
                        img, actions: [.optimise],
                        allowLarger: true,
                        hideFloatingResult: hide,
                        aggressiveOptimisation: aggressive,
                        adaptiveOptimisation: adaptive,
                        source: source
                    ) {
                        currentFile = result.path
                        if !hide { shownVisibleResult = true }
                    }
                }
            case .video:
                let hide = isIntermediateTempFile
                let vid = Video(currentFile)
                if let result = try? await runVideoPipeline(
                    vid, actions: [.optimise],
                    allowLarger: true,
                    hideFloatingResult: hide,
                    aggressiveOptimisation: aggressive,
                    videoEncoderOverride: videoEncoder,
                    source: source
                ) {
                    currentFile = result.path
                    if !hide { shownVisibleResult = true }
                }
            case .pdf:
                let hide = isIntermediateTempFile
                let pdf = PDF(currentFile)
                if let result = try? await runPDFPipeline(
                    pdf, actions: [.optimise],
                    allowLarger: true,
                    hideFloatingResult: hide,
                    source: source
                ) {
                    currentFile = result.path
                    if !hide { shownVisibleResult = true }
                }
            case .audio:
                let hide = isIntermediateTempFile
                let audio = Audio(currentFile)
                if let result = try? await runAudioPipeline(
                    audio, actions: [.optimise],
                    hideFloatingResult: hide,
                    source: source
                ) {
                    currentFile = result.path
                    if !hide { shownVisibleResult = true }
                }
            }

        case let .downscale(factor, location):
            let action = PipelineAction.downscale(factor: factor, cropSize: nil)
            let inputFile = tempCopyIfNeeded(currentFile, location: location)
            let usedTempCopy = inputFile != currentFile
            let hide = usedTempCopy || isIntermediateTempFile

            switch fileType {
            case .image:
                if let data = try? Data(contentsOf: inputFile.url) {
                    let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                    if let result = try? await runImagePipeline(img, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                        if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                        if !hide { shownVisibleResult = true }
                    }
                }
            case .video:
                let vid = Video(inputFile)
                if let result = try? await runVideoPipeline(vid, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                    if !hide { shownVisibleResult = true }
                }
            default:
                log.debug("Pipeline: downscale not applicable for \(fileType)")
            }

        case let .convert(formatStr, location):
            let inputFile = tempCopyIfNeeded(currentFile, location: location)
            let usedTempCopy = inputFile != currentFile
            let hide = usedTempCopy || isIntermediateTempFile

            // Video codec targets (not file extensions) need special handling
            let videoCodecArgs: (encoder: [String], ext: String)? = switch formatStr {
            case "hevc": (["-vcodec", "hevc_videotoolbox", "-q:v", "40", "-tag:v", "hvc1"], "mp4")
            case "x265": (["-vcodec", "libx265", "-crf", "28", "-tag:v", "hvc1", "-preset", "medium"], "mp4")
            case "av1": (["-vcodec", "libsvtav1"], "mkv")
            default: nil
            }

            if let videoCodecArgs, fileType == .video {
                let vid = Video(inputFile)
                let forceMP4 = videoCodecArgs.ext == "mp4"
                let outExt: String? = forceMP4 ? nil : videoCodecArgs.ext
                if let result = try? vid.optimise(
                    optimiser: optimiser, forceMP4: forceMP4, outputExtension: outExt, backup: false,
                    encoderOverride: videoCodecArgs.encoder
                ) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                    if !hide { shownVisibleResult = true }
                }
            } else if let uttype = UTType(filenameExtension: formatStr) {
                let action = PipelineAction.convert(format: uttype)
                switch fileType {
                case .image:
                    if let data = try? Data(contentsOf: inputFile.url) {
                        let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                        if let result = try? await runImagePipeline(img, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                            currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                            if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                            if !hide { shownVisibleResult = true }
                        }
                    }
                case .video:
                    let vid = Video(inputFile)
                    if let result = try? await runVideoPipeline(vid, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                        if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                        if !hide { shownVisibleResult = true }
                    }
                default:
                    log.debug("Pipeline: convert not applicable for \(fileType)")
                }
            } else {
                log.debug("Pipeline: unknown format '\(formatStr)' for convert step")
            }

        case let .crop(width, height, _, longEdge, location):
            let useLongEdge = longEdge != nil
            let targetW = useLongEdge ? (longEdge ?? 0).d : (width ?? 0).d
            let targetH = useLongEdge ? (longEdge ?? 0).d : (height ?? 0).d
            let cs = CropSize(width: targetW, height: targetH, longEdge: useLongEdge)
            let action = PipelineAction.downscale(factor: nil, cropSize: cs)
            let inputFile = tempCopyIfNeeded(currentFile, location: location)
            let usedTempCopy = inputFile != currentFile
            let hide = usedTempCopy || isIntermediateTempFile

            switch fileType {
            case .image:
                if let data = try? Data(contentsOf: inputFile.url) {
                    let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                    let imgW = img.size.width
                    let imgH = img.size.height
                    let maxDim = max(imgW, imgH)
                    let needsCrop = useLongEdge
                        ? (targetW > 0 && maxDim > targetW)
                        : (targetW > 0 && imgW > targetW) || (targetH > 0 && imgH > targetH)
                    if needsCrop, let result = try? await runImagePipeline(img, actions: [action], allowLarger: false, hideFloatingResult: hide, source: source) {
                        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                        if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                        if !hide { shownVisibleResult = true }
                    } else {
                        // Even if no crop needed, apply location (e.g. rename template)
                        if location != "inPlace" {
                            currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                        } else {
                            log.debug("Pipeline: crop skipped, image \(imgW.i)x\(imgH.i) already within target")
                        }
                    }
                }
            case .video:
                let vid = await (try? Video.byFetchingMetadata(path: inputFile)) ?? Video(inputFile)
                let vidSize = vid.size ?? .zero
                let maxDim = max(vidSize.width, vidSize.height)
                let needsCrop = useLongEdge
                    ? (targetW > 0 && maxDim > targetW)
                    : (targetW > 0 && vidSize.width > targetW) || (targetH > 0 && vidSize.height > targetH)
                if needsCrop, let result = try? await runVideoPipeline(vid, actions: [action], allowLarger: false, hideFloatingResult: hide, source: source) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy { cleanupTempFile(inputFile, original: file) }
                    if !hide { shownVisibleResult = true }
                } else {
                    if location != "inPlace" {
                        currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                    } else {
                        log.debug("Pipeline: crop skipped, video \(vidSize.width.i)x\(vidSize.height.i) already within target")
                    }
                }
            default:
                log.debug("Pipeline: crop not applicable for \(fileType)")
            }

        // MARK: File operation steps

        case let .copy(to):
            let destPath = context.resolve(to)
            if let dest = destPath.filePath {
                let destDir = dest.removingLastComponent()
                try? fm.createDirectory(atPath: destDir.string, withIntermediateDirectories: true)
                let copied = try currentFile.copy(to: dest, force: true)
                currentFile = copied
            }

        case let .move(to):
            let destPath = context.resolve(to)
            if let dest = destPath.filePath {
                let destDir = dest.removingLastComponent()
                try? fm.createDirectory(atPath: destDir.string, withIntermediateDirectories: true)
                let moved = try currentFile.move(to: dest, force: true)
                currentFile = moved
            }

        case let .rename(to):
            let newName = context.resolve(to)
            let dest = currentFile.removingLastComponent().appending(newName)
            let moved = try currentFile.move(to: dest, force: true)
            currentFile = moved

        case let .delete(path):
            let resolved = context.resolve(path)
            if let filePath = resolved.filePath, fm.fileExists(atPath: filePath.string) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: filePath.string, isDirectory: &isDir)
                if isDir.boolValue {
                    let shouldDelete = await MainActor.run {
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Move folder to Trash?"
                        alert.informativeText = "The pipeline wants to delete the folder:\n\(filePath.string)"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Move to Trash")
                        alert.addButton(withTitle: "Cancel")
                        return alert.runModal() == .alertFirstButtonReturn
                    }
                    guard shouldDelete else { break }
                }
                try? fm.trashItem(at: filePath.url, resultingItemURL: nil)
            }

        // MARK: Filter steps

        case let .filterIf(condition):
            let (matches, captures) = condition.evaluate(file: currentFile, context: context)
            if !matches {
                log.info("Pipeline: filter condition not met, stopping pipeline for \(currentFile.string)")
                return (currentFile, shownVisibleResult)
            }
            if !captures.isEmpty { context.regexCaptures = captures }

        case let .filterIfNot(condition):
            let (matches, _) = condition.evaluate(file: currentFile, context: context)
            if matches {
                log.info("Pipeline: exclusion filter matched, stopping pipeline for \(currentFile.string)")
                return (currentFile, shownVisibleResult)
            }

        // MARK: Media-specific steps

        case .removeAudio:
            if fileType == .video {
                let hide = isIntermediateTempFile
                let vid = Video(currentFile)
                if let result = try? await runVideoPipeline(vid, actions: [.removeAudio], allowLarger: true, hideFloatingResult: hide, source: source) {
                    currentFile = result.path
                    if !hide { shownVisibleResult = true }
                }
            }

        case let .changeSpeed(factor):
            switch fileType {
            case .video:
                let hide = isIntermediateTempFile
                let vid = Video(currentFile)
                if let result = try? await runVideoPipeline(vid, actions: [.changePlaybackSpeed(factor: factor)], allowLarger: true, hideFloatingResult: hide, source: source) {
                    currentFile = result.path
                    if !hide { shownVisibleResult = true }
                }
            case .audio:
                let audio = Audio(currentFile)
                let changed = try audio.changeSpeed(factor: factor, optimiser: optimiser)
                currentFile = changed.path
            default:
                log.debug("Pipeline: changeSpeed not applicable for \(fileType)")
            }

        // MARK: Generic action steps

        case let .runScript(scriptPath):
            let resolvedPath = context.resolve(scriptPath)
            let inputPath = currentFile.string
            let scriptName = FilePath(resolvedPath).stem ?? resolvedPath
            log.info("Pipeline: running script '\(scriptName)' at \(resolvedPath) with input \(inputPath)")

            let scriptResult: (newPath: FilePath?, error: String?) = await Task.detached {
                let task = Process()
                let resolvedFilePath = FilePath(resolvedPath)
                if fm.isExecutableFile(atPath: resolvedPath) {
                    task.executableURL = URL(fileURLWithPath: resolvedPath)
                    task.arguments = [inputPath]
                } else {
                    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    task.arguments = [resolvedPath, inputPath]
                }
                task.environment = ProcessInfo.processInfo.environment.merging([
                    "CLOP_INPUT_FILE": inputPath,
                ]) { _, new in new }

                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe

                do {
                    try task.run()
                } catch {
                    return (nil, "Script '\(scriptName)' failed to start: \(error.localizedDescription)")
                }
                task.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if task.terminationStatus != 0 {
                    let logContent = """
                    Script: \(scriptName) (\(resolvedPath))
                    Input: \(inputPath)
                    Exit code: \(task.terminationStatus)
                    stdout: \(stdout)
                    stderr: \(stderr)
                    """
                    let logFile = FilePath.forResize.appending("script-error-\(Date.now.timeIntervalSinceReferenceDate.i).log")
                    try? logContent.write(toFile: logFile.string, atomically: true, encoding: .utf8)
                    return (nil, "Script '\(scriptName)' failed (exit \(task.terminationStatus))|\(logFile.string)")
                }

                let trimmedOutput = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedOutput.isEmpty, let outputPath = trimmedOutput.existingFilePath {
                    return (outputPath, nil)
                }
                return (currentFile, nil)
            }.value

            if let error = scriptResult.error {
                let parts = error.split(separator: "|", maxSplits: 1)
                let errorMessage = String(parts[0])
                log.error("Pipeline: \(errorMessage)")
                optimiser.finish(error: errorMessage)
                if parts.count > 1, let logFile = String(parts[1]).existingFilePath {
                    NSWorkspace.shared.open(logFile.url)
                }
                return (currentFile, shownVisibleResult)
            }
            if let newPath = scriptResult.newPath, newPath != currentFile {
                currentFile = newPath
            }

        case let .runShortcut(shortcut):
            let tempDir: FilePath = switch fileType {
            case .image: .images
            case .video: .videos
            case .pdf: .pdfs
            case .audio: .audios
            }
            let shortcutOutFile = tempDir.appending("\(Date.now.timeIntervalSinceReferenceDate.i)-shortcut-output-for-\(currentFile.stem ?? "file")")

            guard let proc = optimiser.runShortcut(shortcut, outFile: shortcutOutFile, url: currentFile.url) else {
                break
            }

            let shortcutResult: (newPath: FilePath?, error: String?) = await Task.detached {
                proc.waitUntilExit()
                shortcutOutFile.waitForFile(for: 2)

                guard shortcutOutFile.exists, let size = shortcutOutFile.fileSize(), size > 0 else {
                    if !currentFile.exists {
                        return (nil, "Shortcut '\(shortcut.name)' removed the file without providing output")
                    }
                    return (currentFile, nil)
                }

                defer { try? FileManager.default.removeItem(atPath: shortcutOutFile.string) }

                if size < 4096,
                   let text = try? String(contentsOfFile: shortcutOutFile.string),
                   let outputPath = text.trimmingCharacters(in: .whitespacesAndNewlines).existingFilePath
                {
                    // Shortcut returned a file path (e.g. renamed/moved the file)
                    if outputPath != currentFile {
                        let outputType = UTType.from(filePath: outputPath)?.fileType
                        if outputType == nil || outputType == fileType {
                            return (outputPath, nil)
                        } else {
                            log.warning("Pipeline: shortcut '\(shortcut.name)' output path is \(outputType!) but expected \(fileType), ignoring")
                        }
                    }
                } else {
                    // Shortcut returned actual file data
                    let outputType = UTType.from(filePath: shortcutOutFile)?.fileType
                    if outputType == nil || outputType == fileType {
                        try? shortcutOutFile.copy(to: currentFile, force: true)
                    } else {
                        log.warning("Pipeline: shortcut '\(shortcut.name)' output data is \(outputType!) but expected \(fileType), ignoring")
                    }
                }
                return (currentFile, nil)
            }.value

            optimiser.running = false
            optimiser.processes = []

            if let error = shortcutResult.error {
                log.error("Pipeline: \(error)")
                optimiser.finish(error: error)
                return (currentFile, shownVisibleResult)
            }
            if let newPath = shortcutResult.newPath {
                let oldBytes = currentFile.fileSize() ?? 0
                currentFile = newPath
                optimiser.url = currentFile.url
                optimiser.finish(oldBytes: oldBytes, newBytes: currentFile.fileSize() ?? 0)
            }

        case let .copyToClipboard(format, relativeTo):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            switch format {
            case .path:
                if let relativeTo {
                    let base = context.resolve(relativeTo)
                    pasteboard.setString(currentFile.string.replacingOccurrences(of: base, with: ""), forType: .string)
                } else {
                    pasteboard.setString(currentFile.string, forType: .string)
                }
            case .imageData:
                if fileType == .image, let img = NSImage(contentsOf: currentFile.url) {
                    pasteboard.writeObjects([img])
                } else {
                    pasteboard.setString(currentFile.string, forType: .string)
                }
            case .markdown:
                let name = currentFile.stem ?? currentFile.lastComponent?.string ?? ""
                let path: String
                if let relativeTo {
                    let base = context.resolve(relativeTo)
                    path = currentFile.string.replacingOccurrences(of: base, with: "")
                } else {
                    path = currentFile.string
                }
                pasteboard.setString("[\(name)](\(path))", forType: .string)
            }
        }

        stepIndex += 1
    }

    return (currentFile, shownVisibleResult)
}

/// Run all configured pipelines for a file type and source after optimisation.
@MainActor func runPipelinesAfterOptimisation(
    file: FilePath,
    type: ItemType,
    source: OptimisationSource,
    optimiser: Optimiser
) async {
    log.info("Pipeline: checking pipelines for file=\(file.string) type=\(String(describing: type)) source=\(source.string)")
    let pipelines = pipelinesFor(type: type, source: source)

    // Seed the temp pipeline
    if let first = pipelines.first {
        optimiser.automationPipeline = first
        var steps = first.resolved.steps.filter { !$0.isFilter }
        if !first.skipOptimisation, !steps.contains(where: { $0.stepName == "optimise" || $0.stepName == "convert" }) {
            steps.insert(.optimise(), at: 0)
        }
        optimiser.tempPipeline = steps
    } else {
        optimiser.tempPipeline = [.optimise()]
    }

    guard !pipelines.isEmpty else {
        log.debug("Pipeline: no pipelines configured, skipping")
        return
    }

    let fileType: ClopFileType?
    switch type {
    case .image: fileType = .image
    case .video: fileType = .video
    case .audio: fileType = .audio
    case .pdf: fileType = .pdf
    default:
        log.debug("Pipeline: unknown file type \(String(describing: type)), skipping")
        return
    }

    guard let fileType else { return }

    var anyVisibleResult = false

    for (i, pipeline) in pipelines.enumerated() {
        let name = pipeline.name ?? "pipeline[\(i)]"
        let stepsDesc = pipeline.steps.map(\.displayString).joined(separator: " -> ")
        log.info("Pipeline: running '\(name)': \(stepsDesc)")
        do {
            let (resultFile, shownVisible) = try await executePipeline(pipeline, file: file, source: source, optimiser: optimiser, fileType: fileType)
            if shownVisible { anyVisibleResult = true }
            log.info("Pipeline: '\(name)' completed, result file: \(resultFile.string), visible: \(shownVisible)")

            // If no step showed a visible result, show one via the parent optimiser.
            if !shownVisible {
                let resultSize = resultFile.fileSize() ?? 0
                let originalSize = file.fileSize() ?? 0
                optimiser.url = resultFile.url
                optimiser.hidden = false
                optimiser.thumbnail = NSImage(contentsOf: resultFile.url)
                optimiser.finish(oldBytes: originalSize, newBytes: resultSize)
                anyVisibleResult = true
            }
        } catch {
            log.error("Pipeline: '\(name)' failed: \(error)")
        }
    }

    // If the optimiser was created just for pipeline execution (skipOptimisation case),
    // and some step already showed a visible result, just remove the parent silently.
    if optimiser.operation == "Running pipeline", anyVisibleResult {
        optimiser.remove(after: 0)
    } else if optimiser.operation == "Running pipeline" {
        optimiser.finish(notice: "Pipeline completed")
    }
}
