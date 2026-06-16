//
//  BatchBackup.swift
//  Clop
//
//  Manifest-based, copy-on-write backup for batch mode. Before any processing, every source file is
//  cloned (APFS clonefile: near-instant, ~0 extra space) into a per-batch folder under
//  `FilePath.batchBackups`, keyed by the stable original path so it survives the in-place-rewrite
//  mtime-hash orphaning that breaks `clopBackupPath`. Backups are removed only by an explicit
//  `deleteBackups()` or after a verified restore, never by the time-based `fileCleaner`.
//

import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "BatchBackup")

struct BatchBackupEntry: Codable {
    let originalPath: String
    let backupPath: String
    let size: Int
}

/// `@unchecked Sendable`: `backupAll` runs once off the main actor before any concurrent access, and
/// every later read/mutation happens on the main actor, so there's no real data race.
final class BatchBackup: @unchecked Sendable {
    init(id: String) {
        self.id = id
        dir = FilePath.dir(FilePath.batchBackups / "batch-\(id)", permissions: 0o755)
        manifestPath = dir / "manifest.json"
        loadManifest()
    }

    let id: String
    let dir: FilePath
    let manifestPath: FilePath

    /// Keyed by the original absolute path.
    private(set) var entries: [String: BatchBackupEntry] = [:]

    /// Clone every source up front. Near-instant and ~0 extra space on APFS; on a non-APFS or
    /// cross-volume target `clone(to:)` falls back to a full copy. Skips sources already backed up
    /// (so re-running `start` on the same batch id is idempotent).
    func backupAll(_ sources: [FilePath]) {
        for src in sources where src.exists {
            guard entries[src.string] == nil else { continue }
            let ext = src.extension.map { ".\($0)" } ?? ""
            let target = dir / "\(UUID().uuidString)\(ext)"
            do {
                try src.clone(to: target, force: true)
                entries[src.string] = BatchBackupEntry(
                    originalPath: src.string,
                    backupPath: target.string,
                    size: src.fileSize() ?? 0
                )
            } catch {
                log.error("Failed to back up \(src.string): \(error.localizedDescription)")
            }
        }
        saveManifest()
    }

    /// The pristine backup for an original, if one exists on disk.
    func backupPath(for original: FilePath) -> FilePath? {
        guard let entry = entries[original.string] else { return nil }
        let path = FilePath(entry.backupPath)
        return path.exists ? path : nil
    }

    /// Restore the original from its pristine clone, then verify the restored file matches the backup
    /// by size and content hash. Returns false if there's no backup or verification fails (the caller
    /// should then surface an error rather than silently re-running on a possibly-corrupt file).
    @discardableResult
    func restoreVerified(_ original: FilePath) -> Bool {
        guard let backup = backupPath(for: original) else {
            log.warning("No batch backup to restore for \(original.string)")
            return false
        }
        do {
            try backup.copy(to: original, force: true)
        } catch {
            log.error("Restore failed for \(original.string): \(error.localizedDescription)")
            return false
        }

        guard let restoredSize = original.fileSize(), let backupSize = backup.fileSize(), restoredSize == backupSize else {
            log.error("Restore size mismatch for \(original.string)")
            return false
        }
        // Restores are rare (reapply / manual), so a full content hash here is fine.
        if original.fileContentsHash != backup.fileContentsHash {
            log.error("Restore hash mismatch for \(original.string)")
            return false
        }
        return true
    }

    /// Restore the original from its backup with byte-level progress (for large/slow-write restores),
    /// verifying the restored size matches. Returns false if there's no backup or the copy fails.
    @discardableResult
    func restore(_ original: FilePath, onProgress: (_ copied: Int64, _ total: Int64) -> Void) -> Bool {
        guard let backup = backupPath(for: original) else {
            log.warning("No batch backup to restore for \(original.string)")
            return false
        }
        do {
            try copyWithProgress(from: backup, to: original, onProgress: onProgress)
        } catch {
            log.error("Restore failed for \(original.string): \(error.localizedDescription)")
            return false
        }
        guard let restoredSize = original.fileSize(), let backupSize = backup.fileSize(), restoredSize == backupSize else {
            log.error("Restore size mismatch for \(original.string)")
            return false
        }
        return true
    }

    /// Remove the whole batch backup folder. Call only once every item is done/failed/skipped.
    func deleteBackups() {
        try? dir.delete()
        entries.removeAll()
    }

    private func loadManifest() {
        guard manifestPath.exists, let data = fm.contents(atPath: manifestPath.string),
              let list = try? JSONDecoder().decode([BatchBackupEntry].self, from: data)
        else { return }
        entries = Dictionary(list.map { ($0.originalPath, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else {
            log.error("Couldn't encode batch backup manifest")
            return
        }
        do {
            try data.write(to: manifestPath.url)
        } catch {
            log.error("Couldn't write batch backup manifest: \(error.localizedDescription)")
        }
    }
}
