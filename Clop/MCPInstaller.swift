import AppKit
import Defaults
import Foundation
import LowtechPro
import os

private let mcpLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lowtechguys.Clop", category: "MCP")

// MARK: - MCPInstaller

/// Registers Clop's MCP server with the agents people actually use, by merging one entry into each
/// client's own config file. Everything else in those files is preserved: they are read, one key is
/// added, and they are written back.
///
/// Same shape as rcmd's and Crank's `MCPInstaller`; keep the three in step.
enum MCPInstaller {
    /// The config layouts in the wild. They differ only in which top-level key holds the servers and
    /// how the command is shaped.
    enum Style {
        case mcpServers // Claude Code, Claude Desktop, Cursor, Windsurf
        case vsCode // "servers", command + args
        case zed // "context_servers", nested command object
    }

    struct Client: Identifiable {
        let id: String
        let name: String
        let path: String
        let style: Style
        /// A file or app that shows the client is on this Mac.
        let evidence: [String]

        var url: URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        /// Where the bytes actually live. These are exactly the files people keep in a dotfiles repo
        /// and symlink into place, and an atomic write against a symlink replaces the link with a
        /// regular file. See `resolvedConfigURL`.
        var writeURL: URL {
            resolvedConfigURL(url)
        }

        var isPresent: Bool {
            FileManager.default.fileExists(atPath: url.path)
                || evidence.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
        }
    }

    // MARK: - State

    enum InstallError: LocalizedError {
        case missingServer

        var errorDescription: String? {
            switch self {
            case .missingServer: "Clop's CLI is missing from the app bundle, so the MCP server cannot run."
            }
        }
    }

    /// What the client's config file says.
    enum ConfigState {
        case installed
        case notInstalled
        /// The file is there and is not an object even with its comments taken out, so there is no
        /// members list to add Clop to.
        case unusable
    }

    static let serverName = "clop"

    static let clients: [Client] = [
        Client(
            id: "claude-code", name: "Claude Code",
            path: "~/.claude.json", style: .mcpServers,
            evidence: ["/opt/homebrew/bin/claude", "~/.claude"]
        ),
        Client(
            id: "claude-desktop", name: "Claude Desktop",
            path: "~/Library/Application Support/Claude/claude_desktop_config.json", style: .mcpServers,
            evidence: ["/Applications/Claude.app"]
        ),
        Client(
            id: "cursor", name: "Cursor",
            path: "~/.cursor/mcp.json", style: .mcpServers,
            evidence: ["/Applications/Cursor.app", "~/.cursor"]
        ),
        Client(
            id: "vscode", name: "VS Code",
            path: "~/Library/Application Support/Code/User/mcp.json", style: .vsCode,
            evidence: ["/Applications/Visual Studio Code.app", "~/Library/Application Support/Code"]
        ),
        Client(
            id: "windsurf", name: "Windsurf",
            path: "~/.codeium/windsurf/mcp_config.json", style: .mcpServers,
            evidence: ["/Applications/Windsurf.app", "~/.codeium"]
        ),
        Client(
            id: "zed", name: "Zed",
            path: "~/.config/zed/settings.json", style: .zed,
            evidence: ["/Applications/Zed.app", "~/.config/zed"]
        ),
    ]

    /// The arguments that turn the CLI into the server.
    static let serveArgs = ["mcp", "serve"]

    // MARK: - Paths

    /// The CLI, which IS the MCP server. Bundled beside the app, so an agent drives the same binary
    /// the user's own `clop` command does.
    ///
    /// It used to be a bundled script that needed an interpreter found at launch, and on a Mac with
    /// no Command Line Tools and no Homebrew the server did not run at all. The CLI is already
    /// signed, notarised and inside the app's seal.
    static var cliPath: String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/ClopCLI").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return ("~/.local/bin/clop" as NSString).expandingTildeInPath
    }

    /// Whether the server can actually run. Installing without it writes a config entry that looks
    /// fine and starts nothing, so every caller checks this first.
    static var scriptExists: Bool {
        FileManager.default.isExecutableFile(atPath: cliPath)
    }

    /// The one-liner for a client that is driven from a terminal.
    static var cliCommand: String {
        "claude mcp add --scope user clop -- \(cliPath) \(serveArgs.joined(separator: " "))"
    }

    static var cardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".well-known/mcp/clop.json")
    }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clop", isDirectory: true)
    }

    // MARK: - The switch

    @MainActor static func setEnabled(_ enabled: Bool) {
        // Pro only, and unlike the optimisation counters this is a wall rather than a nag: there is no
        // free MCP mode. Turning it off never needs a licence, so a lapsed licence can still be
        // switched off rather than being stuck on.
        guard !enabled || proactive else {
            mcpLog.info("MCP enable refused, no Pro licence")
            return
        }
        Defaults[.mcpEnabled] = enabled
        writeServerCard()
        mcpLog.info("MCP \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    /// Handles `clop://mcp/start` and `clop://mcp/stop`. Returns false for a URL that is not ours, so
    /// the caller can keep handling it.
    ///
    /// Start ASKS. The URL is what an agent opens when a tool of its own was refused, so nothing but
    /// this alert stands between "an agent decided to" and the switch being on. Turning it back on
    /// behind someone who just turned it off would make every line of copy about this a lie. Stop
    /// needs no alert: it only ever takes permission away.
    @MainActor static func handle(url: URL) -> Bool {
        guard url.scheme == "clop", url.host == "mcp" else { return false }
        switch url.lastPathComponent {
        case "start":
            guard !Defaults[.mcpEnabled] else { return true }
            guard proactive else {
                showProRequired()
                return true
            }
            if askToEnable() {
                setEnabled(true)
            }
        case "stop": setEnabled(false)
        default: return false
        }
        return true
    }

    // MARK: - Server card

    /// A card an agent can read to find Clop, written on every launch whether or not the switch is on.
    ///
    /// There is no shipped standard for discovering a local MCP server, so this follows the shape of
    /// the proposed `.well-known/mcp` card and drops it in two places an agent is likely to look. It
    /// carries no credentials: Clop's transport is a Mach port that any process of this user can
    /// already open.
    ///
    /// Nothing here may suggest relaunching Clop. MCP is Pro so restarting buys an agent nothing on
    /// this path, but the same words would teach the trick for the CLI and Shortcuts paths, whose free
    /// counters do reset on relaunch by design.
    @MainActor static func writeServerCard() {
        let card: [String: Any] = [
            "name": serverName,
            "displayName": "Clop",
            "description": "Image, video, PDF and audio optimisation. Run pipelines over files, downscale, convert, crop, author new pipelines, and read or change any Clop setting.",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "app": ["bundleID": "com.lowtechguys.Clop", "path": Bundle.main.bundlePath],
            "enabled": Defaults[.mcpEnabled],
            "requiresPro": true,
            "pro": proactive,
            "transport": [
                "type": "stdio",
                "command": cliPath,
                "args": serveArgs,
            ],
            "control": [
                "start": "open clop://mcp/start",
                "stop": "open clop://mcp/stop",
                "note": "Clop's MCP server needs Clop Pro. With a licence, reading works whether or not it is started; changes are refused until it is. Starting sticks across launches until it is stopped.",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: card, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }

        // Both cards go through the symlink resolver for the same reason the client configs do:
        // `~/.well-known` is a folder people keep in a dotfiles repo.
        for url in [supportDirectory.appendingPathComponent("mcp.json"), cardURL].map(resolvedConfigURL) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func state(_ client: Client) -> ConfigState {
        do {
            guard let root = try JSONCEditor.read(client.url) else { return .notInstalled }
            let installed = (root[serversKey(client.style)] as? [String: Any])?[serverName] != nil
            return installed ? .installed : .notInstalled
        } catch {
            return .unusable
        }
    }

    static func isInstalled(_ client: Client) -> Bool {
        state(client) == .installed
    }

    // MARK: - Install and remove

    @discardableResult
    static func install(_ client: Client) -> Result<Void, Error> {
        guard scriptExists else {
            return .failure(InstallError.missingServer)
        }
        return edit(client) { text in
            try JSONCEditor.setMember(in: text, container: serversKey(client.style), name: serverName, member: entry(for: client.style))
        }
    }

    @discardableResult
    static func remove(_ client: Client) -> Result<Void, Error> {
        edit(client) { text in
            // nil means ours was not in there, and nothing is written: a file that was never ours must
            // not be touched on the way out.
            JSONCEditor.removeMember(in: text, container: serversKey(client.style), name: serverName)
        }
    }

    static func revealConfig(_ client: Client) {
        NSWorkspace.shared.activateFileViewerSelecting([client.url])
    }

    @MainActor private static func askToEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let agents control Clop through MCP?"
        alert.informativeText = """
        An AI agent asked for MCP access which allows it to optimise, convert and downscale your files, change any setting, and write or run pipelines.

        You can also toggle this in Clop's Settings -> MCP.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor private static func showProRequired() {
        let alert = NSAlert()
        alert.messageText = "MCP needs Clop Pro"
        alert.informativeText = "An agent asked for access to controlling Clop through MCP. That is a Pro feature."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Manage Licence")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            manageLicenceInSettings()
        }
    }

    private static func serversKey(_ style: Style) -> String {
        switch style {
        case .mcpServers: "mcpServers"
        case .vsCode: "servers"
        case .zed: "context_servers"
        }
    }

    /// The member, already formatted. The file is edited as text, so this is what lands in it verbatim.
    private static func entry(for style: Style) -> String {
        let command = json(cliPath)
        let args = serveArgs.map(json).joined(separator: ", ")
        return switch style {
        case .zed:
            """
            {
              "source": "custom",
              "command": {
                "path": \(command),
                "args": [\(args)]
              }
            }
            """
        case .vsCode:
            """
            {
              "type": "stdio",
              "command": \(command),
              "args": [\(args)]
            }
            """
        case .mcpServers:
            """
            {
              "command": \(command),
              "args": [\(args)]
            }
            """
        }
    }

    /// A path can hold a quote or a backslash, so it goes through the encoder rather than into a
    /// string literal.
    private static func json(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\(value)\"" }
        return String(array.dropFirst().dropLast())
    }

    /// Read the file as text, splice it, write it back. `change` returns nil when there is nothing to
    /// do, and then nothing is written at all.
    ///
    /// The read happens as late as possible: Claude Code keeps writing `~/.claude.json` while it runs,
    /// and anything it puts there between this read and this write is lost. The window is microseconds
    /// and it is not zero; a client that rewrites its config on a timer is a client to install into
    /// while it is closed.
    private static func edit(_ client: Client, _ change: (String) throws -> String?) -> Result<Void, Error> {
        do {
            let target = client.writeURL
            let existing = FileManager.default.fileExists(atPath: target.path)
                ? try String(contentsOf: target, encoding: .utf8)
                : ""
            guard let updated = try change(existing), updated != existing else { return .success(()) }

            let dir = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try updated.write(to: target, atomically: true, encoding: .utf8)
            mcpLog.info("Wrote MCP entry to \(client.path, privacy: .public)")
            return .success(())
        } catch {
            mcpLog.error("MCP install failed for \(client.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }
}
