@testable import Clop
import Foundation
import System

/// Locates the `Fixtures/` directory inside the test bundle.
let fixturesURL: URL = Bundle(for: _ClopTestAnchor.self).url(forResource: "Fixtures", withExtension: nil)
    ?? Bundle(for: _ClopTestAnchor.self).bundleURL.appendingPathComponent("Contents/Resources/Fixtures")

/// Anchor class used only to locate the test bundle.
final class _ClopTestAnchor: NSObject {}

/// Copy every fixture into a unique temp directory and return its URL.
func copyFixturesToTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClopTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let fm = FileManager.default
    for item in try fm.contentsOfDirectory(atPath: fixturesURL.path) {
        // Skip the generator script
        guard !item.hasSuffix(".sh") else { continue }
        let src = fixturesURL.appendingPathComponent(item)
        let dst = tmp.appendingPathComponent(item)
        try fm.copyItem(at: src, to: dst)
    }
    return tmp
}

/// Remove a temp directory created by `copyFixturesToTempDir`.
func cleanupTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// Return a `FilePath` pointing at `name` inside `tempDir`.
func fixture(_ name: String, in tempDir: URL) -> FilePath {
    FilePath(tempDir.appendingPathComponent(name).path)
}

/// Check whether a fixture file exists in the source fixtures directory.
func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixturesURL.appendingPathComponent(name).path)
}
