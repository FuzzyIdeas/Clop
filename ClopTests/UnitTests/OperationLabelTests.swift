@testable import Clop
import Foundation
import Testing

@Suite("operationLabel()")
@MainActor
struct OperationLabelTests {
    init() {
        setTestDefaults()
        resetGlobalState()
    }

    @Test("Optimise with showImages=true hides filename")
    func optimiseShowImages() {
        setShowImages(true)
        let label = operationLabel(for: [.optimise], filename: "photo.jpg", aggressive: false)
        #expect(label == "Optimising")
    }

    @Test("Optimise with showImages=false shows filename")
    func optimiseShowFilename() {
        setShowImages(false)
        let label = operationLabel(for: [.optimise], filename: "photo.jpg", aggressive: false)
        #expect(label == "Optimising photo.jpg")
    }

    @Test("Optimise aggressive adds suffix")
    func optimiseAggressive() {
        setShowImages(true)
        let label = operationLabel(for: [.optimise], filename: "photo.jpg", aggressive: true)
        #expect(label == "Optimising (aggressive)")
    }

    @Test("Downscale with factor shows percentage")
    func downscaleWithFactor() {
        let actions: [PipelineAction] = [.downscale(factor: 0.5, cropSize: nil)]
        let label = operationLabel(for: actions, filename: "photo.jpg", aggressive: false)
        #expect(label == "Scaling to 50%")
    }

    @Test("Downscale with CropSize shows dimensions")
    func downscaleWithCropSize() {
        let crop = CropSize(width: 600, height: 400)
        let actions: [PipelineAction] = [.downscale(factor: nil, cropSize: crop)]
        let label = operationLabel(for: actions, filename: "photo.jpg", imageSize: NSSize(width: 1200, height: 800), aggressive: false)
        #expect(label == "Scaling to 600×400")
    }

    @Test("Downscale with zero-width CropSize computes width from aspect ratio")
    func downscaleAutoWidth() {
        let crop = CropSize(width: 0, height: 400)
        let actions: [PipelineAction] = [.downscale(factor: nil, cropSize: crop)]
        // computedSize scales 1200×800 by factor 400/800=0.5 → 600×400
        let label = operationLabel(for: actions, filename: "photo.jpg", imageSize: NSSize(width: 1200, height: 800), aggressive: false)
        #expect(label == "Scaling to 600×400")
    }

    @Test("Speed up label")
    func speedUp() {
        let actions: [PipelineAction] = [.changePlaybackSpeed(factor: 2.0)]
        let label = operationLabel(for: actions, filename: "video.mp4", aggressive: false)
        #expect(label == "Speeding up by 2x")
    }

    @Test("Speed up fractional label")
    func speedUpFractional() {
        let actions: [PipelineAction] = [.changePlaybackSpeed(factor: 1.5)]
        let label = operationLabel(for: actions, filename: "video.mp4", aggressive: false)
        #expect(label == "Speeding up by 1.50x")
    }

    @Test("Slow down label")
    func slowDown() {
        let actions: [PipelineAction] = [.changePlaybackSpeed(factor: 0.5)]
        let label = operationLabel(for: actions, filename: "video.mp4", aggressive: false)
        #expect(label == "Slowing down to 0.5x")
    }

    @Test("Revert speed label")
    func revertSpeed() {
        let actions: [PipelineAction] = [.changePlaybackSpeed(factor: 1.0)]
        let label = operationLabel(for: actions, filename: "video.mp4", aggressive: false)
        #expect(label == "Reverting to original speed")
    }
}
