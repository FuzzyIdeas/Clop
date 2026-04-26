import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "PipelineExecution")

@MainActor
final class PipelineExecution {
    init(file: FilePath, source: OptimisationSource, optimiser: Optimiser, fileType: ClopFileType) {
        currentFile = file
        originalFile = file
        context = TemplateContext(sourceFile: file)
        self.source = source
        self.optimiser = optimiser
        self.fileType = fileType
    }

    var currentFile: FilePath
    var context: TemplateContext
    var shownVisibleResult = false
    var shouldStop = false
    var stepIndex = 0
    var stepDesc = ""

    let originalFile: FilePath
    let fileType: ClopFileType
    let source: OptimisationSource
    let optimiser: Optimiser

    var hide: Bool { currentFile.string.contains("/pipeline-") }

    // MARK: - Compiled Batch Execution

    /// Execute a batch of consecutive processing/media steps as a single compiled pass.
    /// Returns the number of steps consumed (so the caller can advance the step index).
    func handleCompiledBatch(_ batch: [PipelineStep], startIndex: Int) async -> Int {
        let batchDesc = batch.map(\.displayString).joined(separator: " + ")
        let endIndex = startIndex + batch.count - 1
        log.info("Pipeline: steps[\(startIndex)...\(endIndex)] compiled: \(batchDesc) on \(self.currentFile.string)")

        let actions = optimiser.compilePipelineActions(from: batch)

        let location: String = batch.compactMap { s in
            if case let .optimise(_, _, _, _, loc) = s { return loc }; return nil
        }.last ?? "inPlace"
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        let aggressive = batch.contains { if case let .optimise(enc, _, _, _, _) = $0 { return enc == .aggressive }; return false }
        let dpi: Int? = batch.compactMap { if case let .optimise(_, _, _, d, _) = $0 { return d }; return nil }.last

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

        log.info("Pipeline: steps[\(startIndex)...\(endIndex)] completed, file: \(self.currentFile.string)")
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
                    allowLarger: false,
                    hideFloatingResult: hide,
                    aggressiveOptimisation: aggressive,
                    adaptiveOptimisation: adaptive,
                    source: source
                ) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
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
                vid, actions: [.optimise],
                allowLarger: false,
                hideFloatingResult: hide,
                aggressiveOptimisation: aggressive,
                videoEncoderOverride: videoEncoder,
                source: source
            ) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(inputFile.string)")
                if location != "inPlace" {
                    currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                }
            }
        case .pdf:
            let pdf = PDF(inputFile)
            if let result = try? await runPDFPipeline(
                pdf, actions: [.optimise],
                allowLarger: false,
                hideFloatingResult: hide,
                aggressiveOptimisation: aggressive ? true : nil,
                dpiOverride: dpi,
                source: source
            ) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for PDF \(inputFile.string)")
                if location != "inPlace" {
                    currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
                }
            }
        case .audio:
            let audio = Audio(inputFile)
            if let result = try? await runAudioPipeline(
                audio, actions: [.optimise],
                hideFloatingResult: hide,
                source: source
            ) {
                currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                if !hide { shownVisibleResult = true }
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

    func handleDownscale(factor: Double, location: String) async {
        let action = PipelineAction.downscale(factor: factor, cropSize: nil)
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

        switch fileType {
        case .image:
            if let data = try? Data(contentsOf: inputFile.url) {
                let img = Image(data: data, path: inputFile, retinaDownscaled: false)
                if let result = try? await runImagePipeline(img, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                } else {
                    log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for image \(inputFile.string)")
                }
            }
        case .video:
            let vid = Video(inputFile)
            if let result = try? await runVideoPipeline(vid, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
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
        let inputFile = tempCopyIfNeeded(currentFile, location: location)
        let usedTempCopy = inputFile != currentFile

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
                    if let result = try? await runImagePipeline(img, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                        if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                        if !hide { shownVisibleResult = true }
                    } else {
                        log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for image conversion \(inputFile.string)")
                    }
                }
            case .video:
                let vid = Video(inputFile)
                if let result = try? await runVideoPipeline(vid, actions: [action], allowLarger: true, hideFloatingResult: hide, source: source) {
                    currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
                    if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
                    if !hide { shownVisibleResult = true }
                } else {
                    log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video conversion \(inputFile.string)")
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
                if needsCrop, let result = try? await runImagePipeline(img, actions: [action], allowLarger: false, hideFloatingResult: hide, source: source) {
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
            if needsCrop, let result = try? await runVideoPipeline(vid, actions: [action], allowLarger: false, hideFloatingResult: hide, source: source) {
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

    // MARK: - File Operation Steps

    func handleCopy(to: String) throws {
        let destPath = context.resolve(to)
        if let dest = destPath.filePath {
            let destDir = dest.removingLastComponent()
            try? fm.createDirectory(atPath: destDir.string, withIntermediateDirectories: true)
            let copied = try currentFile.copy(to: dest, force: true)
            currentFile = copied
        }
    }

    func handleMove(to: String) throws {
        let destPath = context.resolve(to)
        if let dest = destPath.filePath {
            let destDir = dest.removingLastComponent()
            try? fm.createDirectory(atPath: destDir.string, withIntermediateDirectories: true)
            let moved = try currentFile.move(to: dest, force: true)
            currentFile = moved
        }
    }

    func handleRename(to: String) throws {
        let newName = context.resolve(to)
        let dest = currentFile.removingLastComponent().appending(newName)
        let moved = try currentFile.move(to: dest, force: true)
        currentFile = moved
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
        let (matches, captures) = condition.evaluate(file: currentFile, context: context)
        if !matches {
            log.info("Pipeline: filter condition not met, stopping pipeline for \(self.currentFile.string)")
            shouldStop = true
            return
        }
        if !captures.isEmpty { context.regexCaptures = captures }
    }

    func handleFilterIfNot(condition: FilterCondition) {
        let (matches, _) = condition.evaluate(file: currentFile, context: context)
        if matches {
            log.info("Pipeline: exclusion filter matched, stopping pipeline for \(self.currentFile.string)")
            shouldStop = true
        }
    }

    // MARK: - Media-specific Steps

    func handleRemoveAudio() async {
        if fileType == .video {
            let vid = Video(currentFile)
            if let result = try? await runVideoPipeline(vid, actions: [.removeAudio], allowLarger: true, hideFloatingResult: hide, source: source) {
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
            if let result = try? await runVideoPipeline(vid, actions: [.changePlaybackSpeed(factor: factor)], allowLarger: true, hideFloatingResult: hide, source: source) {
                currentFile = result.path
                if !hide { shownVisibleResult = true }
            } else {
                log.warning("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) failed for video \(self.currentFile.string)")
            }
        case .audio:
            let audio = Audio(currentFile)
            let changed = try audio.changeSpeed(factor: factor, optimiser: optimiser)
            currentFile = changed.path
        default:
            log.debug("Pipeline: changeSpeed not applicable for \(self.fileType)")
        }
    }

    // MARK: - Generic Action Steps

    func handleRunScript(scriptPath: String) async {
        let resolvedPath = context.resolve(scriptPath)
        let inputPath = currentFile.string
        let scriptName = FilePath(resolvedPath).stem ?? resolvedPath
        log.info("Pipeline: running script '\(scriptName)' at \(resolvedPath) with input \(inputPath)")

        let currentFile = currentFile
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

    func handleCopyLinkForSending() async {
        let url = currentFile.url
        if let shareURL = await warpDropSendAndWait(url: url, optimiser: optimiser) {
            log.info("Pipeline: send link copied: \(shareURL)")
        }
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
            log.debug("Pipeline: step[\(self.stepIndex)] \(self.stepDesc) skipped — bitrate already at or below target for \(inputFile.string)")
            if location != "inPlace" {
                currentFile = applyLocation(location, to: currentFile, original: currentFile, context: context)
            }
            if usedTempCopy, currentFile != inputFile { cleanupTempFile(inputFile, original: originalFile) }
            return
        }

        if let result = try? await runAudioPipeline(
            audio, actions: [.optimise],
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
            vid, actions: filteredActions,
            allowLarger: outExt != nil, hideFloatingResult: hide,
            aggressiveOptimisation: aggressive ? true : nil,
            videoEncoderOverride: videoEncoderOvr, ffmpegEncoderOverride: ffmpegEncoder,
            outputExtension: outExt, source: source
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
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
            allowLarger: outExt != nil, hideFloatingResult: hide,
            aggressiveOptimisation: aggressive, source: source
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
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
            default:
                break
            }
        }

        guard let result = try? await runAudioPipeline(
            audio, actions: actions,
            allowLarger: false, hideFloatingResult: hide,
            source: source,
            bitrateOverride: bitrateOverride,
            aggressiveOptimisation: aggressive ? true : nil
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
        return true
    }

    private func runCompiledPDFBatch(actions: [PipelineAction], inputFile: FilePath, location: String, aggressive: Bool, dpi: Int?) async -> Bool {
        let pdf = PDF(inputFile)

        guard let result = try? await runPDFPipeline(
            pdf, actions: actions,
            allowLarger: false, hideFloatingResult: hide,
            aggressiveOptimisation: aggressive ? true : nil,
            dpiOverride: dpi,
            source: source
        ) else { return false }

        currentFile = applyLocation(location, to: result.path, original: currentFile, context: context)
        return true
    }

}
