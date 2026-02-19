//
//  FloatingResult.swift
//  Clop
//
//  Created by Alin Panaitiu on 26.07.2022.
//

import Defaults
import Lowtech
import LowtechIndie
import LowtechPro
import SwiftUI
import UniformTypeIdentifiers

let FLOAT_MARGIN: CGFloat = 64

private struct PreviewKey: EnvironmentKey {
    public static let defaultValue = false
}

extension EnvironmentValues {
    var preview: Bool {
        get { self[PreviewKey.self] }
        set { self[PreviewKey.self] = newValue }
    }
}

extension View {
    func preview(_ preview: Bool) -> some View {
        environment(\.preview, preview)
    }
}

struct FloatingResultList: View {
    var optimisers: [Optimiser]

    @State var copiedText = "Copy all"
    @Default(.floatingResultsCorner) var floatingResultsCorner

    var copyAllButton: some View {
        Button(copiedText) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let urls = optimisers.compactMap(\.url)
            pasteboard.writeObjects(urls as [NSPasteboardWriting])
            copiedText = "Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copiedText = "Copy all"
            }
        }
        .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .primary, radius: 7, verticalPadding: 2))
        .font(.medium(11))
        .focusable(false)
    }

    var clearAllButton: some View {
        Button("Clear all") {
            for optimiser in optimisers {
                optimiser.remove(after: 100, withAnimation: true)
            }
        }
        .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .primary, radius: 7, verticalPadding: 2))
        .font(.medium(11))
        .focusable(false)
    }

    var body: some View {
        VStack(alignment: floatingResultsCorner.isTrailing ? .leading : .trailing, spacing: 10) {
            ForEach(optimisers) { optimiser in
                FloatingResult(optimiser: optimiser, linear: optimisers.count > 1)
                    .gesture(TapGesture(count: 2).onEnded {
                        if let url = optimiser.url {
                            NSWorkspace.shared.open(url)
                        }
                    })
            }
            if optimisers.count > 1 {
                HStack {
                    copyAllButton
                    clearAllButton
                }.padding(floatingResultsCorner.isTrailing ? .leading : .trailing, 18)
            }
        }
    }
}

struct UpdateButton: View {
    var short = false
    @ObservedObject var um: UpdateManager = UM
    @State var hovering = false

    var body: some View {
        if let updateVersion = um.newVersion {
            Button(short ? "v\(updateVersion) available" : "v\(updateVersion) update available") {
                checkForUpdates()
                focus()
            }
            .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .mauvish, radius: 7, verticalPadding: 2))
            .font(.medium(11))
            .opacity(hovering ? 1 : 0.5)
            .focusable(false)
            .onHover { hovering = $0 }
        }
    }
}

struct FloatingResultContainer: View {
    @ObservedObject var om = OM
    @ObservedObject var sm = SM
    @ObservedObject var dragManager = DM

    var isPreview = false
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showImages) var showImages
    @Default(.alwaysShowCompactResults) var alwaysShowCompactResults

    var shouldShowDropZone: Bool {
        !isPreview && dragManager.showDropZone
    }

    var body: some View {
        let optimisers = om.optimisers.filter(!\.hidden).sorted(by: \.startedAt, order: .reverse)
        VStack(alignment: floatingResultsCorner.isTrailing ? .trailing : .leading, spacing: 10) {
            if shouldShowDropZone, floatingResultsCorner.isTop {
                DropZoneView()
                    // .transition(
                    //     .asymmetric(insertion: .scale.animation(.fastSpring), removal: .identity)
                    // )
                    .padding(.bottom, 10)
            }

            if optimisers.isNotEmpty {
                let compact = (alwaysShowCompactResults && !isPreview) || optimisers.count > 5 || om.compactResults

                if compact {
                    CompactResultList(
                        optimisers: sm.selecting ? optimisers.filter { !$0.running && $0.url != nil } : optimisers,
                        progress: sm.selecting ? nil : om.progress,
                        doneCount: om.doneCount,
                        failedCount: om.failedCount,
                        visibleCount: om.visibleCount
                    )
                    .preview(isPreview)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 15)
                    .onAppear {
                        om.compactResults = true
                    }
                } else {
                    FloatingResultList(optimisers: optimisers).preview(isPreview)
                    UpdateButton().padding(floatingResultsCorner.isTrailing ? .trailing : .leading, 54)
                }

            }

            if shouldShowDropZone, !floatingResultsCorner.isTop {
                DropZoneView()
                    // .transition(
                    //     .asymmetric(insertion: .scale.animation(.fastSpring), removal: .identity)
                    // )
                    .padding(.bottom, 10)
            }
        }
        .onHover { hovering in
            if !hovering {
                hoveredOptimiserID = nil
            }
        }
        .padding(.vertical, om.compactResults ? 0 : (showImages ? 36 : 10))
        .padding(floatingResultsCorner.isTrailing ? .leading : .trailing, 20)
    }
}

var initializedFloatingWindow = false

@MainActor
struct FloatingPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let noThumb = Optimiser(id: "pages.pdf", type: .pdf)
        noThumb.url = "\(HOME)/Documents/pages.pdf".fileURL
        noThumb.finish(oldBytes: 12_250_190, newBytes: 5_211_932)

        let videoOpt = Optimiser(id: "Movies/meeting-recording-video.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "\(HOME)/Movies/meeting-recording-video.mov".fileURL
        videoOpt.operation = Defaults[.showImages] ? "Optimising" : "Optimising \(videoOpt.filename)"
        videoOpt.thumbnail = NSImage(resource: .sonomaVideo)
        videoOpt.changePlaybackSpeedFactor = 2.0

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

@MainActor
struct OnboardingFloatingPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(resource: .sonomaShot)
        clipEnd.isPreview = true
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        o.optimisers = [clipEnd]
        return o
    }()

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }
}

// @MainActor
// struct DraggableConvertedImage: View {
//    var format: UTType
//    var ext: String
//    var image: Image
//    var optimiser: Optimiser
//
//    @State private var rotation: Double = -2
//    @State private var offset: Double = -0.5
//    @State private var hovering: Bool = false
//
//    func preview(ext: String) -> some View {
//        ZStack {
//            SwiftUI.Image(nsImage: image.image)
//            Text(ext)
//                .mono(100, weight: .black)
//                .foregroundColor(.white)
//                .shadow(radius: 20)
//        }
//    }
//
//    var body: some View {
//        Text(ext.uppercased()).roundbg(radius: 4, verticalPadding: 1, horizontalPadding: 3, color: optimiser.type.utType == format ? .fg.warm : .bg.warm.opacity(0.7), noFG: true)
//            .foregroundColor(
//                optimiser.type.utType == format
//                    ? .bg.warm
//                    : .fg.warm
//            )
//            .rotationEffect(.degrees(rotation), anchor: .top)
//            .offset(x: offset * 1.5, y: offset * 0.7)
//            .onAppear {
//                withAnimation(.easeIn(duration: 0.15).repeatForever(autoreverses: true)) {
//                    rotation = 3
//                }
//                withAnimation(.easeOut(duration: 0.2).repeatForever(autoreverses: true).delay(0.1)) {
//                    offset = 0.5
//                }
//            }
//            .onHover { hovering in
//                if hovering {
//                    withAnimation(.jumpySpring) {
//                        self.hovering = true
//                    }
//                } else {
//                    self.hovering = false
//                }
//            }
//            .scaleEffect(hovering ? 1.2 : 1)
//            .if(format == .jpeg) { view in
//                view.draggable(ConvertedImageJPEG(image: image, optimiser: optimiser), preview: { preview(ext: ext) })
//            }
//            .if(format == .png) { view in
//                view.draggable(ConvertedImagePNG(image: image, optimiser: optimiser), preview: { preview(ext: ext) })
//            }
//            .if(format == .avif) { view in
//                view.draggable(ConvertedImageAVIF(image: image), preview: { preview(ext: ext) })
//            }
//            .if(format == .heic) { view in
//                view.draggable(ConvertedImageHEIC(image: image), preview: { preview(ext: ext) })
//            }
//            .if(format == .webP) { view in
//                view.draggable(ConvertedImageWEBP(image: image), preview: { preview(ext: ext) })
//            }
//            .if(format == .gif) { view in
//                view.draggable(ConvertedImageGIF(image: image, optimiser: optimiser), preview: { preview(ext: ext) })
//            }
//    }
// }

@MainActor struct FormatSelectorView: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        if !optimiser.running, optimiser.canChangeFormat() {
            HStack(spacing: 1) {
                ForEach(optimiser.type.convertibleTypes) { format in
                    if let ext = format.preferredFilenameExtension {
                        button(format: format, ext: ext)
                    }
                }
            }
            .font(.medium(8))
        }
    }

    func button(format: UTType, ext: String) -> some View {
        Button(ext.uppercased()) {
            guard !preview, optimiser.type.utType != format else { return }
            optimiser.convert(to: format, optimise: true)
        }
        .buttonStyle(PickerButton(
            color: .bg.warm.opacity(0.7),
            offColor: .bg.warm.opacity(0.9),
            offTextColor: .fg.primary,
            horizontalPadding: 3,
            verticalPadding: 1,
            radius: 4,
            hoverColor: .pinkMauve,
            enumValue: optimiser.type,
            onValue: ItemType.image(format)
        ))

    }
}

// MARK: - FloatingResult

struct FloatingResult: View {
    // color(display-p3 0.9983 0.818 0.3296)
    static let yellow = Color(.displayP3, red: 1, green: 0.768, blue: 0.4296, opacity: 1)
    // color(display-p3 0.0193 0.4224 0.646)
    static let darkBlue = Color(.displayP3, red: 0.0193, green: 0.4224, blue: 0.646, opacity: 1)
    // color(display-p3 0.037 0.6578 0.9928)
    static let lightBlue = Color(.displayP3, red: 0.037, green: 0.6578, blue: 0.9928, opacity: 1)
    // color(display-p3 1 0.015 0.3)
    static let red = Color(.displayP3, red: 1, green: 0.015, blue: 0.2, opacity: 1)

    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    @State var linear = false
    @State var hovering = false
    @State var hoveringThumbnail = false
    @State var editingFilename = false

    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.showImages) var showImages
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.neverShowProError) var neverShowProError

    @Environment(\.openWindow) var openWindow
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
            ResolutionField(optimiser: optimiser, size: oldSize)
                .buttonStyle(FlatButton(color: .black.opacity(0.1), textColor: .white, radius: 3, horizontalPadding: 3, verticalPadding: 1))
                .font(.round(10))
                .foregroundColor(optimiser.thumbnail != nil && showImages ? .lightGray : .secondary)
                .fixedSize()
                .disabled(!optimiser.canCrop())
        }
    }

    @ViewBuilder var fileSizeDiff: some View {
        let improvement = optimiser.newBytes > 0 && optimiser.newBytes < optimiser.oldBytes
        let improvementColor = (optimiser.thumbnail != nil && showImages ? FloatingResult.yellow : (colorScheme == .dark ? FloatingResult.lightBlue : FloatingResult.darkBlue))

        HStack {
            Text(optimiser.oldBytes.humanSize)
                .mono(13, weight: .semibold)
                .foregroundColor(improvement ? Color.red : improvementColor)
            if optimiser.newBytes > 0, optimiser.newBytes != optimiser.oldBytes {
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
        CloseStopButton(optimiser: optimiser)
            .buttonStyle(showsThumbnail ? FlatButton(color: .clear, textColor: .black, circle: true) : FlatButton(color: .inverted, textColor: .primary, circle: true))
            .background(
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow, state: .active, appearance: .vibrantLight)
                    .clipShape(Circle())
                    .shadow(radius: 2)
            )
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
                    if let url = (optimiser.url ?? optimiser.originalURL), url.isFileURL {
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
        .padding(.top, 10)
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
            ChangePlaybackSpeedButton(optimiser: optimiser)
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
            OverlayMessageView(optimiser: optimiser, color: .black)
        }
        .frame(
            width: THUMB_SIZE.width / 2,
            height: THUMB_SIZE.height / 2,
            alignment: .center
        )
        .fixedSize()
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
                .onDrag {
                    guard !preview else {
                        return NSItemProvider()
                    }

                    log.debug("Dragging \(url)")
                    if Defaults[.dismissFloatingResultOnDrop] {
                        optimiser.remove(after: 100, withAnimation: true)
                    }
                    return NSItemProvider(object: url as NSURL)
                }
        })
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)

    }

    func topField(_ url: URL) -> some View {
        ZStack {
            if let info = optimiser.info {
                Text(info)
                    .hfill(.leading)
                    .frame(height: 16)
                    .lineLimit(1)
                    .font(.medium(9))
                    .minimumScaleFactor(0.5)
                    .scaledToFit()
                    .foregroundColor(.primary)
                    .padding(.leading, 5)
                    .background(
                        VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow, state: .active)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    )
                    .frame(width: THUMB_SIZE.width / 2, height: 16, alignment: .leading)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .offset(y: hovering || SWIFTUI_PREVIEW ? 30 : 0)
                    .opacity(hovering || SWIFTUI_PREVIEW ? 0 : 1)
            }

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
                .fixedSize()
                .padding(.horizontal, 5)
                .offset(y: hovering || editingFilename || SWIFTUI_PREVIEW ? 0 : 30)
                .opacity(hovering || editingFilename || SWIFTUI_PREVIEW ? 1 : 0)
                .scaleEffect(
                    x: optimiser.editingFilename ? 1.2 : 1,
                    y: optimiser.editingFilename ? 1.2 : 1,
                    anchor: floatingResultsCorner.isTrailing ? .bottomTrailing : .bottomLeading
                )
        }
    }

    var body: some View {
        let hasThumbnail = optimiser.thumbnail != nil
        HStack {
            FlipGroup(if: !floatingResultsCorner.isTrailing) {
                if hasThumbnail, showImages {
                    VStack(alignment: floatingResultsCorner.isTrailing ? .leading : .trailing, spacing: 2) {
                        if let url = (optimiser.url ?? optimiser.originalURL), url.isFileURL {
                            topField(url)
                        }
                        Group {
                            thumbnailView
                                .contentShape(Rectangle())
                                .if(!optimiser.inRemoval) { view in
                                    view.contextMenu {
                                        RightClickMenuView(optimiser: optimiser)
                                    }
                                }
                            FormatSelectorView(optimiser: optimiser)
                                .frame(width: THUMB_SIZE.width / 2 + 10, height: 16, alignment: .center)
                        }
                        .onHover(perform: updateHover(_:))
                    }
                } else {
                    noThumbnailView
                        .contentShape(Rectangle())
                        .onHover(perform: updateHover(_:))
                        .if(!optimiser.inRemoval) { view in
                            view.contextMenu {
                                RightClickMenuView(optimiser: optimiser)
                            }
                        }
                }

                if hasThumbnail, hovering || optimiser.sharing {
                    SideButtons(optimiser: optimiser, size: showsThumbnail ? 24 : 18)
                        .frame(width: 30, alignment: .bottom)
                        .fixedSize()
                        .zIndex(100)
                } else {
                    SwiftUI.Image("clop")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30, alignment: .center)
                        .fixedSize()
                        .opacity(showFloatingHatIcon ? 1 : 0)
                }
            }
        }
//        .frame(minWidth: THUMB_SIZE.width / 2, idealWidth: THUMB_SIZE.width / 2, maxWidth: THUMB_SIZE.width, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
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
        if hovering, !preview {
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

@ViewBuilder
func FlipGroup(
    if value: Bool,
    @ViewBuilder _ content: @escaping () -> TupleView<(some View, some View, some View)>
) -> some View {
    let pair = content()
    if value {
        TupleView((pair.value.2, pair.value.1, pair.value.0))
    } else {
        TupleView((pair.value.0, pair.value.1, pair.value.2))
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
        o.isPreview = true
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
