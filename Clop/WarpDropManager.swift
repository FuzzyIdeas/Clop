import Cocoa
import Defaults
import Foundation
import os
import WarpDrop

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "WarpDrop")

// MARK: - Link expiration

/// Snap points for the "link expires after" picker, 1 minute up to 3 days.
/// The transfer is peer-to-peer (the room is only alive while this Mac serves it), so
/// "expiring" a link means automatically stopping the session after this interval.
let LINK_EXPIRATION_PRESETS: [TimeInterval] = [
    60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 45 * 60,
    3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600,
    86400, 2 * 86400, 3 * 86400,
]

/// Sentinel for "never expire" (the link lives until the app quits or it is stopped manually).
let LINK_EXPIRATION_NEVER: TimeInterval = 0

func nearestExpirationPresetIndex(_ t: TimeInterval) -> Int {
    LINK_EXPIRATION_PRESETS.indices.min(by: { abs(LINK_EXPIRATION_PRESETS[$0] - t) < abs(LINK_EXPIRATION_PRESETS[$1] - t) }) ?? 0
}

/// Long label for menus/overlays: "1 minute", "45 minutes", "1 hour", "3 days".
func expirationDurationLabel(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    guard s > 0 else { return "never" }
    if s % 86400 == 0 { let d = s / 86400; return "\(d) day\(d == 1 ? "" : "s")" }
    if s % 3600 == 0 { let h = s / 3600; return "\(h) hour\(h == 1 ? "" : "s")" }
    let m = max(1, s / 60); return "\(m) minute\(m == 1 ? "" : "s")"
}

/// Short label for compact buttons: 1m, 45m, 1h, 3d (∞ for never).
func expirationShortLabel(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    guard s > 0 else { return "∞" }
    if s % 86400 == 0 { return "\(s / 86400)d" }
    if s % 3600 == 0 { return "\(s / 3600)h" }
    return "\(max(1, s / 60))m"
}

/// Parse a duration token like "30s", "5m", "1h", "2d", "never" (the copyLinkForSending step param).
func parseExpirationDuration(_ str: String) -> TimeInterval? {
    let s = str.trimmingCharacters(in: .whitespaces).lowercased()
    if s == "never" || s == "0" { return 0 }
    let units: [(String, TimeInterval)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
    for (suffix, mult) in units where s.hasSuffix(suffix) {
        if let n = Double(s.dropLast(suffix.count)), n >= 0 { return n * mult }
    }
    if let n = Double(s), n >= 0 { return n } // bare seconds
    return nil
}

struct WarpDropSession: Identifiable {
    let id: String // room ID
    let files: [URL]
    let task: Task<String, Error>
    var downloadCount = 0
    /// When the link auto-stops, or nil for no expiration.
    var expiresAt: Date?

    /// Human label for the remaining time, e.g. "Expires in 42 minutes". nil when no expiration.
    var expiresInLabel: String? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return "Expiring now" }
        return "Expires in \(expirationDurationLabel(remaining))"
    }

    var directURL: String {
        "https://drop.lowtechguys.com/d/\(id)"
    }

    var roomURL: String {
        "https://drop.lowtechguys.com/r/\(id)"
    }

    var shareURL: String {
        files.count == 1 ? directURL : roomURL
    }

    var fileNames: String {
        files.map(\.lastPathComponent).joined(separator: ", ")
    }

    func copyLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(shareURL, forType: .string)
    }

    func stop() {
        task.cancel()
    }
}

@MainActor
class WarpDropManager: ObservableObject {
    static let shared = WarpDropManager()

    @Published var sessions: [WarpDropSession] = []

    /// Paths of files whose transfer has been started but whose room hasn't been
    /// created yet. A live session only appears in `sessions` once the server
    /// returns a room ID (up to 30s later), so this tracks the in-between window
    /// to stop a second trigger from creating a duplicate link for the same file.
    @Published private(set) var connectingPaths: Set<String> = []

    var hasSessions: Bool {
        sessions.isNotEmpty
    }

    func session(forPath path: String) -> WarpDropSession? {
        sessions.first { s in s.files.contains { $0.path == path } }
    }

    func session(forOptimiser optimiser: Optimiser) -> WarpDropSession? {
        guard let path = optimiser.url?.path else { return nil }
        return session(forPath: path)
    }

    func isConnecting(path: String?) -> Bool {
        guard let path else { return false }
        return connectingPaths.contains(path)
    }

    /// A file is "active" if it already has a live session or a send in flight.
    func isActive(path: String) -> Bool {
        connectingPaths.contains(path) || session(forPath: path) != nil
    }

    /// Reserve the given files for sending and return only the subset that wasn't
    /// already active. Files already covered by a session or an in-flight send are
    /// dropped so we never start a second transfer (and second link) for them.
    /// Returns an empty array when every file is already active — the caller
    /// should then copy the existing link(s) instead of starting a new transfer.
    func reserveForSending(_ urls: [URL]) -> [URL] {
        let fresh = urls.filter { !isActive(path: $0.path) }
        connectingPaths.formUnion(fresh.map(\.path))
        return fresh
    }

    func releaseConnecting(_ urls: [URL]) {
        connectingPaths.subtract(urls.map(\.path))
    }

    func addSession(roomID: String, files: [URL], task: Task<String, Error>, expiresAt: Date? = nil) {
        connectingPaths.subtract(files.map(\.path))
        let session = WarpDropSession(id: roomID, files: files, task: task, expiresAt: expiresAt)
        sessions.append(session)
        scheduleExpiry(roomID: roomID, expiresAt: expiresAt)
        log.debug("WarpDrop room created: \(roomID), expires: \(expiresAt?.description ?? "never")")
    }

    /// Change the expiration of a live session (from the active-link menu).
    func rescheduleExpiry(_ session: WarpDropSession, to expiration: TimeInterval) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let newExpiry = expiration > 0 ? Date().addingTimeInterval(expiration) : nil
        sessions[idx].expiresAt = newExpiry
        scheduleExpiry(roomID: session.id, expiresAt: newExpiry)
    }

    func didCompleteDownload(roomID: String, count: Int) {
        guard let idx = sessions.firstIndex(where: { $0.id == roomID }) else { return }
        sessions[idx].downloadCount = count
        log.debug("WarpDrop download #\(count) completed for room \(roomID)")
    }

    func stopSession(_ session: WarpDropSession) {
        expiryTimers[session.id]?.cancel()
        expiryTimers[session.id] = nil
        session.stop()
        sessions.removeAll { $0.id == session.id }
    }

    func stopAll() {
        for timer in expiryTimers.values {
            timer.cancel()
        }
        expiryTimers.removeAll()
        for session in sessions {
            session.stop()
        }
        sessions.removeAll()
    }

    /// Auto-stop timers keyed by room ID. Cancelled when a session is stopped early or re-scheduled.
    private var expiryTimers: [String: Task<Void, Never>] = [:]

    /// (Re)arm the auto-stop timer for a room. A nil date disarms it (no expiration).
    private func scheduleExpiry(roomID: String, expiresAt: Date?) {
        expiryTimers[roomID]?.cancel()
        expiryTimers[roomID] = nil
        guard let expiresAt else { return }

        expiryTimers[roomID] = Task { @MainActor [weak self] in
            let delay = max(0, expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let session = sessions.first(where: { $0.id == roomID }) else { return }
            log.debug("WarpDrop link expired, stopping room \(roomID)")
            stopSession(session)
        }
    }

}

@MainActor let WDM = WarpDropManager.shared

/// Resolve a requested expiration (nil → the default setting) into an absolute stop date,
/// or nil when the value resolves to "never".
@MainActor
func resolveLinkExpiry(_ expiration: TimeInterval?) -> Date? {
    let interval = expiration ?? Defaults[.defaultLinkExpiration]
    return interval > 0 ? Date().addingTimeInterval(interval) : nil
}

@MainActor
func warpDropSend(optimiser: Optimiser, expiration: TimeInterval? = nil) {
    guard let url = optimiser.url else { return }
    guard FileManager.default.fileExists(atPath: url.path) else {
        optimiser.overlayMessage = "File not found"
        return
    }

    // Already shared: copy the existing link instead of creating a second one.
    if let session = WDM.session(forOptimiser: optimiser) {
        session.copyLink()
        optimiser.overlayMessage = "Copied link"
        return
    }
    // Already connecting (room not created yet): don't start a second transfer.
    // The link is copied to the pasteboard automatically once the room is ready.
    guard WDM.reserveForSending([url]).isNotEmpty else { return }

    optimiser.warpDropConnecting = true
    warpDropSendFiles([url], overlayOptimisers: [optimiser], expiration: expiration)
}

@MainActor
func warpDropSend(optimisers: [Optimiser], expiration: TimeInterval? = nil) {
    let urls = optimisers.compactMap { opt -> URL? in
        guard let url = opt.url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            opt.overlayMessage = "File not found"
            return nil
        }
        return url
    }
    guard urls.isNotEmpty else { return }

    // Only send files that aren't already shared or in flight, so re-pressing
    // "Send files securely" on the same selection can't create duplicate links.
    let fresh = WDM.reserveForSending(urls)
    guard fresh.isNotEmpty else {
        let links = optimisers.compactMap { WDM.session(forOptimiser: $0)?.shareURL }
        if links.isNotEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(links.joined(separator: "\n"), forType: .string)
        }
        return
    }

    let freshPaths = Set(fresh.map(\.path))
    let freshOptimisers = optimisers.filter { freshPaths.contains($0.url?.path ?? "") }
    for optimiser in freshOptimisers {
        optimiser.warpDropConnecting = true
    }
    warpDropSendFiles(fresh, overlayOptimisers: freshOptimisers, expiration: expiration)
}

@MainActor
private func warpDropSendFiles(_ files: [URL], overlayOptimisers: [Optimiser], expiration: TimeInterval? = nil) {
    let expiresAt = resolveLinkExpiry(expiration)
    let client = WarpDropClient()
    let roomIDRef = Ref<String?>(nil)

    let task = Task.detached { () -> String in
        try await client.send(
            files: files,
            multi: true, // serve every receiver at once instead of one-at-a-time
            maxReceivers: 20, // 0 = server default (256); old backends ignore multi and fall back to sequential
            onRoomCreated: { [roomIDRef] roomID in
                roomIDRef.value = roomID
                Task { @MainActor in
                    let shareURL = files.count == 1
                        ? "https://drop.lowtechguys.com/d/\(roomID)"
                        : "https://drop.lowtechguys.com/r/\(roomID)"
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(shareURL, forType: .string)

                    for optimiser in overlayOptimisers {
                        optimiser.warpDropConnecting = false
                    }
                    overlayOptimisers.first?.overlayMessage = "Copied link"
                }
            },
            onDownloadCompleted: { [roomIDRef] count in
                guard let roomID = roomIDRef.value else { return }
                Task { @MainActor in
                    WDM.didCompleteDownload(roomID: roomID, count: count)
                }
            }
        )
    }

    Task {
        defer {
            for optimiser in overlayOptimisers {
                optimiser.warpDropConnecting = false
            }
            // Clear the in-flight reservation if the room never got created
            // (timeout/cancel). On success addSession already cleared it.
            WDM.releaseConnecting(files)
        }
        for _ in 0 ..< 300 {
            try? await Task.sleep(for: .milliseconds(100))
            if let roomID = roomIDRef.value {
                WDM.addSession(roomID: roomID, files: files, task: task, expiresAt: expiresAt)
                return
            }
            if task.isCancelled { return }
        }
    }
}

/// Send a single file securely and await the share link.
/// Returns the share URL on success, nil on failure or timeout.
@MainActor
func warpDropSendAndWait(url: URL, optimiser: Optimiser, expiration: TimeInterval? = nil) async -> String? {
    // Already shared: return the existing link instead of opening another room.
    if let session = WDM.session(forPath: url.path) {
        return session.shareURL
    }
    // Already connecting from another trigger: don't start a duplicate transfer.
    guard WDM.reserveForSending([url]).isNotEmpty else {
        return WDM.session(forPath: url.path)?.shareURL
    }
    defer { WDM.releaseConnecting([url]) }

    let expiresAt = resolveLinkExpiry(expiration)
    let client = WarpDropClient()
    let roomIDRef = Ref<String?>(nil)

    let task = Task.detached { () -> String in
        try await client.send(
            files: [url],
            multi: true, // serve every receiver at once instead of one-at-a-time
            maxReceivers: 20, // 0 = server default (256); old backends ignore multi and fall back to sequential
            onRoomCreated: { [roomIDRef] roomID in
                roomIDRef.value = roomID
                Task { @MainActor in
                    let shareURL = "https://drop.lowtechguys.com/d/\(roomID)"
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(shareURL, forType: .string)
                    optimiser.overlayMessage = "Copied link"
                }
            },
            onDownloadCompleted: { [roomIDRef] count in
                guard let roomID = roomIDRef.value else { return }
                Task { @MainActor in
                    WDM.didCompleteDownload(roomID: roomID, count: count)
                }
            }
        )
    }

    for _ in 0 ..< 300 {
        try? await Task.sleep(for: .milliseconds(100))
        if let roomID = roomIDRef.value {
            WDM.addSession(roomID: roomID, files: [url], task: task, expiresAt: expiresAt)
            return "https://drop.lowtechguys.com/d/\(roomID)"
        }
        if task.isCancelled { return nil }
    }

    return nil
}

/// Thread-safe mutable reference for sharing values across sendable closures.
final class Ref<T>: @unchecked Sendable {
    init(_ value: T) {
        _value = value
    }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }

    private let lock = NSLock()
    private var _value: T

}
