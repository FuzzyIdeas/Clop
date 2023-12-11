//
//  FloatingResult.swift
//  Clop
//
//  Created by Alin Panaitiu on 26.07.2022.
//

import Defaults
import Lowtech
import SwiftUI
#if !SETAPP
    import LowtechIndie
    import LowtechPro
#endif

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

    var body: some View {
        ForEach(optimisers) { optimiser in
            FloatingResult(optimiser: optimiser, linear: optimisers.count > 1)
                .gesture(TapGesture(count: 2).onEnded {
                    if let url = optimiser.url {
                        NSWorkspace.shared.open(url)
                    }
                })
        }
    }
}

#if !SETAPP
    struct UpdateButton: View {
        var short = false
        @ObservedObject var um: UpdateManager = UM
        @State var hovering = false

        var body: some View {
            if let updateVersion = um.newVersion {
                Button(short ? "v\(updateVersion) available" : "v\(updateVersion) update available") {
                    checkForUpdates()
                }
                .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .mauvish, radius: 7, verticalPadding: 2))
                .font(.medium(11))
                .opacity(hovering ? 1 : 0.5)
                .focusable(false)
                .onHover { hovering = $0 }
            }
        }
    }
#endif

struct FloatingResultContainer: View {
    @ObservedObject var om = OM
    @ObservedObject var sm = SM
    @ObservedObject var dragManager = DM
    var isPreview = false
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showImages) var showImages
    @Default(.alwaysShowCompactResults) var alwaysShowCompactResults
    @Default(.onlyShowDropZoneOnOption) var onlyShowDropZoneOnOption

    var shouldShowDropZone: Bool {
        !isPreview && dragManager.showDropZone
    }

    var body: some View {
        let optimisers = om.optimisers.filter(!\.hidden).sorted(by: \.startedAt, order: .reverse)
        VStack(alignment: floatingResultsCorner.isTrailing ? .trailing : .leading, spacing: 10) {
            if shouldShowDropZone, floatingResultsCorner.isTop {
                DropZoneView()
                    .transition(
                        .asymmetric(insertion: .scale.animation(.fastSpring), removal: .identity)
                    )
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
                    ).preview(isPreview)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 15)
                        .onAppear {
                            om.compactResults = true
                        }
                } else {
                    FloatingResultList(optimisers: optimisers).preview(isPreview)
                    #if !SETAPP
                        UpdateButton().padding(floatingResultsCorner.isTrailing ? .trailing : .leading, 54)
                    #endif
                }

            }

            if shouldShowDropZone, !floatingResultsCorner.isTop {
                DropZoneView()
                    .transition(
                        .asymmetric(insertion: .scale.animation(.fastSpring), removal: .identity)
                    )
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

@MainActor
struct OnboardingFloatingPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(resource: .sonomaShot)
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        o.optimisers = [clipEnd]
        return o
    }()

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
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
                #if !SETAPP
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
                #endif
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

    var body: some View {
        let hasThumbnail = optimiser.thumbnail != nil
        HStack {
            FlipGroup(if: !floatingResultsCorner.isTrailing) {
                if hasThumbnail, showImages {
                    VStack(alignment: floatingResultsCorner.isTrailing ? .leading : .trailing, spacing: 2) {
                        if let url = (optimiser.url ?? optimiser.originalURL), url.isFileURL {
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
                        thumbnailView
                            .contentShape(Rectangle())
                            .onHover(perform: updateHover(_:))
                            .if(!optimiser.inRemoval) { view in
                                view.contextMenu {
                                    RightClickMenuView(optimiser: optimiser)
                                }
                            }
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
