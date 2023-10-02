//
//  FloatingResult.swift
//  Clop
//
//  Created by Alin Panaitiu on 26.07.2022.
//

import Defaults
import Lowtech
import LowtechPro
import SwiftUI

let FLOAT_MARGIN: CGFloat = 64

extension Int {
    var humanSize: String {
        switch self {
        case 0 ..< 1000:
            return "\(self)B"
        case 0 ..< 1_000_000:
            let num = self / 1000
            return "\(num)KB"
        case 0 ..< 1_000_000_000:
            let num = d / 1_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s)MB"
        default:
            let num = d / 1_000_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s)GB"
        }
    }
}

struct FloatingResultContainer: View {
    @ObservedObject var om = OM
    @ObservedObject var dragManager = DM
    var isPreview = false
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showImages) var showImages

    var body: some View {
        VStack(spacing: 10) {
            ForEach(om.optimisers.filter(!\.hidden).sorted(by: \.startedAt, order: .reverse).prefix(9)) { optimiser in
                FloatingResult(optimiser: optimiser, isPreview: isPreview, linear: om.optimisers.count > 1)
            }
            if !isPreview, dragManager.dragging {
                DropZoneView()
                    .transition(
                        .asymmetric(insertion: .scale.animation(.fastSpring), removal: .identity)
                    )
            }
        }.onHover { hovering in
            if !hovering {
                hoveredOptimiserID = nil
            }
        }
        .padding(.vertical, showImages ? 36 : 10)
        .padding(floatingResultsCorner.isTrailing ? .leading : .trailing, 20)
    }
}

@MainActor
struct FloatingPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let noThumb = Optimiser(id: "pages.pdf", type: .pdf)
        noThumb.url = "/Users/user/Documents/pages.pdf".fileURL
        noThumb.finish(oldBytes: 12_250_190, newBytes: 5_211_932)

        let videoOpt = Optimiser(id: "Movies/meeting-recording-video.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "/Users/user/Movies/meeting-recording-video.mov".fileURL
        videoOpt.operation = Defaults[.showImages] ? "Optimising" : "Optimising \(videoOpt.filename)"
        videoOpt.thumbnail = NSImage(named: "sonoma-video")
        videoOpt.changePlaybackSpeedFactor = 2.0

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "/Users/user/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(named: "sonoma-shot")
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        o.optimisers = [
            clipEnd,
            videoOpt,
            noThumb,
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

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }

}

// MARK: - FloatingResult

struct FloatingResult: View {
    // color(display-p3 0.9983 0.818 0.3296)
    static let yellow = Color(.displayP3, red: 1, green: 0.818, blue: 0.3296, opacity: 1)
    // color(display-p3 0.0193 0.4224 0.646)
    static let darkBlue = Color(.displayP3, red: 0.0193, green: 0.4224, blue: 0.646, opacity: 1)
    // color(display-p3 0.037 0.6578 0.9928)
    static let lightBlue = Color(.displayP3, red: 0.037, green: 0.6578, blue: 0.9928, opacity: 1)
    // color(display-p3 1 0.015 0.3)
    static let red = Color(.displayP3, red: 1, green: 0.015, blue: 0.2, opacity: 1)

    @ObservedObject var optimiser: Optimiser
    var isPreview = false

    @State var linear = false
    @State var hovering = false
    @State var hoveringThumbnail = false

    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.showImages) var showImages
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.keyComboModifiers) var keyComboModifiers
    @Default(.neverShowProError) var neverShowProError

    @Environment(\.openWindow) var openWindow

    @State var hotkeyMessageOpacity = 1.0

    @State var editingFilename = false

    @Environment(\.colorScheme) var colorScheme

    var showsThumbnail: Bool {
        optimiser.thumbnail != nil && showImages
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
        if optimiser.progress.isIndeterminate, !linear, optimiser.thumbnail == nil, optimiser.progress.kind != .file {
            HStack(spacing: 10) {
                Text(optimiser.operation).round(14, weight: .semibold)
                ProgressView(optimiser.progress).progressViewStyle(.circular)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if optimiser.progress.isIndeterminate {
                    Text(optimiser.operation)
                    progressURLView
                }
                ProgressView(optimiser.progress).progressViewStyle(.linear)
                if !optimiser.progress.isIndeterminate {
                    progressURLView.padding(.top, 5)
                }
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
            .font(.round(10))
            .foregroundColor(optimiser.thumbnail != nil && showImages ? .lightGray : .secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    @ViewBuilder
    var fileSizeDiff: some View {
        let improvement = optimiser.newBytes >= 0 && optimiser.newBytes < optimiser.oldBytes
        let improvementColor = (optimiser.thumbnail != nil && showImages ? FloatingResult.yellow : (colorScheme == .dark ? FloatingResult.lightBlue : FloatingResult.darkBlue))

        HStack {
            Text(optimiser.oldBytes.humanSize)
                .mono(13, weight: .semibold)
                .foregroundColor(improvement ? Color.red : improvementColor)
            if optimiser.newBytes >= 0 {
                SwiftUI.Image(systemName: "arrow.right")
                Text(optimiser.newBytes.humanSize)
                    .mono(13, weight: .semibold)
                    .foregroundColor(improvement ? improvementColor : FloatingResult.red)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .brightness(0.1)
        .saturation(1.1)
    }
    var closeStopButton: some View {
        Button(
            action: {
                if !isPreview {
                    hoveredOptimiserID = nil
                    optimiser.stop(animateRemoval: true)
                }
            },
            label: { SwiftUI.Image(systemName: optimiser.running ? "stop.fill" : "xmark").font(.heavy(9)) }
        )
        .help((optimiser.running ? "Stop" : "Close") + " (\(keyComboModifiers.str)⌫)")
        .buttonStyle(showsThumbnail ? FlatButton(color: .clear, textColor: .black, circle: true) : FlatButton(color: .inverted, textColor: .primary, circle: true))
        .background(
            VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow, state: .active, appearance: .vibrantLight)
                .clipShape(Circle())
                .shadow(radius: 2)
        )
    }
    @ViewBuilder var restoreOptimiseButton: some View {
        if optimiser.url != nil, !optimiser.running {
            if optimiser.isOriginal {
                Button(
                    action: { if !isPreview { optimiser.optimise(allowLarger: false) } },
                    label: { SwiftUI.Image(systemName: "goforward.plus").font(.heavy(9)) }
                )
                .help("Optimise")
            } else {
                Button(
                    action: { if !isPreview { optimiser.restoreOriginal() } },
                    label: { SwiftUI.Image(systemName: "arrow.uturn.left").font(.semibold(9)) }
                )
                .help("Restore original (\(keyComboModifiers.str)Z)")
            }
        }
    }
    var sideButtons: some View {
        VStack {
            Button(
                action: { if !isPreview { optimiser.downscale() }},
                label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) }
            )
            .help("Downscale (\(keyComboModifiers.str)-)")
            .contextMenu {
                DownscaleMenu(optimiser: optimiser)
            }

            Button(
                action: { if !isPreview { optimiser.quicklook() }},
                label: { SwiftUI.Image(systemName: "eye").font(.heavy(9)) }
            ).help("QuickLook (\(keyComboModifiers.str)space)")
            restoreOptimiseButton
            if !optimiser.aggresive {
                Button(
                    action: {
                        guard !isPreview else { return }

                        if optimiser.running {
                            optimiser.stop(remove: false)
                            optimiser.url = optimiser.originalURL
                            optimiser.finish(oldBytes: optimiser.oldBytes ?! optimiser.path?.fileSize() ?? 0, newBytes: -1)
                        }

                        if optimiser.downscaleFactor < 1 {
                            optimiser.downscale(toFactor: optimiser.downscaleFactor, aggressiveOptimisation: true)
                        } else {
                            optimiser.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
                        }
                    },
                    label: { SwiftUI.Image(systemName: "bolt").font(.heavy(9)) }
                ).help("Aggressive optimisation (\(keyComboModifiers.str)A)")
            }
        }
        .buttonStyle(FlatButton(color: .white.opacity(0.9), textColor: .black.opacity(0.7), width: showsThumbnail ? 24 : 18, height: showsThumbnail ? 24 : 18, circle: true))
        .animation(.fastSpring, value: optimiser.aggresive)
    }

    @ViewBuilder var noThumbnailView: some View {
        ZStack(alignment: .topLeading) {
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
                            .font(.semibold(14)).lineLimit(1).fixedSize().opacity(0.8)
                            .padding(.bottom, 4)
                    }
                    fileSizeDiff
                    sizeDiff
                }
            }

            closeStopButton.offset(x: -22, y: -16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            VisualEffectBlur(material: optimiser.error == nil ? .sidebar : .hudWindow, blendingMode: .behindWindow, state: .active)
                .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3).any
                .overlay(optimiser.error == nil ? .clear : .red.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
    @ViewBuilder var errorView: some View {
        let thumb = showsThumbnail
        let proError = optimiser.id == Optimiser.IDs.pro
        if let error = optimiser.error {
            VStack(alignment: proError ? .center : .leading) {
                if proError {
                    Button("Get Clop Pro") {
                        settingsViewManager.tab = .about
                        openWindow(id: "settings")

                        PRO?.manageLicence()
                        focus()
                    }
                    .buttonStyle(FlatButton(color: .inverted, textColor: .mauvish))
                    .font(.round(20, weight: .black))
                    .hfill()
                }
                Text(error)
                    .medium(14)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaledToFit()
                    .minimumScaleFactor(0.75)
                if let notice = optimiser.notice {
                    Text(notice)
                        .round(10)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .scaledToFit()
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(proError ? .center : .leading)
                }

                if proError {
                    Button("Never show this again") {
                        neverShowProError = true
                        hoveredOptimiserID = nil
                        optimiser.remove(after: 200, withAnimation: true)
                    }
                    .buttonStyle(FlatButton(color: .dynamicGray, textColor: .invertedGray))
                    .font(.round(12, weight: .regular))
                    .hfill()
                }
            }
            .padding(4)
            .padding(.bottom, thumb ? 4 : 0)
            .allowsTightening(true)
            .frame(maxWidth: thumb ? THUMB_SIZE.width : 250, alignment: .leading)
            .fixedSize(horizontal: !thumb, vertical: false)
        }
    }
    @ViewBuilder var noticeView: some View {
        if let notice = optimiser.notice {
            VStack(alignment: .leading) {
                ForEach(notice.components(separatedBy: "\n"), id: \.self) { line in
                    Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                        .lineLimit(2)
                        .scaledToFit()
                        .minimumScaleFactor(0.75)
                }
            }
            .allowsTightening(true)
            .frame(maxWidth: 250, alignment: .leading)
            .fixedSize(horizontal: !showsThumbnail, vertical: false)
        }
    }
    var gradient: some View {
        let color = optimiser.error == nil ? Color.black : Color.red
        return LinearGradient(colors: [color, color.opacity(0)], startPoint: .init(x: 0.5, y: 0.95), endPoint: .top)

    }

    @ViewBuilder var topRightButton: some View {
        if !optimiser.running, optimiser.canChangePlaybackSpeed() {
            let factor = optimiser.changePlaybackSpeedFactor.truncatingRemainder(dividingBy: 1) != 0
                ? String(format: "%.2f", optimiser.changePlaybackSpeedFactor)
                : optimiser.changePlaybackSpeedFactor.i.s
            Menu("\(factor)x") {
                ChangePlaybackSpeedMenu(optimiser: optimiser)
            }
            .menuButtonStyle(BorderlessButtonMenuButtonStyle())
            .help("Change Playback Speed" + " (\(keyComboModifiers.str)X)")
            .buttonStyle(FlatButton(color: .clear, textColor: .white, circle: optimiser.changePlaybackSpeedFactor >= 2))
            .font(.round(11, weight: .bold))
            .background(
                VisualEffectBlur(material: .popover, blendingMode: .withinWindow, state: .active, appearance: .vibrantDark)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(radius: 2)
            )

        } else {
            SwiftUI.Image(systemName: optimiser.type.isVideo ? "video.fill" : (optimiser.type.isPDF ? "doc.fill" : "photo.fill"))
                .font(.bold(11))
                .foregroundColor(.grayMauve)
                .padding(3)
                .padding(.top, 2)
                .padding(.trailing, 2)
                .background(
                    VisualEffectBlur(material: .popover, blendingMode: .withinWindow, state: .active, appearance: .vibrantLight)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                )
                .offset(x: 6, y: -8)
        }
    }

    @ViewBuilder var thumbnailView: some View {
        ZStack {
            VStack {
                HStack {
                    closeStopButton
                    Spacer()
                    topRightButton
                }.hfill(.leading)
                Spacer()

                if optimiser.running {
                    progressView
                        .controlSize(.small)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                } else if optimiser.error != nil {
                    errorView
                } else if optimiser.notice != nil {
                    noticeView
                        .foregroundColor(.white)
                } else {
                    VStack(spacing: 4) {
                        fileSizeDiff
                        sizeDiff
                    }
                }
            }
            .hfill(.leading)
            if optimiser.hotkeyMessage.isNotEmpty {
                Text(optimiser.hotkeyMessage)
                    .roundbg(radius: 12, padding: 6, color: .black)
                    .fill()
                    .background(
                        VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow, state: .active, appearance: .vibrantDark).scaleEffect(1.1)
                    )
                    .opacity(hotkeyMessageOpacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.15)) {
                            hotkeyMessageOpacity = 1.0
                        }
                        withAnimation(.easeIn(duration: 0.5).delay(0.3)) {
                            hotkeyMessageOpacity = 0.0
                        }
                    }
            }
        }
        .frame(
            width: THUMB_SIZE.width / 2,
            height: THUMB_SIZE.height / 2,
            alignment: .center
        )
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(
            SwiftUI.Image(nsImage: optimiser.thumbnail!)
                .resizable()
                .scaledToFill()
                .overlay(
                    VisualEffectBlur(material: .popover, blendingMode: .withinWindow, state: .active, appearance: .vibrantDark)
                        .clipped()
                        .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .init(x: 0.5, y: 0.7), endPoint: .init(x: 0.5, y: 0)))
                )
                .scaleEffect(hoveringThumbnail ? 1.1 : 1)
                .blur(radius: hoveringThumbnail ? 6 : 0, opaque: true)
                .any
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
        .ifLet(optimiser.url, transform: { view, url in
            view
                .draggable(url)
        })
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)

    }

    var body: some View {
        let hasThumbnail = optimiser.thumbnail != nil
        HStack {
            FlipGroup(if: !floatingResultsCorner.isTrailing) {
                if hasThumbnail, showImages {
                    VStack(alignment: floatingResultsCorner.isTrailing ? .leading : .trailing, spacing: 2) {
                        if let url = optimiser.url, url.isFileURL {
                            FileNameField(optimiser: optimiser)
                                .font(.medium(9))
                                .foregroundColor(.primary)
                                .padding(.leading, 5)
                                .background(
                                    VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow, state: .active)
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )
                                )
                                .frame(width: THUMB_SIZE.width / 2, height: 16, alignment: .leading)
                                .padding(.horizontal, 5)
                                .offset(y: hovering || editingFilename || SWIFTUI_PREVIEW ? 0 : 30)
                                .opacity(hovering || editingFilename || SWIFTUI_PREVIEW ? 1 : 0)
                                .scaleEffect(
                                    x: optimiser.editingFilename ? 1.2 : 1,
                                    y: optimiser.editingFilename ? 1.2 : 1,
                                    anchor: floatingResultsCorner.isTrailing ? .bottomTrailing : .bottomLeading
                                )
                        }
                        thumbnailView
                            .contentShape(Rectangle())
                            .onHover(perform: updateHover(_:))
                            .contextMenu {
                                RightClickMenuView(optimiser: optimiser)
                            }
                    }
                } else {
                    noThumbnailView
                        .contentShape(Rectangle())
                        .onHover(perform: updateHover(_:))
                        .contextMenu {
                            RightClickMenuView(optimiser: optimiser)
                        }
                }

                if hasThumbnail, hovering {
                    sideButtons
                } else {
                    SwiftUI.Image("clop")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30, alignment: .center)
                        .opacity(showFloatingHatIcon ? 1 : 0)
                }
            }
        }
        .frame(width: THUMB_SIZE.width, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
        .padding(.horizontal)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
        .opacity(optimiser.inRemoval ? 0 : 1)
        .offset(x: optimiser.inRemoval ? (floatingResultsCorner.isTrailing ? 500 : -500) : 0)
        .animation(.easeOut(duration: 0.5), value: optimiser.inRemoval)
        .onAppear {
            if optimiser.editingFilename {
                editingFilename = true
            } else {
                withAnimation(.spring().delay(2)) {
                    editingFilename = false
                }
            }
        }
        .onChange(of: optimiser.editingFilename) { newEditing in
            if newEditing {
                editingFilename = true
            } else {
                withAnimation(.spring().delay(2)) {
                    editingFilename = false
                }
            }
        }
    }

    func updateHover(_ hovering: Bool) {
        if hovering {
            hoveredOptimiserID = optimiser.id
        }
        withAnimation(.easeOut(duration: 0.15)) {
            hoveringThumbnail = hovering
        }
    }

}

@ViewBuilder
func FlipGroup(
    if value: Bool,
    @ViewBuilder _ content: @escaping () -> TupleView<(some View, some View)>
) -> some View {
    let pair = content()
    if value {
        TupleView((pair.value.1, pair.value.0))
    } else {
        TupleView((pair.value.0, pair.value.1))
    }
}

struct FloatingResultContainer_Previews: PreviewProvider {
    static var previews: some View {
        FloatingPreview()
//                        .background(.white)
//            .background(SwiftUI.Image("sonoma-video"))
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))

    }
}

// MARK: - SizeNotificationView_Previews

struct SizeNotificationView_Previews: PreviewProvider {
    static var finishedOpt: Optimiser {
        let o = Optimiser(
            id: Optimiser.IDs.clipboardImage,
            type: .image(.png),
            running: false,
            oldBytes: 750_190,
            newBytes: 211_932,
            oldSize: CGSize(width: 1920, height: 1080),
            newSize: CGSize(width: 1280, height: 720)
        )
        o.finish(error: "A server with the specified hostname could not be found.")
        return o
    }
    static var videoProgress: Progress {
        let p = Progress(totalUnitCount: 100_000)
        p.kind = .file
        p.fileOperationKind = .optimising
        p.fileURL = URL(filePath: "~/Desktop/Screen Recording 2023-07-09 at 15.32.07.mov")
        p.completedUnitCount = 30000
        return p
    }

    static var previews: some View {
        FloatingResult(optimiser: Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png)))
            .padding()
            .background(LinearGradient(colors: [Color.red, Color.orange, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("Optimising Clipboard")
        FloatingResult(optimiser: finishedOpt)
            .padding()
            .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("Finished Clipboard Optimisation")

        FloatingResult(optimiser: Optimiser(id: "~/Desktop/Screen Recording 2023-07-09 at 15.32.07.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress))
            .padding()
            .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("Optimising Video")
    }
}
