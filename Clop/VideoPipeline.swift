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

    let pipelineId = id ?? pathString

    // Serialize per id: terminate the in-flight pipeline's running process and wait for it to unwind.
    // Prevents concurrent downscale/speed-change passes from racing on the same file paths.
    if let previousPipeline = videoPipelineInFlight[pipelineId] {
        opt(pipelineId)?.stop(remove: false)
        await previousPipeline.value
    }

    // Set up optimiser
    let optimiser = OM.optimiser(id: pipelineId, type: itemType, operation: opLabel, hidden: hideFloatingResult, source: source)
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
