import Combine
import Lowtech
import SwiftUI

// MARK: - SettingsSearchAnchor

/// Marks the control a `SettingsSearchIndex` entry describes, so picking a search result can scroll to
/// that exact row and flash it.
///
/// Jumping to the pane alone is not much help in a settings window this size: the video pane is a
/// couple of screens tall and "the setting you asked for is somewhere below" is barely better than
/// nothing. rcmd solves it the same way, with an anchor per row.
///
/// The id is the entry id, so the index and the anchors cannot drift apart without
/// `Scripts/settings-anchor-audit.py` noticing.
struct SettingsSearchAnchor: ViewModifier {
    let id: String

    @ObservedObject var svm = settingsViewManager

    var isHighlighted: Bool {
        svm.highlightedEntry == id
    }

    func body(content: Content) -> some View {
        content
            .id(id)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.peach.opacity(isHighlighted ? 0.28 : 0))
            )
            .animation(.easeOut(duration: 0.25), value: isHighlighted)
    }
}

extension View {
    /// See `SettingsSearchAnchor`. Put this on the control itself, not on the Section.
    func searchAnchor(_ id: String) -> some View {
        modifier(SettingsSearchAnchor(id: id))
    }
}

// MARK: - Jumping to a row

extension SettingsViewManager {
    /// Open the pane a search result lives in and flash its row.
    ///
    /// The scroll cannot happen here: the destination pane may not exist yet when the tab changes, and
    /// `ScrollViewReader.scrollTo` on an id that is not on screen does nothing. `SettingsPaneScroller`
    /// below waits for the pane to appear and then scrolls, which is why the highlight is stored
    /// rather than passed.
    @MainActor func jump(to entry: SettingEntry) {
        tab = entry.tab
        searchQuery = ""
        highlightedEntry = entry.id
    }
}

// MARK: - SettingsPaneScroller

/// Scrolls a pane to `highlightedEntry` once it is on screen, then fades the highlight.
///
/// Wrapped around the detail view rather than baked into each pane, so a pane needs nothing but its
/// anchors to take part.
struct SettingsPaneScroller<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @ObservedObject var svm = settingsViewManager

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .onChange(of: svm.highlightedEntry) { id in
                    guard let id else { return }
                    scroll(proxy, to: id)
                }
                .onAppear {
                    guard let id = svm.highlightedEntry else { return }
                    scroll(proxy, to: id)
                }
        }
    }

    /// One frame's grace for the pane to lay out, then scroll, then clear the highlight after it has
    /// been seen. Clearing matters: without it the row stays lit the next time the pane is opened for
    /// an unrelated reason.
    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        mainAsyncAfter(ms: 120) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        mainAsyncAfter(ms: 2600) {
            guard settingsViewManager.highlightedEntry == id else { return }
            settingsViewManager.highlightedEntry = nil
        }
    }
}
