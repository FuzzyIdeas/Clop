@testable import Clop
import Foundation
import Testing

@Suite("buildPipeline()")
@MainActor
struct BuildPipelineTests {
    init() {
        resetGlobalState()
    }

    @Test("No arguments → [.optimise]")
    func noArgs() {
        let actions = buildPipeline()
        #expect(actions.count == 1)
        #expect(actions[0].isOptimise)
    }

    @Test("scalingFactor < 1 → [.downscale(factor, nil)]")
    func scalingFactorBelow1() {
        let actions = buildPipeline(scalingFactor: 0.5)
        #expect(actions.count == 1)
        #expect(actions[0].isDownscale)
        if case let .downscale(factor, cropSize) = actions[0] {
            #expect(factor == 0.5)
            #expect(cropSize == nil)
        }
    }

    @Test("scalingFactor == 1.0 (not < 1) → [.optimise]")
    func scalingFactor1() {
        let actions = buildPipeline(scalingFactor: 1.0)
        #expect(actions.count == 1)
        #expect(actions[0].isOptimise)
    }

    @Test("scalingFactor > 1 → [.optimise]")
    func scalingFactorAbove1() {
        let actions = buildPipeline(scalingFactor: 1.5)
        #expect(actions.count == 1)
        #expect(actions[0].isOptimise)
    }

    @Test("cropSize only → [.downscale(nil, crop)]")
    func cropSizeOnly() {
        let crop = CropSize(width: 800, height: 600)
        let actions = buildPipeline(cropSize: crop)
        #expect(actions.count == 1)
        #expect(actions[0].isDownscale)
        if case let .downscale(factor, cropSize) = actions[0] {
            #expect(factor == nil)
            #expect(cropSize?.width == 800)
            #expect(cropSize?.height == 600)
        }
    }

    @Test("cropSize + scalingFactor → downscale with both")
    func cropSizeAndScalingFactor() {
        let crop = CropSize(width: 800, height: 600)
        let actions = buildPipeline(scalingFactor: 0.5, cropSize: crop)
        #expect(actions.count == 1)
        #expect(actions[0].isDownscale)
        if case let .downscale(factor, cropSize) = actions[0] {
            #expect(factor == 0.5)
            #expect(cropSize != nil)
        }
    }

    @Test("changePlaybackSpeedFactor: 2.0 → [.changePlaybackSpeed(2.0)]")
    func speedChange() {
        let actions = buildPipeline(changePlaybackSpeedFactor: 2.0)
        #expect(actions.count == 1)
        #expect(actions[0].isChangePlaybackSpeed)
        if case let .changePlaybackSpeed(factor) = actions[0] {
            #expect(factor == 2.0)
        }
    }

    @Test("changePlaybackSpeedFactor: 1.0 → [.optimise] (filtered)")
    func speedFactor1() {
        let actions = buildPipeline(changePlaybackSpeedFactor: 1.0)
        #expect(actions.count == 1)
        #expect(actions[0].isOptimise)
    }

    @Test("changePlaybackSpeedFactor: 0 → [.optimise] (filtered)")
    func speedFactor0() {
        let actions = buildPipeline(changePlaybackSpeedFactor: 0)
        #expect(actions.count == 1)
        #expect(actions[0].isOptimise)
    }

    @Test("cropSize takes priority over speed change")
    func cropSizeWinsOverSpeed() {
        let crop = CropSize(width: 800, height: 600)
        let actions = buildPipeline(cropSize: crop, changePlaybackSpeedFactor: 2.0)
        #expect(actions.count == 1)
        #expect(actions[0].isDownscale)
    }

    @Test("removeAudio: true → appended to optimise")
    func removeAudioTrue() {
        let actions = buildPipeline(removeAudio: true)
        #expect(actions.count == 2)
        #expect(actions[0].isOptimise)
        #expect(actions[1].isRemoveAudio)
    }

    @Test("removeAudio: false → not appended")
    func removeAudioFalse() {
        let actions = buildPipeline(removeAudio: false)
        #expect(actions.count == 1)
        #expect(actions[0].isOptimise)
    }

    @Test("All appendable options combined")
    func allCombined() {
        let crop = CropSize(width: 800, height: 600)
        let actions = buildPipeline(cropSize: crop, removeAudio: true)
        #expect(actions.count == 2)
        #expect(actions[0].isDownscale)
        #expect(actions[1].isRemoveAudio)
    }
}
