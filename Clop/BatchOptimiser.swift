//
//  BatchOptimiser.swift
//  Clop
//
//  Lightweight high-throughput batch engine. Instead of one heavy `Optimiser` (+ thumbnail + UI
//  cascade) per dropped file, a batch holds value-type `BatchItem`s and runs each through the
//  existing pipelines using a transient hidden `Optimiser` that is never registered in `OM`. Only
//  ~concurrency optimisers/file-wrappers are alive at once (an `AsyncSemaphore` admission gate),
//  so memory stays flat regardless of batch size; the per-type `OperationQueue`s inside the
//  pipelines still govern the actual CPU-vs-GPU codec parallelism.
//

import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Batch")

// MARK: - AsyncSemaphore

/// Minimal async counting semaphore (no Lowtech/stdlib equivalent). Bounds how many batch items
/// hold a live `Optimiser` + decoded file wrapper + temp file at once, keeping memory flat for
/// arbitrarily large batches.
actor AsyncSemaphore {
    init(value: Int) {
        self.value = max(value, 1)
    }

    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Model

enum BatchStatus: String {
    case queued
    case copying // pulling off an external volume to the internal disk (see BatchBackup, step 4)
    case running
    case done
    case failed
    case skipped

    var isTerminal: Bool {
        self == .done || self == .failed || self == .skipped
    }
}

/// Where in an image/video convert step should target. Compatibility conversions (HEIC/WebP→JPEG,
/// MOV→MP4, etc.) are handled by the pipeline's own auto-conversion and need no entry here.
enum ImageConvertTarget: Equatable { case jpeg, png, webp, jxl }
enum VideoConvertTarget: Equatable { case mp4, hevc, av1, webm }

/// PDF downsampling mode: use the global setting, force adaptive, a fixed DPI, or step one stop down
/// per file (the "aggressive" behaviour).
enum PDFDPIMode: Equatable { case useDefault, adaptive, fixed(Int), stepDown }

struct ImageBatchParams: Equatable {
    var compression: CompressionQuality?
    var adaptive: Bool?
    var convertTo: ImageConvertTarget?
    var downscaleFactor: Double? // < 1 to downscale
    var maxLongEdge: Int? // cap the long edge to this many px
    var allowLarger = false // keep the result even if it's larger than the original (for conversions)
}

struct VideoBatchParams: Equatable {
    var compression: CompressionQuality? // tier carries the encoder choice; factor 0 = auto CRF
    var convertTo: VideoConvertTarget?
    var downscaleFactor: Double?
    var maxLongEdge: Int?
    var fpsCap: Int?
    var removeAudio = false
    var allowLarger = false
}

struct PDFBatchParams: Equatable {
    var dpiMode: PDFDPIMode = .useDefault
}

struct AudioBatchParams: Equatable {
    var compression: CompressionQuality?
    var bitrate: Int? // explicit kbps; overrides the compression factor
    var format: AudioFormat?
    var convertLossless = false // also convert WAV/AIFF/FLAC inputs to `format`
    var coverArt: AudioCoverArtBehaviour?
    var coverArtMaxLongEdge: Int?
    var loudnorm: Double?
    var allowLarger = false
}

/// Batch-wide parameters, grouped per file type. Every override is optional; `nil` means "use the
/// per-format Defaults", so `fromDefaults()` behaves exactly like optimising each file individually
/// with the current settings. `aggressive` is global (the Cmd-drop / CLI aggressive flag).
struct BatchParams: Equatable {
    var images = ImageBatchParams()
    var video = VideoBatchParams()
    var pdf = PDFBatchParams()
    var audio = AudioBatchParams()
    var aggressive: Bool?
    var output: String? // nil = in place

    static func fromDefaults() -> BatchParams {
        var p = BatchParams()
        // Resolve "use the global default" to a concrete DPI mode up front: the Adjust panel's picker
        // has no "use default" option, so leaving .useDefault here makes an untouched round-trip look
        // like a change and spuriously re-optimises every PDF.
        p.pdf.dpiMode = Defaults[.pdfDPI] == PDF_DPI_ADAPTIVE ? .adaptive : .fixed(Defaults[.pdfDPI])
        return p
    }

    /// Quick-bar helper: apply one compression factor to every present type at once.
    mutating func setUniformCompression(_ factor: Int) {
        let cq = CompressionQuality(tier: .custom, factor: factor)
        images.compression = cq
        video.compression = cq
        audio.compression = cq
    }

    /// Quick-bar helper: apply one downscale factor to image + video at once (< 1 to downscale).
    mutating func setUniformDownscale(_ factor: Double?) {
        images.downscaleFactor = factor
        video.downscaleFactor = factor
    }
}

/// One file in a batch. Pure value type: no `ObservableObject`, no `NSImage`, no retained `Progress`.
struct BatchItem: Identifiable {
    let id: String // == source.string
    let source: FilePath
    let type: ItemType

    var status: BatchStatus = .queued
    var error: String?
    var errorLog: String? // real tool command line + stdout/stderr, for the failures view

    var oldBytes = 0
    var newBytes = 0
    var oldSize: CGSize?
    var newSize: CGSize?
    var oldBitrate: Int?
    var newBitrate: Int?
    var oldDPI: Int?
    var newDPI: Int?
    var oldFormat: String?
    var newFormat: String?

    var resultPath: FilePath?
    var progressFraction: Double = 0
    var params: BatchParams

    var name: String {
        source.lastComponent?.string ?? id
    }

    /// Comparable keys for SwiftUI Table column sorting.
    /// Active rows first, then done, then failed/skipped (the default order).
    var sortRank: Int {
        switch status {
        case .running, .copying: 0
        case .queued: 1
        case .done: 2
        case .failed: 3
        case .skipped: 4
        }
    }

    var formatKey: String {
        oldFormat ?? ""
    }
    var sizeKey: Int {
        oldBytes
    }
    var savedKey: Double {
        savedFraction
    }
    var detailKey: Double {
        switch type {
        case .pdf: Double(newDPI ?? oldDPI ?? 0)
        case .audio: Double(newBitrate ?? oldBitrate ?? 0)
        default: (newSize ?? oldSize).map { Double($0.width * $0.height) } ?? 0
        }
    }

    var savedBytes: Int {
        max(0, oldBytes - newBytes)
    }
    var savedFraction: Double {
        guard oldBytes > 0, newBytes > 0 else { return 0 }
        return Double(oldBytes - newBytes) / Double(oldBytes)
    }
}

/// Roll-up shown in the batch window header.
struct BatchAggregate {
    var total = 0
    var queued = 0
    var copying = 0
    var running = 0
    var done = 0
    var failed = 0
    var skipped = 0
    var totalOldBytes = 0
    var totalNewBytes = 0

    var finished: Int {
        done + failed + skipped
    }
    var overallFraction: Double {
        total > 0 ? Double(finished) / Double(total) : 0
    }
    var savedBytes: Int {
        max(0, totalOldBytes - totalNewBytes)
    }
    var savedFraction: Double {
        guard totalOldBytes > 0 else { return 0 }
        return Double(totalOldBytes - totalNewBytes) / Double(totalOldBytes)
    }
}

/// File-type bucket for per-type batch concurrency and change detection.
enum BatchTypeKey: CaseIterable { case image, video, pdf, audio }

func batchTypeKey(_ type: ItemType) -> BatchTypeKey? {
    if type.isImage { .image } else if type.isVideo { .video } else if type.isPDF { .pdf } else if type.isAudio { .audio } else { nil }
}

// MARK: - BatchManager

/// Single owner of the batch model and the only published surface the batch UI observes. Per-file
/// runners mutate the non-published `backing` array and mark rows dirty; a reused 100 ms flush
/// publishes once (one `objectWillChange` covering all the rows that changed in the window).
@MainActor final class BatchManager: ObservableObject {
    /// The display-ordered, sorted snapshot the table reads (NOT the same order as `backing`).
    @Published private(set) var items: [BatchItem] = []
    @Published private(set) var aggregate = BatchAggregate()
    @Published var params = BatchParams.fromDefaults()
    @Published private(set) var isRunning = false
    /// True while the batch is built but not yet started — the window shows the prepare knob panel.
    @Published private(set) var isPreparing = false
    /// True while a restore-from-backup is in progress, so the UI disables Apply/Restore meanwhile.
    @Published private(set) var isRestoring = false
    /// Short status shown in the header during the brief upfront backup ("Backing up originals…").
    @Published private(set) var phase = ""

    var source: OptimisationSource?

    /// Called after each flush. `orderChanged` true → the table should reloadData (and restore its
    /// selection by id); otherwise only the given display rows changed and can be reloaded targeted.
    var onFlush: ((_ orderChanged: Bool, _ dirtyDisplayRows: IndexSet) -> Void)?

    /// One-shot, fired when the whole run finishes (or finds nothing to do). Used by the CLI bridge to
    /// stream results back once the batch completes.
    var onFinished: (() -> Void)?

    /// Per-batch pristine CoW backup of every source, cloned up front. The only reliable original
    /// after an in-place rewrite. Never auto-deleted (see `FilePath.batchBackups`).
    private(set) var backup: BatchBackup?
    /// The batch window, created lazily by `showWindow()` (see BatchWindow.swift).
    var windowController: NSWindowController?

    /// "Delete backups" is offered only once nothing is still queued/running/copying.
    var canDeleteBackups: Bool {
        backup != nil && !backing.isEmpty && backing.allSatisfy(\.status.isTerminal)
    }

    /// Re-running with new settings needs the pristine originals. Once the backups are deleted in
    /// Clop this is false, so the UI can disable Apply and explain instead of erroring on click.
    var canReapply: Bool {
        backup != nil
    }

    /// Location of this batch's backups, for "Show backups in Finder".
    var backupDirURL: URL? {
        backup?.dir.url
    }

    func row(at idx: Int) -> BatchItem? {
        items.indices.contains(idx) ? items[idx] : nil
    }

    /// The current display row for an item id, for restoring table selection across a re-sort.
    func displayRow(for id: String) -> Int? {
        displayRowByID[id]
    }

    /// Build the batch and show it in the *prepare* state (knob panel, no processing yet). Used by the
    /// drop-zone path; the user reviews the per-type knobs and presses Optimise (`beginProcessing`).
    /// The window appears instantly and the (potentially large) file scan runs off the main actor, so
    /// dropping a big folder never beachballs.
    func prepare(paths: [FilePath], source: OptimisationSource? = nil) {
        cancel()
        self.source = source
        backing = []
        rebuildIndex()
        backup = nil
        isPreparing = true
        phase = "Scanning…"
        publishNow() // window appears instantly, empty, while we scan

        let params = params
        orchestrator = Task {
            let built = await Task.detached { buildBatchItems(paths, params: params) }.value
            guard !Task.isCancelled else { return }
            self.backing = built
            self.rebuildIndex()
            self.phase = ""
            if built.isEmpty {
                self.isPreparing = false
                log.debug("Batch had no supported files")
            }
            self.publishNow()
        }
    }

    /// Build and immediately process with `params` (CLI / Shortcuts auto-start path; no prepare gate).
    func start(paths: [FilePath], params: BatchParams? = nil, source: OptimisationSource? = nil) {
        cancel()
        self.source = source
        let resolved = params ?? .fromDefaults()
        backing = buildBatchItems(paths, params: resolved)
        rebuildIndex()
        guard !backing.isEmpty else {
            log.debug("Batch had no supported files")
            publishNow()
            return
        }
        isPreparing = true // satisfies beginProcessing's guard
        beginProcessing(params: resolved)
    }

    /// Menubar entry: open the batch window ready to receive dropped files. Starts a fresh empty batch
    /// when there's nothing in progress to preserve; otherwise just focuses the existing window (so a
    /// running batch or an in-progress compose isn't wiped).
    func presentForDropping() {
        if !isRunning, !isPreparing, !isRestoring {
            reset()
        }
        showWindow()
    }

    /// Append dropped files/folders to the current prepare-phase batch instead of replacing it, so the
    /// window can be built up over several drops. Folders are expanded to their optimisable contents;
    /// non-optimisable files and duplicates are dropped. Ignored while a run/restore is in progress.
    func add(paths: [FilePath], source: OptimisationSource? = nil) {
        guard !isRunning, !isRestoring else { return }
        if self.source == nil { self.source = source }
        // No `phase` spinner here (unlike `prepare`): keep the already-added files visible while the
        // new drop's folders are expanded, so subsequent drops don't flash the table away.
        isPreparing = true
        publishNow()

        let params = params
        orchestrator = Task {
            let expanded: [FilePath] = await Task.detached {
                var out: [FilePath] = []
                for path in paths where path.exists {
                    if path.isDir {
                        out.append(contentsOf: getURLsFromFolder(path.url, recursive: true, types: ALL_FORMATS).compactMap(\.existingFilePath))
                    } else {
                        out.append(path)
                    }
                }
                return out
            }.value
            guard !Task.isCancelled else { return }
            // Dedup against the live batch at append time (folder expansion above is async, so an
            // up-front snapshot could be stale if drops overlap).
            let existing = Set(self.backing.map(\.id))
            let fresh = buildBatchItems(expanded, params: params).filter { !existing.contains($0.id) }
            self.backing.append(contentsOf: fresh)
            self.rebuildIndex()
            self.publishNow()
        }
    }

    /// Remove items from the prepare-phase batch (the table's "Remove from batch" / Delete key).
    func remove(ids: [String]) {
        guard !isRunning else { return }
        let idset = Set(ids)
        backing.removeAll { idset.contains($0.id) }
        rebuildIndex()
        publishNow()
    }

    /// Clear the batch back to zero files and return to the empty prepare/drop state, ready for new
    /// drops. Stops any in-flight scan/run; leaves on-disk backups for the cleaner to handle.
    func reset() {
        cancel()
        backing = []
        rebuildIndex()
        backup = nil
        aggregate = BatchAggregate()
        // `cancel()` clears isRunning/isPreparing/gates but not isRestoring; clear it here so a reset
        // mid-restore can't leave the UI stuck with Apply/Restore disabled.
        isRestoring = false
        isPreparing = true
        phase = ""
        publishNow()
    }

    /// Start processing a prepared batch with the chosen per-type config (the Optimise button).
    func beginProcessing(params: BatchParams) {
        guard isPreparing else { return }
        self.params = params
        for idx in backing.indices {
            backing[idx].params = params
        }
        isPreparing = false
        startRun(ids: backing.map(\.id), freshBackup: true)
    }

    /// Cancel the whole run: stop the orchestrator and terminate every in-flight optimiser's
    /// processes. Items already finished keep their results.
    func cancel() {
        // Invalidate the in-flight run so its trailing finishRun (which only fires after the task group
        // drains) can't reset the state of whatever run/restore replaces it.
        runGeneration += 1
        orchestrator?.cancel()
        orchestrator = nil
        for optimiser in liveOptimisers.values {
            optimiser.stop(remove: false)
        }
        liveOptimisers.removeAll()
        for idx in backing.indices where backing[idx].status == .running || backing[idx].status == .queued {
            backing[idx].status = .skipped
        }
        isRunning = false
        isPreparing = false
        gates = [:]
        publishNow()
        // A CLI/IPC-initiated batch blocks the `clop` process on `onFinished`; the cancelled run's
        // finishRun is now invalidated by the generation bump and won't fire it, so resume it here.
        // Cleared first so it fires at most once (a later finishRun/cancel sees nil and no-ops).
        let onCancelFinished = onFinished
        onFinished = nil
        onCancelFinished?()
    }

    /// Re-run the whole batch (or just `ids`) with new params. Each affected source is restored from
    /// its verifiable batch backup first (the only pristine copy after an in-place rewrite); an item
    /// whose backup can't be verified is marked failed instead of re-encoding a possibly-corrupt file.
    func reapply(params: BatchParams, toSelection ids: [String]? = nil) {
        let targets = ids ?? backing.map(\.id)
        cancel()
        self.params = params

        for id in targets {
            guard let idx = indexByID[id] else { continue }
            backing[idx].params = params
            backing[idx].error = nil
            backing[idx].newBytes = 0
            backing[idx].newSize = nil
            backing[idx].newBitrate = nil
            backing[idx].newDPI = nil
            backing[idx].newFormat = nil
            backing[idx].resultPath = nil
            backing[idx].progressFraction = 0

            if backup?.restoreVerified(backing[idx].source) ?? false {
                backing[idx].status = .queued
            } else {
                backing[idx].status = .failed
                backing[idx].error = "Couldn't restore the original to re-run"
            }
        }
        publishNow()

        let queued = backing.filter { $0.status == .queued }.map(\.id)
        guard !queued.isEmpty else { return }
        startRun(ids: queued, freshBackup: false)
    }

    /// Restore the pristine originals from the verified backups for all items (or just `ids`),
    /// discarding the optimised results on disk. Runs off-main with per-row progress (a large or
    /// slow-write restore can take minutes); the backups stay in place (so it's repeatable and Apply
    /// still works). An item whose backup can't be restored is marked failed.
    func restoreFromBackup(toSelection ids: [String]? = nil) {
        guard !isRestoring, let backup else { return }
        cancel()
        let targets = (ids ?? backing.map(\.id)).filter { indexByID[$0] != nil }
        guard !targets.isEmpty else { return }

        isRestoring = true
        for id in targets {
            guard let idx = indexByID[id] else { continue }
            backing[idx].status = .copying
            backing[idx].progressFraction = 0
        }
        publishNow()

        orchestrator = Task {
            for id in targets {
                guard let idx = self.indexByID[id] else { continue }
                let src = self.backing[idx].source
                let ok = await Task.detached {
                    backup.restore(src) { copied, total in
                        mainActor { self.setProgress(id: id, total > 0 ? Double(copied) / Double(total) : 0) }
                    }
                }.value
                if ok {
                    self.backing[idx].newBytes = 0
                    self.backing[idx].newSize = nil
                    self.backing[idx].newBitrate = nil
                    self.backing[idx].newDPI = nil
                    self.backing[idx].newFormat = nil
                    self.backing[idx].resultPath = src
                    self.backing[idx].error = nil
                    self.backing[idx].progressFraction = 1
                    self.backing[idx].status = .done
                } else {
                    self.backing[idx].status = .failed
                    self.backing[idx].error = "Couldn't restore the original"
                }
                self.markDirty(idx)
            }
            self.isRestoring = false
            self.publishNow()
        }
    }

    /// Remove the whole batch backup folder. Only valid once every item has finished.
    func deleteBackups() {
        guard canDeleteBackups else { return }
        backup?.deleteBackups()
        backup = nil
    }

    /// Open the before/after comparison window for one finished item (original from the backup vs the
    /// optimised result). Needs the backup to still exist.
    func compareItem(id: String) {
        guard let idx = indexByID[id] else { return }
        let item = backing[idx]
        guard item.status == .done, let backupPath = backup?.backupPath(for: item.source) else { return }
        let optimiser = Optimiser(id: "batch-compare-\(item.id)", type: item.type, running: false)
        optimiser.url = (item.resultPath ?? item.source).url
        optimiser.originalURL = backupPath.url
        optimiser.oldBytes = item.oldBytes
        optimiser.newBytes = item.newBytes
        optimiser.oldSize = item.oldSize
        optimiser.newSize = item.newSize
        optimiser.compare()
    }

    /// Change the table sort. `key` nil restores the composite default order.
    func setSort(key: String?, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        rebuildDisplay()
        onFlush?(true, IndexSet())
    }

    // Non-published backing store mutated by the runners (all on the main actor).
    private var backing: [BatchItem] = []
    private var indexByID: [String: Int] = [:]
    private var displayRowByID: [String: Int] = [:]
    private var liveOptimisers: [String: Optimiser] = [:]
    private var dirtyRows: Set<Int> = []
    private var flushScheduled = false
    private var orchestrator: Task<Void, Never>?
    /// Monotonic run id. Bumped by every `startRun`/`cancel`, so a stale run that finishes unwinding
    /// after a newer run (or a restore) has started can't clobber the live run's state in `finishRun`.
    private var runGeneration = 0
    /// Output paths already claimed by the current run, so same-named sources from different folders
    /// don't collapse onto one output file.
    private var claimedOutputPaths: Set<String> = []
    /// Per-type admission gates so each file type runs at its own concurrency (heavy image decodes
    /// stay bounded, light audio runs wide, video respects the media engine / software-encoder limit).
    private var gates: [BatchTypeKey: AsyncSemaphore] = [:]

    /// nil = the composite default order (active first, grouped by type, depth-aware alphabetical);
    /// otherwise sort by this column key in `sortAscending` direction.
    private var sortKey: String?
    private var sortAscending = true

    private var batchID = ""

    /// Per-type admission limits. Images decode into memory so they're capped near the CPU count;
    /// audio is light and CPU-bound (run wide); PDF parallelises pages internally (keep modest); video
    /// runs `MediaEngineCores` for hardware (VideoToolbox) but only 1 for software encoders, which
    /// already saturate every core on their own.
    private func makeGates(params: BatchParams) -> [BatchTypeKey: AsyncSemaphore] {
        let cpu = ProcessInfo.processInfo.activeProcessorCount
        let media = MediaEngineCores.current.rawValue
        let videoConcurrency = isSoftwareVideo(params.video) ? 1 : media
        return [
            .image: AsyncSemaphore(value: max(cpu - 1, 1)),
            .audio: AsyncSemaphore(value: cpu * 2),
            .pdf: AsyncSemaphore(value: media),
            .video: AsyncSemaphore(value: videoConcurrency),
        ]
    }

    /// True when the chosen video settings use a software encoder (libx264/SVT-AV1/VP9), which pins
    /// all cores per file; hardware VideoToolbox (.fast tier, HEVC/MP4 convert) does not.
    private func isSoftwareVideo(_ v: VideoBatchParams) -> Bool {
        switch v.convertTo {
        case .av1, .webm: return true
        case .hevc, .mp4: return false
        case nil: break
        }
        switch v.compression?.tier ?? .fast {
        case .smaller, .custom, .lossless: return true
        case .fast, .adaptive: return false
        }
    }

    /// Kick off the run for `ids`. `freshBackup` clones the originals up front (initial run); reapply
    /// reuses the existing backup.
    private func startRun(ids: [String], freshBackup: Bool) {
        if freshBackup {
            batchID = UUID().uuidString
            backup = BatchBackup(id: batchID)
        }
        runGeneration += 1
        let generation = runGeneration
        // Reserve the output paths of items NOT being re-run this pass, so a re-running same-named item
        // can't reclaim (and overwrite) a sibling's still-valid result file in the output folder.
        let rerunning = Set(ids)
        claimedOutputPaths = Set(backing.filter { !rerunning.contains($0.id) }.compactMap { $0.resultPath?.string })
        isRunning = true
        if freshBackup { phase = "Backing up originals…" }
        publishNow()

        let sources = backing.map(\.source)
        let gates = makeGates(params: params)
        self.gates = gates
        let backup = backup
        // Singleton: no [weak self] (BAT lives for the whole app lifetime).
        orchestrator = Task {
            if freshBackup, let backup {
                // Clone every source up front (near-instant on APFS) so the pristine original always
                // survives an in-place rewrite. Done off-main so the window stays responsive meanwhile.
                await Task.detached { backup.backupAll(sources) }.value
                self.phase = ""
                self.publishNow()
            }
            await self.runAll(ids: ids, gates: gates, generation: generation)
        }
    }

    // MARK: Execution

    private func runAll(ids: [String], gates: [BatchTypeKey: AsyncSemaphore], generation: Int) async {
        // Pair each id with its type's gate so file types run at independent concurrency.
        let typed: [(String, AsyncSemaphore)] = ids.compactMap { id in
            guard let idx = indexByID[id], let key = batchTypeKey(backing[idx].type), let gate = gates[key] else { return nil }
            return (id, gate)
        }
        await withTaskGroup(of: Void.self) { group in
            for (id, gate) in typed {
                group.addTask {
                    await gate.wait()
                    await self.runItem(id: id)
                    await gate.signal()
                }
            }
        }
        finishRun(generation: generation)
    }

    /// Process a single item end-to-end on the main actor. The heavy codec work runs off-main inside
    /// the pipeline's `OperationQueue`; the file-wrapper decode here is bounded by the semaphore.
    private func runItem(id: String) async {
        guard let idx = indexByID[id], !backing[idx].status.isTerminal else { return }
        guard !Task.isCancelled else {
            setStatus(idx, .skipped)
            return
        }

        let item = backing[idx]
        let src = item.source
        let p = item.params
        let optimiser = makeOptimiser(for: item)

        // Optimise a working copy (leaving the original untouched) when the source is on an external
        // volume, or when results are written to a separate output folder. Otherwise optimise the
        // original in place. External pulls show copy progress; an internal clone is near-instant.
        let outputDir: FilePath? = p.output.map { FilePath($0) }
        let onExternal = src.isOnExternalVolume
        // Never rewrite an original in place without a recoverable copy: if the up-front backup didn't
        // materialise (disk full, I/O error), optimise a working copy and atomically place it back, so
        // the original is only ever replaced once a good result exists.
        let hasBackup = backup?.backupPath(for: src) != nil
        let needsWorkingCopy = onExternal || outputDir != nil || !hasBackup
        var working = src
        if needsWorkingCopy {
            // A per-item work folder so same-named sources from different folders never collide on the
            // shared working path while running concurrently.
            let workDir = FilePath.dir(FilePath.batchBackups / "batch-\(batchID)" / "work" / "\(idx)", permissions: 0o755)
            do {
                if onExternal {
                    setStatus(idx, .copying)
                    working = try await Task.detached {
                        try copyWithProgress(from: src, to: workDir) { copied, total in
                            mainActor { self.setProgress(id: id, total > 0 ? Double(copied) / Double(total) : 0) }
                        }
                    }.value
                } else {
                    working = try src.clone(to: workDir)
                }
            } catch {
                recordFailure(id: id, message: "Couldn't copy the file: \(error.localizedDescription)")
                liveOptimisers[id] = nil
                return
            }
            optimiser.url = working.url
        }
        setStatus(idx, .running)

        let aggressive = p.aggressive

        do {
            switch item.type {
            case .image:
                guard let img = Image(path: working, retinaDownscaled: false) else {
                    throw ClopError.fileNotFound(working)
                }
                let ip = p.images
                _ = try await runImagePipeline(
                    img, actions: batchImageActions(ip), id: id, allowLarger: ip.allowLarger, hideFloatingResult: true,
                    aggressiveOptimisation: aggressive, adaptiveOptimisation: ip.adaptive,
                    source: source, compression: ip.compression, batchOptimiser: optimiser
                )

            case .video:
                let vp = p.video
                let (ffmpegOverride, outputExt) = batchVideoConvertArgs(vp.convertTo)
                let video = Video(working, thumb: false)
                _ = try await runVideoPipeline(
                    video, actions: batchVideoActions(vp), id: id, allowLarger: vp.allowLarger, hideFloatingResult: true,
                    aggressiveOptimisation: aggressive,
                    ffmpegEncoderOverride: ffmpegOverride, outputExtension: outputExt,
                    source: source, fpsOverride: vp.fpsCap, compression: vp.compression, batchOptimiser: optimiser
                )

            case .pdf:
                let (dpi, pdfAggressive) = batchPDFDPIArgs(p.pdf.dpiMode, aggressive: aggressive)
                let pdf = PDF(working, thumb: false)
                _ = try await runPDFPipeline(
                    pdf, actions: [.optimise], id: id, hideFloatingResult: true,
                    aggressiveOptimisation: pdfAggressive, dpiOverride: dpi,
                    source: source, batchOptimiser: optimiser
                )

            case .audio:
                let ap = p.audio
                let inputLossless = ["wav", "aiff", "aif", "flac"].contains(src.extension?.lowercased() ?? "")
                // Leave lossless inputs in-format unless the user opted into converting them.
                let formatOverride: AudioFormat? = (inputLossless && !ap.convertLossless) ? nil : ap.format
                let audio = Audio(working, thumb: false)
                _ = try await runAudioPipeline(
                    audio, actions: [.optimise], id: id, allowLarger: ap.allowLarger, hideFloatingResult: true,
                    source: source, bitrateOverride: ap.bitrate, aggressiveOptimisation: aggressive,
                    formatOverride: formatOverride, loudnormTarget: ap.loudnorm,
                    coverArt: ap.coverArt, coverArtMaxLongEdge: ap.coverArtMaxLongEdge,
                    compression: ap.compression, batchOptimiser: optimiser
                )

            default:
                break
            }
            // Always place the result: an in-place format conversion (e.g. PNG→JPEG) leaves the
            // optimised file in a temp cache dir, so it must be written next to the original too, not
            // only for the working-copy / output-folder cases.
            if await placeResult(optimiser: optimiser, working: working, destinationDir: outputDir, original: src) {
                recordResult(id: id, optimiser: optimiser)
            } else {
                recordFailure(id: id, message: "Couldn't write the optimised file to its destination")
            }
        } catch let error as ClopError {
            switch error {
            case .alreadyOptimised, .imageSizeLarger, .videoSizeLarger, .pdfSizeLarger, .alreadyResized:
                // Not real failures: the file just couldn't get smaller, so keep it as-is.
                recordUnchanged(id: id)
            default:
                recordFailure(id: id, message: error.humanDescription, log: optimiser.errorLog)
            }
        } catch {
            recordFailure(id: id, message: error.localizedDescription, log: optimiser.errorLog)
        }

        if needsWorkingCopy { try? working.delete() }
        liveOptimisers[id] = nil
    }

    private func setProgress(id: String, _ fraction: Double) {
        guard let idx = indexByID[id] else { return }
        backing[idx].progressFraction = fraction
        markDirty(idx)
    }

    /// Place the optimised working file at its destination: the chosen output folder, or back at the
    /// original location (external-volume place-back / in-place format change). Returns false if the
    /// write fails, so the caller marks the item failed instead of reporting a phantom success.
    @discardableResult
    private func placeResult(optimiser: Optimiser, working: FilePath, destinationDir: FilePath?, original: FilePath) async -> Bool {
        let optimised = optimiser.url?.filePath ?? working
        guard optimised.exists else { return false }
        let ext = optimised.extension ?? original.extension ?? ""
        let stem = original.stem ?? "file"
        let formatChanged = (optimised.extension?.lowercased() ?? "") != (original.extension?.lowercased() ?? "")

        let dest: FilePath
        if let destinationDir {
            _ = destinationDir.mkdir(withIntermediateDirectories: true)
            // De-dup within the run so two same-named sources from different folders don't collapse
            // onto one output file (the second would otherwise overwrite the first).
            var candidate = destinationDir / "\(stem).\(ext)"
            var n = 2
            while claimedOutputPaths.contains(candidate.string) {
                candidate = destinationDir / "\(stem)-\(n).\(ext)"
                n += 1
            }
            claimedOutputPaths.insert(candidate.string)
            dest = candidate
        } else if !formatChanged {
            dest = original
        } else {
            // In-place format change (e.g. PNG→JPEG): write the new file next to the original.
            dest = original.dir / "\(stem).\(ext)"
        }

        // In-place same-format pass already wrote the result back through the pipeline.
        guard optimised != dest else { return true }

        guard await placeAtomically(optimised, at: dest) else { return false }

        // In-place conversion: drop the superseded original-format file (its pristine copy is in the backup).
        if destinationDir == nil, formatChanged, original != dest, original.exists {
            try? original.delete()
        }
        optimiser.url = dest.url
        return true
    }

    /// Copy `src` onto `dest` without ever deleting `dest` before the new bytes are safely written:
    /// stage to a sibling temp on the destination's volume, then atomically replace. Returns false on
    /// any failure (volume unplug, full disk) so the caller can mark the item failed rather than
    /// leaving an empty original and reporting success.
    private func placeAtomically(_ src: FilePath, at dest: FilePath) async -> Bool {
        // The copy + atomic replace are blocking filesystem I/O; on a large file or a slow/external
        // destination volume `copyfile` stalls for tens of seconds. `BatchManager` is @MainActor, so
        // run the whole place-back off the main actor to avoid hanging the UI (ANR).
        await Task.detached {
            let tmp = dest.dir / ".clop-place-\(UUID().uuidString).\(dest.extension ?? "tmp")"
            try? tmp.delete()
            guard (try? src.copy(to: tmp, force: true)) != nil, tmp.exists else {
                try? tmp.delete()
                return false
            }
            do {
                if dest.exists {
                    _ = try fm.replaceItemAt(dest.url, withItemAt: tmp.url)
                } else {
                    _ = try tmp.move(to: dest, force: true)
                }
                return true
            } catch {
                try? tmp.delete()
                return false
            }
        }.value
    }

    private func makeOptimiser(for item: BatchItem) -> Optimiser {
        let optimiser = Optimiser(id: item.id, type: item.type, operation: "Optimising")
        optimiser.hidden = true
        optimiser.batchSilent = true
        optimiser.source = source
        optimiser.url = item.source.url
        optimiser.aggressive = item.params.aggressive ?? false
        // Per-type compression is passed to each pipeline as the `compression:` argument, which sets
        // the optimiser's override itself, so nothing to set here.
        liveOptimisers[item.id] = optimiser
        return optimiser
    }

    // MARK: Result recording

    private func recordResult(id: String, optimiser: Optimiser) {
        guard let idx = indexByID[id] else { return }

        if let error = optimiser.error {
            recordFailure(id: id, message: error, log: optimiser.errorLog)
            return
        }

        var it = backing[idx]
        let resultPath = optimiser.url?.filePath ?? it.source
        it.resultPath = resultPath
        if optimiser.oldBytes > 0 { it.oldBytes = optimiser.oldBytes }
        it.newBytes = optimiser.newBytes > 0
            ? optimiser.newBytes
            : (resultPath.fileSize() ?? it.oldBytes)
        it.oldSize = optimiser.oldSize ?? it.oldSize
        it.newSize = optimiser.newSize ?? optimiser.oldSize ?? it.oldSize
        it.oldBitrate = optimiser.oldBitrate
        it.newBitrate = optimiser.newBitrate
        it.oldDPI = optimiser.oldDPI
        it.newDPI = optimiser.newDPI
        it.newFormat = resultPath.extension?.uppercased()
        it.progressFraction = 1
        it.status = .done
        backing[idx] = it
        markDirty(idx)
    }

    private func recordUnchanged(id: String) {
        guard let idx = indexByID[id] else { return }
        backing[idx].newBytes = backing[idx].oldBytes
        backing[idx].newFormat = backing[idx].oldFormat
        backing[idx].progressFraction = 1
        backing[idx].status = .done
        markDirty(idx)
    }

    private func recordFailure(id: String, message: String, log: String? = nil) {
        guard let idx = indexByID[id] else { return }
        backing[idx].status = .failed
        backing[idx].error = message
        backing[idx].errorLog = log
        backing[idx].progressFraction = 0
        markDirty(idx)
    }

    // MARK: Publishing

    private func setStatus(_ idx: Int, _ status: BatchStatus) {
        guard backing.indices.contains(idx) else { return }
        backing[idx].status = status
        markDirty(idx)
    }

    private func markDirty(_ idx: Int) {
        dirtyRows.insert(idx)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        mainAsyncAfter(ms: 100) { self.flush() }
    }

    private func flush() {
        flushScheduled = false
        let dirty = dirtyRows
        dirtyRows.removeAll()
        let oldOrder = items.map(\.id)
        rebuildDisplay()
        recomputeAggregate()
        if items.map(\.id) != oldOrder {
            onFlush?(true, IndexSet())
        } else {
            var rows = IndexSet()
            for backingIdx in dirty where backing.indices.contains(backingIdx) {
                if let row = displayRowByID[backing[backingIdx].id] { rows.insert(row) }
            }
            onFlush?(false, rows)
        }
    }

    private func publishNow() {
        flushScheduled = false
        dirtyRows.removeAll()
        rebuildDisplay()
        recomputeAggregate()
        onFlush?(true, IndexSet())
    }

    private func rebuildDisplay() {
        items = backing.sorted(by: isOrderedBefore)
        displayRowByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    private func finishRun(generation: Int) {
        // A newer run (or a restore) superseded this one while its task group was still draining;
        // don't reset the live run's state or fire onFinished for a run nobody is waiting on.
        guard generation == runGeneration else { return }
        isRunning = false
        gates = [:]
        orchestrator = nil
        publishNow()
        log.debug("Batch finished: \(self.aggregate.done) done, \(self.aggregate.failed) failed, saved \(self.aggregate.savedBytes) bytes")
        // Clear before firing (same discipline as cancel): the continuation it resumes must not be
        // resumed again if a window-close → cancel() lands in the gap before the awaiting CLI bridge
        // clears it, which would be a fatal double-resume.
        let cb = onFinished
        onFinished = nil
        cb?()
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: backing.enumerated().map { ($1.id, $0) })
    }

    private func recomputeAggregate() {
        var agg = BatchAggregate()
        agg.total = backing.count
        for it in backing {
            switch it.status {
            case .queued: agg.queued += 1
            case .copying: agg.copying += 1
            case .running: agg.running += 1
            case .done: agg.done += 1
            case .failed: agg.failed += 1
            case .skipped: agg.skipped += 1
            }
            agg.totalOldBytes += it.oldBytes
            agg.totalNewBytes += (it.status == .done && it.newBytes > 0) ? it.newBytes : it.oldBytes
        }
        aggregate = agg
    }

    // MARK: Ordering

    private func isOrderedBefore(_ a: BatchItem, _ b: BatchItem) -> Bool {
        if let sortKey {
            return sortAscending ? columnLess(a, b, sortKey) : columnLess(b, a, sortKey)
        }
        return compositeLess(a, b)
    }

    /// Composite default: active rows first, then grouped by file type, then depth-aware alphabetical.
    private func compositeLess(_ a: BatchItem, _ b: BatchItem) -> Bool {
        let ra = statusRank(a.status), rb = statusRank(b.status)
        if ra != rb { return ra < rb }
        let ta = typeRank(a.type), tb = typeRank(b.type)
        if ta != tb { return ta < tb }
        let da = a.source.components.count, db = b.source.components.count
        if da != db { return da < db }
        return a.source.string.localizedStandardCompare(b.source.string) == .orderedAscending
    }

    private func statusRank(_ status: BatchStatus) -> Int {
        switch status {
        case .running, .copying: 0
        case .queued: 1
        case .done: 2
        case .failed: 3
        case .skipped: 4
        }
    }

    private func typeRank(_ type: ItemType) -> Int {
        if type.isImage { 0 } else if type.isVideo { 1 } else if type.isPDF { 2 } else if type.isAudio { 3 } else { 4 }
    }

    private func columnLess(_ a: BatchItem, _ b: BatchItem, _ key: String) -> Bool {
        switch key {
        case "status":
            // The status column sorts by the composite default (active first), reversible via the header.
            compositeLess(a, b)
        case "name":
            (a.source.lastComponent?.string ?? "").localizedStandardCompare(b.source.lastComponent?.string ?? "") == .orderedAscending
        case "format":
            (a.oldFormat ?? "").localizedStandardCompare(b.oldFormat ?? "") == .orderedAscending
        case "size":
            a.oldBytes < b.oldBytes
        case "saved":
            a.savedFraction < b.savedFraction
        case "details":
            detailSortValue(a) < detailSortValue(b)
        default:
            a.id < b.id
        }
    }

    /// A single numeric proxy for the "details" column (pixel area / DPI / bitrate) so it sorts.
    private func detailSortValue(_ item: BatchItem) -> Double {
        switch item.type {
        case .pdf: Double(item.newDPI ?? item.oldDPI ?? 0)
        case .audio: Double(item.newBitrate ?? item.oldBitrate ?? 0)
        default:
            if let s = item.newSize ?? item.oldSize { Double(s.width * s.height) } else { 0 }
        }
    }
}

// MARK: - Scanning

/// Build batch items from paths using fast, extension-based type detection (NO `/usr/bin/file` shell
/// per file, which would block) so a large drop scans in milliseconds. Safe to call off the main actor.
func buildBatchItems(_ paths: [FilePath], params: BatchParams) -> [BatchItem] {
    var built: [BatchItem] = []
    // Dedup by path: BatchItem.id == source path, and the index dictionaries are built with
    // `uniqueKeysWithValues`, which traps on a duplicate id. A path can legitimately arrive twice
    // (same arg twice on the CLI, a file plus a folder that contains it), so drop repeats here.
    var seen = Set<String>()
    for path in paths where path.exists {
        guard seen.insert(path.string).inserted else { continue }
        let type = batchItemType(path)
        guard type.isImage || type.isVideo || type.isPDF || type.isAudio else { continue }
        built.append(BatchItem(
            id: path.string,
            source: path,
            type: type,
            oldBytes: path.fileSize() ?? 0,
            oldFormat: path.extension?.uppercased(),
            params: params
        ))
    }
    return built
}

/// Categorise by file extension only (no process spawn). The exact UTType within a category isn't
/// critical for batch — the category picks the pipeline.
private func batchItemType(_ path: FilePath) -> ItemType {
    let utType = path.extension.flatMap { UTType(filenameExtension: $0) }
    if path.isImage { return .image(utType ?? .image) }
    if path.isVideo { return .video(utType ?? .mpeg4Movie) }
    if path.isPDF { return .pdf }
    if path.isAudio { return .audio(utType ?? .mp3) }
    return .unknown
}

// MARK: - Action builders

/// A long-edge cap expressed as a `.downscale` crop, or a plain downscale factor, or nothing.
private func batchResizeAction(maxLongEdge: Int?, downscaleFactor: Double?) -> PipelineAction? {
    if let edge = maxLongEdge, edge > 0 {
        return .downscale(factor: nil, cropSize: CropSize(width: edge, height: edge, longEdge: true))
    }
    if let factor = downscaleFactor, factor < 1 {
        return .downscale(factor: factor, cropSize: nil)
    }
    return nil
}

private func batchImageActions(_ p: ImageBatchParams) -> [PipelineAction] {
    var actions: [PipelineAction] = []
    if let target = p.convertTo, let utType = batchImageConvertUTType(target) {
        actions.append(.convert(format: utType))
    }
    actions.append(.optimise)
    if let resize = batchResizeAction(maxLongEdge: p.maxLongEdge, downscaleFactor: p.downscaleFactor) {
        actions.append(resize)
    }
    return actions
}

private func batchVideoActions(_ p: VideoBatchParams) -> [PipelineAction] {
    var actions: [PipelineAction] = [.optimise]
    if let resize = batchResizeAction(maxLongEdge: p.maxLongEdge, downscaleFactor: p.downscaleFactor) {
        actions.append(resize)
    }
    if p.removeAudio {
        actions.append(.removeAudio)
    }
    return actions
}

private func batchImageConvertUTType(_ target: ImageConvertTarget) -> UTType? {
    switch target {
    case .jpeg: .jpeg
    case .png: .png
    case .webp: .webP
    case .jxl: .jxl
    }
}

/// ffmpeg encoder args + output extension for a video format conversion (mirrors convertToVideoFormat).
private func batchVideoConvertArgs(_ target: VideoConvertTarget?) -> (ffmpeg: [String]?, ext: String?) {
    switch target {
    case .hevc: (["-vcodec", "hevc_videotoolbox", "-q:v", "40", "-tag:v", "hvc1"], "mp4")
    case .av1: (["-vcodec", "libsvtav1"], "mkv")
    case .webm: (["-vcodec", "libvpx-vp9", "-crf", "31", "-b:v", "0", "-row-mt", "1"], "webm")
    case .mp4: (nil, "mp4")
    case nil: (nil, nil)
    }
}

/// PDF DPI override + aggressive flag from the chosen mode.
private func batchPDFDPIArgs(_ mode: PDFDPIMode, aggressive: Bool?) -> (dpi: Int?, aggressive: Bool?) {
    switch mode {
    case .useDefault: (nil, aggressive)
    case .adaptive: (PDF_DPI_ADAPTIVE, aggressive)
    case let .fixed(dpi): (dpi, aggressive)
    case .stepDown: (nil, true)
    }
}

// MARK: - CLI bridge

/// Whether a CLI/IPC request should be handled by the batch engine + window instead of the per-file
/// path: a Pro-only, non-pipeline request with more files than the configured threshold.
@MainActor func shouldRouteToBatch(_ req: OptimisationRequest) -> Bool {
    req.pipeline == nil && proactive && req.urls.count > Defaults[.batchModeFileCountThreshold]
}

/// Run a large CLI/IPC request through the batch engine + window, then stream exactly one response (or
/// error) per requested URL back over the response port so `clop` still finishes and prints results.
@MainActor func runBatchForCLI(_ req: OptimisationRequest) async -> [OptimisationResponse] {
    let paths = req.urls.compactMap(\.filePath)
    var params = BatchParams.fromDefaults()
    params.aggressive = req.aggressiveOptimisation
    params.images.adaptive = req.adaptiveOptimisation
    if let compression = req.compression {
        params.images.compression = compression
        params.video.compression = compression
        params.audio.compression = compression
    }
    params.audio.bitrate = req.audioBitrate
    if let dpi = req.pdfDPI { params.pdf.dpiMode = .fixed(dpi) }
    if let factor = req.downscaleFactor, factor < 1 { params.setUniformDownscale(factor) }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        BAT.start(paths: paths, params: params, source: req.source.optSource)
        guard BAT.isRunning else {
            cont.resume()
            return
        }
        BAT.onFinished = { cont.resume() }
        BAT.showWindow()
    }
    BAT.onFinished = nil

    let cliSource = req.source == "cli"
    let port = cliSource ? OPTIMISATION_CLI_RESPONSE_PORT : OPTIMISATION_RESPONSE_PORT
    let itemByID = Dictionary(BAT.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    var responses: [OptimisationResponse] = []
    for url in req.urls {
        let id = url.filePath?.string ?? url.path
        if let item = itemByID[id], item.status == .done {
            let resp = OptimisationResponse(
                path: (item.resultPath ?? item.source).string, forURL: url,
                oldBytes: item.oldBytes, newBytes: item.newBytes,
                oldWidthHeight: item.oldSize, newWidthHeight: item.newSize,
                oldBitrate: item.oldBitrate, newBitrate: item.newBitrate,
                oldDPI: item.oldDPI, newDPI: item.newDPI
            )
            responses.append(resp)
            try? port.sendAndForget(data: resp.jsonData)
        } else {
            let message = itemByID[id]?.error ?? "Skipped"
            try? port.sendAndForget(data: OptimisationResponseError(error: message, forURL: url).jsonData)
        }
    }
    return responses
}

// MARK: - Singleton

@MainActor let BAT = BatchManager()
