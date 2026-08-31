import AppKit
import Defaults
import Lowtech
import LowtechPro
import SwiftUI

// MARK: - MCPSettingsView

/// Clop's MCP server, and which agents it is installed into. The server is bundled; installing writes
/// one entry into an agent's own config file.
///
/// Same job as rcmd's `AgentsPane` and Crank's `MCPSettingsPane`, built out of Clop's own Form rows
/// rather than their custom controls. Keep the behaviour in step, not the markup.
struct MCPSettingsView: View {
    var body: some View {
        Form {
            Section(header: SectionHeader(title: "MCP")) {
                if !proactive {
                    proRow
                }
                Toggle(isOn: $mcpEnabled) {
                    Text("Enable MCP").regular(13)
                        + Text("\nAllow agents to control Clop, run file optimisations, change settings, write pipelines").round(11, weight: .regular).foregroundColor(.secondary)
                }
                .disabled(!proactive)
                .onChange(of: mcpEnabled) { _ in MCPInstaller.writeServerCard() }
                .searchAnchor("mcp.main.mcpEnabled")

                Toggle(isOn: $mcpAllowScriptSteps) {
                    Text("Allow agents to write arbitrary scripts in pipelines").regular(13)
                        + Text("\nUsing scripts in pipelines allows for flexible operations but can be dangerous if not properly verified").round(11, weight: .regular).foregroundColor(.secondary)
                }
                .disabled(!proactive || !mcpEnabled)
                .onChange(of: mcpAllowScriptSteps) { on in
                    guard on else { return }
                    if !askAboutScripts() {
                        mcpAllowScriptSteps = false
                    }
                }
                .searchAnchor("mcp.main.mcpAllowScriptSteps")
            }

            Section(header: SectionHeader(title: "Install in")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MCPInstaller.clients) { client in
                        clientRow(client)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: SectionHeader(title: "Install by hand")) {
                VStack(alignment: .leading, spacing: 12) {
                    CopyableValueRow(title: "Command line", value: MCPInstaller.cliCommand)
                    CopyableValueRow(title: "Server", value: MCPInstaller.cliPath + " " + MCPInstaller.serveArgs.joined(separator: " "))
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    @State private var states: [String: MCPInstaller.ConfigState] = [:]
    @State private var failures: [String: String] = [:]

    @Default(.mcpEnabled) private var mcpEnabled
    @Default(.mcpAllowScriptSteps) private var mcpAllowScriptSteps

    private var proRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Needs Clop Pro").regular(13)
            Spacer()
            Button("Manage Licence") { manageLicenceInSettings() }
        }
    }

    private func clientRow(_ client: MCPInstaller.Client) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).medium(13)
                Text(rowDetail(client))
                    .round(11)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            switch states[client.id] ?? .notInstalled {
            case .installed:
                Button("Remove") { apply(MCPInstaller.remove(client), to: client) }
                    .tint(.red)
            case .unusable:
                // Not a disabled Install: there is no members list to write into, so the only move left
                // is to open the file.
                Button("Show file") { MCPInstaller.revealConfig(client) }
            case .notInstalled:
                Button("Install") { apply(MCPInstaller.install(client), to: client) }
            }
        }
    }

    private func apply(_ result: Result<Void, Error>, to client: MCPInstaller.Client) {
        if case let .failure(error) = result {
            failures[client.id] = error.localizedDescription
        } else {
            // A later success has to clear the earlier failure, or the row keeps showing an error it no
            // longer has.
            failures[client.id] = nil
        }
        refresh()
    }

    private func rowDetail(_ client: MCPInstaller.Client) -> String {
        if let failure = failures[client.id] {
            return failure
        }
        switch states[client.id] ?? .notInstalled {
        case .unusable:
            return "\(client.path) is not a JSON object."
        case .installed, .notInstalled:
            // Once it is added, the useful detail is where it landed.
            return client.isPresent || states[client.id] == .installed
                ? client.path
                : "Not installed on this Mac."
        }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: MCPInstaller.clients.map { ($0.id, MCPInstaller.state($0)) })
    }

    private func askAboutScripts() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow agents to write scripts?"
        alert.informativeText = """
        A script step runs arbitrary code inside a pipeline.

        Without human verification, it can result in irretrievable file losses as scripts are not sandboxed in any way.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - CopyableValueRow

/// A row whose value is the copy control: click the pill to copy it.
private struct CopyableValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).medium(13)
            CopyablePill(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CopyablePill

private struct CopyablePill: View {
    let value: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            mainAsyncAfter(ms: 1200) { copied = false }
        } label: {
            HStack(spacing: 5) {
                // `SwiftUI.Image` qualified: Clop has its own `Image` type for optimisable files.
                SwiftUI.Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    // Fixed footprint so the glyph swap can't reflow the pill.
                    .frame(width: 12, height: 12)
                Text(copied ? "Copied!" : value)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Copies the line")
    }

    @State private var copied = false
}
