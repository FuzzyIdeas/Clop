import AVKit
import Defaults
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

    @Binding var playing: Bool

    var videoURL: URL
    var otherVideoURL: URL?

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

    @Binding var fitOrFill: ContentMode

    var url: URL
    var image: NSImage?

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

enum CompareMode: String, Defaults.Serializable {
    case sideBySide
    case split
}

enum ComparePane: String {
    case original
    case optimised
    case split
}

extension Defaults.Keys {
    static let compareMode = Key<CompareMode>("compareMode", default: .split)
}

@ViewBuilder
func fileActions(for url: URL) -> some View {
    Button("Open") {
        NSWorkspace.shared.open(url)
    }
    Button("Show in Finder") {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
    Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

struct PathFieldMenu: View {
    let url: URL

    var body: some View {
        Menu(url.shellString) {
            fileActions(for: url)
        }
        .menuStyle(.button)
        .buttonStyle(FlatButton(
            color: .bg.warm.opacity(hovering ? 0.9 : 0.5),
            textColor: hovering ? .primary : .secondary
        ))
        .font(.mono(10)).lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: COMPARISON_VIEW_SIZE)
        .onHover { hover in
            withAnimation(.fastTransition) { hovering = hover }
        }
    }

    @State private var hovering = false

}

/// A view that allows the user to preview a comparison of the optimised and original image/video/PDF.
struct CompareView: View {
    @ObservedObject var optimiser: Optimiser
    @ObservedObject var km = KM

    @Environment(\.colorScheme) var colorScheme

    @Default(.compareMode) var compareMode

    var improvementColor: Color {
        colorScheme == .dark ? FloatingResult.lightBlue : FloatingResult.darkBlue
    }

    var previewStack: some View {
        GeometryReader { _ in
            HStack {
                if let url = optimiser.url, let originalURL = optimiser.comparisonOriginalURL {
                    preview(url: originalURL, pane: .original, title: "Original", bytes: optimiser.oldBytes, size: optimiser.oldSize) {
                        renderer(for: originalURL, otherVideoURL: url)
                    }
                    preview(url: url, pane: .optimised, title: "Optimised", bytes: optimiser.newBytes ?! optimiser.oldBytes, size: optimiser.newSize ?? optimiser.oldSize) {
                        renderer(for: url)
                    }
                }
            }
            .hfill()
            .padding(.vertical)
            .overlay(savingsBadge.allowsHitTesting(false))
            .coordinateSpace(name: "compareArea")
            .onContinuousHover(perform: trackHover(_:))
        }
    }

    var splitStack: some View {
        GeometryReader { _ in
            VStack {
                if let url = optimiser.url, let originalURL = optimiser.comparisonOriginalURL {
                    HStack {
                        paneHeader(title: "Original", url: originalURL)
                        Spacer()
                        paneHeader(title: "Optimised", url: url)
                    }
                    splitPreview(originalURL: originalURL, optimisedURL: url)
                    splitFooter
                }
            }
            .hfill()
            .padding(.vertical)
            .coordinateSpace(name: "compareArea")
            .onContinuousHover(perform: trackHover(_:))
        }
    }

    @ViewBuilder var savingsBadge: some View {
        if optimiser.oldBytes > 0, optimiser.newBytes > 0, optimiser.newBytes != optimiser.oldBytes {
            let percent = ((optimiser.oldBytes - optimiser.newBytes) * 100) / optimiser.oldBytes
            if percent != 0 {
                Text(percent > 0 ? "-\(percent)%" : "+\(-percent)%")
                    .mono(12, weight: .bold)
                    .foregroundColor(percent > 0 ? improvementColor : FloatingResult.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(.ultraThickMaterial)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    )
            }
        }
    }

    @ViewBuilder var splitFooter: some View {
        let improvement = optimiser.newBytes > 0 && optimiser.newBytes < optimiser.oldBytes

        HStack(spacing: 6) {
            if optimiser.oldBytes > 0 {
                Text(optimiser.oldBytes.humanSize).mono(10, weight: .semibold)
                    .foregroundColor(.secondary)
                if optimiser.newBytes > 0, optimiser.newBytes != optimiser.oldBytes {
                    SwiftUI.Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text(optimiser.newBytes.humanSize).mono(10, weight: .semibold)
                        .foregroundColor(improvement ? improvementColor : FloatingResult.red)
                }
            }
            savingsBadge
            if let oldSize = optimiser.oldSize {
                Text("•").foregroundColor(.tertiaryLabel)
                Text(oldSize.s).mono(10).foregroundColor(.secondary)
                if let newSize = optimiser.newSize, newSize != oldSize {
                    SwiftUI.Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text(newSize.s).mono(10).foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            if compareMode == .split {
                splitStack
            } else {
                previewStack
            }

            controls

            if optimiser.type == .pdf, let url = optimiser.url ?? optimiser.comparisonOriginalURL, let pdf = PDFKitView.pdfViewCache[url]?.document {
                pdfControls(pdf: pdf)
            }

            if compareMode == .split {
                Text("Drag across the preview to move the split divider")
                    .round(10).foregroundColor(.tertiaryLabel)
                    .padding(.top, 6)
            }
            Text("Hold **⌘ Command** to zoom in, add **⌥ Option** to zoom further")
                .round(10).foregroundColor(.tertiaryLabel)
                .padding(.top, compareMode == .split ? 2 : 6)
        }
        .onChange(of: km.rcmd) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: km.lcmd) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: km.ralt) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: km.lalt) { _ in flagsChanged(Set(km.flags)) }
        .onChange(of: compareMode) { _ in
            paneFrames = [:]
            activePane = nil
        }
        .background(
            Button("") { optimiser.comparisonWindowController?.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .focusable(false)
    }

    var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $compareMode) {
                SwiftUI.Image(systemName: "rectangle.split.2x1")
                    .help("Side by side comparison")
                    .tag(CompareMode.sideBySide)
                SwiftUI.Image(systemName: "rectangle.lefthalf.inset.filled")
                    .help("Split comparison with a draggable divider")
                    .tag(CompareMode.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if optimiser.type.isVideo {
                Button {
                    videoPlaying.toggle()
                } label: {
                    SwiftUI.Image(systemName: videoPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(FlatButton())
                .keyboardShortcut(.space, modifiers: [])
                .help(videoPlaying ? "Pause both videos" : "Play both videos")
            }

            if optimiser.type.isImage {
                Button {
                    withAnimation(.fastSpring) {
                        fitOrFill = fitOrFill == .fill ? .fit : .fill
                    }
                } label: {
                    SwiftUI.Image(systemName: fitOrFill == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14))
                }
                .buttonStyle(FlatButton())
                .keyboardShortcut(.space, modifiers: [])
                .help(fitOrFill == .fit ? "Fill the preview area" : "Fit the whole image")
            }
        }
        .padding(.top, 10)
    }

    func splitPreview(originalURL: URL, optimisedURL: URL) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                // Frame each renderer to the full pane so fitted content stays centered;
                // the ZStack's `.leading` alignment would otherwise hug it to the left edge,
                // leaving the divider stranded relative to the visible image.
                renderer(for: optimisedURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(zoom, anchor: zoomOffset)
                renderer(for: originalURL, otherVideoURL: optimisedURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(zoom, anchor: zoomOffset)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(width * splitPosition, 0))
                    }
                splitDivider(height: proxy.size.height)
                    .offset(x: width * splitPosition - 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    splitPosition = min(max(value.location.x / width, 0), 1)
                }
            )
            .contextMenu {
                Section("Original") { fileActions(for: originalURL) }
                Section("Optimised") { fileActions(for: optimisedURL) }
            }
        }
        .frame(
            minWidth: COMPARISON_VIEW_SIZE / 2, idealWidth: COMPARISON_VIEW_SIZE * 2, maxWidth: .infinity,
            minHeight: COMPARISON_VIEW_SIZE / 2, idealHeight: COMPARISON_VIEW_SIZE, maxHeight: .infinity
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(paneFrameReader(.split))
    }

    func splitDivider(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2, height: height)
            .shadow(color: .black.opacity(0.55), radius: 3)
            .overlay(
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    SwiftUI.Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.primary)
                }
                .frame(width: 26, height: 26)
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    func pdfControls(pdf: PDFDocument) -> some View {
        VStack {
            HStack(spacing: 10) {
                if pdf.pageCount > 1 {
                    Button {
                        pdfPage -= 1
                    } label: {
                        SwiftUI.Image(systemName: "chevron.left")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(FlatButton())
                    .disabled(pdfPage == 1)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                }

                Text("Page \(pdfPage.i)/\(pdf.pageCount)")
                    .font(.round(11))

                if pdf.pageCount > 1 {
                    Button {
                        pdfPage += 1
                    } label: {
                        SwiftUI.Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(FlatButton())
                    .disabled(Int(pdfPage) == pdf.pageCount)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                }
            }

            if pdf.pageCount > 1 {
                Slider(value: $pdfPage, in: 1 ... pdf.pageCount.d, step: 1.0)
                    .frame(width: 400)
            }
        }
        .padding(.top, 8)
        .onChange(of: pdfPage) { page in
            if let url = optimiser.comparisonOriginalURL, let pdfView = PDFKitView.pdfViewCache[url], let page = pdfView.document?.page(at: page.i - 1) {
                pdfView.go(to: page)
            }
            if let url = optimiser.url, let otherPDFView = PDFKitView.pdfViewCache[url], let page = otherPDFView.document?.page(at: page.i - 1) {
                otherPDFView.go(to: page)
            }
        }
    }

    /// Pick the renderer from the actual file at this pane's URL, not `optimiser.type`. After a
    /// cross-media conversion the two panes can differ (e.g. a GIF made from a video: the optimised
    /// pane is the GIF image while the original pane is the source video), so each side must choose
    /// its player from its own file.
    @ViewBuilder
    func renderer(for url: URL, otherVideoURL: URL? = nil) -> some View {
        if url.filePath?.isVideo == true {
            let other = otherVideoURL?.filePath?.isVideo == true ? otherVideoURL : nil
            LoopingVideoPlayer(videoURL: url, otherVideoURL: other, playing: $videoPlaying)
        } else if url.filePath?.isPDF == true {
            PDFKitView(url: url)
                .allowsHitTesting(false)
                .aspectRatio(contentMode: fitOrFill)
        } else {
            PannableImage(url: url, fitOrFill: $fitOrFill)
        }
    }

    /// Reports the pane's frame in the shared "compareArea" coordinate space, so hover
    /// tracking can anchor the zoom to the pane the cursor was over when zooming started.
    func paneFrameReader(_ pane: ComparePane) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { paneFrames[pane] = proxy.frame(in: .named("compareArea")) }
                .onChange(of: proxy.frame(in: .named("compareArea"))) { paneFrames[pane] = $0 }
        }
    }

    func paneHeader(title: String, url: URL) -> some View {
        VStack {
            Text(title).bold(12)
            PathFieldMenu(url: url)
        }
    }

    func preview(url: URL, pane: ComparePane, title: String, bytes: Int? = nil, size: CGSize? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack {
            VStack {
                paneHeader(title: title, url: url)

                content()
                    .scaleEffect(zoom, anchor: zoomOffset)
                    .frame(
                        minWidth: COMPARISON_VIEW_SIZE / 2, idealWidth: COMPARISON_VIEW_SIZE, maxWidth: .infinity,
                        minHeight: COMPARISON_VIEW_SIZE / 2, idealHeight: COMPARISON_VIEW_SIZE, maxHeight: .infinity
                    )
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipped()
                    .contextMenu { fileActions(for: url) }
                    .background(paneFrameReader(pane))
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

    func trackHover(_ hoverPhase: HoverPhase) {
        switch hoverPhase {
        case let .active(location):
            hoverLocation = location
            if zoomed {
                updateZoomOffset(at: location)
            }
        case .ended:
            hoverLocation = nil
        }
    }

    /// Anchor the zoom inside the pane where it started: cursor positions are clamped to that
    /// pane's bounds, so both panes mirror the same in-pane point instead of tracking the window.
    func updateZoomOffset(at location: CGPoint) {
        guard let pane = activePane ?? pane(at: location), let frame = paneFrames[pane],
              frame.width > 0, frame.height > 0
        else { return }
        zoomOffset = UnitPoint(
            x: min(max((location.x - frame.minX) / frame.width, 0), 1),
            y: min(max((location.y - frame.minY) / frame.height, 0), 1)
        )
    }

    func pane(at location: CGPoint) -> ComparePane? {
        if let hit = paneFrames.first(where: { $0.value.contains(location) }) {
            return hit.key
        }
        return paneFrames.min(by: {
            abs($0.value.midX - location.x) < abs($1.value.midX - location.x)
        })?.key
    }

    func flagsChanged(_ flags: Set<TriggerKey>) {
        guard NSApp.isActive else { return }
        withAnimation(.fastSpring) {
            zoomed = flags.hasElements(from: [.lcmd, .rcmd, .cmd])
            zoom = zoomed ? (flags.hasElements(from: [.lalt, .ralt, .alt]) ? 8.0 : 3.0) : 1.0
            if zoomed {
                // Settle the anchor on key press so the zoom starts at the cursor
                // instead of jumping there on the first mouse move.
                if let hoverLocation {
                    if activePane == nil {
                        activePane = pane(at: hoverLocation)
                    }
                    updateZoomOffset(at: hoverLocation)
                }
            } else {
                activePane = nil
                zoomOffset = .center
            }
        }
    }

    @State private var pdfPage = 1.0

    @State private var videoPlaying = true

    @State private var fitOrFill = ContentMode.fill
    @State private var zoomed = false
    @State private var zoom = 1.0
    @State private var zoomOffset = UnitPoint.center
    @State private var splitPosition: CGFloat = 0.5
    @State private var paneFrames: [ComparePane: CGRect] = [:]
    @State private var hoverLocation: CGPoint?
    @State private var activePane: ComparePane?
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
