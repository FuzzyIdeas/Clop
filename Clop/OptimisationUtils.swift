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
                    KM.bareKeys = []
                    KM.reinitHotkeys()
                    return
                }

                log.debug("Hovered optimiser ID is \(hoveredOptimiserID!), starting hover hotkeys")
                KM.secondaryKeys = DEFAULT_HOVER_KEYS
                KM.bareKeys = [.space]
                KM.reinitHotkeys()
            }
        }
    }
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
        optimiser.publishProgress()
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

enum TempPipelineSegment {
    case encodingGroup([PipelineStep])
    case singleStep(PipelineStep)
}

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
    /// When true, this optimiser's `Progress` is never registered in the system-wide NSProgress
    /// tree. Set for batch-mode runs so a large batch doesn't flood the global progress hierarchy
    /// with thousands of jobs (it also has no floating result observing the progress anyway).
    var batchSilent = false
    @Published var hidden = false
    @Published var isOriginal = false
    @Published var progress = Progress()

    @Published var oldBytes = 0
    @Published var newBytes = 0

    @Published var oldSize: CGSize? = nil
    @Published var newSize: CGSize? = nil

    @Published var oldBitrate: Int? = nil
    @Published var newBitrate: Int? = nil

    @Published var oldDPI: Int? = nil
    @Published var newDPI: Int? = nil

    /// Original embedded cover-art resolution, lazily loaded for the audio "Downscale cover art"
    /// slider so it can show the target size.
    @Published var coverArtSize: CGSize? = nil
    /// Current cover-art scale (1.0 = original). Kept separate from `downscaleFactor` so audio cover
    /// resizing doesn't get tangled up with the image/video resolution-downscale machinery.
    @Published var coverDownscaleFactor = 1.0
    /// Cached pristine, full-resolution cover art extracted on first use. Every cover downscale
    /// scales from this so resizing is absolute (no compounding) and 100% restores the original.
    /// In-place re-muxing changes the file's `clopBackupPath` hash, so we can't rely on the backup.
    var coverArtOriginalPath: FilePath?

    @Published var error: String? = nil
    /// The real command line + stdout/stderr of the failing tool, captured for the batch failures view.
    var errorLog: String?
    @Published var notice: String? = nil
    @Published var info: String? = nil
    @Published var thumbnail: NSImage?

    @Published var originalURL: URL?
    @Published var startingURL: URL?
    @Published var convertedFromURL: URL?
    /// Path of the previous manual-conversion output to delete once the next conversion succeeds
    /// (keep-only-last). Nil when the conversion is additive (Option-click) or the current file is the
    /// original. Set in `convert(to:optimise:additive:)`, consumed in `finish(oldBytes:newBytes:)`.
    var supersededConvertURL: URL?
    @Published var outputFolderURL: URL? = nil
    @Published var downscaleFactor = 1.0
    /// True while the pointer is over the filename name segment specifically (not the extension or
    /// the rest of the card), so the card can hide the crop button and let the name expand.
    @Published var hoveringFilename = false
    /// True while the floating card's extension chip has its one-click convert accordion open, so the
    /// card can hide its other controls (corner buttons, action grid) and let the accordion stand out.
    @Published var showingFormats = false
    @Published var showDownscaleSlider = false
    @Published var showCompressionSlider = false
    /// While true, the floating card shows the "Fit under size" slider (log-scaled target size).
    @Published var showTargetSizeSlider = false
    /// While true, the floating card shows the "Send securely" expiration overlay (slider + confirm).
    @Published var showSendExpiration = false
    /// Chosen link expiration (seconds) for the pending send; seeded from the default setting.
    @Published var sendExpiration: TimeInterval = Defaults[.defaultLinkExpiration]
    /// Set after a manual action (scale, compression, restore) so the hover overlay collapses and the
    /// new file size is visible; cleared on the next hover so the overlay returns on the next pass.
    @Published var collapseHoverOverlay = false
    @Published var audioBitrateOverride: Int?
    @Published var pdfDPIOverride: Int?
    /// Per-result compression override set by the draggable compression button; takes priority
    /// over the global per-format Defaults at encode time. nil = use the global setting.
    /// Set on the main actor (the slider) and read by the background encode; the per-id in-flight
    /// pipeline is terminated before a new encode starts, so there is no concurrent read+write.
    nonisolated(unsafe) var compressionOverride: CompressionQuality?
    /// Ingest-detected codec of the CURRENT file, display-only (chip badge + convert-target
    /// exclusion). Behaviour keys off `type`, which only changes for Clop-made conversions:
    /// retyping arrivals would e.g. strip the crop button from an incoming HEVC mp4.
    @Published var detectedVideoCodec: UTType?
    var downscaleDebounceTask: Task<Void, Never>?
    var lowerBitrateDebounceTask: Task<Void, Never>?
    var pdfDPIDebounceTask: Task<Void, Never>?
    @Published var changePlaybackSpeedFactor = 1.0
    @Published var aggressive = false

    /// Accumulated pipeline of all actions on this item (processing + file ops).
    /// Processing steps within encoding groups are compiled into single ffmpeg passes.
    var tempPipeline: [PipelineStep] = []

    /// The automation pipeline that ran after initial optimisation, if any.
    var automationPipeline: Pipeline?

    lazy var path: FilePath? = {
        if let url { return FilePath(url) }
        return id == IDs.clipboardImage ? nil : FilePath(stringLiteral: id)
    }()
    lazy var filename: String =
        id == IDs.clipboardImage ? id : (url?.lastPathComponent ?? FilePath(stringLiteral: id).name.string)

    var lastRemoveAfterMs: Int?

    @Published var inRemoval = false
    /// Set the instant the close button is pressed so the floating result drops its expensive
    /// content (Liquid Glass, thumbnail) and renders nothing while the actual removal completes.
    /// Avoids paying for a full glass re-render during dismissal, making the click feel instant.
    @Published var dismissing = false

    @Atomic var retinaDownscaled = false

    var source: OptimisationSource?

    /// Per-request placement override carried from a CLI `OptimisationRequest`. When set, `placeOutput`
    /// uses it instead of the stored behaviour Defaults. Nil for UI-initiated work.
    var placementOverride: PlacementOverride?

    /// Bundle id and display name of the app that placed the clipboard content, captured at
    /// clipboard-read time for the `copiedBy` pipeline filter. nil for non-clipboard sources.
    var copiedFromAppBundleID: String?
    var copiedFromAppName: String?

    @Published var sharing = false
    @Published var warpDropConnecting = false
    @Published var isVideoWithAudio = false

    lazy var image: Image? = fetchImage()
    lazy var video: Video? = fetchVideo()
    lazy var pdf: PDF? = fetchPDF()
    lazy var audio: Audio? = fetchAudio()

    var comparisonWindowController: NSWindowController?
    var cropWindowController: NSWindowController?
    /// Last applied rect crop (with its preset name and target size), so the crop window
    /// can re-open on the uncropped source with the current crop pre-selected
    var lastCropSize: CropSize?

    var isComparing = false

    @Published var stepIndicator = ""

    /// The pristine uncropped file that rect crops should start from. The backup name
    /// hashes the file's timestamp, so in-place changes (like a previous crop) can make
    /// it unresolvable: fall back to the URLs tracked at optimisation time.
    var cropOriginalURL: URL? {
        guard let url, let path = url.filePath else { return nil }
        if let backup = path.clopBackupPath, backup.exists {
            return backup.url
        }
        let ext = path.extension?.lowercased()
        for candidate in [originalURL, startingURL] {
            if let p = candidate?.existingFilePath, p.url != url, p.extension?.lowercased() == ext {
                return p.url
            }
        }
        return nil
    }

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

    /// The `AudioFormat` the result is currently in (e.g. `.aac` after a wav→m4a conversion).
    var currentAudioFormat: AudioFormat? {
        guard type.isAudio, let ut = type.utType else { return nil }
        return AudioFormat.allCases.first { $0.utType == ut }
    }

    /// The concrete audio format of this result, derived from its current type/extension. Replaces the old
    /// single global Defaults[.audioFormat] for per-result bitrate UI.
    var audioFormat: AudioFormat {
        let ext = (url ?? originalURL)?.filePath?.extension?.lowercased()
            ?? { if case let .audio(ut) = type { return ut.preferredFilenameExtension?.lowercased() }; return nil }()
        return AudioFormat.allCases.first { $0 != .sameAsInput && ($0.fileExtension == ext || ($0 == .opus && ext == "opus")) } ?? .aac
    }

    @Published var editing = false {
        didSet {
            guard editing != oldValue else {
                return
            }

            if editing {
                KM.secondaryKeys = []
                KM.bareKeys = []
                KM.reinitHotkeys()
            } else {
                floatingResultsWindow.allowToBecomeKey = false
                if hoveredOptimiserID != nil {
                    KM.secondaryKeys = DEFAULT_HOVER_KEYS
                    KM.bareKeys = [.space]
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
            animatedGIFCache = nil
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

    @Published var operation = "Optimising" {
        didSet {
            if !progress.isIndeterminate {
                progress.localizedDescription = operation
            }
        }
    }

    /// While a manual scale and/or compression change is applied, describe both dimensions so the
    /// operation text reads e.g. "Scale: 50% | Compression: 80%" instead of hiding the one you
    /// didn't just touch (changing compression after a downscale shouldn't read "Scaling to 50%").
    /// Returns nil when neither was manually changed, so callers fall back to their own label.
    var manualAdjustmentOperation: String? {
        var parts: [String] = []
        if downscaleFactor < 0.99 {
            parts.append("Scale: \((downscaleFactor * 100).intround)%")
        }
        if let cq = compressionOverride {
            parts.append("Compression: \(CompressionScale.label(for: cq, type: compressionSliderType))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " | ") + (aggressive ? " (aggressive)" : "")
    }

    var description: String {
        "\(operation) \(id) [\(running ? "RUNNING" : "FINISHED")]"
    }

    var remover: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }
    var deleter: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    /// The DPI shown as "current" in PDF UI (sliders, indicators) when the user
    /// hasn't dragged a manual override. Resolves the Adaptive sentinel via the
    /// optimiser's `newDPI` (set during optimisation), falling back to the
    /// no-downsample stop if no optimisation has run yet.
    var effectiveBasePDFDPI: Int {
        let setting = Defaults[.pdfDPI]
        // aggressive renders one stop below the setting, so the actual DPI lives in newDPI
        return setting == PDF_DPI_ADAPTIVE || aggressive ? (newDPI ?? PDF_DPI_NO_DOWNSAMPLE) : setting
    }

    /// True only for a multi-frame GIF still typed as an image. Memoised by url so it isn't re-probed
    /// on every SwiftUI render; the cache is cleared in url.didSet.
    var isAnimatedGIF: Bool {
        guard type == .image(.gif), let url, let path else { return false }
        if let cache = animatedGIFCache, cache.url == url { return cache.value }
        let value = path.isAnimatedGIF
        animatedGIFCache = (url, value)
        return value
    }

    /// True when this is a GIF that was produced from a video and still remembers the source, so
    /// "Restore original" can take the user back to that video.
    var convertedFromVideo: Bool {
        type == .image(.gif) && (convertedFromURL?.filePath?.isVideo ?? false)
    }

    /// Formats this item can be converted to. Animated GIFs offer video targets (so all frames are
    /// preserved) instead of image targets; everything else uses the type's default list.
    var convertibleTypes: [UTType] {
        if isAnimatedGIF {
            return [.mpeg4Movie, .quickTimeMovie, .webm, .hevcVideo, .av1Video].compactMap { $0 }
        }
        return type.convertibleTypes
    }

    /// The result's real video codec when it differs from what the container implies.
    var videoCodecType: UTType? {
        switch type {
        case .video(.hevcVideo): .hevcVideo
        case .video(.av1Video): .av1Video
        case .video(.webm) where convertedFromURL != nil: .webm
        default: detectedVideoCodec
        }
    }

    /// The type the compression slider should style itself for: the codec type only when this
    /// result is a Clop-made conversion the slider can actually re-encode (sticky), otherwise the
    /// plain video type, so an arriving .webm doesn't get a "VP9 · N%" label on a drag that would
    /// run a plain optimise.
    var compressionSliderType: ItemType {
        guard type.isVideo else { return type }
        return stickyConversionFormat() != nil ? type : .video(.mpeg4Movie)
    }

    /// Codec shown on ambiguous audio containers (m4a can be AAC or ALAC, ogg Opus or Vorbis).
    /// Clop's own conversions know their codec from `AudioFormat`; arrivals use the fetched fourcc.
    var audioCodecName: String? {
        guard type.isAudio, let ext = (url ?? originalURL)?.filePath?.extension?.lowercased(),
              ext == "m4a" || ext == "ogg" || ext == "oga"
        else { return nil }
        if convertedFromURL != nil, let fmt = currentAudioFormat {
            switch fmt {
            case .aac: return "AAC"
            case .opus: return "OPUS"
            default: break
            }
        }
        return audio?.codec.flatMap(audioCodecDisplayName)
    }

    /// Codec appended to the extension chip when the extension alone is ambiguous or misleading:
    /// mp4/mov badge non-H.264 codecs, mkv always shows its codec (codec-agnostic container),
    /// webm only badges a non-VP9 codec, m4a/ogg always show their audio codec. Plain extensions
    /// (H.264 mp4, mp3, png, ...) get no badge.
    var codecBadge: String? {
        if type.isVideo {
            let ext = (url ?? originalURL)?.filePath?.extension?.lowercased() ?? ""
            switch videoCodecType {
            case .some(.hevcVideo): return "HEVC"
            case .some(.av1Video): return "AV1"
            case .some(.webm): return ext == "webm" ? nil : "VP9"
            default: return nil
            }
        }
        return audioCodecName
    }

    /// Extension chip text: `mp4` or `mp4 · HEVC`.
    var formatChipText: String {
        let ext = url?.filePath?.extension ?? originalURL?.filePath?.extension ?? ""
        guard let badge = codecBadge else { return ext }
        return "\(ext) · \(badge)"
    }

    nonisolated static func == (lhs: Optimiser, rhs: Optimiser) -> Bool {
        lhs.id == rhs.id
    }

    /// `currentAudioFormat`, but only when a conversion is actually in effect (the result's format
    /// differs from `originalExtension`). Used as a `formatOverride` when re-encoding from the pristine
    /// original so recompressing a converted file keeps the converted format instead of reverting to the
    /// original's extension. Returns nil for a plain (non-converted) recompress so the pipeline resolves
    /// the format normally and still honours the user's file-placement preference (a non-nil
    /// `formatOverride` keeps the result pinned to the temp folder).
    func audioConversionFormat(originalExtension: String?) -> AudioFormat? {
        guard let cur = currentAudioFormat, let ext = originalExtension?.lowercased(),
              !ext.isEmpty, ext != cur.fileExtension
        else { return nil }
        return cur
    }

    /// The format a compression re-encode must keep so it doesn't revert a manual conversion:
    /// the Clop-set codec for video conversions, the current image format when it differs from the
    /// original file's. Mirrors the audio fix (`audioConversionFormat` recovers audio's format inside
    /// `executeTempPipeline`). `convertedFromURL` gates this to conversions Clop actually performed —
    /// ingest-detected codecs are informational and must not change what a re-encode produces.
    /// GIF→video-codec results are deliberately excluded: their pristine original is a GIF, which
    /// the temp pipeline's video branch can't re-encode from, so those keep today's behaviour.
    func stickyConversionFormat() -> String? {
        guard let source = convertedFromURL else { return nil }
        let sourceIsGIF = source.pathExtension.lowercased() == "gif"
        switch type {
        case .video(.hevcVideo) where !sourceIsGIF: return "hevc"
        case .video(.av1Video) where !sourceIsGIF: return "av1"
        case .video(.webm) where !sourceIsGIF: return "webm"
        case let .image(ut):
            guard let ext = ut.preferredFilenameExtension?.lowercased(),
                  let origExt = (originalURL ?? startingURL)?.pathExtension.lowercased(),
                  !origExt.isEmpty, origExt != ext
            else { return nil }
            return ext
        default: return nil
        }
    }

    /// Guarantee at least a placeholder thumbnail (the file's QuickLook / system icon) so a result never
    /// renders as an empty no-thumbnail card. No-op once a real thumbnail is set.
    @MainActor func ensurePlaceholderThumbnail() {
        guard thumbnail == nil, let fileURL = url ?? originalURL, fileURL.isFileURL, let filePath = fileURL.filePath else { return }
        thumbnail = Optimisable.fallbackThumbnail(for: fileURL, path: filePath)
    }

    /// Register/unregister this optimiser's `Progress` in the system-wide tree, unless this is a
    /// silent batch run. Centralising it here keeps every pipeline's publish/unpublish gated.
    func publishProgress() {
        guard !batchSilent else { return }
        progress.publish()
    }

    func unpublishProgress() {
        guard !batchSilent else { return }
        progress.unpublish()
    }

    /// Update the temp pipeline with a new user action.
    /// Same-type steps are replaced; new types are inserted at canonical position.
    /// optimise and convert are mutually exclusive.
    func updateTempPipeline(with step: PipelineStep) {
        guard var groupRange = findPrimaryEncodingGroup() else {
            // No encoding group exists yet, create one at the end
            tempPipeline.append(step)
            return
        }

        var group = Array(tempPipeline[groupRange])

        // Handle optimise/convert mutual exclusivity
        if step.stepName == "convert" {
            group.removeAll { $0.stepName == "optimise" }
        } else if step.stepName == "optimise" {
            group.removeAll { $0.stepName == "convert" }
        }

        // Replace existing step of same type, or insert new
        if let idx = group.firstIndex(where: { $0.stepName == step.stepName }) {
            group[idx] = step
        } else {
            group.append(step)
        }

        // Sort group into canonical order
        group.sort { canonicalOrder($0) < canonicalOrder($1) }

        // Replace group in the full pipeline
        tempPipeline.replaceSubrange(groupRange, with: group)
    }

    /// Remove a step by name from the primary encoding group.
    func removeTempPipelineStep(named name: String) {
        guard let groupRange = findPrimaryEncodingGroup() else { return }
        var group = Array(tempPipeline[groupRange])
        group.removeAll { $0.stepName == name }
        tempPipeline.replaceSubrange(groupRange, with: group)
    }

    /// Compile processing PipelineSteps into PipelineActions for runVideoPipeline/runImagePipeline.
    func compilePipelineActions(from steps: [PipelineStep]) -> [PipelineAction] {
        var actions: [PipelineAction] = []

        for step in steps {
            switch step {
            case let .downscale(factor, _):
                actions.append(.downscale(factor: factor, cropSize: nil))
            case let .crop(width, height, longEdge, _):
                let cs = CropSize(
                    width: longEdge ?? width ?? 0,
                    height: longEdge != nil ? (longEdge ?? 0) : (height ?? 0),
                    longEdge: longEdge != nil
                )
                actions.append(.downscale(factor: nil, cropSize: cs))
            case let .changeSpeed(factor):
                actions.append(.changePlaybackSpeed(factor: factor))
            case .removeAudio:
                actions.append(.removeAudio)
            case .optimise:
                actions.append(.optimise)
            case let .convert(formatStr, _):
                if let uttype = UTType(filenameExtension: formatStr) {
                    actions.append(.convert(format: uttype))
                }
            default:
                break
            }
        }

        // If no encoding step, add default optimise
        if !actions.contains(where: { $0.isOptimise || $0.isConvert }) {
            actions.append(.optimise)
        }

        return actions
    }

    /// Segment the temp pipeline into runs: consecutive encoding groups and individual non-processing steps.
    func segmentTempPipeline() -> [TempPipelineSegment] {
        var segments: [TempPipelineSegment] = []
        var currentGroup: [PipelineStep] = []

        for step in tempPipeline {
            if isEncodingGroupStep(step) {
                currentGroup.append(step)
            } else {
                if !currentGroup.isEmpty {
                    segments.append(.encodingGroup(currentGroup))
                    currentGroup = []
                }
                segments.append(.singleStep(step))
            }
        }
        if !currentGroup.isEmpty {
            segments.append(.encodingGroup(currentGroup))
        }

        return segments
    }

    /// Execute the full temp pipeline from the original/backup file.
    func executeTempPipeline() {
        guard !inRemoval, !tempPipeline.isEmpty else { return }

        stop(remove: false)
        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil

        // originalURL can point at the backup, which "Restore original" moves back
        // over the working file, so only trust it if the file still exists
        guard var originalFilePath = originalURL?.existingFilePath ?? path else { return }
        let backupPath = (originalFilePath.clopBackupPath?.exists ?? false)
            ? originalFilePath.clopBackupPath
            : convertedFromURL?.existingFilePath
        if !originalFilePath.exists, let backupPath {
            _ = try? backupPath.copy(to: originalFilePath)
        }
        if let templatedPath = templatedPathForManualOptimisation(originalFilePath) {
            originalFilePath = templatedPath
            url = templatedPath.url
            if type.isPDF, pdf != nil {
                pdf = PDF(templatedPath, thumb: !hidden)
            }
        }

        let segments = segmentTempPipeline()
        let optimiserSource = source ?? .cli
        let fileType = fileType ?? .image

        // Extract video encoder override from the pipeline
        let videoEncoderOverride: VideoEncoder? = tempPipeline.compactMap { step in
            if case let .optimise(_, _, ve, _, _) = step { return ve }
            return nil
        }.last

        Task {
            var currentFile = originalFilePath

            for segment in segments {
                if inRemoval { break }

                switch segment {
                case let .encodingGroup(steps):
                    let actions = compilePipelineActions(from: steps)

                    if type.isVideo {
                        let videoPath = self.path ?? currentFile
                        let video: Video? = if let oldSize {
                            Video(path: videoPath, metadata: VideoMetadata(resolution: oldSize, fps: 0, hasAudio: isVideoWithAudio), fileSize: oldBytes, thumb: false)
                        } else {
                            try? await Video.byFetchingMetadata(path: videoPath, fileSize: oldBytes, thumb: !hidden, id: self.id)
                        }

                        // Extract video codec encoder override from convert steps
                        var ffmpegEncoder: [String]?
                        var outExt: String?
                        for step in steps {
                            if case let .convert(fmt, _) = step, let conv = videoConversionArgs(format: fmt, cq: compressionOverride) {
                                ffmpegEncoder = conv.args
                                outExt = conv.outputExt == "mp4" ? "mp4" : conv.outputExt
                            }
                        }

                        if let video, let result = try? await runVideoPipeline(
                            video, actions: actions,
                            id: self.id,
                            originalPath: currentFile != videoPath ? currentFile : backupPath,
                            aggressiveOptimisation: aggressive ? true : nil,
                            videoEncoderOverride: videoEncoderOverride,
                            ffmpegEncoderOverride: ffmpegEncoder,
                            outputExtension: outExt
                        ) {
                            currentFile = result.path
                        }
                    } else if type.isImage, let image = Image(path: currentFile, retinaDownscaled: self.retinaDownscaled) {
                        let savePath = self.startingURL?.filePath ?? self.path
                        if let result = try? await runImagePipeline(
                            image, actions: actions,
                            id: self.id, saveTo: savePath,
                            copyToClipboard: id == IDs.clipboardImage,
                            aggressiveOptimisation: aggressive ? true : nil,
                            skipCache: true
                        ) {
                            currentFile = result.path
                            self.url = result.path.url
                            self.type = .image(result.type)
                            self.image = result
                        }
                    } else if type.isPDF, let pdf = self.pdf {
                        // Honour DPI from a temp-pipeline `optimise(dpi:)` step, otherwise fall back to the slider override.
                        let stepDPI: Int? = steps.compactMap { if case let .optimise(_, _, _, d, _) = $0 { return d }; return nil }.last
                        if let result = try? await runPDFPipeline(
                            pdf, actions: actions,
                            id: self.id,
                            aggressiveOptimisation: aggressive ? true : nil,
                            dpiOverride: stepDPI ?? self.pdfDPIOverride
                        ) {
                            currentFile = result.path
                        }
                    } else if type.isAudio {
                        let audio = await (try? Audio.byFetchingMetadata(path: currentFile, thumb: !hidden)) ?? Audio(path: currentFile, thumb: !hidden)

                        // Resolve the target format: an explicit `.convert` step wins, otherwise keep the
                        // format the result is already in. Without this, recompressing a converted file
                        // (e.g. after wav→m4a) would resolve the output format from the original's
                        // extension and silently revert the conversion back to the original format.
                        let convertFormat: AudioFormat? = actions.compactMap { action in
                            if case let .convert(format) = action { return AudioFormat.allCases.first { $0.utType == format } }
                            return nil
                        }.first
                        let targetFormat = convertFormat ?? audioConversionFormat(originalExtension: originalFilePath.extension)

                        // Bitrate-reduction steps in the temp pipeline override the UI's bitrate override.
                        var stepBitrate: Int?
                        for step in steps {
                            switch step {
                            case let .lowerBitrate(kbps, _):
                                if let clamped = audio.loweredBitrate(kbps: kbps) { stepBitrate = clamped }
                            case let .downscale(factor, _):
                                if stepBitrate == nil, let clamped = audio.loweredBitrate(factor: factor) { stepBitrate = clamped }
                            default: break
                            }
                        }

                        // Format change and plain recompress both re-encode from the pristine original
                        // through the same off-main pass, so a conversion shows progress and honours the
                        // compression/bitrate override (`Audio.optimise` reads `formatOverride` +
                        // `compressionOverride`), instead of blocking the main actor and ignoring both.
                        if let result = try? await runAudioPipeline(
                            audio, actions: [.optimise],
                            id: self.id,
                            allowLarger: true,
                            hideFloatingResult: hidden,
                            bitrateOverride: stepBitrate ?? self.audioBitrateOverride,
                            aggressiveOptimisation: aggressive ? true : nil,
                            formatOverride: targetFormat,
                            operationOverride: convertFormat != nil ? "Converting to \(targetFormat?.name ?? "audio")" : nil
                        ) {
                            currentFile = result.path
                            self.audio = result
                            self.url = result.path.url
                            if let ut = targetFormat?.utType {
                                self.type = .audio(ut)
                            }
                        }
                    }

                case let .singleStep(step):
                    let singlePipeline = Pipeline(steps: [step])
                    if let (resultFile, _, _) = try? await executePipeline(
                        singlePipeline, file: currentFile,
                        source: optimiserSource,
                        optimiser: self,
                        fileType: fileType
                    ) {
                        currentFile = resultFile
                    }
                }
            }
        }
    }

    func convert(to type: UTType, optimise: Bool = false, additive: Bool = false) {
        guard !isPreview else { return }
        // Also refuse converting to the codec the file already has (`videoCodecType` is nil for
        // non-videos and unknown codecs, and nil never equals a non-optional `type`, so this only
        // blocks real same-codec re-encodes): a detected-HEVC mp4 must not re-encode HEVC→HEVC.
        guard type != self.type.utType, type != videoCodecType else { return }
        // Keep-only-last: remember the prior converted output so the next successful conversion can delete
        // it. Skipped when additive (Option-click), so both formats are kept side by side.
        supersededConvertURL = additive ? nil : previousManualConvertOutput()
        let typeStr = type.preferredFilenameExtension ?? type.identifier

        // Use temp pipeline when initial optimisation has completed, to always
        // convert from the original file and avoid double-encoding quality loss.
        // Animated GIF -> video conversions bypass it: the temp pipeline routes a GIF
        // (type.isImage) through the image pipeline, which cannot emit video.
        if !tempPipeline.isEmpty, !(self.type.isVideo && type == .gif), !(isAnimatedGIF && convertibleTypes.contains(type)) {
            // If converting back to the original format, drop convert and restore optimise
            let originalExt = originalURL?.pathExtension.lowercased() ?? startingURL?.pathExtension.lowercased()
            if let originalExt, originalExt == typeStr.lowercased() {
                removeTempPipelineStep(named: "convert")

                // For audio, restore original file directly instead of re-encoding
                if self.type.isAudio, !tempPipeline.contains(where: \.isProcessingStep),
                   let origPath = (originalURL ?? startingURL)?.filePath, origPath.exists
                {
                    stop(remove: false)
                    stopRemover()
                    Task {
                        let audio = await (try? Audio.byFetchingMetadata(path: origPath, thumb: !hidden)) ?? Audio(path: origPath, thumb: !hidden)
                        self.audio = audio
                        if let ext = origPath.extension, let audioFmt = AudioFormat.allCases.first(where: { $0.fileExtension == ext })?.utType {
                            self.type = .audio(audioFmt)
                        }
                        self.url = origPath.url
                        self.isOriginal = true
                        self.error = nil
                        self.notice = nil
                        self.info = nil
                        self.finish(oldBytes: self.oldBytes, newBytes: origPath.fileSize() ?? self.oldBytes, removeAfterMs: self.lastRemoveAfterMs)
                    }
                    return
                }

                if !tempPipeline.contains(where: { $0.stepName == "optimise" }) {
                    updateTempPipeline(with: .optimise())
                }
            } else {
                updateTempPipeline(with: .convert(to: typeStr))
            }
            executeTempPipeline()
            return
        }

        operation = "Converting to \(typeStr)"
        progress = Progress()
        progress.localizedAdditionalDescription = ""
        progress.completedUnitCount = 0
        running = true
        isOriginal = false

        // Animated GIFs convert to real video formats via ffmpeg, preserving every frame.
        // They stay typed as .image(.gif), so route them explicitly instead of through the
        // image branch below (Image.convert cannot produce video).
        if isAnimatedGIF, convertibleTypes.contains(type), let url {
            convertToVideoFormat(Video(path: FilePath(url.path)), to: type)
            return
        }

        switch self.type {
        case .image:
            guard let image else {
                return
            }
            imageOptimisationQueue.addOperation { [weak self] in
                guard let converted = try? image.convert(to: type, asTempFile: true, optimiser: optimise ? self : nil) else {
                    mainActor {
                        guard let self else { return }
                        self.finish(error: "\(typeStr) conversion failed")
                    }
                    return
                }
                mainActor {
                    guard let self else { return }
                    let originalFilePath = (self.startingURL ?? self.originalURL ?? self.url)?.filePath ?? converted.path
                    let placed = try? placeOutput(produced: converted.path, original: originalFilePath, type: .image, kind: .manualConvert, overrides: self.placementOverride)
                    let finalImage = placed.flatMap { p in p.path != converted.path ? try? converted.copyWithPath(p.path) : converted } ?? converted
                    if self.convertedFromURL == nil {
                        self.convertedFromURL = self.url
                    }
                    self.image = finalImage
                    self.type = .image(finalImage.type)
                    self.url = finalImage.path.url
                    self.error = nil
                    self.notice = nil
                    self.info = nil
                    self.finish(oldBytes: self.oldBytes, newBytes: finalImage.data.count, oldSize: self.oldSize, newSize: finalImage.size, removeAfterMs: self.lastRemoveAfterMs)
                }
            }
        case .audio:
            // Route through temp pipeline to always convert from the original file
            // and avoid double-encoding quality loss on subsequent format changes
            if originalURL == nil {
                originalURL = url
            }
            updateTempPipeline(with: .convert(to: typeStr))
            executeTempPipeline()
        case .video:
            guard let url else { return }
            let video = Video(path: FilePath(url.path))

            if type == .gif {
                DispatchQueue.global().async { [weak self] in
                    guard let self else { return }
                    guard let result = try? video.convertToGIF(optimiser: self, maxWidth: 960, fps: 15) else {
                        mainActor { self.finish(error: "GIF conversion failed") }
                        return
                    }
                    mainActor {
                        if self.convertedFromURL == nil { self.convertedFromURL = self.url }
                        self.type = .image(.gif)
                        // The GIF replaced the video, so a codec detected on the source must not
                        // linger (it would grey out that codec's convert target for the GIF).
                        self.detectedVideoCodec = nil
                        self.url = result.path.url
                        self.error = nil
                        self.notice = nil
                        self.tempPipeline = []
                        self.automationPipeline = nil
                        self.finish(oldBytes: self.oldBytes, newBytes: result.data.count, removeAfterMs: self.lastRemoveAfterMs)
                    }
                }
            } else {
                convertToVideoFormat(video, to: type)
            }
        default:
            break
        }
    }

    func compare() {
        if let window = comparisonWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            focus()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: COMPARISON_VIEW_SIZE * 2 + 100, height: COMPARISON_VIEW_SIZE + 200),
            styleMask: [.fullSizeContentView, .titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Comparison: \(filename)"
        window.identifier = COMPARISON_WINDOW_IDENTIFIER
        // The window controller owns the window; releasing on close too would double-release.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: COMPARISON_VIEW_SIZE + 100, height: COMPARISON_VIEW_SIZE / 2 + 200)

        window.contentView = NSHostingView(
            rootView: CompareView(optimiser: self)
                .frame(
                    minWidth: COMPARISON_VIEW_SIZE + 100, idealWidth: COMPARISON_VIEW_SIZE * 2 + 100,
                    minHeight: COMPARISON_VIEW_SIZE / 2 + 200, idealHeight: COMPARISON_VIEW_SIZE + 200
                )
                .padding()
                .background(.regularMaterial)
        )
        window.backgroundColor = .clear

        window.setFrameAutosaveName("Compare Window")
        if !window.setFrameUsingName("Compare Window") {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        focus()

        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)

        comparisonWindowController = NSWindowController(window: window)
        isComparing = true
    }

    @objc func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: notification.object)
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
            refreshImageThumbnail()
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
            refreshImageThumbnail()
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

    /// Refresh the floating-result thumbnail from the current image file.
    /// `Image` is not an `Optimisable`, so re-fetching it never regenerates the card
    /// thumbnail the way video/pdf/audio do (they pass `thumb:`). Without this, a crop
    /// or downscale that changes the pixels leaves the card showing the original,
    /// un-cropped preview.
    func refreshImageThumbnail() {
        guard !hidden, let newThumbnail = image?.image else { return }
        thumbnail = newThumbnail
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
        guard !isPreview else { return }
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
        convertibleTypes.isNotEmpty
    }

    func canReoptimise() -> Bool {
        switch type {
        case .image(.png), .image(.jpeg), .image(.gif), .video(.mpeg4Movie), .video(.quickTimeMovie), .pdf:
            true
        case .audio:
            true
        default:
            false
        }
    }

    func canDownscale() -> Bool {
        // Downscaling works for any raster image (webp/heic/avif/tiff/jxl included, not just
        // png/jpeg/gif), any video, plus PDF (DPI) and audio (bitrate). Whitelisting only a few
        // formats made the button look disabled for files that downscale just fine.
        type.isImage || type.isVideo || type.isPDF || type.isAudio
    }

    /// Compression applies to any image/video (a re-encode), and to audio only when the output
    /// format has a bitrate axis (lossless WAV/FLAC/AIFF have none, so it would be a no-op).
    func canCompress() -> Bool {
        if type.isImage || type.isVideo { return true }
        guard type.isAudio else { return false }
        let ext = (url ?? originalURL)?.filePath?.extension ?? ""
        return audioFormat.bitrateRange != nil
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
        (type.isVideo || type.isAudio) && !inRemoval
    }

    func canRemoveAudio() -> Bool {
        type.isVideo && !inRemoval && isVideoWithAudio
    }

    func removeAudio() {
        guard !inRemoval, !SWIFTUI_PREVIEW, !isPreview else { return }

        if !tempPipeline.isEmpty {
            updateTempPipeline(with: .removeAudio)
            executeTempPipeline()
            return
        }

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
            isVideoWithAudio = false
            progress.completedUnitCount = progress.totalUnitCount
            finish(oldBytes: oldBytes, newBytes: path.fileSize() ?? newBytes)
        }
    }

    func changePlaybackSpeed(byFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) {
        guard !inRemoval, !SWIFTUI_PREVIEW, !isPreview else { return }

        let effectiveFactor = factor ?? changePlaybackSpeedFactor
        changePlaybackSpeedFactor = effectiveFactor

        if !tempPipeline.isEmpty {
            if let aggressiveOptimisation { aggressive = aggressiveOptimisation }
            if effectiveFactor == 1.0 {
                removeTempPipelineStep(named: "changeSpeed")
            } else {
                updateTempPipeline(with: .changeSpeed(factor: effectiveFactor))
            }
            executeTempPipeline()
            return
        }

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

        if type.isAudio {
            // Audio speed runs off the pristine backup when we still have it, so factors stay
            // absolute (1.5x then 2x means 2x of the original, not 3x), matching the menu.
            running = true
            operation = effectiveFactor == 1.0 ? "Restoring speed" : "Changing speed to \(effectiveFactor)x"
            let oldBytes = oldBytes
            let speedSource = (path.clopBackupPath?.exists ?? false) ? path.clopBackupPath! : path
            let optimiser = self
            audioOptimisationQueue.addOperation {
                let audio = Audio(speedSource)
                guard let changed = try? audio.changeSpeed(factor: effectiveFactor, optimiser: optimiser), changed.path.exists else {
                    mainActor { optimiser.running = false; optimiser.overlayMessage = "Speed change failed" }
                    return
                }
                let finalPath: FilePath = (changed.path.dir == FilePath.audios && changed.path != path)
                    ? ((try? changed.path.move(to: path, force: true)) ?? changed.path)
                    : changed.path
                mainActor {
                    optimiser.url = finalPath.url
                    optimiser.finish(oldBytes: oldBytes, newBytes: finalPath.fileSize() ?? oldBytes)
                }
            }
            return
        }

        let originalPath = (path.clopBackupPath?.exists ?? false) ? path.clopBackupPath : convertedFromURL?.existingFilePath
        if !path.exists, let originalPath {
            _ = try? originalPath.copy(to: path)
        }

        Task {
            let videoPath = self.path ?? path
            guard let video = try await Video.byFetchingMetadata(path: videoPath, fileSize: oldBytes, id: self.id) else {
                return
            }

            _ = try? await runVideoPipeline(
                video,
                actions: [.changePlaybackSpeed(factor: effectiveFactor)],
                id: self.id,
                originalPath: path != videoPath ? path : originalPath,
                hideFloatingResult: hideFloatingResult,
                aggressiveOptimisation: shouldUseAggressiveOptimisation
            )
        }
    }

    func stepDownscale() {
        guard !isPreview else { return }
        stopRemover()
        guard downscaleFactor > 0.1 else { return }

        let newFactor = max(downscaleFactor > 0.5 ? downscaleFactor - 0.25 : downscaleFactor - 0.1, 0.1)
        downscaleFactor = newFactor
        stepIndicator = "\((newFactor * 100).intround)%"

        downscaleDebounceTask?.cancel()
        downscaleDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            stepIndicator = ""
            downscale(toFactor: newFactor)
        }
    }

    func stepLowerPDFDPI() {
        guard !isPreview else { return }
        stopRemover()
        guard type.isPDF else { return }

        let stops = PDF_DPI_STOPS
        let currentDPI = pdfDPIOverride ?? effectiveBasePDFDPI

        guard let currentIndex = stops.firstIndex(where: { $0 <= currentDPI }) ?? stops.indices.last else { return }
        let nextIndex = currentIndex + 1
        guard nextIndex < stops.count else { return }

        let newDPI = stops[nextIndex]
        pdfDPIOverride = newDPI
        stepIndicator = "\(newDPI) DPI"

        pdfDPIDebounceTask?.cancel()
        pdfDPIDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            stepIndicator = ""
            lowerPDFDPI(to: newDPI)
        }
    }

    func stepLowerBitrate() {
        guard !isPreview else { return }
        stopRemover()
        guard type.isAudio else { return }

        let bitrates = audioFormat.allowedBitrates
        let currentBitrate = audioBitrateOverride ?? Defaults[.audioBitrate]

        guard let currentIndex = bitrates.firstIndex(of: currentBitrate) else { return }
        let nextIndex = currentIndex - 1
        guard nextIndex >= 0 else { return }

        let newBitrate = bitrates[nextIndex]
        audioBitrateOverride = newBitrate
        stepIndicator = "\(newBitrate) kbps"

        lowerBitrateDebounceTask?.cancel()
        lowerBitrateDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            stepIndicator = ""
            lowerBitrate(to: newBitrate)
        }
    }

    func lowerPDFDPI(to dpi: Int) {
        guard !inRemoval, !isPreview, type.isPDF else { return }

        pdfDPIOverride = dpi

        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil

        guard let path = originalURL?.filePath ?? path else { return }

        Task {
            let pdf = PDF(path)
            _ = try? await runPDFPipeline(
                pdf,
                actions: [.optimise],
                id: self.id,
                allowLarger: true,
                hideFloatingResult: hidden,
                aggressiveOptimisation: aggressive ? true : nil,
                dpiOverride: dpi,
                source: source
            )
        }
    }

    /// Re-encode the audio normalising its loudness to `lufs` (EBU R128 two-pass loudnorm),
    /// reusing the audio optimise pipeline's `loudnormTarget`.
    func normalizeAudioLoudness(lufs: Double) {
        guard !inRemoval, !isPreview, type.isAudio else { return }

        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil

        guard let path = originalURL?.filePath ?? path else { return }

        // Re-encode from the original but keep the converted format (if any) so loudness normalisation
        // doesn't revert a wav→m4a conversion. Only force the format for an actual conversion so a plain
        // normalise still gets the user's file placement.
        let targetFormat = audioConversionFormat(originalExtension: path.extension)
        Task {
            let audio = await (try? Audio.byFetchingMetadata(path: path, thumb: !hidden)) ?? Audio(path: path, thumb: !hidden)
            _ = try? await runAudioPipeline(
                audio,
                actions: [.optimise],
                id: self.id,
                allowLarger: true,
                hideFloatingResult: hidden,
                source: source,
                formatOverride: targetFormat,
                loudnormTarget: lufs
            )
        }
    }

    func lowerBitrate(to bitrate: Int) {
        guard !inRemoval, !isPreview, type.isAudio else { return }

        audioBitrateOverride = bitrate

        stopRemover()
        isOriginal = false
        error = nil
        notice = nil
        info = nil

        guard let path = originalURL?.filePath ?? path else { return }

        // Re-encode from the original but keep the converted format (if any) so a bitrate change
        // doesn't revert a wav→m4a conversion back to wav. Only force the format for an actual
        // conversion so a plain bitrate change still gets the user's file placement.
        let targetFormat = audioConversionFormat(originalExtension: path.extension)
        Task {
            let audio = await (try? Audio.byFetchingMetadata(path: path, thumb: !hidden)) ?? Audio(path: path, thumb: !hidden)
            _ = try? await runAudioPipeline(
                audio,
                actions: [.optimise],
                id: self.id,
                allowLarger: true,
                hideFloatingResult: hidden,
                source: source,
                bitrateOverride: bitrate,
                formatOverride: targetFormat,
                operationOverride: "Lowering bitrate to \(bitrate) kbps"
            )
        }
    }

    func downscale(toFactor factor: Double? = nil, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) {
        guard !inRemoval, !isPreview else { return }

        let effectiveFactor = factor ?? downscaleFactor
        if let factor { downscaleFactor = factor }

        if !tempPipeline.isEmpty {
            if let aggressiveOptimisation { aggressive = aggressiveOptimisation }
            if effectiveFactor >= 1.0 {
                removeTempPipelineStep(named: "downscale")
            } else {
                updateTempPipeline(with: .downscale(factor: effectiveFactor))
            }
            executeTempPipeline()
            return
        }

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
            _ = try? originalPath.copy(to: path)
        }

        Task {
            if type.isImage, let image = Image(path: path, retinaDownscaled: self.retinaDownscaled) {
                if !hidden, thumbnail == nil {
                    thumbnail = image.image
                }
                let _ = try? await runImagePipeline(
                    image, actions: [.downscale(factor: effectiveFactor, cropSize: nil)],
                    id: self.id, saveTo: self.path,
                    copyToClipboard: id == IDs.clipboardImage,
                    hideFloatingResult: hideFloatingResult,
                    aggressiveOptimisation: shouldUseAggressiveOptimisation
                )
            }
            if type.isVideo {
                let videoPath = self.path ?? path
                let video = if let oldSize {
                    Video(path: videoPath, metadata: VideoMetadata(resolution: oldSize, fps: 0, hasAudio: isVideoWithAudio), fileSize: oldBytes, thumb: false)
                } else {
                    try? await Video.byFetchingMetadata(path: videoPath, fileSize: oldBytes, thumb: !hidden, id: self.id)
                }
                guard let video else { return }

                _ = try? await runVideoPipeline(
                    video,
                    actions: [.downscale(factor: effectiveFactor, cropSize: nil)],
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
            // stop() is always an explicit termination (swipe, close button, cancellation),
            // so the removal must go through even while another result is hovered.
            // animateRemoval gates BOTH the short slide-out delay and the inRemoval slide
            // itself: with it off the result is dropped on the next tick (just the fade
            // from the list removal), so a close-button press feels instant instead of
            // sliding 500px off-screen first. The delay is kept short so the gap starts
            // closing (the results above falling in) while the dismissed result is still
            // sliding/fading out, rather than after it has fully gone.
            let animate = animateRemoval && !OM.compactResults
            self.remove(after: animate ? 60 : 0, withAnimation: animate, force: true)
        }
    }

    func reoptimise() {
        guard !isPreview else { return }
        try? (path ?? url?.filePath)?.removeOptimisationStatusXattr()
        if !tempPipeline.isEmpty {
            executeTempPipeline()
            return
        }
        optimise()
    }

    func reoptimiseWithEncoder(_ encoder: VideoEncoder) {
        guard !isPreview else { return }
        Defaults[.videoEncoder] = encoder
        // Keep the unified value (the real source of truth for the encode) in sync with the legacy encoder.
        Defaults[.videoCompression] = videoEncoderToCQ(encoder)
        try? (path ?? url?.filePath)?.removeOptimisationStatusXattr()
        if !tempPipeline.isEmpty {
            updateTempPipeline(with: .optimise(videoEncoder: encoder))
            executeTempPipeline()
            return
        }
        optimise(fromOriginal: true)
    }

    /// Re-run optimisation for this result with a per-result compression value (the draggable
    /// compression button). The override is read by the image/video encode paths at encode time.
    func reoptimise(compression cq: CompressionQuality) {
        guard !inRemoval, !isPreview else { return }
        compressionOverride = cq
        // Compile the per-result operations into the temp pipeline so they always re-run from the
        // pristine original in a single pass (optimise [+ downscale]) instead of stacking encodes on
        // top of the previous result. The image/video pipelines read `compressionOverride` for the
        // factor; the downscale step carries the current resize.
        // A converted result must stay converted: put the conversion (not a plain optimise, which
        // would evict it — optimise/convert are mutually exclusive in the encoding group) into the
        // pipeline, so the re-run re-encodes from the pristine original in the current codec/format
        // with the new factor.
        if tempPipeline.contains(where: { $0.stepName == "convert" }) {
            // A convert step already in the pipeline re-runs with the new `compressionOverride`;
            // adding a plain optimise would evict it (optimise/convert are mutually exclusive).
        } else if let fmt = stickyConversionFormat() {
            updateTempPipeline(with: .convert(to: fmt))
        } else {
            updateTempPipeline(with: .optimise())
        }
        if downscaleFactor < 1 {
            updateTempPipeline(with: .downscale(factor: downscaleFactor))
        } else {
            removeTempPipelineStep(named: "downscale")
        }
        executeTempPipeline()
    }

    /// Copy `path` to the location dictated by the optimised-file location setting
    /// (e.g. "Same folder" with `%f-opt`) so manual re-optimisations land in the same
    /// place as first-time ones. Returns nil for files already at the templated
    /// location, converted results and Clop-internal files, which stay where they are.
    func templatedPathForManualOptimisation(_ path: FilePath) -> FilePath? {
        guard let fileType, convertedFromURL == nil,
              !path.starts(with: FilePath.workdir),
              !isAlreadyTemplatedPath(type: fileType, path: path),
              let templatedPath = try? getTemplatedPath(type: fileType, path: path),
              templatedPath != path
        else { return nil }
        return try? path.copy(to: templatedPath, force: true)
    }

    func optimise(allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil, fromOriginal: Bool = false) {
        guard !isPreview, let url, var path = url.filePath else { return }
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
        if let templatedPath = templatedPathForManualOptimisation(path) {
            path = templatedPath
            self.url = path.url
        }

        isOriginal = false
        var shouldUseAggressiveOptimisation = aggressiveOptimisation
        if let aggressiveOptimisation {
            aggressive = aggressiveOptimisation
        } else if aggressive {
            shouldUseAggressiveOptimisation = true
        }
        if type.isImage, let img = Image(path: path, retinaDownscaled: retinaDownscaled) {
            Task { try? await runImagePipeline(img, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation) }
            return
        }
        if type.isVideo, path.exists {
            Task {
                let video = if let oldSize {
                    Video(path: path, metadata: VideoMetadata(resolution: oldSize, fps: 0, hasAudio: isVideoWithAudio), fileSize: oldBytes, thumb: false)
                } else {
                    try? await Video.byFetchingMetadata(path: path, fileSize: oldBytes, id: id)
                }
                guard let video else { return }
                _ = try? await runVideoPipeline(video, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation)
            }
        }
        if type.isPDF, path.exists, let pdf {
            Task { try? await runPDFPipeline(pdf, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation) }
        }
        if type.isAudio, path.exists {
            Task {
                let aud = await (try? Audio.byFetchingMetadata(path: path, fileSize: oldBytes, id: id)) ?? Audio(path: path, id: id)
                _ = try? await runAudioPipeline(aud, actions: [.optimise], id: id, allowLarger: allowLarger, hideFloatingResult: hideFloatingResult, aggressiveOptimisation: shouldUseAggressiveOptimisation)
            }
        }
    }

    func restoreOriginal() {
        guard !isPreview, let url, var path = url.filePath else { return }
        scalingFactor = 1.0
        downscaleFactor = 1.0
        coverDownscaleFactor = 1.0
        changePlaybackSpeedFactor = 1.0
        lastCropSize = nil
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
        oldBytes = path.fileSize() ?? oldBytes
        newBytes = -1
        newSize = nil
        // Clear the optimised-vs-original deltas so audio/PDF results stop showing the stale
        // "183kbps → 160kbps" / DPI comparison after the original is restored.
        newBitrate = nil
        newDPI = nil
        // Re-derive the type from the RESTORED file's own extension rather than preserving the prior
        // category, so a cross-media conversion reverts correctly in both directions: a GIF produced
        // from a video comes back as .video, and a video produced from an animated GIF comes back as
        // .image(.gif).
        if let utType = path.url.utType() {
            type = if path.isVideo {
                .video(utType)
            } else if path.isAudio {
                .audio(utType)
            } else if path.isPDF {
                .pdf
            } else if path.isImage {
                .image(utType)
            } else {
                type
            }
        }
        if type.isImage, let image = Image(path: path, retinaDownscaled: retinaDownscaled), id == IDs.clipboardImage {
            image.copyToClipboard()
        }
        isOriginal = true
        tempPipeline = []
        automationPipeline = nil
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// The result's current file if it still exists on disk; otherwise flash a clear "File not found"
    /// overlay and return nil, so an action on a moved or deleted result fails loudly instead of silently
    /// doing nothing (a result can outlive its file, e.g. a cached image whose working copy was moved away).
    @discardableResult
    func existingFileOrNotify() -> FilePath? {
        if let p = (url ?? originalURL)?.existingFilePath { return p }
        overlayMessage = "File not found"
        return nil
    }

    func copyToClipboard(withPath: Bool? = nil) {
        guard existingFileOrNotify() != nil, let url, let path else { return }
        if type.isImage, let image = Image(path: path, retinaDownscaled: retinaDownscaled) {
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
        guard existingFileOrNotify() != nil, let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func save() {
        guard existingFileOrNotify() != nil, let url, let path = url.existingFilePath else { return }

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
        supersededConvertURL = nil // conversion failed: keep the previous output
        self.error = error
        self.notice = notice
        self.running = false
        // Batch runs read results straight off the optimiser and own its lifetime; they never touch
        // the floating-result removal machinery (which would reassign OM.optimisers and churn the UI).
        if batchSilent { return }
        removeDebouncer()

        guard !OM.compactResults else { return }
        remove(after: removeAfterMs)
    }

    func finish(notice: String) {
        supersededConvertURL = nil
        self.notice = notice
        self.running = false
        removeDebouncer()

        remove(after: 2500)
    }

    /// Capture the failing process's command line and output, then finish with a generic error.
    func finish(processError proc: Process) {
        errorLog = "\(proc.commandLine)\n\nExit code: \(proc.terminationStatus)\n\nSTDERR:\n\(proc.err)\n\nSTDOUT:\n\(proc.out)"
        finish(error: "Optimisation failed")
    }

    func finish(oldBytes: Int, newBytes: Int, oldSize: CGSize? = nil, newSize: CGSize? = nil, oldBitrate: Int? = nil, newBitrate: Int? = nil, removeAfterMs: Int? = nil) {
        // Keep-only-last: now that the new conversion has produced its output, delete the previous one.
        removeSupersededConvertOutput()
        // Batch runs read results straight off the optimiser; just record them and stop, without the
        // animation/removal machinery (which would reassign OM.optimisers and churn the UI per file).
        if batchSilent {
            self.oldBytes = oldBytes
            self.newBytes = newBytes
            if let oldSize { self.oldSize = oldSize }
            if let newSize { self.newSize = newSize }
            if let oldBitrate { self.oldBitrate = oldBitrate }
            if let newBitrate { self.newBitrate = newBitrate }
            running = false
            return
        }
        guard !inRemoval else { return }
        stopRemover()
        withAnimation(.easeOut(duration: 0.5)) {
            self.oldBytes = oldBytes
            self.newBytes = newBytes
            if let oldSize { self.oldSize = oldSize }
            if let newSize { self.newSize = newSize }
            if let oldBitrate { self.oldBitrate = oldBitrate }
            if let newBitrate { self.newBitrate = newBitrate }
            self.running = false
        }
        removeDebouncer()

        guard !hidden else {
            remove(after: removeAfterMs ?? 2500)
            return
        }

        guard let removeAfterMs, removeAfterMs > 0, !OM.compactResults else { return }

        remove(after: removeAfterMs)
    }

    func stopRemover() {
        guard !hidden else { return }

        remover = nil
        inRemoval = false
        lastRemoveAfterMs = nil
        OM.remover = nil
        OM.lastRemoveAfterMs = nil
    }

    func resetRemover() {
        guard !hidden, !inRemoval, remover != nil, let lastRemoveAfterMs else {
            return
        }

        remove(after: lastRemoveAfterMs)
    }

    func bringBack() {
        stopRemover()
        dismissing = false
        OM.optimisers = OM.optimisers.with(self)
    }

    func crop(to size: CropSize) {
        guard !isPreview, let url, url.isFileURL, url.filePath?.exists ?? false else { return }
        lastCropSize = size.cropRect == nil ? nil : size

        // pipeline crop steps can't represent arbitrary rects, those go through optimiseItem directly
        if !tempPipeline.isEmpty, size.cropRect == nil {
            updateTempPipeline(with: .crop(
                width: size.width.i, height: size.height.i,
                longEdge: size.longEdge ? max(size.width.i, size.height.i) : nil
            ))
            executeTempPipeline()
            return
        }

        let clip = ClipboardType.fromURL(url)

        Task {
            // re-crops run from the pristine original: make sure it's reachable at the
            // backup path the pipelines resolve, even after in-place changes renamed it
            if size.cropRect != nil, let path = self.url?.filePath, let backup = path.clopBackupPath, !backup.exists,
               let original = self.cropOriginalURL?.filePath
            {
                try? original.copy(to: backup)
            }
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

    func remove(after ms: Int, withAnimation: Bool = false, force: Bool = false) {
        guard !inRemoval, !SWIFTUI_PREVIEW, !SM.selecting, !SHARING_MANAGER.isShowingPicker, !sharing else { return }

        lastRemoveAfterMs = ms
        remover = mainAsyncAfter(ms: ms) { [weak self] in
            guard let self else { return }
            guard !hidden else {
                OM.optimisers = OM.optimisers.filter { $0.id != self.id }
                OM.removedOptimisers = OM.removedOptimisers.filter { $0.id != self.id && !$0.hidden && !$0.isPreview }
                removeDebouncer()
                return
            }

            // The hover deferral below is meant for auto-hide timers, where removal should wait
            // while the user interacts with the results. Explicit dismissals (swipe, stop/close
            // button) pass force=true: deferring those would set inRemoval=false and slide the
            // already-dismissed result back into view when another result is hovered.
            guard force || (hoveredOptimiserID == nil && !DM.dragging && !editingFilename && !SM.selecting && !SHARING_MANAGER.isShowingPicker && !sharing) else {
                if editingFilename, let lastRemoveAfterMs, lastRemoveAfterMs < 1000 * 120 {
                    self.lastRemoveAfterMs = 1000 * 120
                }
                inRemoval = false
                resetRemover()
                return
            }
            editingFilename = false
            // Suppress the floating cards' hover overlay while the gap closes, so a card sliding under a
            // stationary cursor mid-drop doesn't pop its controls and interfere with the fall.
            OM.markRemovalAnimating()
            // Honour the withAnimation flag: a forced button dismissal (withAnimation: false)
            // drops the result on the spot; swipe/clear-all (withAnimation: true) keep the fade.
            if withAnimation {
                // The results above the freed slot snap down into the gap.
                SwiftUI.withAnimation(resultFallAnimation) {
                    OM.optimisers = OM.optimisers.filter { $0.id != self.id }
                }
            } else {
                OM.optimisers = OM.optimisers.filter { $0.id != self.id }
            }
            if url != nil {
                OM.removedOptimisers = OM.removedOptimisers.without(self).with(self).filter { !$0.hidden && !$0.isPreview }

                deleter = mainAsyncAfter(ms: 600_000) { [weak self] in
                    guard let self else { return }

                    if OM.removedOptimisers.contains(self) {
                        OM.removedOptimisers = OM.removedOptimisers.without(self)
                    }
                }
            }
        }

        if withAnimation, force || (hoveredOptimiserID == nil && !DM.dragging) {
            inRemoval = true
        }
    }

    /// Memoised animated-GIF check, keyed by the url it was computed for. Cleared whenever url changes
    /// (e.g. after a video->gif conversion) so a freshly produced GIF is re-probed.
    private var animatedGIFCache: (url: URL, value: Bool)?

    /// The current file when it is a Clop-produced conversion output that persists alongside the original
    /// (same/specific-folder placement) — i.e. the prior format to remove on the next keep-only-last
    /// convert. Returns nil for the original/source file or for in-place/temporary placements.
    private func previousManualConvertOutput() -> URL? {
        guard let current = url, let currentPath = current.filePath, currentPath.exists else { return nil }
        let sources = [originalURL, startingURL, convertedFromURL].compactMap { $0 }
        guard !sources.contains(current) else { return nil }
        let behaviour: FileBehaviour
        if type.isImage { behaviour = Defaults[.manualConvertedImageBehaviour] }
        else if type.isVideo { behaviour = Defaults[.manualConvertedVideoBehaviour] }
        else if type.isAudio { behaviour = Defaults[.manualConvertedAudioBehaviour] }
        else { return nil }
        guard behaviour == .sameFolder || behaviour == .specificFolder else { return nil }
        return current
    }

    /// Delete the previous conversion output after the new one has succeeded (keep-only-last). It's a
    /// Clop-produced intermediate, so it's removed outright rather than sent to Trash (which would pile
    /// up); guarded so it never removes the file just produced nor the original/source.
    private func removeSupersededConvertOutput() {
        guard let oldURL = supersededConvertURL else { return }
        supersededConvertURL = nil
        guard oldURL != url else { return }
        let sources = [originalURL, startingURL, convertedFromURL].compactMap { $0 }
        guard !sources.contains(oldURL), let oldPath = oldURL.filePath, oldPath.exists else { return }
        try? fm.removeItem(at: oldURL)
    }

    /// Re-encode `video` into a different video container/codec via ffmpeg. Works for real videos and
    /// for animated GIFs used as video input (ffmpeg preserves every frame). Runs off the main thread,
    /// updates the optimiser on completion, and records the source url so "Restore original" can revert.
    private func convertToVideoFormat(_ video: Video, to type: UTType) {
        let isCodecConversion = type == .hevcVideo || type == .av1Video || type == .webm
        let formatKey: String? = switch type {
        case .hevcVideo: "hevc"
        case .av1Video: "av1"
        case .webm: "webm"
        default: nil
        }
        let conversion = formatKey.flatMap { videoConversionArgs(format: $0, cq: compressionOverride) }
        let encoderOverride = conversion?.args
        let forceMP4 = conversion?.outputExt == "mp4" || type == .mpeg4Movie
        let outputExt: String? = (conversion?.outputExt).flatMap { $0 == "mp4" ? nil : $0 }

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let result = try? video.optimise(
                optimiser: self, forceMP4: forceMP4, outputExtension: outputExt, backup: false,
                encoderOverride: encoderOverride, manualConversion: true
            ) else {
                let label = type.preferredFilenameExtension ?? "video"
                mainActor { self.finish(error: "\(label) conversion failed") }
                return
            }
            mainActor {
                if self.convertedFromURL == nil { self.convertedFromURL = self.url }
                self.type = isCodecConversion ? .video(type) : .video(UTType(filenameExtension: result.path.extension ?? "mp4") ?? .mpeg4Movie)
                // Detection describes the CURRENT file and this encode replaced it: codec targets are
                // shadowed by `type` above, container targets (MP4/MOV) are default-args H.264.
                self.detectedVideoCodec = nil
                self.url = result.path.url
                self.error = nil
                self.notice = nil
                self.finish(oldBytes: self.oldBytes, newBytes: result.fileSize, removeAfterMs: self.lastRemoveAfterMs)
            }
        }
    }

    // MARK: - Temp Pipeline

    private func canonicalOrder(_ step: PipelineStep) -> Int {
        switch step {
        case .downscale, .lowerBitrate: 0
        case .crop: 1
        case .changeSpeed: 2
        case .removeAudio: 3
        case .optimise, .convert: 4
        default: 5
        }
    }

    private func isEncodingGroupStep(_ step: PipelineStep) -> Bool {
        step.isProcessingStep || step.category == .mediaSpecific
    }

    /// Find the primary encoding group: the group of consecutive processing/media steps
    /// that contains an optimise or convert step, or the first such group if none.
    private func findPrimaryEncodingGroup() -> Range<Int>? {
        var groups: [Range<Int>] = []
        var groupStart: Int?

        for (i, step) in tempPipeline.enumerated() {
            if isEncodingGroupStep(step) {
                if groupStart == nil { groupStart = i }
            } else {
                if let start = groupStart {
                    groups.append(start ..< i)
                    groupStart = nil
                }
            }
        }
        if let start = groupStart {
            groups.append(start ..< tempPipeline.count)
        }

        guard !groups.isEmpty else { return nil }

        // Prefer the group containing optimise/convert
        return groups.first(where: { range in
            tempPipeline[range].contains(where: { $0.stepName == "optimise" || $0.stepName == "convert" })
        }) ?? groups.first
    }

}

@MainActor
class OptimisationManager: ObservableObject, QLPreviewPanelDataSource {
    @Published var progress: Progress?
    @Published var current: Optimiser?
    @Published var skippedBecauseNotPro: [URL] = []
    @Published var ignoreProErrorBadge = false

    var optimisedFilesByHash: [String: FilePath] = [:]

    /// App that placed the most recent clipboard content (bundle id + display name), captured by the
    /// clipboard watcher and applied to clipboard optimisers in `optimiser(id:...)` for the `copiedBy` filter.
    var lastClipboardSourceApp: (bundleID: String?, name: String?) = (nil, nil)

    @Published var doneCount = 0
    @Published var failedCount = 0
    @Published var visibleCount = 0

    /// True while results are dropping/closing the gap after a removal. The floating cards suppress their
    /// hover overlay while this is set, so a card sliding under a stationary cursor mid-drop doesn't pop its
    /// controls and interfere with the animation. Cleared a beat after the last removal settles.
    @Published var animatingRemoval = false
    var animatingRemovalClearer: DispatchWorkItem?
    var lastRemoveAfterMs: Int?

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

    var remover: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }
    var hovered: Optimiser? {
        guard let hoveredOptimiserID else { return nil }
        return opt(hoveredOptimiserID)
    }
    @Published var optimisers: Set<Optimiser> = [] {
        didSet {
            SHARING_MANAGER.isShowingPicker = false
            // Only write (and fire the @Published/SwiftUI invalidation) for optimisers whose value
            // actually changes; the set is reassigned on every pipeline tick, so an unconditional
            // write here floods SwiftUI with no-op invalidations.
            for o in optimisers where o.sharing {
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

    var clipboardImageOptimiser: Optimiser? {
        optimisers.first(where: { $0.id.hasPrefix(Optimiser.IDs.clipboardImage) })
    }

    var clipboardImageOptimisers: [Optimiser] {
        optimisers.filter { $0.id.hasPrefix(Optimiser.IDs.clipboardImage) && $0.url != nil && !$0.running }
    }

    func markRemovalAnimating() {
        animatingRemoval = true
        animatingRemovalClearer?.cancel()
        let work = DispatchWorkItem { self.animatingRemoval = false }
        animatingRemovalClearer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
                resetRemover()
                return
            }

            clearVisibleOptimisers()
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
        if source == .clipboard {
            optimiser.copiedFromAppBundleID = lastClipboardSourceApp.bundleID
            optimiser.copiedFromAppName = lastClipboardSourceApp.name
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
    Task {
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
    // Audio encoders (ffmpeg + aac_at/lame/opus) are light and CPU-bound, not media-engine-bound, so
    // they're not limited by MediaEngineCores like video; run plenty in parallel to saturate the CPU.
    q.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount * 2
    q.underlyingQueue = DispatchQueue.global()
    return q
}()
@MainActor var pdfOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var audioOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var videoOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var imageOptimiseDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var imageResizeDebouncers: [String: DispatchWorkItem] = [:]
@MainActor var imagePipelineInFlight: [String: Task<Void, Never>] = [:]
@MainActor var videoPipelineInFlight: [String: Task<Void, Never>] = [:]
@MainActor var pdfPipelineInFlight: [String: Task<Void, Never>] = [:]
@MainActor var audioPipelineInFlight: [String: Task<Void, Never>] = [:]
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

import LowtechPro

@discardableResult @inline(__always)
@MainActor func proGuard<T>(count: inout Int, limit: Int = 5, url: URL? = nil, _ action: @escaping () async throws -> T) async throws -> T {
    guard !BM.decompressingBinaries else { throw ClopError.decompressingBinariesError }
    guard proactive || count < limit, validReq() else {
        clopDebugLog(
            "proGuard BLOCKED: proactive=\(proactive) count=\(count) limit=\(limit) url=\(url?.absoluteString ?? "nil") PRO=\(PRO != nil ? "exists" : "nil") productActivated=\(PRO?.productActivated ?? false) onTrial=\(PRO?.onTrial ?? false)"
        )
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
    optimiser.unpublishProgress()

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

func getTemplatedPath(type: ClopFileType, path: FilePath, optimisedFileBehaviour: FileBehaviour? = nil) throws -> FilePath? {
    let overrides = optimisedFileBehaviour.map { PlacementOverride(optimised: $0) }
    return try destinationPath(type: type, kind: .optimised, path: path, overrides: overrides)
}

/// Whether `path` already sits at the location produced by the optimised-file
/// location setting, so re-optimisations don't apply the template a second time
/// (e.g. `%f-opt` turning `kitty-opt.mp4` into `kitty-opt-opt.mp4`).
func isAlreadyTemplatedPath(type: ClopFileType, path: FilePath) -> Bool {
    switch type.optimisedFileBehaviour {
    case .temporary, .inPlace:
        return true
    case .sameFolder:
        let template = Defaults[type.sameFolderNameTemplateKey]
        guard !template.isEmpty else { return true }
        return nameMatchesTemplate(path.stem ?? path.name.string, template: template)
    case .specificFolder:
        let template = Defaults[type.specificFolderNameTemplateKey]
        guard !template.isEmpty else { return true }
        let pathWithoutExtension = (path.dir / (path.stem ?? path.name.string)).string
        let isAbsoluteTemplate = template.hasPrefix("/") || template.hasPrefix("%P") || template.hasPrefix("%F")
        return nameMatchesTemplate(pathWithoutExtension, template: template, allowPathPrefix: !isAbsoluteTemplate)
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
    pdfDPI: Int? = nil,
    compression: CompressionQuality? = nil,
    audioBitrate: Int? = nil,
    optimisationCount: inout Int,
    copyToClipboard: Bool,
    source: OptimisationSource? = nil,
    output: String? = nil,
    removeAudio: Bool? = nil,
    optimisedFileBehaviour: FileBehaviour? = nil,
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

        // Copy the source to the output template path off the main actor: for a large file or a
        // slow/network destination volume, `copyItem` blocks for tens of seconds and would hang the
        // UI (ANR). `optimiseItem` is async, so we can await an off-main copy here.
        let resolvedItem: ClipboardType
        if let outFilePath, item.path.exists {
            let srcPath = item.path
            let copiedPath = try await Task.detached { try srcPath.copy(to: outFilePath, force: true) }.value
            if case let .image(img) = item {
                resolvedItem = .image(img.copyWithPath(copiedPath))
            } else {
                resolvedItem = .file(copiedPath)
            }
        } else {
            resolvedItem = item
        }
        let item: ClipboardType = resolvedItem

        // Per-run compression override (CLI/Shortcuts): set it on the optimiser before
        // any pipeline runs, so the image/video/audio encode paths pick it up.
        let forceReencode = compression != nil || audioBitrate != nil
        if forceReencode, item.path.exists {
            let type = ItemType.from(filePath: item.path)
            if type.isImage || type.isVideo || type.isAudio || type.isPDF {
                let optimiser = OM.optimiser(id: id, type: type, operation: "Optimising", hidden: hideFloatingResult, source: source)
                optimiser.compressionOverride = compression
                if let audioBitrate {
                    optimiser.audioBitrateOverride = audioBitrate
                }
            }
        }

        // When every pipeline for this source skips optimisation, don't run the
        // initial optimise pass: the pipeline's own steps decide what happens to
        // the file, and a separate pass would double-process it and show its own
        // floating result. Mirror the clipboard and file-watcher `allSkip` paths
        // and let the pipeline produce the single result on a hidden parent.
        // Explicit transformations (downscale, crop, speed-up, Cmd-drop aggressive)
        // keep the normal flow: the user asked for that exact operation.
        if !skipPipelineLookup, let source, aggressiveOptimisation != true,
           scalingFactor == nil, cropSize == nil, changePlaybackSpeedFactor == nil, removeAudio == nil,
           item.path.exists
        {
            let type = ItemType.from(filePath: item.path)
            let pipelines = pipelinesFor(type: type, source: source)
            let allSkip = !pipelines.isEmpty && pipelines.allSatisfy(\.skipsPreOptimisation)
            if allSkip, type.isImage || type.isVideo || type.isAudio || type.isPDF {
                let optimiser = OM.optimiser(id: id, type: type, operation: "Running pipeline", hidden: true, source: source)
                optimiser.url = item.path.url
                optimiser.startingURL = item.path.url
                let (finalFile, anyRan) = await runPipelinesAfterOptimisation(file: item.path, type: type, source: source, optimiser: optimiser, forceHide: hideFloatingResult, copyToClipboard: copyToClipboard)
                if anyRan {
                    return .file(finalFile)
                }
                // No pipeline condition matched. A drop is a strong optimisation
                // intent (unlike file watching), so fall through to the normal pass.
            }
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
                await runPipelinesAfterOptimisation(file: result.path, type: .image(result.type), source: source, optimiser: optimiser, copyToClipboard: copyToClipboard)
            }
            return .image(result)
        case var .file(path):
            if path.isImage, var img = Image(path: path, retinaDownscaled: false) {
                guard aggressiveOptimisation == true || forceReencode || scalingFactor != nil || cropSize != nil || !path.hasOptimisationStatusXattr() else {
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
                    await runPipelinesAfterOptimisation(file: result.path, type: .image(result.type), source: source, optimiser: optimiser, copyToClipboard: copyToClipboard)
                }
                return .image(result)
            } else if path.isVideo {
                guard aggressiveOptimisation == true || forceReencode || changePlaybackSpeedFactor != nil || scalingFactor != nil || cropSize != nil || !path.hasOptimisationStatusXattr() else {
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
                    await runPipelinesAfterOptimisation(file: result.path, type: .video(UTType.from(filePath: result.path) ?? .mpeg4Movie), source: source, optimiser: optimiser, copyToClipboard: copyToClipboard)
                }
                return .file(result.path)
            } else if path.isPDF {
                guard aggressiveOptimisation == true || pdfDPI != nil || cropSize != nil || !path.hasOptimisationStatusXattr() else {
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
                        dpiOverride: pdfDPI,
                        source: source
                    )
                }
                guard let result else { return nil }
                if !skipPipelineLookup, let source, let optimiser = opt(id) {
                    await runPipelinesAfterOptimisation(file: result.path, type: .pdf, source: source, optimiser: optimiser, copyToClipboard: copyToClipboard)
                }
                return .file(result.path)
            } else if path.isAudio {
                guard aggressiveOptimisation == true || forceReencode || scalingFactor != nil || !path.hasOptimisationStatusXattr() else {
                    let audioType = path.url.utType() ?? .mp3
                    let optimiser = OM.optimiser(id: id, type: .audio(audioType), operation: "", hidden: hideFloatingResult, source: source)
                    optimiser.url = path.url
                    let audio = Audio(path: path, thumb: !hideFloatingResult)
                    optimiser.audio = audio
                    if !hideFloatingResult {
                        setAudioThumbnail(on: optimiser, path: path)
                    }
                    optimiser.finish(oldBytes: audio.fileSize, newBytes: audio.fileSize, oldBitrate: audio.bitrate, newBitrate: audio.bitrate)
                    if skipPipelineLookup { return .file(path) }
                    throw ClopError.alreadyOptimised(path)
                }

                let result: Audio? = try await proGuard(count: &optimisationCount, limit: 5, url: path.url) {
                    let audio = await (try? Audio.byFetchingMetadata(path: path, thumb: !hideFloatingResult)) ?? Audio(path: path, thumb: !hideFloatingResult)
                    let bitrateOverride: Int? = if let audioBitrate {
                        audioBitrate
                    } else if let factor = scalingFactor, factor > 0, factor < 1 {
                        audio.loweredBitrate(factor: factor)
                    } else {
                        nil
                    }
                    return try await runAudioPipeline(
                        audio,
                        actions: [.optimise],
                        id: id,
                        copyToClipboard: copyToClipboard,
                        hideFloatingResult: hideFloatingResult,
                        source: source,
                        bitrateOverride: bitrateOverride
                    )
                }
                guard let result else { return nil }
                if !skipPipelineLookup, let source, let optimiser = opt(id) {
                    await runPipelinesAfterOptimisation(file: result.path, type: .audio(path.url.utType() ?? .mp3), source: source, optimiser: optimiser, copyToClipboard: copyToClipboard)
                }
                return .file(result.path)
            } else {
                nope(notice: "Clipboard contents can't be optimised")
                throw ClopError.unknownType
            }
        case let .url(url):
            return try await proGuard(count: &optimisationCount, limit: 5, url: url) {
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
    guard Defaults[.enableFloatingResults] || DM.showDropZone, !floatingResultsWindow.isVisible || force else {
        return
    }

    // Pin the panel to a concrete screen so its `windowDidResize` delegate re-anchors the corner
    // synchronously on every content-size change. Without a `screenPlacement` the delegate early-returns
    // and only a 10ms-throttled observer re-pins, so removing a result lets the window display risen
    // (AppKit keeps the top-left fixed when the content shrinks) before it snaps back down — the up-then-down
    // jolt on bottom corners. A concrete screen (not the dynamic `.withMouse`) keeps the panel on its own
    // display even if the cursor wanders to another one.
    floatingResultsWindow.screenPlacement = NSScreen.withMouse ?? NSScreen.main

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

/// Resolve a request `pipeline` argument: saved pipeline name first, then inline pipeline DSL.
@MainActor func resolveRequestPipeline(_ arg: String) -> Pipeline? {
    if let saved = Defaults[.savedPipelines].first(where: { ($0.name ?? "").localizedCaseInsensitiveCompare(arg) == .orderedSame }) {
        return saved.resolved
    }
    let steps = Pipeline.parseSteps(from: arg)
    guard !steps.isEmpty else { return nil }
    // Inline DSL runs exactly the steps written: no implicit optimisation pass.
    return Pipeline(steps: steps, rawText: Pipeline.cleanupPipelineText(arg), skipOptimisation: true)
}

/// Handle a request that carries an explicit pipeline (CLI `clop pipeline run`).
/// Mirrors the watched-folder automation flow: standard optimisation first unless the
/// pipeline opts out via `skipOptimisation`, then the pipeline steps on the result.
func processPipelineRequestURL(_ req: OptimisationRequest, url: URL) async throws -> OptimisationResponse {
    guard let path = url.existingFilePath else {
        throw ClopError.fileNotFound(FilePath(url.path))
    }
    guard let pipelineArg = req.pipeline, let pipeline = await MainActor.run(body: { resolveRequestPipeline(pipelineArg) }) else {
        throw ClopError.optimisationFailed("Invalid pipeline '\(req.pipeline ?? "")': no saved pipeline with that name and no valid steps")
    }
    let type = ItemType.from(filePath: path)
    switch type {
    case .image, .video, .audio, .pdf: break
    default: throw ClopError.unknownType
    }

    let id = url.absoluteString
    let source = req.source.optSource ?? .cli
    let oldBytes = path.fileSize() ?? 0
    var startPath = path

    if !pipeline.skipsPreOptimisation {
        do {
            let result = try await optimiseItem(
                ClipboardType.fromURL(url),
                id: id,
                hideFloatingResult: req.hideFloatingResult,
                aggressiveOptimisation: req.aggressiveOptimisation,
                adaptiveOptimisation: req.adaptiveOptimisation,
                pdfDPI: req.pdfDPI,
                compression: req.compression,
                audioBitrate: req.audioBitrate,
                optimisationCount: &cliOptimisationCount,
                copyToClipboard: false, // batched at the end of processOptimisationRequest
                source: source,
                optimisedFileBehaviour: .inPlace,
                skipPipelineLookup: true
            )
            switch result {
            case let .file(p): startPath = p
            case let .image(img): startPath = img.path
            default: break
            }
        } catch let ClopError.alreadyOptimised(p) {
            startPath = p
        }
    }

    let optimiser = await MainActor.run {
        let o = OM.optimiser(id: id, type: type, operation: "Running pipeline", hidden: req.hideFloatingResult, source: source)
        if o.url == nil { o.url = startPath.url }
        // Per-run compression overrides: pipeline steps that spawn child pipelines
        // (convert, optimise) propagate these to the child optimisers.
        if let compression = req.compression { o.compressionOverride = compression }
        if let bitrate = req.audioBitrate { o.audioBitrateOverride = bitrate }
        o.placementOverride = req.placement
        return o
    }
    let (resultFile, _) = await runPipelinesAfterOptimisation(
        file: startPath, type: type, source: source, optimiser: optimiser,
        pipelines: [pipeline], forceHide: req.hideFloatingResult,
        copyToClipboard: false // batched at the end of processOptimisationRequest
    )

    return OptimisationResponse(
        path: resultFile.string, forURL: url,
        oldBytes: oldBytes, newBytes: resultFile.fileSize() ?? 0
    )
}

func processOptimisationRequest(_ req: OptimisationRequest) async throws -> [OptimisationResponse] {
    // --review: open the batch window for the user to tweak knobs and press Optimise; don't process here.
    if req.prepareInBatch == true, await MainActor.run(body: { proactive }) {
        await MainActor.run {
            BAT.prepare(paths: req.urls.compactMap(\.filePath), source: req.source.optSource)
            BAT.showWindow()
        }
        return []
    }

    // Large requests go through the batch engine + window (Pro-only); small ones use the per-file path.
    if await shouldRouteToBatch(req) {
        return await runBatchForCLI(req)
    }

    return try await withThrowingTaskGroup(of: OptimisationResponse.self, returning: [OptimisationResponse].self) { group in
        THUMBNAIL_URLS.accessQueue.sync {
            THUMBNAIL_URLS = ThreadSafeDictionary(dict: req.originalUrls)
        }
        for url in req.urls {
            let added = group.addTaskUnlessCancelled {
                let clip = ClipboardType.fromURL(url)

                do {
                    if req.pipeline != nil {
                        return try await processPipelineRequestURL(req, url: url)
                    }
                    // Pre-register the optimiser so placementOverride is available before the pipeline runs.
                    if let placement = req.placement {
                        await MainActor.run {
                            OM.optimiser(id: url.absoluteString, type: .unknown, operation: "", hidden: req.hideFloatingResult).placementOverride = placement
                        }
                    }
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
                            pdfDPI: req.pdfDPI,
                            compression: req.compression,
                            audioBitrate: req.audioBitrate,
                            optimisationCount: &cliOptimisationCount,
                            copyToClipboard: false, // batched at the end so every input copies, even failures
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
                    await MainActor.run { opt.placementOverride = req.placement }

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
                        oldWidthHeight: opt.oldSize, newWidthHeight: opt.newSize,
                        oldBitrate: opt.oldBitrate, newBitrate: opt.newBitrate,
                        oldDPI: opt.oldDPI, newDPI: opt.newDPI
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
        // For --copy: one file per input ends up on the clipboard, the optimised result on success
        // or the original file on failure, so the count always matches the inputs.
        var copiedFiles = [URL]()
        while !group.isEmpty {
            do {
                guard let resp = try await group.next() else {
                    continue
                }
                responses.append(resp)
                copiedFiles.append(URL(fileURLWithPath: resp.path))
                if req.source == "cli" {
                    try? OPTIMISATION_CLI_RESPONSE_PORT.sendAndForget(data: resp.jsonData)
                } else {
                    try? OPTIMISATION_RESPONSE_PORT.sendAndForget(data: resp.jsonData)
                }
            } catch is CancellationError {
                log.error("BatchOptimisation cancelled")
                continue
            } catch let BatchOptimisationError.wrappedClopError(error, url) {
                copiedFiles.append(req.originalUrls[url] ?? url)
                if req.source == "cli" {
                    try? OPTIMISATION_CLI_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.description, forURL: url).jsonData)
                } else {
                    try? OPTIMISATION_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.description, forURL: url).jsonData)
                }
                log.error("BatchOptimisation ClopError \(error.description) for \(url)")
            } catch let BatchOptimisationError.wrappedError(error, url) {
                copiedFiles.append(req.originalUrls[url] ?? url)
                if req.source == "cli" {
                    try? OPTIMISATION_CLI_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.localizedDescription, forURL: url).jsonData)
                } else {
                    try? OPTIMISATION_RESPONSE_PORT.sendAndForget(data: OptimisationResponseError(error: error.localizedDescription, forURL: url).jsonData)
                }
                log.error("BatchOptimisation Error \(error.localizedDescription) for \(url)")
            }
        }

        if req.copyToClipboard, !copiedFiles.isEmpty {
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(copiedFiles.map { $0 as NSURL })
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
