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

    var hasSessions: Bool { sessions.isNotEmpty }

    func session(forPath path: String) -> WarpDropSession? {
        sessions.first { s in s.files.contains { $0.path == path } }
    }

    func session(forOptimiser optimiser: Optimiser) -> WarpDropSession? {
        guard let path = optimiser.url?.path else { return nil }
        return session(forPath: path)
    }

    func addSession(roomID: String, files: [URL], task: Task<String, Error>) {
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
    optimiser.warpDropConnecting = true
    warpDropSendFiles([url], overlayOptimiser: optimiser)
}

@MainActor
func warpDropSend(optimisers: [Optimiser]) {
    let urls = optimisers.compactMap(\.url)
    guard urls.isNotEmpty else { return }
    warpDropSendFiles(urls, overlayOptimiser: optimisers.first)
}

@MainActor
private func warpDropSendFiles(_ files: [URL], overlayOptimiser: Optimiser?) {
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

                    overlayOptimiser?.warpDropConnecting = false
                    overlayOptimiser?.overlayMessage = "Copied link"
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
        defer { overlayOptimiser?.warpDropConnecting = false }
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
