import AppKit
import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

@MainActor final class LastFocusedAppTracker: ObservableObject {
    private init() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier
        {
            bundleId = id
            name = app.localizedName
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier
            else { return }
            mainActor {
                LastFocusedAppTracker.shared.bundleId = id
                LastFocusedAppTracker.shared.name = app.localizedName
            }
        }
    }

    static let shared = LastFocusedAppTracker()

    @Published var bundleId: String?
    @Published var name: String?

}

@MainActor private var iconCache: [String: NSImage] = [:]

@MainActor private func icon(for bundleId: String, path: FilePath?) -> NSImage {
    if let cached = iconCache[bundleId] { return cached }
    let image: NSImage = if let path, path.exists {
        NSWorkspace.shared.icon(forFile: path.string)
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
        NSWorkspace.shared.icon(forFile: url.path)
    } else {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }
    iconCache[bundleId] = image
    return image
}

@MainActor private func displayName(for bundleId: String, path: FilePath?) -> String {
    if let path, path.exists, let bundle = Bundle(path: path.string) {
        return bundle.name
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
       let bundle = Bundle(url: url)
    {
        return bundle.name
    }
    return bundleId
}

struct IgnoredAppsPicker: View {
    @Binding var bundleIds: Set<String>

    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bundleIds.isEmpty {
                Text("No apps ignored. Clipboard events from all apps are processed.")
                    .round(11, weight: .regular)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
            } else {
                VStack(spacing: 2) {
                    ForEach(sortedBundleIds, id: \.self) { id in
                        appRow(bundleId: id)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
            }

            HStack(spacing: 6) {
                Menu {
                    if let id = LastFocusedAppTracker.shared.bundleId, !bundleIds.contains(id) {
                        let appName = LastFocusedAppTracker.shared.name ?? id
                        Button {
                            bundleIds.insert(id)
                        } label: {
                            Label("Last focused: \(appName)", systemImage: "rectangle.inset.filled.and.person.filled")
                        }
                        Divider()
                    }

                    if selectableApps.isEmpty {
                        Text("Loading installed apps…").disabled(true)
                    } else {
                        ForEach(selectableApps, id: \.bundleIdentifier) { app in
                            Button {
                                pathByBundleId[app.bundleIdentifier] = app.path
                                bundleIds.insert(app.bundleIdentifier)
                            } label: {
                                Label {
                                    Text(app.name)
                                } icon: {
                                    SwiftUI.Image(nsImage: icon(for: app.bundleIdentifier, path: app.path))
                                        .resizable()
                                        .frame(width: 12, height: 12)
                                }
                            }
                        }
                    }

                    Divider()
                    Button("Choose app…") { chooseApp() }
                } label: {
                    Label("Add app", systemImage: "plus")
                        .font(.round(11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!enabled)

                Spacer()

                if !bundleIds.isEmpty {
                    Button {
                        bundleIds = []
                    } label: {
                        Text("Clear all").font(.round(10, weight: .regular))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .disabled(!enabled)
                }
            }
        }
        .onAppear { loadInstalledApps() }
    }

    @State private var installedApps: [InstalledApp] = []
    @State private var appQuery: Any?
    @State private var pathByBundleId: [String: FilePath] = [:]

    private var sortedBundleIds: [String] {
        bundleIds.sorted { displayName(for: $0, path: pathByBundleId[$0]).localizedCaseInsensitiveCompare(displayName(for: $1, path: pathByBundleId[$1])) == .orderedAscending }
    }

    private var selectableApps: [InstalledApp] {
        installedApps
            .filter { !bundleIds.contains($0.bundleIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func appRow(bundleId: String) -> some View {
        let path = pathByBundleId[bundleId]
        HStack(spacing: 8) {
            SwiftUI.Image(nsImage: icon(for: bundleId, path: path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName(for: bundleId, path: path))
                    .round(12, weight: .medium)
                Text(bundleId)
                    .mono(10)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                bundleIds.remove(bundleId)
            } label: {
                SwiftUI.Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from ignore list")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func loadInstalledApps() {
        guard appQuery == nil, installedApps.isEmpty else { return }
        appQuery = queryInstalledApps { apps in
            mainActor {
                let filtered = apps
                    .filter { isAppPathRelevant($0.path.string) }
                    .reduce(into: [String: InstalledApp]()) { acc, app in
                        if acc[app.bundleIdentifier] == nil { acc[app.bundleIdentifier] = app }
                    }
                installedApps = Array(filtered.values)
                for app in installedApps where pathByBundleId[app.bundleIdentifier] == nil {
                    pathByBundleId[app.bundleIdentifier] = app.path
                }
                appQuery = nil
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            pathByBundleId[id] = url.filePath
            bundleIds.insert(id)
        }
    }
}

private struct IgnoredAppsPickerPreview: View {
    @State var ids: Set<String>

    var body: some View {
        IgnoredAppsPicker(bundleIds: $ids)
            .padding()
            .frame(width: 360)
    }
}

#Preview("Empty") {
    IgnoredAppsPickerPreview(ids: [])
}

#Preview("Populated") {
    IgnoredAppsPickerPreview(ids: ["com.apple.Safari", "com.apple.dt.Xcode", "com.tinyspeck.slackmacgap"])
}
