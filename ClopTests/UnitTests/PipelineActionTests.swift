@testable import Clop
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("PipelineAction")
struct PipelineActionTests {
    // MARK: - Description strings

    @Test("optimise description")
    func optimiseDescription() {
        let action = PipelineAction.optimise
        #expect(action.description == "optimise")
    }

    @Test("convert description")
    func convertDescription() {
        let action = PipelineAction.convert(format: .jpeg)
        #expect(action.description == "convert(jpeg)")
    }

    @Test("downscale with factor description")
    func downscaleFactorDescription() {
        let action = PipelineAction.downscale(factor: 0.5, cropSize: nil)
        #expect(action.description == "downscale(50%)")
    }

    @Test("downscale with cropSize description")
    func downscaleCropDescription() {
        let crop = CropSize(width: 800, height: 600)
        let action = PipelineAction.downscale(factor: nil, cropSize: crop)
        #expect(action.description == "downscale(crop)")
    }

    @Test("downscale with no factor or crop description")
    func downscaleNeitherDescription() {
        let action = PipelineAction.downscale(factor: nil, cropSize: nil)
        #expect(action.description == "downscale")
    }

    @Test("changePlaybackSpeed description")
    func changeSpeedDescription() {
        let action = PipelineAction.changePlaybackSpeed(factor: 2.0)
        #expect(action.description == "changePlaybackSpeed(2.0x)")
    }

    @Test("removeAudio description")
    func removeAudioDescription() {
        let action = PipelineAction.removeAudio
        #expect(action.description == "removeAudio")
    }

    @Test("runShortcut description")
    func runShortcutDescription() {
        let action = PipelineAction.runShortcut(Shortcut(name: "MyShortcut", identifier: "abc"))
        #expect(action.description == "runShortcut(MyShortcut)")
    }

    // MARK: - Boolean helpers

    @Test("isDownscale returns true only for .downscale")
    func isDownscaleHelper() {
        #expect(PipelineAction.downscale(factor: 0.5, cropSize: nil).isDownscale)
        #expect(!PipelineAction.optimise.isDownscale)
        #expect(!PipelineAction.removeAudio.isDownscale)
    }

    @Test("isOptimise returns true only for .optimise")
    func isOptimiseHelper() {
        #expect(PipelineAction.optimise.isOptimise)
        #expect(!PipelineAction.removeAudio.isOptimise)
    }

    @Test("isConvert returns true only for .convert")
    func isConvertHelper() {
        #expect(PipelineAction.convert(format: .png).isConvert)
        #expect(!PipelineAction.optimise.isConvert)
    }

    @Test("isChangePlaybackSpeed returns true only for .changePlaybackSpeed")
    func isChangePlaybackSpeedHelper() {
        #expect(PipelineAction.changePlaybackSpeed(factor: 1.5).isChangePlaybackSpeed)
        #expect(!PipelineAction.optimise.isChangePlaybackSpeed)
    }
}
