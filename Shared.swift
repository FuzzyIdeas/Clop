//
//  Shared.swift
//  Clop
//
//  Created by Alin Panaitiu on 24.09.2023.
//

import Foundation
import System

func printerr(_ msg: String, end: String = "\n") {
    fputs("\(msg)\(end)", stderr)
}

let OPTIMISATION_PORT_ID = "com.lowtechguys.Clop.optimisationService"
let OPTIMISATION_PORT = LocalMachPort(portLocation: OPTIMISATION_PORT_ID)

extension Encodable {
    var jsonData: Data {
        try! JSONEncoder().encode(self)
    }
}
extension Decodable {
    static func from(_ data: Data) -> OptimisationResponse? {
        try? JSONDecoder().decode(OptimisationResponse.self, from: data)
    }
}

struct OptimisationResponse: Codable, Identifiable {
    let path: FilePath

    var id: String { path.string }
}

struct OptimisationRequest: Codable, Identifiable {
    let url: URL
    let size: NSSize?
    let downscaleFactor: Double?
    let speedUpFactor: Double?
    let hideFloatingResult: Bool
    let copyToClipboard: Bool
    let aggressiveOptimisation: Bool
    let source: String

    var id: String { url.path }
}
