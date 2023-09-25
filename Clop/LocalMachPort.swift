//
//  LocalMachPort.swift
//  Clop
//
//  Created by Alin Panaitiu on 24.09.2023.
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

    func send(data: Data? = nil, sendTimeout: TimeInterval = 0, recvTimeout: TimeInterval = 0) -> Data? {
        guard let port = CFMessagePortCreateRemote(nil, portLocation) else {
            print("Could not create port \(portLocation!)")
            return nil
        }

        print("Sending \(data?.s ?? String(describing: data)) to port \(portLocation!)")
        var returnData: Unmanaged<CFData>?
        let err = CFMessagePortSendRequest(port, Int32.random(in: 1 ... 100_000), data as CFData?, sendTimeout, recvTimeout, nil, &returnData)
        guard err == KERN_SUCCESS else {
            printerr("Could not send data to port \(portLocation!) (error: \(err))")
            return nil
        }

        return returnData?.takeRetainedValue() as? Data
    }
}

extension Data {
    var s: String? { String(data: self, encoding: .utf8) }
}
