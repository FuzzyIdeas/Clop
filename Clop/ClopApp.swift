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

class WindowManager: ObservableObject {
    @Published var windowToOpen: String? = nil

    func open(_ window: String) {
        windowToOpen = window
    }
}
let WM = WindowManager()

extension NSPasteboard {
    func debug() {
        #if DEBUG
            print(name.rawValue)
            guard let pasteboardItems else {
                print("No items")
                return
            }
            pasteboardItems.forEach { item in
                item.types.filter { ![NSPasteboard.PasteboardType.rtf, NSPasteboard.PasteboardType(rawValue: "public.utf16-external-plain-text")].contains($0) }.forEach { type in
                    print(type.rawValue + " " + (item.string(forType: type) ?! String(describing: item.propertyList(forType: type) ?? item.data(forType: type) ?? "<EMPTY DATA>")))
                }
            }
        #endif
    }
}

class AppDelegate: LowtechProAppDelegate {
    var didBecomeActiveAtLeastOnce = false

    var videoWatcher: FileOptimisationWatcher?
    var imageWatcher: FileOptimisationWatcher?
    var pdfWatcher: FileOptimisationWatcher?

    @MainActor var swipeEnded = true

    @Setting(.floatingResultsCorner) var floatingResultsCorner

    lazy var draggingSet: PassthroughSubject<Bool, Never> = debouncer(in: &observers, every: .milliseconds(200)) { dragging in
        mainActor {
            DM.dragging = dragging
            if !dragging {
                DM.dropped = true
            } else {
                showFloatingThumbnails(force: true)
            }
        }
    }

    var lastDragChangeCount = NSPasteboard(name: .drag).changeCount

    @MainActor lazy var dragMonitor = GlobalEventMonitor(mask: [.leftMouseDragged]) { event in
        guard NSEvent.pressedMouseButtons > 0, self.pro.active || DM.optimisationCount <= 5 else {
            return
        }

        let drag = NSPasteboard(name: .drag)
        drag.debug()
        guard self.lastDragChangeCount != drag.changeCount else {
            return
        }
        DM.dropped = false
        self.lastDragChangeCount = drag.changeCount

        guard let items = drag.pasteboardItems, !items.contains(where: { $0.types.set.hasElements(from: [.promise, .promisedFileName, .promisedFileURL, .promisedSuggestedFileName, .promisedMetadata]) }) else {
            DM.itemsToOptimise = []
            self.draggingSet.send(true)
            return
        }

        let toOptimise: [ClipboardType] = items.compactMap { item -> ClipboardType? in
            let types = item.types
            if types.contains(.fileURL), let url = item.string(forType: .fileURL)?.url,
               let path = url.existingFilePath, path.isImage || path.isVideo || path.isPDF
            {
                return .file(path)
            }

            if let str = item.string(forType: .string), let path = str.existingFilePath, path.isImage || path.isVideo || path.isPDF {
                return .file(path)
            }

            if types.contains(.URL), let url = item.string(forType: .URL)?.url ?? item.string(forType: .string)?.url, url.isImage || url.isVideo || url.isPDF {
                return .url(url)
            }

            if types.set.hasElements(from: IMAGE_VIDEO_PASTEBOARD_TYPES) || types.contains(.pdf) {
                return .file(FilePath.tmp)
            }

            if let str = item.string(forType: .string), let url = str.url, url.isImage || url.isVideo || url.isPDF {
                return .url(url)
            }

            return nil
        }

        guard toOptimise.isNotEmpty else {
            DM.itemsToOptimise = []
            return
        }

        DM.itemsToOptimise = toOptimise
        self.draggingSet.send(true)
    }
    @MainActor lazy var mouseUpMonitor = GlobalEventMonitor(mask: [.leftMouseUp]) { event in
        self.draggingSet.send(false)
        if !DM.dragHovering, DM.itemsToOptimise.isNotEmpty {
            DM.dragging = false
            DM.itemsToOptimise = []
        }
    }
//    @MainActor lazy var stopDragMonitor = GlobalEventMonitor(mask: [.flagsChanged]) { event in
//        guard !Defaults[.onlyShowDropZoneOnOption], event.modifierFlags.contains(.option), !DM.dragHovering else { return }
//
//        DM.dragging = false
//    }

    @Setting(.optimiseVideoClipboard) var optimiseVideoClipboard

    var machPortThread: Thread?
    var machPortStopThread: Thread?

    @MainActor
    static func handleStopOptimisationRequest(_ req: StopOptimisationRequest) {
        log.debug("Stopping optimisation request: \(req.jsonString)")

        for id in req.ids {
            guard let opt = opt(id) else {
                continue
            }

            opt.stop(remove: req.remove)
            opt.uiStop()
        }
    }

    static func handleOptimisationRequest(_ req: OptimisationRequest) -> Data? {
        log.debug("Handling optimisation request: \(req.jsonString)")

        let sem = DispatchSemaphore(value: 0)
        var resp: [OptimisationResponse] = []
        tryAsync {
            resp = try await processOptimisationRequest(req)
            sem.signal()
        }
        sem.wait()

        return resp.jsonData
    }

    func setupServiceProvider() {
        NSApp.registerServicesMenuSendTypes([.png, .pdf, .fileURL, .fileContents], returnTypes: [.png, .pdf, .fileURL, .fileContents])
        NSApplication.shared.servicesProvider = ContextualMenuServiceProvider()
        NSUpdateDynamicServices()
    }

    @MainActor
    func handleCommandHotkey(_ key: SauceKey) {
        guard let opt = OM.hovered else {
            return
        }

        switch key {
        case .comma:
            WM.open("settings")
            focus()
        case .minus where opt.downscaleFactor > 0.1:
            opt.downscale()
        case .x where opt.changePlaybackSpeedFactor < 10 && opt.canChangePlaybackSpeed():
            opt.changePlaybackSpeed()
        case .delete:
            hoveredOptimiserID = nil
            opt.stop(animateRemoval: true)
        case .space:
            opt.quicklook()
        case .z where !opt.isOriginal:
            opt.restoreOriginal()
        case .r where !opt.running:
            opt.editingFilename = true
        case .c:
            opt.copyToClipboard()
            opt.overlayMessage = "Copied"
        case .s:
            opt.save()
        case .f:
            opt.showInFinder()
        case .u:
            opt.uploadWithDropshare()
        case .o:
            guard let url = opt.url ?? opt.originalURL else { return }
            NSWorkspace.shared.open(url)
        case .a where !opt.aggresive:
            if opt.downscaleFactor < 1 {
                opt.downscale(toFactor: opt.downscaleFactor, aggressiveOptimisation: true)
            } else {
                opt.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
            }
        default:
            break
        }
    }

    @MainActor
    func handleHotkey(_ key: SauceKey) {
        switch key {
        case .escape:
            OM.clearVisibleOptimisers(stop: true)
        case .minus:
            if let opt = OM.current {
                guard opt.downscaleFactor > 0.1 else { return }
                opt.downscale()
            } else {
                guard scalingFactor > 0.1 else { return }
                scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
                Task.init { try? await optimiseLastClipboardItem(downscaleTo: scalingFactor) }
            }
        case .x:
            if let opt = OM.current, opt.canChangePlaybackSpeed() {
                guard opt.changePlaybackSpeedFactor < 10 else { return }
                opt.changePlaybackSpeed()
            } else {
                Task.init { try? await optimiseLastClipboardItem(changePlaybackSpeedBy: 1.25) }
            }
        case .r:
            if let opt = OM.current, !opt.running {
                opt.editingFilename = true
            }
        case .delete:
            if let opt = OM.optimisers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                hoveredOptimiserID = nil
                opt.stop(animateRemoval: true)
            }
        case .equal:
            if let opt = OM.removedOptimisers.popLast() {
                opt.bringBack()
            }
        case .space:
            if let opt = OM.optimisers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                opt.quicklook()
            } else {
                Task.init { try? await quickLookLastClipboardItem() }
            }
        case .z:
            if let opt = OM.optimisers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt), !opt.isOriginal {
                opt.restoreOriginal()
            }
        case .p:
            pauseForNextClipboardEvent = true
            showNotice("**Paused**\nNext clipboard event will be ignored")
        case .c:
            Task.init { try? await optimiseLastClipboardItem() }
        case .a:
            if let opt = OM.optimisers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt), !opt.aggresive {
                if opt.downscaleFactor < 1 {
                    opt.downscale(toFactor: opt.downscaleFactor, aggressiveOptimisation: true)
                } else {
                    opt.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
                }
            } else {
                Task.init { try? await optimiseLastClipboardItem(aggressiveOptimisation: true) }
            }
        case SauceKey.NUMBER_KEYS.suffix(from: 1).arr:
            guard let number = key.QWERTYCharacter.d else { break }

            if let opt = OM.optimisers.filter({ !$0.inRemoval && !$0.hidden }).max(by: \.startedAt) {
                opt.downscale(toFactor: number / 10.0)
            } else {
                Task.init { try? await optimiseLastClipboardItem(downscaleTo: number / 10.0) }
            }
        default:
            break
        }
    }

    func syncSettings() {
        UserDefaults.standard.register(defaults: UserDefaults.standard.dictionaryRepresentation())
        if Defaults[.syncSettingsCloud] {
            Zephyr.observe(keys: SETTINGS_TO_SYNC)
        }
        pub(.syncSettingsCloud)
            .sink { change in
                if change.newValue {
                    Zephyr.observe(keys: SETTINGS_TO_SYNC)
                } else {
                    Zephyr.stopObserving(keys: SETTINGS_TO_SYNC)
                }
            }.store(in: &observers)
    }
    func initMachPortListener() {
        machPortThread = Thread {
            OPTIMISATION_PORT.listen { data in
                guard let data else {
                    return nil
                }

                var result: Data? = nil
                if let req = OptimisationRequest.from(data) {
                    result = Self.handleOptimisationRequest(req)
                }

                guard let result else {
                    return nil
                }
                return Unmanaged.passRetained(result as CFData)
            }
            RunLoop.current.run()
        }
        machPortStopThread = Thread {
            OPTIMISATION_STOP_PORT.listen { data in
                guard let data, let req = StopOptimisationRequest.from(data) else {
                    return nil
                }

                mainActor { Self.handleStopOptimisationRequest(req) }
                return nil
            }
            RunLoop.current.run()
        }

        machPortThread?.start()
        machPortStopThread?.start()
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        if !SWIFTUI_PREVIEW {
            handleCLIInstall()

            NSApplication.shared.windows.first?.close()
            unarchiveBinaries()
            print(NSFilePromiseReceiver.swizzleReceivePromisedFiles)
            shouldRestartOnCrash = true

            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .forEach {
                    $0.forceTerminate()
                }
            let _ = shell("/usr/bin/pkill", args: ["-fl", "Clop/bin/(arm64|x86)/.+"], wait: false)
            signal(SIGTERM) { _ in
                (OM.optimisers + OM.removedOptimisers).forEach { opt in
                    opt.stop(animateRemoval: false)
                }
                exit(0)
            }
            signal(SIGKILL) { _ in
                (OM.optimisers + OM.removedOptimisers).forEach { opt in
                    opt.stop(animateRemoval: false)
                }
                exit(0)
            }
            syncSettings()
            Defaults[.cliInstalled] = fm.fileExists(atPath: CLOP_CLI_BIN_LINK)
        }

        paddleVendorID = "122873"
        paddleAPIKey = "e1e517a68c1ed1bea2ac968a593ac147"
        paddleProductID = "841006"
        trialDays = 14
        trialText = "This is a trial for the Pro features. After the trial, the app will automatically revert to the free version."
        price = 15
        productName = "Clop Pro"
        vendorName = "Panaitiu Alin Valentin PFA"
        hasFreeFeatures = true

        if !SWIFTUI_PREVIEW {
            sentryDSN = "https://7dad9331a2e1753c3c0c6bc93fb0d523@o84592.ingest.sentry.io/4505673793077248"
            configureSentry(restartOnHang: true)

            KM.primaryKeyModifiers = Defaults[.keyComboModifiers]
            KM.primaryKeys = Defaults[.enabledKeys] + Defaults[.quickResizeKeys]
            KM.onPrimaryHotkey = { key in
                self.handleHotkey(key)
                #if !DEBUG
                    if let product {
                        _ = checkInternalRequirements([product], nil)
                    }
                #endif
            }

            KM.secondaryKeyModifiers = [.lcmd]
            KM.onSecondaryHotkey = { key in
                self.handleCommandHotkey(key)
                #if !DEBUG
                    if let product {
                        _ = checkInternalRequirements([product], nil)
                    }
                #endif
            }
        }
        super.applicationDidFinishLaunching(_: notification)
        UM.updater = updateController.updater
        PM.pro = pro

        NSApplication.shared.windows.first?.close()
        Defaults[.videoDirs] = Defaults[.videoDirs].filter { fm.fileExists(atPath: $0) }

        guard !SWIFTUI_PREVIEW else { return }
        sizeNotificationWindow.animateOnResize = true
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

        initOptimisers()
        trackScrollWheel()

        if Defaults[.enableDragAndDrop] {
            dragMonitor.start()
            mouseUpMonitor.start()
        }
        pub(.enableDragAndDrop)
            .sink { enabled in
                if enabled.newValue {
                    self.dragMonitor.start()
                    self.mouseUpMonitor.start()
                } else {
                    self.dragMonitor.stop()
                    self.mouseUpMonitor.stop()
                }
            }
            .store(in: &observers)
        pub(.enableClipboardOptimiser)
            .sink { enabled in
                if enabled.newValue {
                    self.initClipboardOptimiser()
                } else {
                    clipboardWatcher?.invalidate()
                }
            }
            .store(in: &observers)
        pub(.pauseAutomaticOptimisations)
            .sink { paused in
                if paused.newValue {
                    clipboardWatcher?.invalidate()
                } else {
                    self.initClipboardOptimiser()
                }
            }
            .store(in: &observers)
        initMachPortListener()

        #if !DEBUG
            if let product {
                _ = checkInternalRequirements([product], nil)
            }
        #endif
        setupServiceProvider()
        startShortcutWatcher()
        Dropshare.fetchAppURL()

        // listen for NSWindow.willCloseNotification to release the window
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeMainNotification), name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.title == "Settings" {
            mainActor {
                settingsViewManager.windowOpen = false
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc func windowDidBecomeMainNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.title == "Settings" {
            mainActor {
                settingsViewManager.windowOpen = true
                NSApp.setActivationPolicy(.regular)

                log.debug("Starting settings tab key monitor")
                tabKeyMonitor.start()
            }
        }
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
                    if self.swipeEnded, !OM.compactResults, self.floatingResultsCorner.isTrailing ? event.scrollingDeltaX > 3 : event.scrollingDeltaX < -3,
                       let hov = hoveredOptimiserID, let optimiser = OM.optimisers.first(where: { $0.id == hov })
                    {
                        hoveredOptimiserID = nil
                        optimiser.stop(remove: true, animateRemoval: true)
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
            WM.open("settings")
            focus()
        }

        return true
    }

    override func applicationDidBecomeActive(_ notification: Notification) {
        if didBecomeActiveAtLeastOnce, !Defaults[.showMenubarIcon] {
            WM.open("settings")
            focus()
        }
        didBecomeActiveAtLeastOnce = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor func initOptimisers() {
        videoWatcher = FileOptimisationWatcher(pathsKey: .videoDirs, maxFilesToHandleKey: .maxVideoFileCount, shouldHandle: shouldHandleVideo(event:), cancel: cancelImageOptimisation(path:)) { event in
            let video = Video(path: FilePath(event.path))
            Task.init {
                try? await optimiseVideo(video, debounceMS: 200, source: Defaults[.videoDirs].filter { event.path.starts(with: $0) }.max(by: \.count))
            }
        }
        imageWatcher = FileOptimisationWatcher(pathsKey: .imageDirs, maxFilesToHandleKey: .maxImageFileCount, shouldHandle: shouldHandleImage(event:), cancel: cancelVideoOptimisation(path:)) { event in
            guard let img = Image(path: FilePath(event.path), retinaDownscaled: false) else { return }
            Task.init {
                try? await optimiseImage(img, debounceMS: 200, source: Defaults[.imageDirs].filter { event.path.starts(with: $0) }.max(by: \.count))
            }
        }
        pdfWatcher = FileOptimisationWatcher(pathsKey: .pdfDirs, maxFilesToHandleKey: .maxPDFFileCount, shouldHandle: shouldHandlePDF(event:), cancel: cancelPDFOptimisation(path:)) { event in
            guard let path = event.path.existingFilePath else { return }
            Task.init {
                try? await optimisePDF(PDF(path), debounceMS: 200, source: Defaults[.pdfDirs].filter { event.path.starts(with: $0) }.max(by: \.count))
            }
        }

        if Defaults[.enableClipboardOptimiser], !Defaults[.pauseAutomaticOptimisations] {
            initClipboardOptimiser()
        }

        #if !DEBUG
            if let product {
                _ = checkInternalRequirements([product], nil)
            }
        #endif
    }

    @MainActor func initClipboardOptimiser() {
        clipboardWatcher?.invalidate()
        clipboardWatcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let newChangeCount = NSPasteboard.general.changeCount
            guard newChangeCount != pbChangeCount else {
                return
            }
            pbChangeCount = newChangeCount
            guard !pauseForNextClipboardEvent else {
                pauseForNextClipboardEvent = false
                return
            }
            guard let item = NSPasteboard.general.pasteboardItems?.first, item.string(forType: .optimisationStatus) != "true" else {
                return
            }

            mainActor {
                if self.optimiseVideoClipboard, let path = item.existingFilePath, path.isVideo, !path.hasOptimisationStatusXattr() {
                    Task.init {
                        try? await optimiseVideo(Video(path: path), source: "clipboard")
                    }
                    return
                }
                optimiseClipboardImage(item: item)
            }
        }

        clipboardWatcher?.tolerance = 100
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

extension NSPasteboardItem {
    var existingFilePath: FilePath? {
        string(forType: .fileURL)?.fileURL?.existingFilePath ?? string(forType: .string)?.fileURL?.existingFilePath
    }
    var filePath: FilePath? {
        string(forType: .fileURL)?.fileURL?.filePath ?? string(forType: .string)?.fileURL?.filePath
    }
    var url: URL? {
        string(forType: .URL)?.url
    }
}

var statusItem: NSStatusItem? {
    NSApp.windows.lazy.compactMap { window in
        window.perform(Selector(("statusItem")))?.takeUnretainedValue() as? NSStatusItem
    }.first
}

import Ignore

@MainActor
class FileOptimisationWatcher {
    init(pathsKey: Defaults.Key<[String]>, maxFilesToHandleKey: Defaults.Key<Int>, shouldHandle: @escaping (EonilFSEventsEvent) -> Bool, cancel: @escaping (FilePath) -> Void, handler: @escaping (EonilFSEventsEvent) -> Void) {
        self.pathsKey = pathsKey
        self.maxFilesToHandleKey = maxFilesToHandleKey
        self.shouldHandle = shouldHandle
        self.cancel = cancel
        self.handler = handler

        pub(pathsKey).sink { [weak self] change in
            self?.paths = change.newValue
            self?.startWatching()
        }.store(in: &observers)

        pub(maxFilesToHandleKey).sink { [weak self] change in
            self?.maxFilesToHandle = change.newValue
        }.store(in: &observers)

        pub(.pauseAutomaticOptimisations).sink { [weak self] change in
            guard let self else { return }

            if change.newValue {
                if watching {
                    EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
                    watching = false
                }
            } else {
                startWatching()
            }
        }.store(in: &observers)

        startWatching()
    }

    deinit {
        guard watching else { return }
        EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
    }

    var watching = false

    var pathsKey: Defaults.Key<[String]>
    lazy var paths: [String] = Defaults[pathsKey]

    var maxFilesToHandleKey: Defaults.Key<Int>
    lazy var maxFilesToHandle: Int = Defaults[maxFilesToHandleKey]

    var handler: (EonilFSEventsEvent) -> Void
    var cancel: (FilePath) -> Void
    var shouldHandle: (EonilFSEventsEvent) -> Bool

    var observers = Set<AnyCancellable>()
    var justAddedFiles = Set<FilePath>()
    var cancelledFiles = Set<FilePath>()
    var addedFileRemovers = [FilePath: DispatchWorkItem]()

    var addedFilesCleaner: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    func isAddedFile(event: EonilFSEventsEvent) -> Bool {
        guard let flag = event.flag, let path = event.path.existingFilePath, let stem = path.stem, !stem.starts(with: ".") else {
            return false
        }

        return flag.isDisjoint(with: [.historyDone, .itemRemoved]) &&
            flag.contains(.itemIsFile) &&
            flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified])
    }

    func startWatching() {
        if watching {
            EonilFSEvents.stopWatching(for: ObjectIdentifier(self))
            watching = false
        }

        guard !paths.isEmpty, !Defaults[.pauseAutomaticOptimisations] else { return }

        try! EonilFSEvents.startWatching(paths: paths, for: ObjectIdentifier(self)) { event in
            guard !SWIFTUI_PREVIEW else { return }

            mainAsync { [weak self] in
                guard let self, isAddedFile(event: event), let path = event.path.existingFilePath else {
                    return
                }

                justAddedFiles.insert(path)
                addedFileRemovers[path]?.cancel()
                addedFileRemovers[path] = mainAsyncAfter(ms: 1000) { [weak self] in
                    self?.justAddedFiles.remove(path)
                    self?.addedFileRemovers.removeValue(forKey: path)
                }
            }

            mainActor { [weak self] in
                guard let self else { return }
                guard shouldHandle(event) else { return }

                guard justAddedFiles.count <= maxFilesToHandle else {
                    log.debug("More than \(maxFilesToHandle) files dropped (\(justAddedFiles.count))")
                    for path in justAddedFiles.subtracting(cancelledFiles) {
                        log.debug("Cancelling optimisation on \(path)")
                        cancel(path)
                        cancelledFiles.insert(path)
                    }
                    addedFilesCleaner = mainAsyncAfter(ms: 1000) { [weak self] in
                        self?.cancelledFiles.removeAll()
                        self?.justAddedFiles.removeAll()
                    }

                    return
                }

                if let root = paths.first(where: { event.path.hasPrefix($0) }), let ignorePath = "\(root)/.clopignore".existingFilePath, event.path.isIgnored(in: ignorePath.string) {
                    log.debug("Ignoring \(event.path) because it's in \(ignorePath.string)")
                    return
                }

                Task.init { [weak self] in
                    guard let self else { return }

                    var count = optimisedCount
                    try? await proGuard(count: &count, limit: 5, url: event.path.fileURL) {
                        self.handler(event)
                    }
                    optimisedCount = count
                }
            }
        }
        watching = true
    }

    private var optimisedCount = 0
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

    let optimiser = OM.optimiser(id: Optimiser.IDs.pro, type: .unknown, operation: "")
    optimiser.finish(error: "Free version limits reached", notice: "Only 5 file optimisations per session\nare included in the free version", keepFor: 5000)
}

#if DEBUG
    let sizeNotificationWindow = OSDWindow(swiftuiView: FloatingResultContainer().any, level: .floating, canScreenshot: true, allowsMouse: true)
#else
    let sizeNotificationWindow = OSDWindow(swiftuiView: FloatingResultContainer().any, level: .floating, canScreenshot: false, allowsMouse: true)
#endif
var clipboardWatcher: Timer?
var pbChangeCount = NSPasteboard.general.changeCount
let THUMB_SIZE = CGSize(width: 300, height: 220)

// MARK: - ClopApp

@main
struct ClopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.openWindow) var openWindow
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase

    @AppStorage("showMenubarIcon") var showMenubarIcon = Defaults[.showMenubarIcon]

    @ObservedObject var om = OM
    @ObservedObject var pm = PM
    @ObservedObject var wm = WM

    var body: some Scene {
        Window("Settings", id: "settings") {
            SettingsView()
                .frame(minWidth: 850, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: $showMenubarIcon, content: {
            MenuView()
        }, label: { SwiftUI.Image(nsImage: NSImage(named: !(pm.pro?.active ?? false) && !om.ignoreProErrorBadge && om.skippedBecauseNotPro.isNotEmpty ? "MenubarIconBadge" : "MenubarIcon")!) })
            .menuBarExtraStyle(.menu)
            .onChange(of: showMenubarIcon) { show in
                if !show {
                    openWindow(id: "settings")
                    focus()
                } else {
                    NSApplication.shared.keyWindow?.close()
                }
            }
            .onChange(of: wm.windowToOpen) { window in
                guard let window else { return }
                openWindow(id: window)
                wm.windowToOpen = nil
            }

    }
}

import ObjectiveC.runtime

extension NSFilePromiseReceiver {
    static let swizzleReceivePromisedFiles: String = {
        let originalSelector = #selector(receivePromisedFiles(atDestination:options:operationQueue:reader:))
        let swizzledSelector = #selector(swizzledReceivePromisedFiles(atDestination:options:operationQueue:reader:))

        guard let originalMethod = class_getInstanceMethod(NSFilePromiseReceiver.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSFilePromiseReceiver.self, swizzledSelector)
        else {
            return "Swizzling NSFilePromiseReceiver.receivePromisedFiles() failed"

        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        return "Swizzled NSFilePromiseReceiver.receivePromisedFiles()"
    }()

    @objc private func swizzledReceivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:], operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        let exc = tryBlock {
            self.swizzledReceivePromisedFiles(atDestination: destinationDir, options: options, operationQueue: operationQueue, reader: reader)
        }
        guard let exc else {
            return
        }
        log.error(exc.description)
    }
}

class ContextualMenuServiceProvider: NSObject {
    @objc func optimisationService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return
        }

        for item in items.map(ClipboardType.fromPasteboardItem) {
            guard item != .unknown else {
                continue
            }
            Task.init {
                try await optimiseItem(
                    item,
                    id: item.id,
                    hideFloatingResult: false,
                    downscaleTo: nil,
                    changePlaybackSpeedBy: nil,
                    aggressiveOptimisation: nil,
                    optimisationCount: &manualOptimisationCount,
                    copyToClipboard: false,
                    source: "service"
                )
            }
        }
    }
}
