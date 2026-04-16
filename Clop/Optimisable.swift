//
//  Optimisable.swift
//  Clop
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import Cocoa
import Foundation
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Optimisable")

class Optimisable {
    required init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.path = path
        self.id = id

        if thumb {
            mainActor { self.fetchThumbnail() }
        }
    }

    class var dir: FilePath { .tmp }

    let path: FilePath
    let id: String?

    lazy var fileSize: Int = path.fileSize() ?? 0
    lazy var hash: String = path.fileContentsHash ?? ""

    @MainActor var optimiser: Optimiser? {
        OM.optimisers.first(where: { $0.id == id ?? path.string || $0.id == path.string || $0.id == path.url.absoluteString })
    }

    @MainActor static func getOptimiser(id: String? = nil, path: FilePath) -> Optimiser? {
        OM.optimisers.first(where: { $0.id == id ?? path.string || $0.id == path.string || $0.id == path.url.absoluteString })
    }

    @MainActor static func fallbackThumbnail(for url: URL, path: FilePath) -> NSImage {
        // Try the file at its current location, then the backup, then a UTType-based generic icon.
        let candidates: [String?] = [
            url.existingFilePath?.string,
            path.string,
            path.clopBackupPath?.string,
        ]
        for case let candidate? in candidates where FileManager.default.fileExists(atPath: candidate) {
            let icon = NSWorkspace.shared.icon(forFile: candidate)
            icon.size = THUMB_SIZE
            return icon
        }
        let utType = path.url.utType() ?? (path.extension.flatMap { UTType(filenameExtension: $0) }) ?? .item
        let icon = NSWorkspace.shared.icon(for: utType)
        icon.size = THUMB_SIZE
        return icon
    }

    func copyWithPath(_ path: FilePath) -> Self {
        Self(path, thumb: true, id: id)
    }

    @MainActor func fetchThumbnail() {
        var url = path.url
        if let thumbURL = THUMBNAIL_URLS[url] {
            log.debug("Using cached thumbnail from \(thumbURL.path) for \(self.path.string)")
            url = thumbURL
        }

        // Seed with a best-effort placeholder immediately so we always have *something*.
        if let optimiser = Self.getOptimiser(id: id, path: path), optimiser.thumbnail == nil {
            optimiser.thumbnail = Self.fallbackThumbnail(for: url, path: path)
        }

        generateThumbnail(for: url, size: THUMB_SIZE, onCompletion: { [url, id, path] thumb in
            guard let optimiser = Self.getOptimiser(id: id, path: path) else {
                log.debug("Thumbnail generation cancelled for \(url.path)")
                return
            }
            log.debug("Thumbnail generated for \(path.string)")
            optimiser.thumbnail = NSImage(cgImage: thumb.cgImage, size: .zero)
        }, onFailure: { [url, id, path] in
            guard let optimiser = Self.getOptimiser(id: id, path: path) else { return }
            log.debug("Thumbnail generation failed for \(path.string), using system icon")
            optimiser.thumbnail = Self.fallbackThumbnail(for: url, path: path)
        })
    }

    func runThroughShortcut(shortcut: Shortcut? = nil, optimiser: Optimiser, allowLarger: Bool, aggressiveOptimisation: Bool, source: OptimisationSource?) throws -> Self? {
        let shortcutOutFile = (self is PDF ? FilePath.pdfs : FilePath.videos).appending("\(Date.now.timeIntervalSinceReferenceDate.i)-shortcut-output-for-\(path.stem!)")

        guard let shortcut else { return nil }
        let proc: Process? = optimiser.runShortcut(shortcut, outFile: shortcutOutFile, url: path.url)
        guard let proc else { return nil }

        proc.waitUntilExit()
        guard shortcutOutFile.exists else {
            return nil
        }
        let outfile: Self? =
            if let size = shortcutOutFile.fileSize(), size < 4096, let path = (try? String(contentsOfFile: shortcutOutFile.string))?.existingFilePath, self.path != path {
                Self(path, id: id)
            } else {
                Self(shortcutOutFile, id: id)
            }

        guard let outfile, outfile.hash != hash, outfile.fileSize > 0 else {
            return nil
        }

        if outfile.path != path {
            try outfile.path.copy(to: path, force: true)
        }
        return outfile.copyWithPath(path)
    }

}
