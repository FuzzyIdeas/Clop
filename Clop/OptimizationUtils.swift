//
//  OptimizationUtils.swift
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
    case url
    case unknown

    var ext: String? {
        switch self {
        case let .image(uTType):
            return uTType.preferredFilenameExtension
        case let .video(uTType):
            return uTType.preferredFilenameExtension
        case .url:
            return nil
        case .unknown:
            return nil
        }
    }

    var isImage: Bool {
        switch self {
        case .image:
            return true
        default:
            return false
        }
    }

    var isVideo: Bool {
        switch self {
        case .video:
            return true
        default:
            return false
        }
    }

    var isURL: Bool {
        switch self {
        case .url:
            return true
        default:
            return false
        }
    }

    var utType: UTType? {
        switch self {
        case let .image(utType):
            return utType
        case let .video(utType):
            return utType
        case .url:
            return nil
        case .unknown:
            return nil
        }
    }

    static func from(mimeType: String) -> ItemType {
        switch mimeType {
        case "image/jpeg", "image/png", "image/gif", "image/tiff", "image/webp", "image/heic", "image/heif", "image/avif":
            return .image(UTType(mimeType: mimeType)!)
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/x-mpeg":
            return .video(UTType(mimeType: mimeType)!)
        case "text/html":
            return .url
        default:
            return .unknown
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
        case "text/html":
            return .url
        default:
            return .unknown
        }
    }
}

var hoveredOptimizerID: String?

@MainActor
class OptimizerProgressDelegate: NSObject, URLSessionDataDelegate {
    init(optimizer: Optimizer) {
        self.optimizer = optimizer
    }

    let optimizer: Optimizer

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        debug("Finished downloading \(location.path)")
    }

    func handleTask(_ task: URLSessionTask) {
        optimizer.progress = task.progress
        if !optimizer.running || optimizer.inRemoval {
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

        NSApp.activate(ignoringOtherApps: true)
        ql.makeKeyAndOrderFront(nil)
        ql.dataSource = self
        ql.currentPreviewItemIndex = 0
        ql.reloadData()
    }
}

// MARK: - Optimizer

@MainActor
final class Optimizer: ObservableObject, Identifiable, Hashable, Equatable, CustomStringConvertible {
    init(id: String, type: ItemType, running: Bool = true, oldBytes: Int = 0, newBytes: Int = 0, oldSize: CGSize? = nil, newSize: CGSize? = nil, progress: Progress? = nil, operation: String = "Optimizing") {
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

    @Published var running = true
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

    @Published var downscaleFactor = 1.0
    @Published var aggresive = false

    lazy var path: FilePath? = {
        if let url { return FilePath(url) }
        return id == IDs.clipboardImage ? nil : FilePath(stringLiteral: id)
    }()
    lazy var filename: String =
        id == IDs.clipboardImage ? id : (url?.lastPathComponent ?? FilePath(stringLiteral: id).name.string)

    var lastRemoveAfterMs: Int? = nil

    @Published var inRemoval = false

    @Published var url: URL? {
        didSet {
            print("URL set to \(url?.path ?? "nil") from \(oldValue?.path ?? "nil")")
            if startingURL == nil {
                startingURL = url
            }
        }
    }
    @Published var operation = "Optimizing" { didSet {
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

    nonisolated static func == (lhs: Optimizer, rhs: Optimizer) -> Bool {
        lhs.id == rhs.id
    }

    func quicklook() {
        resetRemover()
        OM.quicklook(optimizer: self)
    }

    func downscale(toFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimization: Bool? = nil) {
        guard !inRemoval else { return }

        remover = nil
        isOriginal = false
        error = nil
        notice = nil

        var shouldUseAggressiveOptimization = aggressiveOptimization
        if let aggressiveOptimization {
            aggresive = aggressiveOptimization
        } else if aggresive {
            shouldUseAggressiveOptimization = true
        }

        Task.init {
            if type.isImage, let path = originalURL?.filePath ?? path, let image = Image(path: path) {
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
                    aggressiveOptimization: shouldUseAggressiveOptimization
                )
            }
            if type.isVideo, let path = originalURL?.filePath ?? path {
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
                    aggressiveOptimization: shouldUseAggressiveOptimization
                )
            }
        }
    }

    func stop(remove: Bool = true, animateRemoval: Bool = true) {
        if running {
            for process in processes {
                mainAsync { processTerminated.insert(process.processIdentifier) }
                (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                process.terminate()
            }
        }
        if remove {
            self.remove(after: animateRemoval ? 500 : 0, withAnimation: true)
        }
    }

    func optimize(allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimization: Bool? = nil, fromOriginal: Bool = false) {
        guard let url else { return }
        remover = nil
        error = nil
        notice = nil

        var path = url.filePath
        if fromOriginal, path.hasOptimizationStatusXattr() {
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
        var shouldUseAggressiveOptimization = aggressiveOptimization
        if let aggressiveOptimization {
            aggresive = aggressiveOptimization
        } else if aggresive {
            shouldUseAggressiveOptimization = true
        }
        if type.isImage, let img = Image(path: path) {
            Task.init { try? await optimizeImage(img, id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimization: shouldUseAggressiveOptimization) }
            return
        }
        if type.isVideo, path.exists {
            let video = Video(path: path, metadata: VideoMetadata(resolution: oldSize!, fps: 0), fileSize: oldBytes, thumb: false)
            Task.init { try? await optimizeVideo(video, id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimization: shouldUseAggressiveOptimization) }
        }
    }

    func restoreOriginal() {
        guard let url else { return }
        scalingFactor = 1.0
        downscaleFactor = 1.0
        aggresive = false
        resetRemover()

        let path: FilePath
        if let startingURL, let startingPath = startingURL.existingFilePath, startingPath.backupPath?.exists ?? false {
            self.url = startingURL
            startingPath.restore(force: true)
            path = startingPath
        } else if let originalURL {
            self.url = originalURL
            path = originalURL.filePath
        } else {
            url.filePath.restore()
            path = url.filePath
        }
        self.newBytes = -1
        self.newSize = nil

        if type.isImage, let image = Image(path: path), id == IDs.clipboardImage {
            image.copyToClipboard()
        }
        isOriginal = true
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
        mainAsync {
            guard !self.inRemoval, self.remover != nil, let lastRemoveAfterMs = self.lastRemoveAfterMs else {
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
            OM.optimizers = OM.optimizers.with(self)
        }
    }

    func remove(after ms: Int, withAnimation: Bool = false) {
        guard !inRemoval else { return }

        mainAsync {
//            self.isOriginal = false
            self.lastRemoveAfterMs = ms
            self.remover = mainAsyncAfter(ms: ms) {
                guard hoveredOptimizerID != self.id else {
                    self.resetRemover()
                    return
                }
                OM.optimizers = OM.optimizers.filter { $0.id != self.id }
                OM.removedOptimizers = OM.removedOptimizers.without(self).with(self)
            }
            if withAnimation, hoveredOptimizerID != self.id {
                self.inRemoval = true
            }
        }
    }
}

@MainActor
class OptimizationManager: ObservableObject, QLPreviewPanelDataSource {
    @Published var current: Optimizer?
    @Published var skippedBecauseNotPro: [URL] = []
    @Published var ignoreProErrorBadge = false

    @Published var removedOptimizers: [Optimizer] = []

    @Published var optimizers: Set<Optimizer> = [] {
        didSet {
            print("Removed optimizers: \(oldValue.subtracting(optimizers))")
            print("Added optimizers: \(optimizers.subtracting(oldValue))")
        }
    }

    var optimizersWithURLs: [Optimizer] {
        optimizers.filter { $0.url != nil }
    }

    var clipboardImageOptimizer: Optimizer? { optimizers.first(where: { $0.id == Optimizer.IDs.clipboardImage }) }

    func optimizer(id: String, type: ItemType, operation: String, hidden: Bool = false) -> Optimizer {
        let optimizer = OM.optimizers.first(where: { $0.id == id }) ?? Optimizer(id: id, type: type, operation: operation)

        optimizer.operation = operation
        optimizer.running = true
        optimizer.hidden = hidden
        optimizer.progress.completedUnitCount = 0

        if !OM.optimizers.contains(optimizer) {
            OM.optimizers = OM.optimizers.with(optimizer)
        }

        showFloatingThumbnails()
        return optimizer
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        optimizersWithURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let opt = optimizersWithURLs[safe: index] else {
            return nil
        }
        return (opt.url ?? opt.originalURL) as NSURL?
    }

    func quicklook(optimizer: Optimizer? = nil) {
        guard let ql = QLPreviewPanel.shared() else { return }

        NSApp.activate(ignoringOtherApps: true)
        ql.makeKeyAndOrderFront(nil)
        ql.dataSource = self
        if let optimizer {
            ql.currentPreviewItemIndex = optimizersWithURLs.firstIndex(of: optimizer) ?? 0
        } else {
            ql.currentPreviewItemIndex = 0
        }
        ql.reloadData()
    }

}
func mainActor(_ action: @escaping @MainActor () -> Void) {
    Task.init { await MainActor.run { action() }}
}
@MainActor let OM = OptimizationManager()

let optimizationQueue = DispatchQueue(label: "optimization.queue")
let imageOptimizationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
let videoOptimizationQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 4
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
var videoOptimizeDebouncers: [String: DispatchWorkItem] = [:]
var imageOptimizeDebouncers: [String: DispatchWorkItem] = [:]
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
func optimizeURL(_ url: URL, copyToClipboard: Bool = false, hideFloatingResult: Bool = false, downscaleTo scalingFactor: Double? = nil, aggressiveOptimization: Bool? = nil) async throws -> ClipboardType? {
    showFloatingThumbnails()

    do {
        guard let (downloadPath, type, optimizer) = try await getFile(from: url, hideFloatingResult: hideFloatingResult) else {
            return nil
        }
        let downloadURL = downloadPath.url

        optimizer.operation = "Optimizing" + (aggressiveOptimization ?? false ? " (aggressive)" : "")
        optimizer.originalURL = downloadURL
        optimizer.url = downloadURL
        optimizer.type = type

        switch type {
        case .image:
            guard let img = Image(path: downloadPath) else {
                throw ClopError.downloadError("invalid image")
            }

            let result: Image?
            if let scalingFactor, scalingFactor < 1 {
                result = try await downscaleImage(img, toFactor: scalingFactor, id: optimizer.id, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
            } else {
                result = try await optimizeImage(img, copyToClipboard: copyToClipboard, id: optimizer.id, allowTiff: true, allowLarger: true, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
            }

            guard let result else { return nil }
            return .image(result)

        case .video:
            let result: Video?
            if let scalingFactor, scalingFactor < 1, let video = try await Video.byFetchingMetadata(path: downloadPath, id: optimizer.id) {
                result = try await downscaleVideo(video, id: optimizer.id, toFactor: scalingFactor, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
            } else {
                result = try await optimizeVideo(Video(path: downloadPath, id: optimizer.id), id: optimizer.id, allowLarger: true, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
            }

            guard let result else { return nil }
            return .file(result.path)
        default:
            return nil
        }
    } catch let error as ClopError {
        opt(url.absoluteString)?.finish(error: error.humanDescription)
        throw error
    } catch {
        opt(url.absoluteString)?.finish(error: error.localizedDescription)
        throw error
    }
}

extension String {
    var trimmedPath: String {
        trimmingCharacters(in: ["\"", "'", "\n", "\t", " ", "(", ")"])
    }
}

@MainActor func opt(_ optimizerID: String) -> Optimizer? {
    OM.optimizers.first(where: { $0.id == optimizerID })
}

let BASE64_PREFIX = #/(url\()?data:image/[^;]+;base64,/#

enum ClipboardType {
    case image(Image)
    case file(FilePath)
    case url(URL)
    case unknown

    static func fromString(_ str: String) -> ClipboardType {
        if let data = Data(base64Encoded: str.replacing(BASE64_PREFIX, with: "").trimmedPath), let img = Image(data: data) {
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

        if let img = try? Image.fromPasteboard(anyType: true) {
            return .image(img)
        }

        if let str = item.string(forType: .string), let data = Data(base64Encoded: str.replacing(BASE64_PREFIX, with: "").trimmedPath), let img = Image(data: data) {
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

var manualOptimizationCount = 0

@MainActor func getFile(from url: URL, optimizer: Optimizer? = nil, hideFloatingResult: Bool = false) async throws -> (FilePath, ItemType, Optimizer)? {
    var optimizer: Optimizer?
    if optimizer == nil {
        optimizer = OM.optimizer(id: url.absoluteString, type: .url, operation: "Fetching", hidden: hideFloatingResult)
        optimizer!.url = url
    }
    guard let optimizer else { return nil }

    let progressDelegate = OptimizerProgressDelegate(optimizer: optimizer)
    var type = try await fetchType(from: url, progressDelegate: progressDelegate)

    optimizer.operation = "Downloading"
    let fileURL = try await url.download(type: type?.utType, delegate: progressDelegate)

    type = type ?? ItemType.from(filePath: fileURL.filePath)
    guard let type, type.isImage || type.isVideo, let ext = type.ext else {
        throw ClopError.downloadError("invalid file type")
    }
    guard optimizer.running, !optimizer.inRemoval else {
        return nil
    }

    let name: String = url.lastPathComponent.reversed().split(separator: ".", maxSplits: 1).last?.reversed().s ??
        url.lastPathComponent.replacingOccurrences(of: ".\(ext)", with: "", options: .caseInsensitive)
    let downloadPath = FilePath.downloads.appending("\(name).\(ext)")
    try fileURL.filePath.move(to: downloadPath, force: true)

    guard optimizer.running, !optimizer.inRemoval else {
        return nil
    }
    return (downloadPath, type, optimizer)
}

@MainActor func quickLookLastClipboardItem() async throws {
    let item = ClipboardType.lastItem()

    switch item {
    case let .image(image):
        QuickLooker.quicklook(url: image.path.url)
    case let .file(filePath):
        QuickLooker.quicklook(url: filePath.url)
    case let .url(url):
        guard let (downloadPath, _, optimizer) = try await getFile(from: url) else {
            return
        }
        optimizer.stop()

        QuickLooker.quicklook(url: downloadPath.url)
    case .unknown:
        throw ClopError.unknownType
    }
}

@MainActor func optimizeLastClipboardItem(hideFloatingResult: Bool = false, downscaleTo scalingFactor: Double? = nil, aggressiveOptimization: Bool? = nil) async throws {
    let item = ClipboardType.lastItem()
    try await optimizeItem(item, id: Optimizer.IDs.clipboard, hideFloatingResult: hideFloatingResult, downscaleTo: scalingFactor, aggressiveOptimization: aggressiveOptimization)
}

@MainActor func showNotice(_ notice: String) {
    let optimizer = OM.optimizer(id: "notice", type: .unknown, operation: "")
    optimizer.finish(notice: notice)
}

@discardableResult
@MainActor func optimizeItem(_ item: ClipboardType, id: String, hideFloatingResult: Bool = false, downscaleTo scalingFactor: Double? = nil, aggressiveOptimization: Bool? = nil) async throws -> ClipboardType? {
    let nope = { (notice: String) in
        let optimizer = OM.optimizer(id: id, type: .unknown, operation: "", hidden: hideFloatingResult)
        optimizer.finish(notice: notice)
    }

    switch item {
    case let .image(img):
        let result = try await proGuard(count: &manualOptimizationCount, limit: 2, url: img.path.url) {
            if let scalingFactor, scalingFactor < 1 {
                return try await downscaleImage(img, toFactor: scalingFactor, id: id, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
            } else {
                return try await optimizeImage(img, copyToClipboard: true, allowTiff: true, allowLarger: true, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
            }
        }
        guard let result else { return nil }
        return .image(result)
    case let .file(path):
        if path.isImage, let img = Image(path: path) {
            guard !path.hasOptimizationStatusXattr() else {
                nope("Image already optimized")
                throw ClopError.alreadyOptimized(path)
            }
            let result = try await proGuard(count: &manualOptimizationCount, limit: 2, url: path.url) {
                if let scalingFactor, scalingFactor < 1 {
                    return try await downscaleImage(img, toFactor: scalingFactor, id: id, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
                } else {
                    return try await optimizeImage(img, copyToClipboard: true, allowTiff: true, allowLarger: true, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
                }
            }
            guard let result else { return nil }
            return .image(result)
        } else if path.isVideo {
            guard !path.hasOptimizationStatusXattr() else {
                nope("Video already optimized")
                throw ClopError.alreadyOptimized(path)
            }
            let result = try await proGuard(count: &manualOptimizationCount, limit: 2, url: path.url) {
                if let scalingFactor, scalingFactor < 1, let video = try await Video.byFetchingMetadata(path: path) {
                    return try await downscaleVideo(video, toFactor: scalingFactor, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
                } else {
                    return try await optimizeVideo(Video(path: path), allowLarger: true, hideFloatingResult: hideFloatingResult, aggressiveOptimization: aggressiveOptimization)
                }
            }
            guard let result else { return nil }
            return .file(result.path)
        } else {
            nope("Clipboard contents can't be optimized")
            throw ClopError.unknownType
        }
    case let .url(url):
        let result = try await proGuard(count: &manualOptimizationCount, limit: 2, url: url) {
            try await optimizeURL(url, hideFloatingResult: hideFloatingResult, downscaleTo: scalingFactor, aggressiveOptimization: aggressiveOptimization)
        }
        return result
    default:
        nope("Clipboard contents can't be optimized")
        throw ClopError.unknownType
    }
}

@MainActor func showFloatingThumbnails() {
    guard Defaults[.enableFloatingResults] else {
        return
    }
    sizeNotificationWindow.show(closeAfter: 0, fadeAfter: 0, fadeDuration: 0.2, corner: Defaults[.floatingResultsCorner], margin: FLOAT_MARGIN, marginHorizontal: 0)

}
