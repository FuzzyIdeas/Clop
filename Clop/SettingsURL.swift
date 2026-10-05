import Foundation

/// `clop://settings/<tab>[/<row>]` (or `?highlight=<row>`) opens Settings on a tab and flashes one
/// row. The row id is the row's search anchor, which is also its accessibility identifier, so an
/// agent that read one off the window can come straight back to it.
///
/// A row the search index knows opens on the tab the index puts it in, whatever tab the URL names,
/// so a copied link survives the row moving to another pane. `clop://settings/<row>` works too.
enum SettingsURL {
    /// True when the URL was ours, resolved or not: a claimed URL must never reach the file
    /// optimiser, which would try to fetch it.
    @MainActor static func handle(url: URL) -> Bool {
        guard url.scheme == "clop", url.host == "settings" else { return false }

        let parts = url.pathComponents.filter { $0 != "/" }
        let namedTab = parts.first.flatMap { tab(named: $0) }
        let pathRow: String? = parts.count > 1 ? parts[1] : (namedTab == nil ? parts.first : nil)
        let row = pathRow ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "highlight" }?.value
        let indexedTab: SettingsView.Tabs? = row.flatMap { id in SettingsSearchIndex.all.first { $0.id == id }?.tab }
        if let tab = indexedTab ?? namedTab {
            settingsViewManager.tab = tab
        }
        if let row, !row.isEmpty {
            settingsViewManager.highlightedEntry = row
        }
        WM.windowToOpen = "settings"
        return true
    }

    /// The link a search result copies from its context menu. The tab is spelled out even though
    /// `handle` finds it from the row, so the link reads as where it goes and still opens the right
    /// pane on a Clop from before rows were looked up.
    static func link(to entry: SettingEntry) -> String {
        var components = URLComponents()
        components.scheme = "clop"
        components.host = "settings"
        components.path = "/\(entry.tab)/\(entry.id)"
        return components.string ?? "clop://settings/\(entry.tab)/\(entry.id)"
    }

    /// A tab by its case name ("presetZones") or its title ("Preset zones"), in any case, spaces and
    /// dashes ignored.
    @MainActor private static func tab(named raw: String) -> SettingsView.Tabs? {
        let wanted = normalized(raw)
        return SettingsView.Tabs.allCases.first { normalized("\($0)") == wanted || normalized($0.title) == wanted }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
