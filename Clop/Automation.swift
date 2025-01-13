import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

extension Defaults.Keys {
    static let shortcutToRunOnImage = Key<[String: Shortcut]>("shortcutToRunOnImage", default: [:])
    static let shortcutToRunOnVideo = Key<[String: Shortcut]>("shortcutToRunOnVideo", default: [:])
    static let shortcutToRunOnPdf = Key<[String: Shortcut]>("shortcutToRunOnPdf", default: [:])
}

extension Optimiser {
    nonisolated func runShortcut(_ shortcut: Shortcut, outFile: FilePath, url: URL) -> Process? {
        guard let proc = runShortcutProcess(shortcut, url.path, outFile: outFile.string) else {
            return nil
        }

        mainActor { [weak self] in
            self?.running = true
            self?.progress = Progress()
            self?.operation = "❯ \(shortcut.name)"
            self?.processes = [proc]
        }
        return proc
    }

    func runAutomation(outFile: FilePath) -> Process? {
        guard !inRemoval, !SWIFTUI_PREVIEW, let source, let url else {
            return nil
        }

        guard let key = type.shortcutKey, let shortcut = Defaults[key][source.string] else {
            return nil
        }
        return runShortcut(shortcut, outFile: outFile, url: url)
    }

    nonisolated func runAutomation(outFile: FilePath, source: OptimisationSource?, url: URL?, type: ItemType) -> Process? {
        guard let source, let url, let key = type.shortcutKey else {
            return nil
        }

        guard let shortcut = Defaults[key][source.string] else {
            return nil
        }
        return runShortcut(shortcut, outFile: outFile, url: url)
    }
}

struct Shortcut: Codable, Hashable, Defaults.Serializable, Identifiable {
    var name: String
    var identifier: String

    var id: String { identifier }
    var url: URL {
        if let url = identifier.url {
            return url
        }
        guard let id = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "shortcuts://".url!
        }
        return "shortcuts://open-shortcut?id=\(id)".url!
    }
}

struct CachedShortcuts {
    var shortcuts: [Shortcut] = []
    var lastUpdate = Date()
    var folder: String?
}
struct CachedShortcutsMap {
    var shortcuts: [String: [Shortcut]] = [:]
    var lastUpdate = Date()
}

var shortcutsCacheByFolder: [String?: CachedShortcuts] = [:]
var shortcutsMapCache: CachedShortcutsMap?

func getShortcutsOrCached(folder: String? = nil) -> [Shortcut]? {
    if let cached = mainThread({ shortcutsCacheByFolder[folder] }), cached.lastUpdate.timeIntervalSinceNow > -60 {
        return cached.shortcuts
    }

    guard let shortcuts = getShortcuts(folder: folder) else {
        return nil
    }

    mainAsync {
        shortcutsCacheByFolder[folder] = CachedShortcuts(shortcuts: shortcuts, lastUpdate: Date(), folder: folder)
    }
    return shortcuts
}

func getShortcutsMapOrCached() -> [String: [Shortcut]] {
    if let cached = mainThread({ shortcutsMapCache }), cached.lastUpdate.timeIntervalSinceNow > -60 {
        return cached.shortcuts
    }

    let shortcutsMap = getShortcutsMap()

    mainAsync {
        shortcutsMapCache = CachedShortcutsMap(shortcuts: shortcutsMap, lastUpdate: Date())
    }
    return shortcutsMap
}

func getShortcuts(folder: String? = nil) -> [Shortcut]? {
    guard !SWIFTUI_PREVIEW else { return nil }
    log.debug("Getting shortcuts for folder \(folder ?? "nil")")

    let additionalArgs = folder.map { ["--folder-name", $0] } ?? []
    guard let output = shell("/usr/bin/shortcuts", args: ["list", "--show-identifiers"] + additionalArgs, timeout: 2).o else {
        return nil
    }

    let lines = output.split(separator: "\n")
    var shortcuts: [Shortcut] = []
    for line in lines {
        let parts = line.split(separator: " ")
        guard let identifier = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) else {
            continue
        }
        let name = parts.dropLast().joined(separator: " ")
        shortcuts.append(Shortcut(name: name, identifier: identifier))
    }

    guard shortcuts.count > 0 else {
        return nil
    }

    return shortcuts
}

func getShortcutsMap() -> [String: [Shortcut]] {
    guard let folders: [String] = shell("/usr/bin/shortcuts", args: ["list", "--folders"], timeout: 2).o?.split(separator: "\n").map({ s in String(s) })
    else { return [:] }

    if let cached = mainThread({ shortcutsMapCache }), cached.lastUpdate.timeIntervalSinceNow > -60 {
        return cached.shortcuts
    }

    return (folders + ["none"]).compactMap { folder -> (String, [Shortcut])? in
        guard let shortcuts = getShortcutsOrCached(folder: folder) else {
            return nil
        }
        return (folder == "none" ? "Other" : folder, shortcuts)
    }.reduce(into: [:]) { $0[$1.0] = $1.1 }
}

func runShortcutProcess(_ shortcut: Shortcut, _ file: String, outFile: String) -> Process? {
    shellProc("/usr/bin/shortcuts", args: ["run", shortcut.identifier, "--input-path", file, "--output-path", outFile])
}

struct ShortcutsIcon: View {
    var size: CGFloat = 20

    var body: some View {
        VStack(spacing: -size / 1.8) {
            RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(hue: 0.02, saturation: 0.61, brightness: 0.89, opacity: 1.00), location: 0),
                    .init(color: Color(hue: 0.87, saturation: 0.51, brightness: 0.89, opacity: 0.9), location: 0.5),
                    .init(color: Color(hue: 0.87, saturation: 0.51, brightness: 0.89, opacity: 0.3), location: 0.9),
                ], startPoint: .leading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.7), radius: size / 4, y: 2)
                .rotationEffect(.degrees(-45))
                .scaleEffect(y: 0.85)
            RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(hue: 0.59, saturation: 0.49, brightness: 0.48, opacity: 1.00), location: 0),
                    .init(color: Color(hue: 0.46, saturation: 0.46, brightness: 0.74, opacity: 0.9), location: 0.5),
                    .init(color: Color(hue: 0.61, saturation: 0.76, brightness: 0.94, opacity: 1.00), location: 0.9),
                ], startPoint: .top, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-45))
                .scaleEffect(y: 0.85)
                .zIndex(-1)
        }
    }
}

var shortcutCacheResetTask: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}

func startShortcutWatcher() {
    guard fm.fileExists(atPath: "\(HOME)/Library/Shortcuts") else {
        return
    }

    do {
        try LowtechFSEvents.startWatching(paths: ["\(HOME)/Library/Shortcuts"], for: ObjectIdentifier(AppDelegate.instance), latency: 0.9) { event in
            guard !SWIFTUI_PREVIEW else { return }

            shortcutCacheResetTask = mainAsyncAfter(ms: 100) {
                SHM.invalidateCache()
            }
        }
    } catch {
        log.error("Failed to start Shortcut watcher: \(error)")
    }
}

struct AutomationRowView: View {
    @Binding var shortcuts: [String: Shortcut]

    var icon: String
    var type: String
    var color: Color
    var sources: [OptimisationSource] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("On optimised")
                HStack {
                    SwiftUI.Image(systemName: icon).frame(width: 14)
                    Text(type)
                }.roundbg(radius: 6, color: color.opacity(0.1), noFG: true)

                Spacer()

                Menu(content: {
                    Button("From scratch") {
                        NSWorkspace.shared.open(
                            Bundle.main.url(forResource: "Clop - \(type)", withExtension: "shortcut")!
                        )
                    }
                    Section("Templates") {
                        ForEach(CLOP_SHORTCUTS, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                }, label: {
                    HStack {
                        ShortcutsIcon(size: 12)
                        Text("New Shortcut")
                    }
                })
                .buttonStyle(FlatButton(color: .mauve.opacity(0.8), textColor: .white))
                .font(.medium(12))
                .saturation(1.5)
            }
            ForEach(sources, id: \.self) { s in
                picker(source: s.string)
                    .padding(.leading)
            }
        }
    }

    @ViewBuilder
    func picker(source: String) -> some View {
        let binding = Binding<Shortcut?>(
            get: { shortcuts[source] },
            set: {
                if let shortcut = $0, let url = shortcut.identifier.url {
                    NSWorkspace.shared.open(url)
                    return
                }

                if let shortcut = $0 {
                    shortcuts = shortcuts.copyWith(key: source, value: shortcut)
                } else {
                    shortcuts = shortcuts.copyWithout(key: source)
                }
            }
        )

        HStack {
            Picker(
                selection: binding,
                content: {
                    Text("do nothing").tag(nil as Shortcut?)
                    Divider()
                    ShortcutChoiceMenu()
                    DefaultShortcutList()
                },
                label: {
                    HStack {
                        (Text("from  ").round(12, weight: .regular).foregroundColor(.secondary) + Text(source.replacingOccurrences(of: HOME.string, with: "~")).mono(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            )
            Button("\(SwiftUI.Image(systemName: binding.wrappedValue == nil ? "hammer" : "hammer.fill"))") {
                if let url = binding.wrappedValue?.url {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Opens the shortcut in the Shortcuts app for editing")
            .buttonStyle(FlatButton())
            .disabled(binding.wrappedValue == nil)
        }
    }

}

struct DefaultShortcutList: View {
    var body: some View {
        let shortcutNames = SHM.shortcutsMap?.values.joined().map(\.name) ?? []
        Section("Default Shortcuts") {
            let shorts = CLOP_SHORTCUTS.filter { sh in
                !shortcutNames.contains(sh.deletingPathExtension().lastPathComponent)
            }
            ForEach(shorts, id: \.self) { url in
                Text(url.deletingPathExtension().lastPathComponent)
                    .tag(Shortcut(name: url.deletingPathExtension().lastPathComponent, identifier: url.absoluteString))
            }
        }
    }
}

let CLOP_SHORTCUTS = Bundle.main
    .urls(forResourcesWithExtension: "shortcut", subdirectory: nil)!
    .filter { !$0.lastPathComponent.hasPrefix("Clop - ") }
    .sorted(by: \.lastPathComponent)

struct AutomationSettingsView: View {
    @Default(.shortcutToRunOnImage) var shortcutToRunOnImage
    @Default(.shortcutToRunOnVideo) var shortcutToRunOnVideo
    @Default(.shortcutToRunOnPdf) var shortcutToRunOnPdf

    @Default(.enableDragAndDrop) var enableDragAndDrop
    @Default(.optimiseVideoClipboard) var optimiseVideoClipboard
    @Default(.optimiseImagePathClipboard) var optimiseImagePathClipboard
    @Default(.enableClipboardOptimiser) var enableClipboardOptimiser

    @ObservedObject var shortcutsManager = SHM

    var body: some View {
        let imageSources = ((enableClipboardOptimiser || optimiseImagePathClipboard) ? [.clipboard] : []) + (enableDragAndDrop ? [.dropZone] : []) + Defaults[.imageDirs].compactMap(\.optSource).sorted(by: \.string)
        let videoSources = (optimiseVideoClipboard ? [.clipboard] : []) + (enableDragAndDrop ? [.dropZone] : []) + Defaults[.videoDirs].compactMap(\.optSource).sorted(by: \.string)
        let pdfSources = (enableDragAndDrop ? [.dropZone] : []) + Defaults[.pdfDirs].compactMap(\.optSource).sorted(by: \.string)

        Form {
            Section(header: SectionHeader(
                title: "Shortcuts",
                subtitle: "Run macOS Shortcuts on files for further processing after optimisation\nThe shortcuts need to receive files as input and may output a modified file that Clop will use for the result"
            )) {
                if imageSources.isNotEmpty {
                    AutomationRowView(
                        shortcuts: $shortcutToRunOnImage,
                        icon: "photo", type: "image",
                        color: .calmBlue,
                        sources: imageSources.compactMap { $0 }
                    )
                }
                if videoSources.isNotEmpty {
                    AutomationRowView(
                        shortcuts: $shortcutToRunOnVideo,
                        icon: "video", type: "video",
                        color: .red,
                        sources: videoSources.compactMap { $0 }
                    )
                }
                if pdfSources.isNotEmpty {
                    AutomationRowView(
                        shortcuts: $shortcutToRunOnPdf,
                        icon: "doc.text.magnifyingglass", type: "PDF",
                        color: .burntSienna,
                        sources: pdfSources.compactMap { $0 }
                    )
                }
            }
        }
        .padding(4)
        .onChange(of: shortcutsManager.cacheIsValid) { cacheIsValid in
            if !cacheIsValid {
                log.debug("Re-fetching Shortcuts from AutomationSettingsView.onChange")
                shortcutsManager.fetch()
            }
        }
        .onAppear {
            if !shortcutsManager.cacheIsValid {
                log.debug("Re-fetching Shortcuts from AutomationSettingsView.onAppear")
                shortcutsManager.fetch()
            }
        }

    }
}

struct AutomationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AutomationSettingsView()
            .frame(minWidth: 850, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .formStyle(.grouped)
    }
}

class ShortcutsManager: ObservableObject {
    init() {
        guard !SWIFTUI_PREVIEW else { return }
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
            }
        }
    }

    @Published var shortcutsMap: [String: [Shortcut]]? = !SWIFTUI_PREVIEW
        ? nil
        : [
            "Clop": [
                Shortcut(name: "Change video playback speed by 1.5x", identifier: "F2185611-9E75-4FC1-A4D1-67DB58B35992"),
                Shortcut(name: "Limit media size", identifier: "F1185611-9E75-4FC1-A4D1-67DB58B35992"),
                Shortcut(name: "Convert to WEBP", identifier: "FA6F8F4F-ACEB-4BCC-8F25-A6E5CC3BB46D"),
                Shortcut(name: "Blog images", identifier: "F28D4833-C074-48B2-BA85-A582F4940F5D"),
                Shortcut(name: "Menubar Icon", identifier: "666F6660-0B12-4628-A88B-A53899D6F39C"),
            ],
        ]
    @Published var cacheIsValid = true

    func invalidateCache() {
        guard !SWIFTUI_PREVIEW else { return }
        cacheIsValid = false
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil
    }

    func fetch() {
        guard !SWIFTUI_PREVIEW else { return }
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
                self.cacheIsValid = true
            }
        }
    }

    func refetch() {
        guard !SWIFTUI_PREVIEW else { return }
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil

        fetch()
    }
}

let SHM = ShortcutsManager()
