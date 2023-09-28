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
    let speedUpFactor: Double?
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
