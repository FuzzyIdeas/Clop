//
//  Optimisable.swift
//  Clop
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import Cocoa
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Optimisable")

/// Placeholder-icon lookups run here so LaunchServices never blocks the main actor.
let thumbnailQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "com.lowtechguys.Clop").thumbnail", qos: .userInitiated)

class Optimisable {
    required init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.path = path
        self.id = id

        if thumb {
            mainActor { self.fetchThumbnail() }
        }
    }

    class var dir: FilePath {
        .tmp
    }

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

    /// Set the placeholder icon on `optimiser` without blocking the main actor. `NSWorkspace.icon(forFile:)`
    /// is a synchronous LaunchServices round-trip that stalls for 30s+ when the file sits on a slow or
    /// unresponsive volume (CLOP-286), and it only ever produces a placeholder, so nothing needs it
    /// synchronously. Skips the assignment if a real thumbnail landed while the icon was being resolved.
    static func setFallbackThumbnail(on optimiser: Optimiser, for url: URL, path: FilePath) {
        thumbnailQueue.async {
            let icon = fallbackThumbnail(for: url, path: path)
            mainActor {
                guard optimiser.thumbnail == nil else { return }
                optimiser.thumbnail = icon
            }
        }
    }

    static func fallbackThumbnail(for url: URL, path: FilePath) -> NSImage {
        icon(forExtension: path.extension ?? url.pathExtension)
    }

    /// The generic system icon for a file extension, resolved once per type and reused.
    ///
    /// This used to call `NSWorkspace.icon(forFile:)` on the actual file, which stats it and asks
    /// LaunchServices to bind a URL: a round-trip that stalled for 30s+ per file on a slow or
    /// unresponsive volume (CLOP-286). Every file of a given type gets the same generic icon anyway,
    /// so one lookup per type is enough, and a file's own custom icon is only ever on screen until the
    /// real QuickLook thumbnail replaces it. Keyed by `UTType` so `.jpg` and `.jpeg` share an entry.
    static func icon(forExtension fileExtension: String) -> NSImage {
        let type = UTType(filenameExtension: fileExtension.lowercased()) ?? .item

        iconCacheLock.lock()
        let cached = iconCache[type]
        iconCacheLock.unlock()
        if let cached { return cached }

        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = THUMB_SIZE
        iconCacheLock.lock()
        iconCache[type] = icon
        iconCacheLock.unlock()
        return icon
    }

    /// Resolve the placeholder icon for every type Clop handles, off the main thread, so the first
    /// drop or clipboard event of a session never waits on LaunchServices.
    static func warmUpIconCache() {
        thumbnailQueue.async {
            for ext in IMAGE_EXTENSIONS + VIDEO_EXTENSIONS + AUDIO_EXTENSIONS + ["pdf"] {
                _ = icon(forExtension: ext)
            }
        }
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
            Self.setFallbackThumbnail(on: optimiser, for: url, path: path)
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
            Self.setFallbackThumbnail(on: optimiser, for: url, path: path)
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

    private static var iconCache: [UTType: NSImage] = [:]
    private static let iconCacheLock = NSLock()

}
