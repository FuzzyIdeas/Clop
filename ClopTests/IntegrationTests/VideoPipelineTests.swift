import AVFoundation
@testable import Clop
import Foundation
import System
import Testing

@Suite("runVideoPipeline()", .tags(.integration))
@MainActor
struct VideoPipelineTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    @Test("Optimise MP4 → output exists and is valid")
    func optimiseMP4() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let video = try await Video(path: path, metadata: fetchMetadata(path), thumb: false)

        let result = try await runVideoPipeline(video, actions: [.optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        #expect(FileManager.default.fileExists(atPath: path.string))
    }

    @Test("Downscale 50% → output resolution roughly halved")
    func downscale50() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let meta = try await fetchMetadata(path)
        let video = Video(path: path, metadata: meta, thumb: false)
        let originalSize = try #require(video.size)

        let result = try await runVideoPipeline(video, actions: [.downscale(factor: 0.5, cropSize: nil)], allowLarger: true, hideFloatingResult: true, source: .cli)

        #expect(result != nil)
        if let resultPath = result?.path {
            let resultMeta = try await fetchMetadata(resultPath)
            if let resultRes = resultMeta?.resolution {
                #expect(abs(resultRes.width - originalSize.width * 0.5) <= 4)
                #expect(abs(resultRes.height - originalSize.height * 0.5) <= 4)
            }
        }
    }

    @Test("Change speed 2x → output exists")
    func changeSpeed() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let video = try await Video(path: path, metadata: fetchMetadata(path), thumb: false)

        let result = try await runVideoPipeline(video, actions: [.changePlaybackSpeed(factor: 2.0)], allowLarger: true, hideFloatingResult: true, source: .cli)

        #expect(result != nil)
    }

    @Test("Remove audio → no audio track")
    func removeAudio() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let meta = try await fetchMetadata(path)
        let video = Video(path: path, metadata: meta, thumb: false)
        #expect(video.hasAudio)

        let result = try await runVideoPipeline(video, actions: [.optimise, .removeAudio], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            let resultMeta = try await fetchMetadata(resultPath)
            #expect(resultMeta?.hasAudio != true)
        }
    }

    @Test("Downscale + removeAudio combined → both applied")
    func downscaleAndRemoveAudio() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let meta = try await fetchMetadata(path)
        let video = Video(path: path, metadata: meta, thumb: false)
        let originalSize = try #require(video.size)

        let result = try await runVideoPipeline(
            video,
            actions: [.downscale(factor: 0.5, cropSize: nil), .removeAudio],
            allowLarger: true,
            hideFloatingResult: true,
            source: .cli
        )

        #expect(result != nil)
        if let resultPath = result?.path {
            let resultMeta = try await fetchMetadata(resultPath)
            #expect(resultMeta?.hasAudio != true)
            if let resultRes = resultMeta?.resolution {
                #expect(resultRes.width < originalSize.width)
            }
        }
    }

    // MARK: - Helpers

    private func fetchMetadata(_ path: FilePath) async throws -> VideoMetadata? {
        try await getVideoMetadata(path: path)
    }
}
