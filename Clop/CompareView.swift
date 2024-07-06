import AVKit
import Foundation
import Lowtech
import PDFKit
import SwiftUI

@MainActor
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

class PDFDelegate: NSObject, PDFViewDelegate {
    init(otherPDFView: PDFView) {
        self.otherPDFView = otherPDFView
    }

    let otherPDFView: PDFView

    func pdfViewPerformGo(toPage sender: PDFView) {
        guard let page = sender.currentPage, page != otherPDFView.currentPage else { return }
        otherPDFView.go(to: page)
    }
}

struct PDFKitView: NSViewRepresentable {
    static var pdfViewCache = [URL: PDFView]()

    let url: URL

    static func clearCache(for urls: [URL]) {
        for url in urls {
            pdfViewCache.removeValue(forKey: url)
        }
    }

    func makeNSView(context: Context) -> PDFView {
        if let pdfView = Self.pdfViewCache[url] {
            return pdfView
        }

        let pdfView = PDFView()
        pdfView.setFrameSize(NSSize(width: COMPARISON_VIEW_SIZE, height: COMPARISON_VIEW_SIZE))
        pdfView.displayMode = .singlePage

        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true

        Self.pdfViewCache[url] = pdfView

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {}

}

let COMPARISON_VIEW_SIZE: CGFloat = 500

/// A view that allows the user to preview a comparison of the optimised and original image/video/PDF.
struct CompareView: View {
    @ObservedObject var optimiser: Optimiser
    @ObservedObject var km = KM

    @State var pdfPage = 1.0

    var previewStack: some View {
        GeometryReader { proxy in
            HStack {
                if let url = optimiser.url, let originalURL = optimiser.comparisonOriginalURL {
                    preview(url: originalURL, title: "Original", bytes: optimiser.oldBytes, size: optimiser.oldSize) {
                        switch optimiser.type {
                        case .video:
                            LoopingVideoPlayer(videoURL: originalURL)
                        case .image:
                            SwiftUI.Image(nsImage: NSImage(contentsOf: originalURL) ?? .lowtech)
                                .resizable()
                                .scaledToFit()
                        case .pdf:
                            PDFKitView(url: originalURL)
                                .allowsHitTesting(false)
                        default:
                            EmptyView()
                        }
                    }
                    preview(url: url, title: "Optimised", bytes: optimiser.newBytes ?! optimiser.oldBytes, size: optimiser.newSize ?? optimiser.oldSize) {
                        switch optimiser.type {
                        case .video:
                            LoopingVideoPlayer(videoURL: url)
                        case .image:
                            SwiftUI.Image(nsImage: NSImage(contentsOf: url) ?? .lowtech)
                                .resizable()
                                .scaledToFit()
                        case .pdf:
                            PDFKitView(url: url)
                                .allowsHitTesting(false)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
            .hfill()
            .padding(.vertical)
            .onContinuousHover { hoverPhase in
                guard zoomed else { return }

                guard case let .active(location) = hoverPhase else { return }

                let frame = proxy.frame(in: .local)
                let x = (location.x - frame.minX) / frame.width
                let y = (location.y - frame.minY) / frame.height

                zoomOffset = UnitPoint(x: x, y: y)
            }
        }
    }

    var body: some View {
        VStack {
            previewStack

            if optimiser.type == .pdf, let url = optimiser.url ?? optimiser.startingURL ?? optimiser.originalURL, let pdf = PDFKitView.pdfViewCache[url]?.document {
                VStack {
                    Text("Page \(pdfPage.i)/\(pdf.pageCount)")
                    Slider(value: $pdfPage, in: 1 ... pdf.pageCount.d, step: 1.0)
                        .frame(width: 400)
                }
                .font(.round(11))
                .padding(.top, 10)
                .onChange(of: pdfPage) { page in
                    if let url = optimiser.startingURL ?? optimiser.originalURL, let pdfView = PDFKitView.pdfViewCache[url], let page = pdfView.document?.page(at: page.i) {
                        pdfView.go(to: page)
                    }
                    if let url = optimiser.url, let otherPDFView = PDFKitView.pdfViewCache[url], let page = otherPDFView.document?.page(at: page.i) {
                        otherPDFView.go(to: page)
                    }
                }
            }

            Text("Hold the **⌘ Command** key to zoom in")
                .round(10).foregroundColor(.tertiaryLabel)
                .padding(.top, 4)
            Text("Add **⌥ Option** to zoom in further")
                .round(10).foregroundColor(.tertiaryLabel)
        }
        .onChange(of: km.rcmd) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: km.lcmd) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: km.ralt) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: km.lalt) { _ in flagsChanged(Set(km.flags)) }
    }

    func flagsChanged(_ flags: Set<TriggerKey>) {
        guard NSApp.isActive else { return }
        withAnimation(.fastSpring) {
            zoomed = flags.hasElements(from: [.lcmd, .rcmd, .cmd])
            zoom = zoomed ? (flags.hasElements(from: [.lalt, .ralt, .alt]) ? 8.0 : 3.0) : 1.0
            if !zoomed {
                zoomOffset = .center
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
                    .frame(width: COMPARISON_VIEW_SIZE, height: COMPARISON_VIEW_SIZE)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipped()
            }.frame(width: COMPARISON_VIEW_SIZE)

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
            .frame(width: COMPARISON_VIEW_SIZE)
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

        let videoOpt = Optimiser(id: "Movies/sonoma-from-above.mov", type: .video(.quickTimeMovie), running: true, progress: nil)
        videoOpt.url = "\(HOME)/Movies/sonoma-from-above-opt.mp4".fileURL
        videoOpt.originalURL = "\(HOME)/Movies/sonoma-from-above.mov".fileURL
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
        CompareView(
            optimiser: ComparePreview.om.optimisers
                // .first(where: { $0.id == "Movies/sonoma-from-above.mov" })! )
//            .first(where: { $0.id == "pages.pdf" })!)
                .first(where: { $0.id == Optimiser.IDs.clipboardImage })!
        )
    }
}

#Preview {
    ComparePreview()
        .frame(width: 700, height: 500)
        .padding()
}
