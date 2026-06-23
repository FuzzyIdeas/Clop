import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "AudioPipeline")

@discardableResult
@MainActor func runAudioPipeline(
    _ audio: Audio,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    copyToClipboard: Bool = false,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    source: OptimisationSource? = nil,
    bitrateOverride: Int? = nil,
    aggressiveOptimisation: Bool? = nil,
    formatOverride: AudioFormat? = nil,
    operationOverride: String? = nil,
    loudnormTarget: Double? = nil,
    coverArt: AudioCoverArtBehaviour? = nil,
    coverArtMaxLongEdge: Int? = nil,
    compression: CompressionQuality? = nil,
    batchOptimiser: Optimiser? = nil
) async throws -> Audio? {
    let path = audio.path
    let pathString = path.string

    let aggressive = aggressiveOptimisation ?? opt(id ?? pathString)?.aggressive ?? false
    let audioType = path.url.utType() ?? .mp3
    let opLabel = if debounceMS > 0 {
        "Waiting for audio to be ready"
    } else {
        operationLabel(for: actions, filename: path.lastComponent?.string ?? "", aggressive: aggressive)
    }

    let pipelineId = id ?? pathString

    // Serialize per id: terminate the in-flight pipeline's running process and wait for it to unwind.
    if let previousPipeline = audioPipelineInFlight[pipelineId] {
        opt(pipelineId)?.stop(remove: false)
        // Hash off the main actor while the in-flight pass unwinds: the lazy `audio.hash`
        // would only read the file after the awaited pass has already replaced it.
        let contentHash = Task.detached { path.fileContentsHash }
        await previousPipeline.value

        // A duplicate plain-optimise request (e.g. several file-watcher events for one download)
        // queues up here behind the first pass: re-check the cache instead of re-encoding
        // content the awaited pass just finished.
        if actions.allSatisfy(\.isOptimise), !copyToClipboard, aggressiveOptimisation == nil,
           bitrateOverride == nil, formatOverride == nil, loudnormTarget == nil,
           let hash = await contentHash.value, let cachedPath = OM.optimisedFilesByHash[hash], cachedPath.exists
        {
            log.debug("Audio \(pathString) was already optimised by the in-flight pipeline, using cached result \(cachedPath.string)")
            return Audio(path: cachedPath, thumb: false, id: id)
        }
    }

    // In batch mode the engine supplies a transient hidden optimiser that is never registered in OM.
    let optimiser = batchOptimiser ?? OM.optimiser(id: pipelineId, type: .audio(audioType), operation: opLabel, hidden: hideFloatingResult, source: source)
    optimiser.aggressive = aggressive
    if let compression {
        optimiser.compressionOverride = compression
    }

    var done = false
    var result: Audio?

    audioOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        optimiser.operation = operationOverride ?? "Optimising"
        optimiser.originalURL = path.url
        if batchOptimiser == nil {
            OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
            showFloatingThumbnails()
        }

        if !hideFloatingResult {
            setAudioThumbnail(on: optimiser, path: path)
        }

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
                optimisedAudio = try audio.optimise(
                    optimiser: optimiser,
                    bitrateOverride: bitrateOverride,
                    aggressive: aggressive,
                    formatOverride: formatOverride,
                    loudnormTarget: loudnormTarget,
                    coverArtBehaviour: coverArt,
                    coverArtMaxLongEdge: coverArtMaxLongEdge
                )

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
                    mainActor { optimiser.finish(processError: proc) }
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

            // Move optimised file to the correct location based on user preference.
            let resolvedFormat = formatOverride ?? Defaults[.audioFormat].resolved(forInputExtension: path.extension ?? "")
            if formatOverride == nil, optimisedAudio.path.dir == FilePath.audios {
                // Plain optimise: route through placeOutput with kind .optimised.
                if let placed = try? placeOutput(produced: optimisedAudio.path, original: path, type: .audio, kind: .optimised, overrides: optimiser.placementOverride) {
                    if placed.path != optimisedAudio.path {
                        optimisedAudio = optimisedAudio.copyWithPath(placed.path)
                    }
                }
            } else if formatOverride != nil, optimisedAudio.path.dir == FilePath.audios {
                // Auto-compat conversion: route through placeOutput with kind .autoConvert so
                // `convertedAudioBehaviour` (and any per-request override) is honoured.
                if let placed = try? placeOutput(produced: optimisedAudio.path, original: path, type: .audio, kind: .autoConvert, overrides: optimiser.placementOverride) {
                    if placed.path != optimisedAudio.path {
                        optimisedAudio = optimisedAudio.copyWithPath(placed.path)
                    }
                }
            }

            let hideFilesAfter = Defaults[.autoHideFloatingResultsAfter] * 1000
            let oldBitrate = audio.bitrate
            let newBitrate = optimisedAudio.bitrate
            mainActor {
                result = optimisedAudio
                optimiser.url = optimisedAudio.path.url
                optimiser.audio = optimisedAudio
                // Use the format actually produced (formatOverride wins), not the global default, so a
                // per-result conversion sets the right type.
                if let outputType = resolvedFormat.utType {
                    optimiser.type = .audio(outputType)
                }
                optimiser.finish(
                    oldBytes: fileSize, newBytes: optimisedAudio.fileSize,
                    oldBitrate: oldBitrate, newBitrate: newBitrate,
                    removeAfterMs: hideFilesAfter
                )

                if copyToClipboard {
                    optimiser.copyToClipboard()
                }
            }
        }
    }
    audioOptimiseDebouncers[pathString] = workItem

    let pipelineTask = Task<Void, Never> { @MainActor in
        while !done, !workItem.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    audioPipelineInFlight[pipelineId] = pipelineTask
    await pipelineTask.value
    if audioPipelineInFlight[pipelineId] == pipelineTask {
        audioPipelineInFlight.removeValue(forKey: pipelineId)
    }
    return result
}
