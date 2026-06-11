import Cocoa
import Foundation
import os
import WarpDrop

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "WarpDrop")

struct WarpDropSession: Identifiable {
    let id: String // room ID
    let files: [URL]
    let task: Task<String, Error>
    var downloadCount = 0

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

    var hasSessions: Bool { sessions.isNotEmpty }

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

    func addSession(roomID: String, files: [URL], task: Task<String, Error>) {
        connectingPaths.subtract(files.map(\.path))
        let session = WarpDropSession(id: roomID, files: files, task: task)
        sessions.append(session)
        log.debug("WarpDrop room created: \(roomID)")
    }

    func didCompleteDownload(roomID: String, count: Int) {
        guard let idx = sessions.firstIndex(where: { $0.id == roomID }) else { return }
        sessions[idx].downloadCount = count
        log.debug("WarpDrop download #\(count) completed for room \(roomID)")
    }

    func stopSession(_ session: WarpDropSession) {
        session.stop()
        sessions.removeAll { $0.id == session.id }
    }

    func stopAll() {
        for session in sessions {
            session.stop()
        }
        sessions.removeAll()
    }
}

@MainActor let WDM = WarpDropManager.shared

@MainActor
func warpDropSend(optimiser: Optimiser) {
    guard let url = optimiser.url else { return }

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
    warpDropSendFiles([url], overlayOptimisers: [optimiser])
}

@MainActor
func warpDropSend(optimisers: [Optimiser]) {
    let urls = optimisers.compactMap(\.url)
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
    warpDropSendFiles(fresh, overlayOptimisers: freshOptimisers)
}

@MainActor
private func warpDropSendFiles(_ files: [URL], overlayOptimisers: [Optimiser]) {
    let client = WarpDropClient()
    let roomIDRef = Ref<String?>(nil)

    let task = Task.detached { () -> String in
        try await client.send(
            files: files,
            keep: true,
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
                WDM.addSession(roomID: roomID, files: files, task: task)
                return
            }
            if task.isCancelled { return }
        }
    }
}

/// Send a single file securely and await the share link.
/// Returns the share URL on success, nil on failure or timeout.
@MainActor
func warpDropSendAndWait(url: URL, optimiser: Optimiser) async -> String? {
    // Already shared: return the existing link instead of opening another room.
    if let session = WDM.session(forPath: url.path) {
        return session.shareURL
    }
    // Already connecting from another trigger: don't start a duplicate transfer.
    guard WDM.reserveForSending([url]).isNotEmpty else {
        return WDM.session(forPath: url.path)?.shareURL
    }
    defer { WDM.releaseConnecting([url]) }

    let client = WarpDropClient()
    let roomIDRef = Ref<String?>(nil)

    let task = Task.detached { () -> String in
        try await client.send(
            files: [url],
            keep: true,
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
            WDM.addSession(roomID: roomID, files: [url], task: task)
            return "https://drop.lowtechguys.com/d/\(roomID)"
        }
        if task.isCancelled { return nil }
    }

    return nil
}

/// Thread-safe mutable reference for sharing values across sendable closures.
final class Ref<T>: @unchecked Sendable {
    init(_ value: T) { _value = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }

    private let lock = NSLock()
    private var _value: T

}
