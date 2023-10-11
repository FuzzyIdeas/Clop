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
let GIFSKI = BIN_DIR.appendingPathComponent("gifski").existingFilePath!

extension Double {
    var i64: Int64 { Int64(self) }
}

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

    required convenience init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.init(path: path, thumb: thumb, id: id)
    }

    override class var dir: FilePath { .videos }

    var convertedFrom: Video?
    var metadata: VideoMetadata?

    var size: CGSize? { metadata?.resolution }
    var duration: TimeInterval? { metadata?.duration }
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

    override func copyWithPath(_ path: FilePath) -> Self {
        Video(path: path, metadata: metadata, fileSize: path.fileSize() ?? fileSize, convertedFrom: convertedFrom, thumb: true, id: id) as! Self
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

    func convertToGIF(optimiser: Optimiser, maxWidth: Int, fps: Int) throws -> Image {
        log.debug("Converting video \(path.string) to GIF")
        let tempDir = URL.temporaryDirectory.appendingPathComponent("\(path.stem!)_gif_pngs").filePath
        tempDir.mkdir(withIntermediateDirectories: true)

        let duration = duration
        if let duration {
            mainActor {
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(Int64(duration).hmsString)"
            }
        }

        let progressArgs = ["-progress", "pipe:2", "-nostats", "-hide_banner", "-stats_period", "0.1"]
        let fpsArgs = ["-fpsmax", fps.s]

        let videoURL = path.url
        let ffmpegProc = try tryProc(FFMPEG.string, args: ["-i", path.string] + progressArgs + fpsArgs + ["\(tempDir.string)/frame%04d.png"], tries: 3, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: videoURL, optimiser: optimiser, duration: duration?.i64)
            }
        }
        guard ffmpegProc.terminationStatus == 0 else {
            throw ClopProcError.processError(ffmpegProc)
        }

        let gif = FilePath.images / "\(path.stem!).gif"
        let pngs = tempDir.ls()
        let gifskiProc = try tryProc(
            GIFSKI.string,
            args: ["-o", gif.string, "--width", maxWidth.s, "--fps", fps.s, "--quality", Defaults[.useAggresiveOptimisationGIF] ? 60.s : 90.s] + pngs.map(\.string),
            tries: 3,
            captureOutput: true
        ) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressGifski(pipe: proc.standardOutput as! Pipe, url: videoURL, optimiser: optimiser, frames: pngs.count.i64)
            }
        }
        guard gifskiProc.terminationStatus == 0 else {
            throw ClopProcError.processError(gifskiProc)
        }

        try? gif.setOptimisationStatusXattr("true")

        guard let image = Image(path: gif, type: .gif, optimised: true, retinaDownscaled: false) else {
            throw ClopError.fileNotImage(gif)
        }

        mainActor {
            optimiser.url = image.path.url
            optimiser.type = .image(.gif)
        }

        return image
    }

    func getScaleFilters(cropSize: CropSize?, newSize: NSSize? = nil) -> [String] {
        guard let cropSize, let fromSize = size else {
            guard let size = newSize else { return [] } // no resize
            return ["scale=w=\(size.width.i.s):h=\(size.height.i.s)"] // resize to specific size
        }

        let s = cropSize.ns
        guard s.width > 0, s.height > 0, !cropSize.longEdge else {
            // crop by specifying only one size, keeping aspect ratio
            let scaleFactor = cropSize.factor(from: fromSize)

            if !cropSize.longEdge {
                return ["scale=w=\(s.width == 0 ? "-2" : s.width.i.s):h=\(s.height == 0 ? "-2" : s.height.i.s)"]
            } else if fromSize.width > fromSize.height {
                return ["scale=w=\(cropSize.width ?! cropSize.height):h=-2"]
            } else {
                return ["scale=w=-2:h=\(cropSize.height ?! cropSize.width)"]
            }
        }

        // crop and resize to specific size
        let cropString: String
        if (fromSize.width / s.width) > (fromSize.height / s.height) {
            let newAspectRatio = s.width / s.height
            let widthDiff = ((fromSize.width - (newAspectRatio * fromSize.height)) / 2).i
            cropString = "in_w-\(widthDiff * 2):in_h:\(widthDiff):0"
        } else {
            let newAspectRatio = s.height / s.width
            let heightDiff = ((fromSize.height - (newAspectRatio * fromSize.width)) / 2).i
            cropString = "in_w:in_h-\(heightDiff * 2):0:\(heightDiff)"
        }

        return ["crop=\(cropString)", "scale=w=\(s.width.i.s):h=\(s.height.i.s)"]
    }

    func optimise(
        optimiser: Optimiser,
        forceMP4: Bool = false,
        backup: Bool = true,
        resizeTo newSize: CGSize? = nil,
        cropTo cropSize: CropSize? = nil,
        changePlaybackSpeedBy changePlaybackSpeedFactor: Double? = nil,
        originalPath: FilePath? = nil,
        aggressiveOptimisation: Bool? = nil
    ) throws -> Video {
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

        var filters = getScaleFilters(cropSize: cropSize, newSize: newSize)

        if let changePlaybackSpeedFactor, changePlaybackSpeedFactor != 1, changePlaybackSpeedFactor > 0 {
            filters.append("setpts=PTS/\(String(format: "%.2f", changePlaybackSpeedFactor))")
        }

        if filters.isNotEmpty {
            let pathForFilters = FilePath.forFilters.appending(path.nameWithoutFilters)
            try inputPath.copy(to: pathForFilters, force: true)
            inputPath = pathForFilters
            additionalArgs += ["-vf", filters.joined(separator: ",")]
        }

        let duration = duration
        let aggressive = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationMP4]
        mainActor { optimiser.aggresive = aggressive }
        #if arch(arm64)
            let encoderArgs = useAggressiveOptimisation(aggressiveSetting: aggressiveOptimisation ?? false)
                ? ["-vcodec", "h264", "-tag:v", "avc1"] + (aggressive ? ["-preset", "slower", "-crf", "26"] : [])
                : ["-vcodec", "h264_videotoolbox", "-q:v", "50", "-tag:v", "avc1"]
        #else
            let encoderArgs = ["-vcodec", "h264", "-tag:v", "avc1"] + (aggressive ? ["-preset", "slower", "-crf", "26"] : [])
        #endif
        let args = ["-y", "-i", inputPath.string]
            + (["mp4", "mov", "hevc"].contains(outputPath.extension?.lowercased()) ? encoderArgs : [])
            + additionalArgs + ["-movflags", "+faststart", "-progress", "pipe:2", "-nostats", "-hide_banner", "-stats_period", "0.1", outputPath.string]

        var realDuration: Int64?
        if let duration {
            realDuration = ((duration * 1_000_000) / (changePlaybackSpeedFactor ?? 1)).intround.i64
            mainActor {
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(realDuration!.hmsString)"
            }
        }

        let videoURL = path.url
        let proc = try tryProc(FFMPEG.string, args: args, tries: 3, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: videoURL, optimiser: optimiser, duration: realDuration)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        outputPath.waitForFile(for: 2)
        outputPath.copyExif(from: path, stripMetadata: Defaults[.stripMetadata])
        try? outputPath.setOptimisationStatusXattr("true")

        if Defaults[.capVideoFPS], let fps, let new = newFPS, new > fps {
            newFPS = fps
        }
        let resultingSize = if let size, let cropSize {
            cropSize.computedSize(from: size)
        } else {
            newSize ?? size ?? .zero
        }
        let metadata = VideoMetadata(resolution: resultingSize, fps: newFPS ?? fps ?? 0)
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
    var duration: TimeInterval?
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
    let duration = try await track.load(.timeRange).duration
    return VideoMetadata(resolution: CGSize(width: abs(size.width), height: abs(size.height)), fps: fps, duration: duration.seconds)
}

let FFMPEG_DURATION_REGEX = try! Regex(#"^\s*Duration: (\d{2,}):(\d{2,}):(\d{2,}).(\d{2})"#, as: (Substring, Substring, Substring, Substring, Substring).self).anchorsMatchLineEndings(true)
let GIFSKI_FRAME_REGEX = try! Regex(#"Frame (\d+) / (\d+)"#, as: (Substring, Substring, Substring).self).anchorsMatchLineEndings(true)

@MainActor func updateProgressGifski(pipe: Pipe, url: URL, optimiser: Optimiser, frames: Int64) {
    /* Gifski output
         ^MFrame 1 / 88  _...........................................................  52s ^M1.2MB GIF; Frame 10 / 88  #####_...............  ......
          ......................  7s ^M786KB GIF; Frame 18 / 88  ##########_......................................  5s ^M671KB GIF; Frame 19  / 88
          ##########_......................................  6s ^M615KB GIF; Frame 34 / 88  ##################_..............................    3s
           ^M694KB GIF; Frame 39 / 88  #####################_...........................  3s ^M625KB GIF; Frame 51 / 88  ####################  ######
          ##_....................  2s ^M641KB GIF; Frame 62 / 88  ##################################_..............  1s ^M718KB GIF; Frame 70   / 88
           ######################################_..........  1s ^M850KB GIF; Frame 78 / 88  ###########################################_....  .  0
          s ^M970KB GIF; Frame 88 / 88  ###################################################   ^M970KB GIF; Frame 88 / 88  ###################  ######
          ##########################   ^Mgifski created /private/tmp/x.gif
     */

    mainActor {
        optimiser.progress = Progress(totalUnitCount: frames)
        optimiser.progress.fileURL = url
        optimiser.progress.localizedDescription = optimiser.operation
        optimiser.progress.localizedAdditionalDescription = "Frame 0 of \(optimiser.progress.totalUnitCount)"
        optimiser.progress.publish()
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            mainActor { optimiser.progress.unpublish() }
            return
        }
        guard let string = String(data: data.replacing([0x13], with: []), encoding: .utf8) else {
            return
        }

        let lines = string.components(separatedBy: "; ")
        for line in lines where line.starts(with: "Frame ") {
            guard let match = try? GIFSKI_FRAME_REGEX.firstMatch(in: line), let frame = Int64(match.1), frame > 0 else {
                continue
            }
            mainActor {
                optimiser.progress.completedUnitCount = min(frame, optimiser.progress.totalUnitCount)
                optimiser.progress.localizedAdditionalDescription = "Frame \(frame) of \(optimiser.progress.totalUnitCount)"
            }
        }

    }
}

@MainActor func updateProgressFFmpeg(pipe: Pipe, url: URL, optimiser: Optimiser, duration: Int64? = nil) {
    mainActor {
        optimiser.progress = Progress(totalUnitCount: duration ?? 100)
        optimiser.progress.fileURL = url
        optimiser.progress.localizedDescription = optimiser.operation
        if optimiser.progress.totalUnitCount == 100 {
            optimiser.progress.localizedAdditionalDescription = "Calculating duration"
        } else {
            optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(optimiser.progress.totalUnitCount.hmsString)"
        }
        optimiser.progress.publish()
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            mainActor { optimiser.progress.unpublish() }
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
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(optimiser.progress.totalUnitCount.hmsString)"
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
@MainActor func optimiseVideo(
    _ video: Video,
    copyToClipboard: Bool = false,
    id: String? = nil,
    debounceMS: Int = 0,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    noConversion: Bool = false,
    source: String? = nil
) async throws -> Video? {
    let path = video.path
    let pathString = path.string
    let itemType = ItemType.from(filePath: path)
    let optimiser = OM.optimiser(id: id ?? pathString, type: itemType, operation: debounceMS > 0 ? "Waiting for video to be ready" : "Optimising", hidden: hideFloatingResult, source: source)

    var done = false
    var result: Video?

    videoOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        optimiser.operation = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressiveOptimisation ?? false ? " (aggressive)" : "")
        optimiser.originalURL = path.url
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let fileSize = video.fileSize

        videoOptimisationQueue.addOperation {
            var optimisedVideo: Video?
            defer {
                mainActor { done = true }
            }

            do {
                mainActor { OM.current = optimiser }

                optimisedVideo = try video.optimise(optimiser: optimiser, forceMP4: !noConversion && Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie), aggressiveOptimisation: aggressiveOptimisation)
                if optimisedVideo!.convertedFrom == nil, optimisedVideo!.fileSize >= fileSize, !allowLarger {
                    video.path.restore(force: true)
                    mainActor {
                        optimiser.oldBytes = fileSize
                        optimiser.url = video.path.url
                    }

                    throw ClopError.videoSizeLarger(path)
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error optimising video \(pathString): \(proc.commandLine)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedVideo = video
            } catch let error as ClopError {
                log.error("Error optimising video \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error optimising video \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard let optimisedVideo else { return }
            mainActor {
                result = optimisedVideo
                optimiser.url = optimisedVideo.path.url
                optimiser.finish(oldBytes: fileSize, newBytes: optimisedVideo.fileSize, removeAfterMs: hideFilesAfter)
                if copyToClipboard {
                    optimiser.copyToClipboard()
                }
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
@MainActor func downscaleVideo(
    _ video: Video,
    originalPath: FilePath? = nil,
    copyToClipboard: Bool = false,
    id: String? = nil,
    toFactor factor: Double? = nil,
    cropTo cropSize: CropSize? = nil,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    noConversion: Bool = false,
    source: String? = nil
) async throws -> Video? {
    guard let resolution = video.size else {
        throw ClopError.videoError("Error getting resolution for \(video.path.string)")
    }

    let pathString = video.path.string
    videoOptimiseDebouncers[pathString]?.cancel()
    if let cropSize {
        scalingFactor = cropSize.factor(from: resolution)
    } else if let factor {
        scalingFactor = factor
    } else if let currentFactor = opt(id ?? pathString)?.downscaleFactor {
        scalingFactor = max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    } else {
        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
    }

    let itemType = ItemType.from(filePath: video.path)
    let scaleString = if let size = cropSize?.computedSize(from: resolution) {
        "\(size.width > 0 ? size.width.i.s : "Auto")×\(size.height > 0 ? size.height.i.s : "Auto")"
    } else {
        "\((scalingFactor * 100).intround)%"
    }

    let optimiser = OM.optimiser(id: id ?? pathString, type: itemType, operation: "Scaling to \(scaleString)", hidden: hideFloatingResult, source: source)
    let aggressive = aggressiveOptimisation ?? optimiser.aggresive
    if aggressive {
        optimiser.operation += " (aggressive)"
    }
    optimiser.remover = nil
    optimiser.inRemoval = false
    optimiser.stop(remove: false)
    optimiser.downscaleFactor = scalingFactor
    let changePlaybackSpeedFactor = optimiser.changePlaybackSpeedFactor

    var result: Video?
    var done = false

    let workItem = optimisationQueue.asyncAfter(ms: 500) {
        defer {
            mainActor { done = true }
        }

        var optimisedVideo: Video?
        let newSize = cropSize?.computedSize(from: resolution) ?? resolution.scaled(by: scalingFactor)
        let fileSize = video.fileSize
        do {
            optimisedVideo = try video.optimise(
                optimiser: optimiser,
                forceMP4: !noConversion && Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie),
                backup: false,
                resizeTo: newSize,
                cropTo: cropSize,
                changePlaybackSpeedBy: changePlaybackSpeedFactor,
                originalPath: originalPath,
                aggressiveOptimisation: aggressive
            )
            if optimisedVideo!.path.extension == video.path.extension, optimisedVideo!.path != video.path {
                let path = try optimisedVideo!.path.move(to: video.path, force: true)
                optimisedVideo = optimisedVideo?.copyWithPath(path)
            }
        } catch let ClopProcError.processError(proc) {
            if proc.terminated {
                log.debug("Process terminated by us: \(proc.commandLine)")
            } else {
                log.error("Error downscaling video \(pathString): \(proc.commandLine)")
                mainActor {
                    optimiser.finish(error: "Downscaling failed")
                }
            }
        } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
            optimisedVideo = video
        } catch let error as ClopError {
            log.error("Error downscaling video \(pathString): \(error.description)")
            mainActor { optimiser.finish(error: error.humanDescription) }
        } catch {
            log.error("Error downscaling video \(pathString): \(error)")
            mainActor { optimiser.finish(error: "Optimisation failed") }
        }

        guard let optimisedVideo else { return }
        mainActor {
            optimiser.url = optimisedVideo.path.url
            OM.current = optimiser
            optimiser.finish(oldBytes: fileSize, newBytes: optimisedVideo.fileSize, oldSize: resolution, newSize: newSize, removeAfterMs: hideFilesAfter)
            result = optimisedVideo
            if copyToClipboard {
                optimiser.copyToClipboard()
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
@MainActor func changePlaybackSpeedVideo(
    _ video: Video,
    originalPath: FilePath? = nil,
    copyToClipboard: Bool = false,
    id: String? = nil,
    byFactor factor: Double? = nil,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    noConversion: Bool = false,
    source: String? = nil
) async throws -> Video? {
    let pathString = video.path.string
    videoOptimiseDebouncers[pathString]?.cancel()

    let changePlaybackSpeedFactor: Double = if let factor {
        factor
    } else if let currentFactor = opt(id ?? pathString)?.changePlaybackSpeedFactor {
        min(currentFactor < 2 ? currentFactor + 0.25 : currentFactor + 1.0, 10)
    } else {
        1.25
    }

    let itemType = ItemType.from(filePath: video.path)
    let optimiser = OM.optimiser(
        id: id ?? pathString,
        type: itemType,
        operation: changePlaybackSpeedFactor > 1
            ? "Speeding up by \(changePlaybackSpeedFactor < 2 ? changePlaybackSpeedFactor.str(decimals: 2) : changePlaybackSpeedFactor.i.s)x"
            : (
                changePlaybackSpeedFactor == 1
                    ? "Reverting to original speed"
                    : "Slowing down by \(changePlaybackSpeedFactor < 2 ? changePlaybackSpeedFactor.str(decimals: 2) : changePlaybackSpeedFactor.i.s)x"
            ),
        hidden: hideFloatingResult, source: source
    )
    let aggressive = aggressiveOptimisation ?? optimiser.aggresive
    if aggressive {
        optimiser.operation += " (aggressive)"
    }
    optimiser.remover = nil
    optimiser.inRemoval = false
    optimiser.stop(remove: false)
    optimiser.changePlaybackSpeedFactor = changePlaybackSpeedFactor

    var result: Video?
    var done = false

    let resolution = optimiser.newSize
    let workItem = optimisationQueue.asyncAfter(ms: 500) {
        defer {
            mainActor { done = true }
        }

        var optimisedVideo: Video?
        let fileSize = video.fileSize
        do {
            optimisedVideo = try video.optimise(
                optimiser: optimiser,
                forceMP4: !noConversion && Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie),
                backup: false,
                resizeTo: resolution,
                changePlaybackSpeedBy: changePlaybackSpeedFactor,
                originalPath: originalPath,
                aggressiveOptimisation: aggressive
            )
            if optimisedVideo!.path.extension == video.path.extension, optimisedVideo!.path != video.path {
                let path = try optimisedVideo!.path.move(to: video.path, force: true)
                optimisedVideo = optimisedVideo?.copyWithPath(path)
            }
        } catch let ClopProcError.processError(proc) {
            if proc.terminated {
                log.debug("Process terminated by us: \(proc.commandLine)")
            } else {
                log.error("Error downscaling video \(pathString): \(proc.commandLine)")
                mainActor {
                    optimiser.finish(error: "Downscaling failed")
                }
            }
        } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
            optimisedVideo = video
        } catch let error as ClopError {
            log.error("Error downscaling video \(pathString): \(error.description)")
            mainActor { optimiser.finish(error: error.humanDescription) }
        } catch {
            log.error("Error downscaling video \(pathString): \(error)")
            mainActor { optimiser.finish(error: "Optimisation failed") }
        }

        guard let optimisedVideo else { return }
        mainActor {
            optimiser.url = optimisedVideo.path.url
            OM.current = optimiser
            optimiser.finish(oldBytes: fileSize, newBytes: optimisedVideo.fileSize, removeAfterMs: hideFilesAfter)
            result = optimisedVideo
            if copyToClipboard {
                optimiser.copyToClipboard()
            }
        }
    }
    videoOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }

    return result
}
