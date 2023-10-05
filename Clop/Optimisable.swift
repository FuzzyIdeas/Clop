//
//  Optimisable.swift
//  Clop
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import Cocoa
import Foundation
import System
import UniformTypeIdentifiers

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

    func copyWithPath(_ path: FilePath) -> Self {
        Self(path, thumb: true, id: id)
    }

    @MainActor func fetchThumbnail() {
        var url = path.url
        if let thumbURL = THUMBNAIL_URLS[url] {
            log.debug("Using cached thumbnail from \(thumbURL.path) for \(path.string)")
            url = thumbURL
        }
        generateThumbnail(for: url, size: THUMB_SIZE) { [weak self] thumb in
            guard let self, let optimiser else {
                log.debug("Thumbnail generation cancelled for \(url.path)")
                return
            }
            log.debug("Thumbnail generated for \(path.string)")
            optimiser.thumbnail = NSImage(cgImage: thumb.cgImage, size: .zero)
        }
    }

    func runThroughShortcut(shortcut: Shortcut? = nil, optimiser: Optimiser, allowLarger: Bool, aggressiveOptimisation: Bool, source: String?) throws -> Self? {
        let shortcutOutFile = FilePath.videos.appending("\(Date.now.timeIntervalSinceReferenceDate.i)-shortcut-output-for-\(path.stem!)")

        let proc: Process? = if let shortcut {
            optimiser.runShortcut(shortcut, outFile: shortcutOutFile, url: path.url)
        } else {
            optimiser.runAutomation(outFile: shortcutOutFile, source: source, url: path.url, type: .video(UTType.from(filePath: path) ?? .mpeg4Movie))
        }
        guard let proc else { return nil }

        proc.waitUntilExit()
        guard shortcutOutFile.exists else {
            return nil
        }
        var outfile: Self? = if let size = shortcutOutFile.fileSize(), size < 4096,
                                let path = (try? String(contentsOfFile: shortcutOutFile.string))?.existingFilePath, self.path != path
        {
            Self(path, id: id)
        } else {
            Self(shortcutOutFile, id: id)
        }

        guard let outfile, outfile.hash != hash else {
            return nil
        }

        if outfile.path != path {
            try outfile.path.copy(to: path, force: true)
        }
        return outfile.copyWithPath(path)
    }

}
