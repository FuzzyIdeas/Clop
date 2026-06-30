import AVFoundation
import Cocoa
import CoreTransferable
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Video")

var FFMPEG = BIN_DIR.appendingPathComponent("ffmpeg").filePath!
var GIFSKI = BIN_DIR.appendingPathComponent("gifski").filePath!

extension Double {
    var i64: Int64 {
        Int64(self)
    }
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
            Task {
                self.metadata = try? await getVideoMetadata(path: path)
                await MainActor.run {
                    if let optimiser, optimiser.oldSize == nil {
                        optimiser.oldSize = self.size
                    }
                }
            }
        }
    }

    required convenience init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.init(path: path, thumb: thumb, id: id)
    }

    override class var dir: FilePath {
        .videos
    }

    var convertedFrom: Video?
    var metadata: VideoMetadata?

    var size: CGSize? {
        metadata?.resolution
    }
    var duration: TimeInterval? {
        metadata?.duration
    }
    var fps: Float? {
        guard let fps = metadata?.fps, fps > 0 else { return nil }
        return fps
    }
    var hasAudio: Bool {
        metadata?.hasAudio ?? false
    }

    override func copyWithPath(_ path: FilePath) -> Self {
        Video(path: path, metadata: metadata, fileSize: path.fileSize() ?? fileSize, convertedFrom: convertedFrom, thumb: true, id: id) as! Self
    }

    static func byFetchingMetadata(path: FilePath, fileSize: Int? = nil, convertedFrom: Video? = nil, thumb: Bool = true, id: String? = nil) async throws -> Video? {
        let metadata = try await getVideoMetadata(path: path)
        let video = Video(path: path, metadata: metadata, fileSize: fileSize, convertedFrom: convertedFrom, thumb: thumb, id: id)

        await MainActor.run {
            if let optimiser = video.optimiser, optimiser.oldSize == nil, let metadata {
                optimiser.oldSize = metadata.resolution
            }
        }

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
                let bits = (size.area.i &* max(duration.intround, 0) &* fileSize)
                return bits < 1920 * 1080 * 10 * 5_000_000 && bits > 500_000
            }
            return (size?.area.i ?? Int.max) < (1920 * 1080) || (metadata?.duration ?? 999_999) < 10 || fileSize < 5_000_000
        }
    #endif

    func convertToGIF(optimiser: Optimiser, maxWidth: Int, fps: Int) throws -> Image {
        log.debug("Converting video \(self.path.string) to GIF")
        let tempDir = URL.temporaryDirectory.appendingPathComponent("\(path.stem!)_gif_pngs").filePath!
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
            args: ["-o", gif.string, "--width", maxWidth.s, "--fps", fps.s, "--quality", Defaults[.useAggressiveOptimisationGIF] ? 60.s : 90.s] + pngs.map(\.string),
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
            // Record the originating video BEFORE overwriting url, so "Restore original" can revert
            // the GIF back to the source video. Covers both callers (convert button and right-click
            // "Convert to GIF"), which previously captured the GIF path because they set this afterwards.
            if optimiser.convertedFromURL == nil {
                optimiser.convertedFromURL = optimiser.url
            }
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

        if let cropRect = cropSize.cropRect, !cropRect.isFullFrame {
            // relative expressions let ffmpeg crop the backup original, whose pixel size can
            // differ from the displayed file; even dimensions are required by most encoders
            let r = cropRect.clamped()
            var filters = [String(
                format: "crop=floor(in_w*%.6f/2)*2:floor(in_h*%.6f/2)*2:in_w*%.6f:in_h*%.6f",
                r.width, r.height, r.x, r.y
            )]

            let target = cropSize.ns
            if target.width > 0, target.height > 0 {
                filters.append("scale=w=\(target.width.evenInt):h=\(target.height.evenInt)")
            }
            return filters
        }

        let s = cropSize.isAspectRatio ? cropSize.computedSize(from: fromSize) : cropSize.ns
        guard s.width > 0, s.height > 0, !cropSize.longEdge || cropSize.isAspectRatio else {
            // crop by specifying only one size, keeping aspect ratio
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

    func removeAudio(optimiser: Optimiser) throws {
        let outputPath = URL.temporaryDirectory.appendingPathComponent("\(path.stem!)_no_audio.\(path.extension!)").filePath!
        let args = ["-y", "-i", path.string, "-an", "-vcodec", "copy", "-movflags", "+faststart", "-progress", "pipe:2", "-nostats", "-hide_banner", "-stats_period", "0.1", outputPath.string]
        let url = path.url
        let proc = try tryProc(FFMPEG.string, args: args, tries: 3, captureOutput: true) { proc in
            mainActor {
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: url, optimiser: optimiser)
            }
        }
        proc.waitUntilExit()

        outputPath.waitForFile(for: 2)
        outputPath.copyExif(from: path, stripMetadata: Defaults[.stripMetadata])
        if Defaults[.preserveDates] {
            outputPath.copyCreationModificationDates(from: path)
        }
        try? outputPath.setOptimisationStatusXattr("true")
        try outputPath.move(to: path, force: true)
    }

    func optimise(
        optimiser: Optimiser,
        forceMP4: Bool = false,
        outputExtension: String? = nil,
        backup: Bool = true,
        resizeTo newSize: CGSize? = nil,
        cropTo cropSize: CropSize? = nil,
        changePlaybackSpeedBy changePlaybackSpeedFactor: Double? = nil,
        originalPath: FilePath? = nil,
        aggressiveOptimisation: Bool? = nil,
        removeAudio: Bool? = nil,
        encoderOverride: [String]? = nil,
        videoEncoderOverride: VideoEncoder? = nil,
        fpsOverride: Int? = nil,
        manualConversion: Bool = false
    ) throws -> Video {
        log.debug("Optimising video \(self.path.string)")
        guard let name = path.lastComponent else {
            log.error("No file name for path: \(self.path)")
            throw ClopError.fileNotFound(path)
        }

        path.waitForFile(for: 3)
        try? path.setOptimisationStatusXattr("pending")

        let outputPath: FilePath = if let outputExtension {
            FilePath.videos.appending("\(name.stem).\(outputExtension)")
        } else if forceMP4 {
            FilePath.videos.appending("\(name.stem).mp4")
        } else {
            path
        }
        var inputPath = originalPath ?? ((path == outputPath || backup) ? (path.backup(path: path.clopBackupPath, operation: .copy) ?? path) : path)
        var additionalArgs = [String]()

        var newFPS = fps
        if let fpsOverride {
            newFPS = Float(fpsOverride)
            additionalArgs += ["-fpsmax", "\(fpsOverride)"]
        } else if Defaults[.capVideoFPS] {
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
        let audioRemoved = removeAudio ?? Defaults[.removeAudioFromVideos]
        let convertAudioToAAC = Defaults[.convertAudioToAAC]
        // Source of truth for the default H.264 encode: the unified compression value. An explicit
        // VideoEncoder override (from a pipeline/button) maps onto a tier; otherwise use the setting.
        let cq: CompressionQuality = optimiser.compressionOverride ?? videoEncoderOverride.map { videoEncoderToCQ($0) } ?? Defaults[.videoCompression]
        let aggressive = aggressiveOptimisation ?? false
        mainActor { optimiser.aggressive = aggressive }

        // The "Adaptive" choice picks the best encoder per file: hardware for small/short clips,
        // efficient software for larger ones (arm64). On Intel there's no VideoToolbox, so software.
        let resolvedCQ: CompressionQuality = {
            guard videoEncoderOverride == nil, cq.tier == .adaptive else { return cq }
            #if arch(arm64)
                return CompressionQuality(tier: useAggressiveOptimisation(aggressiveSetting: false) ? .smaller : .fast, factor: cq.factor)
            #else
                return CompressionQuality(tier: .smaller, factor: cq.factor)
            #endif
        }()

        let encoderArgs: [String] = encoderOverride ?? {
            if aggressive {
                return ["-vcodec", "h264", "-tag:v", "avc1", "-preset", "veryslow", "-crf", "28"]
            }
            return resolvedCQ.videoH264Args()
        }()
        let outExt = outputPath.extension?.lowercased() ?? ""
        let isWebm = outExt == "webm"
        let audioArgs: [String] = if audioRemoved {
            ["-an"]
        } else if isWebm {
            ["-c:a", "libopus", "-b:a", "128k", "-map", "0:v", "-map", "0:a?"]
        } else if convertAudioToAAC {
            ["-c:a", "aac", "-b:a", "192k", "-map", "0:v", "-map", "0:a?"]
        } else {
            ["-c:a", "copy", "-map", "0:v", "-map", "0:a?"]
        }
        let useEncoder = encoderOverride != nil || ["mp4", "mov", "hevc"].contains(outExt)
        var args = ["-y", "-i", inputPath.string]
        if useEncoder { args += encoderArgs }
        args += audioArgs + additionalArgs
        if !isWebm { args += ["-movflags", "+faststart"] }
        args += ["-progress", "pipe:2", "-nostats", "-hide_banner", "-stats_period", "0.1", outputPath.string]

        var realDuration: Int64?
        if let duration {
            realDuration = ((duration * 1_000_000) / (changePlaybackSpeedFactor ?? 1)).intround.i64
            mainActor {
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(realDuration!.hmsString)"
            }
        }

        var args2 = args
        var args3 = args
        if let mapArgsRange = args.firstRange(of: ["-map", "0:v", "-map", "0:a?"]) {
            args2.removeSubrange(mapArgsRange)
        }
        if let mapArgsRange = args.firstRange(of: ["-c:a", "copy", "-map", "0:v", "-map", "0:a?"]) {
            args3.removeSubrange(mapArgsRange)
        }
        let argArray = [args, args2, args3]

        let videoURL = path.url
        let proc = try tryProc(FFMPEG.string, argArray: argArray, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: videoURL, optimiser: optimiser, duration: realDuration)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        outputPath.waitForFile(for: 2)
        outputPath.copyExif(from: inputPath, stripMetadata: Defaults[.stripMetadata])
        if Defaults[.preserveDates] {
            outputPath.copyCreationModificationDates(from: inputPath)
        }
        try? outputPath.setOptimisationStatusXattr("true")

        if Defaults[.capVideoFPS], let fps, let new = newFPS, new > fps {
            newFPS = fps
        }
        let resultingSize = if let size, let cropSize {
            cropSize.computedSize(from: size)
        } else {
            newSize ?? size ?? .zero
        }
        let metadata = VideoMetadata(
            resolution: resultingSize, fps: newFPS ?? fps ?? 0,
            hasAudio: audioRemoved ? false : hasAudio
        )
        let convertedFrom = forceMP4 && inputPath.extension?.lowercased() != "mp4" ? self : nil
        var newVideo = Video(path: outputPath, metadata: metadata, convertedFrom: convertedFrom)

        if let convertedFrom, convertedFrom.path.exists {
            // placeOutput is @MainActor; dispatch synchronously so we can use the result
            // here on the background optimisation queue thread.
            let kind: OutputKind = manualConversion ? .manualConvert : .autoConvert
            let placedResult: Result<PlacedOutput, Error> = DispatchQueue.main.sync {
                Result { try placeOutput(produced: newVideo.path, original: convertedFrom.path, type: .video, kind: kind, overrides: optimiser.placementOverride) }
            }
            let placed = try placedResult.get()
            if placed.path != newVideo.path {
                newVideo = Video(path: placed.path, metadata: metadata, convertedFrom: convertedFrom)
            }
            mainActor {
                optimiser.convertedFromURL = (placed.backup ?? convertedFrom.path).url
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
    let hasAudio: Bool
}

func videoHasAudio(path: FilePath) async throws -> Bool {
    let avAsset = AVURLAsset(url: path.url)
    let tracks = try await avAsset.load(.tracks)
    return tracks.contains(where: { $0.mediaType == .audio })
}

func isVideoValid(path: FilePath) async throws -> Bool {
    let avAsset = AVURLAsset(url: path.url)
    _ = try await avAsset.load(.tracks)
    return try await avAsset.loadTracks(withMediaType: .video).first != nil
}

func getVideoMetadata(path: FilePath) async throws -> VideoMetadata? {
    let avAsset = AVURLAsset(url: path.url)
    let tracks = try await avAsset.load(.tracks)
    guard let track = try await avAsset.loadTracks(withMediaType: .video).first else {
        return nil
    }
    var size = try await track.load(.naturalSize)
    if let transform = try? await track.load(.preferredTransform) {
        size = size.applying(transform)
    }
    let fps = try await track.load(.nominalFrameRate)
    let duration = try await track.load(.timeRange).duration
    return VideoMetadata(resolution: CGSize(width: abs(size.width), height: abs(size.height)), fps: fps, duration: duration.seconds, hasAudio: tracks.contains(where: { $0.mediaType == .audio }))
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
        optimiser.publishProgress()
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            mainActor { optimiser.unpublishProgress() }
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
        optimiser.publishProgress()
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            mainActor { optimiser.unpublishProgress() }
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
        for line in lines where line.trimmed.isNotEmpty {
            guard line.starts(with: "out_time_us="), let time = Int64(line.suffix(line.count - 12)), time > 0 else {
                if !FFMPEG_IGNORE_LINES.contains(where: line.starts(with:)) {
                    log.trace("FFmpeg: \(line)")
                }
                continue
            }
            mainActor {
                optimiser.progress.completedUnitCount = min(time, optimiser.progress.totalUnitCount)
                optimiser.progress.localizedAdditionalDescription = "\(time.hmsString) of \(optimiser.progress.totalUnitCount.hmsString)"
            }
        }
    }
}

let FFMPEG_IGNORE_LINES = [
    "bitrate=",
    "drop_frames=",
    "dup_frames=",
    "fps=",
    "frame=",
    "out_time_ms=",
    "out_time_us=",
    "out_time=",
    "progress=",
    "speed=",
    "stream_0_0_q=",
    "total_size=",
]

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

    guard let optimiser = opt(path.string) else {
        return
    }
    optimiser.stop(animateRemoval: false)
    optimiser.remove(after: 0, withAnimation: false)
}

@MainActor func shouldHandleVideo(event: EonilFSEventsEvent) async -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          VIDEO_EXTENSIONS.contains(ext), !Defaults[.videoFormatsToSkip].lazy.compactMap(\.preferredFilenameExtension).contains(ext)
    else {
        return false

    }

    log.debug("\(path.shellString): \(flag)")

    // Run the blocking filesystem checks (xattr read, size stat) off the main actor; the FSEvents
    // callback is on the main thread, so doing them here would hang the UI on a burst of events or a
    // slow/network volume (ANR). The debouncer bookkeeping stays on the main actor below.
    let eventPath = event.path
    let io = await Task.detached { () -> (passes: Bool, exists: Bool) in
        let exists = fm.fileExists(atPath: eventPath)
        guard exists, !eventPath.contains(FilePath.clopBackups.string),
              flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
              !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0,
              Defaults[.maxVideoSizeMB] == 0 || size < Defaults[.maxVideoSizeMB] * 1_000_000,
              Defaults[.minVideoSizeKB] == 0 || size >= Defaults[.minVideoSizeKB] * 1000
        else {
            return (false, exists)
        }
        return (true, exists)
    }.value

    guard io.passes else {
        if flag.contains(.itemRemoved) || !io.exists {
            videoOptimiseDebouncers[event.path]?.cancel()
            videoOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    guard videoOptimiseDebouncers[event.path] == nil else { return false }
    return true
}
