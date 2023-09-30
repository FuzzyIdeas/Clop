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
}

struct StopOptimisationRequest: Codable {
    let ids: [String]
    let remove: Bool
}

struct OptimisationRequest: Codable, Identifiable {
    let id: String
    let urls: [URL]
    var originalUrls: [URL: URL] = [:] // [tempURL: originalURL]
    let size: NSSize?
    let downscaleFactor: Double?
    let changePlaybackSpeedFactor: Double?
    let hideFloatingResult: Bool
    let copyToClipboard: Bool
    let aggressiveOptimisation: Bool
    let source: String
}

func isClopRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.lowtechguys.Clop").isEmpty
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

func shell(_ command: String, args: [String] = []) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: command)
    task.arguments = args

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        log.error(error.localizedDescription)
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

extension URL {
    func fetchFileType() -> UTType? {
        if let type = UTType(filenameExtension: pathExtension) {
            return type
        }

        guard let mimeType = shell("/usr/bin/file", args: ["-b", "--mime-type", path]) else {
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

extension NSSize {
    func cropTo(aspectRatio: Double) -> NSRect {
        let sizeAspectRatio = self.aspectRatio
        if sizeAspectRatio > aspectRatio {
            let width = height * aspectRatio
            let x = (self.width - width) / 2
            return NSRect(x: x, y: 0, width: width, height: height)
        } else {
            let height = width / aspectRatio
            let y = (self.height - height) / 2
            return NSRect(x: 0, y: y, width: width, height: height)
        }
    }
}

extension PDFDocument {
    func cropTo(aspectRatio: Double) {
        guard pageCount > 0 else { return }

        for i in 0 ..< pageCount {
            let page = page(at: i)!
            let size = page.bounds(for: .mediaBox).size
            let cropRect = size.cropTo(aspectRatio: aspectRatio)
            page.setBounds(cropRect, for: .cropBox)
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
