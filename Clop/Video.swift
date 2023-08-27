import AVFoundation
import Cocoa
import CoreTransferable
import Defaults
import EonilFSEvents
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

let FFMPEG = BIN_DIR.appendingPathComponent("ffmpeg").existingFilePath!

class Video: Optimisable {
    init(path: FilePath, metadata: VideoMetadata? = nil, fileSize: Int? = nil, convertedFrom: Video? = nil, thumb: Bool = true, id: String? = nil) {
        super.init(path, thumb: thumb, id: id)
        self.convertedFrom = convertedFrom

        if let fileSize {
            self.fileSize = fileSize
        }

        if let metadata {
            self.metadata = metadata
        } else {
            Task.init {
                self.metadata = try? await getVideoMetadata(path: path)
                await MainActor.run { optimiser?.oldSize = self.size }
            }
        }
    }

    var convertedFrom: Video?
    var metadata: VideoMetadata?

    var size: CGSize? { metadata?.resolution }
    var duration: Double? { metadata?.duration }
    var fps: Float? {
        guard let fps = metadata?.fps, fps > 0 else { return nil }
        return fps
    }

    static func byFetchingMetadata(path: FilePath, fileSize: Int? = nil, convertedFrom: Video? = nil, thumb: Bool = true, id: String? = nil) async throws -> Video? {
        let metadata = try await getVideoMetadata(path: path)
        let video = Video(path: path, metadata: metadata, fileSize: fileSize, convertedFrom: convertedFrom, thumb: thumb, id: id)

        await MainActor.run { video.optimiser?.oldSize = metadata?.resolution }

        return video
    }

    #if arch(arm64)
        func useAggressiveOptimisation(aggressiveSetting: Bool) -> Bool {
            if Defaults[.useCPUIntensiveEncoder] || aggressiveSetting {
                return true
            }
            guard Defaults[.adaptiveVideoSize] else {
                return false
            }
            if let size, let duration, fileSize > 0 {
                return size.area.i * max(duration.intround, 0) * fileSize < 1920 * 1080 * 10 * 5_000_000
            }
            return (size?.area.i ?? Int.max) < (1920 * 1080) || (metadata?.duration ?? 999_999) < 10 || fileSize < 5_000_000
        }
    #endif

    func optimise(optimiser: Optimiser, forceMP4: Bool = false, backup: Bool = true, resizeTo newSize: CGSize? = nil, originalPath: FilePath? = nil, aggressiveOptimisation: Bool? = nil) throws -> Video {
        log.debug("Optimising video \(path.string)")
        guard let name = path.lastComponent else {
            log.error("No file name for path: \(path)")
            throw ClopError.fileNotFound(path)
        }

        path.waitForFile(for: 3)
        try path.setOptimisationStatusXattr("pending")

        let outputPath = forceMP4 ? FilePath.videos.appending("\(name.stem).mp4") : path
        var inputPath = originalPath ?? ((path == outputPath && backup) ? (path.backup(operation: .copy) ?? path) : path)

        var additionalArgs = [String]()
        if let size = newSize {
            let pathForResize = FilePath.forResize.appending(path.nameWithoutSize)
            try inputPath.copy(to: pathForResize, force: true)
            inputPath = pathForResize
            additionalArgs += ["-vf", "scale=w=\(size.width.i.s):h=\(size.height.i.s)"]
        }

        var newFPS = fps
        if Defaults[.capVideoFPS] {
            newFPS = Defaults[.targetVideoFPS]
            if newFPS == -2, let fps {
                newFPS = max(fps / 2, Defaults[.minVideoFPS])
            } else if newFPS == -4, let fps {
                newFPS = max(fps / 4, Defaults[.minVideoFPS])
            } else if newFPS! < 0 {
                newFPS = 60
            }
            additionalArgs += ["-fpsmax", "\(newFPS!)"]
        }

        let aggressive = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationMP4]
        mainActor { optimiser.aggresive = aggressive }
        #if arch(arm64)
            let encoderArgs = useAggressiveOptimisation(aggressiveSetting: aggressiveOptimisation ?? false)
                ? ["-vcodec", "h264", "-tag:v", "avc1"] + (aggressive ? ["-preset", "slower", "-crf", "20"] : [])
                : ["-vcodec", "h264_videotoolbox", "-q:v", "50", "-tag:v", "avc1"]
        #else
            let encoderArgs = ["-vcodec", "h264", "-tag:v", "avc1"] + (aggressive ? ["-preset", "slower", "-crf", "20"] : [])
        #endif
        let args = ["-y", "-i", inputPath.string] + encoderArgs + additionalArgs + ["-movflags", "+faststart", "-progress", "pipe:2", "-nostats", "-hide_banner", "-stats_period", "0.1", outputPath.string]

        let proc = try tryProc(FFMPEG.string, args: args, tries: 3, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: inputPath.url, optimiser: optimiser)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        outputPath.waitForFile(for: 2)
        outputPath.copyExif(from: path)
        try? outputPath.setOptimisationStatusXattr("true")

        if Defaults[.capVideoFPS], let fps, let new = newFPS, new > fps {
            newFPS = fps
        }
        let metadata = VideoMetadata(resolution: newSize ?? size ?? .zero, fps: newFPS ?? fps ?? 0)
        let convertedFrom = forceMP4 && inputPath.extension?.lowercased() != "mp4" ? self : nil
        var newVideo = Video(path: outputPath, metadata: metadata, convertedFrom: convertedFrom)

        if let convertedFrom {
            let behaviour = Defaults[.convertedVideoBehaviour]
            if behaviour == .inPlace {
                convertedFrom.path.backup(force: true, operation: .move)
            }
            if behaviour != .temporary {
                let path = try newVideo.path.copy(to: convertedFrom.path.dir, force: true)
                mainActor {
                    optimiser.convertedFromURL = convertedFrom.path.url
                }
                newVideo = Video(path: path, metadata: metadata, convertedFrom: convertedFrom)
            }
        }
        mainActor {
            optimiser.url = newVideo.path.url
        }

        return newVideo
    }
}

struct VideoMetadata {
    let resolution: CGSize
    let fps: Float
    var duration: Double?
}

func getVideoMetadata(path: FilePath) async throws -> VideoMetadata? {
    guard let track = try await AVURLAsset(url: path.url).loadTracks(withMediaType: .video).first else {
        return nil
    }
    var size = try await track.load(.naturalSize)
    if let transform = try? await track.load(.preferredTransform) {
        size = size.applying(transform)
    }
    let fps = try await track.load(.nominalFrameRate)
    let duration = try await track.asset?.load(.duration)
    return VideoMetadata(resolution: CGSize(width: abs(size.width), height: abs(size.height)), fps: fps, duration: duration?.seconds)
}

let FFMPEG_DURATION_REGEX = try! Regex(#"^\s*Duration: (\d{2,}):(\d{2,}):(\d{2,}).(\d{2})"#, as: (Substring, Substring, Substring, Substring, Substring).self).anchorsMatchLineEndings(true)

@MainActor func updateProgressFFmpeg(pipe: Pipe, url: URL, optimiser: Optimiser) {
    mainActor {
        optimiser.progress = Progress(totalUnitCount: 100)
        optimiser.progress.fileURL = url
        optimiser.progress.localizedDescription = optimiser.operation
        optimiser.progress.localizedAdditionalDescription = "Calculating duration"
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return
        }

        // match `Duration: 00:00:02.88`
        mainActor {
            if optimiser.progress.totalUnitCount == 100, let match = try? FFMPEG_DURATION_REGEX.firstMatch(in: string) {
                let h = Int64(match.1)!
                let m = Int64(match.2)!
                let s = Int64(match.3)!
                let ms = Int64(match.4)!
                optimiser.progress.totalUnitCount = ((h * 3600 + m * 60 + s) * 1000 + (ms * 10)) * 1000
            }
        }

        let lines = string.components(separatedBy: .newlines)
        for line in lines where line.starts(with: "out_time_us=") {
            guard let time = Int64(line.suffix(line.count - 12)), time > 0 else {
                continue
            }
            mainActor {
                optimiser.progress.completedUnitCount = min(time, optimiser.progress.totalUnitCount)
                optimiser.progress.localizedAdditionalDescription = "\(time.hmsString) of \(optimiser.progress.totalUnitCount.hmsString)"
            }
        }
    }
}

extension Int64 {
    var hmsString: String {
        let ms = self / 1000
        let s = ms / 1000
        let m = s / 60
        let h = m / 60
        if h == 0 {
            if m == 0 {
                return String(format: "%d.%03ds", s % 60, ms % 1000)
            }
            return String(format: "%dm %d.%03ds", m % 60, s % 60, ms % 1000)
        }
        return String(format: "%dh %dm %d.%03ds", h % 60, m % 60, s % 60, ms % 1000)
    }
}

var processTerminated = Set<pid_t>()

@MainActor func cancelVideoOptimisation(path: FilePath) {
    videoOptimiseDebouncers[path.string]?.cancel()
    videoOptimiseDebouncers.removeValue(forKey: path.string)

    opt(path.string)?.stop(animateRemoval: false)
}

@MainActor func shouldHandleVideo(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          VIDEO_EXTENSIONS.contains(ext), !Defaults[.videoFormatsToSkip].lazy.compactMap(\.preferredFilenameExtension).contains(ext)
    else {
        return false

    }

    log.debug("\(path.shellString): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.backups.string),
          flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
          !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0, size < Defaults[.maxVideoSizeMB] * 1_000_000, videoOptimiseDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            videoOptimiseDebouncers[event.path]?.cancel()
            videoOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }
    return true
}

@discardableResult
@MainActor func optimiseVideo(_ video: Video, id: String? = nil, debounceMS: Int = 0, allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) async throws -> Video? {
    let path = video.path
    let pathString = path.string
    let itemType = ItemType.from(filePath: path)
    let optimiser = OM.optimiser(id: id ?? pathString, type: itemType, operation: debounceMS > 0 ? "Waiting for video to be ready" : "Optimising", hidden: hideFloatingResult)

    var done = false
    var result: Video?

    videoOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        optimiser.operation = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressiveOptimisation ?? false ? " (aggressive)" : "")
        optimiser.originalURL = path.url
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        videoOptimisationQueue.addOperation {
            defer {
                mainActor {
                    videoOptimiseDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }
            do {
                mainAsync { OM.current = optimiser }

                let oldFileSize = video.fileSize
                let optimisedVideo = try video.optimise(optimiser: optimiser, forceMP4: Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie), aggressiveOptimisation: aggressiveOptimisation)
                if optimisedVideo.convertedFrom == nil, optimisedVideo.fileSize >= video.fileSize, !allowLarger {
                    video.path.restore(force: true)
                    mainAsync {
                        optimiser.oldBytes = oldFileSize
                        optimiser.url = video.path.url
                    }

                    throw ClopError.videoSizeLarger(path)
                }
                mainActor {
                    result = optimisedVideo
                }
                mainAsync {
                    optimiser.url = optimisedVideo.path.url
                    optimiser.finish(oldBytes: oldFileSize, newBytes: optimisedVideo.fileSize, removeAfterMs: hideFilesAfter)
                }
            } catch let ClopError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error optimising video \(pathString): \(proc.commandLine)")
                    optimiser.finish(error: "Optimisation failed")
                }
            } catch let error as ClopError {
                log.error("Error optimising video \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error optimising video \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }
        }
    }
    videoOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }
    return result
}

@discardableResult
@MainActor func downscaleVideo(_ video: Video, originalPath: FilePath? = nil, id: String? = nil, toFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) async throws -> Video? {
    guard let resolution = video.size else {
        throw ClopError.videoError("Error getting resolution for \(video.path.string)")
    }

    let pathString = video.path.string
    videoOptimiseDebouncers[pathString]?.cancel()
    if let factor {
        scalingFactor = factor
    } else if let currentFactor = opt(id ?? pathString)?.downscaleFactor {
        scalingFactor = max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    } else {
        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
    }

    let itemType = ItemType.from(filePath: video.path)
    let optimiser = OM.optimiser(id: id ?? pathString, type: itemType, operation: "Scaling to \((scalingFactor * 100).intround)%", hidden: hideFloatingResult)
    let aggressive = aggressiveOptimisation ?? optimiser.aggresive
    if aggressive {
        optimiser.operation += " (aggressive)"
    }
    optimiser.remover = nil
    optimiser.inRemoval = false
    optimiser.stop(remove: false)
    optimiser.downscaleFactor = scalingFactor

    var result: Video?
    var done = false

    let workItem = optimisationQueue.asyncAfter(ms: 500) {
        defer {
            mainActor {
                videoOptimiseDebouncers[pathString]?.cancel()
                videoOptimiseDebouncers.removeValue(forKey: pathString)
                done = true
            }
        }
        do {
            let newSize = resolution.scaled(by: scalingFactor)
            let oldFileSize = video.fileSize

            let optimisedVideo = try video.optimise(
                optimiser: optimiser,
                forceMP4: Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie),
                backup: false,
                resizeTo: newSize,
                originalPath: originalPath,
                aggressiveOptimisation: aggressive
            )
            if optimisedVideo.path.extension == video.path.extension, optimisedVideo.path != video.path {
                try optimisedVideo.path.move(to: video.path, force: true)
            }

            mainActor {
                optimiser.url = optimisedVideo.path.url
                OM.current = optimiser
                optimiser.finish(oldBytes: oldFileSize, newBytes: optimisedVideo.fileSize, oldSize: resolution, newSize: newSize, removeAfterMs: hideFilesAfter)
                result = optimisedVideo
            }
        } catch let ClopError.processError(proc) {
            if proc.terminated {
                log.debug("Process terminated by us: \(proc.commandLine)")
            } else {
                log.error("Error downscaling video \(pathString): \(proc.commandLine)")
                mainActor {
                    optimiser.finish(error: "Downscaling failed")
                }
            }
        } catch let error as ClopError {
            log.error("Error downscaling video \(pathString): \(error.description)")
            mainActor { optimiser.finish(error: error.humanDescription) }
        } catch {
            log.error("Error downscaling video \(pathString): \(error)")
            mainActor { optimiser.finish(error: "Optimisation failed") }
        }
    }
    videoOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }

    return result
}
