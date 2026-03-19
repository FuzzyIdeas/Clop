@testable import Clop
import Cocoa
import Foundation
import System
import Testing

@Suite("runImagePipeline()", .tags(.integration))
@MainActor
struct ImagePipelineTests {
    init() throws {
        try #require(binariesAvailable())
        tempDir = try copyFixturesToTempDir()
        setTestDefaults()
        resetGlobalState()
        _ = try setTestWorkdir()
    }

    let tempDir: URL

    @Test("Optimise JPEG → smaller or equal file")
    func optimiseJPEG() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let originalSize = path.fileSize() ?? 0

        let img = try #require(Image(path: path, retinaDownscaled: false))
        let result = try await runImagePipeline(img, actions: [.optimise], hideFloatingResult: true, aggressiveOptimisation: true)

        #expect(result != nil)
        #expect(FileManager.default.fileExists(atPath: path.string))
        let newSize = path.fileSize() ?? Int.max
        #expect(newSize <= originalSize)
    }

    @Test("Optimise PNG → result is still PNG")
    func optimisePNG() async throws {
        let path = fixture("sample.png", in: tempDir)

        let img = try #require(Image(path: path, retinaDownscaled: false))
        let result = try await runImagePipeline(img, actions: [.optimise], hideFloatingResult: true, aggressiveOptimisation: true)

        #expect(result != nil)
        #expect(result?.type == .png)
    }

    @Test("Downscale 50% → dimensions roughly halved")
    func downscale50Percent() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let originalDims = try #require(imageDimensions(at: path))

        let img = try #require(Image(path: path, retinaDownscaled: false))
        _ = try await runImagePipeline(img, actions: [.downscale(factor: 0.5, cropSize: nil)], allowLarger: true, hideFloatingResult: true)

        let newDims = try #require(imageDimensions(at: path))
        #expect(abs(newDims.width - originalDims.width * 0.5) <= 2)
        #expect(abs(newDims.height - originalDims.height * 0.5) <= 2)
    }

    @Test("Downscale to CropSize → file on disk is resized")
    func downscaleToCropSize() async throws {
        let path = fixture("sample.jpg", in: tempDir)
        let originalDims = try #require(imageDimensions(at: path))

        let img = try #require(Image(path: path, retinaDownscaled: false))
        let crop = CropSize(width: 600, height: 400)
        _ = try await runImagePipeline(img, actions: [.downscale(factor: nil, cropSize: crop)], allowLarger: true, hideFloatingResult: true)

        // Check the file on disk was actually resized
        let newDims = try #require(imageDimensions(at: path))
        #expect(newDims.width < originalDims.width)
        #expect(newDims.height < originalDims.height)
    }

    @Test("Convert PNG→JPEG → result has .jpg path")
    func convertPNGToJPEG() async throws {
        let path = fixture("sample.png", in: tempDir)
        let img = try #require(Image(path: path, retinaDownscaled: false))

        let result = try await runImagePipeline(img, actions: [.convert(format: .jpeg), .optimise], allowLarger: true, hideFloatingResult: true)

        #expect(result != nil)
        if let resultPath = result?.path {
            #expect(resultPath.extension == "jpg" || resultPath.extension == "jpeg")
        }
    }

    @Test("TIFF skipped when optimiseTIFF=false → throws skippedType")
    func tiffSkippedWhenDisabled() async throws {
        let path = fixture("sample.tiff", in: tempDir)
        let img = try #require(Image(path: path, retinaDownscaled: false))

        await #expect(throws: ClopError.self) {
            try await runImagePipeline(img, actions: [.optimise], allowTiff: false, hideFloatingResult: true)
        }
    }
}
