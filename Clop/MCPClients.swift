import AppKit
import Foundation
import os

private let clientsLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MCPInstaller", category: "MCP")

// MARK: - Clients

/// The agents an app can install its MCP server into, where each one keeps its servers, and the edits
/// that put one entry in and take it back out without touching anything else in the file.
///
/// The same file lives in rcmd, Clop, Lunar and Crank. What differs per app (`serverName`, `cliPath`,
/// `serveArgs`, `scriptExists`, `InstallError`) stays in that app's `MCPInstaller.swift`, so this one
/// is copied across unchanged. Keep the copies in step.
extension MCPInstaller {
    /// How a client's config file holds its servers.
    enum Style {
        /// `mcpServers`, command and args side by side: Claude Code, Claude Desktop, pi, Gemini CLI,
        /// Antigravity, Qwen Code, Kimi Code, Devin and Cursor.
        case mcpServers
        /// `mcpServers` with `"type": "stdio"`: Factory Droid.
        case droid
        /// `mcpServers` with `"type": "local"` and a tool allowlist: Copilot CLI.
        case copilot
        /// `amp.mcpServers`, a dotted name at the top level: Amp.
        case amp
        /// `mcp`, with the command and its arguments in one array: OpenCode.
        case openCode
        /// `mcp` with `"type": "stdio"`: Crush's older `crush.json`.
        case crushJSON
        /// `servers` with `"type": "stdio"`: VS Code.
        case vsCode
        /// `context_servers`, command and args side by side: Zed.
        case zed
        /// A `[mcp_servers.<name>]` table in TOML: Codex.
        case codex
        /// `extensions.<name>` in YAML: Goose.
        case goose
        /// An `mcp add` command in a Bash file: Crush.
        case crushrc
    }

    struct Config {
        let path: String
        let style: Style

        var url: URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
    }

    struct Client: Identifiable {
        init(id: String, name: String, path: String, style: Style, evidence: [String]) {
            self.init(id: id, name: name, configs: [Config(path: path, style: style)], evidence: evidence)
        }

        init(id: String, name: String, configs: [Config], evidence: [String]) {
            self.id = id
            self.name = name
            self.configs = configs
            self.evidence = evidence
        }

        let id: String
        let name: String
        /// Where the client reads its servers, in its own order. The first one on disk is the one edited,
        /// and with none there the first is created. Crush warns when a folder has both a `crushrc` and a
        /// `crush.json`, so a second file is never started next to the one already in use.
        let configs: [Config]
        /// A file, folder or app that shows the client is on this Mac.
        let evidence: [String]

        var config: Config {
            configs.first { FileManager.default.fileExists(atPath: $0.url.path) } ?? configs[0]
        }

        var path: String {
            config.path
        }

        var style: Style {
            config.style
        }

        var url: URL {
            config.url
        }

        /// Where the bytes actually live. These are exactly the files people keep in a dotfiles repo and
        /// symlink into place, and an atomic write against a symlink replaces the link with a regular
        /// file. See `resolvedConfigURL`.
        var writeURL: URL {
            resolvedConfigURL(url)
        }

        var isPresent: Bool {
            configs.contains { FileManager.default.fileExists(atPath: $0.url.path) }
                || evidence.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
        }
    }

    /// What the client's config file says.
    enum ConfigState {
        case installed
        case notInstalled
        /// The file is there and is not an object even with its comments taken out, so there is no
        /// members list to add the server to. Only JSON ends up here: the TOML, YAML and Bash editors read
        /// what they can, and refuse at write time with a `LayoutError` instead.
        case unusable
    }

    /// A file the TOML, YAML or Bash editor would not change.
    struct LayoutError: LocalizedError {
        let path: String

        var errorDescription: String? {
            "\(path) has a layout that can't be edited safely."
        }
    }

    // MARK: - The list

    /// The rows above "See more".
    static let featuredClients: [Client] = [
        Client(
            id: "claude-code", name: "Claude Code",
            path: "~/.claude.json", style: .mcpServers,
            evidence: ["~/.claude"] + binaries("claude")
        ),
        Client(
            id: "claude-desktop", name: "Claude Desktop",
            path: "~/Library/Application Support/Claude/claude_desktop_config.json", style: .mcpServers,
            evidence: ["/Applications/Claude.app"]
        ),
        // The ChatGPT desktop app runs Codex too and reads the same config.toml.
        Client(
            id: "codex", name: "Codex",
            path: "~/.codex/config.toml", style: .codex,
            evidence: ["~/.codex", "/Applications/Codex.app", "/Applications/ChatGPT.app"] + binaries("codex")
        ),
        Client(
            id: "copilot", name: "Copilot CLI",
            path: "~/.copilot/mcp-config.json", style: .copilot,
            evidence: ["~/.copilot"] + binaries("copilot")
        ),
        // Native MCP since pi 0.99. Older builds ignore this file until `pi update`.
        Client(
            id: "pi", name: "pi",
            path: "~/.pi/agent/mcp.json", style: .mcpServers,
            evidence: ["~/.pi"] + binaries("pi")
        ),
        Client(
            id: "opencode", name: "OpenCode",
            configs: [
                Config(path: "~/.config/opencode/opencode.json", style: .openCode),
                Config(path: "~/.config/opencode/opencode.jsonc", style: .openCode),
            ],
            evidence: ["~/.config/opencode", "~/.opencode", "/Applications/OpenCode.app"] + binaries("opencode")
        ),
        Client(
            id: "gemini", name: "Gemini CLI",
            path: "~/.gemini/settings.json", style: .mcpServers,
            evidence: binaries("gemini")
        ),
    ]

    /// The rows under "See more".
    static let moreClients: [Client] = [
        // One file for the agy CLI and the Antigravity app.
        Client(
            id: "antigravity", name: "Antigravity",
            path: "~/.gemini/config/mcp_config.json", style: .mcpServers,
            evidence: ["/Applications/Antigravity.app", "~/.gemini/antigravity"] + binaries("agy")
        ),
        Client(
            id: "amp", name: "Amp",
            path: "~/.config/amp/settings.json", style: .amp,
            evidence: ["~/.config/amp", "~/.amp"] + binaries("amp")
        ),
        Client(
            id: "droid", name: "Factory Droid",
            path: "~/.factory/mcp.json", style: .droid,
            evidence: ["~/.factory"] + binaries("droid")
        ),
        Client(
            id: "goose", name: "Goose",
            path: "~/.config/goose/config.yaml", style: .goose,
            evidence: ["~/.config/goose", "/Applications/Goose.app"] + binaries("goose")
        ),
        Client(
            id: "crush", name: "Crush",
            configs: [
                Config(path: "~/.config/crush/crushrc", style: .crushrc),
                Config(path: "~/.config/crush/crush.json", style: .crushJSON),
            ],
            evidence: ["~/.local/share/crush"] + binaries("crush")
        ),
        Client(
            id: "qwen", name: "Qwen Code",
            path: "~/.qwen/settings.json", style: .mcpServers,
            evidence: ["~/.qwen"] + binaries("qwen")
        ),
        Client(
            id: "kimi", name: "Kimi Code",
            path: "~/.kimi-code/mcp.json", style: .mcpServers,
            evidence: ["~/.kimi-code"] + binaries("kimi")
        ),
        // The Devin CLI, and Windsurf since it became Devin Desktop: Cascade's old
        // `~/.codeium/windsurf/mcp_config.json` moved here with the rename.
        Client(
            id: "devin", name: "Devin",
            path: "~/.config/devin/mcp_config.json", style: .mcpServers,
            evidence: ["/Applications/Devin.app", "/Applications/Windsurf.app", "~/.codeium/windsurf"] + binaries("devin")
        ),
        Client(
            id: "cursor", name: "Cursor",
            path: "~/.cursor/mcp.json", style: .mcpServers,
            evidence: ["/Applications/Cursor.app", "~/.cursor"] + binaries("cursor-agent")
        ),
        Client(
            id: "vscode", name: "VS Code",
            path: "~/Library/Application Support/Code/User/mcp.json", style: .vsCode,
            evidence: ["/Applications/Visual Studio Code.app", "~/Library/Application Support/Code"]
        ),
        Client(
            id: "vscode-insiders", name: "VS Code Insiders",
            path: "~/Library/Application Support/Code - Insiders/User/mcp.json", style: .vsCode,
            evidence: ["/Applications/Visual Studio Code - Insiders.app", "~/Library/Application Support/Code - Insiders"]
        ),
        Client(
            id: "zed", name: "Zed",
            path: "~/.config/zed/settings.json", style: .zed,
            evidence: ["/Applications/Zed.app", "~/.config/zed"]
        ),
    ]

    static let clients = featuredClients + moreClients

    // MARK: - Reading

    static func state(_ client: Client) -> ConfigState {
        let config = client.config
        guard let container = jsonContainer(config.style) else {
            guard let text = try? String(contentsOf: config.url, encoding: .utf8) else {
                return .notInstalled
            }
            return textEntry(in: text, style: config.style) != nil ? .installed : .notInstalled
        }
        do {
            guard let root = try JSONCEditor.read(config.url) else {
                return .notInstalled
            }
            return (root[container] as? [String: Any])?[serverName] != nil ? .installed : .notInstalled
        } catch {
            return .unusable
        }
    }

    static func isInstalled(_ client: Client) -> Bool {
        state(client) == .installed
    }

    /// The command and arguments a client's config currently points at, or nil when the server is not in
    /// it or its entry is shaped in a way this cannot read.
    static func installedCommand(_ client: Client) -> (command: String, args: [String])? {
        let config = client.config
        guard let container = jsonContainer(config.style) else {
            guard let text = try? String(contentsOf: config.url, encoding: .utf8),
                  let entry = textEntry(in: text, style: config.style),
                  let command = entry.command
            else {
                return nil
            }
            return (command, entry.args)
        }
        guard let root = try? JSONCEditor.read(config.url),
              let member = (root[container] as? [String: Any])?[serverName] as? [String: Any]
        else {
            return nil
        }

        switch config.style {
        case .openCode:
            guard let parts = member["command"] as? [String], let command = parts.first else {
                return nil
            }
            return (command, Array(parts.dropFirst()))
        case .zed:
            // Zed used to nest the pair under `command` and migrates it flat on launch; either may be here.
            if let nested = member["command"] as? [String: Any] {
                guard let command = nested["path"] as? String else {
                    return nil
                }
                return (command, nested["args"] as? [String] ?? [])
            }
            fallthrough
        default:
            guard let command = member["command"] as? String else {
                return nil
            }
            return (command, member["args"] as? [String] ?? [])
        }
    }

    // MARK: - Install and remove

    @discardableResult
    static func install(_ client: Client) -> Result<Void, Error> {
        guard scriptExists else {
            return .failure(InstallError.missingServer)
        }
        let config = client.config
        return edit(client, config) { text in
            switch config.style {
            case .codex:
                return try TOMLEditor.setTable(in: text, path: ["mcp_servers", serverName], body: codexBody)
            case .goose:
                return try YAMLEditor.setChild(in: text, parent: "extensions", name: serverName, body: gooseBody)
            case .crushrc:
                return try ShellRCEditor.setCommand(in: text, matching: ["mcp", "add", serverName], with: crushLine)
            default:
                let container = jsonContainer(config.style) ?? "mcpServers"
                return try JSONCEditor.setMember(in: text, container: container, name: serverName, member: jsonEntry(config.style))
            }
        }
    }

    @discardableResult
    static func remove(_ client: Client) -> Result<Void, Error> {
        let config = client.config
        // nil means ours was not in there, and nothing is written: a file that was never ours must not be
        // touched on the way out.
        return edit(client, config) { text in
            switch config.style {
            case .codex:
                try TOMLEditor.removeTable(in: text, path: ["mcp_servers", serverName])
            case .goose:
                try YAMLEditor.removeChild(in: text, parent: "extensions", name: serverName)
            case .crushrc:
                try ShellRCEditor.removeCommand(in: text, matching: ["mcp", "add", serverName])
            default:
                JSONCEditor.removeMember(in: text, container: jsonContainer(config.style) ?? "mcpServers", name: serverName)
            }
        }
    }

    static func revealConfig(_ client: Client) {
        NSWorkspace.shared.activateFileViewerSelecting([client.url])
    }

    // MARK: - Entries

    /// The places a CLI's installer usually puts it.
    private static func binaries(_ name: String) -> [String] {
        ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.bun/bin"].map { "\($0)/\(name)" }
    }

    /// The top-level key holding the servers, or nil for a file that is not JSON.
    private static func jsonContainer(_ style: Style) -> String? {
        switch style {
        case .mcpServers, .droid, .copilot: "mcpServers"
        case .amp: "amp.mcpServers"
        case .openCode, .crushJSON: "mcp"
        case .vsCode: "servers"
        case .zed: "context_servers"
        case .codex, .goose, .crushrc: nil
        }
    }

    /// The member, already formatted. The file is edited as text, so this is what lands in it verbatim.
    private static func jsonEntry(_ style: Style) -> String {
        let command = json(cliPath)
        let args = serveArgs.map { json($0) }.joined(separator: ", ")
        return switch style {
        case .openCode:
            """
            {
              "type": "local",
              "command": [\(([cliPath] + serveArgs).map { json($0) }.joined(separator: ", "))],
              "enabled": true
            }
            """
        case .copilot:
            """
            {
              "type": "local",
              "command": \(command),
              "args": [\(args)],
              "tools": ["*"]
            }
            """
        case .droid, .crushJSON, .vsCode:
            """
            {
              "type": "stdio",
              "command": \(command),
              "args": [\(args)]
            }
            """
        case .mcpServers, .amp, .zed, .codex, .goose, .crushrc:
            """
            {
              "command": \(command),
              "args": [\(args)]
            }
            """
        }
    }

    /// TOML basic strings take JSON's escapes, so the JSON encoder quotes for both.
    private static var codexBody: [String] {
        [
            "command = \(json(cliPath))",
            "args = [\(serveArgs.map { json($0) }.joined(separator: ", "))]",
        ]
    }

    /// Goose reads every extension as `enabled` plus the fields of its type. Double-quoted YAML takes
    /// JSON's escapes, so the JSON encoder quotes here too.
    private static var gooseBody: [String] {
        [
            "enabled: true",
            "type: stdio",
            "name: \(json(serverName))",
            "cmd: \(json(cliPath))",
            "args:",
        ] + serveArgs.map { "- \(json($0))" } + [
            "envs: {}",
            "timeout: 300",
        ]
    }

    private static var crushLine: String {
        (["mcp", "add", serverName, "--command", cliPath] + serveArgs.flatMap { ["--args", $0] })
            .map { ShellRCEditor.quote($0) }
            .joined(separator: " ")
    }

    /// The entry in a TOML, YAML or Bash config, nil when it is not there. `command` is nil for an entry
    /// that exists in a shape this cannot read, such as a TOML inline table.
    private static func textEntry(in text: String, style: Style) -> (command: String?, args: [String])? {
        switch style {
        case .codex:
            guard let values = TOMLEditor.values(in: text, path: ["mcp_servers", serverName]) else {
                return nil
            }
            return (values["command"].flatMap { TOMLEditor.strings($0) }?.first, values["args"].flatMap { TOMLEditor.strings($0) } ?? [])
        case .goose:
            guard let fields = YAMLEditor.childFields(in: text, parent: "extensions", name: serverName) else {
                return nil
            }
            return (fields["cmd"]?.first, fields["args"] ?? [])
        case .crushrc:
            guard let words = ShellRCEditor.words(in: text, matching: ["mcp", "add", serverName]) else {
                return nil
            }
            var command: String?
            var args: [String] = []
            var i = 3
            while i < words.count {
                let word = words[i]
                if word == "--command" || word == "--args", i + 1 < words.count {
                    if word == "--command" {
                        command = words[i + 1]
                    } else {
                        args.append(words[i + 1])
                    }
                    i += 2
                    continue
                }
                if word.hasPrefix("--command=") {
                    command = String(word.dropFirst("--command=".count))
                } else if word.hasPrefix("--args=") {
                    args.append(String(word.dropFirst("--args=".count)))
                }
                i += 1
            }
            return (command, args)
        default:
            return nil
        }
    }

    /// A path can hold a quote or a backslash, so it goes through the encoder rather than into a string
    /// literal.
    private static func json(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return String(array.dropFirst().dropLast())
    }

    /// Read the file as text, splice it, write it back. `change` returns nil when there is nothing to do,
    /// and then nothing is written at all.
    ///
    /// The read happens as late as possible: Claude Code keeps writing `~/.claude.json` while it runs, and
    /// anything it puts there between this read and this write is lost. The window is microseconds and it
    /// is not zero; a client that rewrites its config on a timer is a client to install into while it is
    /// closed.
    ///
    /// The file's permissions are put back after the write. An atomic write lands a new file with default
    /// permissions, and `~/.codex/config.toml` and `~/.claude.json` are private to their owner because
    /// people keep tokens in them.
    private static func edit(_ client: Client, _ config: Config, _ change: (String) throws -> String?) -> Result<Void, Error> {
        let fm = FileManager.default
        do {
            let target = resolvedConfigURL(config.url)
            let exists = fm.fileExists(atPath: target.path)
            let existing = exists ? try String(contentsOf: target, encoding: .utf8) : ""
            guard let updated = try change(existing), updated != existing else {
                return .success(())
            }

            let permissions = exists ? (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] : nil
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: target, atomically: true, encoding: .utf8)
            if let permissions {
                try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            clientsLog.info("Wrote MCP entry to \(config.path, privacy: .public)")
            return .success(())
        } catch is ConfigLayoutError {
            clientsLog.error("MCP edit refused for \(client.name, privacy: .public): \(config.path, privacy: .public) has a layout it does not edit")
            return .failure(LayoutError(path: config.path))
        } catch {
            clientsLog.error("MCP edit failed for \(client.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }
}

// MARK: - ConfigLayoutError

/// Why one of the editors below would not touch a file. `MCPInstaller` turns it into a `LayoutError`
/// that names the file.
enum ConfigLayoutError: Error {
    case unsupported
}

// MARK: - ConfigLines

/// A text file as lines, for the line-based editors. A `\r` stays on its line, so a CRLF file comes back
/// with the endings it had.
struct ConfigLines {
    init(_ text: String) {
        var parts = text.isEmpty ? [] : text.components(separatedBy: "\n")
        // By byte: Swift reads CRLF as one Character, so `hasSuffix("\n")` is false for a CRLF file.
        if text.utf8.last == UInt8(ascii: "\n") {
            parts.removeLast()
        }
        lines = parts
        crlf = text.contains("\r\n")
    }

    var lines: [String]
    let crlf: Bool

    var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// A line written by the editor, ending the way the file's own lines do.
    func fresh(_ line: String) -> String {
        crlf ? line + "\r" : line
    }

    /// Drop `ranges`, and with each one any blank lines it leaves doubled up, so taking a block out does
    /// not leave a gap where it was. Returns every line dropped, by its old index.
    @discardableResult
    mutating func remove(_ ranges: [Range<Int>]) -> IndexSet {
        var drop = IndexSet()
        for range in ranges {
            drop.insert(integersIn: range)
        }
        var extra = IndexSet()
        for run in drop.rangeView {
            let followedByBlank = run.upperBound >= lines.count || Self.isBlank(lines[run.upperBound])
            guard followedByBlank else {
                continue
            }
            var start = run.lowerBound
            while start > 0, Self.isBlank(lines[start - 1]), !drop.contains(start - 1) {
                start -= 1
                extra.insert(start)
            }
            // At the top of the file there is nothing above to keep apart, so the gap below goes instead.
            var end = run.upperBound
            while start == 0, end < lines.count, Self.isBlank(lines[end]), !drop.contains(end) {
                extra.insert(end)
                end += 1
            }
        }
        drop.formUnion(extra)
        lines = lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        return drop
    }
}

private func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

// MARK: - TOMLEditor

/// Adds and removes one table in a TOML file, as text, the way `JSONCEditor` does for JSON: comments,
/// key order and formatting outside the table survive byte for byte.
///
/// The scanner knows enough TOML to find where each table and each statement starts and ends: strings
/// of all four kinds, comments, and arrays or inline tables that run over several lines. A file it cannot
/// follow is refused rather than guessed at.
enum TOMLEditor {
    /// The values set directly in the table at `path`, unparsed, or nil when nothing defines that table.
    static func values(in text: String, path: [String]) -> [String: String]? {
        guard let items = scan(ConfigLines(text).lines) else {
            return nil
        }
        let ours = items.filter { $0.path.starts(with: path) }
        guard !ours.isEmpty else {
            return nil
        }
        var values: [String: String] = [:]
        for item in ours where !item.isHeader && item.path.count == path.count + 1 {
            values[item.path[path.count]] = item.value
        }
        return values
    }

    /// Replace whatever defines the table at `path` with `[path]` followed by `body`. The table goes where
    /// the old one started, or at the end of the file when there was none.
    static func setTable(in text: String, path: [String], body: [String]) throws -> String {
        var file = ConfigLines(text)
        let found = try owned(by: path, in: file.lines)
        let block = (["[\(path.map { key($0) }.joined(separator: "."))]"] + body).map { file.fresh($0) }

        guard let first = found.firstSection else {
            file.remove(found.ranges)
            if let last = file.lines.last, !ConfigLines.isBlank(last) {
                file.lines.append(file.fresh(""))
            }
            file.lines += block
            return file.text
        }
        // The rest of ours goes first, then the block lands where the first table was. Removal never
        // reaches into that table: it ends on a line of content, and only blank lines are swept up.
        let dropped = file.remove(found.ranges.filter { $0 != first })
        let start = first.lowerBound - dropped.count(in: 0 ..< first.lowerBound)
        file.lines.replaceSubrange(start ..< start + first.count, with: block)
        return file.text
    }

    /// Drop everything that defines the table at `path`. Nil when there was nothing to drop.
    static func removeTable(in text: String, path: [String]) throws -> String? {
        var file = ConfigLines(text)
        let found = try owned(by: path, in: file.lines)
        guard !found.ranges.isEmpty else {
            return nil
        }
        file.remove(found.ranges)
        return file.text
    }

    /// The strings in a value: the one string, or each element of an array of strings. Nil for any other
    /// kind of value.
    static func strings(_ value: String) -> [String]? {
        let s = Array(value.unicodeScalars)
        var i = 0
        skipSpace(s, &i, newlines: true)
        guard i < s.count else {
            return nil
        }
        guard s[i] == "[" else {
            return parseString(s, &i).map { [$0] }
        }
        i += 1
        var out: [String] = []
        while true {
            skipSpace(s, &i, newlines: true)
            guard i < s.count else {
                return nil
            }
            if s[i] == "]" {
                return out
            }
            guard let element = parseString(s, &i) else {
                return nil
            }
            out.append(element)
            skipSpace(s, &i, newlines: true)
            guard i < s.count else {
                return nil
            }
            if s[i] == "," {
                i += 1
            } else if s[i] != "]" {
                return nil
            }
        }
    }

    // MARK: Scanning

    /// A table header or a `key = value` statement, and the lines it covers.
    private struct Item {
        let isHeader: Bool
        /// The table for a header; the enclosing table plus the dotted key for a statement.
        let path: [String]
        let lines: Range<Int>
        /// What follows `=`, comments taken out. Empty for a header.
        let value: String
    }

    private enum Mode {
        case code
        case basic
        case literal
        case multiBasic
        case multiLiteral
    }

    /// The line ranges that define the table at `path`: its header sections (cut back to their last line
    /// of content, so a comment heading the next table stays with it) and any dotted keys that reach into
    /// it from elsewhere.
    private static func owned(by path: [String], in lines: [String]) throws -> (ranges: [Range<Int>], firstSection: Range<Int>?) {
        guard let items = scan(lines) else {
            throw ConfigLayoutError.unsupported
        }
        // `mcp_servers = { … }` holds every server inline, and a table cannot be added next to it or cut
        // out of it line by line.
        if items.contains(where: { !$0.isHeader && $0.path.count < path.count && path.starts(with: $0.path) }) {
            throw ConfigLayoutError.unsupported
        }

        let headers = items.filter(\.isHeader)
        var sections: [Range<Int>] = []
        for (n, header) in headers.enumerated() where header.path.starts(with: path) {
            var end = n + 1 < headers.count ? headers[n + 1].lines.lowerBound : lines.count
            while end > header.lines.upperBound, ConfigLines.isBlank(lines[end - 1]) || isComment(lines[end - 1]) {
                end -= 1
            }
            sections.append(header.lines.lowerBound ..< end)
        }
        let statements = items
            .filter { !$0.isHeader && $0.path.starts(with: path) }
            .map(\.lines)
            .filter { line in !sections.contains { $0.contains(line.lowerBound) } }
        return ((sections + statements).sorted { $0.lowerBound < $1.lowerBound }, sections.first)
    }

    private static func isComment(_ line: String) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.hasPrefix("#")
    }

    /// Every header and statement, or nil when the file has something this cannot follow.
    private static func scan(_ lines: [String]) -> [Item]? {
        var items: [Item] = []
        var table: [String] = []
        var n = 0
        while n < lines.count {
            let s = Array(lines[n].unicodeScalars)
            var i = 0
            skipSpace(s, &i, newlines: false)
            if i >= s.count || s[i] == "#" {
                n += 1
                continue
            }

            if s[i] == "[" {
                let isArray = i + 1 < s.count && s[i + 1] == "["
                i += isArray ? 2 : 1
                guard let path = keyPath(s, &i) else {
                    return nil
                }
                for _ in 0 ..< (isArray ? 2 : 1) {
                    guard i < s.count, s[i] == "]" else {
                        return nil
                    }
                    i += 1
                }
                skipSpace(s, &i, newlines: false)
                guard i >= s.count || s[i] == "#" else {
                    return nil
                }
                table = path
                items.append(Item(isHeader: true, path: path, lines: n ..< n + 1, value: ""))
                n += 1
                continue
            }

            guard let key = keyPath(s, &i), i < s.count, s[i] == "=" else {
                return nil
            }
            // The value can run over several lines: a multi-line string, or an array.
            var mode = Mode.code
            var depth = 0
            var value = ""
            var line = s
            var start = i + 1
            let first = n
            while true {
                guard let end = advance(line, from: start, mode: &mode, depth: &depth), depth >= 0 else {
                    return nil
                }
                value += string(line[start ..< end])
                if mode == .code, depth == 0 {
                    break
                }
                n += 1
                guard n < lines.count else {
                    return nil
                }
                value += "\n"
                line = Array(lines[n].unicodeScalars)
                start = 0
            }
            items.append(Item(
                isHeader: false, path: table + key, lines: first ..< n + 1,
                value: value.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            n += 1
        }
        return items
    }

    /// Walk one line from `start`, carrying string and bracket state over from the line before. Returns
    /// where the line's content ends (a comment is not content), or nil when a one-line string runs off the
    /// end of its line.
    private static func advance(_ s: [Unicode.Scalar], from start: Int, mode: inout Mode, depth: inout Int) -> Int? {
        var i = start
        while i < s.count {
            let c = s[i]
            switch mode {
            case .code:
                switch c {
                case "#":
                    return i
                case "\"":
                    if quotes(s, at: i, "\"") >= 3 {
                        mode = .multiBasic
                        i += 3
                        continue
                    }
                    mode = .basic
                case "'":
                    if quotes(s, at: i, "'") >= 3 {
                        mode = .multiLiteral
                        i += 3
                        continue
                    }
                    mode = .literal
                case "[", "{":
                    depth += 1
                case "]", "}":
                    depth -= 1
                default:
                    break
                }
            case .basic:
                if c == "\\" {
                    i += 2
                    continue
                }
                if c == "\"" {
                    mode = .code
                }
            case .literal:
                if c == "'" {
                    mode = .code
                }
            case .multiBasic, .multiLiteral:
                let quote: Unicode.Scalar = mode == .multiBasic ? "\"" : "'"
                if c == "\\", mode == .multiBasic {
                    i += 2
                    continue
                }
                // Up to two quotes may sit right before the closing three, and belong to the string.
                let run = quotes(s, at: i, quote)
                if run >= 3 {
                    mode = .code
                    i += min(run, 5)
                    continue
                }
                i += max(run, 1)
                continue
            }
            i += 1
        }
        return mode == .basic || mode == .literal ? nil : s.count
    }

    private static func quotes(_ s: [Unicode.Scalar], at start: Int, _ quote: Unicode.Scalar) -> Int {
        var i = start
        while i < s.count, s[i] == quote {
            i += 1
        }
        return i - start
    }

    private static func skipSpace(_ s: [Unicode.Scalar], _ i: inout Int, newlines: Bool) {
        while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\r" || (newlines && s[i] == "\n") {
            i += 1
        }
    }

    /// A dotted key, `a."b c".'d'`, leaving `i` after the space that follows it.
    private static func keyPath(_ s: [Unicode.Scalar], _ i: inout Int) -> [String]? {
        var path: [String] = []
        while true {
            skipSpace(s, &i, newlines: false)
            guard i < s.count else {
                return nil
            }
            if s[i] == "\"" || s[i] == "'" {
                guard let part = parseString(s, &i) else {
                    return nil
                }
                path.append(part)
            } else {
                let start = i
                while i < s.count, isBare(s[i]) {
                    i += 1
                }
                guard i > start else {
                    return nil
                }
                path.append(string(s[start ..< i]))
            }
            skipSpace(s, &i, newlines: false)
            guard i < s.count, s[i] == "." else {
                return path
            }
            i += 1
        }
    }

    private static func isBare(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
    }

    private static func key(_ part: String) -> String {
        !part.isEmpty && part.unicodeScalars.allSatisfy { isBare($0) } ? part : "\"\(part.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// A one-line basic or literal string starting at `i`, with its escapes resolved.
    private static func parseString(_ s: [Unicode.Scalar], _ i: inout Int) -> String? {
        guard i < s.count, s[i] == "\"" || s[i] == "'" else {
            return nil
        }
        let quote = s[i]
        i += 1
        var out = String.UnicodeScalarView()
        while i < s.count, s[i] != quote {
            guard quote == "\"", s[i] == "\\", i + 1 < s.count else {
                out.append(s[i])
                i += 1
                continue
            }
            let e = s[i + 1]
            i += 2
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "e": out.append("\u{1B}")
            case "u", "U":
                let length = e == "u" ? 4 : 8
                guard i + length <= s.count,
                      let code = UInt32(string(s[i ..< i + length]), radix: 16),
                      let scalar = Unicode.Scalar(code)
                else {
                    return nil
                }
                out.append(scalar)
                i += length
            default:
                out.append(e)
            }
        }
        guard i < s.count else {
            return nil
        }
        i += 1
        return String(out)
    }
}

// MARK: - YAMLEditor

/// Adds and removes one child of a top-level mapping in a YAML file, as text.
///
/// Only block style is handled, which is how Goose writes its config. A top-level key, a parent whose value
/// is a non-empty flow mapping, tab indentation or a second document are all refused rather than guessed
/// at.
enum YAMLEditor {
    /// The scalars and sequences set directly under `parent.name`, or nil when there is no such child.
    static func childFields(in text: String, parent: String, name: String) -> [String: [String]]? {
        let lines = ConfigLines(text).lines
        guard let found = try? locate(parent, in: lines), let child = found.children.first(where: { $0.name == name }) else {
            return nil
        }
        var fields: [String: [String]] = [:]
        var body = child.range.dropFirst().filter { !ConfigLines.isBlank(lines[$0]) && !isComment(lines[$0]) }[...]
        guard let first = body.first else {
            return fields
        }
        let indent = ConfigLines.indent(lines[first])
        while let n = body.popFirst() {
            guard ConfigLines.indent(lines[n]) == indent, let (key, value) = keyValue(lines[n]) else {
                continue
            }
            if !value.isEmpty {
                fields[key] = value.hasPrefix("[") ? flowSequence(value) : [scalar(value)]
                continue
            }
            // A block sequence may sit at the key's own indent, which is how serde writes it.
            var items: [String] = []
            while let next = body.first, ConfigLines.indent(lines[next]) >= indent,
                  case let item = lines[next].drop(while: { $0 == " " }), item.hasPrefix("- ") || item == "-"
            {
                items.append(scalar(String(item.dropFirst(1))))
                body.removeFirst()
            }
            fields[key] = items
        }
        return fields
    }

    /// Replace `parent.name` with `body`, indented under it. The child is added at the end of `parent`
    /// when it is new, and `parent` at the end of the file when that is missing too.
    static func setChild(in text: String, parent: String, name: String, body: [String]) throws -> String {
        var file = ConfigLines(text)
        guard let found = try locate(parent, in: file.lines) else {
            file.lines += ([key(parent) + ":"] + childLines(name, body, indent: 2)).map { file.fresh($0) }
            return file.text
        }
        let block = childLines(name, body, indent: found.childIndent ?? 2).map { file.fresh($0) }
        if let child = found.children.first(where: { $0.name == name }) {
            file.lines.replaceSubrange(child.range, with: block)
        } else {
            file.lines.insert(contentsOf: block, at: found.end)
            if found.emptyFlow {
                file.lines[found.parentLine] = file.fresh(key(parent) + ":")
            }
        }
        return file.text
    }

    /// Drop `parent.name`, and `parent` with it when that was its only child. Nil when it was not there.
    static func removeChild(in text: String, parent: String, name: String) throws -> String? {
        var file = ConfigLines(text)
        guard let found = try locate(parent, in: file.lines), let child = found.children.first(where: { $0.name == name }) else {
            return nil
        }
        file.remove([found.children.count == 1 ? found.parentLine ..< found.end : child.range])
        return file.text
    }

    // MARK: Scanning

    private struct Found {
        let parentLine: Int
        /// One past the parent's last line of content.
        let end: Int
        let childIndent: Int?
        let children: [(name: String, range: Range<Int>)]
        /// `parent: {}` or `parent: null`, which has to become `parent:` once it holds a child.
        let emptyFlow: Bool
    }

    private static func locate(_ parent: String, in lines: [String]) throws -> Found? {
        var seenContent = false
        var topLevel: [(line: Int, key: String, value: String)] = []
        for (n, line) in lines.enumerated() where !ConfigLines.isBlank(line) && !isComment(line) {
            if line.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
                throw ConfigLayoutError.unsupported
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed.hasPrefix("--- ") || trimmed == "..." {
                guard !seenContent else {
                    throw ConfigLayoutError.unsupported
                }
                continue
            }
            seenContent = true
            guard ConfigLines.indent(line) == 0 else {
                continue
            }
            guard let (key, value) = keyValue(line) else {
                throw ConfigLayoutError.unsupported
            }
            topLevel.append((n, key, value))
        }

        guard let index = topLevel.firstIndex(where: { $0.key == parent }) else {
            return nil
        }
        let parentLine = topLevel[index].line
        let value = topLevel[index].value
        let emptyFlow = ["{}", "~", "null"].contains(value)
        guard value.isEmpty || emptyFlow else {
            throw ConfigLayoutError.unsupported
        }

        var end = index + 1 < topLevel.count ? topLevel[index + 1].line : lines.count
        while end > parentLine + 1, ConfigLines.isBlank(lines[end - 1]) || isComment(lines[end - 1]) {
            end -= 1
        }
        let content = (parentLine + 1 ..< end).filter { !ConfigLines.isBlank(lines[$0]) && !isComment(lines[$0]) }
        guard !emptyFlow || content.isEmpty else {
            throw ConfigLayoutError.unsupported
        }
        guard let first = content.first else {
            return Found(parentLine: parentLine, end: parentLine + 1, childIndent: nil, children: [], emptyFlow: emptyFlow)
        }

        let childIndent = ConfigLines.indent(lines[first])
        guard !lines[first].drop(while: { $0 == " " }).hasPrefix("-") else {
            throw ConfigLayoutError.unsupported
        }
        var starts: [(name: String, line: Int)] = []
        for n in content {
            let indent = ConfigLines.indent(lines[n])
            guard indent >= childIndent else {
                throw ConfigLayoutError.unsupported
            }
            guard indent == childIndent else {
                continue
            }
            guard let (key, _) = keyValue(lines[n]) else {
                throw ConfigLayoutError.unsupported
            }
            starts.append((key, n))
        }
        let children = starts.enumerated().map { m, start -> (name: String, range: Range<Int>) in
            var stop = m + 1 < starts.count ? starts[m + 1].line : end
            while stop > start.line + 1, ConfigLines.isBlank(lines[stop - 1]) || isComment(lines[stop - 1]) {
                stop -= 1
            }
            return (start.name, start.line ..< stop)
        }
        return Found(parentLine: parentLine, end: end, childIndent: childIndent, children: children, emptyFlow: false)
    }

    private static func isComment(_ line: String) -> Bool {
        line.drop { $0 == " " }.hasPrefix("#")
    }

    private static func childLines(_ name: String, _ body: [String], indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        return ["\(pad)\(key(name)):"] + body.map { "\(pad)  \($0)" }
    }

    private static func key(_ name: String) -> String {
        name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } ? name : "\"\(name)\""
    }

    /// `key: value` with the comment taken off the value. Nil for a line that is not a mapping entry.
    private static func keyValue(_ line: String) -> (String, String)? {
        let s = Array(line.drop { $0 == " " }.trimmingCharacters(in: .newlines).unicodeScalars)
        guard let first = s.first, first != "-" || s.count > 1 && s[1] != " " else {
            return nil
        }
        var i = 0
        var key: String
        if first == "\"" || first == "'" {
            i = 1
            while i < s.count, s[i] != first {
                i += s[i] == "\\" && first == "\"" ? 2 : 1
            }
            guard i < s.count else {
                return nil
            }
            key = scalar(string(s[0 ... i]))
            i += 1
            guard i < s.count, s[i] == ":" else {
                return nil
            }
        } else {
            while i < s.count, !(s[i] == ":" && (i + 1 == s.count || s[i + 1] == " ")) {
                i += 1
            }
            guard i < s.count else {
                return nil
            }
            key = string(s[0 ..< i]).trimmingCharacters(in: .whitespaces)
        }
        var value = string(s[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #") {
            value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else if value.hasPrefix("#") {
            value = ""
        }
        return key.isEmpty ? nil : (key, value)
    }

    private static func flowSequence(_ value: String) -> [String] {
        value.dropFirst().prefix { $0 != "]" }
            .split(separator: ",")
            .map { scalar($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// A scalar without its quotes. Double quotes take JSON's escapes, so the JSON decoder reads them.
    private static func scalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2,
           let data = "[\(value)]".data(using: .utf8),
           let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String], let first = decoded.first
        {
            return first
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}

// MARK: - ShellRCEditor

/// Adds and removes one command in a Bash file such as Crush's `crushrc`, as text. A command is matched by
/// its first words with quotes resolved, so `mcp add clop` finds it however it was quoted or split over
/// lines with `\`.
enum ShellRCEditor {
    /// The words of the first command that starts with `prefix`, or nil when none does.
    static func words(in text: String, matching prefix: [String]) -> [String]? {
        commands(in: ConfigLines(text).lines).first { $0.words.starts(with: prefix) }?.words
    }

    /// Put `line` where the first matching command was, dropping any others, or at the end of the file.
    static func setCommand(in text: String, matching prefix: [String], with line: String) throws -> String {
        var file = ConfigLines(text)
        let matches = commands(in: file.lines).filter { $0.words.starts(with: prefix) }
        guard let first = matches.first else {
            file.lines.append(file.fresh(line))
            return file.text
        }
        let rest = matches.dropFirst().map(\.lines)
        file.lines.replaceSubrange(first.lines, with: [file.fresh(line)])
        let shift = first.lines.count - 1
        file.remove(rest.map { $0.lowerBound - shift ..< $0.upperBound - shift })
        return file.text
    }

    /// Drop every command that starts with `prefix`. Nil when there was none.
    static func removeCommand(in text: String, matching prefix: [String]) throws -> String? {
        var file = ConfigLines(text)
        let matches = commands(in: file.lines).filter { $0.words.starts(with: prefix) }
        guard !matches.isEmpty else {
            return nil
        }
        file.remove(matches.map(\.lines))
        return file.text
    }

    /// One word as Bash reads it back: bare when it is plain, single-quoted otherwise.
    static func quote(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "@%+=:,./_-".unicodeScalars.contains($0)
        }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Scanning

    /// A command's lines, and the words of its first simple command.
    private static func commands(in lines: [String]) -> [(lines: Range<Int>, words: [String])] {
        var out: [(lines: Range<Int>, words: [String])] = []
        var n = 0
        while n < lines.count {
            let start = n
            var joined = lines[n]
            var result = split(joined)
            // A trailing `\` or a quote still open carries the command onto the next line.
            while result.continues, n + 1 < lines.count {
                n += 1
                joined += "\n" + lines[n]
                result = split(joined)
            }
            if !result.words.isEmpty {
                out.append((start ..< n + 1, result.words))
            }
            n += 1
        }
        return out
    }

    /// The words up to the first `;`, `&`, `|` or comment, quotes resolved. `continues` is set when the
    /// text ends inside a quote or on a line-continuing backslash.
    private static func split(_ text: String) -> (words: [String], continues: Bool) {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if let q = quote {
                if c == q {
                    quote = nil
                } else if q == "\"", c == "\\", let next = chars.first, "\"\\$`\n".contains(next) {
                    chars.removeFirst()
                    if next != "\n" {
                        word.append(next)
                    }
                } else {
                    word.append(c)
                }
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                inWord = true
            case "\\":
                guard let next = chars.popFirst(), !(next == "\r" && chars.isEmpty) else {
                    return (words, true)
                }
                if next != "\n", next != "\r\n" {
                    word.append(next)
                    inWord = true
                }
            case " ", "\t", "\r", "\n", "\r\n":
                if inWord {
                    words.append(word)
                    word = ""
                    inWord = false
                }
            case "#" where !inWord, ";", "&", "|":
                if inWord {
                    words.append(word)
                }
                return (words, false)
            default:
                word.append(c)
                inWord = true
            }
        }
        if quote != nil {
            return (words, true)
        }
        if inWord {
            words.append(word)
        }
        return (words, false)
    }
}
