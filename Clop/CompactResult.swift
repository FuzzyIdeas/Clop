import Defaults
import Foundation
import Lowtech
import LowtechPro
import SwiftUI

struct CompactResult: View {
    static let improvementColor = Color(light: FloatingResult.darkBlue, dark: FloatingResult.yellow)

    @ObservedObject var optimiser: Optimiser
    @State var hovering = false

    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.neverShowProError) var neverShowProError

    @Environment(\.openWindow) var openWindow

    @Default(.showCompactImages) var showCompactImages

    @Environment(\.preview) var preview

    @ViewBuilder var pathView: some View {
        if let url = optimiser.url, url.isFileURL {
            Text(url.filePath.shellString)
                .medium(9)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .allowsTightening(true)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder var nameView: some View {
        if let url = optimiser.url, url.isFileURL {
            Text(url.lastPathComponent)
                .medium(9)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .frame(width: 120, alignment: .trailing)
                .allowsTightening(true)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder var progressURLView: some View {
        if optimiser.type.isURL, let url = optimiser.url {
            HStack(spacing: 2) {
                SwiftUI.Image(systemName: "link")
                    .font(.medium(10))
                    .foregroundColor(.secondary.opacity(0.75))

                Link(url.absoluteString, destination: url)
                    .font(.medium(10))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .truncationMode(.middle)
            }
        }
    }
    @ViewBuilder var progressView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if optimiser.progress.isIndeterminate {
                HStack(alignment: .bottom) {
                    Text(optimiser.operation)
                    Spacer()
                    nameView
                }
                progressURLView
                ProgressView(optimiser.progress).progressViewStyle(.linear)
            } else {
                ZStack(alignment: .topTrailing) {
                    ProgressView(optimiser.progress).progressViewStyle(.linear)
                    nameView.offset(y: 2)
                }
                progressURLView.padding(.top, 5)
            }
        }
    }
    @ViewBuilder var sizeDiff: some View {
        if let oldSize = optimiser.oldSize {
            HStack(spacing: 3) {
                Text("\(oldSize.width.i)×\(oldSize.height.i)")
                if let newSize = optimiser.newSize, newSize != oldSize {
                    SwiftUI.Image(systemName: "arrow.right")
                    Text("\(newSize.width.i)×\(newSize.height.i)")
                }
            }
            .font(.mono(11, weight: .medium))
            .foregroundColor(.secondary.opacity(0.7))
            .lineLimit(1)
            .fixedSize()
        }
    }

    @ViewBuilder var fileSizeDiff: some View {
        let improvement = optimiser.newBytes >= 0 && optimiser.newBytes < optimiser.oldBytes

        HStack {
            Text(optimiser.oldBytes.humanSize)
                .mono(11, weight: .semibold)
                .foregroundColor(improvement ? Color.red : Color.secondary)
            if optimiser.newBytes >= 0, optimiser.newBytes != optimiser.oldBytes {
                SwiftUI.Image(systemName: "arrow.right")
                    .font(.medium(11))
                Text(optimiser.newBytes.humanSize)
                    .mono(11, weight: .semibold)
                    .foregroundColor(improvement ? Self.improvementColor : FloatingResult.red)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder var errorView: some View {
        let proError = optimiser.id == Optimiser.IDs.pro
        if let error = optimiser.error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .medium(12)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if let notice = optimiser.notice {
                    Text(notice)
                        .round(10)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if proError {
                    HStack {
                        Button("Get Clop Pro") {
                            settingsViewManager.tab = .about
                            openWindow(id: "settings")

                            PRO?.manageLicence()
                            focus()
                        }
                        .buttonStyle(FlatButton(color: .inverted, textColor: .mauvish, radius: 5, verticalPadding: 2))
                        .font(.round(10, weight: .heavy))
                        .colorMultiply(.mauvish.blended(withFraction: 0.8, of: .white))
                        Spacer()
                        Button("Never show this again") {
                            neverShowProError = true
                            hoveredOptimiserID = nil
                            optimiser.remove(after: 200, withAnimation: true)
                        }
                        .buttonStyle(FlatButton(color: .inverted.opacity(0.8), textColor: .secondary, radius: 5, verticalPadding: 2))
                        .font(.round(10, weight: .semibold))
                    }
                }
                pathView
            }
            .allowsTightening(true)
        }
    }
    @ViewBuilder var thumbnail: some View {
        if showCompactImages {
            if let image = optimiser.thumbnail {
                SwiftUI.Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                SwiftUI.Image(systemName: optimiser.type.icon)
                    .font(.system(size: 22))
                    .frame(width: 40)
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
    }
    @ViewBuilder var noticeView: some View {
        if let notice = optimiser.notice {
            VStack(alignment: .leading) {
                ForEach(notice.components(separatedBy: "\n"), id: \.self) { line in
                    Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
            }
            .allowsTightening(true)
        }
    }
    var body: some View {
        HStack {
            thumbnail

            if optimiser.running {
                progressView
                    .controlSize(.small)
                    .lineLimit(1)
            } else if optimiser.error != nil {
                errorView
            } else if optimiser.notice != nil {
                noticeView
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let url = optimiser.url, url.isFileURL {
                        FileNameField(optimiser: optimiser)
                            .foregroundColor(.primary)
                            .font(.medium(12)).lineLimit(1).fixedSize()
                    }
                    HStack {
                        fileSizeDiff
                        Spacer()
                        sizeDiff
                    }
                    ActionButtons(optimiser: optimiser, size: 18)
                        .padding(.top, 2)
                        .opacity(hovering ? 1 : 0.3)
                }
            }

            Spacer()
            CloseStopButton(optimiser: optimiser)
                .buttonStyle(FlatButton(color: .primary.opacity(0.13), textColor: Color.mauvish.opacity(0.8), circle: true))
                .focusable(false)
        }
        .padding(.top, 3)
        .onHover(perform: updateHover(_:))
        .ifLet(optimiser.url, transform: { view, url in
            view.draggable(url)
        })
    }

    func updateHover(_ hovering: Bool) {
        if hovering, !preview {
            hoveredOptimiserID = optimiser.id
        }
        withAnimation(.easeOut(duration: 0.15)) {
            self.hovering = hovering
        }
    }

}

struct OverlayMessageView: View {
    @ObservedObject var optimiser: Optimiser
    var color: Color

    @State var opacity = 1.0

    var body: some View {
        if optimiser.overlayMessage.isNotEmpty {
            Text(optimiser.overlayMessage)
                .roundbg(radius: 12, padding: 6, color: color)
                .fill()
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow, state: .active, appearance: color == .black ? .vibrantDark : .none).scaleEffect(1.1)
                )
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.15)) {
                        opacity = 1.0
                    }
                    withAnimation(.easeIn(duration: 0.5).delay(0.3)) {
                        opacity = 0.0
                    }
                }
        }

    }
}

struct CompactResultList: View {
    @State var hovering = false
    @State var showList = true
    var optimisers: [Optimiser]
    var progress: Progress?

    var doneCount: Int
    var failedCount: Int
    var visibleCount: Int

    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showCompactImages) var showCompactImages

    @Environment(\.preview) var preview

    var body: some View {
        let isTrailing = floatingResultsCorner.isTrailing

        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 5) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                Button("Clear all") {
                    OM.clearVisibleOptimisers(stop: true)
                }
                .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .mauvish, radius: 7, verticalPadding: 2))
                .font(.medium(11))
                .opacity(hovering ? 1 : 0)
                .focusable(false)
                .opacity(showList ? 1 : 0)

                let opts = optimisers.dropLast().map { ($0, false) } + [(optimisers.last!, true)]
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical, showsIndicators: false) {
                        ForEach(opts, id: \.0.id) { optimiser, isLast in
                            ZStack {
                                CompactResult(optimiser: optimiser)
                                OverlayMessageView(optimiser: optimiser, color: .secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .padding(.horizontal, 10)
                            .gesture(TapGesture(count: 2).onEnded {
                                if let url = optimiser.url {
                                    NSWorkspace.shared.open(url)
                                }
                            })

                            if !isLast {
                                Divider().background(.secondary.opacity(0.35))
                            }
                        }
                        .padding(.bottom, progress == nil ? 0 : 22)
                    }
                    .padding(.vertical, 5)
                    .frame(width: THUMB_SIZE.width + (showCompactImages ? 50 : 0), height: min(360, (optimisers.count * 70).cg), alignment: .center)
                    .background(Color.inverted.brightness(0.1))

                    if progress != nil {
                        ProgressView(" Done: \(doneCount)/\(visibleCount)  |  Failed: \(failedCount)/\(visibleCount)", value: (doneCount + failedCount).d, total: visibleCount.d)
                            .controlSize(.small)
                            .frame(width: THUMB_SIZE.width + (showCompactImages ? 40 : -10))
                            .padding(.top, 4)
                            .background(VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow, state: .active).scaleEffect(1.1))
                            .offset(y: 6)
                            .font(.mono(9))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: preview ? 0 : 10)
                .opacity(showList ? 1 : 0)
                .allowsHitTesting(showList)

                ToggleCompactResultListButton(showList: $showList.animation(), badge: optimisers.count.s)
                    .offset(x: isTrailing ? 10 : -10)
            }
        }
        .padding(isTrailing ? .trailing : .leading)
        .frame(width: THUMB_SIZE.width + (showCompactImages ? 60 : 50), height: 442, alignment: floatingResultsCorner.alignment)
        .contentShape(Rectangle())
        .onHover { hovered in
            withAnimation(.easeIn(duration: 0.35)) {
                hovering = hovered
            }
        }
    }
}

struct ToggleCompactResultListButton: View {
    @Binding var showList: Bool
    var badge: String

    var body: some View {
        VStack(spacing: 0) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                Button(action: { showList.toggle() }, label: {
                    ZStack(alignment: floatingResultsCorner.isTrailing ? .topLeading : .topTrailing) {
                        SwiftUI.Image("clop")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30, alignment: .center)
                        if !showList {
                            Text(badge)
                                .round(10)
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Circle().fill(Color.darkGray))
                                .offset(x: 0, y: -6)
                                .opacity(0.75)
                        }
                    }
                })
                .buttonStyle(FlatButton(color: .clear, textColor: .primary, radius: 7, verticalPadding: 2))

                Text(showList ? "Hide" : "Show")
                    .font(.medium(10))
                    .roundbg(radius: 5, padding: 2, color: .inverted.opacity(0.9), noFG: true)
                    .foregroundColor(.primary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
    }

    @Default(.floatingResultsCorner) private var floatingResultsCorner
    @State private var hovering = false

}

@MainActor
struct CompactPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let errorOpt = Optimiser(id: "file-with-error", type: .image(.png))
        errorOpt.url = "\(HOME)/Desktop/passport-scan.png".fileURL
        errorOpt.thumbnail = NSImage(named: "passport")
        errorOpt.finish(error: "Already optimised")

        let pdfRunning = Optimiser(id: "scans.pdf", type: .pdf, running: true, progress: pdfProgress)
        pdfRunning.url = "\(HOME)/Documents/scans.pdf".fileURL
        pdfRunning.operation = "Optimising"
        pdfRunning.thumbnail = NSImage(named: "scans.pdf")

        let videoOpt = Optimiser(id: "Movies/meeting-recording.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "\(HOME)/Movies/meeting-recording.mov".fileURL
        videoOpt.operation = "Optimising"
        videoOpt.thumbnail = NSImage(named: "sonoma-video")
        videoOpt.changePlaybackSpeedFactor = 2.0

        let videoToGIF = Optimiser(id: "Videos/app-ui-demo.mov", type: .video(.quickTimeMovie), running: true, progress: videoToGIFProgress)
        videoToGIF.url = "\(HOME)/Videos/app-ui-demo.mov".fileURL
        videoToGIF.operation = "Converting to GIF"
        videoToGIF.thumbnail = NSImage(named: "app-ui-demo")

        let pdfEnd = Optimiser(id: "pages.pdf", type: .pdf)
        pdfEnd.url = "\(HOME)/Documents/pages.pdf".fileURL
        pdfEnd.thumbnail = NSImage(named: "pages.pdf")
        pdfEnd.finish(oldBytes: 12_250_190, newBytes: 15_211_932)

        let gifOpt = Optimiser(id: "https://files.lowtechguys.com/moon.gif", type: .url, running: true, progress: gifProgress)
        gifOpt.url = "https://files.lowtechguys.com/moon.gif".url!
        gifOpt.operation = "Downloading"

        let pngIndeterminate = Optimiser(id: "png-indeterminate", type: .image(.png), running: true)
        pngIndeterminate.url = "\(HOME)/Desktop/dash-screenshot.png".fileURL
        pngIndeterminate.thumbnail = NSImage(named: "sonoma-shot")

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(named: "sonoma-shot")
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        let proErrorOpt = Optimiser(id: Optimiser.IDs.pro, type: .unknown)
        proErrorOpt.finish(error: "Free version limits reached", notice: "Only 2 file optimisations per session\nare included in the free version")

        let noticeOpt = Optimiser(id: "notice", type: .unknown, operation: "")
        noticeOpt.finish(notice: "**Paused**\nNext clipboard event will be ignored")

        o.optimisers = [
            clipEnd,
            videoOpt,
//            proErrorOpt,
            gifOpt,
            errorOpt,
            pngIndeterminate,
            pdfRunning,
//            noticeOpt,
            pdfEnd,
            videoToGIF,
        ]
        o.updateProgress()
        return o
    }()

    static var videoProgress: Progress = {
        let p = Progress(totalUnitCount: 103_021_021)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 32_473_200
        p.localizedAdditionalDescription = "\(p.completedUnitCount.hmsString) of \(p.totalUnitCount.hmsString)"
        return p
    }()

    static var videoToGIFProgress: Progress = {
        let p = Progress(totalUnitCount: 492)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 201
        p.localizedAdditionalDescription = "Frame \(p.completedUnitCount) of \(p.totalUnitCount)"
        return p
    }()

    static var gifProgress: Progress = {
        let p = Progress(totalUnitCount: 23_421_021)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 17_473_200
        p.localizedAdditionalDescription = "\(p.completedUnitCount) of \(p.totalUnitCount) bytes"
        return p
    }()

    static var pdfProgress: Progress = {
        let p = Progress(totalUnitCount: 231)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 35
        p.localizedAdditionalDescription = "Page \(p.completedUnitCount) of \(p.totalUnitCount)"
        return p
    }()

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }

}

struct CompactResult_Previews: PreviewProvider {
    static var previews: some View {
        CompactPreview()
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
