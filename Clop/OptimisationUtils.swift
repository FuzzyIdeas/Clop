//
//  OptimisationUtils.swift
//  Clop
//
//  Created by Alin Panaitiu on 12.07.2023.
//

import Defaults
import Foundation
import Lowtech
import QuickLookUI
import SwiftUI
import System

enum ItemType {
    case image(UTType)
    case video(UTType)
    case pdf
    case url
    case unknown

    var ext: String? {
        switch self {
        case let .image(uTType):
            uTType.preferredFilenameExtension
        case let .video(uTType):
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
        case .pdf:
            .pdf
        case .url:
            nil
        case .unknown:
            nil
        }
    }

    var shortcutKey: Defaults.Key<[String: Shortcut]>? {
        switch self {
        case let .image:
            .shortcutToRunOnImage
        case let .video:
            .shortcutToRunOnVideo
        case .pdf:
            .shortcutToRunOnPdf
        case .url:
            nil
        case .unknown:
            nil
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType? {
        switch self {
        case let .image(utType):
            utType.pasteboardType
        case let .video(utType):
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
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/x-mpeg":
            return .video(UTType(mimeType: fileType)!)
        case "application/pdf":
            return .pdf
        case "text/html":
            return .url
        default:
            return .unknown
        }
    }
}

var hoveredOptimiserID: String? {
    didSet {
        mainAsync {
            guard hoveredOptimiserID != oldValue else {
                return
            }
            guard hoveredOptimiserID != nil else {
                KM.secondaryKeys = []
                KM.reinitHotkeys()
                return
            }

            KM.secondaryKeys = DEFAULT_HOVER_KEYS
            KM.reinitHotkeys()
        }
    }
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

// MARK: - Optimiser

@MainActor
final class Optimiser: ObservableObject, Identifiable, Hashable, Equatable, CustomStringConvertible {
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

    @Published var hidden = false
    @Published var isOriginal = false
    @Published var progress = Progress()

    @Published var oldBytes = 0
    @Published var newBytes = 0

    @Published var oldSize: CGSize? = nil
    @Published var newSize: CGSize? = nil

    @Published var error: String? = nil
    @Published var notice: String? = nil
    @Published var thumbnail: NSImage?
    @Published var originalURL: URL?
    @Published var startingURL: URL?
    @Published var convertedFromURL: URL?

    @Published var downscaleFactor = 1.0
    @Published var speedUpFactor = 1.0
    @Published var aggresive = false

    lazy var path: FilePath? = {
        if let url { return FilePath(url) }
        return id == IDs.clipboardImage ? nil : FilePath(stringLiteral: id)
    }()
    lazy var filename: String =
        id == IDs.clipboardImage ? id : (url?.lastPathComponent ?? FilePath(stringLiteral: id).name.string)

    var lastRemoveAfterMs: Int? = nil

    @Published var inRemoval = false

    @Atomic var retinaDownscaled = false

    var source: String?

    @Published var editingFilename = false {
        didSet {
            guard editingFilename != oldValue else {
                return
            }

            if editingFilename {
                KM.secondaryKeys = []
                KM.reinitHotkeys()
            } else if hoveredOptimiserID != nil {
                KM.secondaryKeys = DEFAULT_HOVER_KEYS
                KM.reinitHotkeys()
            }

            if let lastRemoveAfterMs, lastRemoveAfterMs < 1000 * 120 {
                self.lastRemoveAfterMs = 1000 * 120
                resetRemover()
            }
        }
    }
    @Published var hotkeyMessage = "" {
        didSet {
            guard !SWIFTUI_PREVIEW, hotkeyMessage.isNotEmpty else { return }
            hotkeyMessageResetter = mainAsyncAfter(ms: 1000) { [weak self] in
                self?.hotkeyMessage = ""
            }
        }
    }
    var hotkeyMessageResetter: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    @Published var running = true {
        didSet {
            if running, !oldValue {
                remover = nil
                inRemoval = false
                lastRemoveAfterMs = nil
            }
        }
    }
    @Published var url: URL? {
        didSet {
            log.debug("URL set to \(url?.path ?? "nil") from \(oldValue?.path ?? "nil")")
            if startingURL == nil {
                startingURL = url
            }
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

    func canSpeedUp() -> Bool {
        type.isVideo && !inRemoval
    }

    func speedUp(byFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) {
        guard !inRemoval, !SWIFTUI_PREVIEW else { return }

        remover = nil
        isOriginal = false
        error = nil
        notice = nil

        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggresive = aggressiveOptimisation
        } else if aggresive {
            shouldUseAggressiveOptimisation = true
        }

        guard let path = originalURL?.filePath ?? path else {
            return
        }
        let originalPath = (path.backupPath?.exists ?? false) ? path.backupPath : nil
        if !path.exists, let originalPath {
            let _ = try? originalPath.copy(to: path)
        }

        Task.init {
            guard let video = try await Video.byFetchingMetadata(path: path, fileSize: oldBytes, id: self.id) else {
                return
            }

            if let factor {
                speedUpFactor = factor
            }

            let _ = try? await speedUpVideo(
                video,
                originalPath: originalPath,
                id: self.id, byFactor: factor, hideFloatingResult: hideFloatingResult,
                aggressiveOptimisation: shouldUseAggressiveOptimisation
            )
        }
    }

    func downscale(toFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) {
        guard !inRemoval else { return }

        remover = nil
        isOriginal = false
        error = nil
        notice = nil

        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggresive = aggressiveOptimisation
        } else if aggresive {
            shouldUseAggressiveOptimisation = true
        }

        guard let path = originalURL?.filePath ?? path else {
            return
        }
        let originalPath = (path.backupPath?.exists ?? false) ? path.backupPath : nil
        if !path.exists, let originalPath {
            let _ = try? originalPath.copy(to: path)
        }

        Task.init {
            if type.isImage, let image = Image(path: path, retinaDownscaled: self.retinaDownscaled) {
                if thumbnail == nil {
                    thumbnail = image.image
                }
                if let factor {
                    downscaleFactor = factor
                }
                let _ = try? await downscaleImage(
                    image, toFactor: factor, saveTo: self.path,
                    copyToClipboard: id == IDs.clipboardImage, id: self.id,
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: shouldUseAggressiveOptimisation
                )
            }
            if type.isVideo {
                guard let video = try await (
                    oldSize == nil
                        ? Video.byFetchingMetadata(path: path, fileSize: oldBytes, id: self.id)
                        : Video(path: path, metadata: VideoMetadata(resolution: oldSize!, fps: 0), fileSize: oldBytes, id: self.id)
                )
                else {
                    return
                }

                if let factor {
                    downscaleFactor = factor
                }

                let _ = try? await downscaleVideo(
                    video,
                    originalPath: (path.backupPath?.exists ?? false) ? path.backupPath : nil,
                    id: self.id, toFactor: factor, hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: shouldUseAggressiveOptimisation
                )
            }
        }
    }

    func stop(remove: Bool = true, animateRemoval: Bool = true) {
        if running {
            for process in processes {
                let pid = process.processIdentifier
                mainAsync { processTerminated.insert(pid) }

                (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                process.terminate()
            }
        }
        if remove {
            self.remove(after: animateRemoval ? 500 : 0, withAnimation: true)
        }
    }

    func optimise(allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil, fromOriginal: Bool = false) {
        guard let url else { return }
        remover = nil
        error = nil
        notice = nil

        var path = url.filePath
        if fromOriginal, path.hasOptimisationStatusXattr() {
            if let backup = path.backupPath, backup.exists {
                path.restore(force: true)
            } else if let startingPath = startingURL?.existingFilePath, let originalPath = originalURL?.existingFilePath, originalPath != startingPath {
                path = (try? originalPath.copy(to: startingPath, force: true)) ?? path
            }
        }
        if path.starts(with: FilePath.backups) {
            path = (try? path.copy(to: type.isImage ? FilePath.images : FilePath.videos, force: true)) ?? path
        }

        isOriginal = false
        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggresive = aggressiveOptimisation
        } else if aggresive {
            shouldUseAggressiveOptimisation = true
        }
        if type.isImage, let img = Image(path: path, retinaDownscaled: self.retinaDownscaled) {
            Task.init { try? await optimiseImage(img, id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation) }
            return
        }
        if type.isVideo, path.exists {
            let video = Video(path: path, metadata: VideoMetadata(resolution: oldSize!, fps: 0), fileSize: oldBytes, thumb: false)
            Task.init { try? await optimiseVideo(video, id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation) }
        }
    }

    func restoreOriginal() {
        guard let url else { return }
        scalingFactor = 1.0
        downscaleFactor = 1.0
        speedUpFactor = 1.0
        aggresive = false
        resetRemover()

        let restore: (FilePath) -> Void = { path in
            try? path.backupPath?.setOptimisationStatusXattr("original")
            path.restore()
        }

        let path: FilePath
        if let convertedFromURL {
            self.url = convertedFromURL
            path = convertedFromURL.filePath

            if path.backupPath?.exists ?? false {
                restore(path)
            }

            if let startingPath = startingURL?.existingFilePath, startingPath != path, startingPath.stem == path.stem, startingPath.dir == path.dir {
                try? startingPath.delete()
            }
        } else if let startingURL, startingURL.filePath.backupPath?.exists ?? false {
            path = startingURL.filePath
            self.url = startingURL

            restore(path)
        } else if let originalURL {
            self.url = originalURL
            path = originalURL.filePath
        } else {
            path = url.filePath
            restore(path)
        }
        self.oldBytes = path.fileSize() ?? self.oldBytes
        self.newBytes = -1
        self.newSize = nil

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
            if let savedPath = try? path.copy(to: url.filePath, force: true) {
                self?.hotkeyMessage = "Saved"
                self?.url = url
                self?.path = savedPath
                self?.filename = savedPath.name.string
            } else {
                self?.hotkeyMessage = "Error saving"
            }
        }
    }

    func finish(error: String, notice: String? = nil, keepFor removeAfterMs: Int = 2500) {
        mainAsync { [weak self] in
            guard let self else { return }

            self.error = error
            self.notice = notice
            self.running = false

            self.remove(after: removeAfterMs)
        }
    }

    func finish(notice: String) {
        mainAsync { [weak self] in
            guard let self else { return }

            self.notice = notice
            self.running = false

            self.remove(after: 2500)
        }
    }

    func finish(oldBytes: Int, newBytes: Int, oldSize: CGSize? = nil, newSize: CGSize? = nil, removeAfterMs: Int? = nil) {
        mainAsync { [weak self] in
            guard let self, !self.inRemoval else { return }
            self.remover = nil
            withAnimation(.easeOut(duration: 0.5)) {
                self.oldBytes = oldBytes
                self.newBytes = newBytes
                if let oldSize { self.oldSize = oldSize }
                if let newSize { self.newSize = newSize }
                self.running = false
            }

            guard let removeAfterMs, removeAfterMs > 0 else { return }

            self.remove(after: removeAfterMs)
        }
    }

    func resetRemover() {
        mainAsync { [weak self] in
            guard let self, !self.inRemoval, self.remover != nil, let lastRemoveAfterMs = self.lastRemoveAfterMs else {
                return
            }

            self.remove(after: lastRemoveAfterMs)
        }
    }

    func bringBack() {
        mainAsync {
            self.remover = nil
            self.inRemoval = false
            self.lastRemoveAfterMs = nil
            OM.optimisers = OM.optimisers.with(self)
        }
    }

    func remove(after ms: Int, withAnimation: Bool = false) {
        guard !inRemoval else { return }

        mainAsync { [weak self] in
            guard let self else { return }

            self.lastRemoveAfterMs = ms
            self.remover = mainAsyncAfter(ms: ms) { [weak self] in
                guard let self else { return }

                guard hoveredOptimiserID == nil, !DM.dragging, !editingFilename else {
                    if editingFilename, let lastRemoveAfterMs = self.lastRemoveAfterMs, lastRemoveAfterMs < 1000 * 120 {
                        self.lastRemoveAfterMs = 1000 * 120
                    }
                    self.resetRemover()
                    return
                }
                self.editingFilename = false
                OM.optimisers = OM.optimisers.filter { $0.id != self.id }
                if url != nil {
                    OM.removedOptimisers = OM.removedOptimisers.without(self).with(self)

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
}

@MainActor
class OptimisationManager: ObservableObject, QLPreviewPanelDataSource {
    @Published var current: Optimiser?
    @Published var skippedBecauseNotPro: [URL] = []
    @Published var ignoreProErrorBadge = false

    @Published var removedOptimisers: [Optimiser] = []

    var optimisedFilesByHash: [String: FilePath] = [:]

    var hovered: Optimiser? {
        guard let hoveredOptimiserID else { return nil }
        return opt(hoveredOptimiserID)
    }
    @Published var optimisers: Set<Optimiser> = [] {
        didSet {
            let removed = oldValue.subtracting(optimisers)
            let added = optimisers.subtracting(oldValue)
            if !removed.isEmpty {
                log.debug("Removed optimisers: \(removed)")
            }
            if !added.isEmpty {
                log.debug("Added optimisers: \(added)")
            }
        }
    }

    var optimisersWithURLs: [Optimiser] {
        optimisers.filter { $0.url != nil }
    }

    var clipboardImageOptimiser: Optimiser? { optimisers.first(where: { $0.id == Optimiser.IDs.clipboardImage }) }

    func optimiser(id: String, type: ItemType, operation: String, hidden: Bool = false, source: String? = nil) -> Optimiser {
        let optimiser = (
            OM.optimisers.first(where: { $0.id == id }) ??
                (current?.id == id ? current : nil) ??
                Optimiser(id: id, type: type, operation: operation)
        )

        optimiser.operation = operation
        optimiser.running = true
        optimiser.hidden = hidden
        optimiser.progress.completedUnitCount = 0
        optimiser.isOriginal = false

        if let source {
            optimiser.source = source
        }

        if !OM.optimisers.contains(optimiser) {
            OM.optimisers = OM.optimisers.with(optimiser)
        }
        if id == Optimiser.IDs.clipboardImage || id == Optimiser.IDs.clipboard {
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
        ql.dataSource = self
        if let optimiser {
            ql.currentPreviewItemIndex = optimisersWithURLs.firstIndex(of: optimiser) ?? 0
        } else {
            ql.currentPreviewItemIndex = 0
        }
        ql.reloadData()
    }

}

func tryAsync(_ action: @escaping () async throws -> Void) {
    Task.init {
        do {
            try await action()
        } catch {
            log.error(error.localizedDescription)
        }
    }
}

func justTry(_ action: () throws -> Void) {
    do {
        try action()
    } catch {
        log.error(error.localizedDescription)
    }
}

func mainActor(_ action: @escaping @MainActor () -> Void) {
    Task.init { await MainActor.run { action() }}
}
@MainActor let OM = OptimisationManager()

let optimisationQueue = DispatchQueue(label: "optimisation.queue")
let imageOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
let videoOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 4
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
let pdfOptimisationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 4
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
var pdfOptimiseDebouncers: [String: DispatchWorkItem] = [:]
var videoOptimiseDebouncers: [String: DispatchWorkItem] = [:]
var imageOptimiseDebouncers: [String: DispatchWorkItem] = [:]
var imageResizeDebouncers: [String: DispatchWorkItem] = [:]
var scalingFactor = 1.0

var hideClipboardAfter: Int? {
    let hide = Defaults[.autoHideFloatingResults]
    let hideClipboardAfter = Defaults[.autoHideClipboardResultAfter]
    let hideFilesAfter = Defaults[.autoHideFloatingResultsAfter]
    return hide ? (hideClipboardAfter == -1 ? hideFilesAfter : hideClipboardAfter) * 1000 : nil
}

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
    speedUpBy speedUpFactor: Double? = nil,
    aggressiveOptimisation: Bool? = nil,
    source: String? = nil
) async throws -> ClipboardType? {
    showFloatingThumbnails(force: true)

    var clipResult: ClipboardType?
    do {
        guard let (downloadPath, type, optimiser) = try await downloadFile(from: url, hideFloatingResult: hideFloatingResult) else {
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

            let result: Image?
            if let scalingFactor, scalingFactor < 1 {
                result = try await downscaleImage(img, toFactor: scalingFactor, id: optimiser.id, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            } else {
                result = try await optimiseImage(
                    img,
                    copyToClipboard: copyToClipboard,
                    id: optimiser.id,
                    allowTiff: true,
                    allowLarger: false,
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: aggressiveOptimisation,
                    source: source
                )
            }

            if let result {
                clipResult = .image(result)
            }
        case .video:
            clipResult = .file(downloadPath)

            let result: Video?
            if let scalingFactor, scalingFactor < 1, let video = try await Video.byFetchingMetadata(path: downloadPath, id: optimiser.id) {
                result = try await downscaleVideo(video, id: optimiser.id, toFactor: scalingFactor, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            } else if let speedUpFactor, speedUpFactor < 1, let video = try await Video.byFetchingMetadata(path: downloadPath, id: optimiser.id) {
                result = try await speedUpVideo(video, copyToClipboard: copyToClipboard, id: optimiser.id, byFactor: speedUpFactor, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            } else {
                result = try await optimiseVideo(Video(path: downloadPath, id: optimiser.id), id: optimiser.id, allowLarger: false, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            }

            if let result {
                clipResult = .file(result.path)
            }
        case .pdf:
            clipResult = .file(downloadPath)

            let result: PDF? = try await optimisePDF(PDF(downloadPath, id: optimiser.id), id: optimiser.id, allowLarger: false, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)

            if let result {
                clipResult = .file(result.path)
            }
        default:
            return nil
        }
    } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
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

    var id: String {
        switch self {
        case let .image(img): img.path.string
        case let .file(path): path.string
        case let .url(url): url.path
        case .unknown: ""
        }
    }

    static func == (lhs: ClipboardType, rhs: ClipboardType) -> Bool {
        lhs.id == rhs.id
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

        if let path = item.string(forType: .fileURL)?.trimmedPath.url?.filePath ?? item.string(forType: .string)?.trimmedPath.existingFilePath, path.isPDF || path.isVideo {
            return .file(path)
        }

        if let img = try? Image.fromPasteboard(anyType: true) {
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

@discardableResult
@MainActor func proGuard<T>(count: inout Int, limit: Int = 2, url: URL? = nil, _ action: @escaping () async throws -> T) async throws -> T {
    guard let PRO, PRO.active || count < limit else {
        proLimitsReached(url: url)
        throw ClopError.proError("Pro limits reached")
    }
    let result = try await action()
    count += 1
    return result
}

var manualOptimisationCount = 0

@MainActor func downloadFile(from url: URL, optimiser: Optimiser? = nil, hideFloatingResult: Bool = false) async throws -> (FilePath, ItemType, Optimiser)? {
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

    type = type ?? ItemType.from(filePath: fileURL.filePath)
    guard let type, type.isImage || type.isVideo, let ext = type.ext else {
        throw ClopError.downloadError("invalid file type")
    }
    guard optimiser.running, !optimiser.inRemoval else {
        return nil
    }

    let name: String = url.lastPathComponent.reversed().split(separator: ".", maxSplits: 1).last?.reversed().s ??
        url.lastPathComponent.replacingOccurrences(of: ".\(ext)", with: "", options: .caseInsensitive)
    let downloadPath = FilePath.downloads.appending("\(name).\(ext)")
    try fileURL.filePath.move(to: downloadPath, force: true)

    guard optimiser.running, !optimiser.inRemoval else {
        return nil
    }
    return (downloadPath, type, optimiser)
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

@MainActor func optimiseLastClipboardItem(hideFloatingResult: Bool = false, downscaleTo scalingFactor: Double? = nil, speedUpBy speedUpFactor: Double? = nil, aggressiveOptimisation: Bool? = nil) async throws {
    let item = ClipboardType.lastItem()
    try await optimiseItem(
        item,
        id: Optimiser.IDs.clipboard,
        hideFloatingResult: hideFloatingResult,
        downscaleTo: scalingFactor,
        speedUpBy: speedUpFactor,
        aggressiveOptimisation: aggressiveOptimisation,
        optimisationCount: &manualOptimisationCount,
        copyToClipboard: true,
        source: "clipboard"
    )
}

@MainActor func showNotice(_ notice: String) {
    let optimiser = OM.optimiser(id: "notice", type: .unknown, operation: "")
    optimiser.finish(notice: notice)
}

@discardableResult
@MainActor func optimiseItem(
    _ item: ClipboardType,
    id: String,
    hideFloatingResult: Bool = false,
    downscaleTo scalingFactor: Double? = nil,
    speedUpBy speedUpFactor: Double? = nil,
    aggressiveOptimisation: Bool? = nil,
    optimisationCount: inout Int,
    copyToClipboard: Bool,
    source: String? = nil
) async throws -> ClipboardType? {
    let nope = { (notice: String) in
        let optimiser = OM.optimiser(id: id, type: .unknown, operation: "", hidden: hideFloatingResult)
        optimiser.finish(notice: notice)
    }

    switch item {
    case let .image(img):
        let result = try await proGuard(count: &optimisationCount, limit: 2, url: img.path.url) {
            if let scalingFactor, scalingFactor < 1 {
                try await downscaleImage(img, toFactor: scalingFactor, copyToClipboard: copyToClipboard, id: id, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            } else {
                try await optimiseImage(img, copyToClipboard: copyToClipboard, allowTiff: true, allowLarger: false, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            }
        }
        guard let result else { return nil }
        return .image(result)
    case let .file(path):
        if path.isImage, let img = Image(path: path, retinaDownscaled: false) {
            guard aggressiveOptimisation == true || !path.hasOptimisationStatusXattr() else {
                nope("Already optimised")
                throw ClopError.alreadyOptimised(path)
            }
            let result = try await proGuard(count: &optimisationCount, limit: 2, url: path.url) {
                if let scalingFactor, scalingFactor < 1 {
                    try await downscaleImage(img, toFactor: scalingFactor, copyToClipboard: copyToClipboard, id: id, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
                } else {
                    try await optimiseImage(img, copyToClipboard: copyToClipboard, allowTiff: true, allowLarger: false, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
                }
            }
            guard let result else { return nil }
            return .image(result)
        } else if path.isVideo {
            guard aggressiveOptimisation == true || speedUpFactor != nil || scalingFactor != nil || !path.hasOptimisationStatusXattr() else {
                nope("Already optimised")
                throw ClopError.alreadyOptimised(path)
            }
            let result = try await proGuard(count: &optimisationCount, limit: 2, url: path.url) {
                let video = await (try? Video.byFetchingMetadata(path: path)) ?? Video(path: path)

                if let scalingFactor, scalingFactor < 1 {
                    return try await downscaleVideo(video, copyToClipboard: copyToClipboard, toFactor: scalingFactor, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
                } else if let speedUpFactor, speedUpFactor != 1, speedUpFactor != 0 {
                    return try await speedUpVideo(video, copyToClipboard: copyToClipboard, byFactor: speedUpFactor, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
                } else {
                    return try await optimiseVideo(video, copyToClipboard: copyToClipboard, allowLarger: false, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
                }
            }
            guard let result else { return nil }
            return .file(result.path)
        } else if path.isPDF {
            guard aggressiveOptimisation == true || !path.hasOptimisationStatusXattr() else {
                nope("Already optimised")
                throw ClopError.alreadyOptimised(path)
            }
            let result = try await proGuard(count: &optimisationCount, limit: 2, url: path.url) {
                try await optimisePDF(PDF(path), copyToClipboard: copyToClipboard, allowLarger: false, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: aggressiveOptimisation, source: source)
            }
            guard let result else { return nil }
            return .file(result.path)
        } else {
            nope("Clipboard contents can't be optimised")
            throw ClopError.unknownType
        }
    case let .url(url):
        let result = try await proGuard(count: &optimisationCount, limit: 2, url: url) {
            try await optimiseURL(url, copyToClipboard: copyToClipboard, hideFloatingResult: hideFloatingResult, downscaleTo: scalingFactor, speedUpBy: speedUpFactor, aggressiveOptimisation: aggressiveOptimisation, source: source)
        }
        return result
    default:
        nope("Clipboard contents can't be optimised")
        throw ClopError.unknownType
    }
}

@MainActor func showFloatingThumbnails(force: Bool = false) {
    guard Defaults[.enableFloatingResults], !sizeNotificationWindow.isVisible || force else {
        return
    }
    sizeNotificationWindow.show(closeAfter: 0, fadeAfter: 0, fadeDuration: 0.2, corner: Defaults[.floatingResultsCorner], margin: FLOAT_MARGIN, marginHorizontal: 0)

}
