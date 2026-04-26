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

// MARK: - Pipeline

struct Pipeline: Codable, Hashable, Identifiable, Defaults.Serializable {
    init(id: String = UUID().uuidString, steps: [PipelineStep], name: String? = nil, rawText: String? = nil, skipOptimisation: Bool = false, hideResult: Bool = false, libraryID: String? = nil, fileType: ClopFileType? = nil) {
        self.id = id
        self.steps = steps
        self.name = name
        self.rawText = rawText
        self.skipOptimisation = skipOptimisation
        self.hideResult = hideResult
        self.libraryID = libraryID
        self.fileType = fileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        do {
            steps = try container.decodeIfPresent([PipelineStep].self, forKey: .steps) ?? []
        } catch {
            steps = []
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        skipOptimisation = try container.decodeIfPresent(Bool.self, forKey: .skipOptimisation) ?? false
        hideResult = try container.decodeIfPresent(Bool.self, forKey: .hideResult) ?? false
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        fileType = try container.decodeIfPresent(ClopFileType.self, forKey: .fileType)

        // Re-parse rawText when steps failed to decode or are empty.
        // rawText parsing handles all step types correctly and provides
        // backward compatibility when the Codable schema changes.
        if steps.isEmpty, let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps = Self.parseSteps(from: rawText)
        }
    }

    var id: String = UUID().uuidString
    var steps: [PipelineStep]
    var name: String?
    var rawText: String?
    var skipOptimisation = false
    var hideResult = false
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

    static func cleanupPipelineText(_ text: String) -> String {
        text.replacingOccurrences(of: ")->", with: ") ->")
            .replacingOccurrences(of: "->(", with: "-> (")
    }

    static func parseSteps(from text: String) -> [PipelineStep] {
        text.components(separatedBy: "->")
            .flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { parsePipelineStep($0) }
    }

    mutating func updateFromText(_ text: String) {
        rawText = Self.cleanupPipelineText(text)
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
    let exec = PipelineExecution(file: file, source: source, optimiser: optimiser, fileType: fileType, forceHide: pipeline.hideResult)

    log.debug("Pipeline: executing \(pipeline.steps.count) steps on \(file.string)")

    // For video/image, compile consecutive processing/media steps into a single ffmpeg/vips pass
    var stepIndex = 0
    while stepIndex < pipeline.steps.count {
        let step = pipeline.steps[stepIndex]

        if optimiser.inRemoval {
            log.debug("Pipeline: step \(stepIndex) skipped, optimiser removed")
            break
        }

        // Collect consecutive processing/media steps for compiled execution
        let isEncodable = step.isProcessingStep || step.category == .mediaSpecific
        if isEncodable {
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
                let consumed = await exec.handleCompiledBatch(batch, startIndex: stepIndex)
                stepIndex += consumed
                continue
            }
        }

        let stepDesc = step.displayString
        exec.stepIndex = stepIndex
        exec.stepDesc = stepDesc
        log.info("Pipeline: step[\(stepIndex)] \(stepDesc) started on \(exec.currentFile.string)")

        switch step {
        case let .optimise(encoder, adaptive, videoEncoder, dpi, location):
            await exec.handleOptimise(encoder: encoder, adaptive: adaptive, videoEncoder: videoEncoder, dpi: dpi, location: location)
        case let .extractPagesAsImages(format, quality, location):
            await exec.handleExtractPagesAsImages(format: format, quality: quality, location: location)
        case let .downscale(factor, location):
            await exec.handleDownscale(factor: factor, location: location)
        case let .lowerBitrate(kbps, location):
            await exec.handleLowerBitrate(kbps: kbps, location: location)
        case let .convert(formatStr, location):
            await exec.handleConvert(formatStr: formatStr, location: location)
        case let .crop(width, height, longEdge, location):
            await exec.handleCrop(width: width, height: height, longEdge: longEdge, location: location)
        case let .copy(to):
            try exec.handleCopy(to: to)
        case let .move(to):
            try exec.handleMove(to: to)
        case let .rename(to):
            try exec.handleRename(to: to)
        case let .delete(path):
            await exec.handleDelete(path: path)
        case let .filterIf(condition):
            exec.handleFilterIf(condition: condition)
        case let .filterIfNot(condition):
            exec.handleFilterIfNot(condition: condition)
        case .removeAudio:
            await exec.handleRemoveAudio()
        case let .changeSpeed(factor):
            try await exec.handleChangeSpeed(factor: factor)
        case let .runScript(scriptPath):
            await exec.handleRunScript(scriptPath: scriptPath)
        case let .runShortcut(shortcut):
            await exec.handleRunShortcut(shortcut: shortcut)
        case let .copyToClipboard(format, relativeTo):
            exec.handleCopyToClipboard(format: format, relativeTo: relativeTo)
        case .copyLinkForSending:
            await exec.handleCopyLinkForSending()
        case let .shelveWith(app):
            try await exec.handleShelveWith(app: app)
        case let .uploadWith(app):
            try await exec.handleUploadWith(app: app)
        case let .openWith(app):
            try await exec.handleOpenWith(app: app)
        }

        if exec.shouldStop { break }

        log.info("Pipeline: step[\(stepIndex)] \(stepDesc) completed, file: \(exec.currentFile.string)")
        stepIndex += 1
    }

    return (exec.currentFile, exec.shownVisibleResult)
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
            // Respect the pipeline's hideResult toggle: keep the optimiser hidden when set.
            if !shownVisible {
                let resultSize = resultFile.fileSize() ?? 0
                let originalSize = file.fileSize() ?? 0
                optimiser.url = resultFile.url
                optimiser.hidden = pipeline.hideResult
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
