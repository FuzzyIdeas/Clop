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

extension UTType: Identifiable {
    public var id: String { identifier }
}

extension UTType {
    static let avif = UTType("public.avif")
    static let webm = UTType("org.webmproject.webm")
    static let mkv = UTType("org.matroska.mkv")
    static let mpeg = UTType("public.mpeg")
    static let wmv = UTType("com.microsoft.windows-media-wmv")
    static let flv = UTType("com.adobe.flash.video")
    static let m4v = UTType("com.apple.m4v-video")
}

let VIDEO_FORMATS: [UTType] = [.quickTimeMovie, .mpeg4Movie, .webm, .mkv, .mpeg2Video, .avi, .m4v, .mpeg].compactMap { $0 }
let IMAGE_FORMATS: [UTType] = [.webP, .avif, .heic, .bmp, .tiff, .png, .jpeg, .gif].compactMap { $0 }
let IMAGE_VIDEO_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS
let ALL_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS + [.pdf]

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

#if !SETAPP
    let OPTIMISATION_PORT_ID = "com.lowtechguys.Clop.optimisationService"
    let OPTIMISATION_STOP_PORT_ID = "com.lowtechguys.Clop.optimisationServiceStop"
    let OPTIMISATION_RESPONSE_PORT_ID = "com.lowtechguys.Clop.optimisationServiceResponse"
    let OPTIMISATION_CLI_RESPONSE_PORT_ID = "com.lowtechguys.Clop.optimisationServiceResponseCLI"
#else
    let OPTIMISATION_PORT_ID = "com.lowtechguys.Clop-setapp.optimisationService"
    let OPTIMISATION_STOP_PORT_ID = "com.lowtechguys.Clop-setapp.optimisationServiceStop"
    let OPTIMISATION_RESPONSE_PORT_ID = "com.lowtechguys.Clop-setapp.optimisationServiceResponse"
    let OPTIMISATION_CLI_RESPONSE_PORT_ID = "com.lowtechguys.Clop-setapp.optimisationServiceResponseCLI"
#endif

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
}

func runningClopApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.lowtechguys.Clop-setapp").first
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.lowtechguys.Clop").first
}

func isClopRunning() -> Bool {
    runningClopApp() != nil
}

import os

final class SharedLogger {
    @usableFromInline static let oslog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lowtechguys.Logger", category: "default")
    @usableFromInline static let traceLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lowtechguys.Logger", category: "trace")

    @inline(__always) @inlinable class func verbose(_ message: String, context: Any? = "") {
        #if DEBUG
            oslog.trace("🫥 \(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #else
            oslog.trace("\(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #endif
    }

    @inline(__always) @inlinable class func debug(_ message: String, context: Any? = "") {
        #if DEBUG
            oslog.debug("🌲 \(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #else
            oslog.debug("\(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #endif
    }

    @inline(__always) @inlinable class func info(_ message: String, context: Any? = "") {
        #if DEBUG
            oslog.info("💠 \(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #else
            oslog.info("\(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #endif
    }

    @inline(__always) @inlinable class func warning(_ message: String, context: Any? = "") {
        #if DEBUG
            oslog.warning("🦧 \(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #else
            oslog.warning("\(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #endif
    }

    @inline(__always) @inlinable class func error(_ message: String, context: Any? = "") {
        #if DEBUG
            oslog.fault("👹 \(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #else
            oslog.fault("\(message, privacy: .public) \(String(describing: context ?? ""), privacy: .public)")
        #endif
    }

    @inline(__always) @inlinable class func traceCalls() {
        traceLog.trace("\(Thread.callStackSymbols.joined(separator: "\n"), privacy: .public)")
    }

}

let log = SharedLogger.self

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
        log.error(error.localizedDescription)
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
            log.error(error.localizedDescription)
        }
        return type as? UTType
    }
}

import PDFKit

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

@frozen
enum PageLayout: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case auto
}

extension PDFDocument {
    func cropTo(aspectRatio: Double, alwaysPortrait: Bool = false, alwaysLandscape: Bool = false) {
        guard pageCount > 0 else { return }

        for i in 0 ..< pageCount {
            let page = page(at: i)!
            let size = page.bounds(for: .mediaBox).size
            let cropRect = size.cropTo(aspectRatio: aspectRatio, alwaysPortrait: alwaysPortrait, alwaysLandscape: alwaysLandscape)
            page.setBounds(cropRect, for: .cropBox)
        }
    }
    func uncrop() {
        guard pageCount > 0 else { return }

        for i in 0 ..< pageCount {
            let page = page(at: i)!
            page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        }
    }
}

let PAPER_SIZES_BY_CATEGORY = [
    "A": [
        "A0": NSSize(width: 841, height: 1189),
        "A1": NSSize(width: 594, height: 841),
        "A2": NSSize(width: 420, height: 594),
        "A3": NSSize(width: 297, height: 420),
        "A4": NSSize(width: 210, height: 297),
        "A5": NSSize(width: 148, height: 210),
        "A6": NSSize(width: 105, height: 148),
        "A7": NSSize(width: 74, height: 105),
        "A8": NSSize(width: 52, height: 74),
        "A9": NSSize(width: 37, height: 52),
        "A10": NSSize(width: 26, height: 37),
        "A11": NSSize(width: 18, height: 26),
        "A12": NSSize(width: 13, height: 18),
        "A13": NSSize(width: 9, height: 13),
        "2A0": NSSize(width: 1189, height: 1682),
        "4A0": NSSize(width: 1682, height: 2378),
        "A0+": NSSize(width: 914, height: 1292),
        "A1+": NSSize(width: 609, height: 914),
        "A3+": NSSize(width: 329, height: 483),
    ],
    "B": [
        "B0": NSSize(width: 1000, height: 1414),
        "B1": NSSize(width: 707, height: 1000),
        "B2": NSSize(width: 500, height: 707),
        "B3": NSSize(width: 353, height: 500),
        "B4": NSSize(width: 250, height: 353),
        "B5": NSSize(width: 176, height: 250),
        "B6": NSSize(width: 125, height: 176),
        "B7": NSSize(width: 88, height: 125),
        "B8": NSSize(width: 62, height: 88),
        "B9": NSSize(width: 44, height: 62),
        "B10": NSSize(width: 31, height: 44),
        "B11": NSSize(width: 22, height: 31),
        "B12": NSSize(width: 15, height: 22),
        "B13": NSSize(width: 11, height: 15),
        "B0+": NSSize(width: 1118, height: 1580),
        "B1+": NSSize(width: 720, height: 1020),
        "B2+": NSSize(width: 520, height: 720),
    ],
    "US": [
        "Letter": NSSize(width: 216, height: 279),
        "Legal": NSSize(width: 216, height: 356),
        "Tabloid": NSSize(width: 279, height: 432),
        "Ledger": NSSize(width: 432, height: 279),
        "Junior Legal": NSSize(width: 127, height: 203),
        "Half Letter": NSSize(width: 140, height: 216),
        "Government Letter": NSSize(width: 203, height: 267),
        "Government Legal": NSSize(width: 216, height: 330),
        "ANSI A": NSSize(width: 216, height: 279),
        "ANSI B": NSSize(width: 279, height: 432),
        "ANSI C": NSSize(width: 432, height: 559),
        "ANSI D": NSSize(width: 559, height: 864),
        "ANSI E": NSSize(width: 864, height: 1118),
        "Arch A": NSSize(width: 229, height: 305),
        "Arch B": NSSize(width: 305, height: 457),
        "Arch C": NSSize(width: 457, height: 610),
        "Arch D": NSSize(width: 610, height: 914),
        "Arch E": NSSize(width: 914, height: 1219),
        "Arch E1": NSSize(width: 762, height: 1067),
        "Arch E2": NSSize(width: 660, height: 965),
        "Arch E3": NSSize(width: 686, height: 991),
    ],
    "Photography": [
        "Passport": NSSize(width: 35, height: 45),
        "2R": NSSize(width: 64, height: 89),
        "LD, DSC": NSSize(width: 89, height: 119),
        "3R, L": NSSize(width: 89, height: 127),
        "LW": NSSize(width: 89, height: 133),
        "KGD": NSSize(width: 102, height: 136),
        "4R, KG": NSSize(width: 102, height: 152),
        "2LD, DSCW": NSSize(width: 127, height: 169),
        "5R, 2L": NSSize(width: 127, height: 178),
        "2LW": NSSize(width: 127, height: 190),
        "6R": NSSize(width: 152, height: 203),
        "8R, 6P": NSSize(width: 203, height: 254),
        "S8R, 6PW": NSSize(width: 203, height: 305),
        "11R": NSSize(width: 279, height: 356),
        "A3+ Super B": NSSize(width: 330, height: 483),
    ],
    "Newspaper": [
        "Berliner": NSSize(width: 315, height: 470),
        "Broadsheet": NSSize(width: 597, height: 749),
        "US Broadsheet": NSSize(width: 381, height: 578),
        "British Broadsheet": NSSize(width: 375, height: 597),
        "South African Broadsheet": NSSize(width: 410, height: 578),
        "Ciner": NSSize(width: 350, height: 500),
        "Compact": NSSize(width: 280, height: 430),
        "Nordisch": NSSize(width: 400, height: 570),
        "Rhenish": NSSize(width: 350, height: 520),
        "Swiss": NSSize(width: 320, height: 475),
        "Newspaper Tabloid": NSSize(width: 280, height: 430),
        "Canadian Tabloid": NSSize(width: 260, height: 368),
        "Norwegian Tabloid": NSSize(width: 280, height: 400),
        "New York Times": NSSize(width: 305, height: 559),
        "Wall Street Journal": NSSize(width: 305, height: 578),
    ],
    "Books": [
        "Folio": NSSize(width: 304.8, height: 482.6),
        "Quarto": NSSize(width: 241.3, height: 304.8),
        "Imperial Octavo": NSSize(width: 209.55, height: 292.1),
        "Super Octavo": NSSize(width: 177.8, height: 279.4),
        "Royal Octavo": NSSize(width: 165, height: 254),
        "Medium Octavo": NSSize(width: 165.1, height: 234.95),
        "Octavo": NSSize(width: 152.4, height: 228.6),
        "Crown Octavo": NSSize(width: 136.525, height: 203.2),
        "12mo": NSSize(width: 127.0, height: 187.325),
        "16mo": NSSize(width: 101.6, height: 171.45),
        "18mo": NSSize(width: 101.6, height: 165.1),
        "32mo": NSSize(width: 88.9, height: 139.7),
        "48mo": NSSize(width: 63.5, height: 101.6),
        "64mo": NSSize(width: 50.8, height: 76.2),
        "A Format": NSSize(width: 110, height: 178),
        "B Format": NSSize(width: 129, height: 198),
        "C Format": NSSize(width: 135, height: 216),
    ],
]
let PAPER_SIZES: [String: NSSize] = PAPER_SIZES_BY_CATEGORY.reduce(into: [:]) { result, category in
    category.value.forEach { result[$0.key] = $0.value }
}
let PAPER_CROP_SIZES: [String: [String: CropSize]] = PAPER_SIZES_BY_CATEGORY.reduce(into: [:]) { result, category in
    let paperCropSizes = category.value.map { k, v in (k, CropSize(width: v.width.intround, height: v.height.intround, name: k, isAspectRatio: true)) }
    result[category.key] = [String: CropSize](uniqueKeysWithValues: paperCropSizes)
}

let DEVICE_SIZES = [
    "iPhone 15 Pro Max": NSSize(width: 1290, height: 2796),
    "iPhone 15 Pro": NSSize(width: 1179, height: 2556),
    "iPhone 15 Plus": NSSize(width: 1290, height: 2796),
    "iPhone 15": NSSize(width: 1179, height: 2556),
    "iPad Pro": NSSize(width: 2048, height: 2732),
    "iPad Pro 6 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 6 11inch": NSSize(width: 1668, height: 2388),
    "iPad": NSSize(width: 1640, height: 2360),
    "iPad 10": NSSize(width: 1640, height: 2360),
    "iPhone 14 Plus": NSSize(width: 1284, height: 2778),
    "iPhone 14 Pro Max": NSSize(width: 1290, height: 2796),
    "iPhone 14 Pro": NSSize(width: 1179, height: 2556),
    "iPhone 14": NSSize(width: 1170, height: 2532),
    "iPhone SE 3": NSSize(width: 750, height: 1334),
    "iPad Air": NSSize(width: 1640, height: 2360),
    "iPad Air 5": NSSize(width: 1640, height: 2360),
    "iPhone 13": NSSize(width: 1170, height: 2532),
    "iPhone 13 mini": NSSize(width: 1080, height: 2340),
    "iPhone 13 Pro Max": NSSize(width: 1284, height: 2778),
    "iPhone 13 Pro": NSSize(width: 1170, height: 2532),
    "iPad 9": NSSize(width: 1620, height: 2160),
    "iPad Pro 5 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 5 11inch": NSSize(width: 1668, height: 2388),
    "iPad Air 4": NSSize(width: 1640, height: 2360),
    "iPhone 12": NSSize(width: 1170, height: 2532),
    "iPhone 12 mini": NSSize(width: 1080, height: 2340),
    "iPhone 12 Pro Max": NSSize(width: 1284, height: 2778),
    "iPhone 12 Pro": NSSize(width: 1170, height: 2532),
    "iPad 8": NSSize(width: 1620, height: 2160),
    "iPhone SE 2": NSSize(width: 750, height: 1334),
    "iPad Pro 4 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 4 11inch": NSSize(width: 1668, height: 2388),
    "iPad 7": NSSize(width: 1620, height: 2160),
    "iPhone 11 Pro Max": NSSize(width: 1242, height: 2688),
    "iPhone 11 Pro": NSSize(width: 1125, height: 2436),
    "iPhone 11": NSSize(width: 828, height: 1792),
    "iPod touch 7": NSSize(width: 640, height: 1136),
    "iPad mini": NSSize(width: 1488, height: 2266),
    "iPad mini 6": NSSize(width: 1488, height: 2266),
    "iPad mini 5": NSSize(width: 1536, height: 2048),
    "iPad Air 3": NSSize(width: 1668, height: 2224),
    "iPad Pro 3 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 3 11inch": NSSize(width: 1668, height: 2388),
    "iPhone XR": NSSize(width: 828, height: 1792),
    "iPhone XS Max": NSSize(width: 1242, height: 2688),
    "iPhone XS": NSSize(width: 1125, height: 2436),
    "iPad 6": NSSize(width: 1536, height: 2048),
    "iPhone X": NSSize(width: 1125, height: 2436),
    "iPhone 8 Plus": NSSize(width: 1080, height: 1920),
    "iPhone 8": NSSize(width: 750, height: 1334),
    "iPad Pro 2 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 2 10.5inch": NSSize(width: 1668, height: 2224),
    "iPad 5": NSSize(width: 1536, height: 2048),
    "iPhone 7 Plus": NSSize(width: 1080, height: 1920),
    "iPhone 7": NSSize(width: 750, height: 1334),
    "iPhone SE 1": NSSize(width: 640, height: 1136),
    "iPad Pro 1 9.7inch": NSSize(width: 1536, height: 2048),
    "iPad Pro 1 12.9inch": NSSize(width: 2048, height: 2732),
    "iPhone 6s Plus": NSSize(width: 1080, height: 1920),
    "iPhone 6s": NSSize(width: 750, height: 1334),
    "iPad mini 4": NSSize(width: 1536, height: 2048),
    "iPod touch 6": NSSize(width: 640, height: 1136),
    "iPad Air 2": NSSize(width: 1536, height: 2048),
    "iPad mini 3": NSSize(width: 1536, height: 2048),
    "iPhone 6 Plus": NSSize(width: 1080, height: 1920),
    "iPhone 6": NSSize(width: 750, height: 1334),
    "iPad mini 2": NSSize(width: 1536, height: 2048),
    "iPad Air 1": NSSize(width: 1536, height: 2048),
    "iPhone 5C": NSSize(width: 640, height: 1136),
    "iPhone 5S": NSSize(width: 640, height: 1136),
    "iPad 4": NSSize(width: 1536, height: 2048),
    "iPod touch 5": NSSize(width: 640, height: 1136),
    "iPhone 5": NSSize(width: 640, height: 1136),
    "iPad 3": NSSize(width: 1536, height: 2048),
    "iPhone 4S": NSSize(width: 640, height: 960),
    "iPad 2": NSSize(width: 768, height: 1024),
    "iPod touch 4": NSSize(width: 640, height: 960),
    "iPhone 4": NSSize(width: 640, height: 960),
]

// grouped by device type (iPad, iPhone etc.)
let DEVICE_CROP_SIZES: [String: [String: CropSize]] = DEVICE_SIZES.reduce(into: [:]) { result, device in
    let deviceType = String(device.key.split(separator: " ").first!)
    if result[deviceType] == nil {
        result[deviceType] = [:]
    }
    result[deviceType]![device.key] = CropSize(width: device.value.width.intround, height: device.value.height.intround, name: device.key, isAspectRatio: true)
}

enum CropOrientation: String, CaseIterable, Codable {
    case landscape
    case portrait
    case adaptive
}

struct CropSize: Codable, Hashable, Identifiable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let name = try container.decode(String.self, forKey: .name)
        let longEdge = try container.decode(Bool.self, forKey: .longEdge)
        let smartCrop = try container.decode(Bool.self, forKey: .smartCrop)
        let isAspectRatio = try container.decodeIfPresent(Bool.self, forKey: .isAspectRatio) ?? false
        self.init(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }

    init(width: Int, height: Int, name: String = "", longEdge: Bool = false, smartCrop: Bool = false, isAspectRatio: Bool = false) {
        self.width = width
        self.height = height
        self.name = name
        self.longEdge = longEdge
        self.smartCrop = smartCrop
        self.isAspectRatio = isAspectRatio
    }

    init(width: Double, height: Double, name: String = "", longEdge: Bool = false, smartCrop: Bool = false, isAspectRatio: Bool = false) {
        self.width = width.evenInt
        self.height = height.evenInt
        self.name = name
        self.longEdge = longEdge
        self.smartCrop = smartCrop
        self.isAspectRatio = isAspectRatio
    }

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case name
        case longEdge
        case smartCrop
        case isAspectRatio
    }

    static let zero = CropSize(width: 0, height: 0)

    let width: Int
    let height: Int
    var name = ""
    var longEdge = false
    var smartCrop = false
    var isAspectRatio = false

    var flipped: CropSize {
        var flippedName = name
        if name.contains(":") {
            let elements = name.split(separator: ":")
            flippedName = "\(elements.last ?? ""):\(elements.first ?? "")"
        }
        return CropSize(width: height, height: width, name: flippedName, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }
    var orientation: CropOrientation {
        width >= height ? .landscape : .portrait
    }
    var fractionalAspectRatio: Double {
        min(width, height).d / max(width, height).d
    }
    var id: String { "\(width == 0 ? "Auto" : width.s)×\(height == 0 ? "Auto" : height.s)" }
    var area: Int { (width == 0 ? height : width) * (height == 0 ? width : height) }
    var ns: NSSize { NSSize(width: width, height: height) }
    var cg: CGSize { CGSize(width: width, height: height) }
    var aspectRatio: Double { width.d / height.d }

    func withLongEdge(_ longEdge: Bool) -> CropSize {
        CropSize(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }

    func withSmartCrop(_ smartCrop: Bool) -> CropSize {
        CropSize(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }

    func withOrientation(_ orientation: CropOrientation, for size: NSSize? = nil) -> CropSize {
        switch orientation {
        case .landscape:
            (width >= height ? self : flipped).withLongEdge(false)
        case .portrait:
            (width >= height ? flipped : self).withLongEdge(false)
        case .adaptive:
            if let size {
                (size.orientation == self.orientation ? self : flipped).withLongEdge(true)
            } else {
                withLongEdge(true)
            }
        }
    }

    func factor(from size: NSSize) -> Double {
        if isAspectRatio {
            let cropSize = computedSize(from: size)
            return (cropSize.width * cropSize.height) / (size.width * size.height)
        }
        if longEdge {
            return width == 0 ? height.d / max(size.width, size.height) : width.d / max(size.width, size.height)
        }
        if width == 0 {
            return height.d / size.height
        }
        if height == 0 {
            return width.d / size.width
        }
        return (width.d * height.d) / (size.width * size.height)
    }

    func computedSize(from size: NSSize) -> NSSize {
        guard width == 0 || height == 0 || longEdge || isAspectRatio else {
            return ns
        }
        if isAspectRatio {
            return size.cropTo(aspectRatio: fractionalAspectRatio, alwaysPortrait: !longEdge && width < height, alwaysLandscape: !longEdge && height < width).size
        }
        return size.scaled(by: factor(from: size))
    }

}

func < (_ cropSize: CropSize, _ size: NSSize) -> Bool {
    cropSize.longEdge
        ? (cropSize.width == 0 ? cropSize.height : cropSize.width).d < max(size.width, size.height)
        : (cropSize.width.d < size.width && cropSize.height.d <= size.height) || (cropSize.width.d <= size.width && cropSize.height.d < size.height)
}

extension NSSize {
    var orientation: CropOrientation {
        width >= height ? .landscape : .portrait
    }
    func cropSize(name: String = "", longEdge: Bool = false) -> CropSize {
        CropSize(width: width.evenInt, height: height.evenInt, name: name, longEdge: longEdge)
    }
    var flipped: NSSize {
        NSSize(width: height, height: width)
    }
}

enum Device: String, Codable, Sendable, CaseIterable {
    case iPhone15ProMax = "iPhone 15 Pro Max"
    case iPhone15Pro = "iPhone 15 Pro"
    case iPhone15Plus = "iPhone 15 Plus"
    case iPhone15 = "iPhone 15"
    case iPadPro = "iPad Pro"
    case iPadPro6129Inch = "iPad Pro 6 12.9inch"
    case iPadPro611Inch = "iPad Pro 6 11inch"
    case iPad
    case iPad10 = "iPad 10"
    case iPhone14Plus = "iPhone 14 Plus"
    case iPhone14ProMax = "iPhone 14 Pro Max"
    case iPhone14Pro = "iPhone 14 Pro"
    case iPhone14 = "iPhone 14"
    case iPhoneSe3 = "iPhone SE 3"
    case iPadAir = "iPad Air"
    case iPadAir5 = "iPad Air 5"
    case iPhone13 = "iPhone 13"
    case iPhone13Mini = "iPhone 13 mini"
    case iPhone13ProMax = "iPhone 13 Pro Max"
    case iPhone13Pro = "iPhone 13 Pro"
    case iPad9 = "iPad 9"
    case iPadPro5129Inch = "iPad Pro 5 12.9inch"
    case iPadPro511Inch = "iPad Pro 5 11inch"
    case iPadAir4 = "iPad Air 4"
    case iPhone12 = "iPhone 12"
    case iPhone12Mini = "iPhone 12 mini"
    case iPhone12ProMax = "iPhone 12 Pro Max"
    case iPhone12Pro = "iPhone 12 Pro"
    case iPad8 = "iPad 8"
    case iPhoneSe2 = "iPhone SE 2"
    case iPadPro4129Inch = "iPad Pro 4 12.9inch"
    case iPadPro411Inch = "iPad Pro 4 11inch"
    case iPad7 = "iPad 7"
    case iPhone11ProMax = "iPhone 11 Pro Max"
    case iPhone11Pro = "iPhone 11 Pro"
    case iPhone11 = "iPhone 11"
    case iPodTouch7 = "iPod touch 7"
    case iPadMini = "iPad mini"
    case iPadMini6 = "iPad mini 6"
    case iPadMini5 = "iPad mini 5"
    case iPadAir3 = "iPad Air 3"
    case iPadPro3129Inch = "iPad Pro 3 12.9inch"
    case iPadPro311Inch = "iPad Pro 3 11inch"
    case iPhoneXr = "iPhone XR"
    case iPhoneXsMax = "iPhone XS Max"
    case iPhoneXs = "iPhone XS"
    case iPad6 = "iPad 6"
    case iPhoneX = "iPhone X"
    case iPhone8Plus = "iPhone 8 Plus"
    case iPhone8 = "iPhone 8"
    case iPadPro2129Inch = "iPad Pro 2 12.9inch"
    case iPadPro2105Inch = "iPad Pro 2 10.5inch"
    case iPad5 = "iPad 5"
    case iPhone7Plus = "iPhone 7 Plus"
    case iPhone7 = "iPhone 7"
    case iPhoneSe1 = "iPhone SE 1"
    case iPadPro197Inch = "iPad Pro 1 9.7inch"
    case iPadPro1129Inch = "iPad Pro 1 12.9inch"
    case iPhone6SPlus = "iPhone 6s Plus"
    case iPhone6S = "iPhone 6s"
    case iPadMini4 = "iPad mini 4"
    case iPodTouch6 = "iPod touch 6"
    case iPadAir2 = "iPad Air 2"
    case iPadMini3 = "iPad mini 3"
    case iPhone6Plus = "iPhone 6 Plus"
    case iPhone6 = "iPhone 6"
    case iPadMini2 = "iPad mini 2"
    case iPadAir1 = "iPad Air 1"
    case iPhone5C = "iPhone 5C"
    case iPhone5S = "iPhone 5S"
    case iPad4 = "iPad 4"
    case iPodTouch5 = "iPod touch 5"
    case iPhone5 = "iPhone 5"
    case iPad3 = "iPad 3"
    case iPhone4S = "iPhone 4S"
    case iPad2 = "iPad 2"
    case iPodTouch4 = "iPod touch 4"
    case iPhone4 = "iPhone 4"

    var aspectRatio: Double {
        DEVICE_SIZES[rawValue]!.aspectRatio
    }

}

enum PaperSize: String, Codable, Sendable, CaseIterable {
    case a0 = "A0"
    case a1 = "A1"
    case a2 = "A2"
    case a3 = "A3"
    case a4 = "A4"
    case a5 = "A5"
    case a6 = "A6"
    case a7 = "A7"
    case a8 = "A8"
    case a9 = "A9"
    case a10 = "A10"
    case a11 = "A11"
    case a12 = "A12"
    case a13 = "A13"
    case _2A0 = "2A0"
    case _4A0 = "4A0"
    case a0plus = "A0+"
    case a1plus = "A1+"
    case a3plus = "A3+"
    case b0 = "B0"
    case b1 = "B1"
    case b2 = "B2"
    case b3 = "B3"
    case b4 = "B4"
    case b5 = "B5"
    case b6 = "B6"
    case b7 = "B7"
    case b8 = "B8"
    case b9 = "B9"
    case b10 = "B10"
    case b11 = "B11"
    case b12 = "B12"
    case b13 = "B13"
    case b0plus = "B0+"
    case b1plus = "B1+"
    case b2plus = "B2+"
    case letter = "Letter"
    case legal = "Legal"
    case tabloid = "Tabloid"
    case ledger = "Ledger"
    case juniorLegal = "Junior Legal"
    case halfLetter = "Half Letter"
    case governmentLetter = "Government Letter"
    case governmentLegal = "Government Legal"
    case ansiA = "ANSI A"
    case ansiB = "ANSI B"
    case ansiC = "ANSI C"
    case ansiD = "ANSI D"
    case ansiE = "ANSI E"
    case archA = "Arch A"
    case archB = "Arch B"
    case archC = "Arch C"
    case archD = "Arch D"
    case archE = "Arch E"
    case archE1 = "Arch E1"
    case archE2 = "Arch E2"
    case archE3 = "Arch E3"
    case passport = "Passport"
    case _2R = "2R"
    case ldDsc = "LD, DSC"
    case _3RL = "3R, L"
    case lw = "LW"
    case kgd = "KGD"
    case _4RKg = "4R, KG"
    case _2LdDscw = "2LD, DSCW"
    case _5R2L = "5R, 2L"
    case _2Lw = "2LW"
    case _6R = "6R"
    case _8R6P = "8R, 6P"
    case s8R6Pw = "S8R, 6PW"
    case _11R = "11R"
    case a3SuperB = "A3+ Super B"
    case berliner = "Berliner"
    case broadsheet = "Broadsheet"
    case usBroadsheet = "US Broadsheet"
    case britishBroadsheet = "British Broadsheet"
    case southAfricanBroadsheet = "South African Broadsheet"
    case ciner = "Ciner"
    case compact = "Compact"
    case nordisch = "Nordisch"
    case rhenish = "Rhenish"
    case swiss = "Swiss"
    case newspaperTabloid = "Newspaper Tabloid"
    case canadianTabloid = "Canadian Tabloid"
    case norwegianTabloid = "Norwegian Tabloid"
    case newYorkTimes = "New York Times"
    case wallStreetJournal = "Wall Street Journal"
    case folio = "Folio"
    case quarto = "Quarto"
    case imperialOctavo = "Imperial Octavo"
    case superOctavo = "Super Octavo"
    case royalOctavo = "Royal Octavo"
    case mediumOctavo = "Medium Octavo"
    case octavo = "Octavo"
    case crownOctavo = "Crown Octavo"
    case _12Mo = "12mo"
    case _16Mo = "16mo"
    case _18Mo = "18mo"
    case _32Mo = "32mo"
    case _48Mo = "48mo"
    case _64Mo = "64mo"
    case aFormat = "A Format"
    case bFormat = "B Format"
    case cFormat = "C Format"

    var aspectRatio: Double {
        PAPER_SIZES[rawValue]!.aspectRatio
    }

}

let SWIFTUI_PREVIEW = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

final class NanoID {
    init(alphabet: NanoIDAlphabet..., size: Int) {
        self.size = size
        self.alphabet = NanoIDHelper.parse(alphabet)
    }

    static func new() -> String {
        NanoIDHelper.generate(from: defaultAphabet, of: defaultSize)
    }

    static func new(alphabet: NanoIDAlphabet..., size: Int) -> String {
        let charactersString = NanoIDHelper.parse(alphabet)
        return NanoIDHelper.generate(from: charactersString, of: size)
    }

    static func new(_ size: Int) -> String {
        NanoIDHelper.generate(from: NanoID.defaultAphabet, of: size)
    }

    static func random(maxSize: Int = 40) -> String {
        maxSize < 10
            ? NanoID.new(alphabet: .all, size: maxSize)
            : NanoIDHelper.generate(from: NanoIDAlphabet.all.toString(), of: arc4random_uniform((maxSize - 10).u32).i + 10)
    }

    func new() -> String {
        NanoIDHelper.generate(from: alphabet, of: size)
    }

    private static let defaultSize = 21
    private static let defaultAphabet = NanoIDAlphabet.urlSafe.toString()

    private var size: Int
    private var alphabet: String
}

extension Int {
    var u32: UInt32 { UInt32(self) }
}

extension UInt32 {
    var i: Int { Int(self) }
}

// MARK: - NanoIDHelper

private enum NanoIDHelper {
    static func parse(_ alphabets: [NanoIDAlphabet]) -> String {
        var stringCharacters = ""

        for alphabet in alphabets {
            stringCharacters.append(alphabet.toString())
        }

        return stringCharacters
    }

    static func generate(from alphabet: String, of length: Int) -> String {
        var nanoID = ""

        for _ in 0 ..< length {
            let randomCharacter = NanoIDHelper.randomCharacter(from: alphabet)
            nanoID.append(randomCharacter)
        }

        return nanoID
    }

    static func randomCharacter(from string: String) -> Character {
        let randomNum = arc4random_uniform(string.count.u32).i
        let randomIndex = string.index(string.startIndex, offsetBy: randomNum)
        return string[randomIndex]
    }
}

// MARK: - NanoIDAlphabet

enum NanoIDAlphabet {
    case urlSafe
    case uppercasedLatinLetters
    case lowercasedLatinLetters
    case numbers
    case symbols
    case all

    func toString() -> String {
        switch self {
        case .uppercasedLatinLetters, .lowercasedLatinLetters, .numbers, .symbols:
            chars()
        case .urlSafe:
            "\(NanoIDAlphabet.uppercasedLatinLetters.chars())\(NanoIDAlphabet.lowercasedLatinLetters.chars())\(NanoIDAlphabet.numbers.chars())~_"
        case .all:
            "\(NanoIDAlphabet.uppercasedLatinLetters.chars())\(NanoIDAlphabet.lowercasedLatinLetters.chars())\(NanoIDAlphabet.numbers.chars())\(NanoIDAlphabet.symbols.chars())"
        }
    }

    private func chars() -> String {
        switch self {
        case .uppercasedLatinLetters:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        case .lowercasedLatinLetters:
            "abcdefghijklmnopqrstuvwxyz"
        case .numbers:
            "1234567890"
        case .symbols:
            "§±!@#$%^&*()_+-=[]{};':,.<>?`~ /|"
        default:
            ""
        }
    }
}

enum FileNameToken: String {
    case year = "%y"
    case monthNumeric = "%m"
    case monthName = "%n"
    case day = "%d"
    case weekday = "%w"
    case hour = "%H"
    case minutes = "%M"
    case seconds = "%S"
    case amPm = "%p"
    case randomCharacters = "%r"
    case autoIncrementingNumber = "%i"
    case filename = "%f"
    case ext = "%e"
}
func generateFileName(template: String, for path: FilePath? = nil, autoIncrementingNumber: inout Int) -> String {
    var name = template
    let date = Date()
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
    let num = autoIncrementingNumber + 1

    name = name.replacingOccurrences(of: FileNameToken.year.rawValue, with: String(format: "%04d", components.year!))
        .replacingOccurrences(of: FileNameToken.monthNumeric.rawValue, with: String(format: "%02d", components.month!))
        .replacingOccurrences(of: FileNameToken.monthName.rawValue, with: calendar.monthSymbols[components.month! - 1])
        .replacingOccurrences(of: FileNameToken.day.rawValue, with: String(format: "%02d", components.day!))
        .replacingOccurrences(of: FileNameToken.weekday.rawValue, with: String(components.weekday!))
        .replacingOccurrences(of: FileNameToken.hour.rawValue, with: String(format: "%02d", components.hour!))
        .replacingOccurrences(of: FileNameToken.minutes.rawValue, with: String(format: "%02d", components.minute!))
        .replacingOccurrences(of: FileNameToken.seconds.rawValue, with: String(format: "%02d", components.second!))
        .replacingOccurrences(of: FileNameToken.amPm.rawValue, with: components.hour! > 12 ? "PM" : "AM")
        .replacingOccurrences(of: FileNameToken.randomCharacters.rawValue, with: NanoID.new(alphabet: .lowercasedLatinLetters, size: 5))
        .replacingOccurrences(of: FileNameToken.autoIncrementingNumber.rawValue, with: num.s)
        .replacingOccurrences(of: FileNameToken.filename.rawValue, with: path?.stem ?? "")
        .replacingOccurrences(of: FileNameToken.ext.rawValue, with: path?.extension ?? "")
        .safeFilename

    if !SWIFTUI_PREVIEW, template.contains(FileNameToken.autoIncrementingNumber.rawValue) {
        autoIncrementingNumber = num
    }

    return name
}

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
        return "\(size.width)"
    }
    if size.width == 0 {
        return "\(size.height)"
    }
    if size.height == 0 {
        return "\(size.width)"
    }
    return "\(size.width)x\(size.height)"
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
    func tempFile(ext: String? = nil) -> FilePath {
        Self.tempFile(name: stem, ext: ext ?? `extension` ?? "png")
    }

    static func tempFile(name: String? = nil, ext: String) -> FilePath {
        URL.temporaryDirectory.appendingPathComponent("\(name ?? UUID().uuidString).\(ext)").filePath!
    }
}

let ARCH: String = {
    var ret = 0
    var size = MemoryLayout.size(ofValue: ret)
    Darwin.sysctlbyname("hw.cputype", &ret, &size, nil, 0)
    return ret == NSBundleExecutableArchitectureARM64 ? "arm64" : "x86"
}()
let GLOBAL_BIN_DIR_PARENT = FileManager.default.urls(for: .applicationScriptsDirectory, in: .userDomainMask).first! // ~/Library/Application Scripts/com.lowtechguys.Clop
let GLOBAL_BIN_DIR = GLOBAL_BIN_DIR_PARENT.appendingPathComponent("bin") // ~/Library/Application Scripts/com.lowtechguys.Clop/bin/
let BIN_DIR = GLOBAL_BIN_DIR.appendingPathComponent(ARCH) // ~/Library/Application Scripts/com.lowtechguys.Clop/bin/arm64
let EXIFTOOL = BIN_DIR.appendingPathComponent("exiftool").existingFilePath!
let HEIF_ENC = BIN_DIR.appendingPathComponent("heif-enc").existingFilePath!
let CWEBP = BIN_DIR.appendingPathComponent("cwebp").existingFilePath!

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

extension String {
    var shellString: String { replacingFirstOccurrence(of: NSHomeDirectory(), with: "~") }
}
extension URL {
    var shellString: String { isFileURL ? path.shellString : absoluteString }
}
