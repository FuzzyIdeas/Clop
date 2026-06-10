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
    loudnormTarget: Double? = nil
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
        await previousPipeline.value
    }

    let optimiser = OM.optimiser(id: pipelineId, type: .audio(audioType), operation: opLabel, hidden: hideFloatingResult, source: source)
    optimiser.aggressive = aggressive

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
                optimisedAudio = try audio.optimise(optimiser: optimiser, bitrateOverride: bitrateOverride, aggressive: aggressive, formatOverride: formatOverride, loudnormTarget: loudnormTarget)

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

            // Move optimised file to the correct location based on user preference.
            // Pipeline conversion steps (formatOverride) manage placement themselves via
            // applyLocation, so leave the result in the temp folder for those.
            let behaviour = Defaults[.optimisedAudioBehaviour]
            let resolvedFormat = formatOverride ?? Defaults[.audioFormat].resolved(forInputExtension: path.extension ?? "")
            if formatOverride == nil, optimisedAudio.path.dir == FilePath.audios {
                let destPath: FilePath? = switch behaviour {
                case .inPlace:
                    path.dir.appending("\(path.stem!).\(resolvedFormat.fileExtension)")
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

                if behaviour == .inPlace, path.extension?.lowercased() != resolvedFormat.fileExtension {
                    try? fm.removeItem(at: path.url)
                }
            }

            let hideFilesAfter = Defaults[.autoHideFloatingResultsAfter] * 1000
            let oldBitrate = audio.bitrate
            let newBitrate = optimisedAudio.bitrate
            mainActor {
                result = optimisedAudio
                optimiser.url = optimisedAudio.path.url
                optimiser.audio = optimisedAudio
                if let outputType = Defaults[.audioFormat].utType {
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
