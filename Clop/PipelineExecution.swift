import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "PipelineExecution")

/// Map an EncoderQuality to a fixed PDF DPI so the encoder preset is deterministic
/// rather than driven by user defaults. An explicit `dpi:` param on the step still
/// overrides this mapping.
func pdfDPIForEncoder(_ encoder: EncoderQuality?) -> Int? {
    switch encoder {
    case .lossless: PDF_DPI_NO_DOWNSAMPLE
    case .medium: PDF_DPI_ADAPTIVE
    case .aggressive: 100
    case .none: nil
    }
}

@MainActor
final class PipelineExecution {
    init(file: FilePath, source: OptimisationSource, optimiser: Optimiser, fileType: ClopFileType, forceHide: Bool = false) {
        currentFile = file
        originalFile = file
        context = TemplateContext(sourceFile: file)
        self.source = source
        self.optimiser = optimiser
        self.fileType = fileType
        self.forceHide = forceHide
    }

    var currentFile: FilePath
    var context: TemplateContext
    var shownVisibleResult = false
    /// Whether any non-filter step actually executed. Stays false when a leading
    /// filter condition stops the pipeline before it does anything, letting callers
    /// fall back to a normal optimisation pass.
    var didWork = false
    var shouldStop = false
    var stepIndex = 0
    var stepDesc = ""

    let originalFile: FilePath
    let fileType: ClopFileType
    let source: OptimisationSource
    let optimiser: Optimiser
    let forceHide: Bool

    /// A pipeline shows ONE morphing result card by default: every step renders into the
    /// parent optimiser (renderTargetID) and the card stays visible across steps, so `hide`
    /// depends only on the pipeline-level toggle, not on whether the working file is a temp
    /// copy. (The old `/pipeline-` check hid intermediate steps, which is what produced the
    /// flickering per-step cards.)
    var hide: Bool {
        forceHide
    }

    /// The optimiser every step renders into, so a multi-step pipeline shows one card that
    /// morphs through its stages instead of spawning a separate result per step. The `fork`
    /// step is the explicit way to also produce a second card.
    var renderTargetID: String {
        optimiser.id
    }

    /// Save destination for clipboard re-encode steps so the visible result tracks a stable
    /// file (matches `optimiser.downscale` / `executeTempPipeline`). nil for non-clipboard.
    var clipboardSaveTo: FilePath? {
        source == .clipboard ? (optimiser.startingURL?.filePath ?? optimiser.path) : nil
    }

    /// Whether a clipboard image re-encode step should copy its result back to the clipboard,
    /// matching `optimiseClipboardImage`'s copyToClipboard decision.
    var copyResultToClipboard: Bool {
        source == .clipboard && fileType == .image
            && (!Defaults[.appendClipboardResults] || Defaults[.copyConsecutiveClipboardImages])
    }

    /// Clipboard image pipelines must keep updating the single "Clipboard image" optimiser
    /// (rather than spawning a new floating result keyed by each step's temp file path) so a
    /// pipeline like `downscale(0.5)` shows only one result. For in-place steps on a clipboard
    /// source, reuse the parent optimiser id; for file/dir sources the optimiser id already
    /// equals the file path so this is a no-op.
    func encodeID(forLocation location: String) -> String? {
        renderTargetID
    }

    /// After `applyLocation` copies the result somewhere outside the temp cache,
    /// point the visible child optimiser (created by run{Video,Image,PDF,Audio}Pipeline
    /// keyed by the temp input path) at the final destination so the floating result
    /// tracks a file that won't be deleted by cache cleanup. The `url` setter
    /// re-derives path/filename and calls `refetch()` to refresh the thumbnail.
    func retargetChildOptimiser(originalID: String, to dest: FilePath) {
        guard let child = opt(originalID), child.url != dest.url else { return }
        child.url = dest.url
    }

    /// Point the single result card at the step's final file when it's a renderable media
    /// file, so the one card follows the file as steps convert/move it. No-op for side-effect
    /// or non-renderable steps (send-link, clipboard copy, delete), so the card keeps its last
    /// good thumbnail + size/resolution/bitrate/DPI deltas.
    func syncRenderTarget() {
        guard isRenderableMediaFile(currentFile) else { return }
        retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
    }

    // MARK: - Compiled Batch Execution

    /// Execute a batch of consecutive processing/media steps as a single compiled pass.
    /// Returns the number of steps consumed (so the caller can advance the step index).
    func handleCompiledBatch(_ batch: [PipelineStep], startIndex: Int) async -> Int {
        let batchDesc = batch.map(\.displayString).joined(separator: " + ")
        let endIndex = startIndex + batch.count - 1
        log.debug("Pipeline: steps[\(startIndex)...\(endIndex)] compiled: \(batchDesc) on \(self.currentFile.string)")

        let actions = optimiser.compilePipelineActions(from: batch)

        // The batch result goes where the last located step says. Convert defaults to
        // sameFolder (keep the original), the other processing steps to inPlace.
        // When a convert step's location is the default "sameFolder" and no explicit
        // non-default location overrides it, honour the manual-conversion behaviour
        // setting (which the user may have set to inPlace via --convert-behaviour).
        var location: String = batch.compactMap(\.location).last(where: { $0 != "inPlace" }) ?? "inPlace"
        let batchHasConvert = batch.contains { if case .convert = $0 { return true }; return false }
        if batchHasConvert, location == "sameFolder" {
            let behaviour = optimiser.placementOverride?.manualConvert ?? fileType.behaviour(for: .manualConvert)
            if let behaviour {
                switch behaviour {
                case .inPlace:
                    location = "inPlace"
                case .sameFolder:
                    location = "sameFolder"
                case .temporary:
                    location = "temporaryFolder"
                case .specificFolder:
                    if let key = fileType.specificFolderTemplateKey(for: .manualConvert) {
                        location = optimiser.placementOverride?.specificFolderTemplate ?? Defaults[key]
                    }
                }
            }
        }
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        let aggressive = batch.contains { if case let .optimise(enc, _, _, _, _) = $0 { return enc == .aggressive }; return false }
        let explicitDPI: Int? = batch.compactMap { if case let .optimise(_, _, _, d, _) = $0 { return d }; return nil }.last
        let lastEncoder: EncoderQuality? = batch.compactMap { if case let .optimise(enc, _, _, _, _) = $0 { return enc }; return nil }.last
        let dpi: Int? = explicitDPI ?? pdfDPIForEncoder(lastEncoder)

        var success = false

        switch fileType {
        case .video:
            success = await runCompiledVideoBatch(batch: batch, actions: actions, inputFile: inputFile, location: location, aggressive: aggressive)
        case .image:
            success = await runCompiledImageBatch(batch: batch, actions: actions, inputFile: inputFile, location: location, aggressive: aggressive)
        case .audio:
            success = await runCompiledAudioBatch(batch: batch, actions: actions, inputFile: inputFile, location: location, aggressive: aggressive)
        case .pdf:
            success = await runCompiledPDFBatch(actions: actions, inputFile: inputFile, location: location, aggressive: aggressive, dpi: dpi)
        }

        if success {
            if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
            if !hide { shownVisibleResult = true }
        } else {
            log.warning("Pipeline: steps[\(startIndex)...\(endIndex)] compiled batch failed for \(self.fileType.rawValue) \(self.currentFile.string)")
        }

        log.debug("Pipeline: steps[\(startIndex)...\(endIndex)] completed, file: \(self.currentFile.string)")
        return batch.count
    }

    // MARK: - Processing Steps

    func handleOptimise(encoder: EncoderQuality?, adaptive: Bool, videoEncoder: VideoEncoder?, dpi: Int? = nil, location: String) async {
        let aggressive = encoder == .aggressive
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        switch fileType {
        case .image:
            if let data = try? Data(contentsOf: inputFile.url) {
                let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                if let result = try? await runImagePipeline(
                    img, actions: [.optimise],
                    id: encodeID(forLocation: location),
                    saveTo: clipboardSaveTo,
                    copyToClipboard: copyResultToClipboard,
                    allowLarger: false,
                    hideFloatingResult: hide,
                    aggressiveOptimisation: aggressive,
                    adaptiveOptimisation: adaptive,
                    source: source
                ) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                    retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
                } else {
                    log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for image \(inputFile.string)")
                    if location != "inPlace" {
                        currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                    }
                }
            }
        case .video:
            let vid = Video(inputFile)
            if let result = try? await runVideoPipeline(
                vid, actions: [.optimise], id: renderTargetID,
                allowLarger: false,
                hideFloatingResult: hide,
                aggressiveOptimisation: aggressive,
                videoEncoderOverride: videoEncoder,
                source: source
            ) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
                retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(inputFile.string)")
                if location != "inPlace" {
                    currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                }
            }
        case .pdf:
            let pdf = PDF(inputFile)
            let pdfDPI = dpi ?? pdfDPIForEncoder(encoder)
            if let result = try? await runPDFPipeline(
                pdf, actions: [.optimise], id: renderTargetID,
                allowLarger: false,
                hideFloatingResult: hide,
                aggressiveOptimisation: aggressive ? true : nil,
                dpiOverride: pdfDPI,
                source: source
            ) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
                retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for PDF \(inputFile.string)")
                if location != "inPlace" {
                    currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                }
            }
        case .audio:
            let audio = Audio(inputFile)
            if let result = try? await runAudioPipeline(
                audio, actions: [.optimise], id: renderTargetID,
                hideFloatingResult: hide,
                source: source
            ) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
                retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for audio \(inputFile.string)")
                if location != "inPlace" {
                    currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                }
            }
        }
    }

    func handleExtractPagesAsImages(format: String, quality: String, location: String) async {
        guard fileType == .pdf else { return }

        let pdf = PDF(currentFile)
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return }

        let ext = format == "png" ? "png" : "jpg"
        let bitmapFormat: NSBitmapImageRep.FileType = format == "png" ? .png : .jpeg
        let scale: CGFloat = switch quality {
        case "low": 1.0
        case "high": 3.0
        default: 2.0
        }

        let stem = currentFile.lastComponent?.stem ?? "page"
        let outputDir: FilePath = switch location {
        case "temporaryFolder": .images
        case "sameFolder": currentFile.removingLastComponent()
        default:
            if location.contains("/"), let fp = context.resolve(location).filePath {
                fp
            } else {
                currentFile.removingLastComponent()
            }
        }
        try? fm.createDirectory(atPath: outputDir.string, withIntermediateDirectories: true)

        // Phase 1: Extract pages as images
        optimiser.running = true
        optimiser.operation = "Extracting pages"
        optimiser.progress = Progress(totalUnitCount: Int64(pageCount))

        let batchSize = ProcessInfo.processInfo.activeProcessorCount

        let extractedPaths: [FilePath] = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var paths: [FilePath] = []
                let pathsLock = NSLock()

                for batchStart in stride(from: 0, to: pageCount, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, pageCount)
                    let group = DispatchGroup()
                    for i in batchStart ..< batchEnd {
                        group.enter()
                        DispatchQueue.global().async {
                            defer {
                                mainActor { self.optimiser.progress.completedUnitCount += 1 }
                                group.leave()
                            }

                            guard let imageData = pdf.renderPage(pageIndex: i, format: bitmapFormat, scale: scale) else { return }

                            let filename = "\(stem)-page\(i + 1).\(ext)"
                            let outputPath = outputDir.appending(filename)
                            fm.createFile(atPath: outputPath.string, contents: imageData)

                            pathsLock.lock()
                            paths.append(outputPath)
                            pathsLock.unlock()
                        }
                    }
                    group.wait()
                }

                paths.sort { $0.string < $1.string }
                continuation.resume(returning: paths)
            }
        }

        // Phase 2: Optimise extracted images
        optimiser.operation = "Optimising images"
        optimiser.progress = Progress(totalUnitCount: Int64(extractedPaths.count))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for batchStart in stride(from: 0, to: extractedPaths.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, extractedPaths.count)
                    let group = DispatchGroup()
                    for i in batchStart ..< batchEnd {
                        let outputPath = extractedPaths[i]
                        group.enter()
                        DispatchQueue.global().async {
                            defer {
                                mainActor { self.optimiser.progress.completedUnitCount += 1 }
                                group.leave()
                            }

                            if let img = Image(path: outputPath, retinaDownscaled: false) {
                                let optimised = try? img.optimise(optimiser: self.optimiser, allowLarger: true, aggressiveOptimisation: img.type.aggressiveOptimisation, adaptiveSize: false)
                                if let optimised {
                                    try? optimised.path.copy(to: outputPath, force: true)
                                }
                            }
                        }
                    }
                    group.wait()
                }
                continuation.resume()
            }
        }

        optimiser.running = false
        optimiser.outputFolderURL = outputDir.url

        if pageCount == 1 {
            let firstPage = outputDir.appending("\(stem)-page1.\(ext)")
            if firstPage.exists {
                currentFile = firstPage
            }
        }
    }

    // MARK: - Target Size

    /// Compress the file until it fits under `bytes`, using type-appropriate strategies:
    /// images get aggressive optimisation then iterative downscaling, videos a computed
    /// bitrate (with one retry on overshoot), PDFs walk down the DPI stops, and audio
    /// gets a bitrate computed from the duration.
    func handleTargetSize(bytes: Int, location: String) async {
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        guard let startSize = inputFile.fileSize(), startSize > bytes else {
            log.debug("Pipeline: targetSize skipped, file already under \(bytes) bytes")
            if location != "inPlace" {
                currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
            }
            if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
            return
        }

        let result: FilePath? = switch fileType {
        case .image: await targetSizeImage(bytes: bytes, inputFile: inputFile)
        case .video: await targetSizeVideo(bytes: bytes, inputFile: inputFile)
        case .pdf: await targetSizePDF(bytes: bytes, inputFile: inputFile)
        case .audio: await targetSizeAudio(bytes: bytes, inputFile: inputFile)
        }

        guard let result else {
            log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for \(self.fileType.rawValue) \(inputFile.string)")
            return
        }
        if let finalSize = result.fileSize(), finalSize > bytes {
            log.warning("Pipeline: targetSize got \(inputFile.string) down to \(finalSize) bytes, above the \(bytes) target")
        }
        currentFile = applyLocation(location, to: result, original: currentFile, context: context)
        if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
        if !hide { shownVisibleResult = true }
        retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
    }

    // MARK: - Metadata & Overlay Steps

    func handleStripExif() async {
        guard fileType == .image || fileType == .video else {
            log.debug("Pipeline: stripExif not applicable for \(self.fileType)")
            return
        }
        let input = currentFile
        let hadOptimisationStatus = input.hasOptimisationStatusXattr()
        optimiser.running = true
        optimiser.operation = "Stripping metadata"

        let stripped: FilePath? = await Task.detached {
            let tempFile = FilePath.images.appending("exif-\(UUID().uuidString.prefix(8))-\(input.lastComponent?.string ?? "file")")
            try? fm.removeItem(atPath: tempFile.string)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            proc.arguments = [EXIFTOOL.string, "-XResolution=72", "-YResolution=72"]
                + ["-all=", "-tagsFromFile", "@"]
                + ["-XResolution", "-YResolution", "-Orientation"]
                + ["-o", tempFile.string, input.string]
            proc.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            proc.standardError = errPipe
            do { try proc.run() } catch { return nil }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, tempFile.exists, (tempFile.fileSize() ?? 0) > 0 else {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log.error("Pipeline: stripExif failed for \(input.string): \(err)")
                return nil
            }
            return tempFile
        }.value

        optimiser.running = false
        guard let stripped, let replaced = try? stripped.move(to: input, force: true) else {
            log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for \(input.string)")
            return
        }
        if hadOptimisationStatus {
            try? replaced.setOptimisationStatusXattr("true")
        }
        currentFile = replaced
    }

    func handleWatermark(image: String, position: String, opacity: Double, scale: Double, location: String) async {
        guard fileType == .image || fileType == .video else {
            log.debug("Pipeline: watermark not applicable for \(self.fileType)")
            return
        }
        let wmTemplate = context.resolve(image)
        guard let wm = wmTemplate.existingFilePath else {
            optimiser.finish(error: "Watermark image not found: \(wmTemplate)")
            shouldStop = true
            return
        }

        let input = currentFile

        // Still images are watermarked natively (Core Graphics) to preserve quality and file
        // size. Videos use ffmpeg; animated GIFs also use ffmpeg so every frame is overlaid
        // rather than flattened to a single frame.
        if fileType == .image {
            guard let base = Image(path: input, retinaDownscaled: false) else {
                optimiser.finish(error: "Can't read image for watermarking")
                shouldStop = true
                return
            }

            if base.type == .gif {
                await watermarkWithFFmpeg(input: input, wm: wm, baseWidth: Int(base.size.width), position: position, opacity: opacity, scale: scale, location: location, isVideo: false)
                return
            }

            optimiser.running = true
            optimiser.operation = "Watermarking"
            let resultPath: FilePath? = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        let result = try base.watermarked(watermark: wm, position: position, opacity: opacity, scale: scale, optimiser: self.optimiser)
                        continuation.resume(returning: result.path)
                    } catch {
                        log.error("Pipeline: native watermark failed for \(input.string): \(String(describing: error))")
                        continuation.resume(returning: nil)
                    }
                }
            }
            optimiser.running = false

            guard let resultPath else {
                optimiser.finish(error: "Watermarking failed")
                shouldStop = true
                return
            }
            // Name the result like the input so applyLocation(inPlace) replaces the original
            let named = (try? resultPath.move(to: resultPath.dir.appending(input.lastComponent?.string ?? resultPath.name.string), force: true)) ?? resultPath
            currentFile = applyLocation(location, to: named, original: currentFile, context: context)
            if !hide { shownVisibleResult = true }
            return
        }

        // Video
        guard let baseWidth = await (try? Video.byFetchingMetadata(path: input))?.size.map({ Int($0.width) }), baseWidth > 0 else {
            optimiser.finish(error: "Can't read dimensions for watermarking")
            shouldStop = true
            return
        }
        await watermarkWithFFmpeg(input: input, wm: wm, baseWidth: baseWidth, position: position, opacity: opacity, scale: scale, location: location, isVideo: true)
    }

    func handleCapFps(fps: Int) async {
        guard fileType == .video else {
            log.debug("Pipeline: capFps not applicable for \(self.fileType)")
            return
        }
        let vid = Video(currentFile)
        if let result = try? await runVideoPipeline(
            vid, actions: [.optimise], id: renderTargetID,
            allowLarger: true, hideFloatingResult: hide,
            source: source, fpsOverride: fps
        ) {
            currentFile = result.path
            if !hide { shownVisibleResult = true }
        } else {
            log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(self.currentFile.string)")
        }
    }

    func handleNormalize(lufs: Double) async {
        guard fileType == .audio else {
            log.debug("Pipeline: normalize not applicable for \(self.fileType)")
            return
        }
        let audio = await (try? Audio.byFetchingMetadata(path: currentFile, thumb: !hide)) ?? Audio(path: currentFile, thumb: !hide)
        if let result = try? await runAudioPipeline(
            audio, actions: [.optimise], id: renderTargetID,
            allowLarger: true, hideFloatingResult: hide,
            source: source, loudnormTarget: lufs
        ) {
            currentFile = applyLocation("inPlace", to: result.path, original: currentFile, context: context)
            if !hide { shownVisibleResult = true }
        } else {
            log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for audio \(self.currentFile.string)")
        }
    }

    func handleDownscale(factor: Double, location: String) async {
        let action = PipelineAction.downscale(factor: factor, cropSize: nil)
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        switch fileType {
        case .image:
            if let data = try? Data(contentsOf: inputFile.url) {
                let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                if let result = try? await runImagePipeline(
                    img,
                    actions: [action],
                    id: encodeID(forLocation: location),
                    saveTo: clipboardSaveTo,
                    copyToClipboard: copyResultToClipboard,
                    allowLarger: true,
                    hideFloatingResult: hide,
                    source: source
                ) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                } else {
                    log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for image \(inputFile.string)")
                }
            }
        case .video:
            let vid = Video(inputFile)
            if let result = try? await runVideoPipeline(vid, actions: [action], id: renderTargetID, allowLarger: true, hideFloatingResult: hide, source: source) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(inputFile.string)")
            }
        case .audio:
            await runAudioBitrateStep(inputFile: inputFile, location: location, usedTempCopy: usedTempCopy) { audio in
                audio.loweredBitrate(factor: factor)
            }
        default:
            log.debug("Pipeline: downscale not applicable for \(self.fileType)")
        }
    }

    func handleLowerBitrate(kbps: Int, location: String) async {
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        switch fileType {
        case .audio:
            await runAudioBitrateStep(inputFile: inputFile, location: location, usedTempCopy: usedTempCopy) { audio in
                audio.loweredBitrate(kbps: kbps)
            }
        default:
            log.debug("Pipeline: lowerBitrate not applicable for \(self.fileType)")
        }
    }

    func handleConvert(formatStr: String, location: String) async {
        // When the step carries no explicit location (DSL default is "sameFolder"),
        // honour the manual-conversion behaviour set by the user (e.g. --convert-behaviour inplace).
        // An explicit non-default location in the DSL (e.g. "temporaryFolder" or a path template)
        // is preserved as-is; only the default "sameFolder" is eligible for override.
        let effectiveLocation: String
        if location == "sameFolder" {
            let behaviour = optimiser.placementOverride?.manualConvert ?? fileType.behaviour(for: .manualConvert)
            if let behaviour {
                switch behaviour {
                case .inPlace:
                    effectiveLocation = "inPlace"
                case .sameFolder:
                    effectiveLocation = "sameFolder"
                case .temporary:
                    effectiveLocation = "temporaryFolder"
                case .specificFolder:
                    if let key = fileType.specificFolderTemplateKey(for: .manualConvert) {
                        effectiveLocation = optimiser.placementOverride?.specificFolderTemplate ?? Defaults[key]
                    } else {
                        effectiveLocation = location
                    }
                }
            } else {
                effectiveLocation = location
            }
        } else {
            effectiveLocation = location
        }
        let inputFile = tempCopyIfNeeded(currentFile, location: effectiveLocation)
        let usedTempCopy = inputFile != currentFile

        // GIF conversion uses gifski, not ffmpeg, so it has its own path.
        if formatStr == "gif", fileType == .video {
            let vid = await (try? Video.byFetchingMetadata(path: inputFile)) ?? Video(inputFile)
            let optimiser = optimiser
            let gif: Image? = await withCheckedContinuation { continuation in
                videoOptimisationQueue.addOperation {
                    continuation.resume(returning: try? vid.convertToGIF(optimiser: optimiser, maxWidth: 960, fps: 15))
                }
            }
            if let gif {
                currentFile = applyLocation(effectiveLocation, to: gif.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video GIF conversion \(inputFile.string)")
            }
            return
        }

        // Video codec targets (not file extensions) need special handling. Pipelines are
        // deterministic automation, so they always use the legacy default quality (cq: nil);
        // the per-result slider override applies only to interactive re-encodes.
        let videoCodecArgs: (encoder: [String], ext: String)? = videoConversionArgs(format: formatStr, cq: nil)
            .map { (encoder: $0.args, ext: $0.outputExt) }

        if let videoCodecArgs, fileType == .video {
            let vid = Video(inputFile)
            let forceMP4 = videoCodecArgs.ext == "mp4"
            let outExt: String? = forceMP4 ? nil : videoCodecArgs.ext
            let optimiserRef = optimiser
            let encoderArgs = videoCodecArgs.encoder
            let converted = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Video, Error>) in
                videoOptimisationQueue.addOperation {
                    do {
                        try cont.resume(returning: vid.optimise(
                            optimiser: optimiserRef, forceMP4: forceMP4, outputExtension: outExt, backup: false,
                            encoderOverride: encoderArgs
                        ))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            if let result = converted {
                // Mirror runVideoPipeline's finalization: reflect the new codec in `type` and clear
                // the ingest detection — it describes the CURRENT file, which was just re-encoded.
                if let codec = encoderArgs.codecUTType {
                    // Record provenance the way the direct convert path does (`convertedFromURL` gates
                    // `stickyConversionFormat`) so a later slider re-run keeps the conversion: the
                    // step's input file is the pre-conversion source.
                    if optimiser.convertedFromURL == nil {
                        optimiser.convertedFromURL = optimiser.url ?? inputFile.url
                    }
                    optimiser.type = .video(codec)
                }
                optimiser.detectedVideoCodec = nil
                currentFile = applyLocation(effectiveLocation, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video codec conversion \(inputFile.string)")
            }
        } else if let uttype = UTType(filenameExtension: formatStr) {
            let action = PipelineAction.convert(format: uttype)
            switch fileType {
            case .image:
                if let data = try? Data(contentsOf: inputFile.url) {
                    let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                    if let result = try? await runImagePipeline(
                        img,
                        actions: [action],
                        id: encodeID(forLocation: effectiveLocation),
                        saveTo: clipboardSaveTo,
                        copyToClipboard: copyResultToClipboard,
                        allowLarger: true,
                        hideFloatingResult: hide,
                        source: source,
                        compression: optimiser.compressionOverride
                    ) {
                        currentFile = applyLocation(effectiveLocation, to: result.path, original: currentFile, context: context)
                        if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                        if !hide { shownVisibleResult = true }
                    } else {
                        log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for image conversion \(inputFile.string)")
                    }
                }
            case .video:
                let vid = Video(inputFile)
                if let result = try? await runVideoPipeline(vid, actions: [action], id: renderTargetID, allowLarger: true, hideFloatingResult: hide, source: source, compression: optimiser.compressionOverride) {
                    currentFile = applyLocation(effectiveLocation, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                } else {
                    log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video conversion \(inputFile.string)")
                }
            case .audio:
                guard let format = AudioFormat.from(conversionTarget: formatStr) else {
                    log.warning("Pipeline: unknown audio format '\(formatStr)' for convert step")
                    return
                }
                let audio = await (try? Audio.byFetchingMetadata(path: inputFile, thumb: !hide)) ?? Audio(path: inputFile, thumb: !hide)
                if let result = try? await runAudioPipeline(
                    audio, actions: [action], id: renderTargetID,
                    allowLarger: true, hideFloatingResult: hide,
                    source: source, bitrateOverride: optimiser.audioBitrateOverride,
                    formatOverride: format, compression: optimiser.compressionOverride
                ) {
                    currentFile = applyLocation(effectiveLocation, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                } else {
                    log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for audio conversion \(inputFile.string)")
                }
            default:
                log.debug("Pipeline: convert not applicable for \(self.fileType)")
            }
        } else {
            log.debug("Pipeline: unknown format '\(formatStr)' for convert step")
        }
    }

    func handleCrop(width: Int?, height: Int?, longEdge: Int?, location: String) async {
        let useLongEdge = longEdge != nil
        let targetW = useLongEdge ? (longEdge ?? 0).d : (width ?? 0).d
        let targetH = useLongEdge ? (longEdge ?? 0).d : (height ?? 0).d
        let cs = CropSize(width: targetW, height: targetH, longEdge: useLongEdge)
        let action = PipelineAction.downscale(factor: nil, cropSize: cs)
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

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
                if needsCrop, let result = try? await runImagePipeline(
                    img,
                    actions: [action],
                    id: encodeID(forLocation: location),
                    saveTo: clipboardSaveTo,
                    copyToClipboard: copyResultToClipboard,
                    allowLarger: false,
                    hideFloatingResult: hide,
                    source: source
                ) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                } else {
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
            if needsCrop, let result = try? await runVideoPipeline(vid, actions: [action], id: renderTargetID, allowLarger: false, hideFloatingResult: hide, source: source) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
            } else {
                if location != "inPlace" {
                    currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                } else {
                    log.debug("Pipeline: crop skipped, video \(vidSize.width.i)x\(vidSize.height.i) already within target")
                }
            }
        default:
            log.debug("Pipeline: crop not applicable for \(self.fileType)")
        }
    }

    func handleCopy(to: String) throws {
        if let dest = resolveFileDestination(to) {
            let copied = try currentFile.copy(to: dest, force: true)
            currentFile = copied
        }
    }

    func handleMove(to: String) throws {
        if let dest = resolveFileDestination(to) {
            let pointsAtCurrent = optimiser.path == currentFile
            let moved = try currentFile.move(to: dest, force: true)
            currentFile = moved
            if pointsAtCurrent {
                optimiser.url = moved.url
            }
        }
    }

    func handleRename(to: String) throws {
        var newName = context.resolve(to)
        // Re-add the extension when the template resolves without one (e.g. "%y-%m-%d_%f")
        let lastPart = newName.split(separator: "/").last.map(String.init) ?? newName
        if !lastPart.contains("."), let ext = currentFile.extension, !ext.isEmpty {
            newName += ".\(ext)"
        }
        let dest = currentFile.removingLastComponent().appending(newName)
        let pointsAtCurrent = optimiser.path == currentFile
        let moved = try currentFile.move(to: dest, force: true)
        currentFile = moved
        if pointsAtCurrent {
            optimiser.url = moved.url
        }
    }

    func handleDelete(path: String) async {
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
                guard shouldDelete else { return }
            }
            try? fm.trashItem(at: filePath.url, resultingItemURL: nil)
        }
    }

    // MARK: - Filter Steps

    func handleFilterIf(condition: FilterCondition) {
        let (matches, captures) = condition.evaluate(file: currentFile, context: context, sourceAppBundleID: optimiser.copiedFromAppBundleID, sourceAppName: optimiser.copiedFromAppName)
        if !matches {
            log.debug("Pipeline: filter condition not met, stopping pipeline for \(self.currentFile.string)")
            shouldStop = true
            return
        }
        if !captures.isEmpty { context.regexCaptures = captures }
    }

    func handleFilterIfNot(condition: FilterCondition) {
        let (matches, _) = condition.evaluate(file: currentFile, context: context, sourceAppBundleID: optimiser.copiedFromAppBundleID, sourceAppName: optimiser.copiedFromAppName)
        if matches {
            log.debug("Pipeline: exclusion filter matched, stopping pipeline for \(self.currentFile.string)")
            shouldStop = true
        }
    }

    // MARK: - Media-specific Steps

    func handleRemoveAudio() async {
        if fileType == .video {
            let vid = Video(currentFile)
            if let result = try? await runVideoPipeline(vid, actions: [.removeAudio], id: renderTargetID, allowLarger: true, hideFloatingResult: hide, source: source) {
                currentFile = result.path
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(self.currentFile.string)")
            }
        }
    }

    func handleChangeSpeed(factor: Double) async throws {
        switch fileType {
        case .video:
            let vid = Video(currentFile)
            if let result = try? await runVideoPipeline(vid, actions: [.changePlaybackSpeed(factor: factor)], id: renderTargetID, allowLarger: true, hideFloatingResult: hide, source: source) {
                currentFile = result.path
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(self.currentFile.string)")
            }
        case .audio:
            let audio = Audio(currentFile)
            let changed = try audio.changeSpeed(factor: factor, optimiser: optimiser)
            // The result lands in the temp audio folder: replace the original in place,
            // matching how video speed changes behave.
            if changed.path != currentFile, changed.path.dir == FilePath.audios,
               let moved = try? changed.path.move(to: currentFile, force: true)
            {
                currentFile = moved
            } else {
                currentFile = changed.path
            }
        default:
            log.debug("Pipeline: changeSpeed not applicable for \(self.fileType)")
        }
    }

    // MARK: - Generic Action Steps

    func handleRunScript(path: String?, code: String?) async {
        let inputPath = currentFile.string

        // Inline code is run literally via `zsh -c` so the script's own `$1` stays the input
        // file (don't resolve % tokens / $1 captures into it). A path is resolved as before:
        // run directly if executable, otherwise as a script file via zsh.
        let inlineCode = (code?.isEmpty == false) ? code : nil
        let resolvedPath = inlineCode == nil ? context.resolve(path ?? "") : ""
        let scriptName = inlineCode != nil ? "inline code" : (FilePath(resolvedPath).stem ?? resolvedPath)
        log.debug("Pipeline: running script '\(scriptName)' with input \(inputPath)")

        let currentFile = currentFile
        let fileType = fileType
        let scriptResult: (newPath: FilePath?, error: String?) = await Task.detached {
            let task = Process()
            if let inlineCode {
                task.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // argv after the command string become $0, $1, …: pass the input file as $1.
                task.arguments = ["-c", inlineCode, "clop", inputPath]
            } else if fm.isExecutableFile(atPath: resolvedPath) {
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
                Script: \(scriptName) (\(inlineCode ?? resolvedPath))
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
            if !trimmedOutput.isEmpty, let outputPath = trimmedOutput.existingFilePath, outputPath != currentFile {
                // Only adopt the script's output path as the new working file if it is the
                // same media kind we're processing; a non-media stdout path would poison
                // currentFile for later steps (mirrors handleRunShortcut's guard).
                let outputType = UTType.from(filePath: outputPath)?.fileType
                if outputType == nil || outputType == fileType {
                    return (outputPath, nil)
                }
                log.warning("Pipeline: script '\(scriptName)' output path is \(String(describing: outputType)) but expected \(fileType), ignoring")
            }
            return (currentFile, nil)
        }.value

        if let error = scriptResult.error {
            let parts = error.split(separator: "|", maxSplits: 1)
            let errorMessage = String(parts[0])
            log.error("Pipeline: \(errorMessage)")
            optimiser.finish(error: errorMessage)
            // Don't pop the error log in an editor for hidden runs (automations, CLI)
            if !hide, parts.count > 1, let logFile = String(parts[1]).existingFilePath {
                NSWorkspace.shared.open(logFile.url)
            }
            shouldStop = true
            return
        }
        if let newPath = scriptResult.newPath, newPath != self.currentFile {
            self.currentFile = newPath
        }
    }

    func handleRunShortcut(shortcut: Shortcut) async {
        let tempDir: FilePath = switch fileType {
        case .image: .images
        case .video: .videos
        case .pdf: .pdfs
        case .audio: .audios
        }
        let shortcutOutFile = tempDir.appending("\(Date.now.timeIntervalSinceReferenceDate.i)-shortcut-output-for-\(currentFile.stem ?? "file")")

        guard let proc = optimiser.runShortcut(shortcut, outFile: shortcutOutFile, url: currentFile.url) else {
            return
        }

        let currentFile = currentFile
        let fileType = fileType
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
                if outputPath != currentFile {
                    let outputType = UTType.from(filePath: outputPath)?.fileType
                    if outputType == nil || outputType == fileType {
                        return (outputPath, nil)
                    } else {
                        log.warning("Pipeline: shortcut '\(shortcut.name)' output path is \(outputType!) but expected \(fileType), ignoring")
                    }
                }
            } else {
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
            shouldStop = true
            return
        }
        if let newPath = shortcutResult.newPath {
            let oldBytes = self.currentFile.fileSize() ?? 0
            self.currentFile = newPath
            optimiser.url = self.currentFile.url
            optimiser.finish(oldBytes: oldBytes, newBytes: self.currentFile.fileSize() ?? 0)
        }
    }

    // MARK: - Clipboard Steps

    func handleCopyToClipboard(format: ClipboardCopyFormat, relativeTo: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        switch format {
        case .path:
            if let relativeTo {
                let base = context.resolve(relativeTo)
                item.setString(currentFile.string.replacingOccurrences(of: base, with: ""), forType: .string)
            } else {
                item.setString(currentFile.string, forType: .string)
            }
        case .imageData:
            if fileType == .image, let data = try? Data(contentsOf: currentFile.url),
               let type = UTType(filenameExtension: currentFile.extension ?? "png")
            {
                item.setData(data, forType: type.pasteboardType)
            } else {
                item.setString(currentFile.string, forType: .string)
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
            item.setString("[\(name)](\(path))", forType: .string)
        }
        item.setString("true", forType: .optimisationStatus)
        pasteboard.writeObjects([item])
        try? currentFile.setOptimisationStatusXattr("true")
    }

    func handleCopyLinkForSending(expiration: TimeInterval? = nil) async {
        let url = currentFile.url
        if let shareURL = await warpDropSendAndWait(url: url, optimiser: optimiser, expiration: expiration) {
            log.debug("Pipeline: send link copied: \(shareURL)")
        }
    }

    // MARK: - Fork

    /// Branch off the current result as a SECOND floating result card, then let the main line
    /// (card B) keep going into the one morphing card. `currentFile` is never changed, so the
    /// next step's input is preserved.
    ///
    /// - No `location`: the user only cares about the floating result, so card A's file lives in
    ///   temp. We avoid copying when we can: if no following step would overwrite/delete/move the
    ///   current file, card A just references it in place; only when a later step would clobber it
    ///   do we snapshot it to a stable temp path.
    /// - With `location`: card A's file is persisted there using the same rules as every other
    ///   step's `location` (sameFolder / template), without disturbing the main line.
    func handleFork(location: String?, followingSteps: [PipelineStep]) async {
        let sourceFile = currentFile
        guard isRenderableMediaFile(sourceFile) else {
            log.debug("Pipeline: fork skipped, current file not renderable: \(sourceFile.string)")
            return
        }

        let cardAFile: FilePath
        if let location, location != "temporaryFolder", location != "inPlace" {
            // Persist a copy at the requested location, leaving the main-line file untouched.
            let tempCopy = (try? sourceFile.copy(to: forkTempPath(for: sourceFile), force: true)) ?? sourceFile
            cardAFile = applyLocation(location, to: tempCopy, original: originalFile, context: context)
        } else if forkNeedsCopy(after: followingSteps) {
            // A later in-place / delete / move / rename step would clobber the current file, so
            // snapshot it now to a stable temp path (no "pipeline-" prefix → survives cleanup).
            cardAFile = (try? sourceFile.copy(to: forkTempPath(for: sourceFile), force: true)) ?? sourceFile
        } else {
            // Nothing downstream touches this file: card A can point at it directly, no copy.
            cardAFile = sourceFile
        }

        spawnForkedResult(file: cardAFile)
        log.debug("Pipeline: forked card from \(sourceFile.string) to \(cardAFile.string)")
    }

    // MARK: - App Integration Steps

    func handleShelveWith(app: String) async throws {
        let shelfApp: AppIntegration? = switch app.lowercased() {
        case "yoink": YOINK
        case "dockside": DOCKSIDE
        case "dropover": DROPOVER
        case "atoll": ATOLL
        default: nil
        }
        if let shelfApp {
            shelfApp.fetchAppURL()
            let available = shelfApp.waitToBeAvailable(for: 5.0)
            if available {
                try await shelfApp.open(currentFile)
            } else {
                log.warning("Pipeline: shelveWith(\(app)) - app not available")
                optimiser.finish(error: "\(shelfApp.appName) is not available")
                shouldStop = true
            }
        } else {
            log.warning("Pipeline: shelveWith - unknown app '\(app)'")
        }
    }

    func handleUploadWith(app: String) async throws {
        let uploadApp: AppIntegration? = switch app.lowercased() {
        case "dropshare": DROPSHARE
        default: nil
        }
        if let uploadApp {
            uploadApp.fetchAppURL()
            let available = uploadApp.waitToBeAvailable(for: 5.0)
            if available {
                try await uploadApp.open(currentFile)
            } else {
                log.warning("Pipeline: uploadWith(\(app)) - app not available")
                optimiser.finish(error: "\(uploadApp.appName) is not available")
                shouldStop = true
            }
        } else {
            log.warning("Pipeline: uploadWith - unknown app '\(app)'")
        }
    }

    func handleOpenWith(app: String) async throws {
        let appURL: URL? = {
            for base in ["/Applications", "\(NSHomeDirectory())/Applications"] {
                let direct = "\(base)/\(app).app"
                if FileManager.default.fileExists(atPath: direct) {
                    return URL(fileURLWithPath: direct)
                }
            }
            let candidates = NSWorkspace.shared.urlsForApplications(toOpen: currentFile.url)
            if let match = candidates.first(where: {
                Bundle(url: $0)?.name.localizedCaseInsensitiveCompare(app) == .orderedSame
            }) {
                return match
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        }()

        if let appURL {
            let config = NSWorkspace.OpenConfiguration()
            config.addsToRecentItems = false
            _ = try await NSWorkspace.shared.open([currentFile.url], withApplicationAt: appURL, configuration: config)
        } else {
            log.warning("Pipeline: openWith - app '\(app)' not found")
            optimiser.finish(error: "App '\(app)' not found")
            shouldStop = true
        }
    }

    private func forkTempPath(for file: FilePath) -> FilePath {
        URL.temporaryDirectory.appendingPathComponent("clop-fork-\(Int.random(in: 1000 ... 10_000_000))-\(file.name.string)").filePath!
    }

    /// Whether a step after the fork would overwrite/delete/move the current file, meaning card A
    /// must snapshot it to survive.
    private func forkNeedsCopy(after followingSteps: [PipelineStep]) -> Bool {
        for step in followingSteps {
            switch step {
            case .delete, .move, .rename:
                return true
            case .optimise, .downscale, .lowerBitrate, .crop, .targetSize, .stripExif, .watermark,
                 .capFps, .normalize, .removeAudio, .changeSpeed:
                if (step.location ?? "inPlace") == "inPlace" { return true }
            case .convert:
                if (step.location ?? "sameFolder") == "inPlace" { return true }
            default:
                break
            }
        }
        return false
    }

    /// Create a finished, draggable result card seeded from the main line's current renderable
    /// snapshot (thumbnail + size/resolution/bitrate/DPI deltas), so it shows the result-so-far.
    private func spawnForkedResult(file: FilePath) {
        let forkID = "\(renderTargetID)-fork-\(Int.random(in: 1000 ... 10_000_000))"
        let cardA = OM.optimiser(id: forkID, type: .from(filePath: file), operation: "Forked", hidden: forceHide, source: source)
        cardA.url = file.url
        // Override whatever url.didSet refetched with the parent's current snapshot so both cards
        // match at the fork point.
        if let thumb = optimiser.thumbnail { cardA.thumbnail = thumb }
        cardA.oldDPI = optimiser.oldDPI
        cardA.newDPI = optimiser.newDPI
        let newBytes = optimiser.newBytes > 0 ? optimiser.newBytes : (file.fileSize() ?? optimiser.oldBytes)
        cardA.finish(
            oldBytes: optimiser.oldBytes,
            newBytes: newBytes,
            oldSize: optimiser.oldSize,
            newSize: optimiser.newSize,
            oldBitrate: optimiser.oldBitrate,
            newBitrate: optimiser.newBitrate
        )
    }

    private func targetSizeImage(bytes: Int, inputFile: FilePath) async -> FilePath? {
        guard let data = try? Data(contentsOf: inputFile.url) else { return nil }
        var img = Image(data: data, path: inputFile, optimised: false, retinaDownscaled: false)

        if let optimised = try? await runImagePipeline(
            img, actions: [.optimise],
            allowLarger: false, hideFloatingResult: true,
            aggressiveOptimisation: true, source: source
        ) {
            img = optimised
        }

        // Probe higher compression factors before touching the resolution: pipelines re-encode
        // from the original backup, so a probe never compounds compression artifacts. The factor
        // step is sized to the overshoot; at 80+ this also unlocks GIF frame dropping and the
        // extreme JPEG/PNG ramps.
        var factor = COMPRESSION_FACTOR_AGGRESSIVE
        for _ in 0 ..< 2 {
            guard let size = img.path.fileSize(), size > bytes, factor < 100 else { break }
            let overshoot = Double(size) / Double(bytes)
            factor = overshoot > 3 ? 100 : min(100, factor + (overshoot > 1.5 ? 30 : 18))
            guard let imgData = try? Data(contentsOf: img.path.url) else { break }
            let fresh = Image(data: imgData, path: img.path, optimised: false, retinaDownscaled: false)
            guard let smaller = try? await runImagePipeline(
                fresh, actions: [.optimise],
                allowLarger: true, hideFloatingResult: true,
                source: source, skipCache: true,
                compression: CompressionQuality(tier: .custom, factor: factor)
            ) else { break }
            img = smaller
        }

        // Still too big at factor 100: resort to downscaling, keeping maximum compression.
        var attempts = 0
        while let size = img.path.fileSize(), size > bytes, attempts < 5 {
            let scale = max(0.2, (Double(bytes) / Double(size)).squareRoot() * 0.92)
            guard let imgData = try? Data(contentsOf: img.path.url) else { break }
            let fresh = Image(data: imgData, path: img.path, optimised: false, retinaDownscaled: false)
            guard let smaller = try? await runImagePipeline(
                fresh, actions: [.downscale(factor: scale, cropSize: nil)],
                allowLarger: true, hideFloatingResult: true,
                source: source, skipCache: true,
                compression: CompressionQuality(tier: .custom, factor: 100)
            ) else { break }
            img = smaller
            attempts += 1
        }
        return img.path
    }

    private func targetSizeVideo(bytes: Int, inputFile: FilePath) async -> FilePath? {
        let vid = await (try? Video.byFetchingMetadata(path: inputFile)) ?? Video(inputFile)
        guard let duration = vid.duration, duration > 0 else {
            // No duration metadata: best effort with aggressive optimisation
            return await (try? runVideoPipeline(vid, actions: [.optimise], allowLarger: true, hideFloatingResult: true, aggressiveOptimisation: true, source: source))?.path
        }

        func encode(toFit target: Int) async -> FilePath? {
            // 7% container overhead margin, 128 kbps reserved for audio.
            // libx264 ABR with a tight maxrate: hardware encoders ignore very low
            // bitrate targets, software x264 actually honours them.
            let totalKbps = Double(target) * 8.0 * 0.93 / duration / 1000.0
            let videoKbps = max(40.0, totalKbps - 128.0)
            var encoderArgs = [
                "-vcodec", "libx264",
                "-preset", "fast",
                "-b:v", "\(Int(videoKbps))k",
                "-maxrate", "\(Int(videoKbps * 1.2))k",
                "-bufsize", "\(Int(videoKbps * 2))k",
            ]

            // When the bitrate would starve the pixel rate (bits-per-pixel too low), cap the frame
            // rate at 30 and then downscale so the remaining bits go further: fewer, better pixels
            // beat a full-resolution mush of encoder artifacts.
            var actions: [PipelineAction] = [.optimise]
            if let size = vid.size, size.width > 0, size.height > 0 {
                let minBPP = 0.04
                let fps = Double(vid.fps ?? 30)
                var bpp = videoKbps * 1000.0 / (Double(size.width) * Double(size.height) * max(fps, 1))
                if bpp < minBPP, fps > 30 {
                    encoderArgs += ["-r", "30"]
                    bpp *= fps / 30.0
                }
                if bpp < minBPP {
                    let scale = max(0.25, (bpp / minBPP).squareRoot())
                    actions = [.downscale(factor: scale, cropSize: nil)]
                }
            }
            return await (try? runVideoPipeline(
                vid, actions: actions,
                allowLarger: true, hideFloatingResult: true,
                ffmpegEncoderOverride: encoderArgs, source: source
            ))?.path
        }

        guard var result = await encode(toFit: bytes) else { return nil }
        // One retry on VBV overshoot, aiming proportionally lower
        if let actual = result.fileSize(), actual > bytes {
            let correctedTarget = Int(Double(bytes) * Double(bytes) / Double(actual) * 0.95)
            if let retried = await encode(toFit: correctedTarget) {
                result = retried
            }
        }
        return result
    }

    private func targetSizePDF(bytes: Int, inputFile: FilePath) async -> FilePath? {
        // Bisect the DPI stops (250 down to 48) for the highest quality that fits, instead of
        // walking every stop: at most 3 Ghostscript passes plus one re-run of the winning stop.
        let stops = Array(PDF_DPI_STOPS.sorted(by: >).dropFirst())

        func encode(at stop: Int) async -> FilePath? {
            let pdf = PDF(inputFile)
            let optimised = try? await runPDFPipeline(
                pdf, actions: [.optimise],
                allowLarger: true, hideFloatingResult: true,
                aggressiveOptimisation: true, dpiOverride: stop, source: source
            )
            return optimised?.path
        }

        var lo = 0
        var hi = stops.count - 1
        var chosen: Int?
        var lastEncoded: Int?
        var result: FilePath?
        while lo <= hi {
            let mid = (lo + hi) / 2
            guard let path = await encode(at: stops[mid]) else {
                lo = mid + 1
                continue
            }
            result = path
            lastEncoded = stops[mid]
            if let size = path.fileSize(), size <= bytes {
                chosen = stops[mid]
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        // The last gs pass may have been a higher-DPI probe that overshot; re-encode the winner.
        if let chosen, chosen != lastEncoded, let path = await encode(at: chosen) {
            result = path
        }
        return result
    }

    private func targetSizeAudio(bytes: Int, inputFile: FilePath) async -> FilePath? {
        let audio = await (try? Audio.byFetchingMetadata(path: inputFile, thumb: false)) ?? Audio(path: inputFile, thumb: false)
        guard let duration = audio.duration, duration > 0 else { return nil }

        let kbps = Int(Double(bytes) * 8.0 * 0.95 / duration / 1000.0)
        let clamped = audio.loweredBitrate(kbps: kbps) ?? kbps
        return await (try? runAudioPipeline(
            audio, actions: [.optimise],
            allowLarger: true, hideFloatingResult: true,
            source: source, bitrateOverride: clamped
        ))?.path
    }

    /// ffmpeg-based watermarking, used for videos and animated GIFs (both need every frame
    /// overlaid). Still images go through `Image.watermarked` instead.
    private func watermarkWithFFmpeg(input: FilePath, wm: FilePath, baseWidth: Int, position: String, opacity: Double, scale: Double, location: String, isVideo: Bool) async {
        let targetWmWidth = max(16, Int(Double(baseWidth) * scale))
        let coords = switch position {
        case "topLeft": "20:20"
        case "topRight": "W-w-20:20"
        case "bottomLeft": "20:H-h-20"
        case "center": "(W-w)/2:(H-h)/2"
        default: "W-w-20:H-h-20"
        }
        let filter = "[1:v]scale=\(targetWmWidth):-1,format=rgba,colorchannelmixer=aa=\(opacity)[wm];[0:v][wm]overlay=\(coords)"

        let tempDir: FilePath = isVideo ? .videos : .images
        let output = tempDir.appending("wm-\(UUID().uuidString.prefix(8))-\(input.lastComponent?.string ?? "file")")
        var args = ["-y", "-i", input.string, "-i", wm.string, "-filter_complex", filter]
        if isVideo {
            args += ["-c:a", "copy"]
        }
        args.append(output.string)

        optimiser.running = true
        optimiser.operation = "Watermarking"
        let success: Bool = await Task.detached {
            let proc = Process()
            proc.executableURL = FFMPEG.url
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            proc.standardError = errPipe
            do { try proc.run() } catch { return false }
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log.error("Pipeline: watermark ffmpeg failed for \(input.string): \(err.suffix(500))")
            }
            return proc.terminationStatus == 0 && output.exists && (output.fileSize() ?? 0) > 0
        }.value
        optimiser.running = false

        guard success else {
            optimiser.finish(error: "Watermarking failed")
            shouldStop = true
            return
        }
        // Name the result like the input so applyLocation(inPlace) replaces the original
        let named = (try? output.move(to: output.dir.appending(input.lastComponent?.string ?? output.name.string), force: true)) ?? output
        currentFile = applyLocation(location, to: named, original: currentFile, context: context)
        if !hide { shownVisibleResult = true }
    }

    // MARK: - File Operation Steps

    /// Resolve a copy/move destination template into a concrete file path.
    ///
    /// - Templates ending in "/" (or resolving to an existing directory) are treated as
    ///   directories: they are created and the current filename is appended.
    /// - When the resolved name has no extension, the current file's extension is added
    ///   (template tokens like "%f" resolve without one).
    private func resolveFileDestination(_ to: String) -> FilePath? {
        var resolved = context.resolve(to)
        // Relative destinations (e.g. "copy-of-%f") are placed next to the current file
        if !resolved.hasPrefix("/"), !resolved.hasPrefix("~") {
            resolved = currentFile.dir.string + "/" + resolved
        }
        guard var dest = resolved.filePath else { return nil }

        if to.hasSuffix("/") || resolved.hasSuffix("/") || dest.isDir {
            try? fm.createDirectory(atPath: dest.string, withIntermediateDirectories: true)
            return dest.appending(currentFile.lastComponent?.string ?? currentFile.name.string)
        }

        try? fm.createDirectory(atPath: dest.removingLastComponent().string, withIntermediateDirectories: true)
        if let last = dest.lastComponent?.string, !last.contains("."),
           let ext = currentFile.extension, !ext.isEmpty
        {
            dest = dest.removingLastComponent().appending("\(last).\(ext)")
        }
        return dest
    }

    /// Shared path for audio bitrate reduction steps (downscale/lowerBitrate).
    /// Fetches metadata so the clamp helper can see the input bitrate, computes the
    /// target bitrate via `compute`, and runs the audio pipeline with that override.
    /// If `compute` returns nil (no-op lowering), the step is skipped without failing.
    private func runAudioBitrateStep(
        inputFile: FilePath,
        location: String,
        usedTempCopy: Bool,
        compute: (Audio) -> Int?
    ) async {
        let audio = await (try? Audio.byFetchingMetadata(path: inputFile, thumb: false)) ?? Audio(path: inputFile, thumb: false)
        guard let targetBitrate = compute(audio) else {
            log.debug("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) skipped, bitrate already at or below target for \(inputFile.string)")
            if location != "inPlace" {
                currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
            }
            if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
            return
        }

        if let result = try? await runAudioPipeline(
            audio, actions: [.optimise], id: renderTargetID,
            allowLarger: true, hideFloatingResult: hide,
            source: source, bitrateOverride: targetBitrate
        ) {
            currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
            if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
            if !hide { shownVisibleResult = true }
        } else {
            log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for audio \(inputFile.string)")
        }
    }

    private func runCompiledVideoBatch(batch: [PipelineStep], actions: [PipelineAction], inputFile: FilePath, location: String, aggressive: Bool) async -> Bool {
        let videoEncoderOvr: VideoEncoder? = batch.compactMap { s in
            if case let .optimise(_, _, ve, _, _) = s { return ve }; return nil
        }.last
        var ffmpegEncoder: [String]?
        var outExt: String?
        for s in batch {
            if case let .convert(fmt, _) = s {
                switch fmt {
                case "hevc": ffmpegEncoder = ["-vcodec", "hevc_videotoolbox", "-q:v", "40", "-tag:v", "hvc1"]; outExt = "mp4"
                case "x265": ffmpegEncoder = ["-vcodec", "libx265", "-crf", "28", "-tag:v", "hvc1", "-preset", "medium"]; outExt = "mp4"
                case "av1": ffmpegEncoder = ["-vcodec", "libsvtav1"]; outExt = "mkv"
                case "webm": ffmpegEncoder = ["-vcodec", "libvpx-vp9", "-crf", "32", "-b:v", "0"]; outExt = "webm"
                default: break
                }
            }
        }

        let vid = await (try? Video.byFetchingMetadata(path: inputFile)) ?? Video(inputFile)
        let vidSize = vid.size ?? .zero
        let filteredActions = actions.filter { action in
            guard case let .downscale(factor, cropSize) = action, factor == nil, let cropSize else { return true }
            if cropSize.longEdge {
                return cropSize.width > 0 && max(vidSize.width, vidSize.height) > cropSize.width.d
            }
            return (cropSize.width > 0 && vidSize.width > cropSize.width.d) || (cropSize.height > 0 && vidSize.height > cropSize.height.d)
        }

        guard let result = try? await runVideoPipeline(
            vid, actions: filteredActions, id: renderTargetID,
            allowLarger: outExt != nil, hideFloatingResult: hide,
            aggressiveOptimisation: aggressive ? true : nil,
            videoEncoderOverride: videoEncoderOvr, ffmpegEncoderOverride: ffmpegEncoder,
            outputExtension: outExt, source: source
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
        retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
        return true
    }

    private func runCompiledImageBatch(batch: [PipelineStep], actions: [PipelineAction], inputFile: FilePath, location: String, aggressive: Bool) async -> Bool {
        var outExt: String?
        for s in batch {
            if case .convert = s { outExt = "" } // presence means allowLarger
        }

        guard let data = try? Data(contentsOf: inputFile.url) else { return false }
        let img = Image(data: data, path: inputFile, retinaDownscaled: false)
        let filteredActions = actions.filter { action in
            guard case let .downscale(factor, cropSize) = action, factor == nil, let cropSize else { return true }
            let imgW = img.size.width; let imgH = img.size.height
            if cropSize.longEdge {
                return cropSize.width > 0 && max(imgW, imgH) > cropSize.width.d
            }
            return (cropSize.width > 0 && imgW > cropSize.width.d) || (cropSize.height > 0 && imgH > cropSize.height.d)
        }

        guard let result = try? await runImagePipeline(
            img, actions: filteredActions,
            id: encodeID(forLocation: location),
            saveTo: clipboardSaveTo,
            copyToClipboard: copyResultToClipboard,
            allowLarger: outExt != nil, hideFloatingResult: hide,
            aggressiveOptimisation: aggressive, source: source
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
        retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
        return true
    }

    private func runCompiledAudioBatch(batch: [PipelineStep], actions: [PipelineAction], inputFile: FilePath, location: String, aggressive: Bool) async -> Bool {
        // Fetch metadata so bitrate-reduction steps can clamp against the real input bitrate.
        let audio = await (try? Audio.byFetchingMetadata(path: inputFile, thumb: false)) ?? Audio(path: inputFile, thumb: false)

        // Extract an explicit target bitrate from the batch. `lowerBitrate` wins over
        // `downscale(factor:)` if both are present; the last one in the batch wins among
        // duplicates. A nil result from the helper means "no-op" (would be upscaling), so
        // we simply skip applying a bitrate override in that case.
        var bitrateOverride: Int?
        var formatOverride: AudioFormat?
        for step in batch {
            switch step {
            case let .lowerBitrate(kbps, _):
                if let clamped = audio.loweredBitrate(kbps: kbps) {
                    bitrateOverride = clamped
                }
            case let .downscale(factor, _):
                if bitrateOverride == nil, let clamped = audio.loweredBitrate(factor: factor) {
                    bitrateOverride = clamped
                }
            case let .convert(fmt, _):
                formatOverride = AudioFormat.from(conversionTarget: fmt)
            default:
                break
            }
        }

        guard let result = try? await runAudioPipeline(
            audio, actions: actions, id: renderTargetID,
            allowLarger: formatOverride != nil, hideFloatingResult: hide,
            source: source,
            bitrateOverride: bitrateOverride,
            aggressiveOptimisation: aggressive ? true : nil,
            formatOverride: formatOverride
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
        retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
        return true
    }

    private func runCompiledPDFBatch(actions: [PipelineAction], inputFile: FilePath, location: String, aggressive: Bool, dpi: Int?) async -> Bool {
        let pdf = PDF(inputFile)

        guard let result = try? await runPDFPipeline(
            pdf, actions: actions, id: renderTargetID,
            allowLarger: false, hideFloatingResult: hide,
            aggressiveOptimisation: aggressive ? true : nil,
            dpiOverride: dpi,
            source: source
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
        retargetChildOptimiser(originalID: renderTargetID, to: currentFile)
        return true
    }

}
