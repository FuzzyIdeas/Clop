import AVFoundation
@testable import Clop
import Foundation
import System
import Testing
import UniformTypeIdentifiers

@Suite("Multi-action pipeline combinations", .tags(.integration))
@MainActor
struct CombinationTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    @Test("Image convert + optimise: PNG→JPEG with backup of original PNG")
    func imageConvertAndOptimise() async throws {
        let path = fixture("sample.png", in: tempDir)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        let result = try await runImagePipeline(
            img,
            actions: [.convert(format: .jpeg), .optimise],
            allowLarger: true,
            hideFloatingResult: true
        )

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.extension == "jpg" || resultPath.extension == "jpeg")
        }
    }

    @Test("Video downscale + removeAudio → both effects applied")
    func videoDownscaleAndRemoveAudio() async throws {
        let path = fixture("sample.mp4", in: tempDir)
        let meta = try await getVideoMetadata(path: path)
        let video = Video(path: path, metadata: meta, thumb: false)

        let result = try await runVideoPipeline(
            video,
            actions: [.downscale(factor: 0.5, cropSize: nil), .removeAudio],
            allowLarger: true,
            hideFloatingResult: true,
            source: .cli
        )

        #expect(result != nil)
        if let resultPath = result?.path {
            let resultMeta = try await getVideoMetadata(path: resultPath)
            #expect(resultMeta?.hasAudio != true)
        }
    }

    @Test("buildPipeline output fed to runImagePipeline → works end-to-end")
    func buildPipelineFedToExecutor() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let img = try #require(Image(path: path, retinaDownscaled: false))

        let actions = buildPipeline(scalingFactor: 0.5)
        #expect(actions.first?.isDownscale == true)

        let result = try await runImagePipeline(img, actions: actions, hideFloatingResult: true)
        #expect(result != nil)
    }

    @Test("computeImageDownscaleFactor auto-decrements with no explicit factor")
    func autoDecrementDownscale() {
        // First call with no existing optimiser → uses global scalingFactor
        scalingFactor = 1.0
        let factor1 = computeImageDownscaleFactor(id: "test-path", factor: nil, cropSize: nil, imageSize: NSSize(width: 1200, height: 1200))
        #expect(factor1 == 0.75) // 1.0 - 0.25

        // With explicit factor, returns it directly
        let factor2 = computeImageDownscaleFactor(id: "test-path2", factor: 0.5, cropSize: nil, imageSize: NSSize(width: 1200, height: 1200))
        #expect(factor2 == 0.5)
    }

    @Test("computeSpeedFactor auto-increments when no explicit factor")
    func autoIncrementSpeed() {
        // With no existing optimiser → returns default 1.25
        let factor1 = computeSpeedFactor(id: "test-path", factor: nil)
        #expect(factor1 == 1.25)

        // With explicit factor, returns it directly
        let factor2 = computeSpeedFactor(id: "test-path2", factor: 3.0)
        #expect(factor2 == 3.0)
    }
}
