//
//  FileOps.swift
//  Clop
//
//  Copy-on-write cloning, progress-reporting copies, and volume detection used by batch mode.
//

import Cocoa
import Darwin
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "FileOps")

extension FilePath {
    /// Clone this file to `dest` using APFS copy-on-write when possible: near-instant and zero extra
    /// space until one side is modified. `copyfile(COPYFILE_CLONE)` clones on the same APFS volume
    /// and otherwise falls back to a normal copy; we add a manual `copy` fallback for safety.
    @discardableResult
    func clone(to dest: FilePath, force: Bool = true) throws -> FilePath {
        guard exists else {
            log.error("Can't clone, path doesn't exist: \(string)")
            return self
        }
        let target = dest.isDir ? dest.appending(name) : dest
        _ = target.dir.mkdir(withIntermediateDirectories: true)

        // COPYFILE_CLONE implies COPYFILE_EXCL, so the destination must not exist.
        if target.exists {
            guard force else { return target }
            try target.delete()
        }

        if copyfile(string, target.string, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 {
            return target
        }
        let err = String(cString: strerror(errno))
        log.debug("CoW clone failed (\(err)) for \(self.string) → \(target.string); falling back to copy")
        return try copy(to: target, force: true)
    }

    /// True when this file lives somewhere we'd rather copy to the internal disk before working on
    /// it: a removable, network, or otherwise non-internal volume.
    var isOnExternalVolume: Bool {
        guard let v = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsEjectableKey]) else {
            return false
        }
        if v.volumeIsRemovable == true || v.volumeIsEjectable == true { return true }
        if v.volumeIsLocal == false { return true } // network volume
        if let isInternal = v.volumeIsInternal { return !isInternal }
        return false
    }

    /// Free space (bytes) available for new files on this path's volume, or nil if unknown.
    var volumeAvailableCapacity: Int64? {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }
}

/// Copy `src` to `dest` in chunks, reporting byte-level progress via `onProgress(copied, total)` so
/// the batch UI and the CLI can show a copy progress bar (used when pulling files off an external
/// volume). Falls back to a plain copy if the streaming handles can't be opened.
@discardableResult
func copyWithProgress(
    from src: FilePath,
    to dest: FilePath,
    force: Bool = true,
    chunkSize: Int = 4 << 20,
    onProgress: (_ copied: Int64, _ total: Int64) -> Void
) throws -> FilePath {
    guard src.exists else { throw ClopError.fileNotFound(src) }
    let target = dest.isDir ? dest.appending(src.name) : dest
    _ = target.dir.mkdir(withIntermediateDirectories: true)
    if target.exists {
        guard force else { return target }
        try target.delete()
    }

    let total = Int64(src.fileSize() ?? 0)

    guard let inFH = FileHandle(forReadingAtPath: src.string) else {
        return try src.copy(to: target, force: true)
    }
    FileManager.default.createFile(atPath: target.string, contents: nil)
    guard let outFH = FileHandle(forWritingAtPath: target.string) else {
        try? inFH.close()
        return try src.copy(to: target, force: true)
    }
    defer { try? inFH.close(); try? outFH.close() }

    var copied: Int64 = 0
    onProgress(0, total)
    while true {
        let data = try inFH.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty { break }
        try outFH.write(contentsOf: data)
        copied += Int64(data.count)
        onProgress(copied, total)
    }

    // Preserve the original timestamps so the copy looks like the source to downstream tooling.
    if let attrs = try? FileManager.default.attributesOfItem(atPath: src.string) {
        let dates = attrs.filter { $0.key == .creationDate || $0.key == .modificationDate }
        try? FileManager.default.setAttributes(dates, ofItemAtPath: target.string)
    }
    return target
}
