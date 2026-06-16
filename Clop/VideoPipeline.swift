import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "VideoPipeline")

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
    source: OptimisationSource? = nil,
    fpsOverride: Int? = nil,
    compression: CompressionQuality? = nil,
    batchOptimiser: Optimiser? = nil
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
            if let resolution = video.size {
                // Never upscale: a long-edge cap larger than the source is a no-op, not an enlargement.
                // ffmpeg's `scale` would otherwise blow the video up (unlike vipsthumbnail for images).
                if let cropSize, cropSize.longEdge {
                    let target = cropSize.computedSize(from: resolution)
                    if max(target.width, target.height) >= max(resolution.width, resolution.height) {
                        break
                    }
                }
                cropTo = cropSize
                let effectiveFactor: Double = if let cropSize {
                    computeVideoDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: cropSize, videoSize: resolution)
                } else {
                    computeVideoDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: nil, videoSize: resolution)
                }
                scalingFactor = effectiveFactor
                resizeTo = cropSize?.computedSize(from: resolution) ?? resolution.scaled(by: effectiveFactor)
            } else {
                cropTo = cropSize
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

    let pipelineId = id ?? pathString

    // Serialize per id: terminate the in-flight pipeline's running process and wait for it to unwind.
    // Prevents concurrent downscale/speed-change passes from racing on the same file paths.
    if let previousPipeline = videoPipelineInFlight[pipelineId] {
        opt(pipelineId)?.stop(remove: false)
        // Hash off the main actor while the in-flight pass unwinds: the lazy `video.hash`
        // would only read the file after the awaited pass has already replaced it.
        let contentHash = Task.detached { path.fileContentsHash }
        await previousPipeline.value

        // A duplicate plain-optimise request (e.g. several file-watcher events for one download)
        // queues up here behind the first pass: re-check the cache instead of re-encoding
        // content the awaited pass just finished.
        if actions.allSatisfy(\.isOptimise), !copyToClipboard, aggressiveOptimisation == nil,
           videoEncoderOverride == nil, ffmpegEncoderOverride == nil, outputExtension == nil, fpsOverride == nil,
           let hash = await contentHash.value, let cachedPath = OM.optimisedFilesByHash[hash], cachedPath.exists
        {
            log.debug("Video \(pathString) was already optimised by the in-flight pipeline, using cached result \(cachedPath.string)")
            return Video(path: cachedPath, thumb: false, id: id)
        }
    }

    // Set up optimiser. In batch mode the engine supplies a transient hidden optimiser that is
    // never registered in OM, so the floating-result machinery is skipped entirely.
    let optimiser = batchOptimiser ?? OM.optimiser(id: pipelineId, type: itemType, operation: opLabel, hidden: hideFloatingResult, source: source)
    if let compression {
        optimiser.compressionOverride = compression
    }
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
    optimiser.newSize = nil
    optimiser.newBytes = -1

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
        optimiser.operation = optimiser.manualAdjustmentOperation ?? finalOpLabel
        if !hasDownscale, !hasSpeedChange {
            optimiser.originalURL = path.url
        }
        if batchOptimiser == nil {
            OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
            showFloatingThumbnails()
        }

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
                    videoEncoderOverride: videoEncoderOverride,
                    fpsOverride: fpsOverride
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
                    mainActor { optimiser.finish(processError: proc) }
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
                if let codec = ffmpegEncoderOverride?.codecUTType {
                    optimiser.type = .video(codec)
                } else if let ext = optimisedVideo.path.extension, let utType = UTType(filenameExtension: ext) {
                    optimiser.type = .video(utType)
                }
                if !hideFloatingResult {
                    OM.current = optimiser
                }

                // rect crops (full-frame ones included, those are plain downscales) run from
                // the pristine original (the backup), so keep reporting the original
                // bytes/size instead of the working file's
                let rectCrop = cropTo?.cropRect != nil
                if hasDownscale {
                    optimiser.finish(
                        oldBytes: rectCrop && optimiser.oldBytes > 0 ? optimiser.oldBytes : fileSize,
                        newBytes: optimisedVideo.fileSize,
                        oldSize: rectCrop ? (optimiser.oldSize ?? resolution) : resolution,
                        newSize: resizeTo,
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

    let pipelineTask = Task<Void, Never> { @MainActor in
        while !done, !workItem.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    videoPipelineInFlight[pipelineId] = pipelineTask
    await pipelineTask.value
    if videoPipelineInFlight[pipelineId] == pipelineTask {
        videoPipelineInFlight.removeValue(forKey: pipelineId)
    }
    return result
}

private extension [String] {
    var codecUTType: UTType? {
        guard let codecIdx = firstIndex(of: "-vcodec"), codecIdx + 1 < count else { return nil }
        switch self[codecIdx + 1] {
        case "libsvtav1", "libaom-av1": return .av1Video
        case "hevc_videotoolbox", "libx265": return .hevcVideo
        case "libvpx-vp9", "libvpx": return .webm
        default: return nil
        }
    }
}
