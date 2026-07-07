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
import os
import SwiftUI
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "FloatingResult")

let FLOAT_MARGIN: CGFloat = 4

private struct PreviewKey: EnvironmentKey {
    static let defaultValue = false
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

    @ViewBuilder func sideButtonBackground(preview: Bool = false) -> some View {
        let shape = Capsule()
        if preview {
            background(Color.white, in: shape)
                .overlay(shape.strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        } else if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        } else {
            background(.ultraThickMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
    }

    @ViewBuilder func noThumbBackground(isError: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if isError {
            if #available(macOS 26.0, *) {
                background(.red.opacity(0.5), in: shape)
                    .glassEffect(.regular, in: shape)
            } else {
                background(.red.opacity(0.5), in: shape)
                    .background(.thinMaterial, in: shape)
            }
        } else {
            // Semi-opaque backing so the panel reads against the desktop instead of being see-through
            // (bare .glassEffect on macOS 26 has no fill of its own).
            if #available(macOS 26.0, *) {
                background(Color.bg.primary.opacity(0.75), in: shape)
                    .glassEffect(.regular, in: shape)
            } else {
                background(Color.bg.primary.opacity(0.75), in: shape)
                    .background(.thinMaterial, in: shape)
            }
        }
    }
}

/// Drop animation when a result is removed: the gap closing and the results above falling in. Uses
/// SwiftUI's `.snappy` spring where available (macOS 14+), with a close equivalent on macOS 13.
var resultFallAnimation: Animation {
    if #available(macOS 14.0, *) {
        return .snappy(duration: 0.2, extraBounce: 0.1)
    }
    return .spring(response: 0.2, dampingFraction: 0.75)
}

private struct FloatingListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct FloatingResultList: View {
    var optimisers: [Optimiser]

    @State var copiedText = "Copy all"
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showCopyClearButtons) var showCopyClearButtons

    @Environment(\.preview) var preview

    var dragAllButton: some View {
        SwiftUI.Image(systemName: "line.3.horizontal")
            .font(.medium(11))
            .frame(height: 18)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.inverted.opacity(0.9)))
            .foregroundColor(.primary)
            // A real multi-item AppKit drag so the drop lands EVERY file. SwiftUI's `.onDrag` returns one
            // provider == one item, which is why "drag all" used to drop a single file. See onDragAllFiles.
            .onDragAllFiles(help: "Drag all") { preview ? [] : optimisers }
    }

    var copyAllButton: some View {
        Button(copiedText) {
            guard !preview else { return }
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
            guard !preview else { return }
            // Explicit user action: drop the hover state and force removal so it fires immediately even
            // while the cursor is over the list (the hover deferral is only meant for auto-hide timers).
            hoveredOptimiserID = nil
            for optimiser in optimisers {
                optimiser.remove(after: 100, withAnimation: true, force: true)
            }
        }
        .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .primary, radius: 7, verticalPadding: 2))
        .font(.medium(11))
        .focusable(false)
    }

    var body: some View {
        // Fixed-geometry overlay cards no longer grow on hover, so the list spacing is constant
        // (the old hover-driven 4↔10 shuffle is gone). The copy/clear row gets a little breathing
        // room above it and sits close to the cards' edge so it lines up with the result rects.
        VStack(alignment: floatingResultsCorner.isTrailing ? .trailing : .leading, spacing: 4) {
            ForEach(Array(optimisers.enumerated()), id: \.element.id) { index, optimiser in
                FloatingResult(optimiser: optimiser, linear: optimisers.count > 1)
                    .zIndex(Double(optimisers.count - index))
                    .gesture(TapGesture(count: 2).onEnded {
                        if let url = optimiser.url {
                            NSWorkspace.shared.open(url)
                        }
                    })
            }
            if showCopyClearButtons, optimisers.isNotEmpty {
                HStack {
                    dragAllButton
                    copyAllButton
                    clearAllButton
                }
                .padding(.top, 6)
                .padding(floatingResultsCorner.isTrailing ? .trailing : .leading, 16)
                .padding(.bottom, preview ? 0 : 30)
                // Every card carries a zIndex >= 1 (for the piled look), so without this the row sits
                // underneath them and the card just above steals the drag-handle's clicks/drags.
                .zIndex(Double(optimisers.count + 1))
                // Keep the row's footprint with a single result so the layout doesn't shift going 2->1;
                // just hide it and let clicks fall through (it only does anything with more than one result).
                .opacity(optimisers.count > 1 ? 1 : 0)
                .allowsHitTesting(optimisers.count > 1)
            }
        }
        // While a result is being removed, pin the stack to its pre-removal height (anchored to the active
        // corner) so the window doesn't shrink mid-drop: the results below the removed one stay put like a
        // brick wall while those above fall into the freed slot. The empty space opens at the far (invisible)
        // edge and is reclaimed a moment after the drop settles.
        .frame(height: heldHeight, alignment: floatingResultsCorner.isTop ? .top : .bottom)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: FloatingListHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(FloatingListHeightKey.self) { h in
            if heldHeight == nil, h > 0 { naturalHeight = h }
        }
        .onChange(of: optimisers.count) { newCount in
            if newCount < lastCount, newCount > 0, naturalHeight > 0 {
                heldHeight = naturalHeight
                releaseWork?.cancel()
                let work = DispatchWorkItem { heldHeight = nil }
                releaseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
            lastCount = newCount
        }
        .onAppear { lastCount = optimisers.count }
    }

    // Measured natural height of the stack, and the height it's pinned to while a result is being removed.
    // Holding the pre-removal height (bottom-anchored) keeps the window from shrinking mid-drop, so the
    // results below the removed one stay put like a brick wall while those above fall into the freed slot.
    @State private var naturalHeight: CGFloat = 0
    @State private var heldHeight: CGFloat? = nil
    @State private var lastCount = 0
    @State private var releaseWork: DispatchWorkItem? = nil

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
    @Default(.enableFloatingResults) var enableFloatingResults
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.alwaysShowCompactResults) var alwaysShowCompactResults

    var shouldShowDropZone: Bool {
        !isPreview && dragManager.showDropZone && !dragManager.dropZoneAtCursor
    }

    var body: some View {
        // The settings preview keeps its authored order (so we can lay the sample results out
        // deliberately); real results sort newest-first.
        let optimisers = isPreview
            ? om.optimisers.filter(!\.hidden)
            : (enableFloatingResults ? om.optimisers.filter(!\.hidden).sorted(by: \.startedAt, order: .reverse) : [])
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
                        // Keep every row visible while selecting (running rows just aren't selectable),
                        // so starting a selection no longer reshuffles the list out from under the cursor.
                        optimisers: optimisers,
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
        .padding(.vertical, om.compactResults ? 0 : (isPreview ? 6 : 36))
        .padding(floatingResultsCorner.isTrailing ? .leading : .trailing, 20)
    }
}

var initializedFloatingWindow = false

/// Generic audio-file icon used as a stand-in for album art in the settings live previews.
var audioPreviewThumbnail: NSImage {
    let icon = NSWorkspace.shared.icon(for: .mp3)
    icon.size = THUMB_SIZE
    return icon
}

/// Folder under the system temp dir where preview sample files live. It's deliberately throwaway:
/// the files are re-materialised from bundled assets on every launch, so if a curious user does
/// "Show in Finder" and deletes them, nothing breaks. Preview optimisers are also gated against
/// every file-mutating action, so these stay strictly read-only demo files.
var previewSamplesDir: FilePath {
    FilePath.dir(FilePath(NSTemporaryDirectory()) / "com.lowtechguys.Clop" / "preview-samples", permissions: 0o755)
}

/// Materialise a bundled preview sample (a `.dataset` in the asset catalog) to a temp file, so the
/// settings-preview cards can be double-clicked to open the real file.
func previewSampleURL(dataAsset: String, named: String) -> URL? {
    guard let asset = NSDataAsset(name: dataAsset) else { return nil }
    let path = previewSamplesDir.appending(named)
    fm.createFile(atPath: path.string, contents: asset.data)
    return path.url
}

@MainActor
struct FloatingPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let pdfOpt = Optimiser(id: "Low-Tech Whistle.pdf", type: .pdf)
        pdfOpt.thumbnail = NSImage(resource: .previewPdfThumb)
        pdfOpt.finish(oldBytes: 12_250_190, newBytes: 5_211_932)

        let audioOpt = Optimiser(id: "Evening guitar.m4a", type: .audio(.mpeg4Audio))
        audioOpt.thumbnail = NSImage(resource: .guitarCover)
        audioOpt.coverArtSize = CGSize(width: 1012, height: 1012)
        audioOpt.finish(oldBytes: 2_834_000, newBytes: 1_027_608, oldBitrate: 256, newBitrate: 96)

        let videoOpt = Optimiser(id: "copy-optimise-paste.mp4", type: .video(.mpeg4Movie))
        videoOpt.thumbnail = NSImage(resource: .previewVideoThumb)
        videoOpt.finish(oldBytes: 4_512_000, newBytes: 1_204_233, oldSize: CGSize(width: 1920, height: 1080), newSize: CGSize(width: 1280, height: 720))

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.webP))
        clipEnd.thumbnail = NSImage(resource: .previewImageThumb)
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        // Record which bundled sample backs each card. The temp files are only written when the
        // Floating Results settings tab is actually shown (materializeSamples), to avoid I/O on launch.
        FloatingPreview.sampleSpecs = [
            (clipEnd, "preview-sample-image", "downscale-images.webp"),
            (videoOpt, "preview-sample-video", "copy-optimise-paste.mp4"),
            (pdfOpt, "preview-sample-pdf", "Low-Tech Whistle.pdf"),
            (audioOpt, "preview-sample-audio", "Evening guitar.m4a"),
        ]

        // Authored order is the display order in the settings preview (it isn't sorted): pdf and
        // audio up top, image and video at the bottom near the clear-all buttons.
        o.optimisers = [
            pdfOpt,
            audioOpt,
            clipEnd,
            videoOpt,
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

    /// (card optimiser, bundled data-set name, display filename) for each openable preview card.
    static var sampleSpecs: [(opt: Optimiser, asset: String, name: String)] = []
    static var samplesMaterialized = false

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }

    /// Write the bundled preview samples to the temp folder and point the cards at them. Called only
    /// when the Floating Results settings tab appears, so we don't do this I/O on launch.
    static func materializeSamples() {
        _ = om // ensure the (cheap, in-memory) setup ran and populated sampleSpecs
        guard !samplesMaterialized else { return }
        samplesMaterialized = true
        for spec in sampleSpecs {
            if let url = previewSampleURL(dataAsset: spec.asset, named: spec.name) {
                spec.opt.url = url
            }
        }
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
        if let folderURL = optimiser.outputFolderURL, !optimiser.running {
            Button {
                NSWorkspace.shared.open(folderURL)
            } label: {
                HStack(spacing: 3) {
                    SwiftUI.Image(systemName: "folder")
                    Text("Open folder with pages")
                }
                .font(.medium(8))
            }
            .buttonStyle(PickerButton(
                color: .bg.warm.opacity(0.7),
                offColor: .bg.warm.opacity(0.9),
                offTextColor: .fg.primary,
                horizontalPadding: 3,
                verticalPadding: 1,
                radius: 4,
                hoverColor: .pinkMauve,
                enumValue: true,
                onValue: true
            ))
            .contentShape(Rectangle())
        } else if !optimiser.running, optimiser.canChangeFormat() {
            HStack(spacing: 1) {
                ForEach(optimiser.convertibleTypes) { format in
                    let ext = format.preferredFilenameExtension ?? format.identifier.components(separatedBy: ".").last ?? ""
                    if !ext.isEmpty {
                        button(format: format, ext: ext)
                    }
                }
            }
            .font(.medium(8))
        }
    }

    func button(format: UTType, ext: String) -> some View {
        let label: String = if format == .hevcVideo {
            "HEVC"
        } else if format == .av1Video {
            "AV1"
        } else {
            ext.uppercased()
        }
        let onValue: ItemType = switch optimiser.type {
        case .audio: .audio(format)
        case .video: .video(format)
        // Animated GIFs offer video conversion targets while still typed .image(.gif).
        default: optimiser.isAnimatedGIF ? .video(format) : .image(format)
        }
        return Button(label) {
            guard !preview, optimiser.type.utType != format, optimiser.videoCodecType != format else { return }
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
            onValue: onValue
        ))
    }
}

// MARK: - NameFormatPill

/// Compact in-thumbnail filename + format control. `name.ext` rendered as two tappable chips side by
/// side: the name (tap to edit inline) and the extension (hover to spring up a one-click convert
/// accordion). Each chip is a bordered
/// accent pill (translucent accent fill, more opaque accent border, white text) that intensifies on
/// hover, so both read as clickable at a glance over the dark result backdrop. While editing it becomes
/// a full-width text field with a solid backing for legibility. Purpose-built for the small overlay card
/// (the old FileNameField was sized for the full-width top slot and didn't populate/focus correctly here).
struct NameFormatPill: View {
    @ObservedObject var optimiser: Optimiser
    var fullWidth = false

    @Environment(\.preview) var preview
    @ObservedObject var km = KM

    var body: some View {
        Group {
            if optimiser.editingFilename {
                editor.frame(maxWidth: fullWidth ? .infinity : 150)
            } else {
                segments
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 18)
        // Only the inline editor gets a solid warm backing so the text field stays legible over the
        // thumbnail; at rest the two faint-accent chips carry their own fill, with no warm pill behind.
        .background {
            if optimiser.editingFilename {
                Capsule().fill(.regularMaterial)
                Capsule().fill(Color.bg.warm.opacity(0.92))
                Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .onChange(of: optimiser.running) { running in if running { optimiser.editingFilename = false; optimiser.showingFormats = false } }
        .onDisappear { optimiser.showingFormats = false }
    }

    var segments: some View {
        HStack(spacing: 4) {
            Text(stem.isEmpty ? "filename" : stem)
                .font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(.middle)
                // Shrink the text a little more while hovering the name so more of a long filename
                // shows, but not so much it stops being readable.
                .minimumScaleFactor(optimiser.hoveringFilename ? 0.75 : 0.9)
                .multilineTextAlignment(.trailing)
                // Fixed height so the hover scale factor only changes width-fitting, never the chip height.
                .frame(maxWidth: fullWidth ? .infinity : 92, alignment: .trailing)
                .frame(height: 12)
                .padding(.horizontal, 6).padding(.vertical, 2)
                // Mono warm chip so the name reads as tappable at a glance; border firms up on hover.
                .cardChip(hovering: optimiser.hoveringFilename)
                .onHover { inside in
                    optimiser.hoveringFilename = inside
                    if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
                }
                .onTapGesture { startEditing() }
            if !ext.isEmpty {
                formatSegment
            }
        }
    }

    @ViewBuilder var formatSegment: some View {
        if !optimiser.running, optimiser.canChangeFormat() {
            // Hovering the extension chip springs the convert targets up from behind it; one click on a
            // target converts. The accordion sits in an overlay so it doesn't affect the pill's layout,
            // and rises into the card interior (over the thumbnail) rather than past the clipped edge.
            Text(optimiser.formatChipText).font(.system(size: 9, weight: .bold))
                .frame(height: 12)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .cardChip(hovering: hoveringExt || optimiser.showingFormats)
                .onHover { hovering in
                    hoveringExt = hovering
                    updateFormatsVisibility()
                }
                .overlay(alignment: .bottomTrailing) { formatAccordion }
        } else {
            Text(optimiser.formatChipText).font(.system(size: 9, weight: .semibold)).foregroundColor(.white).padding(.leading, 1).padding(.trailing, 4)
        }
    }

    @ViewBuilder var formatAccordion: some View {
        let formats = targetFormats
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(Array(formats.enumerated()), id: \.offset) { idx, item in
                Button { convert(to: item.type) } label: {
                    Text((additiveConvert ? "+" : "") + item.ext.uppercased())
                        .font(.mono(9, weight: .bold))
                        .frame(height: 12)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .cardChip(hovering: hoveredFormatIdx == idx)
                }
                .buttonStyle(.plain)
                .onHover { hovering in hoveredFormatIdx = hovering ? idx : (hoveredFormatIdx == idx ? nil : hoveredFormatIdx) }
                // Springy emerge from behind the chip: the lowest target rises first, the rest follow.
                .opacity(optimiser.showingFormats ? 1 : 0)
                .scaleEffect(optimiser.showingFormats ? 1 : 0.6, anchor: .bottom)
                .offset(y: optimiser.showingFormats ? 0 : CGFloat(formats.count - idx) * 6)
                .animation(.spring(response: 0.16, dampingFraction: 0.66).delay(Double(formats.count - 1 - idx) * 0.018), value: optimiser.showingFormats)
                // Hover pop (centred, so it composes with the emerge scale above).
                .scaleEffect(hoveredFormatIdx == idx ? 1.12 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hoveredFormatIdx)
            }
        }
        // Bottom padding sits over the chip so moving the cursor from chip to list stays continuous;
        // when closed the overlay is non-interactive so the chip's own hover/taps work normally.
        .padding(.bottom, 22)
        .fixedSize()
        .onHover { hovering in
            hoveringList = hovering
            updateFormatsVisibility()
        }
        // Outermost so it gates the .onHover too: when closed, the (upward) accordion frame is fully
        // transparent to hover/clicks and never blocks elements rendered above the extension chip.
        .allowsHitTesting(optimiser.showingFormats)
    }

    var editor: some View {
        HStack(spacing: 4) {
            TextField("", text: $tempName)
                .textFieldStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.primary)
                .focused($focused)
                .onSubmit {
                    optimiser.rename(to: tempName)
                    optimiser.editingFilename = false
                }
            Button(action: { optimiser.editingFilename = false }, label: {
                SwiftUI.Image(systemName: "xmark").font(.bold(8)).foregroundColor(.secondary)
            })
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .onAppear {
            tempName = stem
            floatingResultsWindow.allowToBecomeKey = true
            floatingResultsWindow.makeKeyAndOrderFront(nil)
            floatingResultsWindow.orderFrontRegardless()
            focused = true
        }
    }

    func startEditing() {
        guard !preview, !SM.selecting else { return }
        tempName = stem
        optimiser.showingFormats = false
        withAnimation(.easeOut(duration: 0.1)) { optimiser.editingFilename = true }
    }

    @FocusState private var focused: Bool
    @State private var tempName = ""
    @State private var hoveringExt = false
    @State private var hoveringList = false
    @State private var hoveredFormatIdx: Int? = nil

    /// True while Option is held: a plain click on a format replaces the current one (keep-only-last),
    /// Option+click keeps both. The accordion pills show a "+" while this is true.
    private var additiveConvert: Bool {
        km.lalt || km.ralt
    }

    /// Convert targets shown in the accordion: every convertible type except the current one.
    private var targetFormats: [(type: UTType, ext: String)] {
        optimiser.convertibleTypes.compactMap { format in
            guard optimiser.type.utType != format, optimiser.videoCodecType != format else { return nil }
            let e = format.preferredFilenameExtension ?? format.identifier.components(separatedBy: ".").last ?? ""
            return e.isEmpty ? nil : (format, e)
        }
    }

    private var stem: String {
        optimiser.url?.filePath?.stem ?? optimiser.originalURL?.filePath?.stem ?? ""
    }
    private var ext: String {
        optimiser.url?.filePath?.extension ?? optimiser.originalURL?.filePath?.extension ?? ""
    }

    private func convert(to format: UTType) {
        optimiser.showingFormats = false
        guard !preview, optimiser.type.utType != format else { return }
        optimiser.convert(to: format, optimise: true, additive: additiveConvert)
    }

    private func updateFormatsVisibility() {
        // While the share picker is open, never spring the format accordion: showing formats hides the
        // action grid, which unmounts the share button the picker popover is anchored to and dismisses
        // the popover. The cursor often crosses the extension chip on its way to the popover, so this
        // path is hit precisely when the user is reaching for the share menu.
        if optimiser.sharing {
            optimiser.showingFormats = false
            return
        }
        if hoveringExt || hoveringList {
            optimiser.showingFormats = true
        } else {
            // Grace period so crossing the small gap between the chip and the list doesn't close it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard !hoveringExt, !hoveringList else { return }
                optimiser.showingFormats = false
                hoveredFormatIdx = nil
            }
        }
    }

}

// MARK: - FloatingResult

struct FloatingResult: View {
    /// color(display-p3 0.9983 0.818 0.3296)
    static let yellow = Color(.displayP3, red: 1, green: 0.768, blue: 0.4296, opacity: 1)
    /// color(display-p3 0.0193 0.4224 0.646)
    static let darkBlue = Color(.displayP3, red: 0.0193, green: 0.4224, blue: 0.646, opacity: 1)
    /// color(display-p3 0.037 0.6578 0.9928)
    static let lightBlue = Color(.displayP3, red: 0.037, green: 0.6578, blue: 0.9928, opacity: 1)
    /// color(display-p3 1 0.015 0.3)
    static let red = Color(.displayP3, red: 1, green: 0.015, blue: 0.2, opacity: 1)

    // MARK: - Overlay-grid thumbnail card

    //
    // Fixed-geometry card: the thumbnail is the background, all controls are layered over it and
    // revealed by opacity on hover. Geometry never changes on hover (only a cheap dim + control
    // opacity), so the Liquid Glass controls never trigger an expensive re-resolve.

    static let cardW: CGFloat = 196
    static let cardH: CGFloat = 148

    @ObservedObject var optimiser: Optimiser
    @ObservedObject var om = OM
    @Environment(\.preview) var preview

    @State var linear = false
    @State var hovering = false
    @State var hoveringThumbnail = false
    @State var editingFilename = false

    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.neverShowProError) var neverShowProError
    @Default(.floatingResultActions) var floatingResultActions

    @Environment(\.openWindow) var openWindow
    @Environment(\.colorScheme) var colorScheme

    var isExpanded: Bool {
        // While results are dropping after a removal, keep the overlay collapsed so a card sliding under the
        // cursor doesn't reveal its controls mid-fall. It re-evaluates the instant the drop settles.
        // While the share picker is open keep the overlay expanded regardless of hover: the picker popover is
        // anchored to the share button's view, so collapsing the grid (and unmounting that view) when the
        // cursor leaves the card to reach the popover would dismiss the popover along with its anchor.
        !om.animatingRemoval && ((hovering && !optimiser.collapseHoverOverlay) || optimiser.editingResolution || optimiser.sharing)
    }

    var showsThumbnail: Bool {
        optimiser.thumbnail != nil
    }

    /// Configured grid actions (crop is a dedicated corner button, so it's excluded here). When a
    /// configured action is hidden for this file type (e.g. downscale on audio), backfill a Show in
    /// Finder button so the grid keeps a useful action instead of an empty slot.
    var gridConfigured: [FloatingAction] {
        let shown = floatingResultActions.filter(gridApplies)
        let configuredCount = floatingResultActions.filter { $0 != .crop }.count
        if shown.count < configuredCount, !shown.contains(.showInFinder) {
            return shown + [.showInFinder]
        }
        return shown
    }

    /// Always six slots: configured actions first, remaining slots are faint "+" add-placeholders.
    var gridSlots: [FloatingAction?] {
        var slots: [FloatingAction?] = Array(gridConfigured.prefix(6)).map { Optional($0) }
        while slots.count < 6 {
            slots.append(nil)
        }
        return slots
    }

    var addableActions: [FloatingAction] {
        FloatingAction.allCases.filter { gridApplies($0) && !gridConfigured.contains($0) }
    }

    /// Bottom-anchored content: hidden while a slider is up; progress / error / notice while busy;
    /// the unified name·format pill on hover; a full-width filename editor while editing; the
    /// centered size-saving stats at rest.
    /// Whether the filename renders fully at the pill's resting width, so hovering it shouldn't expand
    /// the pill (and the crop button can stay put). Mirrors NameFormatPill's 9pt name segment / 92pt cap.
    var filenameFits: Bool {
        let stem = optimiser.url?.filePath?.stem ?? optimiser.originalURL?.filePath?.stem ?? ""
        let width = (stem as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width
        return width <= 92
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
                .foregroundColor(optimiser.thumbnail != nil ? .lightGray : .secondary)
                .fixedSize()
                .disabled(!optimiser.canCrop())
        }
    }

    @ViewBuilder var bitrateDiff: some View {
        if optimiser.type.isAudio, let oldBitrate = optimiser.oldBitrate, oldBitrate > 0 {
            HStack(spacing: 3) {
                let hideOldBitrate = OM.compactResults && (optimiser.newBitrate ?? 0) > 0 && optimiser.newBitrate! != oldBitrate
                if !hideOldBitrate {
                    Text("\(oldBitrate) kbps")
                }
                if let newBitrate = optimiser.newBitrate, newBitrate > 0, newBitrate != oldBitrate {
                    if !hideOldBitrate {
                        SwiftUI.Image(systemName: "arrow.right")
                    }
                    Text("\(newBitrate) kbps")
                }
            }
            .lineLimit(1)
            .font(.round(10))
            .foregroundColor(optimiser.thumbnail != nil ? .lightGray : .secondary)
            .fixedSize()
        }
    }

    @ViewBuilder var coverArtDiff: some View {
        if optimiser.type.isAudio, let base = optimiser.coverArtSize, base.width > 0, base.height > 0 {
            let factor = optimiser.coverDownscaleFactor
            let scaled = factor < 0.999
            HStack(spacing: 3) {
                SwiftUI.Image(systemName: "photo").font(.system(size: 8))
                Text("\(Int(base.width.rounded()))×\(Int(base.height.rounded()))")
                if scaled {
                    SwiftUI.Image(systemName: "arrow.right")
                    Text("\(Int((base.width * factor).rounded()))×\(Int((base.height * factor).rounded()))")
                }
            }
            .lineLimit(1)
            .font(.round(10))
            .foregroundColor(optimiser.thumbnail != nil ? .lightGray : .secondary)
            .fixedSize()
        }
    }

    @ViewBuilder var dpiDiff: some View {
        if optimiser.type.isPDF, let oldDPI = optimiser.oldDPI {
            HStack(spacing: 3) {
                let hideOldDPI = OM.compactResults && optimiser.newDPI != nil && optimiser.newDPI! != oldDPI
                if !hideOldDPI {
                    Text("\(oldDPI) DPI")
                }
                if let newDPI = optimiser.newDPI, newDPI != oldDPI {
                    if !hideOldDPI {
                        SwiftUI.Image(systemName: "arrow.right")
                    }
                    Text("\(newDPI) DPI")
                }
            }
            .lineLimit(1)
            .font(.round(10))
            .foregroundColor(optimiser.thumbnail != nil ? .lightGray : .secondary)
            .fixedSize()
        }
    }

    @ViewBuilder var fileSizeDiff: some View {
        let improvement = optimiser.newBytes > 0 && optimiser.newBytes < optimiser.oldBytes
        let improvementColor = (optimiser.thumbnail != nil ? FloatingResult.yellow : (colorScheme == .dark ? FloatingResult.lightBlue : FloatingResult.darkBlue))

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
    }

    var noThumbnailView: some View {
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
                            .font(.semibold(14)).lineLimit(1).opacity(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: THUMB_SIZE.width * 0.8, alignment: .leading)
                            .padding(.bottom, 4)
                    }
                    fileSizeDiff
                    sizeDiff
                    bitrateDiff
                    dpiDiff
                }
            }

            closeStopButton.offset(x: -22, y: -16)
        }
        .animation(nil, value: optimiser.running)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .noThumbBackground(isError: optimiser.error != nil)
        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
    @ViewBuilder var errorView: some View {
        let proError = optimiser.id == Optimiser.IDs.pro
        if let error = optimiser.error {
            if proError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .medium(13)
                        .foregroundColor(.white)
                    if let notice = optimiser.notice {
                        Text(notice)
                            .round(10)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        Button("Get Clop Pro") {
                            manageLicenceInSettings()
                        }
                        .buttonStyle(FlatButton(color: .inverted, textColor: .mauvish, radius: 6, verticalPadding: 3))
                        .font(.round(11, weight: .semibold))

                        Button("Never show this again") {
                            neverShowProError = true
                            hoveredOptimiserID = nil
                            optimiser.remove(after: 200, withAnimation: true)
                        }
                        .buttonStyle(FlatButton(color: .white.opacity(0.15), textColor: .white.opacity(0.7), radius: 6, verticalPadding: 3))
                        .font(.round(11, weight: .regular))
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .allowsTightening(true)
                .frame(maxWidth: 250, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let url = optimiser.url, url.isFileURL {
                        Text("~/" + url.path.replacingOccurrences(of: HOME.string + "/", with: ""))
                            .round(10)
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(error)
                        .medium(13)
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                    if let notice = optimiser.notice {
                        Text(notice)
                            .round(10)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .allowsTightening(true)
                .frame(maxWidth: 250, alignment: .leading)
            }
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
            SwiftUI.Image(systemName: optimiser.type.systemImage)
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

    var actionGrid: some View {
        let cols = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 3)
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(Array(gridSlots.enumerated()), id: \.offset) { _, slot in
                if let action = slot {
                    let button = FloatingGridActionButton(action: action, optimiser: optimiser) {
                        floatingResultActions = floatingResultActions.filter { $0 != action }
                    }
                    // The slider buttons own their press-drag (mouse-down opens the slider, which
                    // grabs the still-held drag), so they must keep blocking the file drag. Every
                    // other button lets a press-drag pull the file out, like the thumbnail itself.
                    if action == .downscale || action == .compression {
                        button
                    } else {
                        fileDraggable(button)
                    }
                } else {
                    fileDraggable(addPlaceholderSlot)
                }
            }
        }
        .fixedSize()
    }

    /// Faint dashed slot; clicking pops a menu of actions to add to the grid. The menu opens on
    /// mouse-up (see FloatingAddActionSlot), so the wrapping fileDraggable gets the press-drag.
    var addPlaceholderSlot: some View {
        FloatingAddActionSlot(actions: addableActions) { action in
            floatingResultActions = floatingResultActions + [action]
        }
    }

    /// Center: the downscale/compression slider while active, otherwise the action grid on hover.
    /// The grid buttons flip showDownscaleSlider/showCompressionSlider on mouse-DOWN and the
    /// thin card slider's event overlay grabs the still-held drag, so press-and-drag is one gesture.
    @ViewBuilder var cardGrid: some View {
        if optimiser.showDownscaleSlider {
            sliderBand {
                if optimiser.type.isAudio {
                    CardCoverArtSlider(optimiser: optimiser)
                } else if optimiser.type.isPDF {
                    CardPDFDPISlider(optimiser: optimiser)
                } else {
                    CardDownscaleSlider(optimiser: optimiser)
                }
            }
        } else if optimiser.showCompressionSlider {
            sliderBand { CardCompressionSlider(optimiser: optimiser) }
        } else if optimiser.showTargetSizeSlider {
            sliderBand { CardTargetSizeSlider(optimiser: optimiser) }
        } else if optimiser.showSendExpiration {
            sliderBand { CardSendExpirationSlider(optimiser: optimiser) }
        } else if isExpanded, !optimiser.running, optimiser.error == nil, optimiser.notice == nil, !optimiser.showingFormats {
            actionGrid
                .opacity(optimiser.editingFilename ? 0.3 : 1)
                .allowsHitTesting(!optimiser.editingFilename)
        }
    }

    @ViewBuilder var cardBottomContent: some View {
        if optimiser.showSendExpiration {
            SendExpirationConfirmButton(optimiser: optimiser)
        } else if optimiser.showDownscaleSlider || optimiser.showCompressionSlider || optimiser.showTargetSizeSlider {
            EmptyView()
        } else if optimiser.running {
            progressView.controlSize(.small).lineLimit(1).foregroundColor(.white)
        } else if optimiser.error != nil {
            errorView.foregroundColor(.white)
        } else if optimiser.notice != nil {
            noticeView.foregroundColor(.white)
        } else if optimiser.editingFilename {
            NameFormatPill(optimiser: optimiser, fullWidth: true)
        } else if isExpanded {
            if optimiser.hoveringFilename, !filenameFits {
                // Hovering a name that doesn't fit: expand full-width to give it room (the crop button,
                // if any, has stepped aside). A name that already fits is left as-is.
                NameFormatPill(optimiser: optimiser, fullWidth: true)
            } else if optimiser.canCrop() {
                // Right-aligned so it clears the crop button in the bottom-left corner.
                HStack(spacing: 0) { Spacer(minLength: 0); NameFormatPill(optimiser: optimiser) }
            } else {
                // No crop button to clear (e.g. audio): centre the pill at its natural width rather
                // than stretching it full-width right-aligned, which looks odd for short filenames.
                HStack(spacing: 0) { Spacer(minLength: 0); NameFormatPill(optimiser: optimiser); Spacer(minLength: 0) }
            }
        } else {
            VStack(spacing: 2) { fileSizeDiff; sizeDiff; bitrateDiff; coverArtDiff; dpiDiff }
                .frame(maxWidth: .infinity)
                .foregroundColor(.white)
                .onAppear { if optimiser.type.isAudio { loadAudioCoverArtSize(optimiser: optimiser) } }
        }
    }

    @ViewBuilder var cornerControls: some View {
        let sliding = optimiser.showDownscaleSlider || optimiser.showCompressionSlider || optimiser.showSendExpiration
        if isExpanded || optimiser.running, !sliding, !optimiser.showingFormats {
            fileDraggable(CloseStopButton(optimiser: optimiser))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        if isExpanded, !optimiser.running, !optimiser.editingFilename, !sliding, !optimiser.showingFormats {
            Menu {
                RightClickMenuView(optimiser: optimiser)
            } label: {
                SwiftUI.Image(systemName: "ellipsis")
            }
            .menuButtonStyle(BorderlessButtonMenuButtonStyle())
            .menuIndicator(.hidden)
            .buttonStyle(FloatingCornerButtonStyle())
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Crop lives in the bottom-left corner; it only steps aside while a name that doesn't fit
            // is hovered (so a long filename can use the full width). A fitting name keeps the button.
            if optimiser.canCrop(), !optimiser.hoveringFilename || filenameFits {
                fileDraggable(
                    Button(action: { if !preview { optimiser.showCropWindow() } }, label: { SwiftUI.Image(systemName: "crop") })
                        .buttonStyle(FloatingCornerButtonStyle())
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    var thumbnailView: some View {
        ZStack {
            cardGrid

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                cardBottomContent
            }
            .animation(nil, value: optimiser.running)

            cornerControls

            OverlayMessageView(optimiser: optimiser, color: .black)
        }
        .padding(8)
        .frame(width: Self.cardW, height: Self.cardH, alignment: .center)
        .fixedSize()
        .background(
            SwiftUI.Image(nsImage: optimiser.thumbnail!)
                .resizable()
                .scaledToFill()
                .overlay(
                    // The bottom band fades softly upward. A translucent black gradient sits behind
                    // the vibrant blur so white text stays legible over bright/white thumbnails, where
                    // the blur alone isn't dark enough. Both share the same upward fade mask.
                    ZStack {
                        LinearGradient(
                            colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                            startPoint: .bottom, endPoint: .top
                        )
                        VisualEffectBlur(material: .popover, blendingMode: .withinWindow, state: .active, appearance: .vibrantDark)
                    }
                    .clipped()
                    .mask(LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.25),
                            .init(color: .black.opacity(0.7), location: 0.42),
                            .init(color: .black.opacity(0), location: 0.88),
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    ))
                )
                // Hardware blur of the thumbnail on hover (NSVisualEffectView .withinWindow blurs the
                // image behind it — no gaussian pixelation), appearing instantly, no animation. Same
                // .hudWindow vibrantDark material the step-hint label uses, so the veil matches it.
                .overlay {
                    if isExpanded {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow, state: .active, appearance: .vibrantDark)
                    }
                }
                // File-drag lives on the background image, NOT the whole card, so pressing a grid
                // button (downscale/compression) never starts a drag and the slider catches the
                // press-drag instantly. No drag while a slider is active either. The other card
                // buttons opt back in individually via `fileDraggable`.
                .ifLet(optimiser.url, transform: { img, url in
                    img.if(!optimiser.showDownscaleSlider && !optimiser.showCompressionSlider && !optimiser.showSendExpiration) { v in
                        v.onDrag {
                            guard !preview else {
                                return NSItemProvider()
                            }

                            log.debug("Dragging \(url)")
                            if Defaults[.dismissFloatingResultOnDrop] {
                                optimiser.remove(after: 100, withAnimation: true)
                            }
                            return NSItemProvider(object: url as NSURL)
                        } preview: {
                            dragThumbPreview
                        }
                    }
                })
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        // NOTE: no card-wide white foreground — controls sit on light warm material and must use
        // .primary (adaptive). White is applied only to content over the dark thumbnail below.
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
    }

    var body: some View {
        if optimiser.dismissing {
            // Close button pressed: render nothing (no glass, no thumbnail) while removal
            // completes, so dismissal is instant instead of paying for a final glass re-render.
            Color.clear.frame(width: 0, height: 0)
        } else {
            mainBody
        }
    }

    /// Clean rounded thumbnail used as the drag image for a single result (the same look as one tile
    /// in the "drag all" pile, no badge), instead of the default washed-out dark rectangle.
    @ViewBuilder var dragThumbPreview: some View {
        if let thumb = optimiser.thumbnail {
            SwiftUI.Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                .padding(8)
        } else {
            SwiftUI.Image(systemName: "doc.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
                .padding(8)
        }
    }

    @ViewBuilder var mainBody: some View {
        let hasThumbnail = optimiser.thumbnail != nil
        Group {
            if hasThumbnail, optimiser.error == nil {
                // Self-contained overlay-grid card: corners + grid + filename/format all live
                // on the fixed-geometry thumbnail, revealed by opacity on hover.
                thumbnailView
                    .onHover(perform: updateHover(_:))
                    .if(!optimiser.inRemoval) { view in
                        view.contextMenu {
                            RightClickMenuView(optimiser: optimiser)
                        }
                    }
            } else {
                VStack(spacing: 4) {
                    noThumbnailView
                        .contentShape(Rectangle())
                        .onHover(perform: updateHover(_:))
                        .if(!optimiser.inRemoval) { view in
                            view.contextMenu {
                                RightClickMenuView(optimiser: optimiser)
                            }
                        }
                    if optimiser.error == nil {
                        FormatSelectorView(optimiser: optimiser)
                            .frame(width: THUMB_SIZE.width / 2 + 10, height: 16, alignment: .center)
                            .opacity(isExpanded ? 1 : 0.1)
                            .animation(.easeOut(duration: 0.15), value: isExpanded)
                    }
                }
            }
        }
//        .frame(minWidth: THUMB_SIZE.width / 2, idealWidth: THUMB_SIZE.width / 2, maxWidth: THUMB_SIZE.width, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
        .padding(.horizontal)
        .fixedSize()
        .onHover { hovering in
            // A fresh hover (mouse re-entering) brings the overlay back after it was collapsed by an action.
            if hovering { optimiser.collapseHoverOverlay = false }
            // Leaving the card abandons an in-progress send-expiration overlay.
            if !hovering { optimiser.showSendExpiration = false }
            withAnimation(.easeOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
        .opacity(optimiser.inRemoval ? 0 : 1)
        .offset(x: optimiser.inRemoval ? (floatingResultsCorner.isTrailing ? 500 : -500) : 0)
        // A dismissed result should not react to the cursor: its hit area follows the slide-out
        // offset and could steal hover from the remaining results. The layout slot is kept
        // intact during the slide-out; the gap closes afterwards via the animated removal
        // from `OM.optimisers`, so the two motions don't fight each other.
        .allowsHitTesting(!optimiser.inRemoval)
        // Match the list-collapse curve so the slide-out and the gap closing behind it move as one motion.
        .animation(resultFallAnimation, value: optimiser.inRemoval)
        .onAppear {
            optimiser.ensurePlaceholderThumbnail()
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

    /// Wraps a card control in the same file-drag as the thumbnail background, so a press-drag that
    /// starts on the control still pulls the file out while a plain click keeps activating it. The
    /// downscale/compression grid buttons stay out of this (their mouse-down opens the slider, which
    /// owns the still-held drag), as does the corner ellipsis menu (SwiftUI menus open on mouse-down).
    /// The add-placeholder slots pop their menu on mouse-up (FloatingAddActionSlot), so they opt in.
    @ViewBuilder func fileDraggable(_ content: some View) -> some View {
        if let url = optimiser.url {
            content.onDrag {
                guard !preview else {
                    return NSItemProvider()
                }

                log.debug("Dragging \(url)")
                if Defaults[.dismissFloatingResultOnDrop] {
                    optimiser.remove(after: 100, withAnimation: true)
                }
                return NSItemProvider(object: url as NSURL)
            } preview: {
                dragThumbPreview
            }
        } else {
            content
        }
    }

    func sliderBand(@ViewBuilder _ slider: () -> some View) -> some View {
        slider().frame(width: Self.cardW - 30)
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
                    .offset(y: isExpanded || SWIFTUI_PREVIEW ? 30 : 0)
                    .opacity(isExpanded || SWIFTUI_PREVIEW ? 0 : 1)
            }

            FileNameField(optimiser: optimiser)
                .font(.medium(9))
                .foregroundColor(.primary)
                .frame(width: THUMB_SIZE.width / 2, height: 16, alignment: .leading)
                .fixedSize()
                .padding(.horizontal, 5)
                .offset(y: isExpanded || editingFilename || SWIFTUI_PREVIEW ? 0 : 30)
                .opacity(isExpanded || editingFilename || SWIFTUI_PREVIEW ? 1 : 0)
                .scaleEffect(
                    x: optimiser.editingFilename ? 1.2 : 1,
                    y: optimiser.editingFilename ? 1.2 : 1,
                    anchor: floatingResultsCorner.isTrailing ? .bottomTrailing : .bottomLeading
                )
        }
    }

    /// Whether an action belongs in the in-card grid for this result. Crop is a dedicated corner
    /// button; downscale is dropped for audio, which uses the compression button as its single
    /// bitrate/quality axis.
    func gridApplies(_ action: FloatingAction) -> Bool {
        switch action {
        case .crop: false
        // Audio's downscale button is repurposed to resize the embedded cover art, so it's shown for
        // every type now (bitrate lives on the compression button).
        case .downscale: true
        // PDF's downscale button already is the compression (DPI) control with the same icon, so a
        // separate, always-disabled compression button is just a confusing duplicate; hide it like
        // PDF does.
        case .compression: !optimiser.type.isPDF
        default: true
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
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

@MainActor
struct FloatingPreviewAllStates: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(resource: .sonomaShot)
        clipEnd.image = Image(nsImage: clipEnd.thumbnail!, data: Data(), type: .png, retinaDownscaled: false)
        clipEnd.isPreview = true
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: thumbSize)

        let videoOpt = Optimiser(id: "Movies/meeting-recording-video.mov", type: .video(.quickTimeMovie))
        videoOpt.url = "\(HOME)/Movies/meeting-recording-video.mov".fileURL
        videoOpt.thumbnail = NSImage(resource: .sonomaVideo)
        videoOpt.isPreview = true
        videoOpt.finish(oldBytes: 52_400_000, newBytes: 31_200_000)

        let cropped = Optimiser(id: "cropped-image", type: .image(.png))
        cropped.url = "\(HOME)/Desktop/menubar/icon@2x.png".fileURL
        cropped.thumbnail = NSImage(resource: .sonomaShot)
        cropped.isPreview = true
        cropped.finish(oldBytes: 16220, newBytes: 1077, oldSize: CGSize(width: 570, height: 320), newSize: CGSize(width: 44, height: 44))

        let pipelineRunning = Optimiser(id: "pipeline-running", type: .image(.png), running: true)
        pipelineRunning.url = "\(HOME)/Desktop/menubar/icon.png".fileURL
        pipelineRunning.operation = "Running pipeline"
        pipelineRunning.progress = Progress()

        let errorOpt = Optimiser(id: "error-file", type: .image(.jpeg))
        errorOpt.url = "\(HOME)/Desktop/broken.jpg".fileURL
        errorOpt.isPreview = true
        errorOpt.finish(error: "A server with the specified hostname could not be found.")

        let proError = Optimiser(id: Optimiser.IDs.pro, type: .image(.png))
        proError.isPreview = true
        proError.finish(error: "You've optimised 5 files this session", notice: "Get Clop Pro to remove the limit and unlock all features. Relaunch the app to reset the counter.")

        o.optimisers = [clipEnd, videoOpt, cropped, errorOpt, proError]
        for opt in o.optimisers {
            opt.isPreview = true
        }
        return o
    }()

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }
}

struct FloatingResultAllStates_Previews: PreviewProvider {
    static var previews: some View {
        FloatingPreviewAllStates()
            .frame(width: 450, height: 1100)
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("All States")
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
