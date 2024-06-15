import AVKit
import Foundation
import Lowtech
import PDFKit
import SwiftUI

struct LoopingVideoPlayer: View {
    init(videoURL: URL) {
        let asset = AVAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)

        player = AVQueuePlayer(playerItem: item)
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }

    private var player: AVQueuePlayer
    private var playerLooper: AVPlayerLooper
}

struct PDFKitView: NSViewRepresentable {
    init(url: URL, scale: CGFloat = 1.0) {
        self.url = url
        self.scale = scale
    }

    open class Coordinator: NSObject {
        var scaleFactor: CGFloat = 1.0
    }

    let url: URL
    var scale: CGFloat = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.setFrameSize(NSSize(width: 300, height: 300))
        pdfView.displayMode = .singlePageContinuous

        pdfView.document = PDFDocument(url: url)
        if let page = pdfView.document?.page(at: 0) {
            let pageBounds = page.bounds(for: pdfView.displayBox)
            pdfView.scaleFactor = 270 / pageBounds.width
            context.coordinator.scaleFactor = pdfView.scaleFactor
        }

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        pdfView.scaleFactor = scale * context.coordinator.scaleFactor
    }

    private var scaleFactor = 1.0
}

/// A view that allows the user to preview a comparison of the optimised and original image/video/PDF.
struct CompareView: View {
    @ObservedObject var optimiser: Optimiser
    @ObservedObject var km = KM

    var body: some View {
        VStack {
            GeometryReader { proxy in
                HStack {
                    if let url = optimiser.url, let originalURL = optimiser.originalURL {
                        preview(url: originalURL, title: "Original", bytes: optimiser.oldBytes, size: optimiser.oldSize) {
                            switch optimiser.type {
                            case .video:
                                LoopingVideoPlayer(videoURL: originalURL)
                                    .scaledToFit()
                            case .image:
                                SwiftUI.Image(nsImage: NSImage(contentsOf: originalURL) ?? .lowtech)
                                    .resizable()
                                    .scaledToFit()
                            case .pdf:
                                PDFKitView(url: originalURL)
                                    .scaledToFit()
                            default:
                                EmptyView()
                            }
                        }
                        preview(url: url, title: "Optimised", bytes: optimiser.newBytes, size: optimiser.newSize) {
                            switch optimiser.type {
                            case .video:
                                LoopingVideoPlayer(videoURL: url)
                                    .scaledToFit()
                            case .image:
                                SwiftUI.Image(nsImage: NSImage(contentsOf: url) ?? .lowtech)
                                    .resizable()
                                    .scaledToFit()
                            case .pdf:
                                PDFKitView(url: url)
                                    .scaledToFit()
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
                .if(zoomed) {
                    $0.onContinuousHover { hoverPhase in
                        guard case let .active(location) = hoverPhase else { return }
                        let frame = proxy.frame(in: .local)
                        let x = (location.x - frame.minX) / frame.width
                        let y = (location.y - frame.minY) / frame.height
                        zoomOffset = UnitPoint(x: x, y: y)
                    }
                }
            }
            Text("Hold the **⌘ Command** key to zoom in")
                .round(10).foregroundColor(.tertiaryLabel)
                .padding(.top, 4)
        }
        .onChange(of: km.lcmd) { lcmd in
            guard (lcmd || km.rcmd) != zoomed else { return }

            withAnimation(.fastSpring) {
                zoomed = lcmd || km.rcmd
                zoom = zoomed ? 3.0 : 1.0
            }
        }
        .onChange(of: km.rcmd) { rcmd in
            guard (rcmd || km.lcmd) != zoomed else { return }

            withAnimation(.fastSpring) {
                zoomed = rcmd || km.lcmd
                zoom = zoomed ? 3.0 : 1.0
            }
        }
    }

    func preview(url: URL, title: String, bytes: Int? = nil, size: CGSize? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack {
            VStack {
                Text(title).bold(12)
                Text(url.shellString)
                    .mono(10).lineLimit(1)
                    .foregroundColor(.secondary)
                    .truncationMode(.middle)
                content()
                    .scaleEffect(zoom, anchor: zoomOffset)
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipped()
            }.frame(width: 300)

            VStack(alignment: .leading) {
                if let bytes {
                    Text("Size: \(bytes.humanSize)").mono(10)
                        .hfill(.leading)
                }
                if let size {
                    Text("Dimensions: \(size.s)").mono(10)
                        .hfill(.leading)
                }
            }
            .frame(width: 300)
            .foregroundColor(.secondary)
            .padding(.top, 4)
        }
    }

    @State private var zoomed = false
    @State private var zoom = 1.0
    @State private var zoomOffset = UnitPoint.center

}

@MainActor
struct ComparePreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let noThumb = Optimiser(id: "pages.pdf", type: .pdf)
        noThumb.url = "\(HOME)/Documents/pages.pdf".fileURL
        noThumb.originalURL = "\(HOME)/Documents/pages-before.pdf".fileURL
        noThumb.finish(oldBytes: 12_250_190, newBytes: 5_211_932)

        let videoOpt = Optimiser(id: "Movies/meeting-recording-video.mov", type: .video(.quickTimeMovie), running: true, progress: nil)
        videoOpt.url = "\(HOME)/Movies/meeting-recording-video.mov".fileURL
        videoOpt.thumbnail = NSImage(resource: .sonomaVideo)
        videoOpt.changePlaybackSpeedFactor = 2.0
        videoOpt.finish(oldBytes: 7_750_190, newBytes: 2_211_932, oldSize: thumbSize)

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot-opt.png".fileURL
        clipEnd.originalURL = "\(HOME)/Desktop/sonoma-shot.png".fileURL
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
        CompareView(optimiser: ComparePreview.om.optimisers.first(where: { $0.id == "pages.pdf" })!)
        // Optimiser.IDs.clipboardImage })!)
    }
}

#Preview {
    ComparePreview()
        .frame(width: 600, height: 400)
        .padding()
}
