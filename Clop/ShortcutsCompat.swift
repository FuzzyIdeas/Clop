import Cocoa
import Combine
import Defaults
import Foundation
import Lowtech
import os
import SwiftUI

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "ShortcutsCompat")

func runShortcutProcess(_ shortcut: Shortcut, _ file: String, outFile: String) -> Process? {
    log.debug("Running shortcut \(shortcut.identifier) on \(file) -> \(outFile)")
    return ShortcutsFetcher.run(identifier: shortcut.identifier, inputPath: file, outputPath: outFile)
}

func startShortcutWatcher() {
    guard hasShortcutsDB() else { return }
    SHM.startWatching()
}
