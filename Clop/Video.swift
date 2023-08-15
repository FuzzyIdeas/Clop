import AVFoundation
import Cocoa
import CoreTransferable
import Defaults
import EonilFSEvents
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

let FFMPEG = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)!.path
// let MEDIAINFO = Bundle.main.url(forResource: "mediainfo", withExtension: nil)!.path

class Video {
    init(path: FilePath, metadata: VideoMetadata? = nil, fileSize: Int? = nil, convertedFrom: Video? = nil, thumb: Bool = true, id: String? = nil) {
        self.path = path
        self.convertedFrom = convertedFrom
        self.id = id

        if let fileSize {
            self.fileSize = fileSize
        }

        if let metadata {
            self.metadata = metadata
        } else {
            Task.init {
                self.metadata = try? await getVideoMetadata(path: path)
                await MainActor.run { optimizer?.oldSize = self.size }
            }
        }
        if thumb {
            mainActor { self.fetchThumbnail() }
        }
    }

    let path: FilePath
    lazy var fileSize: Int = path.fileSize() ?? 0
    var convertedFrom: Video?
    let id: String?

    var metadata: VideoMetadata?

    var size: CGSize? { metadata?.resolution }
    var fps: Float? {
        guard let fps = metadata?.fps, fps > 0 else { return nil }
        return fps
    }

    @MainActor var optimizer: Optimizer? {
        OM.optimizers.first(where: { $0.id == id ?? path.string })
    }

    static func byFetchingMetadata(path: FilePath, fileSize: Int? = nil, convertedFrom: Video? = nil, thumb: Bool = true, id: String? = nil) async throws -> Video? {
        let metadata = try await getVideoMetadata(path: path)
        let video = Video(path: path, metadata: metadata, fileSize: fileSize, convertedFrom: convertedFrom, thumb: thumb, id: id)

        await MainActor.run { video.optimizer?.oldSize = metadata?.resolution }

        return video
    }

    func useAggressiveOptimisation(aggressiveSetting: Bool) -> Bool {
        Defaults[.useCPUIntensiveEncoder] || aggressiveSetting ||
            (
                Defaults[.adaptiveVideoSize] &&
                    ((size?.area.i ?? Int.max) < (1920 * 1080) || fileSize < 20_000_000)
            )

    }

    @MainActor
    func fetchThumbnail() {
        generateThumbnail(for: path.url, size: THUMB_SIZE) { [weak self] thumb in
            guard let self, let optimizer else {
                return
            }
            optimizer.thumbnail = NSImage(cgImage: thumb.cgImage, size: .zero)
        }
    }

    func optimize(optimizer: Optimizer, forceMP4: Bool = false, backup: Bool = true, resizeTo newSize: CGSize? = nil, originalPath: FilePath? = nil, aggressiveOptimization: Bool? = nil) throws -> Video {
        print("Optimizing video \(path.string)")
        guard let name = path.lastComponent else {
            err("No file name for path: \(path)")
            throw ClopError.fileNotFound(path)
        }

        path.waitForFile(for: 3)
        try path.setOptimizationStatusXattr("pending")

        let outputPath = forceMP4 ? path.removingLastComponent().appending("\(name.stem).mp4") : path
        var inputPath = originalPath ?? ((path == outputPath && backup) ? (path.backup(operation: .copy) ?? path) : path)
        let tmpPath = FilePath.videos.appending(outputPath.name)

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

        let aggressive = aggressiveOptimization ?? Defaults[.useAggresiveOptimizationMP4]
        mainActor { optimizer.aggresive = aggressive }
        #if arch(arm64)
            let encoderArgs = useAggressiveOptimisation(aggressiveSetting: aggressiveOptimization ?? false)
                ? ["-vcodec", "h264", "-tag:v", "avc1"] + (aggressive ? ["-preset", "slower", "-crf", "20"] : [])
                : ["-vcodec", "h264_videotoolbox", "-q:v", "50", "-tag:v", "avc1"]
        #else
            let encoderArgs = ["-vcodec", "h264", "-tag:v", "avc1"] + (aggressive ? ["-preset", "slower", "-crf", "20"] : [])
        #endif
        let args = ["-y", "-i", inputPath.string] + encoderArgs + additionalArgs + ["-movflags", "+faststart", "-progress", "pipe:2", "-nostats", "-hide_banner", "-stats_period", "0.1", tmpPath.string]

        let proc = try tryProc(FFMPEG, args: args, tries: 3, captureOutput: true) { proc in
            mainActor {
                optimizer.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: inputPath.url, optimizer: optimizer)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        tmpPath.waitForFile(for: 2)
        tmpPath.copyExif(from: path)
        try? tmpPath.setOptimizationStatusXattr("true")
        try tmpPath.move(to: outputPath, force: true)

        if Defaults[.capVideoFPS], let fps, let new = newFPS, new > fps {
            newFPS = fps
        }
        let metadata = VideoMetadata(resolution: newSize ?? size ?? .zero, fps: newFPS ?? fps ?? 0)
        return Video(path: outputPath, metadata: metadata, convertedFrom: forceMP4 && inputPath.extension?.lowercased() != "mp4" ? self : nil)
    }
}

struct VideoMetadata {
    let resolution: CGSize
    let fps: Float
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
    return VideoMetadata(resolution: CGSize(width: abs(size.width), height: abs(size.height)), fps: fps)
}

let FFMPEG_DURATION_REGEX = try! Regex(#"^\s*Duration: (\d{2,}):(\d{2,}):(\d{2,}).(\d{2})"#, as: (Substring, Substring, Substring, Substring, Substring).self).anchorsMatchLineEndings(true)

@MainActor func updateProgressFFmpeg(pipe: Pipe, url: URL, optimizer: Optimizer) {
    mainActor {
        optimizer.progress = Progress(totalUnitCount: 100)
        optimizer.progress.fileURL = url
        optimizer.progress.localizedDescription = optimizer.operation
        optimizer.progress.localizedAdditionalDescription = "Calculating duration"
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
            if optimizer.progress.totalUnitCount == 100, let match = try? FFMPEG_DURATION_REGEX.firstMatch(in: string) {
                let h = Int64(match.1)!
                let m = Int64(match.2)!
                let s = Int64(match.3)!
                let ms = Int64(match.4)!
                optimizer.progress.totalUnitCount = ((h * 3600 + m * 60 + s) * 1000 + (ms * 10)) * 1000
            }
        }

        let lines = string.components(separatedBy: .newlines)
        for line in lines where line.starts(with: "out_time_us=") {
            guard let time = Int64(line.suffix(line.count - 12)), time > 0 else {
                continue
            }
            mainActor {
                optimizer.progress.completedUnitCount = min(time, optimizer.progress.totalUnitCount)
                optimizer.progress.localizedAdditionalDescription = "\(time.hmsString) of \(optimizer.progress.totalUnitCount.hmsString)"
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

@MainActor func shouldHandleVideo(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          VIDEO_EXTENSIONS.contains(ext), !Defaults[.videoFormatsToSkip].lazy.compactMap(\.preferredFilenameExtension).contains(ext)
    else {
        return false

    }

    print("\(event.path): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.backups.string),
          flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
          !path.hasOptimizationStatusXattr(), let size = path.fileSize(), size > 0, size < Defaults[.maxVideoSizeMB] * 1_000_000, videoOptimizeDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            videoOptimizeDebouncers[event.path]?.cancel()
            videoOptimizeDebouncers.removeValue(forKey: event.path)
        }
        return false
    }
    return true
}

@discardableResult
@MainActor func optimizeVideo(_ video: Video, id: String? = nil, debounceMS: Int = 0, allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimization: Bool? = nil) async throws -> Video? {
    let path = video.path
    let pathString = path.string
    let itemType = ItemType.from(filePath: path)
    let optimizer = OM.optimizer(id: id ?? pathString, type: itemType, operation: debounceMS > 0 ? "Waiting for video to be ready" : "Optimizing", hidden: hideFloatingResult)

    var done = false
    var result: Video?

    videoOptimizeDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        optimizer.operation = (Defaults[.showImages] ? "Optimizing" : "Optimizing \(optimizer.filename)") + (aggressiveOptimization ?? false ? " (aggressive)" : "")
        optimizer.originalURL = path.url
        OM.optimizers = OM.optimizers.without(optimizer).with(optimizer)
        showFloatingThumbnails()

        videoOptimizationQueue.addOperation {
            defer {
                mainActor {
                    videoOptimizeDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }
            do {
                mainAsync { OM.current = optimizer }

                let oldFileSize = video.fileSize
                let optimizedVideo = try video.optimize(optimizer: optimizer, forceMP4: Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie), aggressiveOptimization: aggressiveOptimization)
                if optimizedVideo.convertedFrom == nil, optimizedVideo.fileSize > video.fileSize, !allowLarger {
                    video.path.restore(force: true)
                    mainAsync {
                        optimizer.oldBytes = oldFileSize
                        optimizer.url = video.path.url
                    }

                    throw ClopError.videoSizeLarger(path)
                }
                mainActor {
                    result = optimizedVideo
                }
                mainAsync {
                    optimizer.url = optimizedVideo.path.url
                    optimizer.finish(oldBytes: oldFileSize, newBytes: optimizedVideo.fileSize, removeAfterMs: hideFilesAfter)
                }
            } catch let ClopError.processError(proc) {
                if proc.terminated {
                    debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    err("Error optimizing video \(pathString): \(proc.commandLine)")
                    optimizer.finish(error: "Optimization failed")
                }
            } catch let error as ClopError {
                err("Error optimizing video \(pathString): \(error.description)")
                mainActor { optimizer.finish(error: error.humanDescription) }
            } catch {
                err("Error optimizing video \(pathString): \(error)")
                mainActor { optimizer.finish(error: "Optimization failed") }
            }
        }
    }
    videoOptimizeDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }
    return result
}

@discardableResult
@MainActor func downscaleVideo(_ video: Video, originalPath: FilePath? = nil, id: String? = nil, toFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimization: Bool? = nil) async throws -> Video? {
    guard let resolution = video.size else {
        throw ClopError.videoError("Error getting resolution for \(video.path.string)")
    }

    let pathString = video.path.string
    videoOptimizeDebouncers[pathString]?.cancel()
    if let factor {
        scalingFactor = factor
    } else if let currentFactor = opt(id ?? pathString)?.downscaleFactor {
        scalingFactor = max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    } else {
        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
    }

    let itemType = ItemType.from(filePath: video.path)
    let optimizer = OM.optimizer(id: id ?? pathString, type: itemType, operation: "Scaling to \((scalingFactor * 100).intround)%", hidden: hideFloatingResult)
    let aggressive = aggressiveOptimization ?? optimizer.aggresive
    if aggressive {
        optimizer.operation += " (aggressive)"
    }
    optimizer.remover = nil
    optimizer.inRemoval = false
    optimizer.stop(remove: false)
    optimizer.downscaleFactor = scalingFactor

    var result: Video?
    var done = false

    let workItem = optimizationQueue.asyncAfter(ms: 500) {
        defer {
            mainActor {
                videoOptimizeDebouncers[pathString]?.cancel()
                videoOptimizeDebouncers.removeValue(forKey: pathString)
                done = true
            }
        }
        do {
            let newSize = resolution.scaled(by: scalingFactor)
            let oldFileSize = video.fileSize

            let optimizedVideo = try video.optimize(
                optimizer: optimizer,
                forceMP4: Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie),
                backup: false,
                resizeTo: newSize,
                originalPath: originalPath,
                aggressiveOptimization: aggressive
            )
            if optimizedVideo.path.extension == video.path.extension, optimizedVideo.path != video.path {
                try optimizedVideo.path.move(to: video.path, force: true)
            }

            mainActor {
                OM.current = optimizer
                optimizer.finish(oldBytes: oldFileSize, newBytes: optimizedVideo.fileSize, oldSize: resolution, newSize: newSize, removeAfterMs: hideFilesAfter)
                result = optimizedVideo
            }
        } catch let ClopError.processError(proc) {
            if proc.terminated {
                debug("Process terminated by us: \(proc.commandLine)")
            } else {
                err("Error downscaling video \(pathString): \(proc.commandLine)")
                mainActor {
                    optimizer.finish(error: "Downscaling failed")
                }
            }
        } catch let error as ClopError {
            err("Error downscaling video \(pathString): \(error.description)")
            mainActor { optimizer.finish(error: error.humanDescription) }
        } catch {
            err("Error downscaling video \(pathString): \(error)")
            mainActor { optimizer.finish(error: "Optimization failed") }
        }
    }
    videoOptimizeDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }

    return result
}
