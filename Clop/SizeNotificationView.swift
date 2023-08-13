//
//  SizeNotificationView.swift
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

struct SizeNotificationContainer: View {
    @ObservedObject var om = OM
    var isPreview = false
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showImages) var showImages

    var body: some View {
        VStack(spacing: 10) {
            ForEach(om.optimizers.filter(!\.hidden).sorted(by: \.startedAt, order: .reverse).prefix(9)) { optimizer in
                SizeNotificationView(optimizer: optimizer, isPreview: isPreview, linear: om.optimizers.count > 1)
            }
        }.onHover { hovering in
            if !hovering {
                hoveredOptimizerID = nil
            }
        }
        .padding(.vertical, showImages ? 36 : 10)
        .padding(floatingResultsCorner.isTrailing ? .leading : .trailing, 20)
    }
}

class ThumbDropDelegate: DropDelegate {
    func performDrop(info: DropInfo) -> Bool {
        print("performDrop", info)
        return true
    }

}

@MainActor
struct FloatingPreview: View {
    static var om: OptimizationManager = {
        let o = OptimizationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))
//        let thumbSizeAfter = THUMB_SIZE.applying(.init(scaleX: 2, y: 2))

        let videoOpt = Optimizer(id: "Movies/meeting-recording-video.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.operation = Defaults[.showImages] ? "Optimizing" : "Optimizing \(videoOpt.filename)"
        videoOpt.thumbnail = NSImage(named: "sonoma-video")
//        videoOpt.finish(error: "Optimized image is larger")
//        videoOpt.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize, newSize: thumbSizeAfter, remove: false)

        let clipEnd = Optimizer(id: Optimizer.IDs.clipboardImage, type: .image(.png))
        clipEnd.thumbnail = NSImage(named: "sonoma-shot")
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

//        let proOpt = OM.optimizer(id: Optimizer.IDs.pro, type: .unknown, operation: "")
//        proOpt.finish(error: "Free version limits reached", notice: "Only 2 file optimizations per session\nare included in the free version")

//        let url = "https://files.lunar.fyi/software-vs-hardware.png".url!
//        let urlOpt = Optimizer(id: url.absoluteString, type: .url, operation: "Fetching")
//        urlOpt.url = url

        o.optimizers = [
            //            urlOpt,
//            proOpt,
            videoOpt,
            clipEnd,
        ]
        return o
    }()

    static var videoProgress: Progress = {
        let p = Progress(totalUnitCount: 103_021_021)
//        p.kind = .file
        p.fileOperationKind = .optimizing
        p.completedUnitCount = 32_473_200
        p.localizedAdditionalDescription = "\(p.completedUnitCount.hmsString) of \(p.totalUnitCount.hmsString)"
        return p
    }()

    var body: some View {
        SizeNotificationContainer(om: Self.om, isPreview: true)
    }

}

// MARK: - SizeNotificationView

struct SizeNotificationView: View {
    @ObservedObject var optimizer: Optimizer
    var isPreview = false

    @State var linear = false
    @State var hovering = false
    @State var hoveringThumbnail = false

    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.showImages) var showImages
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.keyComboModifiers) var keyComboModifiers
    @Default(.neverShowProError) var neverShowProError

    var dropDelegate = ThumbDropDelegate()

    @Environment(\.openWindow) var openWindow

    var showsThumbnail: Bool {
        optimizer.thumbnail != nil && showImages
    }

    @ViewBuilder var progressURLView: some View {
        if optimizer.type.isURL, let url = optimizer.url {
            Text(url.absoluteString)
                .medium(10)
                .foregroundColor(.secondary.opacity(0.75))
                .lineLimit(1)
                .allowsTightening(true)
                .truncationMode(.middle)
        }
    }
    @ViewBuilder var progressView: some View {
        if optimizer.progress.isIndeterminate, !linear, optimizer.thumbnail == nil, optimizer.progress.kind != .file {
            HStack(spacing: 10) {
                Text(optimizer.operation).round(14, weight: .semibold)
                ProgressView(optimizer.progress).progressViewStyle(.circular)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if optimizer.progress.isIndeterminate {
                    Text(optimizer.operation)
                    progressURLView
                }
                ProgressView(optimizer.progress).progressViewStyle(.linear)
                if !optimizer.progress.isIndeterminate {
                    progressURLView.padding(.top, 5)
                }
            }
        }
    }
    @ViewBuilder var sizeDiff: some View {
        if let oldSize = optimizer.oldSize {
            HStack(spacing: 3) {
                Text("\(oldSize.width.i)×\(oldSize.height.i)")
                if let newSize = optimizer.newSize {
                    SwiftUI.Image(systemName: "arrow.right")
                    Text("\(newSize.width.i)×\(newSize.height.i)")
                }
            }
            .font(.round(10))
            .foregroundColor(optimizer.thumbnail != nil && showImages ? .lightGray : .secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    var fileSizeDiff: some View {
        HStack {
            Text(optimizer.oldBytes.humanSize)
                .mono(13, weight: .semibold)
                .foregroundColor(Color.red)
            if optimizer.newBytes >= 0 {
                SwiftUI.Image(systemName: "arrow.right")
                Text(optimizer.newBytes.humanSize)
                    .mono(13, weight: .semibold)
                    .foregroundColor(optimizer.newBytes < optimizer.oldBytes ? .blue : Color.red)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
    var closeStopButton: some View {
        Button(
            action: {
                if !isPreview {
                    hoveredOptimizerID = nil
                    optimizer.stop(animateRemoval: true)
                }
            },
            label: { SwiftUI.Image(systemName: optimizer.running ? "stop.fill" : "xmark").font(.heavy(9)) }
        )
        .help((optimizer.running ? "Stop" : "Close") + " (\(keyComboModifiers.str)⌫)")
        .buttonStyle(showsThumbnail ? FlatButton(color: .clear, textColor: .black, circle: true) : FlatButton(color: .inverted, textColor: .primary, circle: true))
        .background(
            VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow, state: .active, appearance: .vibrantLight)
                .clipShape(Circle())
                .shadow(radius: 2)
        )
    }
    @ViewBuilder var restoreOptimizeButton: some View {
        if optimizer.url != nil, !optimizer.running {
            if optimizer.isOriginal {
                Button(
                    action: { if !isPreview { optimizer.optimize(allowLarger: true) } },
                    label: { SwiftUI.Image(systemName: "goforward.plus").font(.heavy(9)) }
                )
                .help("Optimize")
            } else {
                Button(
                    action: { if !isPreview { optimizer.restoreOriginal() } },
                    label: { SwiftUI.Image(systemName: "arrow.uturn.left").font(.semibold(9)) }
                )
                .help("Restore original (\(keyComboModifiers.str)Z)")
            }
        }
    }
    var sideButtons: some View {
        VStack {
            Button(
                action: { if !isPreview { optimizer.downscale() }},
                label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) }
            ).help("Downscale (\(keyComboModifiers.str)-)")
            Button(
                action: { if !isPreview { optimizer.quicklook() }},
                label: { SwiftUI.Image(systemName: "eye").font(.heavy(9)) }
            ).help("QuickLook (\(keyComboModifiers.str)space)")
            restoreOptimizeButton
            if !optimizer.aggresive {
                Button(
                    action: {
                        guard !isPreview else { return }

                        if optimizer.running {
                            optimizer.stop(remove: false)
                            optimizer.url = optimizer.originalURL
                            optimizer.finish(oldBytes: optimizer.oldBytes ?! optimizer.path?.fileSize() ?? 0, newBytes: -1)
                        }

                        if optimizer.downscaleFactor < 1 {
                            optimizer.downscale(toFactor: optimizer.downscaleFactor, aggressiveOptimization: true)
                        } else {
                            optimizer.optimize(allowLarger: true, aggressiveOptimization: true, fromOriginal: true)
                        }
                    },
                    label: { SwiftUI.Image(systemName: "bolt").font(.heavy(9)) }
                ).help("Aggressive optimization (\(keyComboModifiers.str)A)")
            }
        }
        .buttonStyle(FlatButton(color: .white.opacity(0.9), textColor: .black.opacity(0.7), width: showsThumbnail ? 24 : 18, height: showsThumbnail ? 24 : 18, circle: true))
        .animation(.fastSpring, value: optimizer.aggresive)
    }

    @ViewBuilder var noThumbnailView: some View {
        ZStack(alignment: .topLeading) {
            if optimizer.running {
                progressView
                    .controlSize(.small)
                    .lineLimit(1)
            } else if optimizer.error != nil {
                errorView
            } else if optimizer.notice != nil {
                noticeView
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(optimizer.filename)
                            .scaledToFit()
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: 200, alignment: .leading)
                        Spacer(minLength: 20)
                        SwiftUI.Image(systemName: optimizer.type.isVideo ? "video" : "photo")
                    }
                    .font(.semibold(14)).lineLimit(1).fixedSize().opacity(0.8)
                    .padding(.bottom, 4)

                    fileSizeDiff
                    sizeDiff
                }
            }

            closeStopButton.offset(x: -22, y: -16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            VisualEffectBlur(material: optimizer.error == nil ? .sidebar : .hudWindow, blendingMode: .withinWindow, state: .active)
                .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3).any
                .overlay(optimizer.error == nil ? .clear : .red.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
    @ViewBuilder var errorView: some View {
        let thumb = showsThumbnail
        let proError = optimizer.id == Optimizer.IDs.pro
        if let error = optimizer.error {
            VStack(alignment: proError ? .center : .leading) {
                if proError {
                    Button("Get Clop Pro") {
                        settingsViewManager.tab = .about
                        openWindow(id: "settings")

                        PRO?.manageLicence()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(FlatButton(color: .inverted, textColor: .mauvish))
                    .font(.round(20, weight: .black))
                    .hfill()
                } else {
                    Text("error")
                        .round(28, weight: .black)
                        .foregroundColor(.black.opacity(0.3))
                        .offset(x: 8, y: -10)
                        .hfill(.trailing)
                }
                Text(error)
                    .medium(14)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .scaledToFit()
                    .minimumScaleFactor(0.75)
                if let notice = optimizer.notice {
                    Text(notice)
                        .round(10)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .scaledToFit()
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(proError ? .center : .leading)
                }

                if proError {
                    Button("Never show this again") {
                        neverShowProError = true
                        hoveredOptimizerID = nil
                        optimizer.remove(after: 200, withAnimation: true)
                    }
                    .buttonStyle(FlatButton(color: .dynamicGray, textColor: .invertedGray))
                    .font(.round(12, weight: .regular))
                    .hfill()
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, thumb ? 4 : 0)
            .allowsTightening(true)
            .frame(maxWidth: thumb ? THUMB_SIZE.width : 250, alignment: .leading)
            .fixedSize(horizontal: !thumb, vertical: false)
        }
    }
    @ViewBuilder var noticeView: some View {
        if let notice = optimizer.notice {
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
    @ViewBuilder var thumbnailView: some View {
        VStack {
            HStack {
                closeStopButton
                Spacer()
                SwiftUI.Image(systemName: optimizer.type.isVideo ? "video.fill" : "photo.fill")
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
            }.hfill(.leading)
            Spacer()

            if optimizer.running {
                progressView
                    .controlSize(.small)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            } else if optimizer.error != nil {
                errorView
            } else if optimizer.notice != nil {
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
        .frame(
            width: THUMB_SIZE.width / 2,
            height: THUMB_SIZE.height / 2,
            alignment: .center
        )
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(
            SwiftUI.Image(nsImage: optimizer.thumbnail!)
                .resizable()
                .scaledToFill()
                .overlay(LinearGradient(colors: [.clear, optimizer.error == nil ? .blackMauve : .red], startPoint: .top, endPoint: .bottom))
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
        .ifLet(optimizer.url, transform: { view, url in
            view
                .draggable(url)
                .onDrop(of: [.fileURL, .url, .image, .video], delegate: dropDelegate)
        })
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
    }

    var body: some View {
        let hasThumbnail = optimizer.thumbnail != nil
        HStack {
            FlipGroup(if: !floatingResultsCorner.isTrailing) {
                if hasThumbnail, showImages {
                    thumbnailView
                        .contentShape(Rectangle())
                        .onHover(perform: updateHover(_:))
                } else {
                    noThumbnailView
                        .contentShape(Rectangle())
                        .onHover(perform: updateHover(_:))
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
        .opacity(optimizer.inRemoval ? 0 : 1)
        .offset(x: optimizer.inRemoval ? (floatingResultsCorner.isTrailing ? 500 : -500) : 0)
        .animation(.easeOut(duration: 0.5), value: optimizer.inRemoval)
    }

    func updateHover(_ hovering: Bool) {
        if hovering {
            hoveredOptimizerID = optimizer.id
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

struct SizeNotificationContainer_Previews: PreviewProvider {
    static var previews: some View {
        FloatingPreview()
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))

    }
}

// MARK: - SizeNotificationView_Previews

struct SizeNotificationView_Previews: PreviewProvider {
    static var videoProgress: Progress {
        let p = Progress(totalUnitCount: 100_000)
        p.kind = .file
        p.fileOperationKind = .optimizing
        p.fileURL = URL(filePath: "~/Desktop/Screen Recording 2023-07-09 at 15.32.07.mov")
        p.completedUnitCount = 30000
        return p
    }

    static var previews: some View {
        SizeNotificationView(optimizer: Optimizer(id: Optimizer.IDs.clipboardImage, type: .image(.png)))
            .padding()
            .background(LinearGradient(colors: [Color.red, Color.orange, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("Optimizing Clipboard")
        SizeNotificationView(optimizer: Optimizer(
            id: Optimizer.IDs.clipboardImage,
            type: .image(.png),
            running: false,
            oldBytes: 750_190,
            newBytes: 211_932,
            oldSize: CGSize(width: 1920, height: 1080),
            newSize: CGSize(width: 1280, height: 720)
        ))
        .padding()
        .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
        .previewDisplayName("Finished Clipboard Optimization")

        SizeNotificationView(optimizer: Optimizer(id: "~/Desktop/Screen Recording 2023-07-09 at 15.32.07.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress))
            .padding()
            .background(LinearGradient(colors: [.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("Optimizing Video")
    }
}
