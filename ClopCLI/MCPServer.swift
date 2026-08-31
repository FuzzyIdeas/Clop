//
//  MCPServer.swift
//  ClopCLI
//
//  The MCP server, inside the CLI binary. `clop mcp serve` speaks newline-delimited JSON-RPC 2.0
//  on stdin/stdout; everything else goes to stderr so it can never corrupt the stream.
//
//  This replaces the bundled `clop_mcp.py`. Same tools, same descriptions, same elicitation
//  behaviour, and the same gate: every request carries `origin = "mcp"` and the APP decides what an
//  agent may do. What changes is the plumbing. The Python server shelled out to this binary for
//  every call, so each tool call paid a process launch and every session paid the interpreter. Here
//  the tools run the same commands in this process.
//
//  It also removes the python hunt. `MCPInstaller` used to probe /usr/bin/python3, then Homebrew,
//  testing whether the Command Line Tools shim actually forwards, and on a Mac with neither the
//  server did not run at all. The CLI is already signed, notarised and in the app's seal.
//
//  Ported from `Clop/clop_mcp.py`. Lunar and rcmd carry the same design; keep them in step, and see
//  `docs/specs/mcp.md`.
//

import CryptoKit
import Foundation

// MARK: - ClopMCPError

/// An error whose message is meant for the agent to read. Clop's own refusals come back verbatim,
/// with only the next step appended.
struct ClopMCPError: Error {
    init(_ message: String) {
        self.message = message
    }

    let message: String

}

// MARK: - ToolOutput

/// What a tool hands back. `.text` keeps prose readable instead of escaping it into a JSON string;
/// `.json` is for payloads an agent should parse.
enum ToolOutput {
    case text(String)
    case json(Any)
}

// MARK: - MCPTool

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let handler: ([String: Any]) throws -> ToolOutput
}

// MARK: - MCPServer

enum MCPServer {
    // MARK: Session state

    final class State {
        var protocolVersion = MCPServer.defaultProtocol
        var modes: Set<String> = []
        var clientName = ""
    }

    struct Call {
        var requestID: Any?
        var name = ""
        var args: [String: Any] = [:]
        var params: [String: Any] = [:]
    }

    // MARK: Protocol constants

    static let serverName = "clop-mcp"
    static let serverVersion = "2.0.0"

    /// Only the fallback for a client that omits the field. The negotiated version is whatever the
    /// client asked for, since `initialize` echoes it back, so anything version-dependent branches
    /// on `state.protocolVersion` rather than on this.
    static let defaultProtocol = "2025-11-25"

    /// 2026-07-28 replaced server-initiated requests with Multi Round-Trip Requests and called it a
    /// breaking change, so elicitation splits on this version. The versions sort
    /// lexicographically, which is why a plain string compare is enough.
    static let mrtrFrom = "2026-07-28"

    static let buyURL = "https://lowtechguys.com/clop"

    static var state = State()
    static var current = Call()
    static var depth = 0
    static var reader = LineReader()
    static var pending: [String: [String: Any]?] = [:]
    static var owner: [String: String] = [:]
    static var elicitCounter = 0
    static var stateKey = SymmetricKey(size: .bits256)

    /// A person has to answer the dialog, so this is a person's wait, not a process's.
    static var elicitTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["CLOP_MCP_ELICIT_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
    }

    // MARK: The loop

    static func serve() -> Never {
        // Set here rather than left to the environment, so a client that builds its own environment
        // cannot drop the stamp the app's gate reads.
        CLI_ORIGIN = "mcp"
        log("starting")
        while true {
            let line: Data
            do {
                line = try reader.nextLine(deadline: nil)
            } catch {
                break // the client closed stdin
            }
            guard !line.isEmpty, let message = parse(line) else { continue }
            dispatch(message)
        }
        exit(0)
    }

    /// Routes one message. Both the outer loop and the nested elicitation pump call this, so the
    /// servicing rules live in one place and a tools/call that arrives while a dialog is up is
    /// still served.
    @discardableResult
    static func dispatch(_ message: [String: Any]) -> String? {
        if let id = message["id"] as? String, pending.keys.contains(id),
           message["result"] != nil || message["error"] != nil
        {
            pending[id] = message
            return id
        }
        handle(message)
        return nil
    }

    static func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            handleInitialize(id, params)
        case "notifications/initialized":
            break // a notification, no reply
        case "notifications/cancelled":
            onCancelled(params)
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": tools.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
            }])
        case "tools/call":
            callTool(id, params)
        case nil:
            // A message with an id and no method is a RESPONSE, never a request. This happens when
            // an elicitation answer arrives after the pump gave up on it. Answering it would mean
            // replying to a reply, which clients may surface as a server fault.
            log("ignoring late or unmatched response \(String(describing: id))")
        default:
            if message.keys.contains("id") {
                sendError(id, -32601, "method not found: \(method ?? "")")
            }
            // else: an unknown notification, ignored
        }
    }

    static func handleInitialize(_ id: Any?, _ params: [String: Any]) {
        // Only a string. A client sending a number here would poison every later version compare.
        state.protocolVersion = params["protocolVersion"] as? String ?? defaultProtocol
        state.modes = elicitationModes(params["capabilities"] as? [String: Any])
        state.clientName = (params["clientInfo"] as? [String: Any])?["name"] as? String ?? ""
        reply(id, [
            "protocolVersion": state.protocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": serverVersion],
        ])
    }

    static func callTool(_ id: Any?, _ params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = toolsByName[name] else {
            reply(id, ["content": [["type": "text", "text": "unknown tool: \(name)"]], "isError": true])
            return
        }

        // Checked from the tool's own schema rather than in each handler, so a missing argument
        // names itself instead of surfacing as an internal error the agent cannot act on.
        let required = tool.inputSchema["required"] as? [String] ?? []
        let missing = required.filter { key in
            guard let value = args[key] else { return true }
            if let s = value as? String {
                return s.isEmpty
            }
            if let a = value as? [Any] {
                return a.isEmpty
            }
            return value is NSNull
        }
        guard missing.isEmpty else {
            reply(id, [
                "content": [["type": "text", "text": "\(name) needs \(missing.joined(separator: ", "))"]],
                "isError": true,
            ])
            return
        }

        let previous = current
        current = Call(requestID: id, name: name, args: args, params: params)
        depth += 1
        defer {
            depth -= 1
            current = previous
        }

        do {
            switch try tool.handler(args) {
            case let .text(body):
                reply(id, ["content": [["type": "text", "text": body]]])
            case let .json(payload):
                reply(id, ["content": [["type": "text", "text": prettyJSONString(payload)]]])
            }
        } catch let need as NeedInput {
            reply(id, [
                "resultType": "input_required",
                "inputRequests": [need.key: [
                    "method": "elicitation/create",
                    "params": ["mode": "form", "message": need.message, "requestedSchema": need.schema],
                ]],
                "requestState": sealState(tool: name, args: args),
            ])
        } catch let error as ClopMCPError {
            // Clop's own words, with no prefix: they are what the agent should read.
            reply(id, ["content": [["type": "text", "text": error.message]], "isError": true])
        } catch {
            reply(id, ["content": [["type": "text", "text": "tool error: \(error)"]], "isError": true])
        }
    }

    // MARK: Wire

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[clop-mcp] \(message)\n".utf8))
    }

    static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    static func reply(_ id: Any?, _ result: [String: Any]) {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
        message["id"] = id ?? NSNull()
        send(message)
    }

    static func sendError(_ id: Any?, _ code: Int, _ message: String) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        payload["id"] = id ?? NSNull()
        send(payload)
    }

    static func parse(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    static func prettyJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: value) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - LineReader

/// Byte-level line reader over stdin, with an optional deadline.
///
/// `readLine()` cannot be given one, and a read on a pipe can block after the fd says readable when
/// only part of a line arrived. So the bytes are read from the raw fd and split here, and the
/// deadline is a `poll(2)` timeout.
final class LineReader {
    struct TimedOut: Error {}
    struct EndOfInput: Error {}

    /// The bytes of one line, without the newline. Throws `TimedOut` when a deadline passes and
    /// `EndOfInput` when the client closes stdin.
    func nextLine(deadline: TimeInterval?) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex ..< newline)
                buffer = buffer.subdata(in: (newline + 1) ..< buffer.endIndex)
                return trimmed(line)
            }
            if let deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = Int32(max(0, (deadline - Date().timeIntervalSince1970) * 1000))
                if poll(&descriptor, 1, ms) == 0 {
                    throw TimedOut()
                }
            }
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                if !buffer.isEmpty {
                    let line = buffer
                    buffer = Data()
                    return trimmed(line)
                }
                throw EndOfInput()
            }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }

    private let fd: Int32 = 0
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 65536)

    private func trimmed(_ data: Data) -> Data {
        var out = data
        while let last = out.last, last == 0x0D || last == 0x20 || last == 0x09 {
            out.removeLast()
        }
        return out
    }
}
