import Foundation

/// `clop://settings/<tab>[/<row>]` (or `?highlight=<row>`) opens Settings on a tab and flashes one
/// row. The row id is the row's search anchor, which is also its accessibility identifier, so an
/// agent that read one off the window can come straight back to it.
enum SettingsURL {
    /// True when the URL was ours, resolved or not: a claimed URL must never reach the file
    /// optimiser, which would try to fetch it.
    @MainActor static func handle(url: URL) -> Bool {
        guard url.scheme == "clop", url.host == "settings" else { return false }

        let parts = url.pathComponents.filter { $0 != "/" }
        if let tab = parts.first.flatMap(tab(named:)) {
            settingsViewManager.tab = tab
        }
        let row = parts.dropFirst().first
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "highlight" }?.value
        if let row, !row.isEmpty {
            settingsViewManager.highlightedEntry = row
        }
        WM.windowToOpen = "settings"
        return true
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
