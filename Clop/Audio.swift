//
//  Audio.swift
//  Clop
//
//  Created by Alin Panaitiu on 19.03.2026.
//

import AppKit
import AVFoundation
import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Audio")

extension CompressionQuality {
    /// Target bitrate (kbps) for an audio format. factor 5 -> highest bitrate (best quality),
    /// factor 100 -> lowest (most compressed). Mapped continuously over the format's
    /// quality-aware range so the percentage yields finely-stepped bitrates; the actual kbps
    /// differs per codec (Opus needs the fewest for the same quality, then AAC, then MP3).
    /// Returns nil for lossless/empty formats (WAV); those have no bitrate axis.
    func audioBitrate(for format: AudioFormat) -> Int? {
        guard let (lo, hi) = format.bitrateRange, hi > lo else { return nil }
        let t = Double(min(100, max(5, factor)) - 5) / 95.0
        let raw = Double(hi) - t * Double(hi - lo)
        return min(hi, max(lo, roundedAudioBitrate(raw)))
    }
}

/// Round a raw kbps figure to the nearest 16 so the slider surfaces familiar bitrates.
/// The common ones (96, 128, 160, 192, 224, 256, 320) are all multiples of 16, while
/// still allowing in-between values (144, 176, 208, …) nudged to the closest round number.
func roundedAudioBitrate(_ raw: Double) -> Int {
    max(8, Int((raw / 16).rounded()) * 16)
}

/// Inverse of `CompressionQuality.audioBitrate(for:)`: the nearest 5..100 factor for a bitrate.
func audioCompressionFactor(forBitrate bitrate: Int, format: AudioFormat) -> Int {
    guard let (lo, hi) = format.bitrateRange, hi > lo, bitrate > 0 else { return 35 }
    let clamped = Double(min(hi, max(lo, bitrate)))
    let t = (Double(hi) - clamped) / Double(hi - lo)
    return min(100, max(5, Int((5 + t * 95).rounded())))
}

struct AudioMetadata {
    let duration: TimeInterval?
    let bitrate: Int?
    let sampleRate: Double?
    let codec: String?
}

class Audio: Optimisable {
    init(path: FilePath, metadata: AudioMetadata? = nil, fileSize: Int? = nil, thumb: Bool = true, id: String? = nil) {
        super.init(path, thumb: thumb, id: id)

        if let fileSize {
            self.fileSize = fileSize
        }

        if let metadata {
            self.metadata = metadata
        } else {
            Task {
                self.metadata = try? await getAudioMetadata(path: path)
                await MainActor.run {
                    if let optimiser = self.optimiser, optimiser.oldBitrate == nil, let kbps = self.bitrate {
                        optimiser.oldBitrate = kbps
                    }
                }
            }
        }
    }

    required convenience init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.init(path: path, thumb: thumb, id: id)
    }

    override class var dir: FilePath {
        .audios
    }

    var metadata: AudioMetadata?

    var duration: TimeInterval? {
        metadata?.duration
    }
    var bitrate: Int? {
        metadata?.bitrate
    }
    var sampleRate: Double? {
        metadata?.sampleRate
    }
    var codec: String? {
        metadata?.codec
    }

    /// Resolve the output format for this audio (honouring `.sameAsInput`).
    var outputFormat: AudioFormat {
        Defaults[.audioFormat].resolved(forInputExtension: path.extension ?? "")
    }

    override func copyWithPath(_ path: FilePath) -> Self {
        Audio(path: path, metadata: metadata, fileSize: path.fileSize() ?? fileSize, thumb: true, id: id) as! Self
    }

    static func byFetchingMetadata(path: FilePath, fileSize: Int? = nil, thumb: Bool = true, id: String? = nil) async throws -> Audio? {
        let metadata = try await getAudioMetadata(path: path)
        let audio = Audio(path: path, metadata: metadata, fileSize: fileSize, thumb: thumb, id: id)

        await MainActor.run {
            if let optimiser = audio.optimiser, optimiser.oldBitrate == nil, let kbps = metadata?.bitrate {
                optimiser.oldBitrate = kbps
            }
        }

        return audio
    }

    /// Compute a target bitrate that is at most `kbps`, never exceeds the input bitrate,
    /// and is snapped to an allowed bitrate for the output format. Returns nil if lowering
    /// would be a no-op (e.g. input bitrate is already at or below the target).
    func loweredBitrate(kbps: Int) -> Int? {
        outputFormat.loweredBitrate(target: kbps, inputBitrate: bitrate)
    }

    /// Compute a target bitrate by multiplying the input bitrate by `factor` (0-1),
    /// then clamping/snapping the same way as `loweredBitrate(kbps:)`. Returns nil if
    /// the factor is >= 1 (never upscales) or if lowering would be a no-op.
    func loweredBitrate(factor: Double) -> Int? {
        guard factor > 0, factor < 1 else { return nil }
        let input = bitrate ?? outputFormat.defaultBitrate
        guard input > 0 else { return nil }
        let target = Int((Double(input) * factor).rounded())
        return outputFormat.loweredBitrate(target: target, inputBitrate: input)
    }

    func optimise(
        optimiser: Optimiser,
        bitrateOverride: Int? = nil,
        aggressive: Bool = false,
        formatOverride: AudioFormat? = nil,
        loudnormTarget: Double? = nil,
        coverArtBehaviour: AudioCoverArtBehaviour? = nil,
        coverArtMaxLongEdge: Int? = nil
    ) throws -> Audio {
        log.debug("Optimising audio \(self.path.string)")
        guard let name = path.lastComponent else {
            log.error("No file name for path: \(self.path)")
            throw ClopError.fileNotFound(path)
        }

        path.waitForFile(for: 3)
        try? path.setOptimisationStatusXattr("pending")

        let format = formatOverride ?? Defaults[.audioFormat].resolved(forInputExtension: path.extension ?? "")
        let rawBitrate = bitrateOverride ?? (optimiser.compressionOverride ?? Defaults[.audioCompression]).audioBitrate(for: format) ?? Defaults[.audioBitrate]
        var bitrate = format.resolveBitrate(rawBitrate, inputBitrate: bitrate)
        // Aggressive must actually shrink: for lossy formats force at least one allowed step below the
        // source bitrate, otherwise re-encoding at the same (or capped) bitrate would be a no-op.
        if aggressive, !format.allowedBitrates.isEmpty {
            bitrate = min(bitrate, format.resolveBitrate(-1, inputBitrate: self.bitrate))
        }
        let outputPath = FilePath.audios.appending("\(name.stem).\(format.fileExtension)")
        let inputPath = path.backup(path: path.clopBackupPath, operation: .copy) ?? path
        var args = ["-y", "-i", inputPath.string]
        args += audioCoverArtArgs(input: inputPath, format: format, stem: name.stem, behaviour: coverArtBehaviour ?? Defaults[.audioCoverArt], maxLongEdge: coverArtMaxLongEdge)
        args += format.encodingArgs(bitrate: bitrate, aggressive: aggressive, inputSampleRate: sampleRate)
        if let loudnormTarget {
            // loudnorm resamples to 192 kHz in single-pass mode, which the AudioToolbox AAC encoder
            // (aac_at) rejects with a "fmt?" error; resample back to the input rate so encoding works.
            let resampleRate = sampleRate.flatMap { $0 > 0 ? Int($0) : nil } ?? 48000
            args += ["-af", "loudnorm=I=\(loudnormTarget):TP=-1.5:LRA=11,aresample=\(resampleRate)"]
        }
        args += [
            "-progress", "pipe:2",
            "-nostats", "-hide_banner", "-stats_period", "0.1",
            outputPath.string,
        ]

        var realDuration: Int64?
        if let duration {
            realDuration = (duration * 1_000_000).intround.i64
            mainActor {
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(realDuration!.hmsString)"
            }
        }

        let audioURL = path.url
        let proc = try tryProc(FFMPEG.string, args: args, tries: 1, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: audioURL, optimiser: optimiser, duration: realDuration)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        outputPath.waitForFile(for: 2)
        if Defaults[.preserveDates] {
            outputPath.copyCreationModificationDates(from: inputPath)
        }
        try? outputPath.setOptimisationStatusXattr("true")

        let newAudio = Audio(path: outputPath, metadata: AudioMetadata(
            duration: duration,
            bitrate: bitrate,
            sampleRate: sampleRate,
            codec: format.ffmpegCodec
        ), fileSize: outputPath.fileSize(), thumb: false)

        let inputExtension = path.extension?.lowercased()
        let sameFormat = inputExtension == format.fileExtension
            || (inputExtension == "m4a" && format == .aac)
            || (inputExtension == "ogg" && format == .opus)
            || (inputExtension == "opus" && format == .opus)
        if sameFormat, newAudio.fileSize >= fileSize {
            throw ClopError.audioSizeLarger(path)
        }

        return newAudio
    }

    func changeSpeed(factor: Double, optimiser: Optimiser) throws -> Audio {
        log.debug("Changing audio speed to \(factor)x for \(self.path.string)")
        guard let name = path.lastComponent else {
            throw ClopError.fileNotFound(path)
        }

        let ext = path.extension ?? "m4a"
        let outputPath = FilePath.audios.appending("\(name.stem)-speed\(factor)x.\(ext)")
        let inputPath = path

        // atempo filter accepts values between 0.5 and 100.0
        // For values < 0.5, chain multiple atempo filters
        var atempoFilters: [String] = []
        var remaining = factor
        while remaining < 0.5 {
            atempoFilters.append("atempo=0.5")
            remaining /= 0.5
        }
        while remaining > 100.0 {
            atempoFilters.append("atempo=100.0")
            remaining /= 100.0
        }
        atempoFilters.append("atempo=\(remaining)")

        let filterStr = atempoFilters.joined(separator: ",")

        let args = [
            "-y", "-i", inputPath.string,
            "-vn",
            "-filter:a", filterStr,
            "-progress", "pipe:2",
            "-nostats", "-hide_banner", "-stats_period", "0.1",
            outputPath.string,
        ]

        var realDuration: Int64?
        if let duration {
            realDuration = (duration / factor * 1_000_000).intround.i64
            mainActor {
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(realDuration!.hmsString)"
            }
        }

        let audioURL = path.url
        let proc = try tryProc(FFMPEG.string, args: args, tries: 1, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: audioURL, optimiser: optimiser, duration: realDuration)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        outputPath.waitForFile(for: 2)
        if Defaults[.preserveDates] {
            outputPath.copyCreationModificationDates(from: inputPath)
        }
        try? outputPath.setOptimisationStatusXattr("true")

        let newDuration = duration.map { $0 / factor }
        return Audio(path: outputPath, metadata: AudioMetadata(
            duration: newDuration,
            bitrate: bitrate,
            sampleRate: sampleRate,
            codec: codec
        ), fileSize: outputPath.fileSize(), thumb: false)
    }

    func convert(to format: AudioFormat, optimiser: Optimiser) throws -> Audio {
        log.debug("Converting audio \(self.path.string) to \(format.name)")
        guard let name = path.lastComponent else {
            throw ClopError.fileNotFound(path)
        }

        let bitrate = format.defaultBitrate
        let outputPath = FilePath.audios.appending("\(name.stem).\(format.fileExtension)")
        let inputPath = path

        var args = ["-y", "-i", inputPath.string]
        args += audioCoverArtArgs(input: inputPath, format: format, stem: name.stem, behaviour: Defaults[.audioCoverArt])
        args += format.encodingArgs(bitrate: bitrate)
        args += [
            "-progress", "pipe:2",
            "-nostats", "-hide_banner", "-stats_period", "0.1",
            outputPath.string,
        ]

        var realDuration: Int64?
        if let duration {
            realDuration = (duration * 1_000_000).intround.i64
            mainActor {
                optimiser.progress.localizedAdditionalDescription = "\(0.i64.hmsString) of \(realDuration!.hmsString)"
            }
        }

        let audioURL = path.url
        let proc = try tryProc(FFMPEG.string, args: args, tries: 1, captureOutput: true) { proc in
            mainActor {
                optimiser.processes = [proc]
                updateProgressFFmpeg(pipe: proc.standardError as! Pipe, url: audioURL, optimiser: optimiser, duration: realDuration)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        outputPath.waitForFile(for: 2)
        try? outputPath.setOptimisationStatusXattr("true")

        return Audio(path: outputPath, metadata: AudioMetadata(
            duration: duration,
            bitrate: bitrate,
            sampleRate: sampleRate,
            codec: format.ffmpegCodec
        ), fileSize: outputPath.fileSize(), thumb: false)
    }
}

func getAudioMetadata(path: FilePath) async throws -> AudioMetadata? {
    let avAsset = AVURLAsset(url: path.url)
    let tracks = try await avAsset.load(.tracks)
    guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
        return nil
    }
    let duration = try await avAsset.load(.duration).seconds
    let estimatedDataRate = try await track.load(.estimatedDataRate)
    let bitrate = estimatedDataRate > 0 ? Int(estimatedDataRate / 1000) : nil

    var sampleRate: Double?
    let descriptions = try await track.load(.formatDescriptions)
    if let desc = descriptions.first {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        sampleRate = asbd?.pointee.mSampleRate
    }

    let codec = descriptions.first.flatMap { desc -> String? in
        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
        return String(describing: mediaSubType)
    }

    return AudioMetadata(duration: duration, bitrate: bitrate, sampleRate: sampleRate, codec: codec)
}

/// Build the ffmpeg argument block (inserted right after `-i <input>`) that applies the user's
/// cover-art behaviour to an audio re-encode. For `.optimise` it extracts the embedded artwork
/// losslessly and recompresses it with Clop's image optimisers, then returns it as a second input
/// to re-attach. Returns `["-vn"]` (strip art) when the format can't carry art, the behaviour is
/// `.remove`, or no artwork is found.
func audioCoverArtArgs(input: FilePath, format: AudioFormat, stem: String, behaviour: AudioCoverArtBehaviour, maxLongEdge: Int? = nil) -> [String] {
    guard behaviour != .remove, format.supportsCoverArt else {
        return ["-vn"]
    }

    if behaviour == .keep {
        // Copy the original art stream untouched; `?` keeps the map optional so art-less files still encode.
        return ["-map", "0:a", "-map", "0:v?", "-c:v", "copy"]
    }

    guard let cover = optimisedAudioCoverArt(input: input, stem: stem, maxLongEdge: maxLongEdge) else {
        // No embedded art (or extraction failed): nothing to optimise, strip cleanly.
        return ["-vn"]
    }
    var args = ["-i", cover.string, "-map", "0:a", "-map", "1:v", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
    if format == .mp3 {
        args += ["-id3v2_version", "3"]
    }
    return args
}

/// jpegli quality (via the bundled jpegli-backed jpegoptim) for aggressive cover-art recompression.
/// 68 is the validated sweet spot: near-visually-lossless album art at a fraction of the size.
let AUDIO_COVER_JPEG_QUALITY = 68

/// Shannon-entropy gate above which a PNG cover is worth trying as a JPEG (photographic art has high
/// entropy and shrinks far more as JPEG; flat graphics stay smaller as PNG). Mirrors the `< 5`
/// threshold Clop's image adaptive optimisation uses for the opposite JPEG→PNG decision.
let COVER_JPEG_ENTROPY_THRESHOLD = 5.0

/// Recompress a JPEG cover in place with the bundled jpegli-backed jpegoptim at the aggressive
/// cover-art quality. Shared by the JPEG path and the adaptive PNG→JPEG trial.
func optimiseCoverJPEG(_ path: FilePath) {
    #if arch(arm64)
        let archArgs = ["--auto-mode"]
    #else
        let archArgs: [String] = []
    #endif
    _ = try? tryProc(JPEGOPTIM.string, args: ["--strip-all", "--force", "--max", "\(AUDIO_COVER_JPEG_QUALITY)"] + archArgs + [path.string], tries: 2, captureOutput: true)
}

/// Extract the embedded cover art as losslessly as possible (copy the original encoded bytes, no
/// transcode and no resize) into a temp file named by its real format (.jpg/.png sniffed from the
/// header bytes, .img when unknown). Returns nil when there's no artwork or extraction fails.
/// Shared by the optimise pass and the "Extract cover art" action.
func extractedAudioCoverArt(input: FilePath, stem: String) -> FilePath? {
    let token = "\(stem)-cover-\(Int.random(in: 100 ... 100_000))"
    let rawPath = FilePath.images.appending("\(token).img")
    try? rawPath.delete()

    // Lossless extraction: copy the original encoded packet straight out, no re-encode or resize.
    guard let proc = try? tryProc(FFMPEG.string, args: [
        "-y", "-i", input.string, "-an", "-map", "0:v:0", "-c:v", "copy", "-f", "image2", rawPath.string,
    ], tries: 1, captureOutput: true),
    proc.terminationStatus == 0, let data = fm.contents(atPath: rawPath.string), !data.isEmpty
    else {
        try? rawPath.delete()
        return nil
    }

    // The container reports the codec, not the extension, so sniff the header to name the file.
    let ext: String? = if data.starts(with: [0xFF, 0xD8, 0xFF] as [UInt8]) {
        "jpg"
    } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47] as [UInt8]) {
        "png"
    } else {
        nil
    }
    guard let ext else { return rawPath }
    let coverPath = FilePath.images.appending("\(token).\(ext)")
    return (try? rawPath.move(to: coverPath, force: true)) != nil ? coverPath : rawPath
}

/// Downsize an extracted cover image in place to a max long edge, preserving its format (so the
/// header sniffing in `optimisedAudioCoverArt` still picks the right recompression path).
func resizeCoverArt(_ path: FilePath, maxLongEdge: Int) {
    guard maxLongEdge > 0, let data = fm.contents(atPath: path.string), let image = NSImage(data: data) else { return }
    let px = image.realSize
    let longEdge = max(px.width, px.height)
    guard longEdge > CGFloat(maxLongEdge) else { return }

    let scale = CGFloat(maxLongEdge) / longEdge
    let target = CGSize(width: (px.width * scale).rounded(), height: (px.height * scale).rounded())
    guard let resized = image.resize(to: target),
          let tiff = resized.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return }

    let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF] as [UInt8])
    let out = isJPEG
        ? rep.representation(using: .jpeg, properties: [.compressionFactor: 1.0])
        : rep.representation(using: .png, properties: [:])
    if let out { try? out.write(to: path.url) }
}

/// Extract the embedded cover art losslessly, then recompress it in place at aggressive settings
/// while keeping the original resolution. JPEG art goes through jpegoptim (jpegli); PNG art through
/// pngquant, with an adaptive PNG→JPEG trial for photographic covers. Returns the temp file, or nil
/// when the input has no artwork or extraction fails.
func optimisedAudioCoverArt(input: FilePath, stem: String, maxLongEdge: Int? = nil) -> FilePath? {
    guard let coverPath = extractedAudioCoverArt(input: input, stem: stem) else { return nil }
    if let maxLongEdge { resizeCoverArt(coverPath, maxLongEdge: maxLongEdge) }
    guard let data = fm.contents(atPath: coverPath.string) else { return nil }

    let cq = CompressionQuality(tier: .custom, factor: COMPRESSION_FACTOR_AGGRESSIVE)

    if data.starts(with: [0xFF, 0xD8, 0xFF] as [UInt8]) {
        optimiseCoverJPEG(coverPath)
        return coverPath
    }

    if data.starts(with: [0x89, 0x50, 0x4E, 0x47] as [UInt8]) {
        // Baseline: pngquant the PNG in place at aggressive settings.
        _ = try? tryProc(PNGQUANT.string, args: ["--force", "--speed", "\(cq.pngQuantSpeed)", "--quality", cq.pngQuantQuality, "--ext", ".png", coverPath.string], tries: 2, captureOutput: true)

        // Adaptive, mirroring Clop's image optimisation: photographic (high-entropy) art usually
        // shrinks far more as JPEG. Convert the original to a 100%-quality JPEG, jpegoptim it, and
        // keep it when it beats the pngquant result.
        let original = Image(data: data, path: coverPath, type: .png, retinaDownscaled: false)
        if !original.image.hasTransparentPixels, (original.image.entropy ?? 0) >= COVER_JPEG_ENTROPY_THRESHOLD,
           let jpeg = try? original.convert(to: .jpeg, asTempFile: true)
        {
            optimiseCoverJPEG(jpeg.path)
            if let pngSize = coverPath.fileSize(), let jpegSize = jpeg.path.fileSize(), jpegSize < pngSize {
                return jpeg.path
            }
        }
        return coverPath
    }

    // Unknown image format: re-embed the losslessly-extracted art untouched rather than dropping it.
    return coverPath
}

/// Pull the embedded cover art out of an audio file and surface it as a new floating image result
/// the user can save, drag, or optimise. Mirrors the PDF "extract pages as images" flow.
@MainActor func extractAudioCoverArt(optimiser: Optimiser) {
    guard !optimiser.isPreview else { return }
    guard let url = optimiser.url ?? optimiser.originalURL, let audioPath = url.filePath else {
        optimiser.overlayMessage = "No file"
        return
    }
    let stem = audioPath.lastComponent?.stem ?? "cover"
    let source = optimiser.source

    audioOptimisationQueue.addOperation {
        guard let coverPath = extractedAudioCoverArt(input: audioPath, stem: stem) else {
            mainActor { optimiser.overlayMessage = "No cover art" }
            return
        }
        mainActor {
            guard let img = Image(path: coverPath, retinaDownscaled: false) else {
                optimiser.overlayMessage = "Extract failed"
                return
            }
            // Surface the extracted art as its own finished result WITHOUT running it through the
            // optimiser: the user asked for the original embedded cover, not a re-compressed copy.
            let coverType: ItemType = coverPath.extension?.lowercased() == "png" ? .image(.png) : .image(.jpeg)
            let cover = OM.optimiser(id: coverPath.string, type: coverType, operation: "", source: source)
            cover.url = coverPath.url
            cover.originalURL = coverPath.url
            cover.thumbnail = img.image
            cover.image = img
            let bytes = coverPath.fileSize() ?? img.data.count
            cover.finish(oldBytes: bytes, newBytes: bytes, oldSize: img.size)
        }
    }
}

/// Resolve the pristine, full-resolution cover art: the cached copy if we already grabbed one,
/// otherwise extract it from `audio` (which is full-resolution until the first downscale) and cache
/// it. Caching is what makes downscaling absolute, the in-place re-mux changes the file's backup
/// hash, so we can't re-derive the original from disk afterwards. `cached` is read on the main actor
/// by the caller and passed in; the cache write happens back on the main actor.
func resolveOriginalAudioCoverArt(cached: FilePath?, optimiser: Optimiser, audio: FilePath, stem: String) -> FilePath? {
    if let cached, cached.exists { return cached }
    guard let cover = extractedAudioCoverArt(input: audio, stem: "\(stem)-orig") else { return nil }
    mainActor { optimiser.coverArtOriginalPath = cover }
    return cover
}

/// Lazily read the original embedded cover-art resolution and cache the original cover, for the
/// "Downscale cover art" slider's resolution label.
@MainActor func loadAudioCoverArtSize(optimiser: Optimiser) {
    guard optimiser.coverArtSize == nil,
          let url = optimiser.url ?? optimiser.originalURL, let path = url.filePath
    else { return }
    let stem = path.lastComponent?.stem ?? "audio"
    let cached = optimiser.coverArtOriginalPath
    audioOptimisationQueue.addOperation {
        guard let coverPath = resolveOriginalAudioCoverArt(cached: cached, optimiser: optimiser, audio: path, stem: stem),
              let image = NSImage(contentsOf: coverPath.url)
        else { return }
        let size = image.realSize
        mainActor { optimiser.coverArtSize = size }
    }
}

/// Downscale just the embedded cover art to `factor` of its ORIGINAL resolution, leaving the audio
/// stream untouched (copied, not re-encoded). Absolute: it always scales from the cached pristine
/// cover, so dragging back up restores detail and repeated downscales don't compound. At 100% the
/// original cover is re-embedded verbatim.
@MainActor func downscaleAudioCoverArt(optimiser: Optimiser, toFactor factor: Double) {
    guard !optimiser.isPreview else { return }
    guard let url = optimiser.url ?? optimiser.originalURL, let audioPath = url.filePath else { return }
    let stem = audioPath.lastComponent?.stem ?? "audio"
    let oldBytes = optimiser.oldBytes
    let cached = optimiser.coverArtOriginalPath

    optimiser.coverDownscaleFactor = factor
    optimiser.running = true
    optimiser.operation = "Downscaling cover art"
    optimiser.stopRemover()

    audioOptimisationQueue.addOperation {
        func fail(_ message: String) {
            mainActor {
                optimiser.running = false
                optimiser.overlayMessage = message
            }
        }
        guard let coverOrig = resolveOriginalAudioCoverArt(cached: cached, optimiser: optimiser, audio: audioPath, stem: stem) else {
            fail("No cover art")
            return
        }
        let isPNG = coverOrig.extension?.lowercased() == "png"
        let f = min(1.0, factor)

        // The cover to embed: the pristine original at 100%, otherwise a scaled + recompressed copy.
        let coverToEmbed: FilePath
        if f >= 0.999 {
            coverToEmbed = coverOrig
        } else {
            let scaledPath = FilePath.images.appending("\(stem)-cover-scaled-\(Int.random(in: 100 ... 100_000)).\(isPNG ? "png" : "jpg")")
            // Even dimensions keep every encoder happy.
            let scaleFilter = "scale='trunc(\(f)*iw/2)*2':'trunc(\(f)*ih/2)*2'"
            var scaleArgs = ["-y", "-i", coverOrig.string, "-vf", scaleFilter]
            if !isPNG { scaleArgs += ["-q:v", "3"] }
            scaleArgs.append(scaledPath.string)
            guard let sproc = try? tryProc(FFMPEG.string, args: scaleArgs, tries: 1, captureOutput: true),
                  sproc.terminationStatus == 0, (scaledPath.fileSize() ?? 0) > 0
            else {
                fail("Downscale failed")
                return
            }
            if !isPNG { optimiseCoverJPEG(scaledPath) }
            coverToEmbed = scaledPath
        }

        // Re-mux: copy the (already optimised) audio stream, attach the cover.
        let ext = audioPath.extension ?? "m4a"
        let outPath = FilePath.audios.appending("\(stem)-coverscaled.\(ext)")
        var muxArgs = ["-y", "-i", audioPath.string, "-i", coverToEmbed.string, "-map", "0:a", "-map", "1:v", "-c:a", "copy", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        if ext.lowercased() == "mp3" { muxArgs += ["-id3v2_version", "3"] }
        muxArgs.append(outPath.string)
        guard let mproc = try? tryProc(FFMPEG.string, args: muxArgs, tries: 1, captureOutput: true),
              mproc.terminationStatus == 0, (outPath.fileSize() ?? 0) > 0
        else {
            fail("Downscale failed")
            return
        }

        let finalPath = (try? outPath.move(to: audioPath, force: true)) ?? outPath
        // Keep the cached original; only the transient scaled copy is disposable.
        if coverToEmbed != coverOrig { try? coverToEmbed.delete() }
        mainActor {
            optimiser.url = finalPath.url
            let bytes = finalPath.fileSize() ?? oldBytes
            optimiser.finish(oldBytes: oldBytes, newBytes: bytes)
        }
    }
}

/// Put audio on the thumbnail card: seed a generic placeholder immediately, then upgrade to the
/// embedded cover art (what Finder shows) when the file has any. Used by every audio optimiser path.
@MainActor func setAudioThumbnail(on optimiser: Optimiser, path: FilePath) {
    if optimiser.thumbnail == nil {
        optimiser.thumbnail = Optimisable.fallbackThumbnail(for: path.url, path: path)
    }
    Task {
        if let art = await audioCoverArt(from: path) {
            await MainActor.run { optimiser.thumbnail = art }
        }
    }
}

/// Embedded cover art (album artwork) from an audio file, the same image Finder shows. Returns nil
/// when the file has no artwork.
func audioCoverArt(from path: FilePath) async -> NSImage? {
    let asset = AVURLAsset(url: path.url)
    guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
    for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
        if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
            return image
        }
    }
    return nil
}

@MainActor func cancelAudioOptimisation(path: FilePath) {
    audioOptimiseDebouncers[path.string]?.cancel()
    audioOptimiseDebouncers.removeValue(forKey: path.string)

    guard let optimiser = opt(path.string) else {
        return
    }
    optimiser.stop(animateRemoval: false)
    optimiser.remove(after: 0, withAnimation: false)
}

@MainActor func shouldHandleAudio(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          AUDIO_EXTENSIONS.contains(ext), !Defaults[.audioFormatsToSkip].lazy.compactMap(\.preferredFilenameExtension).contains(ext)
    else {
        return false
    }

    let inputType = path.url.utType()
    let convertSet = Defaults[.formatsToConvertToOutputAudio]
    if let inputType, !convertSet.isEmpty, !convertSet.contains(where: { inputType.conforms(to: $0) }) {
        return false
    }

    log.debug("\(path.shellString): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.clopBackups.string),
          flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
          !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0,
          Defaults[.maxAudioSizeMB] == 0 || size < Defaults[.maxAudioSizeMB] * 1_000_000,
          Defaults[.minAudioSizeKB] == 0 || size >= Defaults[.minAudioSizeKB] * 1000, audioOptimiseDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            audioOptimiseDebouncers[event.path]?.cancel()
            audioOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    return true
}

/// Resolve an input audio type to its assigned compatibility target. Returns the target format when the
/// input is assigned to AAC or MP3, or nil to keep the input in its own format. AAC is checked first so a
/// (UI-prevented) overlap is still deterministic. Plain function (not @MainActor): it only reads
/// thread-safe `Defaults`, exactly like the `Defaults[.audioFormat]` read it replaces, which already
/// runs off the main thread in the audio queue. Do NOT make it @MainActor (that would force a hop at
/// the off-main call sites).
func audioConversionTarget(forInput inputType: UTType?) -> AudioFormat? {
    guard let inputType else { return nil }
    if Defaults[.formatsToConvertToAAC].contains(where: { inputType.conforms(to: $0) }) { return .aac }
    if Defaults[.formatsToConvertToMP3].contains(where: { inputType.conforms(to: $0) }) { return .mp3 }
    return nil
}
