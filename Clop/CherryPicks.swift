//
//  CherryPicks.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.09.2023.
//

import Cocoa
import Foundation
import System

class LocalMachPort {
    init(portLocation: String) {
        self.portLocation = portLocation as CFString
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            if let port = self.port {
                CFMessagePortInvalidate(port)
            }
        }
    }

    var portLocation: CFString!
    var port: CFMessagePort!
    var portRunLoop: CFRunLoopSource!
    var action: ((Data?) -> Unmanaged<CFData>?)?
    var context: CFMessagePortContext!

    var semaphore = DispatchSemaphore(value: 1)

    func listen(_ action: @escaping ((Data?) -> Unmanaged<CFData>?)) {
        self.action = action

        let selfPointer = UnsafeMutablePointer<LocalMachPort>.allocate(capacity: 1)
        selfPointer.initialize(to: self)

        context = CFMessagePortContext(version: 0, info: selfPointer, retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, portLocation, { _, _, data, selfPointer in
            selfPointer?.assumingMemoryBound(to: LocalMachPort.self).pointee.action?(data as Data?)
        }, &context, nil)

        guard let port else {
            return
        }
        portRunLoop = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), portRunLoop, .defaultMode)
    }

    func sendAndWait(data: Data? = nil, sendTimeout: TimeInterval = 5, recvTimeout: TimeInterval = 600) throws -> Data? {
        try send(data: data, sendTimeout: sendTimeout, recvTimeout: recvTimeout, wait: true)
    }

    func sendAndForget(data: Data? = nil, sendTimeout: TimeInterval = 5, recvTimeout: TimeInterval = 600) throws {
        try send(data: data, sendTimeout: sendTimeout, recvTimeout: recvTimeout, wait: false)
    }

    @discardableResult
    private func send(data: Data? = nil, sendTimeout: TimeInterval = 5, recvTimeout: TimeInterval = 600, wait: Bool = true) throws -> Data? {
        semaphore.wait()

        guard let port = CFMessagePortCreateRemote(nil, portLocation) else {
            semaphore.signal()
            let err = "Could not create port \(portLocation!)"
            log.error(err)
            throw err.err
        }
        semaphore.signal()

        log.debug("Sending \(data?.s ?? String(describing: data)) to port \(portLocation!)")
        var returnData: Unmanaged<CFData>?
        let err = CFMessagePortSendRequest(
            port, Int32.random(in: 1 ... 100_000),
            data as CFData?, sendTimeout, recvTimeout,
            wait ? CFRunLoopMode.defaultMode.rawValue : nil, &returnData
        )
        guard err == KERN_SUCCESS else {
            let err = "Could not send data to port \(portLocation!) (error: \(err))"
            log.error(err)
            throw err.err
        }

        return returnData?.takeRetainedValue() as? Data
    }
}

extension Data {
    var s: String? {
        String(data: self, encoding: .utf8)
    }
}

var SAFE_FILENAME_REGEX: Regex = try! Regex(#"[\/:{}<>*|$#&^;'"`\x00-\x09\x0B-\x0C\x0E-\x1F\n\t]"#)

extension String {
    var safeFilename: String {
        replacing(SAFE_FILENAME_REGEX, with: { _ in "_" })
    }

    var err: NSError {
        NSError(domain: self, code: 1)
    }
    var url: URL { URL(fileURLWithPath: self) }

    var ns: NSString {
        self as NSString
    }

    var filePath: FilePath? {
        guard !isEmpty, count <= 4096 else { return nil }
        return FilePath(trimmedPath.ns.expandingTildeInPath)
    }

    var trimmedPath: String {
        trimmingCharacters(in: ["\"", "'", "\n", "\t", " ", "(", ")", "[", "]", "{", "}", ","])
    }
}

extension URL {
    var filePath: FilePath { FilePath(self)! }
    var existingFilePath: FilePath? { FileManager.default.fileExists(atPath: path) ? FilePath(self) : nil }
}

extension FilePath {
    var name: FilePath.Component { lastComponent! }
    var dir: FilePath { removingLastComponent() }
    var url: URL { URL(filePath: self)! }

    var isDir: Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: string, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

let OPTIMISATION_PORT = LocalMachPort(portLocation: OPTIMISATION_PORT_ID)
let OPTIMISATION_STOP_PORT = LocalMachPort(portLocation: OPTIMISATION_STOP_PORT_ID)
let OPTIMISATION_RESPONSE_PORT = LocalMachPort(portLocation: OPTIMISATION_RESPONSE_PORT_ID)
let OPTIMISATION_CLI_RESPONSE_PORT = LocalMachPort(portLocation: OPTIMISATION_CLI_RESPONSE_PORT_ID)

extension NSSize {
    var aspectRatio: Double {
        width / height
    }
    func scaled(by factor: Double) -> CGSize {
        CGSize(width: (width * factor).evenInt, height: (height * factor).evenInt)
    }
}

extension Int {
    var s: String {
        String(self)
    }
    var d: Double {
        Double(self)
    }
}

extension Double {
    @inline(__always) @inlinable var intround: Int {
        rounded().i
    }

    @inline(__always) @inlinable var i: Int {
        Int(self)
    }

    var evenInt: Int {
        let x = intround
        return x + x % 2
    }
}

extension CGFloat {
    @inline(__always) @inlinable var intround: Int {
        rounded().i
    }

    @inline(__always) @inlinable var i: Int {
        Int(self)
    }

    var evenInt: Int {
        let x = intround
        return x + x % 2
    }
}

public func / (_ path: FilePath, _ str: String) -> FilePath {
    path.appending(str)
}
public func / (_ path: FilePath, _ component: FilePath.Component) -> FilePath {
    path.appending(component)
}
