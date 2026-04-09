import Cocoa
import Combine
import Defaults
import Foundation
import Lowtech
import SwiftUI

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
    let cmd =
        "/usr/bin/shortcuts run $'\(shortcut.identifier.replacingOccurrences(of: "'", with: "\\'"))' --input-path '\(file.replacingOccurrences(of: "'", with: "\\'"))' --output-path '\(outFile.replacingOccurrences(of: "'", with: "\\'"))'"
    log.debug("Running: \(cmd)")
    let ps = shell(command: cmd)
    return ps.process
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
        guard hasShortcutsDB() else { return }
        return
    }

    let shortcutsDB = "\(HOME)/Library/Shortcuts/Shortcuts.sqlite"
    let shortcutsWAL = "\(HOME)/Library/Shortcuts/Shortcuts.sqlite-wal"
    do {
        try LowtechFSEvents.startWatching(paths: [shortcutsDB, shortcutsWAL], for: ObjectIdentifier(AppDelegate.instance), latency: 2) { event in
            guard !SWIFTUI_PREVIEW else { return }
            log.debug("Shortcuts DB changed: \(event.path) [\(event.flag ?? .init())]")

            shortcutCacheResetTask = mainAsyncAfter(ms: 500) {
                SHM.invalidateCache()
            }
        }
    } catch {
        log.error("Failed to start Shortcut watcher: \(error)")
    }
}

class ShortcutsManager: ObservableObject {
    init() {
        guard !SWIFTUI_PREVIEW else { return }
        fetch()
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
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil
        refetch()
    }

    func fetch() {
        guard !SWIFTUI_PREVIEW, !isFetching else { return }
        isFetching = true
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
                self.cacheIsValid = true
                self.isFetching = false
            }
        }
    }

    func refetch() {
        guard !SWIFTUI_PREVIEW else { return }
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil
        cacheIsValid = false
        fetch()
    }

    private var isFetching = false
}

let SHM = ShortcutsManager()
