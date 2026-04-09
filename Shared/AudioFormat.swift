import Foundation
import UniformTypeIdentifiers

enum AudioFormat: String, CaseIterable, Codable {
    case sameAsInput
    case aac
    case mp3
    case opus
    case wav

    var name: String {
        switch self {
        case .sameAsInput: "Same as input"
        case .aac: "AAC (M4A)"
        case .mp3: "MP3"
        case .opus: "Opus (OGG)"
        case .wav: "WAV"
        }
    }

    var fileExtension: String {
        switch self {
        case .sameAsInput: ""
        case .aac: "m4a"
        case .mp3: "mp3"
        case .opus: "ogg"
        case .wav: "wav"
        }
    }

    var ffmpegCodec: String {
        switch self {
        case .sameAsInput: ""
        case .aac: "aac_at"
        case .mp3: "libmp3lame"
        case .opus: "libopus"
        case .wav: "pcm_s16le"
        }
    }

    var isLossless: Bool {
        self == .wav
    }

    var allowedBitrates: [Int] {
        switch self {
        case .sameAsInput: [56, 64, 80, 96, 128, 160, 192, 256, 320]
        case .aac: [56, 64, 80, 96, 128, 160, 192, 256]
        case .mp3: [56, 64, 80, 96, 128, 160, 192, 256, 320]
        case .opus: [32, 48, 64, 80, 96, 128]
        case .wav: []
        }
    }

    var defaultBitrate: Int {
        switch self {
        case .sameAsInput: -1
        case .aac: 192
        case .mp3: 192
        case .opus: 128
        case .wav: 0
        }
    }

    var utType: UTType? {
        switch self {
        case .sameAsInput: nil
        case .aac: .m4a
        case .mp3: .mp3
        case .opus: .oggAudio
        case .wav: .wav
        }
    }

    /// Resolve `sameAsInput` to a concrete format based on the input file extension.
    func resolved(forInputExtension ext: String) -> AudioFormat {
        guard self == .sameAsInput else { return self }
        return AudioFormat.allCases.first(where: { $0 != .sameAsInput && $0.fileExtension == ext.lowercased() }) ?? .aac
    }

    /// Returns ffmpeg encoding args, using VBR where supported.
    /// For WAV: normal reduces bit depth to 16-bit and caps sample rate at 48kHz;
    /// aggressive uses IMA ADPCM for ~4:1 compression.
    func encodingArgs(bitrate: Int, aggressive: Bool = false, inputSampleRate: Double? = nil) -> [String] {
        switch self {
        case .aac:
            // Apple AudioToolbox encoder with constrained VBR
            return ["-c:a", ffmpegCodec, "-b:a", "\(bitrate)k", "-aac_at_mode", "cvbr"]
        case .mp3:
            // LAME VBR for better quality-to-size ratio
            return ["-c:a", ffmpegCodec, "-q:a", "\(lameVBRQuality(forBitrate: bitrate))"]
        case .opus:
            // Opus uses VBR by default with target bitrate
            return ["-c:a", ffmpegCodec, "-b:a", "\(bitrate)k", "-vbr", "on"]
        case .wav:
            if aggressive {
                return ["-c:a", "adpcm_ima_wav"]
            }
            // 16-bit PCM, cap sample rate at 48kHz (avoid upsampling)
            var args = ["-c:a", ffmpegCodec]
            if let sr = inputSampleRate, sr > 48000 {
                args += ["-ar", "48000"]
            }
            return args
        case .sameAsInput:
            return ["-c:a", ffmpegCodec]
        }
    }

    /// Resolve step-lower sentinel bitrate values (-1, -2) to actual bitrates.
    func resolveBitrate(_ bitrate: Int, inputBitrate: Int?) -> Int {
        guard bitrate < 0 else { return bitrate }
        let stepsLower = abs(bitrate)
        let input = inputBitrate ?? defaultBitrate
        let allowed = allowedBitrates
        guard !allowed.isEmpty else { return input }

        let inputIndex = allowed.lastIndex(where: { $0 <= input }) ?? (allowed.count - 1)
        let targetIndex = max(0, inputIndex - stepsLower)
        return allowed[targetIndex]
    }

    /// Maps target bitrate to LAME VBR quality (0=best, 9=worst).
    private func lameVBRQuality(forBitrate bitrate: Int) -> Int {
        switch bitrate {
        case ...64: 9
        case ...80: 8
        case ...96: 7
        case ...128: 5
        case ...160: 4
        case ...192: 2
        case ...256: 0
        default: 0
        }
    }

}
