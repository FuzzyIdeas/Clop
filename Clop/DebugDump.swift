import AppKit
import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "DebugDump")

/// Sendable bag of data captured on the main actor. Everything inside is
/// already serialized so the background pipeline only needs to write bytes.
private struct DebugDumpSnapshot: Sendable {
    let appInfoText: String
    let settingsData: Data
    let optimisersText: String
    let pipelinesText: String
}

enum DebugDump {
    static let outputDir = URL(fileURLWithPath: "/tmp/clop-debug", isDirectory: true)

    static let confirmationDescription = """
    Collects diagnostic data and bundles it into a single zip:

      • App, license tier and system info
      • Settings (license codes and emails are redacted)
      • Current and recent optimisation results with errors
      • Saved pipelines, automations and watched folders
      • Bundled binaries health check (ffmpeg, ghostscript etc.)
      • Working directory and backups statistics
      • Output of recently run external tools
      • Recent crash reports
      • 30-second live capture of logs, filesystem events and clipboard
        changes (reproduce the issue while it runs)
      • Logs from the last 24 hours

    The zip is written to /tmp/clop-debug and revealed in Finder so you can \
    attach it when contacting the developer. Nothing leaves your machine on its own.

    Collection takes about a minute.
    """

    @MainActor static var isRunning = false
    @MainActor static weak var progressOptimiser: Optimiser?

    @MainActor static func confirmAndRun() {
        guard !isRunning else {
            showNotice("A debug dump is already being collected")
            return
        }
        focus()
        let alert = NSAlert()
        alert.messageText = "Generate diagnostic dump?"
        alert.informativeText = confirmationDescription
        alert.addButton(withTitle: "Create dump")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runAndReveal()
    }

    @MainActor static func runAndReveal() {
        isRunning = true
        let optimiser = OM.optimiser(id: "Debug dump", type: .unknown, operation: "Collecting debug data", indeterminateProgress: true)
        progressOptimiser = optimiser

        Task.detached(priority: .userInitiated) {
            do {
                let zipURL = try await collect()
                await MainActor.run {
                    isRunning = false
                    optimiser.finish(notice: "Debug dump created\nAttach the zip when contacting the developer")
                    NSWorkspace.shared.activateFileViewerSelecting([zipURL])
                }
            } catch {
                log.error("Debug dump failed: \(String(describing: error))")
                try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                await MainActor.run {
                    isRunning = false
                    optimiser.finish(error: "Debug dump failed", notice: error.localizedDescription)
                    NSWorkspace.shared.open(outputDir)
                }
            }
        }
    }

    private static func collect() async throws -> URL {
        let snapshot = try await captureMainActorSnapshot()

        return try await Task.detached(priority: .userInitiated) { () -> URL in
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let timestamp = timestampString()
            let workDir = outputDir.appendingPathComponent("dump-\(timestamp)", isDirectory: true)
            try? FileManager.default.removeItem(at: workDir)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            await setPhase("Writing app state…")
            try writeText(snapshot.appInfoText, to: workDir.appendingPathComponent("app-info.txt"))
            try snapshot.settingsData.write(to: workDir.appendingPathComponent("settings.json"), options: .atomic)
            try writeText(snapshot.optimisersText, to: workDir.appendingPathComponent("optimisers.txt"))
            try writeText(snapshot.pipelinesText, to: workDir.appendingPathComponent("pipelines.txt"))

            await setPhase("Checking bundled binaries…")
            try writeText(binariesReport(), to: workDir.appendingPathComponent("binaries.txt"))

            await setPhase("Measuring working directory…")
            try writeText(workdirReport(), to: workDir.appendingPathComponent("workdir.txt"))

            await setPhase("Copying process logs…")
            copyRecentFiles(from: FilePath.processLogs.url, to: workDir.appendingPathComponent("process-logs", isDirectory: true), newest: 30, tailBytes: 5 * 1_048_576)

            await setPhase("Copying crash reports…")
            copyCrashReports(to: workDir.appendingPathComponent("crashes", isDirectory: true))
            copySyncLog(to: workDir)

            // 30s capture window: stream this app's log live via `log stream
            // --level debug`. Debug (and unfetched info) entries are never
            // persisted to disk, so `log show` can't see them after the fact;
            // only the live stream taps the in-memory feed, so this is the one
            // path that captures every level while the user reproduces an issue.
            // In parallel, an unfiltered fsevents + clipboard trace records what
            // the system delivered vs what Clop's watchers actually handled.
            await startEventRecording()
            try await captureLiveLogs(to: workDir.appendingPathComponent("oslog-live-30s.log"), duration: 30)
            let eventsLog = await stopEventRecording()
            try writeText(eventsLog, to: workDir.appendingPathComponent("events-live-30s.log"))

            await setPhase("Reading 24h of logs…")
            try await dumpOSLog(to: workDir.appendingPathComponent("oslog-historic-24h.log"))

            await setPhase("Compressing…")
            let zipURL = outputDir.appendingPathComponent("clop-debug-dump-\(timestamp).zip")
            try? FileManager.default.removeItem(at: zipURL)
            try zipDirectoryContents(of: workDir, to: zipURL)

            try? FileManager.default.removeItem(at: workDir)
            return zipURL
        }.value
    }

    @MainActor
    private static func captureMainActorSnapshot() throws -> DebugDumpSnapshot {
        DebugDumpSnapshot(
            appInfoText: appInfoSnapshot(),
            settingsData: try settingsSnapshot(),
            optimisersText: optimisersSnapshot(),
            pipelinesText: pipelinesSnapshot()
        )
    }

    private static func setPhase(_ s: String) async {
        await MainActor.run { progressOptimiser?.operation = s }
    }

    // MARK: - Snapshots (read main-actor state)

    @MainActor
    private static func appInfoSnapshot() -> String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "Clop v\(Bundle.main.version) (build \(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "architecture: \(ARCH)",
            "locale: \(Locale.current.identifier)",
            "license: \(proactive ? "Pro" : "Free")",
            "dump created: \(Date())",
            "",
            "workdir: \(FilePath.workdir.string)",
            "paused automatic optimisations: \(Defaults[.pauseAutomaticOptimisations])",
            "CLI installed: \(Defaults[.cliInstalled])",
            "menubar icon: \(Defaults[.showMenubarIcon])",
        ]
        if let app = OM.lastClipboardSourceApp.bundleID {
            lines.append("last clipboard source app: \(app) (\(OM.lastClipboardSourceApp.name ?? "?"))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// All explicitly-set defaults for this app, with anything license- or
    /// identity-shaped redacted. Keys still at their default value don't
    /// appear; `settings.json` shows what the user changed.
    private static func settingsSnapshot() throws -> Data {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.lowtechguys.Clop") ?? [:]
        let sensitive = ["license", "licence", "serial", "email", "activation", "paddle", "token", "secret", "password"]
        var out: [String: Any] = [:]
        for (key, value) in domain {
            let lower = key.lowercased()
            out[key] = sensitive.contains(where: { lower.contains($0) }) ? "<redacted>" : jsonSafe(value)
        }
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    }

    @MainActor
    private static func optimisersSnapshot() -> String {
        var lines: [String] = []

        func describe(_ o: Optimiser) {
            lines.append("  - id: \(o.id)")
            lines.append("    type: \(String(describing: o.type))  source: \(o.source.map { String(describing: $0) } ?? "<nil>")")
            lines.append("    running: \(o.running)  operation: \(o.operation)  progress: \(o.progress.fractionCompleted)  step: \(o.stepIndicator)")
            if let error = o.error { lines.append("    error: \(error)") }
            if let notice = o.notice { lines.append("    notice: \(notice)") }
            lines.append("    bytes: \(o.oldBytes) -> \(o.newBytes)")
            if let old = o.oldSize { lines.append("    size: \(Int(old.width))x\(Int(old.height)) -> \(o.newSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "<nil>")") }
            if let old = o.oldBitrate { lines.append("    bitrate: \(old) -> \(o.newBitrate.map(String.init) ?? "<nil>")") }
            if let old = o.oldDPI { lines.append("    dpi: \(old) -> \(o.newDPI.map(String.init) ?? "<nil>")") }
            lines.append("    aggressive: \(o.aggressive)  downscaleFactor: \(o.downscaleFactor)  playbackSpeed: \(o.changePlaybackSpeedFactor)  isOriginal: \(o.isOriginal)")
            lines.append("    url: \(o.url?.path ?? "<nil>")")
            if let u = o.originalURL { lines.append("    originalURL: \(u.path)") }
            if let u = o.startingURL { lines.append("    startingURL: \(u.path)") }
            if let u = o.convertedFromURL { lines.append("    convertedFromURL: \(u.path)") }
            if o.tempPipeline.isNotEmpty {
                lines.append("    pipeline: \(o.tempPipeline.map(\.displayString).joined(separator: " -> "))")
            }
            if let p = o.automationPipeline {
                lines.append("    automation: \(p.name ?? p.id) [\(p.rawText ?? p.steps.map(\.displayString).joined(separator: " -> "))]")
            }
            if let bid = o.copiedFromAppBundleID { lines.append("    copiedFrom: \(bid)") }
            lines.append("    startedAt: \(o.startedAt)  hidden: \(o.hidden)")
        }

        lines.append("# Counters: done=\(OM.doneCount) failed=\(OM.failedCount) visible=\(OM.visibleCount)")
        lines.append("")
        lines.append("# Active optimisers (\(OM.optimisers.count))")
        for o in OM.optimisers.sorted(by: { $0.startedAt < $1.startedAt }) {
            describe(o)
        }
        lines.append("")
        lines.append("# Removed optimisers, most recent last (\(OM.removedOptimisers.count))")
        for o in OM.removedOptimisers.suffix(20) {
            describe(o)
        }
        lines.append("")
        lines.append("# Skipped because of free version limits (\(OM.skippedBecauseNotPro.count))")
        for url in OM.skippedBecauseNotPro {
            lines.append("  - \(url.path)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func pipelinesSnapshot() -> String {
        var lines: [String] = []

        lines.append("# Saved pipelines (\(Defaults[.savedPipelines].count))")
        for p in Defaults[.savedPipelines] {
            let type = p.fileType.map { String(describing: $0) } ?? "any"
            lines.append("  - \(p.name ?? "<unnamed>") (\(type))  id=\(p.id)  skipOptimisation=\(p.skipOptimisation)  hideResult=\(p.hideResult)")
            lines.append("      \(p.rawText ?? p.steps.map(\.displayString).joined(separator: " -> "))")
        }

        func automations(_ title: String, _ byDir: [String: [Pipeline]]) {
            lines.append("")
            lines.append("# \(title) (\(byDir.count) folders)")
            for (dir, pipelines) in byDir.sorted(by: { $0.key < $1.key }) {
                let exists = FileManager.default.fileExists(atPath: dir)
                lines.append("  \(dir)\(exists ? "" : "  [MISSING]")")
                for p in pipelines {
                    let r = p.resolved
                    let ref = p.isLibraryReference ? " (library ref: \(p.libraryID ?? "?"))" : ""
                    lines.append("    -> \(r.name ?? "<unnamed>")\(ref)  [\(r.rawText ?? r.steps.map(\.displayString).joined(separator: " -> "))]")
                }
            }
        }
        automations("Image automations", Defaults[.pipelinesToRunOnImage])
        automations("Video automations", Defaults[.pipelinesToRunOnVideo])
        automations("PDF automations", Defaults[.pipelinesToRunOnPdf])
        automations("Audio automations", Defaults[.pipelinesToRunOnAudio])

        func watched(_ title: String, _ dirs: [String]) {
            lines.append("")
            lines.append("# Watched \(title) folders (\(dirs.count))")
            for dir in dirs {
                let exists = FileManager.default.fileExists(atPath: dir)
                lines.append("  - \(dir)\(exists ? "" : "  [MISSING]")")
            }
        }
        watched("image", Defaults[.imageDirs])
        watched("video", Defaults[.videoDirs])
        watched("PDF", Defaults[.pdfDirs])
        watched("audio", Defaults[.audioDirs])

        let shortcuts = Defaults[.shortcutToRunOnImage].map { ("image", $0) }
            + Defaults[.shortcutToRunOnVideo].map { ("video", $0) }
            + Defaults[.shortcutToRunOnPdf].map { ("pdf", $0) }
        if shortcuts.isNotEmpty {
            lines.append("")
            lines.append("# Legacy per-folder shortcuts (\(shortcuts.count))")
            for (type, kv) in shortcuts {
                lines.append("  - [\(type)] \(kv.key) -> \(kv.value.name)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Binaries

    /// Presence, size and `--version` output of every bundled binary. Most
    /// "optimisation does nothing" reports come down to a missing or
    /// quarantined binary after the first-launch decompression failed.
    private static func binariesReport() -> String {
        let versionArgs: [String: [String]] = [
            "ffmpeg": ["-version"], "ffprobe": ["-version"], "gs": ["--version"],
            "pngquant": ["--version"], "jpegoptim": ["--version"], "gifsicle": ["--version"],
            "exiftool": ["-ver"], "cwebp": ["-version"], "gifski": ["--version"],
            "vips": ["--version"], "heif-enc": ["--version"],
        ]
        var lines = [
            "bin dir: \(BIN_DIR.path)",
            "bin dir exists: \(FileManager.default.fileExists(atPath: BIN_DIR.path))",
            "",
        ]
        let entries = (try? FileManager.default.contentsOfDirectory(at: BIN_DIR, includingPropertiesForKeys: [.fileSizeKey, .isExecutableKey])) ?? []
        if entries.isEmpty {
            lines.append("NO BINARIES FOUND — first-launch decompression of bin.tar.lrz likely failed")
        }
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isExecutableKey])
            let size = values?.fileSize ?? 0
            let executable = values?.isExecutable ?? false
            var line = "  - \(name)  size=\(size)  executable=\(executable)"
            if let args = versionArgs[name], executable {
                let version = runForOutput(url.path, args: args, timeout: 5)?
                    .components(separatedBy: .newlines)
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "<no output>"
                line += "  version: \(version)"
            }
            lines.append(line)
        }

        lines.append("")
        lines.append("# Finder extension")
        lines.append(runForOutput("/usr/bin/pluginkit", args: ["-m", "-v", "-i", "com.lowtechguys.Clop.FinderOptimiser"], timeout: 5) ?? "<pluginkit query failed>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Workdir

    private static func workdirReport() -> String {
        var lines: [String] = []
        let dirs: [(String, FilePath)] = [
            ("workdir", .workdir), ("backups", .clopBackups), ("images", .images),
            ("videos", .videos), ("pdfs", .pdfs), ("conversions", .conversions),
            ("downloads", .downloads), ("for-resize", .forResize), ("for-filters", .forFilters),
            ("finder-quick-action", .finderQuickAction), ("process-logs", .processLogs),
        ]
        for (name, dir) in dirs {
            let (count, bytes) = dirStats(dir.url)
            lines.append("  \(name): \(count) files, \(bytes) bytes  [\(dir.string)]")
        }
        if let free = try? FilePath.workdir.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            lines.append("")
            lines.append("free disk space on workdir volume: \(free) bytes")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func dirStats(_ dir: URL) -> (count: Int, bytes: Int) {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        var count = 0
        var bytes = 0
        for case let url as URL in enumerator {
            guard count < 50000, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            count += 1
            bytes += values.fileSize ?? 0
        }
        return (count, bytes)
    }

    // MARK: - File copying

    /// Copy the `newest` most recently modified files from `source`, keeping at
    /// most the last `tailBytes` of each so a runaway ffmpeg log can't balloon the dump.
    private static func copyRecentFiles(from source: URL, to dest: URL, newest: Int, tailBytes: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return
        }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let sorted = entries.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in sorted.prefix(newest) {
            let target = dest.appendingPathComponent(url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= tailBytes {
                try? FileManager.default.copyItem(at: url, to: target)
            } else if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: UInt64(size - tailBytes))
                if let data = try? handle.readToEnd() {
                    try? data.write(to: target)
                }
                try? handle.close()
            }
        }
    }

    /// The licensing sync log from the app's caches folder, if one was written.
    private static func copySyncLog(to dest: URL) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let syncLog = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lowtechguys.Clop")
            .appendingPathComponent("sync.log")
        guard FileManager.default.fileExists(atPath: syncLog.path) else { return }
        try? FileManager.default.copyItem(at: syncLog, to: dest.appendingPathComponent("sync.log"))
    }

    private static func copyCrashReports(to dest: URL) {
        let reports = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let clopReports = entries.filter { $0.lastPathComponent.hasPrefix("Clop") }
        guard clopReports.isNotEmpty else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let sorted = clopReports.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for url in sorted.prefix(5) {
            try? FileManager.default.copyItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent))
        }
    }

    // MARK: - OSLog

    private static func dumpOSLog(to url: URL) async throws {
        let predicate = "subsystem == \"\(LOG_SUBSYSTEM)\""
        try await runProcess(
            launchPath: "/usr/bin/log",
            arguments: ["show", "--predicate", predicate, "--last", "24h", "--info", "--debug", "--style", "compact"],
            stdoutTo: url
        )
    }

    /// Streams every log entry this process emits during a `duration`-second
    /// window into `url`. Unlike `log show`, which only sees entries the system
    /// persisted to disk, `log stream` taps the live in-memory feed, so
    /// `--level debug` is the only way to capture debug and info entries.
    /// The phase counts the seconds down so the user can pace the reproduction.
    private static func captureLiveLogs(to url: URL, duration: TimeInterval) async throws {
        let predicate = "subsystem == \"\(LOG_SUBSYSTEM)\""

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        let proc = Process()
        proc.launchPath = "/usr/bin/log"
        proc.arguments = ["stream", "--predicate", predicate, "--level", "debug", "--style", "compact"]
        proc.standardOutput = handle
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        defer {
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            try? handle.close()
        }

        let total = Int(duration)
        for remaining in stride(from: total, through: 1, by: -1) {
            await setPhase("Capturing logs and events, reproduce the issue now… \(remaining)s")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Live event recording

    /// Time-ordered trace of every filesystem event in the watched folders and
    /// every clipboard change during the capture window, unfiltered. Clop's
    /// watchers add ">>> handled by Clop" markers through `DebugDump.record`,
    /// so an event Clop filtered out is visible by the absence of a marker.
    @MainActor
    final class EventRecorder {
        private(set) var lines: [String] = []
        let startedAt = Date()

        func append(_ line: String) {
            lines.append(String(format: "%8.3fs  %@", Date().timeIntervalSince(startedAt), line))
        }
    }

    @MainActor static var eventRecorder: EventRecorder?
    @MainActor private static var clipboardMonitorTimer: Timer?
    @MainActor private static let fseventsMonitorKey = NSObject()

    /// Called by Clop's clipboard and file watchers when they accept an event,
    /// so the live event trace can mark what was actually handled. No-op
    /// unless a debug dump capture window is open.
    @MainActor static func record(_ line: String) {
        eventRecorder?.append(line)
    }

    @MainActor
    private static func startEventRecording() {
        let recorder = EventRecorder()
        eventRecorder = recorder

        let dirs = Set(Defaults[.imageDirs] + Defaults[.videoDirs] + Defaults[.pdfDirs] + Defaults[.audioDirs])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
        recorder.append("[info] raw fsevents stream on \(dirs.count) watched folders: \(dirs.joined(separator: " "))")
        if dirs.isNotEmpty {
            do {
                // .markSelf labels Clop's own writes with the ownEvent flag in the trace
                try LowtechFSEvents.startWatching(paths: dirs, for: ObjectIdentifier(fseventsMonitorKey), latency: 0, flags: [.noDefer, .fileEvents, .markSelf]) { event in
                    mainActor {
                        eventRecorder?.append("[fsevent] \(event.path)  flags=\(event.flag.map { String(describing: $0) } ?? "<none>")")
                    }
                }
            } catch {
                recorder.append("[info] failed to start raw fsevents stream: \(error)")
            }
        }

        recorder.append("[info] clipboard changeCount at start: \(NSPasteboard.general.changeCount)")
        var lastChangeCount = NSPasteboard.general.changeCount
        clipboardMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let pb = NSPasteboard.general
            let changeCount = pb.changeCount
            guard changeCount != lastChangeCount else { return }
            lastChangeCount = changeCount
            let item = pb.pasteboardItems?.first
            let types = item?.types.map(\.rawValue).joined(separator: " ") ?? "<no items>"
            let source = item?.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
                ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
            mainActor {
                eventRecorder?.append("[clipboard] change #\(changeCount)  source=\(source)  types=[\(types)]")
            }
        }
    }

    @MainActor
    private static func stopEventRecording() -> String {
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(fseventsMonitorKey))
        clipboardMonitorTimer?.invalidate()
        clipboardMonitorTimer = nil
        defer { eventRecorder = nil }
        return (eventRecorder?.lines.joined(separator: "\n") ?? "") + "\n"
    }

    // MARK: - Zip

    private static func zipDirectoryContents(of workDir: URL, to zipURL: URL) throws {
        let entries = (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        let names = entries.map(\.lastPathComponent)
        try runProcessSync(launchPath: "/usr/bin/zip", arguments: ["-9", "-q", "-r", zipURL.path] + names, workingDirectory: workDir)
    }

    // MARK: - IO

    private static func writeText(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// JSON-serializable conversion of arbitrary plist values.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let n as NSNumber: return n
        case let s as String: return s
        case let d as Data: return String(data: d, encoding: .utf8) ?? "<\(d.count) bytes of binary data>"
        case let date as Date: return date.description
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = jsonSafe(v)
            }
            return out
        case let arr as [Any]: return arr.map(jsonSafe)
        default: return String(describing: value)
        }
    }

    // MARK: - Process

    /// Run a binary and return its merged stdout+stderr, or nil on failure.
    /// Kills the process after `timeout` seconds so a broken binary can't hang the dump.
    private static func runForOutput(_ launchPath: String, args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do { try proc.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            usleep(50000)
        }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
            return "<timed out after \(Int(timeout))s>"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runProcessSync(launchPath: String, arguments: [String], workingDirectory: URL? = nil, stdoutTo: URL? = nil) throws {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = arguments
        if let workingDirectory {
            proc.currentDirectoryURL = workingDirectory
        }
        if let stdoutTo {
            FileManager.default.createFile(atPath: stdoutTo.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: stdoutTo) {
                proc.standardOutput = handle
            }
        }
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "DebugDump",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(launchPath) exited with status \(proc.terminationStatus)"]
            )
        }
    }

    private static func runProcess(launchPath: String, arguments: [String], workingDirectory: URL? = nil, stdoutTo: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try runProcessSync(launchPath: launchPath, arguments: arguments, workingDirectory: workingDirectory, stdoutTo: stdoutTo)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
