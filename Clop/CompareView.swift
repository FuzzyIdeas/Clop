import Foundation
import SwiftUI

/// A view that allows the user to preview a comparison of the optimised and original image/video/PDF.
struct CompareView: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        VStack {
            HStack {
                if let url = optimiser.url, let image = NSImage(contentsOf: optimiser.url),
                   let originalURL = optimiser.originalURL, let originalImage = NSImage(contentsOf: originalURL)
                {
                    SwiftUI.Image(nsImage: optimiser.originalImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 300, height: 400)
                        .clipped()
                    SwiftUI.Image(nsImage: optimiser.optimisedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 300, height: 400)
                        .clipped()
                }
            }
        }
    }

}

struct ComparePreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let noThumb = Optimiser(id: "pages.pdf", type: .pdf)
        noThumb.url = "\(HOME)/Documents/pages.pdf".fileURL
        noThumb.finish(oldBytes: 12_250_190, newBytes: 5_211_932)

        let videoOpt = Optimiser(id: "Movies/meeting-recording-video.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "\(HOME)/Movies/meeting-recording-video.mov".fileURL
        videoOpt.thumbnail = NSImage(resource: .sonomaVideo)
        videoOpt.changePlaybackSpeedFactor = 2.0
        videoOpt.finish(oldBytes: 7_750_190, newBytes: 2_211_932, oldSize: thumbSize)

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(resource: .sonomaShot)
        clipEnd.image = Image(nsImage: clipEnd.thumbnail!, data: Data(), type: .png, retinaDownscaled: false)
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        o.optimisers = [
            clipEnd,
            videoOpt,
            noThumb,
        ]
        for opt in o.optimisers {
            opt.isPreview = true
        }
        return o
    }()

    var body: some View {
        CompareView(optimiser: om.optimisers[0])
    }
}

#Preview {
    ComparePreview()
        .frame(width: 600, height: 400)
}
