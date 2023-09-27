//
//  Shared.swift
//  Clop
//
//  Created by Alin Panaitiu on 24.09.2023.
//

import Cocoa
import Foundation
import System

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
let OPTIMISATION_PORT = LocalMachPort(portLocation: OPTIMISATION_PORT_ID)
let OPTIMISATION_RESPONSE_PORT_ID = "com.lowtechguys.Clop.optimisationServiceResponse"
let OPTIMISATION_RESPONSE_PORT = LocalMachPort(portLocation: OPTIMISATION_RESPONSE_PORT_ID)

func mainActor(_ action: @escaping @MainActor () -> Void) {
    Task.init { await MainActor.run { action() }}
}

// @MainActor
// var optimisationMachPorts: [String: LocalMachPort] = [:]
//
// @MainActor
// func optimisationPort(id: String) -> LocalMachPort {
//    if let port = optimisationMachPorts[id] {
//        return port
//    }
//
//    let port = LocalMachPort(portLocation: "com.lowtechguys.Clop.optimisation.\(id)")
//    optimisationMachPorts[id] = port
//
//    return port
// }

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

    var oldSize: CGSize? = nil
    var newSize: CGSize? = nil

    var id: String { path }
}

struct StopOptimisationRequest: Codable {
    let ids: [String]
    let remove: Bool
}

struct OptimisationRequest: Codable, Identifiable {
    let id: String
    let urls: [URL]
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
