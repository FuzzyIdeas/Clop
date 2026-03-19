@testable import Clop
import Cocoa
import Foundation
import System
import UniformTypeIdentifiers

// MARK: - Shared Test Workdir

/// Single shared workdir for all test suites. Using a deterministic path avoids
/// race conditions when multiple suites run concurrently and all write to
/// the shared `FilePath.workdir` static variable.
let sharedTestWorkdir: URL = {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClopTestWorkdir")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}()

// MARK: - Defaults Reset

/// Set all relevant UserDefaults keys to known, deterministic values for testing.
///
/// Uses UserDefaults.standard directly to avoid linking the Defaults module
/// into the test target (generic subscript causes linker issues with bundle_loader).
@MainActor func setTestDefaults() {
    let ud = UserDefaults.standard
    // Empty format conversion sets (no auto-conversion)
    ud.set(try? JSONEncoder().encode(Set<String>()), forKey: "formatsToConvertToJPEG")
    ud.set(try? JSONEncoder().encode(Set<String>()), forKey: "formatsToConvertToPNG")
    ud.set(try? JSONEncoder().encode(Set<String>()), forKey: "formatsToConvertToMP4")
    ud.set(true, forKey: "showImages")
    ud.set(true, forKey: "optimiseTIFF")
    ud.set(true, forKey: "stripMetadata")
    ud.set(true, forKey: "preserveDates")
    ud.set(false, forKey: "adaptiveImageSize")
    ud.set(false, forKey: "adaptiveVideoSize")
    ud.set(false, forKey: "useAggressiveOptimisationJPEG")
    ud.set(false, forKey: "useAggressiveOptimisationPNG")
    ud.set(false, forKey: "useAggressiveOptimisationGIF")
    ud.set(false, forKey: "useAggressiveOptimisationPDF")
    ud.set(false, forKey: "capVideoFPS")
    ud.set(false, forKey: "removeAudioFromVideos")
    ud.set("sameFolder", forKey: "convertedImageBehaviour")
    ud.set(false, forKey: "autoHideFloatingResults")
    ud.set(0, forKey: "lastAutoIncrementingNumber")
}

/// Point workdir at the shared test directory.
@MainActor func setTestWorkdir() throws -> URL {
    let tmp = sharedTestWorkdir
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    UserDefaults.standard.set(tmp.path, forKey: "workdir")
    FilePath.workdir = FilePath.dir(tmp.path, permissions: 0o755)
    return tmp
}

/// Set showImages default for tests that need to toggle it.
func setShowImages(_ value: Bool) {
    UserDefaults.standard.set(value, forKey: "showImages")
}

// MARK: - Global State Reset

/// Reset global mutable state that persists across tests.
@MainActor func resetGlobalState() {
    scalingFactor = 1.0
    imageOptimiseDebouncers.removeAll()
    imageResizeDebouncers.removeAll()
    videoOptimiseDebouncers.removeAll()
    pdfOptimiseDebouncers.removeAll()
    OM.optimisers.removeAll()
    OM.optimisedFilesByHash.removeAll()
}

// MARK: - Binary Availability

/// Returns `true` when the bundled optimisation binaries exist.
func binariesAvailable() -> Bool {
    FileManager.default.fileExists(atPath: FFMPEG.string)
        && FileManager.default.fileExists(atPath: PNGQUANT.string)
        && FileManager.default.fileExists(atPath: GS.string)
}

// MARK: - Factory Helpers

/// Create a `Video` with known metadata, suitable for unit tests that don't need a real file.
func makeTestVideo(
    path: FilePath,
    resolution: CGSize = CGSize(width: 1280, height: 720),
    fps: Float = 30,
    duration: TimeInterval = 2.0,
    hasAudio: Bool = true
) -> Video {
    let meta = VideoMetadata(resolution: resolution, fps: fps, duration: duration, hasAudio: hasAudio)
    return Video(path: path, metadata: meta, thumb: false)
}

/// Create a `PDF` instance (without thumbnail generation).
func makeTestPDF(path: FilePath) -> PDF {
    PDF(path, thumb: false)
}

/// Read pixel dimensions from an image file.
func imageDimensions(at path: FilePath) -> NSSize? {
    guard let img = NSImage(contentsOfFile: path.string) else { return nil }
    guard let rep = img.representations.first else { return img.size }
    return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
}
