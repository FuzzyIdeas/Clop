@testable import Clop
import Foundation
import System
import Testing

@Suite("Video.getScaleFilters()")
struct VideoFilterTests {
    // MARK: - Helpers

    func video(width: CGFloat, height: CGFloat) -> Video {
        makeTestVideo(
            path: FilePath("/tmp/test.mp4"),
            resolution: CGSize(width: width, height: height)
        )
    }

    // MARK: - Tests

    @Test("No resize → empty array")
    func noResize() {
        let v = video(width: 1920, height: 1080)
        let filters = v.getScaleFilters(cropSize: nil, newSize: nil)
        #expect(filters.isEmpty)
    }

    @Test("newSize only → single scale filter")
    func newSizeOnly() {
        let v = video(width: 1920, height: 1080)
        let filters = v.getScaleFilters(cropSize: nil, newSize: NSSize(width: 960, height: 540))
        #expect(filters.count == 1)
        #expect(filters[0] == "scale=w=960:h=540")
    }

    @Test("CropSize with width=0 → auto width")
    func autoWidth() {
        let v = video(width: 1920, height: 1080)
        let crop = CropSize(width: 0, height: 540)
        let filters = v.getScaleFilters(cropSize: crop)
        #expect(filters.count == 1)
        #expect(filters[0] == "scale=w=-2:h=540")
    }

    @Test("CropSize with height=0 → auto height")
    func autoHeight() {
        let v = video(width: 1920, height: 1080)
        let crop = CropSize(width: 960, height: 0)
        let filters = v.getScaleFilters(cropSize: crop)
        #expect(filters.count == 1)
        #expect(filters[0] == "scale=w=960:h=-2")
    }

    @Test("longEdge landscape → scale by width")
    func longEdgeLandscape() {
        let v = video(width: 1920, height: 1080)
        let crop = CropSize(width: 1280, height: 0, longEdge: true)
        let filters = v.getScaleFilters(cropSize: crop)
        #expect(filters.count == 1)
        #expect(filters[0] == "scale=w=1280:h=-2")
    }

    @Test("longEdge portrait → scale by height")
    func longEdgePortrait() {
        let v = video(width: 1080, height: 1920)
        let crop = CropSize(width: 1280, height: 0, longEdge: true)
        let filters = v.getScaleFilters(cropSize: crop)
        #expect(filters.count == 1)
        #expect(filters[0] == "scale=w=-2:h=1280")
    }

    @Test("Both dimensions specified → crop + scale")
    func bothDimensions() {
        let v = video(width: 1920, height: 1080)
        let crop = CropSize(width: 800, height: 600)
        let filters = v.getScaleFilters(cropSize: crop)
        #expect(filters.count == 2)
        #expect(filters[0].hasPrefix("crop="))
        #expect(filters[1].hasPrefix("scale="))
        #expect(filters[1] == "scale=w=800:h=600")
    }

    @Test("Square crop from landscape → crop + scale")
    func squareCrop() {
        let v = video(width: 1920, height: 1080)
        let crop = CropSize(width: 500, height: 500)
        let filters = v.getScaleFilters(cropSize: crop)
        #expect(filters.count == 2)
        #expect(filters[0].hasPrefix("crop="))
        #expect(filters[1] == "scale=w=500:h=500")
    }

    @Test("Aspect ratio crop applies computed size")
    func aspectRatioCrop() {
        let v = video(width: 1920, height: 1080)
        let crop = CropSize(width: 16, height: 9, isAspectRatio: true)
        let filters = v.getScaleFilters(cropSize: crop)
        // 16:9 on a 1920x1080 video is already matching, so it should produce scale filters
        #expect(!filters.isEmpty)
    }
}
