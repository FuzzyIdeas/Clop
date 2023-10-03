import Defaults
import Foundation
import Lowtech
import LowtechPro
import SwiftUI

struct CompactResult: View {
    @ObservedObject var optimiser: Optimiser
    @State var hovering = false

    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.neverShowProError) var neverShowProError

    @Environment(\.openWindow) var openWindow

    @Default(.showCompactImages) var showCompactImages

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
            Text(url.absoluteString)
                .medium(10)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .allowsTightening(true)
                .truncationMode(.middle)
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
                .foregroundColor(improvement ? Color.secondary : Color.primary)
            if optimiser.newBytes >= 0 {
                SwiftUI.Image(systemName: "arrow.right")
                    .font(.medium(11))
                Text(optimiser.newBytes.humanSize)
                    .mono(11, weight: .semibold)
                    .foregroundColor(improvement ? Color.primary : Color.secondary)
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
            if showCompactImages, let image = optimiser.thumbnail {
                SwiftUI.Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

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
                .buttonStyle(FlatButton(color: .inverted.opacity(0.7), textColor: .primary.opacity(0.7), circle: true))
        }
        .ifLet(optimiser.url, transform: { view, url in
            view.draggable(url)
        })
        .padding(.vertical, 3)
        .onHover(perform: updateHover(_:))
        .contextMenu {
            RightClickMenuView(optimiser: optimiser)
        }
    }

    func updateHover(_ hovering: Bool) {
        if hovering {
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

    @Default(.floatingResultsCorner) var floatingResultsCorner

    var body: some View {
        let isTrailing = floatingResultsCorner.isTrailing

        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 5) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                Button("Clear all") {
                    hoveredOptimiserID = nil
                    OM.removedOptimisers = OM.removedOptimisers.filter { o in !OM.optimisers.contains(o) }.with(OM.optimisers.arr)
                    OM.optimisers.filter(\.running).forEach { $0.stop(remove: false) }
                    OM.optimisers = OM.optimisers.filter(\.hidden)
                }
                .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .mauvish, radius: 7, verticalPadding: 2))
                .font(.medium(11))
                .opacity(hovering ? 1 : 0)
                .focusable(false)
                .if(!showList, transform: { $0.hidden() })

                List {
                    ForEach(optimisers) { optimiser in
                        ZStack {
                            CompactResult(optimiser: optimiser)
                            OverlayMessageView(optimiser: optimiser, color: .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .gesture(TapGesture(count: 2).onEnded {
                            if let url = optimiser.url {
                                NSWorkspace.shared.open(url)
                            }
                        })
                        .swipeActions(edge: isTrailing ? .leading : .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive, action: {
                                hoveredOptimiserID = nil
                                optimiser.stop(remove: true, animateRemoval: true)
                            }, label: {
                                Label(optimiser.running ? "Stop" : "Remove", systemImage: optimiser.running ? "stop.fill" : "xmark")
                            })
                        }
                    }
                }
                .frame(width: THUMB_SIZE.width, height: min(360, (optimisers.count * 50).cg), alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .if(!showList, transform: { $0.hidden() })

                ToggleCompactResultListButton(showList: $showList, badge: optimisers.count.s)
                    .offset(x: 10)
            }
        }
        .padding(isTrailing ? .trailing : .leading)
        .frame(width: THUMB_SIZE.width + 50, height: 442, alignment: floatingResultsCorner.alignment)
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
                                .padding(2)
                                .background(Circle().fill(.gray))
                                .offset(x: 0, y: -6)
                                .opacity(0.75)
                        }
                    }
                })
                .buttonStyle(FlatButton(color: .clear, textColor: .primary, radius: 7, verticalPadding: 2))

                Text(showList ? "Hide" : "Show")
                    .font(.medium(10))
                    .roundbg(radius: 5, padding: 2, color: .inverted.opacity(0.9))
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
        errorOpt.finish(error: "Already optimised")

        let pdfEnd = Optimiser(id: "pages.pdf", type: .pdf)
        pdfEnd.url = "\(HOME)/Documents/pages.pdf".fileURL
        pdfEnd.finish(oldBytes: 12_250_190, newBytes: 5_211_932)

        let pdfRunning = Optimiser(id: "scans.pdf", type: .pdf, running: true, progress: pdfProgress)
        pdfRunning.url = "\(HOME)/Documents/scans.pdf".fileURL
        pdfRunning.operation = "Optimising"

        let videoOpt = Optimiser(id: "Movies/meeting-recording.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "\(HOME)/Movies/meeting-recording.mov".fileURL
        videoOpt.operation = "Optimising"
        videoOpt.thumbnail = NSImage(named: "sonoma-video")
        videoOpt.changePlaybackSpeedFactor = 2.0

        let videoToGIF = Optimiser(id: "Videos/app-ui-demo.mov", type: .video(.quickTimeMovie), running: true, progress: videoToGIFProgress)
        videoToGIF.url = "\(HOME)/Videos/app-ui-demo.mov".fileURL
        videoToGIF.operation = "Converting to GIF"

        let gifOpt = Optimiser(id: "https://files.lowtechguys.com/moon.gif", type: .image(.gif), running: true, progress: gifProgress)
        gifOpt.url = "https://files.lowtechguys.com/moon.gif".url!
        gifOpt.operation = "Downloading"

        let pngIndeterminate = Optimiser(id: "png-indeterminate", type: .image(.png), running: true)
        pngIndeterminate.url = "\(HOME)/Desktop/dash-screenshot.png".fileURL
        pngIndeterminate.thumbnail = NSImage(named: "sonoma-shot")

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(named: "sonoma-shot")
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

//        clipEnd.overlayMessage = "Copied"

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
