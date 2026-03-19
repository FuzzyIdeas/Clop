import AVFoundation
@testable import Clop
import Defaults
import Foundation
import System
import Testing
import UniformTypeIdentifiers

// MARK: - Helpers

@MainActor func setAudioFormat(_ format: AudioFormat, bitrate: Int? = nil) {
    Defaults[.audioFormat] = format
    Defaults[.audioBitrate] = bitrate ?? format.defaultBitrate
    UserDefaults.standard.synchronize()
}

// MARK: - Unit Tests

@Suite("AudioFormat")
struct AudioFormatTests {
    @Test("AAC properties")
    func aacProperties() {
        let format = AudioFormat.aac
        #expect(format.fileExtension == "m4a")
        #expect(format.ffmpegCodec == "aac")
        #expect(format.allowedBitrates.contains(192))
        #expect(format.defaultBitrate == 192)
    }

    @Test("MP3 properties")
    func mp3Properties() {
        let format = AudioFormat.mp3
        #expect(format.fileExtension == "mp3")
        #expect(format.ffmpegCodec == "libmp3lame")
        #expect(format.allowedBitrates.contains(192))
        #expect(format.defaultBitrate == 192)
    }

    @Test("Opus properties")
    func opusProperties() {
        let format = AudioFormat.opus
        #expect(format.fileExtension == "ogg")
        #expect(format.ffmpegCodec == "libopus")
        #expect(format.allowedBitrates.contains(128))
        #expect(format.defaultBitrate == 128)
    }

    @Test("All formats have a UTType")
    func allFormatsHaveUTType() {
        for format in AudioFormat.allCases {
            #expect(format.utType != nil, "\(format.name) missing utType")
        }
    }
}

@Suite("Audio metadata", .tags(.integration))
@MainActor
struct AudioMetadataTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    @Test("WAV metadata has duration and sample rate")
    func wavMetadata() async throws {
        let path = fixture("sample.wav", in: tempDir)
        let meta = try await getAudioMetadata(path: path)
        let m = try #require(meta)
        #expect(m.duration != nil)
        #expect(m.duration! > 1.5 && m.duration! < 2.5)
        #expect(m.sampleRate != nil)
    }

    @Test("FLAC metadata has duration")
    func flacMetadata() async throws {
        let path = fixture("sample.flac", in: tempDir)
        let meta = try await getAudioMetadata(path: path)
        let m = try #require(meta)
        #expect(m.duration != nil)
        #expect(m.duration! > 1.5 && m.duration! < 2.5)
    }

    @Test("MP3 metadata has duration and bitrate")
    func mp3Metadata() async throws {
        let path = fixture("sample.mp3", in: tempDir)
        let meta = try await getAudioMetadata(path: path)
        let m = try #require(meta)
        #expect(m.duration != nil)
        #expect(m.duration! > 1.5 && m.duration! < 2.5)
        #expect(m.bitrate != nil)
        #expect(m.bitrate! > 200) // 320kbps fixture
    }

    @Test("AIFF metadata has duration")
    func aiffMetadata() async throws {
        let path = fixture("sample.aiff", in: tempDir)
        let meta = try await getAudioMetadata(path: path)
        let m = try #require(meta)
        #expect(m.duration != nil)
        #expect(m.duration! > 1.5 && m.duration! < 2.5)
    }
}

// MARK: - Pipeline Integration Tests

@Suite("runAudioPipeline()", .tags(.integration), .serialized)
@MainActor
struct AudioPipelineTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    // MARK: - Lossless to lossy

    @Test("Optimise WAV to AAC -> output exists and is smaller")
    func optimiseWAVtoAAC() async throws {
        setAudioFormat(.aac)
        let path = fixture("sample.wav", in: tempDir)
        let originalSize = path.fileSize() ?? 0
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(FileManager.default.fileExists(atPath: resultPath.string))
            #expect(resultPath.string.hasSuffix(".m4a"))
            let resultSize = resultPath.fileSize() ?? 0
            #expect(resultSize > 0)
            #expect(resultSize < originalSize)
        }
    }

    @Test("Optimise AIFF -> output exists and is smaller")
    func optimiseAIFF() async throws {
        setAudioFormat(.aac)
        let path = fixture("sample.aiff", in: tempDir)
        let originalSize = path.fileSize() ?? 0
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(FileManager.default.fileExists(atPath: resultPath.string))
            let resultSize = resultPath.fileSize() ?? 0
            #expect(resultSize > 0)
            #expect(resultSize < originalSize)
        }
    }

    @Test("Optimise high-bitrate MP3 -> output exists")
    func optimiseMP3() async throws {
        setAudioFormat(.aac)
        let path = fixture("sample.mp3", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
    }

    // MARK: - Lossless to different lossy formats

    @Test("Convert WAV to MP3 format")
    func convertWAVtoMP3() async throws {
        setAudioFormat(.mp3, bitrate: 192)
        let path = fixture("sample.wav", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".mp3"))
        }
    }

    @Test("Convert WAV to Opus format")
    func convertWAVtoOpus() async throws {
        setAudioFormat(.opus, bitrate: 128)
        let path = fixture("sample.wav", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".ogg"))
        }
    }

    // MARK: - Cross-format conversion (lossy to different lossy)

    @Test("Convert M4A to MP3")
    func convertM4AtoMP3() async throws {
        setAudioFormat(.mp3, bitrate: 192)
        let path = fixture("sample.m4a", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".mp3"))
            #expect(FileManager.default.fileExists(atPath: resultPath.string))
        }
    }

    @Test("Convert M4A to Opus")
    func convertM4AtoOpus() async throws {
        setAudioFormat(.opus, bitrate: 128)
        let path = fixture("sample.m4a", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".ogg"))
        }
    }

    @Test("Convert OGG to AAC")
    func convertOGGtoAAC() async throws {
        setAudioFormat(.aac, bitrate: 192)
        let path = fixture("sample.ogg", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".m4a"))
        }
    }

    @Test("Convert OGG to MP3")
    func convertOGGtoMP3() async throws {
        setAudioFormat(.mp3, bitrate: 192)
        let path = fixture("sample.ogg", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".mp3"))
        }
    }

    @Test("Convert MP3 to AAC")
    func convertMP3toAAC() async throws {
        setAudioFormat(.aac, bitrate: 192)
        let path = fixture("sample.mp3", in: tempDir)
        let audio = try #require(await Audio.byFetchingMetadata(path: path, thumb: false))

        let result = try await runAudioPipeline(audio, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.string.hasSuffix(".m4a"))
        }
    }
}

// MARK: - ItemType audio detection (uses real fixture files)

@Suite("ItemType audio detection", .tags(.integration))
struct ItemTypeAudioTests {
    init() throws {
        tempDir = try copyFixturesToTempDir()
    }

    let tempDir: URL

    @Test("WAV detected as audio")
    func wavDetected() {
        let type = ItemType.from(filePath: fixture("sample.wav", in: tempDir))
        if case .audio = type {} else {
            Issue.record("Expected .audio, got \(type)")
        }
    }

    @Test("FLAC detected as audio")
    func flacDetected() {
        let type = ItemType.from(filePath: fixture("sample.flac", in: tempDir))
        if case .audio = type {} else {
            Issue.record("Expected .audio, got \(type)")
        }
    }

    @Test("MP3 detected as audio")
    func mp3Detected() {
        let type = ItemType.from(filePath: fixture("sample.mp3", in: tempDir))
        if case .audio = type {} else {
            Issue.record("Expected .audio, got \(type)")
        }
    }

    @Test("M4A detected as audio")
    func m4aDetected() {
        let type = ItemType.from(filePath: fixture("sample.m4a", in: tempDir))
        if case .audio = type {} else {
            Issue.record("Expected .audio, got \(type)")
        }
    }

    @Test("OGG detected as audio")
    func oggDetected() {
        let type = ItemType.from(filePath: fixture("sample.ogg", in: tempDir))
        if case .audio = type {} else {
            Issue.record("Expected .audio, got \(type)")
        }
    }

    @Test("AIFF detected as audio")
    func aiffDetected() {
        let type = ItemType.from(filePath: fixture("sample.aiff", in: tempDir))
        if case .audio = type {} else {
            Issue.record("Expected .audio, got \(type)")
        }
    }

    @Test("isAudio property")
    func isAudioProperty() {
        let audioType = ItemType.audio(.wav)
        #expect(audioType.isAudio)

        let imageType = ItemType.image(.jpeg)
        #expect(!imageType.isAudio)
    }

    @Test("Audio convertible types include all output formats")
    func audioConvertibleTypes() {
        let audioType = ItemType.audio(.wav)
        let convertible = audioType.convertibleTypes
        #expect(convertible.count == 3)
        #expect(convertible.contains(.mp3))
        if let m4a = UTType.m4a {
            #expect(convertible.contains(m4a))
        }
        if let ogg = UTType.oggAudio {
            #expect(convertible.contains(ogg))
        }
    }
}
