//
//  Shared.swift
//  Clop
//
//  Created by Alin Panaitiu on 24.09.2023.
//

import Cocoa
import Foundation
import System
import UniformTypeIdentifiers

func ~= (lhs: UTType?, rhs: UTType) -> Bool {
    guard let lhs else { return false }
    return lhs.conforms(to: rhs)
}

enum ClopError: Error, CustomStringConvertible, Codable {
    case fileNotFound(FilePath)
    case fileNotImage(FilePath)
    case noClipboardImage(FilePath)
    case noProcess(String)
    case alreadyOptimised(FilePath)
    case alreadyResized(FilePath)
    case unknownImageType(FilePath)
    case skippedType(String)
    case imageSizeLarger(FilePath)
    case videoSizeLarger(FilePath)
    case pdfSizeLarger(FilePath)
    case audioSizeLarger(FilePath)
    case videoError(String)
    case pdfError(String)
    case downloadError(String)
    case optimisationPaused(FilePath)
    case optimisationFailed(String)
    case conversionFailed(FilePath)
    case proError(String)
    case decompressingBinariesError
    case downscaleFailed(FilePath)
    case appNotRunning(FilePath)
    case encryptedPDF(FilePath)
    case invalidPDF(FilePath)
    case couldNotCreateOutputDirectory(String)
    case unknownType

    var localizedDescription: String { description }
    var description: String {
        switch self {
        case let .fileNotFound(p):
            return "File not found: \(p)"
        case let .fileNotImage(p):
            return "File is not an image: \(p)"
        case let .noClipboardImage(p):
            if p.string.isEmpty { return "No image in clipboard" }
            return "No image in clipboard: \(p.string.count > 100 ? p.string.prefix(50) + "..." + p.string.suffix(50) : p.string)"
        case let .noProcess(string):
            return "Can't start process: \(string)"
        case let .alreadyOptimised(p):
            return "Image is already optimised: \(p)"
        case let .alreadyResized(p):
            return "Image is already at the correct size or smaller: \(p)"
        case let .imageSizeLarger(p):
            return "Optimised image size is larger: \(p)"
        case let .videoSizeLarger(p):
            return "Optimised video size is larger: \(p)"
        case let .pdfSizeLarger(p):
            return "Optimised PDF size is larger: \(p)"
        case let .audioSizeLarger(p):
            return "Optimised audio size is larger: \(p)"
        case let .unknownImageType(p):
            return "Unknown image type: \(p)"
        case let .videoError(string):
            return "Error processing video: \(string)"
        case let .pdfError(string):
            return "Error processing PDF: \(string)"
        case let .downloadError(string):
            return "Download failed: \(string)"
        case let .skippedType(string):
            return "Type is skipped: \(string)"
        case let .optimisationPaused(p):
            return "Optimisation paused: \(p)"
        case let .conversionFailed(p):
            return "Conversion failed: \(p)"
        case let .proError(string):
            return "Pro error: \(string)"
        case .decompressingBinariesError:
            return "Decompressing binaries"
        case let .downscaleFailed(p):
            return "Downscale failed: \(p)"
        case let .optimisationFailed(p):
            return "Optimisation failed: \(p)"
        case let .appNotRunning(p):
            return "App is not running, integration failed: \(p)"
        case let .invalidPDF(p):
            return "Can't parse PDF: \(p)"
        case let .encryptedPDF(p):
            return "PDF is encrypted: \(p)"
        case let .couldNotCreateOutputDirectory(location):
            return "Could not create output directory: \(location)"
        case .unknownType:
            return "Unknown type"
        }
    }
    var humanDescription: String {
        switch self {
        case .fileNotFound:
            "File not found"
        case .fileNotImage:
            "Not an image"
        case .noClipboardImage:
            "No image in clipboard"
        case .noProcess:
            "Can't start process"
        case .alreadyOptimised:
            "Already optimised"
        case .alreadyResized:
            "Image is already at the correct size or smaller"
        case .imageSizeLarger:
            "Already optimised"
        case .videoSizeLarger:
            "Already optimised"
        case .pdfSizeLarger:
            "Already optimised"
        case .audioSizeLarger:
            "Already optimised"
        case .unknownImageType:
            "Unknown image type"
        case .videoError:
            "Video error"
        case .pdfError:
            "PDF error"
        case .downloadError:
            "Download failed"
        case .skippedType:
            "Type is skipped"
        case .optimisationPaused:
            "Optimisation paused"
        case .conversionFailed:
            "Conversion failed"
        case .proError:
            "Pro error"
        case .downscaleFailed:
            "Downscale failed"
        case .optimisationFailed:
            "Optimisation failed"
        case .appNotRunning:
            "App integration not running"
        case .encryptedPDF:
            "PDF is encrypted"
        case .invalidPDF:
            "Can't parse PDF"
        case .couldNotCreateOutputDirectory:
            "Could not create output directory"
        case .decompressingBinariesError:
            "Decompressing binaries"
        case .unknownType:
            "Unknown type"
        }
    }
}

extension UTType: @retroactive Identifiable {
    public var id: String { identifier }
}

extension UTType {
    static let avif = UTType("public.avif") ?? UTType(tag: "avif", tagClass: .filenameExtension, conformingTo: .image)
    static let webm = UTType("org.webmproject.webm") ?? UTType("io.iina.webm") ?? UTType(tag: "webm", tagClass: .filenameExtension, conformingTo: .movie)
    static let mkv = UTType("org.matroska.mkv") ?? UTType("io.iina.mkv") ?? UTType(tag: "mkv", tagClass: .filenameExtension, conformingTo: .movie)
    static let mpeg = UTType("public.mpeg") ?? UTType(tag: "mpeg", tagClass: .filenameExtension, conformingTo: .movie)
    static let wmv = UTType("com.microsoft.windows-media-wmv") ?? UTType("io.iina.wmv") ?? UTType(tag: "wmv", tagClass: .filenameExtension, conformingTo: .movie)
    static let flv = UTType("com.adobe.flash.video") ?? UTType(tag: "flv", tagClass: .filenameExtension, conformingTo: .movie)
    static let m4v = UTType("com.apple.m4v-video") ?? UTType(tag: "m4v", tagClass: .filenameExtension, conformingTo: .movie)
    // Codec targets for video conversion (output is .mp4 with a specific encoder)
    static let hevcVideo = UTType(tag: "hevc", tagClass: .filenameExtension, conformingTo: .movie)
    static let av1Video = UTType(tag: "av1", tagClass: .filenameExtension, conformingTo: .movie)

    static let jxl = UTType("public.jxl") ?? UTType(tag: "jxl", tagClass: .filenameExtension, conformingTo: .image)

    static let flac = UTType("org.xiph.flac") ?? UTType("public.flac")
    static let oggAudio = UTType("org.xiph.ogg-audio") ?? UTType("public.ogg-audio")
    static let opusAudio = UTType("org.xiph.opus")
    static let m4a = UTType("com.apple.m4a-audio") ?? UTType("public.mpeg-4-audio")
}

let VIDEO_FORMATS: [UTType] = [.quickTimeMovie, .mpeg4Movie, .webm, .mkv, .mpeg2Video, .avi, .m4v, .mpeg].compactMap { $0 }
let IMAGE_FORMATS: [UTType] = [.webP, .avif, .heic, .jxl, .bmp, .tiff, .png, .jpeg, .gif].compactMap { $0 }
let AUDIO_FORMATS: [UTType] = [.wav, .aiff, .mp3, .flac, .m4a, .oggAudio].compactMap { $0 }
let IMAGE_VIDEO_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS
let ALL_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS + AUDIO_FORMATS + [.pdf]

func printerr(_ msg: String, terminator: String = "\n") {
    fputs("\(msg)\(terminator)", stderr)
}

func awaitSync(_ action: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task.init {
        await action()
        sem.signal()
    }
    sem.wait()
}

let OPTIMISATION_PORT_ID = "com.lowtechguys.Clop.optimisationService"
let OPTIMISATION_STOP_PORT_ID = "com.lowtechguys.Clop.optimisationServiceStop"
let OPTIMISATION_RESPONSE_PORT_ID = "com.lowtechguys.Clop.optimisationServiceResponse"
let OPTIMISATION_CLI_RESPONSE_PORT_ID = "com.lowtechguys.Clop.optimisationServiceResponseCLI"

func mainActor(_ action: @escaping @MainActor () -> Void) {
    Task.init { await MainActor.run { action() }}
}

extension Encodable {
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }
    var jsonData: Data {
        try! JSONEncoder().encode(self)
    }
}
extension Decodable {
    static func from(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct ProgressPayload: Codable {
    let fractionCompleted: Double
}

// DPI = 300 means no downsampling; below that we let Ghostscript downsample.
let PDF_DPI_NO_DOWNSAMPLE = 300
let PDF_DPI_MIN = 48
let PDF_DPI_MAX = 300
// Sentinel value indicating the aggressive DPI should be picked adaptively per PDF.
let PDF_DPI_ADAPTIVE = 0
// Snap points used by the DPI slider, ordered high to low.
let PDF_DPI_STOPS: [Int] = [300, 250, 200, 150, 100, 72, 48]

// MARK: - Unified compression model

private func cqClamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, v)) }

/// Named per-format compression anchor. Not every case is valid for every format; the
/// format-specific helpers only ever produce/consume the cases relevant to that format.
enum CompressionTier: String, Codable, CaseIterable, Hashable {
    case adaptive   // image: PNG↔JPEG cross-format test; pdf: adaptive DPI
    case lossless   // video: CRF 17; pdf: 300 DPI (no downsample)
    case fast       // video only: hardware VideoToolbox encoder
    case smaller    // video only: efficient software encoder
    case custom     // pure-factor mode (no named anchor)
}

/// Single per-format "how hard do we compress" value: a named `tier` plus a continuous
/// `factor` from 5 (least compression / best quality) to 100 (most compression / smallest file).
struct CompressionQuality: Codable, Hashable {
    var tier: CompressionTier
    var factor: Int

    init(tier: CompressionTier = .custom, factor: Int = 50) {
        self.tier = tier
        self.factor = cqClamp(factor, 5, 100)
    }

    // Tolerant decode so old/partial blobs round-trip through Defaults/iCloud without dropping.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? c.decode(CompressionTier.self, forKey: .tier)) ?? .custom
        let f = (try? c.decode(Int.self, forKey: .factor)) ?? 50
        self.init(tier: t, factor: f)
    }
}

// Factor anchors that reproduce the legacy presets exactly, so migration keeps behaviour identical:
// factor 30 == the old "normal" preset, factor 64 == the old "aggressive" preset.
let COMPRESSION_FACTOR_NORMAL = 30
let COMPRESSION_FACTOR_AGGRESSIVE = 64

// MARK: Image translation (factor 5..100, higher = more compression)
// jpegoptim --max / pngquant --quality ceiling / cwebp,heif,jxl -q are QUALITY scales (inverted);
// gifsicle -O/--lossy is a compression scale (direct).
extension CompressionQuality {
    /// Whether this resolves to the legacy "aggressive" preset (drives UI labels + adaptive thresholds).
    var imageIsAggressive: Bool { tier != .adaptive && factor >= 50 }

    /// jpegoptim --max quality ceiling. factor 30 -> 85 (legacy normal), 64 -> 68 (legacy aggressive).
    var jpegMaxQuality: Int { cqClamp(85 - (factor - 30) / 2, 40, 95) }

    /// jpegoptim --max for the old-binary fallback and the adaptive cross-test. factor 30 -> 90, 64 -> 70.
    var jpegSecondaryMaxQuality: Int { cqClamp(Int((90.0 - Double(factor - 30) * (20.0 / 34.0)).rounded()), 40, 97) }

    /// pngquant --quality string "0-MAX". factor 30 -> "0-100", 64 -> "0-85".
    var pngQuantQuality: String { "0-\(cqClamp(Int((100.0 - Double(factor - 30) * (15.0 / 34.0)).rounded()), 40, 100))" }

    /// gifsicle args. factor 30 -> -O2 --lossy=30 (normal); 64 -> -O3 --lossy=80 --colors=N (aggressive).
    var gifsicleArgs: [String] {
        let oLevel = factor >= 50 ? 3 : (factor >= 20 ? 2 : 1)
        let lossy = cqClamp(Int((30.0 + Double(factor - 30) * (50.0 / 34.0)).rounded()), 0, 200)
        var args = ["-O\(oLevel)", "--lossy=\(lossy)"]
        if factor >= 50 {
            let colors = cqClamp(Int((256.0 - Double(factor - 50) * (192.0 / 50.0)).rounded()), 32, 256)
            args.append("--colors=\(colors)")
        }
        return args
    }

    /// cwebp / heif-enc -q quality (0-100). factor 30 -> 60 (legacy hardcoded default).
    var conversionQuality: Int { cqClamp(Int((75.0 - Double(factor) * 0.5).rounded()), 20, 90) }
    /// JXLCoder quality (0-100). factor 30 -> 60 (legacy).
    var jxlQuality: Int { cqClamp(Int((75.0 - Double(factor) * 0.5).rounded()), 20, 95) }
    /// JXLCoder effort (1-9). factor <50 -> 7 (legacy), ramps to 9 at high compression.
    var jxlEffort: Int { factor >= 70 ? 9 : (factor >= 50 ? 8 : 7) }
}

struct OptimisationResponseError: Codable, Identifiable {
    let error: String
    let forURL: URL

    var id: String { forURL.path }
}

struct OptimisationResponse: Codable, Identifiable {
    let path: String
    let forURL: URL
    var convertedFrom: String? = nil

    var oldBytes = 0
    var newBytes = 0

    var oldWidthHeight: CGSize? = nil
    var newWidthHeight: CGSize? = nil

    var oldBitrate: Int? = nil
    var newBitrate: Int? = nil

    var oldDPI: Int? = nil
    var newDPI: Int? = nil

    var id: String { path }
    var percentageSaved: Double { 100 - (Double(newBytes) / Double(oldBytes == 0 ? 1 : oldBytes) * 100) }
}

struct StopOptimisationRequest: Codable {
    let ids: [String]
    let remove: Bool
}

struct OptimisationRequest: Codable, Identifiable {
    let id: String
    let urls: [URL]
    var originalUrls: [URL: URL] = [:] // [tempURL: originalURL]
    let size: CropSize?
    let downscaleFactor: Double?
    let changePlaybackSpeedFactor: Double?
    let hideFloatingResult: Bool
    let copyToClipboard: Bool
    let aggressiveOptimisation: Bool
    let adaptiveOptimisation: Bool?
    let source: String
    var output: String?
    var removeAudio: Bool?
    /// PDF aggressive DPI override: nil = use the user setting, 0 = adaptive,
    /// positive = a specific stop from `PDF_DPI_STOPS`.
    var pdfDPI: Int?
}

func runningClopApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.lowtechguys.Clop-setapp").first
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.lowtechguys.Clop").first
}

func isClopRunning() -> Bool {
    runningClopApp() != nil
}

import os

let LOG_SUBSYSTEM = Bundle.main.bundleIdentifier ?? "com.lowtechguys.Clop"

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Shared")

extension DispatchWorkItem {
    func wait(for timeout: TimeInterval) -> DispatchTimeoutResult {
        let result = wait(timeout: .now() + timeout)
        if result == .timedOut {
            cancel()
            return .timedOut
        }
        return .success
    }
}

@discardableResult
func asyncNow(_ action: @escaping () -> Void) -> DispatchWorkItem {
    let workItem = DispatchWorkItem(block: action)

    DispatchQueue.global().async(execute: workItem)
    return workItem
}

func shell(_ command: String, args: [String] = [], timeout: TimeInterval? = nil) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: command)
    task.arguments = args

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
    } catch {
        log.error("\(error.localizedDescription)")
        return nil
    }

    if let timeout {
        let result = asyncNow { task.waitUntilExit() }.wait(for: timeout)
        if result == .timedOut {
            task.terminate()
            return nil
        }
    } else {
        task.waitUntilExit()
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

extension URL {
    func utType() -> UTType? {
        contentTypeResourceValue ?? fetchFileType()
    }

    func fetchFileType() -> UTType? {
        if let type = UTType(filenameExtension: pathExtension) {
            return type
        }

        guard let mimeType = shell("/usr/bin/file", args: ["-b", "--mime-type", path], timeout: 5) else {
            return nil
        }

        return UTType(mimeType: mimeType)
    }

    var contentTypeResourceValue: UTType? {
        var type: AnyObject?

        do {
            try (self as NSURL).getResourceValue(&type, forKey: .contentTypeKey)
        } catch {
            log.error("\(error.localizedDescription)")
        }
        return type as? UTType
    }
}

extension Double {
    var fractionalAspectRatio: Double {
        self > 1 ? 1 / self : self
    }
}

extension NSSize {
    var fractionalAspectRatio: Double {
        min(width, height) / max(width, height)
    }

    func cropToPortrait(aspectRatio: Double) -> NSRect {
        let selfAspectRatio = width / height
        if selfAspectRatio > aspectRatio {
            let width = height * aspectRatio
            let x = (self.width - width) / 2
            return NSRect(x: x, y: 0, width: width, height: height)
        } else {
            let height = width / aspectRatio
            let y = (self.height - height) / 2
            return NSRect(x: 0, y: y, width: width, height: height)
        }
    }

    func cropToLandscape(aspectRatio: Double) -> NSRect {
        let selfAspectRatio = height / width
        if selfAspectRatio > aspectRatio {
            let height = width * aspectRatio
            let y = (self.height - height) / 2
            return NSRect(x: 0, y: y, width: width, height: height)
        } else {
            let width = height / aspectRatio
            let x = (self.width - width) / 2
            return NSRect(x: x, y: 0, width: width, height: height)
        }
    }

    var isLandscape: Bool { width > height }
    var isPortrait: Bool { width < height }

    func cropTo(aspectRatio: Double, alwaysPortrait: Bool = false, alwaysLandscape: Bool = false) -> NSRect {
        if alwaysPortrait {
            cropToPortrait(aspectRatio: aspectRatio)
        } else if alwaysLandscape {
            cropToLandscape(aspectRatio: aspectRatio)
        } else {
            isLandscape ? cropToLandscape(aspectRatio: aspectRatio) : cropToPortrait(aspectRatio: aspectRatio)
        }

    }

    var evenSize: NSSize {
        var w = Int(width.rounded())
        w = w + w % 2

        var h = Int(height.rounded())
        h = h + h % 2

        return NSSize(width: Double(w), height: Double(h))
    }
}

let SWIFTUI_PREVIEW = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

func factorStr(_ factor: Double?) -> String {
    guard let factor else {
        return ""
    }
    return String(format: (factor * 10).truncatingRemainder(dividingBy: 1) < 0.001 ? "%.1f" : ((factor * 100).truncatingRemainder(dividingBy: 1) < 0.001 ? "%.2f" : "%.3f"), factor)
}

func cropSizeStr(_ cropSize: CropSize?) -> String {
    guard let cropSize else {
        return ""
    }
    let size = cropSize.ns.evenSize

    if cropSize.longEdge {
        return "\(size.width.i)"
    }
    if size.width == 0 {
        return "\(size.height.i)"
    }
    if size.height == 0 {
        return "\(size.width.i)"
    }
    return "\(size.width.i)x\(size.height.i)"
}

extension Double {
    func str(decimals: Int) -> String {
        String(format: "%.\(decimals)f", self)
    }
}

extension Int {
    var humanSize: String {
        switch self {
        case 0 ..< 1000:
            return "\(self)B"
        case 0 ..< 1_000_000:
            let num = self / 1000
            return "\(num)KB"
        case 0 ..< 1_000_000_000:
            let num = d / 1_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s)MB"
        default:
            let num = d / 1_000_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s)GB"
        }
    }
}

infix operator ?!: NilCoalescingPrecedence

func ?! <T: BinaryInteger>(_ num: T?, _ num2: T) -> T {
    guard let num, num != 0 else {
        return num2
    }
    return num
}

extension FilePath {
    func tempFile(ext: String? = nil, addUniqueID: Bool = false) -> FilePath {
        Self.tempFile(name: stem, ext: ext ?? `extension` ?? "tmp", addUniqueID: addUniqueID)
    }

    static func tempFile(name: String? = nil, ext: String, addUniqueID: Bool = false) -> FilePath {
        URL.temporaryDirectory.appendingPathComponent(
            "\(name ?? UUID().uuidString)\(name != nil && addUniqueID ? "-\(UUID().uuidString)" : "").\(ext)"
        ).filePath!
    }
}

let ARCH: String = {
    var ret = 0
    var size = MemoryLayout.size(ofValue: ret)
    Darwin.sysctlbyname("hw.cputype", &ret, &size, nil, 0)
    return ret == NSBundleExecutableArchitectureARM64 ? "arm64" : "x86"
}()
let APP_SCRIPTS_DIR = FileManager.default.urls(for: .applicationScriptsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Scripts/com.lowtechguys.Clop")

let GLOBAL_BIN_DIR_PARENT = APP_SCRIPTS_DIR // ~/Library/Application Scripts/com.lowtechguys.Clop
let GLOBAL_BIN_DIR = GLOBAL_BIN_DIR_PARENT.appendingPathComponent("bin") // ~/Library/Application Scripts/com.lowtechguys.Clop/bin/
let BIN_DIR = GLOBAL_BIN_DIR.appendingPathComponent(ARCH) // ~/Library/Application Scripts/com.lowtechguys.Clop/bin/arm64
var EXIFTOOL = BIN_DIR.appendingPathComponent("exiftool").filePath!
var HEIF_ENC = BIN_DIR.appendingPathComponent("heif-enc").filePath!
var CWEBP = BIN_DIR.appendingPathComponent("cwebp").filePath!

func getURLsFromFolder(_ folder: URL, recursive: Bool, types: [UTType]) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey, .contentTypeKey],
        options: [.skipsPackageDescendants]
    ) else {
        return []
    }

    var urls: [URL] = []

    for case let fileURL as URL in enumerator {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey, .contentTypeKey]),
              let isDirectory = resourceValues.isDirectory, let isRegularFile = resourceValues.isRegularFile, let name = resourceValues.name
        else {
            continue
        }

        if isDirectory {
            if !recursive || name.hasPrefix(".") || ["node_modules", ".git"].contains(name) {
                enumerator.skipDescendants()
            }
            continue
        }

        if !isRegularFile {
            continue
        }

        if !isURLOptimisable(fileURL, type: resourceValues.contentType, types: types) {
            continue
        }
        urls.append(fileURL)
    }
    return urls
}

func isURLOptimisable(_ url: URL, type: UTType? = nil, types: [UTType]) -> Bool {
    guard url.isFileURL else {
        return true
    }
    guard let type = type ?? url.contentTypeResourceValue ?? url.fetchFileType() else {
        return false
    }
    return types.contains(where: { type.conforms(to: $0) })
}

extension FilePath {
    var exists: Bool { FileManager.default.fileExists(atPath: string) }

    @discardableResult
    func mkdir(withIntermediateDirectories: Bool, permissions: Int = 0o755) -> Bool {
        guard !exists else { return true }
        do {
            try FileManager.default.createDirectory(atPath: string, withIntermediateDirectories: withIntermediateDirectories, attributes: [.posixPermissions: permissions])
        } catch {
            log.error("Error creating directory '\(string)': \(error)")
            return false
        }
        return true
    }
}
