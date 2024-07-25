import AVKit
import Foundation
import Lowtech
import PDFKit
import SwiftUI

struct AVPlayerControllerRepresented: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

@MainActor
struct LoopingVideoPlayer: View {
    init(videoURL: URL, otherVideoURL: URL? = nil, playing: Binding<Bool>) {
        self.videoURL = videoURL
        self.otherVideoURL = otherVideoURL
        _playing = playing

        if let player = Self.playerCache[videoURL],
           let playerLooper = Self.playerLooperCache[videoURL],
           let video = Self.videoCache[videoURL]
        {
            self.video = video
            self.player = player
            self.playerLooper = playerLooper
            return
        }

        let asset = AVAsset(url: videoURL)
        video = AVPlayerItem(asset: asset)

        player = AVQueuePlayer(playerItem: video)
        player.isMuted = true
        player.allowsExternalPlayback = false

        playerLooper = AVPlayerLooper(player: player, templateItem: video)
        Self.playerLooperCache[videoURL] = playerLooper
        Self.playerCache[videoURL] = player
        Self.videoCache[videoURL] = video

        if otherVideoURL != nil {
            setupPeriodicTimeObserver()
        }
    }

    static var playerCache = [URL: AVQueuePlayer]()
    static var playerLooperCache = [URL: AVPlayerLooper]()
    static var videoCache = [URL: AVPlayerItem]()
    static var timeObserverTokens = [URL: Any]()

    var videoURL: URL
    var otherVideoURL: URL?

    @Binding var playing: Bool

    var body: some View {
        AVPlayerControllerRepresented(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .onChange(of: playing) { playing in
                if playing {
                    player.play()
                } else {
                    player.pause()
                }
            }
    }

    var otherPlayer: AVQueuePlayer? {
        get {
            guard let otherVideoURL else { return nil }
            return Self.playerCache[otherVideoURL]
        }
        set {
            guard let otherVideoURL else { return }
            guard let newValue else {
                Self.playerCache.removeValue(forKey: otherVideoURL)
                return
            }
            Self.playerCache[otherVideoURL] = newValue
        }
    }

    static func clearCache(for urls: [URL]) {
        for url in urls {
            let player = playerCache.removeValue(forKey: url)
            playerLooperCache.removeValue(forKey: url)
            videoCache.removeValue(forKey: url)

            if let token = timeObserverTokens[url] {
                player?.removeTimeObserver(token)
                timeObserverTokens.removeValue(forKey: url)
            }
        }
    }

    private var video: AVPlayerItem
    private var player: AVQueuePlayer
    private var playerLooper: AVPlayerLooper

    private func setupPeriodicTimeObserver() {
        let timeInterval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        Self.timeObserverTokens[videoURL] = player.addPeriodicTimeObserver(forInterval: timeInterval, queue: .main) { time in
            mainActor { syncPlayerTimes(with: time) }
        }
    }

    private func syncPlayerTimes(with time: CMTime) {
        guard let otherPlayer, let otherCurrentItem = otherPlayer.currentItem else { return }

        let otherCurrentTime = otherCurrentItem.currentTime()
        let timeDifference = abs(CMTimeGetSeconds(time) - CMTimeGetSeconds(otherCurrentTime))

        if timeDifference > 0.5 {
            otherPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

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

struct PannableImage: View {
    init(url: URL, fitOrFill: Binding<ContentMode> = .constant(.fill)) {
        self.url = url
        _fitOrFill = fitOrFill
        if let image = Self.imageCache[url] {
            self.image = image
            return
        }

        let image = NSImage(contentsOf: url)
        Self.imageCache[url] = image
    }

    static var imageCache = [URL: NSImage]()

    var url: URL
    var image: NSImage?

    @Binding var fitOrFill: ContentMode

    var body: some View {
        if let image {
            SwiftUI.Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: fitOrFill)
        } else {
            ProgressView()
        }
    }

    static func clearCache(for urls: [URL]) {
        for url in urls {
            imageCache.removeValue(forKey: url)
        }
    }

    @State private var offset = CGSize.zero
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

    var previewStack: some View {
        GeometryReader { proxy in
            HStack {
                if let url = optimiser.url, let originalURL = optimiser.comparisonOriginalURL {
                    preview(
                        url: originalURL,
                        title: "Original",
                        bytes: optimiser.oldBytes,
                        size: optimiser.oldSize,
                        aspectRatio: (optimiser.newSize == nil || optimiser.oldSize?.aspectRatio == optimiser.newSize?.aspectRatio) ? (optimiser.oldSize?.aspectRatio ?? 1) : 1
                    ) {
                        switch optimiser.type {
                        case .video:
                            LoopingVideoPlayer(videoURL: originalURL, otherVideoURL: url, playing: $videoPlaying)
                        case .image:
                            PannableImage(url: originalURL, fitOrFill: $fitOrFill)
                        case .pdf:
                            PDFKitView(url: originalURL)
                                .allowsHitTesting(false)
                                .aspectRatio(contentMode: fitOrFill)
                        default:
                            EmptyView()
                        }
                    }
                    preview(
                        url: url,
                        title: "Optimised",
                        bytes: optimiser.newBytes ?! optimiser.oldBytes,
                        size: optimiser.newSize ?? optimiser.oldSize,
                        aspectRatio: (optimiser.newSize == nil || optimiser.oldSize?.aspectRatio == optimiser.newSize?.aspectRatio) ? (optimiser.oldSize?.aspectRatio ?? 1) : 1
                    ) {
                        switch optimiser.type {
                        case .video:
                            LoopingVideoPlayer(videoURL: url, playing: $videoPlaying)
                        case .image:
                            PannableImage(url: url, fitOrFill: $fitOrFill)
                        case .pdf:
                            PDFKitView(url: url)
                                .allowsHitTesting(false)
                                .aspectRatio(contentMode: fitOrFill)
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

            if optimiser.type.isVideo {
                Button {
                    videoPlaying.toggle()
                } label: {
                    SwiftUI.Image(systemName: videoPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(FlatButton())
                .keyboardShortcut(.space, modifiers: [])
                .padding(.top, 10)
            }

            if optimiser.type == .pdf, let url = optimiser.url ?? optimiser.comparisonOriginalURL, let pdf = PDFKitView.pdfViewCache[url]?.document {
                VStack {
                    Text("Page \(pdfPage.i)/\(pdf.pageCount)")
                    if pdf.pageCount > 1 {
                        Slider(value: $pdfPage, in: 1 ... pdf.pageCount.d, step: 1.0)
                            .frame(width: 400)
                    }
                }
                .font(.round(11))
                .padding(.top, 10)
                .onChange(of: pdfPage) { page in
                    if let url = optimiser.comparisonOriginalURL, let pdfView = PDFKitView.pdfViewCache[url], let page = pdfView.document?.page(at: page.i) {
                        pdfView.go(to: page)
                    }
                    if let url = optimiser.url, let otherPDFView = PDFKitView.pdfViewCache[url], let page = otherPDFView.document?.page(at: page.i) {
                        otherPDFView.go(to: page)
                    }
                }

                if pdf.pageCount > 1 {
                    HStack {
                        Button {
                            pdfPage -= 1
                        } label: {
                            SwiftUI.Image(systemName: "chevron.left")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(FlatButton())
                        .disabled(pdfPage == 1)
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Button {
                            pdfPage += 1
                        } label: {
                            SwiftUI.Image(systemName: "chevron.right")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(FlatButton())
                        .disabled(Int(pdfPage) == pdf.pageCount)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                }
            }

            if optimiser.type.isImage {
                Button {
                    withAnimation(.fastSpring) {
                        fitOrFill = fitOrFill == .fill ? .fit : .fill
                    }
                } label: {
                    SwiftUI.Image(systemName: fitOrFill == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 20))
                }
                .buttonStyle(FlatButton())
                .keyboardShortcut(.space, modifiers: [])
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
        .focusable(false)
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
    func preview(url: URL, title: String, bytes: Int? = nil, size: CGSize? = nil, aspectRatio: Double = 1, @ViewBuilder content: () -> some View) -> some View {
        VStack {
            VStack {
                Text(title).bold(12)
                Menu(url.shellString) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(FlatButton(color: .bg.warm.opacity(0.5), textColor: .secondary))
                .font(.mono(10)).lineLimit(1)
                .foregroundColor(.secondary)
                .truncationMode(.middle)

                content()
                    .scaleEffect(zoom, anchor: zoomOffset)
                    .frame(
                        minWidth: COMPARISON_VIEW_SIZE / 2, idealWidth: COMPARISON_VIEW_SIZE, maxWidth: .infinity,
                        minHeight: COMPARISON_VIEW_SIZE / 2, idealHeight: COMPARISON_VIEW_SIZE, maxHeight: .infinity
                    )
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipped()
            }.frame(minWidth: COMPARISON_VIEW_SIZE / 2, idealWidth: COMPARISON_VIEW_SIZE)

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
            .frame(minWidth: COMPARISON_VIEW_SIZE / 2, idealWidth: COMPARISON_VIEW_SIZE)
            .foregroundColor(.secondary)
            .padding(.top, 4)
        }
    }

    @State private var pdfPage = 1.0

    @State private var originalImage: NSImage?
    @State private var optimisedImage: NSImage?

    @State private var originalVideo: PDFDocument?
    @State private var optimisedPDF: PDFDocument?

    @State private var videoPlaying = true

    @State private var fitOrFill = ContentMode.fill
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
                //         .first(where: { $0.id == "Movies/sonoma-from-above.mov" })!
                // )
//                .first(where: { $0.id == "pages.pdf" })!
//        )
                .first(where: { $0.id == Optimiser.IDs.clipboardImage })!
        )
    }
}

#Preview {
    ComparePreview()
        .frame(width: COMPARISON_VIEW_SIZE + 100, height: COMPARISON_VIEW_SIZE / 2 + 200)
        .padding()
}
