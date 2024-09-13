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
        guard let proc = Clop.runShortcut(shortcut, url.path, outFile: outFile.string) else {
            return nil
        }

        mainActor { [weak self] in
            self?.running = true
            self?.progress = Progress()
            self?.operation = "Running \"\(shortcut.name)\""
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
    log.debug("Getting shortcuts for folder \(folder ?? "nil")")

    let additionalArgs = folder.map { ["--folder-name", $0] } ?? []
    guard let output = shell("/usr/bin/shortcuts", args: ["list", "--show-identifiers"] + additionalArgs, timeout: 2).o else {
        return nil
    }

    let lines = output.split(separator: "\n")
    var shortcuts: [Shortcut] = []
    for line in lines {
        let parts = line.split(separator: " ")
        guard let identifier = parts.last?.trimmingCharacters(in: ["(", ")"]) else {
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

func runShortcut(_ shortcut: Shortcut, _ file: String, outFile: String) -> Process? {
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
                if let shortcut = binding.wrappedValue?.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = "shortcuts://open-shortcut?id=\(shortcut)".url {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Opens the shortcut in the Shortcuts app for editing")
            .buttonStyle(FlatButton())
            .disabled(binding.wrappedValue == nil)
        }
    }
}

let CLOP_SHORTCUTS = Bundle.main
    .urls(forResourcesWithExtension: "shortcut", subdirectory: nil)!
    .filter { !$0.lastPathComponent.hasPrefix("Clop - ") }

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
        let imageSources = ((enableClipboardOptimiser || optimiseImagePathClipboard) ? [.clipboard] : []) + (enableDragAndDrop ? [.dropZone] : []) + Defaults[.imageDirs].map(\.optSource)
        let videoSources = (optimiseVideoClipboard ? [.clipboard] : []) + (enableDragAndDrop ? [.dropZone] : []) + Defaults[.videoDirs].map(\.optSource)
        let pdfSources = (enableDragAndDrop ? [.dropZone] : []) + Defaults[.pdfDirs].map(\.optSource)

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
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
            }
        }
    }

    @Published var shortcutsMap: [String: [Shortcut]]? = nil
    @Published var cacheIsValid = true

    func invalidateCache() {
        cacheIsValid = false
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil
    }

    func fetch() {
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
                self.cacheIsValid = true
            }
        }
    }

    func refetch() {
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil

        fetch()
    }
}

let SHM = ShortcutsManager()
