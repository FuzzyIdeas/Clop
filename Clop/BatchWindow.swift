//
//  BatchWindow.swift
//  Clop
//
//  Window controller for batch mode. The whole UI is SwiftUI (see BatchPrepView.swift); this just
//  owns the NSWindow, hosts the SwiftUI root, and handles multi-item QuickLook for the "Open" action.
//

import Cocoa
import Foundation
import Lowtech
import Quartz
import SwiftUI
import System

/// Stable identifier used by the app delegate's window notifications to toggle the activation policy.
let BATCH_WINDOW_IDENTIFIER = NSUserInterfaceItemIdentifier("clop.batch.window")

// MARK: - Multi-item QuickLook

/// QuickLooks several files in a single QuickLook window (so "Open" on a selection doesn't spawn a
/// dozen app windows).
final class BatchQuickLooker: NSObject, QLPreviewPanelDataSource {
    init(urls: [URL]) { self.urls = urls }

    static var shared: BatchQuickLooker?

    let urls: [URL]

    static func quicklook(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        shared = BatchQuickLooker(urls: urls)
        focus()
        panel.makeKeyAndOrderFront(nil)
        panel.dataSource = shared
        panel.reloadData()
    }

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

// MARK: - Window controller

final class BatchWindowController: NSWindowController {
    convenience init(manager: BatchManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Batch optimisation"
        window.identifier = BATCH_WINDOW_IDENTIFIER
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 1100, height: 500)
        window.setFrameAutosaveName("Batch Window")

        let host = NSHostingController(rootView: BatchRootView(manager: manager))
        window.contentViewController = host

        self.init(window: window)
        if !window.setFrameUsingName("Batch Window") {
            window.center()
        }
    }

    func present() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        // Opened from the MenuBarExtra (a tracking run-loop): switching .accessory→.regular there often
        // doesn't register the app in the Cmd-Tab switcher / Dock until the next run-loop cycle. Re-assert
        // on the next tick (after menu tracking ends) so the batch window is reliably Cmd-Tab-able.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension BatchManager {
    /// Open (or focus) the batch window.
    func showWindow() {
        if let wc = windowController {
            (wc as? BatchWindowController)?.present()
            return
        }
        let wc = BatchWindowController(manager: self)
        windowController = wc
        wc.present()
    }
}
