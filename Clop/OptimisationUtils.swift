//
//  OptimisationUtils.swift
//  Clop
//
//  Created by Alin Panaitiu on 12.07.2023.
//

import Defaults
import Foundation
import Lowtech
import os
import QuickLookUI
import SwiftUI
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "OptimisationUtils")

enum ItemType: Equatable, Identifiable {
    case image(UTType)
    case video(UTType)
    case audio(UTType)
    case pdf
    case url
    case unknown

    var id: String {
        switch self {
        case let .image(utType):
            utType.identifier
        case let .video(utType):
            utType.identifier
        case let .audio(utType):
            utType.identifier
        case .pdf:
            "pdf"
        case .url:
            "url"
        case .unknown:
            "unknown"
        }
    }

    var convertibleTypes: [UTType] {
        switch self {
        case .image:
            [.jpeg, .webP, .avif, .heic, .png, .gif].compactMap { $0 }
        case .video:
            [.mpeg4Movie, .quickTimeMovie, .gif, .webm, .hevcVideo, .av1Video].compactMap { $0 }
        case .audio:
            [.m4a, .mp3, .oggAudio].compactMap { $0 }
        default:
            []
        }
    }

    var str: String {
        switch self {
        case .image:
            "image"
        case .video:
            "video"
        case .audio:
            "audio"
        case .pdf:
            "PDF"
        case .url:
            "file"
        case .unknown:
            "file"
        }
    }

    var icon: String {
        switch self {
        case .image:
            "photo"
        case .video:
            "film"
        case .audio:
            "waveform"
        case .pdf:
            "doc.text"
        case .url:
            "link"
        case .unknown:
            "questionmark"
        }
    }

    var ext: String? {
        switch self {
        case let .image(uTType):
            uTType.preferredFilenameExtension
        case let .video(uTType):
            uTType.preferredFilenameExtension
        case let .audio(uTType):
            uTType.preferredFilenameExtension
        case .pdf:
            "pdf"
        case .url:
            nil
        case .unknown:
            nil
        }
    }

    var isImage: Bool {
        switch self {
        case .image:
            true
        default:
            false
        }
    }

    var isVideo: Bool {
        switch self {
        case .video:
            true
        default:
            false
        }
    }

    var isAudio: Bool {
        switch self {
        case .audio:
            true
        default:
            false
        }
    }

    var isPDF: Bool {
        switch self {
        case .pdf:
            true
        default:
            false
        }
    }

    var isURL: Bool {
        switch self {
        case .url:
            true
        default:
            false
        }
    }

    var utType: UTType? {
        switch self {
        case let .image(utType):
            utType
        case let .video(utType):
            utType
        case let .audio(utType):
            utType
        case .pdf:
            .pdf
        case .url:
            nil
        case .unknown:
            nil
        }
    }

    var pipelineKey: Defaults.Key<[String: [Pipeline]]>? {
        switch self {
        case .image:
            .pipelinesToRunOnImage
        case .video:
            .pipelinesToRunOnVideo
        case .pdf:
            .pipelinesToRunOnPdf
        case .audio:
            .pipelinesToRunOnAudio
        default:
            nil
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType? {
        switch self {
        case let .image(utType):
            utType.pasteboardType
        case let .video(utType):
            utType.pasteboardType
        case let .audio(utType):
            utType.pasteboardType
        case .pdf:
            .pdf
        case .url:
            .URL
        case .unknown:
            nil
        }
    }

    static func from(mimeType: String) -> ItemType {
        switch mimeType {
        case "image/jpeg", "image/png", "image/gif", "image/tiff", "image/webp", "image/heic", "image/heif", "image/avif":
            .image(UTType(mimeType: mimeType)!)
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/x-mpeg":
            .video(UTType(mimeType: mimeType)!)
        case "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff", "audio/flac", "audio/ogg", "audio/opus":
            .audio(UTType(mimeType: mimeType) ?? .mp3)
        case "application/pdf":
            .pdf
        case "text/html":
            .url
        default:
            .unknown
        }
    }
    static func from(filePath: FilePath) -> ItemType {
        guard let fileType = filePath.fetchFileType()?.split(separator: ";").first?.s else {
            return .unknown
        }

        switch fileType {
        case "image/jpeg", "image/png", "image/gif", "image/tiff", "image/webp", "image/heic", "image/heif", "image/avif":
            return .image(UTType(mimeType: fileType)!)
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/x-mpeg", "video/webm":
            return .video(UTType(mimeType: fileType)!)
        case "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff", "audio/flac", "audio/ogg", "audio/opus":
            return .audio(UTType(mimeType: fileType) ?? .mp3)
        case "application/pdf":
            return .pdf
        case "text/html":
            return .url
        default:
            return .unknown
        }
    }
}

var hoveredOptimiserIDTask: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}
var lastFocusedApp: NSRunningApplication?
var hoveredOptimiserID: String? {
    didSet {
        guard hoveredOptimiserID != oldValue else {
            return
        }
        hoveredOptimiserIDTask = mainAsyncAfter(ms: 200) {
            mainActor {
                guard hoveredOptimiserID != nil, !SM.selecting else {
                    log.debug("Hovered optimiser ID is nil, stopping hover hotkeys")
                    KM.secondaryKeys = []
                    KM.reinitHotkeys()
                    hoverKeyGlobalMonitor.stop()
                    hoverKeyLocalMonitor.stop()
                    return
                }

                log.debug("Hovered optimiser ID is \(hoveredOptimiserID!), starting hover hotkeys")
                KM.secondaryKeys = DEFAULT_HOVER_KEYS
                KM.reinitHotkeys()
                hoverKeyGlobalMonitor.start()
                hoverKeyLocalMonitor.start()
            }
        }
    }
}

@MainActor var lastQuicklookModifierFlags: NSEvent.ModifierFlags = []
@MainActor var possibleShiftQuickLook = true
@MainActor var hoverKeyGlobalMonitor = GlobalEventMonitor(mask: [.flagsChanged]) { event in
    guard !SM.selecting else { return }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    defer {
        lastQuicklookModifierFlags = flags
        if flags.isEmpty {
            possibleShiftQuickLook = true
        }
    }

    if flags.isNotEmpty, flags != [.shift] {
        possibleShiftQuickLook = false
    }

    if possibleShiftQuickLook, lastQuicklookModifierFlags == [.shift], flags == [] {
        if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible {
            QLPreviewPanel.shared().close()
        } else if let opt = OM.hovered, !opt.editingFilename {
            opt.quicklook()
        }
    }
}
@MainActor var hoverKeyLocalMonitor = LocalEventMonitor(mask: [.flagsChanged]) { event in
    guard !SM.selecting else { return event }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    defer {
        lastQuicklookModifierFlags = flags
        if flags.isEmpty {
            possibleShiftQuickLook = true
        }
    }

    if flags.isNotEmpty, flags != [.shift] {
        possibleShiftQuickLook = false
    }

    if possibleShiftQuickLook, lastQuicklookModifierFlags == [.shift], flags == [] {
        if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible {
            QLPreviewPanel.shared().close()
        } else if let opt = OM.hovered, !opt.editingFilename {
            opt.quicklook()
        }
        return nil
    }
    return event
}

@MainActor var lastDropzoneModifierFlags: NSEvent.ModifierFlags = []
@MainActor var possibleOptionDropzone = true

@MainActor func handleOptionToggleDropZone() {
    if DM.dropZoneAtCursor {
        // Cursor drop zone is visible: hide it
        DM.showDropZone = false
    } else if DM.showDropZone {
        // Corner drop zone is visible: hide it and show at cursor instead
        DM.showDropZone = false
        DM.dropZoneAtCursor = true
        DM.showDropZone = true
    } else {
        // Not visible: show at cursor
        DM.dropZoneAtCursor = true
        DM.showDropZone = true
    }
}

@MainActor var dropZoneKeyGlobalMonitor = GlobalEventMonitor(mask: [.flagsChanged]) { event in
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    defer {
        lastDropzoneModifierFlags = flags
        if flags.isEmpty {
            possibleOptionDropzone = true
        }
    }

    if flags.isNotEmpty, flags != [.option] {
        possibleOptionDropzone = false
    }

    if possibleOptionDropzone, lastDropzoneModifierFlags == [.option], flags == [] {
        handleOptionToggleDropZone()
    }
}
@MainActor var dropZoneKeyLocalMonitor = LocalEventMonitor(mask: [.flagsChanged]) { event in
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    defer {
        lastDropzoneModifierFlags = flags
        if flags.isEmpty {
            possibleOptionDropzone = true
        }
    }

    if flags.isNotEmpty, flags != [.option] {
        possibleOptionDropzone = false
    }

    if possibleOptionDropzone, lastDropzoneModifierFlags == [.option], flags == [] {
        handleOptionToggleDropZone()
        return nil
    }
    return event
}

@MainActor var lastPresetZonesModifierFlags: NSEvent.ModifierFlags = []
@MainActor var possibleControlPresetZones = true

@MainActor var presetZonesKeyGlobalMonitor = GlobalEventMonitor(mask: [.flagsChanged]) { event in
    let flags = event.modifierFlags.intersection([.command, .control, .control, .shift])
    defer {
        lastPresetZonesModifierFlags = flags
        if flags.isEmpty {
            possibleControlPresetZones = true
        }
    }

    if flags.isNotEmpty, flags != [.control] {
        possibleControlPresetZones = false
    }

    if possibleControlPresetZones, lastPresetZonesModifierFlags == [.control], flags == [] {
        DM.showPresetZones.toggle()
    }
}
@MainActor var presetZonesKeyLocalMonitor = LocalEventMonitor(mask: [.flagsChanged]) { event in
    let flags = event.modifierFlags.intersection([.command, .control, .control, .shift])
    defer {
        lastPresetZonesModifierFlags = flags
        if flags.isEmpty {
            possibleControlPresetZones = true
        }
    }

    if flags.isNotEmpty, flags != [.control] {
        possibleControlPresetZones = false
    }

    if possibleControlPresetZones, lastPresetZonesModifierFlags == [.control], flags == [] {
        DM.showPresetZones.toggle()
        return nil
    }
    return event
}

@MainActor
class OptimiserProgressDelegate: NSObject, URLSessionDataDelegate {
    init(optimiser: Optimiser) {
        self.optimiser = optimiser
    }

    let optimiser: Optimiser

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        log.debug("Finished downloading \(location.path)")
    }

    func handleTask(_ task: URLSessionTask) {
        optimiser.progress = task.progress
        if !optimiser.running || optimiser.inRemoval {
            task.cancel()
        }
        optimiser.progress.publish()
    }

    nonisolated func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        mainActor { self.handleTask(task) }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome downloadTask: URLSessionDownloadTask) {
        mainActor { self.handleTask(downloadTask) }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome streamTask: URLSessionStreamTask) {
        mainActor { self.handleTask(streamTask) }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        mainActor { self.handleTask(dataTask) }
    }
}

final class QuickLooker: QLPreviewPanelDataSource {
    init(url: URL) {
        self.url = url
    }

    static var shared: QuickLooker?

    let url: URL

    static func quicklook(url: URL) {
        shared = QuickLooker(url: url)
        shared?.quicklook()
    }

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        1
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> QLPreviewItem! {
        url as NSURL
    }

    func quicklook() {
        guard let ql = QLPreviewPanel.shared() else { return }

        focus()
        ql.makeKeyAndOrderFront(nil)
        ql.dataSource = self
        ql.currentPreviewItemIndex = 0
        ql.reloadData()
    }
}

@MainActor final class BinaryManager: ObservableObject {
    @Published var decompressingBinaries = false
}

@MainActor var BM = BinaryManager()

// MARK: - Optimiser

@MainActor final class Optimiser: ObservableObject, Identifiable, Hashable, Equatable, CustomStringConvertible {
    init(id: String, type: ItemType, running: Bool = true, oldBytes: Int = 0, newBytes: Int = 0, oldSize: CGSize? = nil, newSize: CGSize? = nil, progress: Progress? = nil, operation: String = "Optimising") {
        self.id = id
        self.type = type
        self.running = running
        self.oldBytes = oldBytes
        self.newBytes = newBytes
        if let progress { self.progress = progress }
        if let oldSize { self.oldSize = oldSize }
        if let newSize { self.newSize = newSize }
        self.operation = operation
    }

    enum IDs {
        static let clipboardImage = "Clipboard image"
        static let clipboard = "Clipboard"
        static let pro = "Pro"
    }

    var processes: [Process] = []
    let id: String
    var type: ItemType
    let startedAt = Date()
    var isPreview = false
    @Published var hidden = false
    @Published var isOriginal = false
    @Published var progress = Progress()

    @Published var oldBytes = 0
    @Published var newBytes = 0

    @Published var oldSize: CGSize? = nil
    @Published var newSize: CGSize? = nil

    @Published var error: String? = nil
    @Published var notice: String? = nil
    @Published var info: String? = nil
    @Published var thumbnail: NSImage?
    @Published var originalURL: URL?
    @Published var startingURL: URL?
    @Published var convertedFromURL: URL?
    @Published var downscaleFactor = 1.0
    @Published var changePlaybackSpeedFactor = 1.0
    @Published var aggressive = false

    lazy var path: FilePath? = {
        if let url { return FilePath(url) }
        return id == IDs.clipboardImage ? nil : FilePath(stringLiteral: id)
    }()
    lazy var filename: String =
        id == IDs.clipboardImage ? id : (url?.lastPathComponent ?? FilePath(stringLiteral: id).name.string)

    var lastRemoveAfterMs: Int? = nil

    @Published var inRemoval = false

    @Atomic var retinaDownscaled = false

    var source: OptimisationSource?

    @Published var sharing = false
    @Published var isVideoWithAudio = false

    lazy var image: Image? = fetchImage()
    lazy var video: Video? = fetchVideo()
    lazy var pdf: PDF? = fetchPDF()
    lazy var audio: Audio? = fetchAudio()

    var comparisonWindowController: NSWindowController?

    var isComparing = false

    var fileType: ClopFileType? {
        switch type {
        case .image:
            .image
        case .video:
            .video
        case .audio:
            .audio
        case .pdf:
            .pdf
        default:
            url?.utType()?.fileType
        }
    }
    var comparisonOriginalURL: URL? {
        if let startingURL, startingURL != url, fm.fileExists(atPath: startingURL.path) { return startingURL }
        if let originalURL, originalURL != url, fm.fileExists(atPath: originalURL.path) { return originalURL }
        if let convertedFromURL, convertedFromURL != url, fm.fileExists(atPath: convertedFromURL.path) { return convertedFromURL }
        if let backupPath = path?.clopBackupPath?.url, backupPath != url, fm.fileExists(atPath: backupPath.path) { return backupPath }
        return nil
    }

    @Published var editing = false {
        didSet {
            guard editing != oldValue else {
                return
            }

            if editing {
                KM.secondaryKeys = []
                KM.reinitHotkeys()
            } else {
                floatingResultsWindow.allowToBecomeKey = false
                if hoveredOptimiserID != nil {
                    KM.secondaryKeys = DEFAULT_HOVER_KEYS
                    KM.reinitHotkeys()
                }
            }

            if let lastRemoveAfterMs, lastRemoveAfterMs < 1000 * 120 {
                self.lastRemoveAfterMs = 1000 * 120
                resetRemover()
            }
        }
    }
    @Published var editingResolution = false {
        didSet {
            mainActor { [weak self] in
                guard let self else { return }
                editing = editingFilename || editingResolution
            }
        }
    }

    @Published var editingFilename = false {
        didSet {
            mainActor { [weak self] in
                guard let self else { return }
                editing = editingFilename || editingResolution
            }
        }
    }
    @Published var overlayMessage = "" {
        didSet {
            guard overlayMessage.isNotEmpty else { return }
            overlayMessageResetter = mainAsyncAfter(ms: 1000) { [weak self] in
                self?.overlayMessage = ""
            }
        }
    }
    var overlayMessageResetter: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    @Published var running = true {
        didSet {
            if running, !oldValue {
                stopRemover()
                info = nil
            }
            mainActor { OM.updateProgress() }
            if !running, oldValue {
                tryAsync { try await self.checkIfVideoHasAudio() }

                if OM.compactResults {
                    let removeAfterMs = Defaults[.autoClearAllCompactResultsAfter]
                    guard removeAfterMs > 0 else { return }

                    let visibleOptimisers = OM.optimisers.filter { !$0.hidden }
                    if visibleOptimisers.allSatisfy({ !$0.running }) {
                        OM.removeVisibleOptimisers(after: removeAfterMs * 1000)
                    }
                }
            }
        }
    }

    @Published var url: URL? {
        didSet {
            log.debug("URL set to \(self.url?.path ?? "nil") from \(oldValue?.path ?? "nil")")
            if startingURL == nil {
                startingURL = url
            }
            path = {
                if let url { return FilePath(url) }
                return id == IDs.clipboardImage ? nil : FilePath(stringLiteral: id)
            }()
            filename =
                id == IDs.clipboardImage ? id : (url?.lastPathComponent ?? FilePath(stringLiteral: id).name.string)
            refetch()
        }
    }

    @Published var operation = "Optimising" { didSet {
        if !progress.isIndeterminate {
            progress.localizedDescription = operation
        }
    }}

    var description: String {
        "\(operation) \(id) [\(running ? "RUNNING" : "FINISHED")]"
    }

    var remover: DispatchWorkItem? { didSet {
        oldValue?.cancel()
    }}
    var deleter: DispatchWorkItem? { didSet {
        oldValue?.cancel()
    }}

    nonisolated static func == (lhs: Optimiser, rhs: Optimiser) -> Bool {
        lhs.id == rhs.id
    }

    func convert(to type: UTType, optimise: Bool = false) {
        guard type != self.type.utType else { return }
        let typeStr = type.preferredFilenameExtension ?? type.identifier
        operation = "Converting to \(typeStr)"
        progress = Progress()
        progress.localizedAdditionalDescription = ""
        progress.completedUnitCount = 0
        running = true
        isOriginal = false

        switch self.type {
        case .image:
            guard let image = self.image else {
                return
            }
            imageOptimisationQueue.addOperation { [weak self] in
                guard let converted = try? image.convert(to: type, asTempFile: false, optimiser: optimise ? self : nil) else {
                    mainActor {
                        guard let self else { return }
                        self.finish(error: "\(typeStr) conversion failed")
                    }
                    return
                }
                mainActor {
                    guard let self else { return }
                    if self.convertedFromURL == nil {
                        self.convertedFromURL = self.url
                    }
                    self.image = converted
                    self.type = .image(converted.type)
                    self.url = converted.path.url
                    self.error = nil
                    self.notice = nil
                    self.info = nil
                    self.finish(oldBytes: self.oldBytes, newBytes: converted.data.count, oldSize: self.oldSize, newSize: converted.size, removeAfterMs: self.lastRemoveAfterMs)
                }
            }
        case .audio:
            guard let audio = self.audio else { return }
            guard let format = AudioFormat.allCases.first(where: { $0.utType == type }) else { return }
            DispatchQueue.global().async { [weak self] in
                guard let converted = try? audio.convert(to: format, optimiser: self!) else {
                    mainActor {
                        guard let self else { return }
                        self.finish(error: "\(typeStr) conversion failed")
                    }
                    return
                }
                mainActor {
                    guard let self else { return }
                    if self.convertedFromURL == nil {
                        self.convertedFromURL = self.url
                    }
                    self.audio = converted
                    self.type = .audio(type)
                    self.url = converted.path.url
                    self.error = nil
                    self.notice = nil
                    self.info = nil
                    self.finish(oldBytes: self.oldBytes, newBytes: converted.fileSize, removeAfterMs: self.lastRemoveAfterMs)
                }
            }
        case .video:
            guard let url else { return }
            let path = FilePath(url.path)
            let video = Video(path: path)
            let isCodecConversion = type == .hevcVideo || type == .av1Video

            let encoderOverride: [String]? = if type == .hevcVideo {
                ["-vcodec", "hevc_videotoolbox", "-q:v", "40", "-tag:v", "hvc1"]
            } else if type == .av1Video {
                ["-vcodec", "libsvtav1"]
            } else {
                nil
            }

            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                if type == .gif {
                    guard let result = try? video.convertToGIF(optimiser: self, maxWidth: 960, fps: 15) else {
                        mainActor { self.finish(error: "GIF conversion failed") }
                        return
                    }
                    mainActor {
                        if self.convertedFromURL == nil { self.convertedFromURL = self.url }
                        self.type = .image(.gif)
                        self.url = result.path.url
                        self.error = nil
                        self.notice = nil
                        self.finish(oldBytes: self.oldBytes, newBytes: result.data.count, removeAfterMs: self.lastRemoveAfterMs)
                    }
                } else {
                    let forceMP4 = type == .hevcVideo || type == .mpeg4Movie
                    let outputExt: String? = type == .av1Video ? "mkv" : nil
                    guard let result = try? video.optimise(
                        optimiser: self, forceMP4: forceMP4, outputExtension: outputExt, backup: false,
                        encoderOverride: encoderOverride
                    ) else {
                        let label = type.preferredFilenameExtension ?? "video"
                        mainActor { self.finish(error: "\(label) conversion failed") }
                        return
                    }
                    mainActor {
                        if self.convertedFromURL == nil { self.convertedFromURL = self.url }
                        self.type = isCodecConversion ? .video(type) : .video(UTType(filenameExtension: result.path.extension ?? "mp4") ?? .mpeg4Movie)
                        self.url = result.path.url
                        self.error = nil
                        self.notice = nil
                        self.finish(oldBytes: self.oldBytes, newBytes: result.fileSize, removeAfterMs: self.lastRemoveAfterMs)
                    }
                }
            }
        default:
            break
        }
    }

    func compare() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: COMPARISON_VIEW_SIZE * 2 + 100, height: COMPARISON_VIEW_SIZE + 200),
            styleMask: [.fullSizeContentView, .titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Comparison"
        window.isReleasedWhenClosed = true
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("Compare Window")

        window.contentView = NSHostingView(
            rootView: CompareView(optimiser: self)
                .frame(
                    minWidth: COMPARISON_VIEW_SIZE + 100, idealWidth: COMPARISON_VIEW_SIZE * 2 + 100,
                    minHeight: COMPARISON_VIEW_SIZE / 2 + 200, idealHeight: COMPARISON_VIEW_SIZE + 200
                )
                .padding()
                .background(.regularMaterial)
        )
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.center()
        focus()

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)

        comparisonWindowController = NSWindowController(window: window)
        isComparing = true
    }

    @objc func windowWillClose(_ notification: Notification) {
        isComparing = false
        let cachedURLs = [url, startingURL, originalURL, convertedFromURL].compactMap { $0 }
        PDFKitView.clearCache(for: cachedURLs)
        PannableImage.clearCache(for: cachedURLs)
        LoopingVideoPlayer.clearCache(for: cachedURLs)
        comparisonWindowController = nil
    }

    func fetchVideo() -> Video? {
        guard type.isVideo, let path = url?.existingFilePath else { return nil }
        return Video(path: path, thumb: !hidden, id: id)
    }

    func fetchImage() -> Image? {
        guard case let .image(imageType) = type, let path = url?.existingFilePath else { return nil }
        return Image(path: path, type: imageType, retinaDownscaled: false)
    }

    func fetchPDF() -> PDF? {
        guard type.isPDF, let path = url?.existingFilePath else { return nil }
        return PDF(path, thumb: !hidden, id: id)
    }

    func fetchAudio() -> Audio? {
        guard type.isAudio, let path = url?.existingFilePath else { return nil }
        return Audio(path: path, thumb: false, id: id)
    }

    func refetch() {
        if let image, image.path != self.url?.filePath {
            self.image = fetchImage()
            return
        }
        if let video, video.path != self.url?.filePath {
            self.video = fetchVideo()
            return
        }
        if let pdf, pdf.path != self.url?.filePath {
            self.pdf = fetchPDF()
            return
        }
        if let audio, audio.path != self.url?.filePath {
            self.audio = fetchAudio()
            return
        }
        if let image = fetchImage() {
            self.image = image
            return
        }
        if let video = fetchVideo() {
            self.video = video
            return
        }
        if let pdf = fetchPDF() {
            self.pdf = pdf
            return
        }
        if let audio = fetchAudio() {
            self.audio = audio
            return
        }
    }

    func checkIfVideoHasAudio() async throws {
        guard type.isVideo, let path = url?.existingFilePath else {
            isVideoWithAudio = false
            return
        }

        let hasAudio = try await videoHasAudio(path: path)
        await MainActor.run { self.isVideoWithAudio = hasAudio }
    }

    func rename(to newFileName: String) {
        let newFileName = newFileName.safeFilename
        guard !newFileName.isEmpty, let currentPath = url?.existingFilePath, currentPath.stem != newFileName else {
            return
        }

        var pathToMoveTo = currentPath.dir / "\(newFileName).\(currentPath.extension ?? "")"
        if pathToMoveTo.exists {
            var i = 2
            while pathToMoveTo.exists {
                pathToMoveTo = currentPath.dir / "\(newFileName)_\(i).\(currentPath.extension ?? "")"
                i += 1
            }
        }
        guard let newPath = try? currentPath.move(to: pathToMoveTo) else {
            return
        }

        url = newPath.url
        path = newPath
        filename = newPath.name.string

        if let items = NSPasteboard.general.pasteboardItems, items.count == 1, let item = items.first, item.filePath?.name == currentPath.name {
            copyToClipboard()
        }
    }

    func quicklook() {
        resetRemover()
        OM.quicklook(optimiser: self)
    }

    func canChangeFormat() -> Bool {
        type.convertibleTypes.isNotEmpty
    }

    func canReoptimise() -> Bool {
        switch type {
        case .image(.png), .image(.jpeg), .image(.gif), .video(.mpeg4Movie), .video(.quickTimeMovie), .pdf:
            true
        default:
            false
        }
    }

    func canDownscale() -> Bool {
        switch type {
        case .image(.png), .image(.jpeg), .image(.gif), .video(.mpeg4Movie), .video(.quickTimeMovie):
            true
        default:
            false
        }
    }

    func canCrop() -> Bool {
        switch type {
        case .image(.png), .image(.jpeg), .image(.gif), .video(.mpeg4Movie), .video(.quickTimeMovie), .pdf:
            true
        default:
            false
        }
    }

    func canChangePlaybackSpeed() -> Bool {
        type.isVideo && !inRemoval
    }

    func canRemoveAudio() -> Bool {
        type.isVideo && !inRemoval && isVideoWithAudio
    }

    func removeAudio() {
        guard !inRemoval, !SWIFTUI_PREVIEW else { return }

        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil
        operation = "Removing audio"
        progress.localizedAdditionalDescription = ""
        progress.completedUnitCount = 0
        running = true

        guard let path, path.exists else {
            return
        }
        tryAsync { [weak self] in
            guard let oldBytes = self?.oldBytes, let id = self?.id else { return }
            guard let video = try await Video.byFetchingMetadata(path: path, fileSize: oldBytes, id: id) else {
                return
            }

            guard let self else { return }
            try video.removeAudio(optimiser: self)
            self.isVideoWithAudio = false
            self.progress.completedUnitCount = self.progress.totalUnitCount
            finish(oldBytes: oldBytes, newBytes: path.fileSize() ?? self.newBytes)
        }
    }

    func changePlaybackSpeed(byFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) {
        guard !inRemoval, !SWIFTUI_PREVIEW else { return }

        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil

        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggressive = aggressiveOptimisation
        } else if aggressive {
            shouldUseAggressiveOptimisation = true
        }

        guard let path = originalURL?.filePath ?? path else {
            return
        }
        let originalPath = (path.clopBackupPath?.exists ?? false) ? path.clopBackupPath : convertedFromURL?.existingFilePath
        if !path.exists, let originalPath {
            let _ = try? originalPath.copy(to: path)
        }

        Task.init {
            // Use current path (may have been renamed) for the output destination,
            // pass the backup/original as originalPath so ffmpeg reads from it
            let videoPath = self.path ?? path
            guard let video = try await Video.byFetchingMetadata(path: videoPath, fileSize: oldBytes, id: self.id) else {
                return
            }

            if let factor {
                changePlaybackSpeedFactor = factor
            }

            let _ = try? await runVideoPipeline(
                video,
                actions: [.changePlaybackSpeed(factor: factor ?? changePlaybackSpeedFactor)],
                id: self.id,
                originalPath: path != videoPath ? path : originalPath,
                hideFloatingResult: hideFloatingResult,
                aggressiveOptimisation: shouldUseAggressiveOptimisation
            )
        }
    }

    func downscale(toFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) {
        guard !inRemoval else { return }

        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil

        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggressive = aggressiveOptimisation
        } else if aggressive {
            shouldUseAggressiveOptimisation = true
        }

        guard var path = originalURL?.filePath ?? path else {
            return
        }
        if let selfPath = self.path, selfPath.extension?.lowercased() == "gif", path.extension?.lowercased() != "gif" {
            path = selfPath
        }

        let originalPath = (path.clopBackupPath?.exists ?? false) ? path.clopBackupPath : convertedFromURL?.existingFilePath
        if !path.exists, let originalPath {
            let _ = try? originalPath.copy(to: path)
        }

        Task.init {
            if type.isImage, let image = Image(path: path, retinaDownscaled: self.retinaDownscaled) {
                if !hidden, thumbnail == nil {
                    thumbnail = image.image
                }
                if let factor {
                    downscaleFactor = factor
                }
                let _ = try? await runImagePipeline(
                    image, actions: [.downscale(factor: factor, cropSize: nil)],
                    id: self.id, saveTo: self.path,
                    copyToClipboard: id == IDs.clipboardImage,
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: shouldUseAggressiveOptimisation
                )
            }
            if type.isVideo {
                // Use current path (may have been renamed) for the output destination,
                // pass the backup/original as originalPath so ffmpeg reads from it
                let videoPath = self.path ?? path
                let video = if let oldSize {
                    Video(path: videoPath, metadata: VideoMetadata(resolution: oldSize, fps: 0, hasAudio: isVideoWithAudio), fileSize: oldBytes, thumb: false)
                } else {
                    try? await Video.byFetchingMetadata(path: videoPath, fileSize: oldBytes, thumb: !hidden, id: self.id)
                }
                guard let video else { return }

                if let factor {
                    downscaleFactor = factor
                }

                let _ = try? await runVideoPipeline(
                    video,
                    actions: [.downscale(factor: factor, cropSize: nil)],
                    id: self.id,
                    originalPath: path != videoPath ? path : ((path.clopBackupPath?.exists ?? false) ? path.clopBackupPath : convertedFromURL?.existingFilePath),
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: shouldUseAggressiveOptimisation
                )
            }
        }
    }

    func uiStop() {
        if url == nil, let originalURL {
            url = originalURL
        }
        if oldBytes == 0, let path = (url ?? originalURL)?.existingFilePath, let size = path.fileSize() {
            oldBytes = size
        }
        running = false
    }
    func stop(remove: Bool = true, animateRemoval: Bool = true) {
        if running {
            for process in processes {
                let pid = process.processIdentifier
                mainActor { processTerminated.insert(pid) }

                (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                process.terminate()
            }
        }
        if remove {
            self.remove(after: (animateRemoval && !OM.compactResults) ? 500 : 0, withAnimation: !OM.compactResults)
        }
    }

    func reoptimise() {
        try? (path ?? url?.filePath)?.removeOptimisationStatusXattr()
        optimise()
    }

    func reoptimiseWithEncoder(_ encoder: VideoEncoder) {
        Defaults[.videoEncoder] = encoder
        try? (path ?? url?.filePath)?.removeOptimisationStatusXattr()
        optimise(fromOriginal: true)
    }

    func optimise(allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil, fromOriginal: Bool = false) {
        guard let url, var path = url.filePath else { return }
        stopRemover()
        error = nil
        notice = nil
        info = nil

        if fromOriginal, !path.exists || path.hasOptimisationStatusXattr() {
            if let backup = path.clopBackupPath, backup.exists {
                path.restore(backupPath: backup, force: true)
            } else if let startingPath = startingURL?.existingFilePath, let originalPath = originalURL?.existingFilePath, originalPath != startingPath {
                path = (try? originalPath.copy(to: startingPath, force: true)) ?? path
            }
        }
        if path.starts(with: FilePath.clopBackups) {
            path = (try? path.copy(to: type.isImage ? FilePath.images : FilePath.videos, force: true)) ?? path
        }

        isOriginal = false
        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggressive = aggressiveOptimisation
        } else if aggressive {
            shouldUseAggressiveOptimisation = true
        }
        if type.isImage, let img = Image(path: path, retinaDownscaled: self.retinaDownscaled) {
            Task.init { try? await runImagePipeline(img, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation) }
            return
        }
        if type.isVideo, path.exists {
            Task.init {
                let video = if let oldSize {
                    Video(path: path, metadata: VideoMetadata(resolution: oldSize, fps: 0, hasAudio: isVideoWithAudio), fileSize: oldBytes, thumb: false)
                } else {
                    try? await Video.byFetchingMetadata(path: path, fileSize: oldBytes, id: id)
                }
                guard let video else { return }
                let _ = try? await runVideoPipeline(video, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation)
            }
        }
        if type.isPDF, path.exists, let pdf {
            Task.init { try? await runPDFPipeline(pdf, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation) }
        }
    }

    func restoreOriginal() {
        guard let url, var path = url.filePath else { return }
        scalingFactor = 1.0
        downscaleFactor = 1.0
        changePlaybackSpeedFactor = 1.0
        aggressive = false
        resetRemover()

        let restore: (FilePath) -> Void = { path in
            guard let backup = path.clopBackupPath, backup.exists else { return }
            try? backup.setOptimisationStatusXattr("original")
            path.restore(backupPath: backup)
        }

        if let convertedFromURL, let convertedFromPath = convertedFromURL.filePath {
            if convertedFromPath.starts(with: FilePath.clopBackups), convertedFromPath.exists, let ext = convertedFromPath.extension, ext != path.extension {
                let originalPath = path.withExtension(ext)
                do {
                    try convertedFromPath.copy(to: originalPath, force: true)
                    self.url = originalPath.url
                    path = originalPath
                } catch {
                    log.error("Error restoring original: \(error)")
                }
            } else {
                self.url = convertedFromURL
                path = convertedFromPath

                restore(path)
            }

            if let startingPath = startingURL?.existingFilePath, startingPath != path, startingPath.stem == path.stem, startingPath.dir == path.dir {
                try? startingPath.delete()
            }
        } else if let startingURL, let startingPath = startingURL.filePath, startingPath.clopBackupPath?.exists ?? false {
            path = startingPath
            self.url = startingURL

            restore(path)
        } else if let originalURL, let originalPath = originalURL.filePath {
            self.url = originalURL
            path = originalPath
        } else {
            restore(path)
        }
        self.oldBytes = path.fileSize() ?? self.oldBytes
        self.newBytes = -1
        self.newSize = nil
        if type == .image(.gif), path.isVideo, let utType = path.url.utType() {
            self.type = .video(utType)
        }

        if let utType = path.url.utType() {
            self.type = switch self.type {
            case .image: .image(utType)
            case .video: .video(utType)
            default: self.type
            }
        }
        if type.isImage, let image = Image(path: path, retinaDownscaled: self.retinaDownscaled), id == IDs.clipboardImage {
            image.copyToClipboard()
        }
        isOriginal = true
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func copyToClipboard(withPath: Bool? = nil) {
        guard let url, let path else { return }
        if type.isImage, let image = Image(path: path, retinaDownscaled: self.retinaDownscaled) {
            image.copyToClipboard(withPath: withPath)
            return
        }

        let item = NSPasteboardItem()
        if withPath ?? true {
            item.setString(url.path, forType: .string)
            item.setString(url.absoluteString, forType: .fileURL)
        }
        item.setString("true", forType: .optimisationStatus)
        if type.isPDF, let data = fm.contents(atPath: path.string), data.isNotEmpty {
            item.setData(data, forType: .pdf)
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])

    }

    func showInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func save() {
        guard let url, let path = url.existingFilePath else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = path.name.string
        // panel.directoryURL = path.dir.url
        // panel.allowedFileTypes = [path.ext]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let savedPath = try? path.copy(to: url.filePath!, force: true) {
                self?.overlayMessage = "Saved"
                self?.url = url
                self?.path = savedPath
                self?.filename = savedPath.name.string
            } else {
                self?.overlayMessage = "Error saving"
            }
        }
    }

    func finish(error: String, notice: String? = nil, keepFor removeAfterMs: Int = 2500) {
        self.error = error
        self.notice = notice
        self.running = false
        self.removeDebouncer()

        guard !OM.compactResults else { return }
        self.remove(after: removeAfterMs)
    }

    func finish(notice: String) {
        self.notice = notice
        self.running = false
        self.removeDebouncer()

        self.remove(after: 2500)
    }

    func finish(oldBytes: Int, newBytes: Int, oldSize: CGSize? = nil, newSize: CGSize? = nil, removeAfterMs: Int? = nil) {
        guard !self.inRemoval else { return }
        self.stopRemover()
        withAnimation(.easeOut(duration: 0.5)) {
            self.oldBytes = oldBytes
            self.newBytes = newBytes
            if let oldSize { self.oldSize = oldSize }
            if let newSize { self.newSize = newSize }
            self.running = false
        }
        self.removeDebouncer()

        guard !self.hidden else {
            self.remove(after: removeAfterMs ?? 2500)
            return
        }

        guard let removeAfterMs, removeAfterMs > 0, !OM.compactResults else { return }

        self.remove(after: removeAfterMs)
    }

    func stopRemover() {
        guard !hidden else { return }

        self.remover = nil
        self.inRemoval = false
        self.lastRemoveAfterMs = nil
        OM.remover = nil
        OM.lastRemoveAfterMs = nil
    }

    func resetRemover() {
        guard !self.hidden, !self.inRemoval, self.remover != nil, let lastRemoveAfterMs = self.lastRemoveAfterMs else {
            return
        }

        self.remove(after: lastRemoveAfterMs)
    }

    func bringBack() {
        self.stopRemover()
        OM.optimisers = OM.optimisers.with(self)
    }

    func crop(to size: CropSize) {
        guard let url, url.isFileURL, url.filePath?.exists ?? false else { return }

        let clip = ClipboardType.fromURL(url)

        Task.init {
            try await optimiseItem(
                clip,
                id: id,
                hideFloatingResult: false,
                cropTo: size,
                aggressiveOptimisation: aggressive,
                optimisationCount: &manualOptimisationCount,
                copyToClipboard: id == IDs.clipboardImage,
                source: source,
                optimisedFileBehaviour: .inPlace
            )
        }
    }

    func removeDebouncer() {
        let ids = [path?.string, url?.filePath?.string, convertedFromURL?.filePath?.string, originalURL?.filePath?.string, startingURL?.filePath?.string].compactMap { $0 }.uniqued
        for id in ids {
            if let debouncer = imageOptimiseDebouncers[id] {
                log.debug("Removing image optimise debouncer for \(id)")
                debouncer.cancel()
                imageOptimiseDebouncers.removeValue(forKey: id)
            }
            if let debouncer = imageResizeDebouncers[id] {
                log.debug("Removing image resize debouncer for \(id)")
                debouncer.cancel()
                imageResizeDebouncers.removeValue(forKey: id)
            }
            if let debouncer = videoOptimiseDebouncers[id] {
                log.debug("Removing video optimise debouncer for \(id)")
                debouncer.cancel()
                videoOptimiseDebouncers.removeValue(forKey: id)
            }
            if let debouncer = pdfOptimiseDebouncers[id] {
                log.debug("Removing pdf optimise debouncer for \(id)")
                debouncer.cancel()
                pdfOptimiseDebouncers.removeValue(forKey: id)
            }
        }
    }

    func remove(after ms: Int, withAnimation: Bool = false) {
        guard !inRemoval, !SWIFTUI_PREVIEW, !SM.selecting, !SHARING_MANAGER.isShowingPicker, !sharing else { return }

        self.lastRemoveAfterMs = ms
        self.remover = mainAsyncAfter(ms: ms) { [weak self] in
            guard let self else { return }
            guard !hidden else {
                OM.optimisers = OM.optimisers.filter { $0.id != self.id }
                OM.removedOptimisers = OM.removedOptimisers.filter { $0.id != self.id && !$0.hidden && !$0.isPreview }
                removeDebouncer()
                return
            }

            guard hoveredOptimiserID == nil, !DM.dragging, !editingFilename, !SM.selecting, !SHARING_MANAGER.isShowingPicker, !sharing else {
                if editingFilename, let lastRemoveAfterMs = self.lastRemoveAfterMs, lastRemoveAfterMs < 1000 * 120 {
                    self.lastRemoveAfterMs = 1000 * 120
                }
                self.inRemoval = false
                self.resetRemover()
                return
            }
            self.editingFilename = false
            OM.optimisers = OM.optimisers.filter { $0.id != self.id }
            if url != nil {
                OM.removedOptimisers = OM.removedOptimisers.without(self).with(self).filter { !$0.hidden && !$0.isPreview }

                self.deleter = mainAsyncAfter(ms: 600_000) { [weak self] in
                    guard let self else { return }

                    if OM.removedOptimisers.contains(self) {
                        OM.removedOptimisers = OM.removedOptimisers.without(self)
                    }
                }
            }
        }

        if withAnimation, hoveredOptimiserID == nil, !DM.dragging {
            self.inRemoval = true
        }
    }
}

@MainActor
class OptimisationManager: ObservableObject, QLPreviewPanelDataSource {
    @Published var progress: Progress?
    @Published var current: Optimiser?
    @Published var skippedBecauseNotPro: [URL] = []
    @Published var ignoreProErrorBadge = false

    var optimisedFilesByHash: [String: FilePath] = [:]

    @Published var doneCount = 0
    @Published var failedCount = 0
    @Published var visibleCount = 0

    var lastRemoveAfterMs: Int? = nil

    @Published var removedOptimisers: [Optimiser] = [] {
        didSet {
            if visibleOptimisers.isEmpty {
                current?.removeDebouncer()
                current = nil
            }
        }
    }

    @Published var visibleOptimisers: Set<Optimiser> = [] {
        didSet {
            if visibleOptimisers.isEmpty {
                hoveredOptimiserID = nil
                if removedOptimisers.isEmpty {
                    current?.removeDebouncer()
                    current = nil
                }
            }
            visibleCount = visibleOptimisers.count
            doneCount = visibleOptimisers.filter { !$0.running && $0.error == nil }.count
            failedCount = visibleOptimisers.filter { !$0.running && $0.error != nil }.count
            mainThread {
                SM.selectableCount = visibleOptimisers.filter { !$0.running }.count
            }
        }
    }

    var compactResults = false {
        didSet {
            guard compactResults != oldValue else {
                return
            }

            if compactResults {
                for o in optimisers where o.error == nil && o.notice == nil {
                    o.stopRemover()
                }
            }
        }
    }

    var remover: DispatchWorkItem? { didSet {
        oldValue?.cancel()
    }}
    var hovered: Optimiser? {
        guard let hoveredOptimiserID else { return nil }
        return opt(hoveredOptimiserID)
    }
    @Published var optimisers: Set<Optimiser> = [] {
        didSet {
            SHARING_MANAGER.isShowingPicker = false
            for o in optimisers {
                o.sharing = false
            }

            let removed = oldValue.subtracting(optimisers)
            let added = optimisers.subtracting(oldValue)
            if !removed.isEmpty {
                log.debug("Removed optimisers: \(removed)")
                for o in removed {
                    o.removeDebouncer()
                }
            }
            if !added.isEmpty {
                log.debug("Added optimisers: \(added)")
            }
            visibleOptimisers = optimisers.filter { !$0.hidden }
            if compactResults, visibleOptimisers.isEmpty, !Defaults[.alwaysShowCompactResults] {
                compactResults = false
            }
            updateProgress()
        }
    }
    var optimisersWithURLs: [Optimiser] {
        SM.selecting ? SM.optimisers.filter { $0.url != nil } : optimisers.filter { $0.url != nil }
    }

    var clipboardImageOptimiser: Optimiser? { optimisers.first(where: { $0.id.hasPrefix(Optimiser.IDs.clipboardImage) }) }

    var clipboardImageOptimisers: [Optimiser] {
        optimisers.filter { $0.id.hasPrefix(Optimiser.IDs.clipboardImage) && $0.url != nil && !$0.running }
    }

    func copyAllClipboardImagesToClipboard() {
        let optimisers = clipboardImageOptimisers
        guard optimisers.isNotEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()

        let items: [NSPasteboardItem] = optimisers.compactMap { opt in
            guard let url = opt.url else { return nil }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
            item.setString("true", forType: .optimisationStatus)
            return item
        }
        pb.writeObjects(items)
    }

    func updateProgress() {
        visibleCount = visibleOptimisers.count
        doneCount = visibleOptimisers.filter { !$0.running && $0.error == nil }.count
        failedCount = visibleOptimisers.filter { !$0.running && $0.error != nil }.count
        mainThread {
            SM.selectableCount = visibleOptimisers.filter { !$0.running }.count
        }
        let finishedCount = doneCount + failedCount

        guard finishedCount < visibleCount else {
            progress = nil
            return
        }

        progress = Progress(totalUnitCount: visibleCount.i64)
        progress!.completedUnitCount = finishedCount.i64
    }

    func clearVisibleOptimisers(stop: Bool = false) {
        remover = nil
        lastRemoveAfterMs = nil
        hoveredOptimiserID = nil

        for optimiser in optimisers {
            optimiser.editingFilename = false
        }
        if stop {
            for optimiser in optimisers.filter(\.running) {
                optimiser.stop(remove: false)
            }
            removedOptimisers = removedOptimisers
                .filter { o in !optimisers.contains(o) && !o.hidden && !o.isPreview }
                .with(optimisers.filter { !$0.hidden && !$0.isPreview })
            optimisers = optimisers.filter(\.hidden)
        } else {
            removedOptimisers = removedOptimisers
                .filter { o in !optimisers.contains(o) && !o.hidden && !o.isPreview }
                .with(optimisers.filter { !$0.running && !$0.hidden && !$0.isPreview })
            optimisers = optimisers.filter { $0.running || $0.hidden }
        }
    }

    func removeVisibleOptimisers(after ms: Int) {
        guard !SWIFTUI_PREVIEW, !SHARING_MANAGER.isShowingPicker, !SM.selecting else { return }
        lastRemoveAfterMs = ms
        remover = mainAsyncAfter(ms: ms) { [self] in
            guard hoveredOptimiserID == nil, !DM.dragging, !visibleOptimisers.contains(where: { $0.editingFilename || $0.sharing }), !SHARING_MANAGER.isShowingPicker, !SM.selecting else {
                self.resetRemover()
                return
            }

            self.clearVisibleOptimisers()
        }
    }

    func resetRemover() {
        guard remover != nil, let lastRemoveAfterMs else {
            return
        }

        removeVisibleOptimisers(after: lastRemoveAfterMs)
    }

    func optimiser(id: String, type: ItemType, operation: String, hidden: Bool = false, source: OptimisationSource? = nil, indeterminateProgress: Bool = false) -> Optimiser {
        let optimiser = (
            OM.optimisers.first(where: { $0.id == id }) ??
                (current?.id == id ? current : nil) ??
                Optimiser(id: id, type: type, operation: operation)
        )

        if indeterminateProgress {
            optimiser.progress = Progress()
        }
        optimiser.operation = operation
        optimiser.progress.localizedAdditionalDescription = ""
        optimiser.hidden = hidden
        optimiser.progress.completedUnitCount = 0
        optimiser.running = true
        optimiser.isOriginal = false

        if let source {
            optimiser.source = source
        }

        if !OM.optimisers.contains(optimiser) {
            OM.optimisers = OM.optimisers.with(optimiser)
        }
        if id.hasPrefix(Optimiser.IDs.clipboardImage) || id == Optimiser.IDs.clipboard {
            OM.current = optimiser
        }

        showFloatingThumbnails(force: true)
        return optimiser
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        optimisersWithURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let opt = optimisersWithURLs[safe: index] else {
            return nil
        }
        return (opt.url ?? opt.originalURL) as NSURL?
    }

    func quicklook(optimiser: Optimiser? = nil) {
        guard let ql = QLPreviewPanel.shared() else { return }

        focus()
        ql.makeKeyAndOrderFront(nil)
        ql.orderFrontRegardless()
        ql.dataSource = self
        if let optimiser {
            ql.currentPreviewItemIndex = optimisersWithURLs.firstIndex(of: optimiser) ?? 0
        } else {
            ql.currentPreviewItemIndex = 0
        }
        ql.reloadData()
    }

}

func tryAsync(_ action: @escaping () async throws -> Void, onError: (() async throws -> Void)? = nil) {
    Task.init {
        do {
            try await action()
        } catch {
            log.error("\(error.localizedDescription)")
        }
    }
}

func justTry(_ action: () throws -> Void) {
    do {
        try action()
    } catch {
        log.error("\(error.localizedDescription)")
    }
}

@MainActor let OM = OptimisationManager()

enum MediaEngineCores: Int {
    case base = 1
    case max = 2
    case ultra = 4

    static var current: MediaEngineCores {
        var size: size_t = 0
        var res = Darwin.sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)

        guard res == 0 else {
            return .base
        }

        var ret = [CChar](repeating: 0, count: size + 1)
        res = Darwin.sysctlbyname("machdep.cpu.brand_string", &ret, &size, nil, 0)

        guard let brand = res == 0 ? String(cString: ret) : nil else {
            return .base
        }
        return brand.contains("Ultra") ? .ultra : (brand.contains("Max") ? .max : .base)
    }
}

let optimisationQueue = DispatchQueue(label: "optimisation.queue")
let imageOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
let videoOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = MediaEngineCores.current.rawValue
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
let pdfOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = MediaEngineCores.current.rawValue
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
let audioOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = MediaEngineCores.current.rawValue
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
@MainActor var pdfOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var audioOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var videoOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var imageOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var imageResizeDebouncers: [String: DispatchWorkItem] = [:]
var scalingFactor = 1.0

@MainActor
var hideClipboardAfter: Int? {
    let hide = Defaults[.autoHideFloatingResults]
    let hideClipboardAfter = Defaults[.autoHideClipboardResultAfter]
    let hideFilesAfter = Defaults[.autoHideFloatingResultsAfter]
    return hide ? (hideClipboardAfter == -1 ? hideFilesAfter : hideClipboardAfter) * 1000 : nil
}

@MainActor
var hideFilesAfter: Int? {
    let hide = Defaults[.autoHideFloatingResults]
    let hideFilesAfter = Defaults[.autoHideFloatingResultsAfter]
    return hide ? hideFilesAfter * 1000 : nil
}

func fetchType(from url: URL, progressDelegate: URLSessionDataDelegate) async throws -> ItemType? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5.0)
    request.httpMethod = "HEAD"

    let (_, response) = try await URLSession.shared.data(for: request, delegate: progressDelegate)
    guard let response = response as? HTTPURLResponse,
          200 ..< 300 ~= response.statusCode,
          let mimeType = response.mimeType, !mimeType.isEmpty
    else {
        return nil
    }

    let type = ItemType.from(mimeType: mimeType)
    guard type.isImage || type.isVideo else {
        throw ClopError.downloadError("invalid content type: \(type)")
    }

    return type
}

extension ReversedCollection<Slice<ReversedCollection<String>>> {
    var s: String {
        String(map { $0 })
    }
}

@MainActor
func optimiseURL(
    _ url: URL,
    copyToClipboard: Bool = false,
    hideFloatingResult: Bool = false,
    downscaleTo scalingFactor: Double? = nil,
    cropTo cropSize: CropSize? = nil,
    changePlaybackSpeedBy changePlaybackSpeedFactor: Double? = nil,
    aggressiveOptimisation: Bool? = nil,
    adaptiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil,
    output: String? = nil,
    removeAudio: Bool? = nil
) async throws -> ClipboardType? {
    showFloatingThumbnails(force: true)

    var clipResult: ClipboardType?
    do {
        guard let (downloadPath, type, optimiser) = try await downloadFile(from: url, hideFloatingResult: hideFloatingResult, output: output) else {
            return nil
        }
        let downloadURL = downloadPath.url

        optimiser.operation = "Optimising" + (aggressiveOptimisation ?? false ? " (aggressive)" : "")
        optimiser.originalURL = downloadURL
        optimiser.url = downloadURL
        optimiser.type = type
        if let source {
            optimiser.source = source
        }

        switch type {
        case .image:
            guard let img = Image(path: downloadPath, retinaDownscaled: optimiser.retinaDownscaled) else {
                throw ClopError.downloadError("invalid image")
            }
            clipResult = .image(img)

            let imgActions: [PipelineAction] = if let cropSize, cropSize.cg < img.size {
                [.downscale(factor: nil, cropSize: cropSize)]
            } else if let scalingFactor, scalingFactor < 1 {
                [.downscale(factor: scalingFactor, cropSize: nil)]
            } else {
                [.optimise]
            }
            let result: Image? = try await runImagePipeline(
                img, actions: imgActions,
                id: optimiser.id,
                copyToClipboard: copyToClipboard,
                allowTiff: true,
                hideFloatingResult: hideFloatingResult,
                aggressiveOptimisation: aggressiveOptimisation,
                adaptiveOptimisation: adaptiveOptimisation,
                source: source
            )

            if let result {
                clipResult = .image(result)
            }
        case .video:
            clipResult = .file(downloadPath)

            let vidActions: [PipelineAction] = buildPipeline(
                scalingFactor: scalingFactor,
                cropSize: cropSize,
                changePlaybackSpeedFactor: changePlaybackSpeedFactor,
                removeAudio: removeAudio
            )
            let result: Video? = if let cropSize, let video = try await Video.byFetchingMetadata(path: downloadPath, thumb: !hideFloatingResult, id: optimiser.id), let size = video.size {
                if cropSize < size {
                    try await runVideoPipeline(video, actions: vidActions, id: optimiser.id, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
                } else {
                    throw ClopError.alreadyResized(downloadPath)
                }
            } else if let scalingFactor, scalingFactor < 1, let video = try await Video.byFetchingMetadata(path: downloadPath, thumb: !hideFloatingResult, id: optimiser.id) {
                try await runVideoPipeline(video, actions: vidActions, id: optimiser.id, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            } else if let changePlaybackSpeedFactor, changePlaybackSpeedFactor < 1, let video = try await Video.byFetchingMetadata(path: downloadPath, thumb: !hideFloatingResult, id: optimiser.id) {
                try await runVideoPipeline(video, actions: vidActions, id: optimiser.id, copyToClipboard: copyToClipboard, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            } else {
                try await runVideoPipeline(
                    Video(path: downloadPath, thumb: !hideFloatingResult, id: optimiser.id),
                    actions: vidActions,
                    id: optimiser.id,
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: aggressiveOptimisation,
                    source: source
                )
            }

            if let result {
                clipResult = .file(result.path)
            }
        case .pdf:
            clipResult = .file(downloadPath)

            var pdfActions: [PipelineAction] = [.optimise]
            if let cropSize { pdfActions.append(.downscale(factor: nil, cropSize: cropSize)) }
            let result: PDF? = try await runPDFPipeline(
                PDF(downloadPath, thumb: !hideFloatingResult, id: optimiser.id),
                actions: pdfActions,
                id: optimiser.id,
                hideFloatingResult: hideFloatingResult,
                aggressiveOptimisation: aggressiveOptimisation,
                source: source
            )

            if let result {
                clipResult = .file(result.path)
            }
        default:
            return nil
        }

        // Run user-configured pipelines after optimisation
        if let source, let optimiser = opt(url.absoluteString) {
            let resultPath = clipResult?.path ?? downloadPath
            await runPipelinesAfterOptimisation(file: resultPath, type: type, source: source, optimiser: optimiser)
        }
    } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
        opt(url.absoluteString)?.info = "File already fully compressed"
        return clipResult
    } catch let error as ClopError {
        opt(url.absoluteString)?.finish(error: error.humanDescription)
        throw error
    } catch {
        opt(url.absoluteString)?.finish(error: error.localizedDescription)
        throw error
    }

    return clipResult
}

@MainActor func opt(_ optimiserID: String) -> Optimiser? {
    OM.optimisers.first(where: { $0.id == optimiserID })
}

let BASE64_PREFIX = #/(url\()?data:image/[^;]+;base64,/#

enum ClipboardType: Equatable {
    case image(Image)
    case file(FilePath)
    case url(URL)
    case unknown

    var isImage: Bool {
        switch self {
        case .image: true
        case let .file(path): path.isImage
        case let .url(url): url.isImage
        default: false
        }
    }

    var isVideo: Bool {
        switch self {
        case let .file(path): path.isVideo
        case let .url(url): url.isVideo
        default: false
        }
    }

    var isPDF: Bool {
        switch self {
        case let .file(path): path.isPDF
        case let .url(url): url.isPDF
        default: false
        }
    }

    var isAudio: Bool {
        switch self {
        case let .file(path): path.isAudio
        case let .url(url): url.isAudio
        default: false
        }
    }

    var id: String {
        switch self {
        case let .image(img): img.path.string
        case let .file(path): path.string
        case let .url(url): url.path
        case .unknown: ""
        }
    }

    var path: FilePath {
        switch self {
        case let .image(img): img.path
        case let .file(path): path
        case let .url(url): FilePath.downloads / url.lastPathComponent.safeFilename
        case .unknown: ""
        }
    }

    static func == (lhs: ClipboardType, rhs: ClipboardType) -> Bool {
        lhs.id == rhs.id
    }

    static func fromURL(_ url: URL) -> ClipboardType {
        if url.isFileURL {
            return .file(url.filePath!)
        }

        return .url(url)
    }

    static func fromString(_ str: String) -> ClipboardType {
        if let data = Data(base64Encoded: str.replacing(BASE64_PREFIX, with: "").trimmedPath), let img = Image(data: data, retinaDownscaled: false) {
            return .image(img)
        }

        let str = str.trimmedPath
        let path = str.starts(with: "file:") ? str.url?.filePath : str.existingFilePath
        if let path {
            return .file(path)
        }

        if str.contains(":"), let url = str.url {
            return .url(url)
        }

        return .unknown
    }

    static func lastItem() -> ClipboardType {
        guard let item = NSPasteboard.general.pasteboardItems?.first else {
            return .unknown
        }
        return fromPasteboardItem(item)
    }

    static func fromPasteboardItem(_ item: NSPasteboardItem) -> ClipboardType {
        if let path = item.string(forType: .fileURL)?.trimmedPath.url?.filePath ?? item.string(forType: .string)?.trimmedPath.existingFilePath {
            if path.isPDF || path.isVideo || path.isAudio {
                return .file(path)
            }
            if path.isImage, let img = Image(path: path, retinaDownscaled: false) {
                return .image(img)
            }
        }

        if let img = try? Image.fromPasteboard(item: item, anyType: true) {
            return .image(img)
        }

        if let str = item.string(forType: .string), let data = Data(base64Encoded: str.replacing(BASE64_PREFIX, with: "").trimmedPath), let img = Image(data: data, retinaDownscaled: false) {
            return .image(img)
        }

        if let path = item.string(forType: .fileURL)?.trimmedPath.url?.filePath ?? item.string(forType: .string)?.trimmedPath.existingFilePath {
            return .file(path)
        }

        if let url = item.string(forType: .URL)?.url ?? item.string(forType: .string)?.url {
            return .url(url)
        }

        return .unknown
    }
}

import LowtechPro

@discardableResult @inline(__always)
@MainActor func proGuard<T>(count: inout Int, limit: Int = 5, url: URL? = nil, _ action: @escaping () async throws -> T) async throws -> T {
    guard !BM.decompressingBinaries else { throw ClopError.decompressingBinariesError }
    guard proactive || count < limit, meetsInternalRequirements() else {
        if let url {
            OM.skippedBecauseNotPro = OM.skippedBecauseNotPro.with(url)
        }
        proLimitsReached(url: url)
        throw ClopError.proError("Pro limits reached")
    }
    let result = try await action()
    count += 1
    return result
}

var manualOptimisationCount = 0

@MainActor func downloadFile(from url: URL, optimiser: Optimiser? = nil, hideFloatingResult: Bool = false, output: String? = nil) async throws -> (FilePath, ItemType, Optimiser)? {
    var optimiser: Optimiser?
    if optimiser == nil {
        optimiser = OM.optimiser(id: url.absoluteString, type: .url, operation: "Fetching", hidden: hideFloatingResult)
        optimiser!.url = url
    }
    guard let optimiser else { return nil }

    let progressDelegate = OptimiserProgressDelegate(optimiser: optimiser)
    var type = try await fetchType(from: url, progressDelegate: progressDelegate)

    optimiser.operation = "Downloading"
    let fileURL = try await url.download(type: type?.utType, delegate: progressDelegate)
    optimiser.progress.unpublish()

    type = type ?? ItemType.from(filePath: fileURL.filePath!)
    guard let type, type.isImage || type.isVideo, let ext = type.ext else {
        throw ClopError.downloadError("invalid file type")
    }
    guard optimiser.running, !optimiser.inRemoval else {
        return nil
    }

    let name: String = url.lastPathComponent.reversed().split(separator: ".", maxSplits: 1).last?.reversed().s ??
        url.lastPathComponent.replacingOccurrences(of: ".\(ext)", with: "", options: .caseInsensitive)
    let downloadPath = FilePath.downloads.appending("\(name).\(ext)")

    let outFilePath: FilePath =
        if let path = output?.filePath, path.string.contains("/") {
            path.isDir ? path / "\(name).\(ext)" : path.dir / generateFileName(template: path.name.string, for: downloadPath, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber])
        } else if let output {
            downloadPath.dir / generateFileName(template: output, for: downloadPath, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber])
        } else {
            downloadPath
        }
    guard let path = fileURL.existingFilePath else {
        throw ClopError.downloadError("file not found at \(fileURL.path)")
    }
    guard outFilePath.dir.mkdir(withIntermediateDirectories: true) else {
        throw ClopError.downloadError("could not create directory \(outFilePath.dir.string)")
    }
    try path.move(to: outFilePath, force: true)

    guard optimiser.running, !optimiser.inRemoval else {
        return nil
    }
    return (outFilePath, type, optimiser)
}

@MainActor func quickLookLastClipboardItem() async throws {
    let item = ClipboardType.lastItem()

    switch item {
    case let .image(image):
        QuickLooker.quicklook(url: image.path.url)
    case let .file(filePath):
        QuickLooker.quicklook(url: filePath.url)
    case let .url(url):
        guard let (downloadPath, _, optimiser) = try await downloadFile(from: url) else {
            return
        }
        optimiser.stop()

        QuickLooker.quicklook(url: downloadPath.url)
    case .unknown:
        throw ClopError.unknownType
    }
}

@MainActor func optimiseLastClipboardItem(hideFloatingResult: Bool = false, downscaleTo scalingFactor: Double? = nil, changePlaybackSpeedBy changePlaybackSpeedFactor: Double? = nil, aggressiveOptimisation: Bool? = nil) async throws {
    let item = ClipboardType.lastItem()
    try await optimiseItem(
        item,
        id: Optimiser.IDs.clipboard,
        hideFloatingResult: hideFloatingResult,
        downscaleTo: scalingFactor,
        changePlaybackSpeedBy: changePlaybackSpeedFactor,
        aggressiveOptimisation: aggressiveOptimisation,
        optimisationCount: &manualOptimisationCount,
        copyToClipboard: true,
        source: .clipboard
    )
}

@MainActor func showNotice(_ notice: String) {
    let optimiser = OM.optimiser(id: "notice", type: .unknown, operation: "")
    optimiser.finish(notice: notice)
}

var THUMBNAIL_URLS: ThreadSafeDictionary<URL, URL> = .init()

func getTemplatedPath(type: ClopFileType, path: FilePath, optimisedFileBehaviour: OptimisedFileBehaviour? = nil) throws -> FilePath? {
    switch optimisedFileBehaviour ?? type.optimisedFileBehaviour {
    case .temporary:
        path.tempFile(addUniqueID: true)
    case .inPlace:
        path
    case .sameFolder:
        path.dir / generateFileName(template: Defaults[type.sameFolderNameTemplateKey], for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber])
    case .specificFolder:
        try generateFilePath(template: Defaults[type.specificFolderNameTemplateKey], for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber], mkdir: true)
    }
}

@discardableResult
@MainActor func optimiseItem(
    _ item: ClipboardType,
    id: String,
    hideFloatingResult: Bool = false,
    downscaleTo scalingFactor: Double? = nil,
    cropTo cropSize: CropSize? = nil,
    changePlaybackSpeedBy changePlaybackSpeedFactor: Double? = nil,
    aggressiveOptimisation: Bool? = nil,
    adaptiveOptimisation: Bool? = nil,
    optimisationCount: inout Int,
    copyToClipboard: Bool,
    source: OptimisationSource? = nil,
    output: String? = nil,
    removeAudio: Bool? = nil,
    optimisedFileBehaviour: OptimisedFileBehaviour? = nil,
    skipPipelineLookup: Bool = false
) async throws -> ClipboardType? {
    func nope(notice: String, thumbnail: NSImage? = nil, url: URL? = nil, type: ItemType? = nil) {
        let optimiser = OM.optimiser(id: id, type: type ?? .unknown, operation: "", hidden: hideFloatingResult)
        if let thumbnail {
            optimiser.thumbnail = thumbnail
        }
        if let url {
            optimiser.url = url
        }
        optimiser.finish(notice: notice)
    }

    do {
        var outFilePath: FilePath?
        let output = output?
            .replacingOccurrences(of: "%s", with: factorStr(scalingFactor))
            .replacingOccurrences(of: "%z", with: cropSizeStr(cropSize))
            .replacingOccurrences(of: "%x", with: factorStr(changePlaybackSpeedFactor))
        if let output {
            do {
                outFilePath = try generateFilePath(template: output, for: item.path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber], mkdir: true)
            } catch {
                nope(notice: error.localizedDescription)
                return nil
            }
        }

        let item: ClipboardType =
            if let outFilePath, item.path.exists, case let .image(img) = item {
                try .image(img.copyWithPath(item.path.copy(to: outFilePath, force: true)))
            } else if let outFilePath, item.path.exists {
                try .file(item.path.copy(to: outFilePath, force: true))
            } else {
                item
            }

        switch item {
        case var .image(img):
            if outFilePath == nil, let newPath = try getTemplatedPath(type: .image, path: img.path, optimisedFileBehaviour: optimisedFileBehaviour), newPath != img.path {
                img = try img.copyWithPath(img.path.copy(to: newPath, force: true))
            }

            let imgActions: [PipelineAction] = if let cropSize {
                [.downscale(factor: nil, cropSize: cropSize)]
            } else if let scalingFactor, scalingFactor < 1 {
                [.downscale(factor: scalingFactor, cropSize: nil)]
            } else {
                [.optimise]
            }

            let result: Image? = try await proGuard(count: &optimisationCount, limit: 5, url: img.path.url) {
                if let cropSize {
                    guard cropSize < img.size else { throw ClopError.alreadyResized(img.path) }
                }
                return try await runImagePipeline(
                    img, actions: imgActions,
                    id: id,
                    copyToClipboard: copyToClipboard,
                    allowTiff: true,
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: aggressiveOptimisation,
                    adaptiveOptimisation: adaptiveOptimisation,
                    source: source
                )
            }
            guard let result else { return nil }
            if !skipPipelineLookup, let source, let optimiser = opt(id) {
                await runPipelinesAfterOptimisation(file: result.path, type: .image(result.type), source: source, optimiser: optimiser)
            }
            return .image(result)
        case var .file(path):
            if path.isImage, var img = Image(path: path, retinaDownscaled: false) {
                guard aggressiveOptimisation == true || scalingFactor != nil || cropSize != nil || !path.hasOptimisationStatusXattr() else {
                    let optimiser = OM.optimiser(id: id, type: .image(img.type), operation: "", hidden: hideFloatingResult, source: source)
                    optimiser.url = path.url
                    optimiser.image = img
                    let fileSize = path.fileSize() ?? 0
                    optimiser.finish(oldBytes: fileSize, newBytes: fileSize, oldSize: img.size)
                    if skipPipelineLookup { return .file(path) }
                    throw ClopError.alreadyOptimised(path)
                }

                if outFilePath == nil, let newPath = try getTemplatedPath(type: .image, path: img.path, optimisedFileBehaviour: optimisedFileBehaviour), newPath != img.path {
                    path = try path.copy(to: newPath, force: true)
                    img = img.copyWithPath(path)
                }

                let fileImgActions: [PipelineAction] = if let cropSize {
                    [.downscale(factor: nil, cropSize: cropSize)]
                } else if let scalingFactor, scalingFactor < 1 {
                    [.downscale(factor: scalingFactor, cropSize: nil)]
                } else {
                    [.optimise]
                }

                let result: Image? = try await proGuard(count: &optimisationCount, limit: 5, url: path.url) {
                    if let cropSize {
                        guard cropSize < img.size else { throw ClopError.alreadyResized(img.path) }
                    }
                    return try await runImagePipeline(
                        img, actions: fileImgActions,
                        id: id,
                        copyToClipboard: copyToClipboard,
                        allowTiff: true,
                        hideFloatingResult: hideFloatingResult,
                        aggressiveOptimisation: aggressiveOptimisation,
                        adaptiveOptimisation: adaptiveOptimisation,
                        source: source
                    )
                }
                guard let result else { return nil }
                if !skipPipelineLookup, let source, let optimiser = opt(id) {
                    await runPipelinesAfterOptimisation(file: result.path, type: .image(result.type), source: source, optimiser: optimiser)
                }
                return .image(result)
            } else if path.isVideo {
                guard aggressiveOptimisation == true || changePlaybackSpeedFactor != nil || scalingFactor != nil || cropSize != nil || !path.hasOptimisationStatusXattr() else {
                    let optimiser = OM.optimiser(id: id, type: .video(path.url.utType() ?? .mpeg4Movie), operation: "", hidden: hideFloatingResult, source: source)
                    optimiser.url = path.url

                    if let video = try await Video.byFetchingMetadata(path: path, thumb: !hideFloatingResult) {
                        optimiser.video = video
                        optimiser.finish(oldBytes: video.fileSize, newBytes: video.fileSize, oldSize: video.size)
                    } else {
                        let fileSize = path.fileSize() ?? 0
                        optimiser.finish(oldBytes: fileSize, newBytes: fileSize, oldSize: nil)
                    }
                    if skipPipelineLookup { return .file(path) }
                    throw ClopError.alreadyOptimised(path)
                }

                let willConvert = Defaults[.formatsToConvertToMP4].contains(path.url.utType() ?? .mpeg4Movie)
                if !willConvert, outFilePath == nil, let newPath = try getTemplatedPath(type: .video, path: path, optimisedFileBehaviour: optimisedFileBehaviour), newPath != path {
                    path = try path.copy(to: newPath, force: true)
                }

                let fileVidActions = buildPipeline(
                    scalingFactor: scalingFactor,
                    cropSize: cropSize,
                    changePlaybackSpeedFactor: changePlaybackSpeedFactor,
                    removeAudio: removeAudio
                )

                let result: Video? = try await proGuard(count: &optimisationCount, limit: 5, url: path.url) {
                    let video = await (try? Video.byFetchingMetadata(path: path, thumb: !hideFloatingResult)) ?? Video(path: path, thumb: !hideFloatingResult)

                    if let cropSize, let size = video.size {
                        guard cropSize < size else { throw ClopError.alreadyResized(path) }
                    }

                    return try await runVideoPipeline(
                        video, actions: fileVidActions,
                        id: id,
                        copyToClipboard: copyToClipboard,
                        hideFloatingResult: hideFloatingResult,
                        aggressiveOptimisation: aggressiveOptimisation,
                        source: source
                    )
                }
                guard let result else { return nil }
                if !skipPipelineLookup, let source, let optimiser = opt(id) {
                    await runPipelinesAfterOptimisation(file: result.path, type: .video(UTType.from(filePath: result.path) ?? .mpeg4Movie), source: source, optimiser: optimiser)
                }
                return .file(result.path)
            } else if path.isPDF {
                guard aggressiveOptimisation == true || cropSize != nil || !path.hasOptimisationStatusXattr() else {
                    let optimiser = OM.optimiser(id: id, type: .pdf, operation: "", hidden: hideFloatingResult, source: source)
                    optimiser.url = path.url
                    let pdf = PDF(path, thumb: !hideFloatingResult)
                    optimiser.pdf = pdf
                    optimiser.finish(oldBytes: pdf.fileSize, newBytes: pdf.fileSize, oldSize: pdf.size)

                    if skipPipelineLookup { return .file(path) }
                    throw ClopError.alreadyOptimised(path)
                }

                if outFilePath == nil, let newPath = try getTemplatedPath(type: .pdf, path: path, optimisedFileBehaviour: optimisedFileBehaviour), newPath != path {
                    path = try path.copy(to: newPath, force: true)
                }

                var filePdfActions: [PipelineAction] = [.optimise]
                if let cropSize { filePdfActions.append(.downscale(factor: nil, cropSize: cropSize)) }

                let result = try await proGuard(count: &optimisationCount, limit: 5, url: path.url) {
                    let pdf = PDF(path, thumb: !hideFloatingResult)
                    guard let doc = pdf.document else { throw ClopError.invalidPDF(path) }
                    guard !doc.isEncrypted else { throw ClopError.encryptedPDF(path) }

                    return try await runPDFPipeline(
                        pdf, actions: filePdfActions,
                        id: id,
                        copyToClipboard: copyToClipboard,
                        hideFloatingResult: hideFloatingResult,
                        aggressiveOptimisation: aggressiveOptimisation,
                        source: source
                    )
                }
                guard let result else { return nil }
                if !skipPipelineLookup, let source, let optimiser = opt(id) {
                    await runPipelinesAfterOptimisation(file: result.path, type: .pdf, source: source, optimiser: optimiser)
                }
                return .file(result.path)
            } else if path.isAudio {
                guard !path.hasOptimisationStatusXattr() else {
                    let audioType = path.url.utType() ?? .mp3
                    let optimiser = OM.optimiser(id: id, type: .audio(audioType), operation: "", hidden: hideFloatingResult, source: source)
                    optimiser.url = path.url
                    let audio = Audio(path: path, thumb: !hideFloatingResult)
                    optimiser.audio = audio
                    optimiser.finish(oldBytes: audio.fileSize, newBytes: audio.fileSize)
                    if skipPipelineLookup { return .file(path) }
                    throw ClopError.alreadyOptimised(path)
                }

                let result: Audio? = try await proGuard(count: &optimisationCount, limit: 5, url: path.url) {
                    let audio = await (try? Audio.byFetchingMetadata(path: path, thumb: !hideFloatingResult)) ?? Audio(path: path, thumb: !hideFloatingResult)
                    return try await runAudioPipeline(
                        audio,
                        actions: [.optimise],
                        id: id,
                        copyToClipboard: copyToClipboard,
                        hideFloatingResult: hideFloatingResult,
                        source: source
                    )
                }
                guard let result else { return nil }
                if !skipPipelineLookup, let source, let optimiser = opt(id) {
                    await runPipelinesAfterOptimisation(file: result.path, type: .audio(path.url.utType() ?? .mp3), source: source, optimiser: optimiser)
                }
                return .file(result.path)
            } else {
                nope(notice: "Clipboard contents can't be optimised")
                throw ClopError.unknownType
            }
        case let .url(url):
            let result = try await proGuard(count: &optimisationCount, limit: 5, url: url) {
                try await optimiseURL(
                    url,
                    copyToClipboard: copyToClipboard,
                    hideFloatingResult: hideFloatingResult,
                    downscaleTo: scalingFactor,
                    cropTo: cropSize,
                    changePlaybackSpeedBy: changePlaybackSpeedFactor,
                    aggressiveOptimisation: aggressiveOptimisation,
                    adaptiveOptimisation: adaptiveOptimisation,
                    source: source,
                    output: output,
                    removeAudio: removeAudio
                )
            }
            return result
        default:
            nope(notice: "Clipboard contents can't be optimised")
            throw ClopError.unknownType
        }
    } catch {
        if let opt = opt(id), opt.running {
            await MainActor.run { opt.finish(error: error.localizedDescription) }
        }
        throw error
    }
}

@MainActor func showFloatingThumbnails(force: Bool = false) {
    guard Defaults[.enableFloatingResults], !floatingResultsWindow.isVisible || force else {
        return
    }

    floatingResultsWindow.show(closeAfter: 0, fadeAfter: 0, fadeDuration: 0.2, corner: Defaults[.floatingResultsCorner], margin: FLOAT_MARGIN, marginHorizontal: 0)
}

@MainActor func showFloatingThumbnailsAtCursor() {
    let mouseLocation = NSEvent.mouseLocation

    // Pre-position the window at the cursor before showing to avoid flicker.
    // Use the content fitting size if available, otherwise fall back to a reasonable default.
    let size = cursorDropZoneWindow.contentView?.fittingSize ?? CGSize(width: 180, height: 120)
    let origin = NSPoint(
        x: mouseLocation.x - size.width / 2,
        y: mouseLocation.y - size.height
    )
    cursorDropZoneWindow.setFrame(NSRect(origin: origin, size: size), display: false)
    cursorDropZoneWindow.show(at: origin, closeAfter: 0, fadeAfter: 0, fadeDuration: 0.2, centerWindow: false)
}

@MainActor func hideCursorDropZone() {
    guard cursorDropZoneWindow.isVisible else { return }
    cursorDropZoneWindow.close()
}

var cliOptimisationCount = 0

func processOptimisationRequest(_ req: OptimisationRequest) async throws -> [OptimisationResponse] {
    try await withThrowingTaskGroup(of: OptimisationResponse.self, returning: [OptimisationResponse].self) { group in
        THUMBNAIL_URLS.accessQueue.sync {
            THUMBNAIL_URLS = ThreadSafeDictionary(dict: req.originalUrls)
        }
        for url in req.urls {
            let added = group.addTaskUnlessCancelled {
                let clip = ClipboardType.fromURL(url)

                do {
                    let result: ClipboardType?
                    do {
                        result = try await optimiseItem(
                            clip,
                            id: url.absoluteString,
                            hideFloatingResult: req.hideFloatingResult,
                            downscaleTo: req.downscaleFactor,
                            cropTo: req.size,
                            changePlaybackSpeedBy: req.changePlaybackSpeedFactor,
                            aggressiveOptimisation: req.aggressiveOptimisation,
                            adaptiveOptimisation: req.adaptiveOptimisation,
                            optimisationCount: &cliOptimisationCount,
                            copyToClipboard: req.copyToClipboard,
                            source: req.source.optSource,
                            output: req.output,
                            removeAudio: req.removeAudio,
                            optimisedFileBehaviour: .inPlace
                        )

                        if let origURL = req.originalUrls[url] {
                            await MainActor.run { opt(url.absoluteString)?.url = origURL }
                        }
                    } catch let ClopError.alreadyOptimised(path) {
                        guard path.exists else {
                            throw ClopError.fileNotFound(path)
                        }
                        let size = path.fileSize() ?? 0
                        return OptimisationResponse(path: path.string, forURL: url, oldBytes: size, newBytes: size)
                    }

                    guard let result, let opt = await opt(url.absoluteString) else {
                        throw ClopError.optimisationFailed(url.shellString)
                    }

                    var respPath = switch result {
                    case let .file(path):
                        path.string
                    case let .image(img):
                        img.path.string
                    default:
                        throw ClopError.optimisationFailed(url.shellString)
                    }

                    if req.output == nil, let optURL = respPath.fileURL, optURL != url, optURL.deletingLastPathComponent() != url.deletingLastPathComponent() {
                        let newURL = url.deletingLastPathComponent().appendingPathComponent(optURL.lastPathComponent)
                        if fm.fileExists(atPath: newURL.path) {
                            try fm.removeItem(at: newURL)
                        }
                        try fm.copyItem(at: optURL, to: newURL)
                        await MainActor.run { opt.url = newURL }
                        respPath = newURL.path
                    }

                    return await OptimisationResponse(
                        path: respPath, forURL: url,
                        convertedFrom: opt.convertedFromURL?.filePath?.string,
                        oldBytes: opt.oldBytes ?! url.existingFilePath?.fileSize() ?? 0, newBytes: opt.newBytes,
                        oldWidthHeight: opt.oldSize, newWidthHeight: opt.newSize
                    )
                } catch let error as ClopError {
                    if let opt = await opt(url.absoluteString), await opt.running {
                        await MainActor.run { opt.finish(error: error.localizedDescription) }
                    }
                    throw BatchOptimisationError.wrappedClopError(error, url)
                } catch {
                    if let opt = await opt(url.absoluteString), await opt.running {
                        await MainActor.run { opt.finish(error: error.localizedDescription) }
                    }
                    throw BatchOptimisationError.wrappedError(error, url)
                }
            }
            guard added else { break }
        }

        var responses = [OptimisationResponse]()
        while !group.isEmpty {
            do {
                guard let resp = try await group.next() else {
                    continue
                }
                responses.append(resp)
                if req.source == "cli" {
                    try? OPTIMISATION_CLI_RESPONSE_PORT.sendAndForget(data: resp.jsonData)
                } else {
                    try? OPTIMISATION_RESPONSE_PORT.sendAndForget(data: resp.jsonData)
                }
            } catch is CancellationError {
                log.error("BatchOptimisation cancelled")
                continue
            } catch let BatchOptimisationError.wrappedClopError(error, url) {
                if req.source == "cli" {
                    try? OPTIMISATION_CLI_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.description, forURL: url).jsonData)
                } else {
                    try? OPTIMISATION_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.description, forURL: url).jsonData)
                }
                log.error("BatchOptimisation ClopError \(error.description) for \(url)")
            } catch let BatchOptimisationError.wrappedError(error, url) {
                if req.source == "cli" {
                    try? OPTIMISATION_CLI_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.localizedDescription, forURL: url).jsonData)
                } else {
                    try? OPTIMISATION_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.localizedDescription, forURL: url).jsonData)
                }
                log.error("BatchOptimisation Error \(error.localizedDescription) for \(url)")
            }
        }

        return responses
    }
}

enum BatchOptimisationError: Error {
    case wrappedError(Error, URL)
    case wrappedClopError(ClopError, URL)
}

let OPTIMISATION_PORT = LocalMachPort(portLocation: OPTIMISATION_PORT_ID)
let OPTIMISATION_STOP_PORT = LocalMachPort(portLocation: OPTIMISATION_STOP_PORT_ID)
let OPTIMISATION_RESPONSE_PORT = LocalMachPort(portLocation: OPTIMISATION_RESPONSE_PORT_ID)
let OPTIMISATION_CLI_RESPONSE_PORT = LocalMachPort(portLocation: OPTIMISATION_CLI_RESPONSE_PORT_ID)

extension FilePath {
    func isValid() async throws -> Bool {
        if isVideo {
            return try await isVideoValid(path: self)
        }
        if isImage {
            return isImageValid(path: self)
        }
        if isPDF {
            return isPDFValid(path: self)
        }

        return true
    }
}
