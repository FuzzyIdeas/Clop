//
//  ClopApp.swift
//  Clop
//
//  Created by Alin Panaitiu on 16.07.2022.
//

import SwiftUI

import Cocoa
import Combine
import Defaults
import EonilFSEvents
import Foundation
import Lowtech
import LowtechIndie
import LowtechPro
import Sentry
import ServiceManagement
import System
import UniformTypeIdentifiers

var pauseForNextClipboardEvent = false

class AppDelegate: LowtechProAppDelegate {
    var didBecomeActiveAtLeastOnce = false
    var openWindow: OpenWindowAction?

    var videoWatcher: FileOptimizationWatcher?
    var imageWatcher: FileOptimizationWatcher?

    @MainActor var swipeEnded = true

    @Setting(.floatingResultsCorner) var floatingResultsCorner

    override func applicationDidFinishLaunching(_ notification: Notification) {
        if !SWIFTUI_PREVIEW {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .forEach {
                    $0.forceTerminate()
                }
        }

        paddleVendorID = "122873"
        paddleAPIKey = "e1e517a68c1ed1bea2ac968a593ac147"
        paddleProductID = "841006"
        trialDays = 14
        trialText = "This is a trial for the Pro features. After the trial, the app will automatically revert to the free version."
        price = 8
        productName = "Clop Pro"
        vendorName = "Panaitiu Alin Valentin PFA"
        hasFreeFeatures = true

        if !SWIFTUI_PREVIEW {
            sentryDSN = "https://7dad9331a2e1753c3c0c6bc93fb0d523@o84592.ingest.sentry.io/4505673793077248"
            configureSentry()

            KM.primaryKeyModifiers = Defaults[.keyComboModifiers]
            KM.primaryKeys = Defaults[.enabledKeys] + Defaults[.quickResizeKeys]
            KM.onPrimaryHotkey = { key in
                switch key {
                case .minus:
                    if let opt = OM.current {
                        guard opt.downscaleFactor > 0.1 else { return }
                        opt.downscale()
                    } else {
                        guard scalingFactor > 0.1 else { return }
                        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
                        Task.init { try? await optimizeLastClipboardItem(downscaleTo: scalingFactor) }
                    }
                case .delete:
                    if let opt = OM.optimizers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                        hoveredOptimizerID = nil
                        opt.stop(animateRemoval: true)
                    }
                case .equal:
                    if let opt = OM.removedOptimizers.popLast() {
                        opt.bringBack()
                    }
                case .space:
                    if let opt = OM.optimizers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                        opt.quicklook()
                    } else {
                        Task.init { try? await quickLookLastClipboardItem() }
                    }
                case .z:
                    if let opt = OM.optimizers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt), !opt.isOriginal {
                        opt.restoreOriginal()
                    }
                case .p:
                    pauseForNextClipboardEvent = true
                    showNotice("**Paused**\nNext clipboard event will be ignored")
                case .c:
                    Task.init { try? await optimizeLastClipboardItem() }
                case .a:
                    if let opt = OM.optimizers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt), !opt.aggresive {
                        if opt.downscaleFactor < 1 {
                            opt.downscale(toFactor: opt.downscaleFactor, aggressiveOptimization: true)
                        } else {
                            opt.optimize(allowLarger: true, aggressiveOptimization: true, fromOriginal: true)
                        }
                    } else {
                        Task.init { try? await optimizeLastClipboardItem(aggressiveOptimization: true) }
                    }
                case SauceKey.NUMBER_KEYS.suffix(from: 1).arr:
                    guard let number = key.QWERTYCharacter.d else { break }

                    if let opt = OM.optimizers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                        opt.downscale(toFactor: number / 10.0)
                    } else {
                        Task.init { try? await optimizeLastClipboardItem(downscaleTo: number / 10.0) }
                    }
                default:
                    break
                }
            }
        }
        super.applicationDidFinishLaunching(_: notification)
        UM.updater = updateController.updater
        PM.pro = pro

        if let window = NSApplication.shared.windows.first {
            window.close()
        }
        Defaults[.videoDirs] = Defaults[.videoDirs].filter { fm.fileExists(atPath: $0) }

        guard !SWIFTUI_PREVIEW else { return }
        pub(.floatingResultsCorner)
            .sink {
                sizeNotificationWindow.moveToScreen(.withMouse, corner: $0.newValue)
            }
            .store(in: &observers)
        pub(.keyComboModifiers)
            .sink {
                KM.primaryKeyModifiers = $0.newValue
                KM.reinitHotkeys()
            }
            .store(in: &observers)
        pub(.quickResizeKeys)
            .sink {
                KM.primaryKeys = Defaults[.enabledKeys] + $0.newValue
                KM.reinitHotkeys()
            }
            .store(in: &observers)
        pub(.enabledKeys)
            .sink {
                KM.primaryKeys = $0.newValue + Defaults[.quickResizeKeys]
                KM.reinitHotkeys()
            }
            .store(in: &observers)

        initOptimizers()
        trackScrollWheel()

    }

    func trackScrollWheel() {
        NSApp.publisher(for: \.currentEvent)
            .filter { event in event?.type == .scrollWheel }
            .throttle(
                for: .milliseconds(20),
                scheduler: DispatchQueue.main,
                latest: true
            )
            .sink { event in
                guard let event else { return }

                mainActor {
                    if self.swipeEnded, self.floatingResultsCorner.isTrailing ? event.scrollingDeltaX > 3 : event.scrollingDeltaX < -3,
                       let hov = hoveredOptimizerID, let optimizer = OM.optimizers.first(where: { $0.id == hov })
                    {
                        hoveredOptimizerID = nil
                        optimizer.stop(remove: true, animateRemoval: true)
                        self.swipeEnded = false
                    }
                    if event.scrollingDeltaX == 0 {
                        self.swipeEnded = true
                    }
                }
            }.store(in: &observers)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if !Defaults[.showMenubarIcon] {
            openWindow?(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        return true
    }

    override func applicationDidBecomeActive(_: Notification) {
        if didBecomeActiveAtLeastOnce, !Defaults[.showMenubarIcon] {
            openWindow?(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        didBecomeActiveAtLeastOnce = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor func initOptimizers() {
        videoWatcher = FileOptimizationWatcher(paths: Defaults[.videoDirs], key: .videoDirs, shouldHandle: shouldHandleVideo(event:)) { event in
            let video = Video(path: FilePath(event.path))
            Task.init {
                try? await optimizeVideo(video, debounceMS: 200)
            }
        }
        imageWatcher = FileOptimizationWatcher(paths: Defaults[.imageDirs], key: .imageDirs, shouldHandle: shouldHandleImage(event:)) { event in
            guard let img = Image(path: FilePath(event.path), retinaDownscaled: false) else { return }
            Task.init {
                try? await optimizeImage(img, debounceMS: 200)
            }
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let newChangeCount = NSPasteboard.general.changeCount
            guard newChangeCount != pbChangeCount else {
                return
            }
            pbChangeCount = newChangeCount
            mainActor { optimizeClipboardImage() }
        }

        timer?.tolerance = 100
    }

    @objc func statusBarButtonClicked(_ sender: NSClickGestureRecognizer) {
        mainActor {
            if OM.skippedBecauseNotPro.isNotEmpty {
                OM.ignoreProErrorBadge = true
                sender.isEnabled = false

                guard let button = sender.view as? NSStatusBarButton else { return }
                button.performClick(self)
            }
        }
    }
}

var statusItem: NSStatusItem? {
    NSApp.windows.lazy.compactMap { window in
        window.perform(Selector(("statusItem")))?.takeUnretainedValue() as? NSStatusItem
    }.first
}

@MainActor
class FileOptimizationWatcher {
    init(paths: [String], key: Defaults.Key<[String]>? = nil, shouldHandle: @escaping (EonilFSEventsEvent) -> Bool, handler: @escaping (EonilFSEventsEvent) -> Void) {
        self.paths = paths
        self.key = key
        self.shouldHandle = shouldHandle
        self.handler = handler

        guard let key else { return }
        pub(key).sink { change in
            self.paths = change.newValue
            self.startWatching()
        }.store(in: &observers)

        startWatching()
    }

    var watching = false
    var paths: [String] = []
    var key: Defaults.Key<[String]>?
    var handler: (EonilFSEventsEvent) -> Void = { _ in }
    var shouldHandle: (EonilFSEventsEvent) -> Bool = { _ in false }

    var observers = Set<AnyCancellable>()

    func startWatching() {
        if watching {
            EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
            watching = false
        }

        guard !paths.isEmpty else { return }

        try! EonilFSEvents.startWatching(paths: paths, for: ObjectIdentifier(self)) { event in
            guard !SWIFTUI_PREVIEW else { return }

            mainActor {
                guard self.shouldHandle(event) else { return }
                Task.init {
                    var count = self.optimizedCount
                    try? await proGuard(count: &count, limit: 2, url: event.path.fileURL) {
                        self.handler(event)
                    }
                    self.optimizedCount = count
                }
            }
        }
        watching = true
    }

    private var optimizedCount = 0
}

@MainActor func proLimitsReached(url: URL? = nil) {
    guard !Defaults[.neverShowProError] else {
        if let url, !OM.skippedBecauseNotPro.contains(url) {
            OM.skippedBecauseNotPro = OM.skippedBecauseNotPro.suffix(4).with(url)
        }
        if OM.skippedBecauseNotPro.isNotEmpty {
            let onclick = NSClickGestureRecognizer(target: AppDelegate.instance, action: #selector(AppDelegate.statusBarButtonClicked(_:)))
            statusItem?.button?.addGestureRecognizer(onclick)
        }

        return
    }

    let optimizer = OM.optimizer(id: Optimizer.IDs.pro, type: .unknown, operation: "")
    optimizer.finish(error: "Free version limits reached", notice: "Only 2 file optimizations per session\nare included in the free version", keepFor: 5000)
}

#if DEBUG
    let sizeNotificationWindow = OSDWindow(swiftuiView: SizeNotificationContainer().any, level: .floating, canScreenshot: true, allowsMouse: true)
#else
    let sizeNotificationWindow = OSDWindow(swiftuiView: SizeNotificationContainer().any, level: .floating, canScreenshot: false, allowsMouse: true)
#endif
var timer: Timer?
var pbChangeCount = NSPasteboard.general.changeCount
let THUMB_SIZE = CGSize(width: 300, height: 220)

// MARK: - ClopApp

@main
struct ClopApp: App {
    init() {
        appDelegate.openWindow = openWindow
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.openWindow) var openWindow
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase

    @AppStorage("showMenubarIcon") var showMenubarIcon = Defaults[.showMenubarIcon]

    @ObservedObject var om = OM

    var body: some Scene {
        Window("Settings", id: "settings") {
            SettingsView()
                .windowModifier { window in
                    window.isMovableByWindowBackground = true
                }
                .frame(minWidth: 850, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: $showMenubarIcon, content: {
            MenuView()
        }, label: { SwiftUI.Image(nsImage: NSImage(named: !om.ignoreProErrorBadge && om.skippedBecauseNotPro.isNotEmpty ? "MenubarIconBadge" : "MenubarIcon")!) })
            .menuBarExtraStyle(.menu)
            .onChange(of: showMenubarIcon) { show in
                if !show {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    NSApplication.shared.keyWindow?.close()
                }
            }

    }
}
