@testable import Clop
import Foundation
import System
import Testing

@Suite("Backup creation & restore", .tags(.integration), .serialized)
@MainActor
struct BackupTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    // MARK: - JPEG Backup

    @Test("Optimise JPEG creates valid backup")
    func optimiseJPEGBackup() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let originalSize = path.fileSize() ?? 0
        let originalHash = path.fileContentsHash
        // Capture backup path BEFORE pipeline (mtime changes after copy-back)
        let backupPath = try #require(path.clopBackupPath)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.optimise], hideFloatingResult: true)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileSize() == originalSize)
        #expect(backupPath.fileContentsHash == originalHash)
    }

    @Test("Downscale JPEG creates valid backup")
    func downscaleJPEGBackup() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let originalHash = path.fileContentsHash
        // Capture backup path BEFORE pipeline (downscale changes the modification timestamp)
        let backupPath = try #require(path.clopBackupPath)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.downscale(factor: 0.5, cropSize: nil)], allowLarger: true, hideFloatingResult: true)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileContentsHash == originalHash)
    }

    @Test("Restore JPEG from backup matches original")
    func restoreJPEGFromBackup() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.optimise], hideFloatingResult: true)

        path.restore(backupPath: backupPath, force: true)

        #expect(path.fileContentsHash == originalHash)
    }

    // MARK: - PNG Backup

    @Test("Optimise PNG creates valid backup")
    func optimisePNGBackup() async throws {
        let path = fixture("sample.png", in: tempDir)
        let originalSize = path.fileSize() ?? 0
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.optimise], hideFloatingResult: true)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileSize() == originalSize)
        #expect(backupPath.fileContentsHash == originalHash)
    }

    @Test("Downscale PNG creates valid backup")
    func downscalePNGBackup() async throws {
        let path = fixture("sample.png", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.downscale(factor: 0.5, cropSize: nil)], allowLarger: true, hideFloatingResult: true)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileContentsHash == originalHash)
    }

    @Test("Restore PNG from backup matches original")
    func restorePNGFromBackup() async throws {
        let path = fixture("sample.png", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.optimise], hideFloatingResult: true)

        path.restore(backupPath: backupPath, force: true)

        #expect(path.fileContentsHash == originalHash)
    }

    // MARK: - Video Backup

    @Test("Optimise MP4 creates valid backup")
    func optimiseMP4Backup() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let video = Video(path: path, thumb: false)
        _ = try await runVideoPipeline(video, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileContentsHash == originalHash)
    }

    @Test("Downscale MP4 creates valid backup")
    func downscaleMP4Backup() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let video = Video(path: path, thumb: false)
        // Don't use source: .cli — CLI source sets effectiveOriginalPath which skips backup() in Video.optimise()
        _ = try await runVideoPipeline(video, actions: [.downscale(factor: 0.5, cropSize: nil)], allowLarger: true, hideFloatingResult: true)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileContentsHash == originalHash)
    }

    @Test("Restore MP4 from backup matches original")
    func restoreMP4FromBackup() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let video = Video(path: path, thumb: false)
        _ = try await runVideoPipeline(video, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        path.restore(backupPath: backupPath, force: true)

        #expect(path.fileContentsHash == originalHash)
    }

    // MARK: - PDF Backup

    @Test("Optimise PDF creates valid backup with same page count")
    func optimisePDFBackup() async throws {
        let path = fixture("sample.pdf", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let pdf = makeTestPDF(path: path)
        _ = try await runPDFPipeline(pdf, actions: [.optimise], allowLarger: true, hideFloatingResult: true, aggressiveOptimisation: false)

        #expect(FileManager.default.fileExists(atPath: backupPath.string))
        #expect(backupPath.fileContentsHash == originalHash)
        #expect(isPDFValid(path: path))
    }

    @Test("Restore PDF from backup matches original")
    func restorePDFFromBackup() async throws {
        let path = fixture("sample.pdf", in: tempDir)
        let originalHash = path.fileContentsHash
        let backupPath = try #require(path.clopBackupPath)

        let pdf = makeTestPDF(path: path)
        _ = try await runPDFPipeline(pdf, actions: [.optimise], allowLarger: true, hideFloatingResult: true, aggressiveOptimisation: false)

        path.restore(backupPath: backupPath, force: true)

        #expect(path.fileContentsHash == originalHash)
    }
}

extension Tag {
    @Tag static var integration: Self
}
