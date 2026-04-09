//
//  Audio.swift
//  Clop
//
//  Created by Alin Panaitiu on 19.03.2026.
//

import AVFoundation
import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Audio")

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
            Task.init {
                self.metadata = try? await getAudioMetadata(path: path)
            }
        }
    }

    required convenience init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.init(path: path, thumb: thumb, id: id)
    }

    override class var dir: FilePath { .audios }

    var metadata: AudioMetadata?

    var duration: TimeInterval? { metadata?.duration }
    var bitrate: Int? { metadata?.bitrate }
    var sampleRate: Double? { metadata?.sampleRate }
    var codec: String? { metadata?.codec }

    override func copyWithPath(_ path: FilePath) -> Self {
        Audio(path: path, metadata: metadata, fileSize: path.fileSize() ?? fileSize, thumb: true, id: id) as! Self
    }

    static func byFetchingMetadata(path: FilePath, fileSize: Int? = nil, thumb: Bool = true, id: String? = nil) async throws -> Audio? {
        let metadata = try await getAudioMetadata(path: path)
        return Audio(path: path, metadata: metadata, fileSize: fileSize, thumb: thumb, id: id)
    }

    func optimise(optimiser: Optimiser, bitrateOverride: Int? = nil, aggressive: Bool = false) throws -> Audio {
        log.debug("Optimising audio \(self.path.string)")
        guard let name = path.lastComponent else {
            log.error("No file name for path: \(self.path)")
            throw ClopError.fileNotFound(path)
        }

        path.waitForFile(for: 3)
        try? path.setOptimisationStatusXattr("pending")

        let format = Defaults[.audioFormat].resolved(forInputExtension: path.extension ?? "")
        let rawBitrate = bitrateOverride ?? Defaults[.audioBitrate]
        let bitrate = format.resolveBitrate(rawBitrate, inputBitrate: bitrate)
        let outputPath = FilePath.audios.appending("\(name.stem).\(format.fileExtension)")
        let inputPath = path.backup(path: path.clopBackupPath, operation: .copy) ?? path
        var args = ["-y", "-i", inputPath.string, "-vn"]
        args += format.encodingArgs(bitrate: bitrate, aggressive: aggressive, inputSampleRate: sampleRate)
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

        var args = ["-y", "-i", inputPath.string, "-vn"]
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
          !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0, size < Defaults[.maxAudioSizeMB] * 1_000_000, audioOptimiseDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            audioOptimiseDebouncers[event.path]?.cancel()
            audioOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    return true
}
