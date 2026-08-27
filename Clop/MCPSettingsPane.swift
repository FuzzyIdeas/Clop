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
            Section(header: SectionHeader(
                title: "MCP",
                subtitle: "Clop ships an MCP server: tools for optimising files, authoring pipelines and reading or changing settings"
            )) {
                if !proactive {
                    proRow
                }
                Toggle(isOn: $mcpEnabled) {
                    Text("Accept changes from agents").regular(13)
                        + Text("\nOptimising files, changing settings, saving pipelines. Reading settings and pipelines stays allowed either way").round(11, weight: .regular).foregroundColor(.secondary)
                }
                .disabled(!proactive)
                .onChange(of: mcpEnabled) { _ in MCPInstaller.writeServerCard() }

                Toggle(isOn: $mcpAllowScriptSteps) {
                    Text("Allow agents to write script steps").regular(13)
                        + Text("\nA script step runs arbitrary code. Off means Clop refuses a pipeline from an agent that contains one, and names the step. Scripts you write yourself are unaffected").round(11, weight: .regular)
                        .foregroundColor(.secondary)
                }
                .disabled(!proactive || !mcpEnabled)
                .onChange(of: mcpAllowScriptSteps) { on in
                    guard on else { return }
                    // Asking on the way on only. Turning it off never needs a confirmation.
                    if !askAboutScripts() { mcpAllowScriptSteps = false }
                }
            }

            Section(header: SectionHeader(
                title: "Installed in",
                subtitle: "Adds one entry to the agent's own config file, leaving everything else in it alone"
            )) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MCPInstaller.clients) { client in
                        clientRow(client)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: SectionHeader(
                title: "Install by hand",
                subtitle: "For an agent that is not in the list"
            )) {
                VStack(alignment: .leading, spacing: 12) {
                    CopyableValueRow(
                        title: "Command line",
                        detail: "For an agent that registers MCP servers from a terminal",
                        value: MCPInstaller.cliCommand
                    )
                    CopyableValueRow(
                        title: "Server path",
                        detail: "Point any other MCP client at this file, run with python3",
                        value: MCPInstaller.scriptPath
                    )
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
            Text("MCP needs Clop Pro").regular(13)
                + Text("\nAgents can drive everything Clop does. That is a Pro feature").round(11, weight: .regular).foregroundColor(.secondary)
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
        case .installed:
            return client.detail
        case .unusable:
            return "\(client.path) is not a JSON object."
        case .notInstalled:
            return client.isPresent ? client.path : "Not installed on this Mac."
        }
    }

    private func refresh() {
        states = Dictionary(uniqueKeysWithValues: MCPInstaller.clients.map { ($0.id, MCPInstaller.state($0)) })
    }

    private func askAboutScripts() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Let agents write script steps?"
        alert.informativeText = """
        A script step runs whatever code it contains, with your account's access to your files.

        Clop's built-in steps cover optimising, converting, downscaling and cropping. An agent only needs a script for something none of those can do.
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
    let detail: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).medium(13)
            Text(detail)
                .round(11)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
