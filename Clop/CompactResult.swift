import Defaults
import Foundation
import Lowtech
import LowtechPro
import os
import SwiftUI
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "CompactResult")

struct CompactResult: View {
    static let improvementColor = Color(light: FloatingResult.darkBlue, dark: FloatingResult.yellow)

    // Shared typography so every row reads as one design instead of a pile of ad-hoc sizes.
    static let nameFont = Font.medium(12)
    static let sizeFont = Font.mono(11, weight: .semibold)
    static let metricFont = Font.round(10, weight: .medium)

    @ObservedObject var optimiser: Optimiser
    // Passed down from the list instead of each row observing the global SelectionManager,
    // so toggling one row's selection no longer re-renders every other row's body.
    var selecting: Bool
    var selected = false
    var selectable = true
    var onToggleSelection: () -> Void = {}
    @State var hovering = false

    @Default(.neverShowProError) var neverShowProError
    @Default(.showCompactImages) var showCompactImages

    @Environment(\.openWindow) var openWindow
    @Environment(\.preview) var preview
    @Environment(\.openURL) var openURL
    @Environment(\.colorScheme) var colorScheme

    /// Per-file-type accent hue for the thumbnail ring.
    var typeColor: Color {
        if optimiser.type.isImage { return .blue }
        if optimiser.type.isVideo { return .purple }
        if optimiser.type.isPDF { return .orange }
        if optimiser.type.isAudio { return .pink }
        return .gray
    }

    @ViewBuilder var pathView: some View {
        if let url = optimiser.url, url.isFileURL {
            Text(url.filePath!.shellString)
                .medium(9)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder var nameView: some View {
        if let url = optimiser.url, url.isFileURL {
            Text(url.lastPathComponent)
                .medium(9)
                .foregroundColor(.secondary)
                .lineLimit(1)
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
    var progressView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if optimiser.progress.isIndeterminate {
                VStack(alignment: .leading) {
                    Text(optimiser.operation)
                    ProgressView(optimiser.progress)
                        .progressViewStyle(.linear)
                        .allowsTightening(false)
                    nameView
                }
                progressURLView.padding(.vertical, 4)
            } else {
                VStack(alignment: .leading) {
                    Spacer()
                    ProgressView(optimiser.progress).progressViewStyle(.linear).allowsTightening(false)
                    Spacer()
                    nameView
                }
                progressURLView
                    .padding(.vertical, 4)
            }
        }
    }
    @ViewBuilder var sizeDiff: some View {
        if let oldSize = optimiser.oldSize, !selecting {
            ResolutionField(optimiser: optimiser, showCropIcon: true, size: oldSize)
                .buttonStyle(FlatButton(color: .primary.opacity(0.06), textColor: .secondary, radius: 4, horizontalPadding: 4, verticalPadding: 1, shadowSize: 0))
                .font(Self.metricFont)
                .foregroundColor(.secondary)
                .fixedSize()
                .disabled(!optimiser.canCrop())
        }
    }

    @ViewBuilder var bitrateDiff: some View {
        if optimiser.type.isAudio, let oldBitrate = optimiser.oldBitrate, !selecting {
            HStack(spacing: 3) {
                let hideOldBitrate = optimiser.newBitrate != nil && optimiser.newBitrate! != oldBitrate
                if !hideOldBitrate {
                    Text("\(oldBitrate) kbps")
                }
                if let newBitrate = optimiser.newBitrate, newBitrate != oldBitrate {
                    if !hideOldBitrate {
                        SwiftUI.Image(systemName: "arrow.right")
                    }
                    Text("\(newBitrate) kbps")
                }
            }
            .lineLimit(1)
            .font(Self.metricFont)
            .foregroundColor(.secondary)
            .fixedSize()
        }
    }

    @ViewBuilder var dpiDiff: some View {
        if optimiser.type.isPDF, let oldDPI = optimiser.oldDPI, !selecting {
            HStack(spacing: 3) {
                let hideOldDPI = optimiser.newDPI != nil && optimiser.newDPI! != oldDPI
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
            .font(Self.metricFont)
            .foregroundColor(.secondary)
            .fixedSize()
        }
    }

    /// Percentage saved, styled to match the batch window's savings pills for a cohesive look across the app.
    @ViewBuilder var savingsBadge: some View {
        if !selecting, optimiser.oldBytes > 0, optimiser.newBytes > 0, optimiser.newBytes < optimiser.oldBytes {
            let pct = Int(((optimiser.oldBytes - optimiser.newBytes).d / optimiser.oldBytes.d * 100).rounded())
            if pct > 0 {
                // Bigger savings read stronger: the capsule fill ramps with the percentage (a 70%+ save
                // sits near full intensity), so the wins you care about visibly pop.
                let intensity = min(1.0, max(0.2, pct.d / 70.0))
                Text("−\(pct)%")
                    .mono(9, weight: .bold)
                    .foregroundColor(Self.improvementColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Self.improvementColor.opacity(0.1 + intensity * 0.22), in: Capsule())
                    .fixedSize()
            }
        }
    }

    @ViewBuilder var fileSizeDiff: some View {
        let improvement = optimiser.newBytes > 0 && optimiser.newBytes < optimiser.oldBytes

        HStack(spacing: 4) {
            Text(optimiser.oldBytes.humanSize)
                .font(Self.sizeFont)
                .foregroundColor(
                    !selecting
                        ? (improvement ? Color.red : Color.secondary)
                        : (improvement ? Color.secondary : Color.primary)
                )
            if optimiser.newBytes > 0, optimiser.newBytes != optimiser.oldBytes {
                SwiftUI.Image(systemName: "arrow.right")
                    .font(.medium(11))
                    .foregroundColor(.secondary)
                Text(optimiser.newBytes.humanSize)
                    .font(Self.sizeFont)
                    .foregroundColor(
                        improvement
                            ? (!selecting ? Self.improvementColor : .primary)
                            : (!selecting ? FloatingResult.red : .secondary)
                    )
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
                            manageLicenceInSettings()
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
            Group {
                if let image = optimiser.thumbnail {
                    SwiftUI.Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    SwiftUI.Image(systemName: optimiser.type.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.primary.opacity(optimiser.thumbnail == nil ? 0.05 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            // A thin ring tinted by file type, for a touch of colour and quick scanning (handy when the
            // thumbnail is a generic icon, e.g. audio/PDF).
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(typeColor.opacity(0.3), lineWidth: 1.5)
            )
            .overlay(alignment: .topLeading) {
                if !selecting { closeButton.offset(x: -5, y: -5) }
            }
            // In a SwiftUI List, a press on STATIC content (the bare image) is claimed by the list's own
            // selection/scroll gesture, so neither the row's body-root .onDrag NOR an .onDrag attached
            // here ever initiates from the thumbnail. The drag only works where the press lands on an
            // INTERACTIVE responder (the filename's tap gesture, the checkbox/close Buttons), which lets
            // the drag bubble up to the row's drag source. So give the thumbnail its own tap gesture to
            // make it such a responder: a tap toggles selection while selecting (and is a no-op
            // otherwise), and crucially a press-drag now bubbles to the body-root .onDrag and drags.
            .contentShape(Rectangle())
            .onTapGesture { if SM.selecting { onToggleSelection() } }
            // Signal draggability: a subtle scale-up and a pointer cursor on hover (render-only, no layout shift).
            .scaleEffect(hoveringThumb ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: hoveringThumb)
            .onHover { h in
                hoveringThumb = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    @ViewBuilder var dragPreview: some View {
        if selected, SM.selection.count > 1 {
            DragPilePreview(optimisers: SM.optimisers)
        } else {
            DragPreview(optimiser: optimiser)
        }
    }

    /// Plain X (or stop) button pinned to the thumbnail's top-left corner. Fades in on row hover via
    /// opacity only, so it never shifts the row's geometry. Replaces the old "Close"/"Stop" text pill
    /// that used to sit in the top-right.
    var closeButton: some View {
        Button {
            guard !preview else { return }
            hoveredOptimiserID = nil
            optimiser.stop(remove: !OM.compactResults || !optimiser.running, animateRemoval: true)
            optimiser.uiStop()
        } label: {
            SwiftUI.Image(systemName: optimiser.running ? "stop.fill" : "xmark")
                .font(.bold(7))
                .foregroundColor(.red)
                .frame(width: 14, height: 14)
                .background(Circle().fill(
                    hoveringCloseStopButton
                        ? Color(light: Color(red: 1.0, green: 0.82, blue: 0.82), dark: Color(red: 0.42, green: 0.17, blue: 0.17))
                        : Color(light: Color(red: 1.0, green: 0.89, blue: 0.89), dark: Color(red: 0.32, green: 0.14, blue: 0.14))
                ))
                .overlay(Circle().strokeBorder(Color.red, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusable(false)
        // Only hit-testable while shown (on row hover); otherwise the invisible button would block drags
        // from the thumbnail's top-left corner. `.offset` is render-only so the hit area sits at the corner.
        .allowsHitTesting(hovering)
        .opacity(hovering ? (hoveringCloseStopButton ? 1 : 0.85) : 0)
        .onHover { hoveringCloseStopButton = $0 }
        .help(optimiser.running ? "Stop" : "Close")
    }

    /// Photos/Finder-style selection circle. Always present on selectable rows (translucent at rest,
    /// solid when hovered or selected) so the affordance is discoverable without a hover and the row
    /// geometry never shifts. Clicking it is the ONLY thing that selects a row, so a plain click on the
    /// row body keeps doing single-item things (drag, rename, quick actions) without entering a mode.
    @ViewBuilder var selectionCheckbox: some View {
        if selectable {
            Button(action: onToggleSelection) {
                ZStack {
                    Circle().fill(.background).frame(width: 17, height: 17)
                    if selected {
                        SwiftUI.Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    } else {
                        SwiftUI.Image(systemName: "circle")
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .font(.system(size: 17, weight: .medium))
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(selected || selecting || hovering ? 1 : 0.35)
            .help(selected ? "Deselect" : "Select")
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
                pathView
            }
            .allowsTightening(true)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            if optimiser.running {
                progressView
                    .controlSize(.small)
                    .font(Self.nameFont).lineLimit(1)
            } else if optimiser.error != nil {
                errorView
            } else if optimiser.notice != nil {
                noticeView
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if let url = (optimiser.url ?? optimiser.originalURL), url.isFileURL {
                        CompactNameField(optimiser: optimiser)
                            // Grow to the row's full width while editing so the rename field has room;
                            // at rest it stays at its compact 60% width.
                            .frame(maxWidth: optimiser.editingFilename ? .infinity : THUMB_SIZE.width * 0.6, alignment: .leading)
                    }
                    HStack(spacing: 5) {
                        fileSizeDiff
                        savingsBadge
                        Spacer(minLength: 4)
                        sizeDiff
                        bitrateDiff
                        dpiDiff
                    }
                    // Match the name chip's horizontal text inset so this lines up with the filename text,
                    // not the chip's background edge. Trailing padding keeps the size text off the row edge.
                    .padding(.leading, 3)
                    .padding(.trailing, 8)
                    if !selecting {
                        ActionButtons(optimiser: optimiser, size: 18, revealed: hovering)
                            .padding(.top, 0)
                            .focusable(false)
                    }
                }
            }
        }
        // Always reserve a fixed leading checkbox column so the checkbox sits in its own gap (close to
        // the left edge once the list row insets are removed) and the row geometry never shifts on hover.
        // 28 leaves a small (~7pt) gap between the 17pt checkbox and the 40pt thumbnail without looking loose.
        .padding(.leading, 28)
        .overlay(alignment: .leading) { selectionCheckbox.padding(.leading, 4) }
        .animation(nil, value: optimiser.running)
        .padding(.top, 3)
        .frame(height: 70)
        .hfill(.leading)
        // Plain full-bleed selection fill (no rounding, no inset) so selected rows read as a clean band;
        // a faint accent wash on plain hover gives the row a live feel without adding chrome.
        .background {
            if selected {
                Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14)
            } else if hovering {
                Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.06)
            }
        }
        // Thin accent edge marks the selected row at a glance.
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Color.accentColor).frame(width: 2.5)
            }
        }
        // The close button normally lives on the thumbnail's corner; when thumbnails are hidden there's
        // nothing to anchor it to, so fall back to the row's trailing edge.
        .if(!selecting && !showCompactImages) { view in
            view.overlay(alignment: .topTrailing) { closeButton.padding(.trailing, 4) }
        }
        .onHover(perform: updateHover(_:))
        // Resolve cover-art size for audio so the cover-art downscale button only appears when there's
        // actually cover art to resize.
        .onAppear { if optimiser.type.isAudio { loadAudioCoverArtSize(optimiser: optimiser) } }
        // File drag attached at the body ROOT (see fileDragProvider) so it bridges to the List row's
        // table drag session. Gated by both slider flags so a press-drag on the compression/downscale
        // slider stays with the slider instead of starting a row drag.
        .ifLet(optimiser.url) { view, url in
            view.if(url.isFileURL && !optimiser.showDownscaleSlider && !optimiser.showCompressionSlider && !preview) { v in
                v.onDrag { fileDragProvider(url) } preview: { dragPreview }
            }
        }
        // Uniform breathing room below every row (running rows render a tall progress/name stack that would
        // otherwise crowd the bottom edge); replaces the per-row action-button bottom padding so the gap is
        // consistent whether or not the buttons are shown.
        .padding(.bottom, 8)
    }

    /// File drag for the whole row. Attached at the body ROOT (NOT a nested subview) so it bridges to the
    /// SwiftUI List row's table drag session on macOS — `.onDrag` on a nested subview inside a List row
    /// does not. A selected row (with a multi-selection) drags the whole selection; otherwise just this
    /// file. Gated at the call site by `!showDownscaleSlider && !showCompressionSlider`, so pressing a
    /// grid slider catches the press-drag instead of starting a row drag, exactly like the floating card.
    func fileDragProvider(_ url: URL) -> NSItemProvider {
        if selected, SM.selection.count > 1 {
            let urls = SM.optimisers.compactMap(\.url).filter(\.isFileURL)
            let provider = NSItemProvider()
            for u in urls {
                provider.registerObject(u as NSURL, visibility: .all)
            }
            return provider
        }
        log.debug("Dragging \(url)")
        if Defaults[.dismissCompactResultOnDrop] {
            optimiser.remove(after: 100, withAnimation: true)
        }
        return NSItemProvider(object: url as NSURL)
    }

    func updateHover(_ hovering: Bool) {
        if hovering, !preview {
            hoveredOptimiserID = optimiser.id
        }
        withAnimation(.easeOut(duration: 0.15)) {
            self.hovering = hovering
        }
    }

    @State private var hoveringCloseStopButton = false
    @State private var hoveringThumb = false

}

/// Filename control for the compact list rows: `name.ext` rendered as two tappable chips. Tapping the
/// name chip swaps it for an inline edit field; the extension chip is a borderless format-conversion
/// menu. Each chip is a monochrome rounded chip (very translucent fill + hairline border, 4pt corners,
/// tight padding) so it reads as clickable at a glance, firming up on hover. Text stays `.primary` so it
/// adapts to the compact view's color scheme. The floating card keeps its own `NameFormatPill`/`FileNameField`.
struct CompactNameField: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Group {
            if optimiser.editingFilename {
                editor
            } else {
                segments
            }
        }
        .frame(height: 18)
        .onAppear { tempName = stem }
        .onChange(of: optimiser.url) { _ in tempName = stem }
        .onChange(of: optimiser.running) { running in if running { optimiser.editingFilename = false } }
    }

    var segments: some View {
        HStack(spacing: 4) {
            // Bordered accent chip marks the name as tappable at a glance; it intensifies on hover and
            // shows the I-beam. Text stays `.primary` so it adapts to the compact view's color scheme.
            Text(stem.isEmpty ? "filename" : stem)
                .font(CompactResult.nameFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .listChip(hovering: hoveringName)
                .onHover { inside in
                    guard !SM.selecting else { return }
                    hoveringName = inside
                    if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
                }
                .onTapGesture { startEditing() }
                .help("Click to rename")
            if !ext.isEmpty {
                formatSegment
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder var formatSegment: some View {
        if !optimiser.running, optimiser.canChangeFormat() {
            Menu {
                ForEach(optimiser.convertibleTypes) { format in
                    let e = format.preferredFilenameExtension ?? format.identifier.components(separatedBy: ".").last ?? ""
                    if !e.isEmpty {
                        Button(e.uppercased()) {
                            guard !preview, optimiser.type.utType != format else { return }
                            optimiser.convert(to: format, optimise: true)
                        }
                    }
                }
            } label: {
                Text(ext)
                    .font(CompactResult.nameFont)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .listChip(hovering: hoveringExt)
            }
            .menuButtonStyle(BorderlessButtonMenuButtonStyle())
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .onHover { hoveringExt = $0 }
            .fixedSize()
            .help("Convert to another format")
        } else {
            Text(ext).font(CompactResult.nameFont).foregroundColor(.secondary)
        }
    }

    var editor: some View {
        // The X sits OUTSIDE the field's frame (not in a shared background), so the focused text field's
        // own white editing/selection background stays within the field and never overlaps the button.
        HStack(spacing: 6) {
            TextField("", text: $tempName)
                .textFieldStyle(.plain)
                .font(CompactResult.nameFont)
                .foregroundColor(.primary)
                .focused($focused)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        // Keep the X button clear of the window's rounded corner when the field spans the full width.
        .padding(.trailing, 8)
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
        withAnimation(.easeOut(duration: 0.1)) { optimiser.editingFilename = true }
    }

    @FocusState private var focused: Bool
    @State private var tempName = ""
    @State private var hoveringName = false
    @State private var hoveringExt = false

    private var stem: String {
        optimiser.url?.filePath?.stem ?? optimiser.originalURL?.filePath?.stem ?? ""
    }
    private var ext: String {
        optimiser.url?.filePath?.extension ?? optimiser.originalURL?.filePath?.extension ?? ""
    }

}

struct OverlayMessageView: View {
    @ObservedObject var optimiser: Optimiser
    var color: Color

    @State var opacity = 1.0

    var body: some View {
        if optimiser.stepIndicator.isNotEmpty, !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider {
            Text(optimiser.stepIndicator)
                .foregroundColor(color == .black ? .white : .primary)
                .roundbg(radius: 12, padding: 6, color: color)
                .fill()
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow, state: .active, appearance: color == .black ? .vibrantDark : .none).scaleEffect(1.1)
                )
                .transaction { $0.animation = nil }
        } else if optimiser.overlayMessage.isNotEmpty {
            Text(optimiser.overlayMessage)
                .foregroundColor(color == .black ? .white : .primary)
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

@MainActor
class SelectionManager: ObservableObject {
    @Published var selection = Set<String>()
    @Published var selectableCount = 0

    @Published var selecting = false {
        didSet {
            if selecting {
                for opt in OM.optimisers {
                    opt.editingFilename = false
                }
            }
        }
    }
    var optimisers: [Optimiser] {
        OM.optimisers.filter { selection.contains($0.id) }
    }

    func save() {
        let paths: [String: FilePath] = optimisers.dict { o in
            guard let path = o.url?.existingFilePath else { return nil }
            return (o.id, path)
        }
        guard !paths.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.level = .modalPanel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            var savedURLs = [URL]()
            for (id, path) in paths {
                if let savedPath = try? path.copy(to: url.filePath!, force: true), let opt = opt(id) {
                    let url = savedPath.url
                    savedURLs.append(url)

                    opt.url = url
                    opt.path = savedPath
                    opt.filename = savedPath.name.string

                    try? path.setOptimisationStatusXattr("true")
                }
            }

            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        }
    }

    func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(optimisers.compactMap { $0.url as NSURL? })
    }

    func restoreOriginal() {
        for optimiser in optimisers {
            optimiser.restoreOriginal()
        }
    }

    func quicklook() {
        OM.quicklook()
    }
}

@MainActor let SM = SelectionManager()

extension View {
    /// Full-width footer-bar chrome shared by both bottom bars: fills the panel width and stays flat
    /// (the panel's own rounded clip shapes the bottom corners, so the bar has no corner whitespace),
    /// with a hairline separator above it.
    func footerBarChrome() -> some View {
        padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .resultsBandBackground()
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5) }
    }

    /// Opaque band a touch off the list background: the same `Color.inverted.brightness(0.1)` base plus a
    /// faint primary tint, so it reads as a touch darker in light mode / lighter in dark mode rather than a
    /// blurred material that picks up the content scrolling behind it. Shared by the footer and progress bars.
    ///
    /// `scale` over-extends the fill past its frame to cover the empty space left by row padding (the
    /// progress bar isn't full-width); the footer is full-width and leaves it at 1.
    func resultsBandBackground(scale: CGFloat = 1) -> some View {
        background {
            ZStack {
                Color.inverted.brightness(0.1)
                Color.primary.opacity(0.06)
            }
            .scaleEffect(scale)
        }
    }
}

/// A little stack of result thumbnails shown while dragging a set out of the compact list, matching the
/// floating result's "drag all" preview instead of dragging the bare handle button.
struct DragPilePreview: View {
    var optimisers: [Optimiser]

    var body: some View {
        let thumbs = optimisers.prefix(4).compactMap(\.thumbnail)
        ZStack {
            if thumbs.isEmpty {
                SwiftUI.Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                    .frame(width: 54, height: 54)
            } else {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { i, thumb in
                    SwiftUI.Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.5), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                        .rotationEffect(.degrees(Double(i) * 5 - 7))
                        .offset(x: Double(i) * 6, y: Double(i) * -3)
                }
            }
            Text("\(optimisers.count)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .frame(minWidth: 20, minHeight: 20)
                .background(Circle().fill(Color.accentColor).shadow(color: .black.opacity(0.3), radius: 2))
                .offset(x: 32, y: -30)
        }
        .frame(width: 96, height: 80)
        .padding(8)
    }
}

/// Neutral "drag all" handle for the compact footer bars. Registers one provider per file so the drop
/// lands as a set, and shows the thumbnail-pile preview instead of a snapshot of the handle itself.
struct CompactDragAllHandle: View {
    var optimisers: [Optimiser]
    var help: String

    @Environment(\.preview) var preview

    var body: some View {
        SwiftUI.Image(systemName: "line.3.horizontal")
            .font(.medium(12))
            .frame(width: 30, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
            .foregroundColor(.primary.opacity(0.7))
            .help(help)
            .onDrag {
                guard !preview else { return NSItemProvider() }
                let urls = optimisers.compactMap(\.url).filter(\.isFileURL)
                guard let first = urls.first else { return NSItemProvider() }
                let provider = NSItemProvider()
                provider.registerObject(first as NSURL, visibility: .all)
                for url in urls.dropFirst() {
                    provider.registerObject(url as NSURL, visibility: .all)
                }
                return provider
            } preview: {
                DragPilePreview(optimisers: optimisers)
            }
    }
}

/// The unified action bar shown at the bottom of the compact list while a selection is active. Mirrors
/// the floating-result layout: a drag handle first (drags all selected), then a menu holding every batch
/// action, the crop control, and a selection count + clear on the trailing side. Neutral styling (no warm
/// tint) to match the rest of the redesigned list.
struct CompactSelectionBar: View {
    @ObservedObject var sm = SM

    var body: some View {
        let selected = sm.selection.compactMap { opt($0) }
        HStack(spacing: 6) {
            CompactDragAllHandle(optimisers: selected, help: "Drag all selected files")

            Menu {
                BatchRightClickMenuView()
                Divider()
                Button("Select all") { SM.selection = OM.visibleOptimisers.filter { !$0.running && $0.url != nil }.map(\.id).set }
            } label: {
                SwiftUI.Image(systemName: "ellipsis")
                    .font(.medium(12))
                    .frame(width: 34, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .foregroundColor(.primary.opacity(0.7))
                    .contentShape(Rectangle())
            }
            // .button + .plain renders the custom chip label as-is (the deprecated borderless style
            // swallowed the label background); chip matches the drag handle's size and fill exactly.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions for the selection")

            BatchCropButton()

            Spacer()

            Text("\(sm.selection.count)")
                .mono(11, weight: .semibold)
                .foregroundColor(.primary.opacity(0.6))
            Button(action: { sm.selection = [] }) {
                SwiftUI.Image(systemName: "xmark.circle.fill").font(.medium(13))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Clear selection")
        }
        .font(.round(10))
        .buttonStyle(FlatButton(color: .primary.opacity(0.08), textColor: .primary.opacity(0.8), shadowSize: 0))
        .footerBarChrome()
    }
}

/// The unified bottom bar shown when there is NO active selection: the "drag all" handle first (matching
/// the floating-card and selection-bar layout), then stop/clear, and the update button on the trailing
/// side. Lives in the same overlay slot as `CompactSelectionBar` and fades in on hover, so the list no
/// longer needs a separate row of buttons above it.
struct CompactListBar: View {
    var optimisers: [Optimiser]
    var hasRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            CompactDragAllHandle(optimisers: optimisers, help: "Drag all results")

            if hasRunning {
                Button("Stop all") {
                    for optimiser in OM.optimisers.filter(\.running) {
                        optimiser.stop(remove: false)
                        optimiser.uiStop()
                    }
                }
            }
            Button(hasRunning ? "Stop and clear" : "Clear all") {
                OM.clearVisibleOptimisers(stop: true)
            }
            .help("Stop all running optimisations and dismiss all results (\(keyComboModifiers.str) esc)")

            Spacer()

            UpdateButton(short: !showCompactImages)
        }
        .font(.round(10))
        .buttonStyle(FlatButton(color: .primary.opacity(0.08), textColor: .primary.opacity(0.8), shadowSize: 0))
        .footerBarChrome()
    }

    @Default(.keyComboModifiers) private var keyComboModifiers
    @Default(.showCompactImages) private var showCompactImages

}

@MainActor struct CompactOptimiser: Identifiable {
    let optimiser: Optimiser
    let isLast: Bool
    let isEven: Bool
    let index: Int

    var id: String {
        optimiser.id
    }
    var running: Bool {
        optimiser.running
    }

    var selected: Bool {
        SM.selection.contains(id)
    }
}

struct DragHandle: View {
    var body: some View {
        VStack(spacing: -1) {
            Group {
                SwiftUI.Image(systemName: "square.grid.4x3.fill")
                    .scaledToFill()
                SwiftUI.Image(systemName: "square.grid.4x3.fill")
                    .scaledToFill()
            }
            .onHover { h in
                withAnimation(.easeOut(duration: 0.15)) {
                    hoveringDots = h
                }
            }
        }
        .vfill()
        .frame(width: 20)
        .foregroundColor(hoveringDots ? .red.opacity(0.5) : .secondary.opacity(0.5))
        .roundbg(color: .primary.opacity(hovering ? 0.1 : 0.05))
        .scaleEffect(hovering ? 1.05 : 1)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = h
                if !h {
                    hoveringDots = false
                }
            }
        }
    }

    @State private var hovering = false
    @State private var hoveringDots = false

}

struct CompactResultList: View {
    /// Height reserved at the bottom of the panel for the unified action bar (selection actions, or the
    /// drag-all / clear-all controls), so the bar never covers the last row.
    static let footerBand: CGFloat = 40

    var optimisers: [Optimiser]
    var progress: Progress?

    var doneCount: Int
    var failedCount: Int
    var visibleCount: Int

    var body: some View {
        let isTrailing = floatingResultsCorner.isTrailing

        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 5) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                listPanel

                HStack {
                    ToggleCompactResultListButton(showList: $showList, badge: optimisers.count.s, progress: progress)
                        .offset(x: isTrailing ? 10 : -10)
                }
                .frame(width: size.width, alignment: isTrailing ? .trailing : .leading)
            }
        }
        .padding(isTrailing ? .trailing : .leading)
        .onHover { hovered in
            withAnimation(.easeIn(duration: 0.35)) {
                hovering = hovered
            }
        }
        .onChange(of: showList) { showList in
            setSize(showList: showList)
        }
        .onChange(of: optimisers) { optimisers in
            filterOpts(optimisers)
            setSize(count: optimisers.count)
        }
        .onChange(of: showCompactImages) { compactImages in setSize(compactImages: compactImages) }
        .onAppear {
            filterOpts()
            showList = preview || optimisers.count <= 3
            setSize()
        }
    }

    /// The bordered list of results plus its overlays (progress bar, selection action bar), extracted
    /// from `body` to keep each view expression small enough for the Swift type-checker.
    var listPanel: some View {
        ZStack(alignment: .bottom) {
            // No native `selection:` binding: a plain click on a row body must NOT select (it keeps the
            // row's single-item behaviour). Selection happens only through the per-row checkbox (and
            // Select all / ⌘A / shift-click / a whole-row tap once selecting), wired via the row builder.
            List(opts) { opt in
                row(for: opt)
            }
            // Plain style (not bordered) so rows reach the panel edges with no built-in horizontal inset;
            // the alternating background is applied per row instead, and our panel background shows through.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Reserve the footer band (plus the progress strip when busy) so the bar sits below the
            // rows, never over the last one.
            .padding(.bottom, Self.footerBand + (progress == nil ? 0 : 18))
            .frame(width: size.width, height: size.height, alignment: .center)
            .fixedSize()
            .background(Color.inverted.brightness(0.1))
            .if(!sm.selection.isEmpty) {
                $0.contextMenu { BatchRightClickMenuView() }
            }
            .onHover { hovering in
                if !hovering {
                    hoveredOptimiserID = nil
                }
            }
            .onChange(of: sm.selection, perform: onSelectionChanged)
            .background { selectionKeyboardShortcuts }

            listProgressBar

            // One unified, always-visible bottom bar filling the panel width in the reserved footer band:
            // the selection actions while a selection is active, otherwise the drag-all / clear-all bar.
            if !sm.selection.isEmpty {
                CompactSelectionBar()
            } else {
                CompactListBar(optimisers: optimisers, hasRunning: visibleCount > (doneCount + failedCount))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: preview ? 0 : 10)
        .opacity(showList ? 1 : 0)
        .allowsHitTesting(showList)
    }

    /// Hidden buttons that bind ⌘A (select all) and Escape (clear) once the selection has the window key.
    @ViewBuilder var selectionKeyboardShortcuts: some View {
        Button("") { selectAll() }
            .keyboardShortcut("a", modifiers: .command).hidden().disabled(!showList)
        Button("") { sm.selection = [] }
            .keyboardShortcut(.escape, modifiers: []).hidden().disabled(!sm.selecting)
    }

    @ViewBuilder var listProgressBar: some View {
        if progress != nil {
            ProgressView(" Done: \(doneCount)/\(visibleCount)  |  Failed: \(failedCount)/\(visibleCount)", value: (doneCount + failedCount).d, total: visibleCount.d)
                .controlSize(.small)
                .frame(width: THUMB_SIZE.width + (showCompactImages ? 40 : -10))
                .padding(.top, 4)
                .resultsBandBackground(scale: 1.1)
                .offset(y: -Self.footerBand + 4)
                .font(.mono(9))
        }
    }

    /// One list row, extracted from `body` so the type-checker doesn't choke on the combined expression.
    func row(for opt: CompactOptimiser) -> some View {
        CompactResult(
            optimiser: opt.optimiser,
            selecting: sm.selecting,
            selected: opt.selected,
            selectable: !opt.optimiser.running && opt.optimiser.url != nil,
            onToggleSelection: { toggleSelection(opt) }
        )
        .if(!sm.selecting) {
            $0.overlay(
                OverlayMessageView(optimiser: opt.optimiser, color: .inverted)
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            )
        }
        .tag(opt.id)
        .if(!sm.selecting && !opt.optimiser.inRemoval) { view in
            view.contextMenu {
                RightClickMenuView(optimiser: opt.optimiser)
            }
        }
        // Once in selection mode, the whole row toggles (not just the checkbox), which is what list
        // multi-select feels like. The checkbox Button still consumes its own taps, so this only fires
        // for taps elsewhere on the row. (Dragging the file lives on the thumbnail, see CompactResult.)
        .if(sm.selecting) { view in
            view.contentShape(Rectangle()).onTapGesture { toggleSelection(opt) }
        }
        // macOS's plain List/NSTableView keeps a residual horizontal cell inset that an EMPTY EdgeInsets
        // can't fully remove. Counteract it with a small NEGATIVE horizontal inset on the row cell itself
        // (listRowInsets reaches the cell content; an outer .padding on the List does not), so the
        // full-bleed rows reach the panel edges. Rows carry their own internal leading padding (the
        // reserved checkbox column), so this never clips row content.
        .listRowInsets(EdgeInsets(top: 0, leading: -8, bottom: 0, trailing: -8))
        .listRowSeparator(.hidden)
        // Manual alternating background (the plain list style doesn't provide one).
        .listRowBackground(opt.isEven ? Color.primary.opacity(0.04) : Color.clear)
    }

    func filterOpts(_ optimisers: [Optimiser]? = nil) {
        let optimisers = optimisers ?? self.optimisers
        opts = optimisers.isEmpty
            ? []
            : optimisers
                .dropLast().enumerated()
                .map { n, x in
                    CompactOptimiser(optimiser: x, isLast: false, isEven: (n + 1).isMultiple(of: 2), index: n)
                } + [CompactOptimiser(optimiser: optimisers.last!, isLast: true, isEven: optimisers.count.isMultiple(of: 2), index: optimisers.count - 1)]

        // Drop selected ids whose row no longer exists (finished/auto-dismissed/closed), so selection
        // mode can't get stuck on after the rows it referred to are gone.
        let live = Set(opts.map(\.id))
        let pruned = sm.selection.intersection(live)
        if pruned != sm.selection { sm.selection = pruned }
    }

    func setSize(showList: Bool? = nil, count: Int? = nil, compactImages: Bool? = nil) {
        size = NSSize(
            width: (showList ?? self.showList) ? (THUMB_SIZE.width + ((compactImages ?? showCompactImages) ? 50 : 0)) : 50,
            height: (showList ?? self.showList) ? min(360, ((count ?? optimisers.count) * 80).cg) + Self.footerBand : 50
        )
    }

    /// Selection drives the floating window's key state: take key focus when a selection starts (so the
    /// keyboard shortcuts work) and release it when the selection is cleared.
    func onSelectionChanged(_ sel: Set<String>) {
        guard !sel.isEmpty else {
            floatingResultsWindow.allowToBecomeKey = false
            sm.selecting = false
            return
        }
        sm.selecting = true
        if !floatingResultsWindow.allowToBecomeKey {
            floatingResultsWindow.allowToBecomeKey = true
            focus()
            floatingResultsWindow.becomeFirstResponder()
            floatingResultsWindow.makeKeyAndOrderFront(nil)
            floatingResultsWindow.orderFrontRegardless()
        }
    }

    /// Toggle one row's membership (the checkbox action). Holding Shift extends the range from the last
    /// toggled row, matching the usual list multi-select gesture. The anchor is tracked by id (not index)
    /// so it stays correct when the list reorders (results sort newest-first as new ones arrive).
    func toggleSelection(_ opt: CompactOptimiser) {
        guard !opt.optimiser.running, opt.optimiser.url != nil else { return }
        if NSEvent.modifierFlags.contains(.shift), !sm.selection.isEmpty,
           let anchor = opts.first(where: { $0.id == lastSelectedID })?.index
        {
            let lo = min(anchor, opt.index), hi = max(anchor, opt.index)
            let ids = opts.filter { $0.index >= lo && $0.index <= hi && !$0.optimiser.running && $0.optimiser.url != nil }.map(\.id)
            sm.selection.formUnion(ids)
        } else if sm.selection.contains(opt.id) {
            sm.selection.remove(opt.id)
        } else {
            sm.selection.insert(opt.id)
        }
        lastSelectedID = opt.id
    }

    func selectAll() {
        sm.selection = OM.visibleOptimisers.filter { !$0.running && $0.url != nil }.map(\.id).set
    }

    @Environment(\.preview) private var preview
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject private var sm = SM

    @State private var hovering = false
    @State private var showList = false
    @State private var size = NSSize(width: 50, height: 50)
    @State private var opts: [CompactOptimiser] = []
    @State private var hoveringBatchActions = false

    @State private var lastSelectedID: String?

    @Default(.floatingResultsCorner) private var floatingResultsCorner
    @Default(.showCompactImages) private var showCompactImages
    @Default(.keyComboModifiers) private var keyComboModifiers

}

/// Clean rounded thumbnail used as the drag image for a single result, matching the floating result's
/// `dragThumbPreview` (one tile in the "drag all" pile, no badge) instead of a washed-out rectangle.
struct DragPreview: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        Group {
            if let thumb = optimiser.thumbnail {
                SwiftUI.Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.5), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            } else {
                SwiftUI.Image(systemName: optimiser.type.systemImage)
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
    }
}

struct ToggleCompactResultListButton: View {
    @Binding var showList: Bool

    var badge: String
    var progress: Progress?

    var body: some View {
        VStack(spacing: 0) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                Button(
                    action: {
                        showList.toggle()
                        if !showList {
                            hoveredOptimiserID = nil
                        }
                    },
                    label: {
                        ZStack {
                            if !showList, let progress {
                                ProgressView(value: progress.fractionCompleted, total: 1)
                                    .progressViewStyle(.circular)
                                    .controlSize(.regular)
                                    .font(.regular(1))
                                    .background(.thinMaterial)
                                    .clipShape(Circle())
                                Text((progress.totalUnitCount - progress.completedUnitCount).s)
                                    .round(13, weight: .semibold)
                                    .foregroundColor(.primary)
                            } else {
                                Text(badge)
                                    .round(13, weight: .semibold)
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(Color.darkGray))
                            }
                        }
                        .opacity(hovering ? 1 : 0.6)
                    }
                )
                .buttonStyle(FlatButton(color: .clear, textColor: .primary, radius: 7, verticalPadding: 2))

                Text(showList ? "Hide" : "Show")
                    .medium(10)
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

    @State private var hovering = false

    @Default(.floatingResultsCorner) private var floatingResultsCorner

}

@MainActor
struct CompactPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let errorOpt = Optimiser(id: "file-with-error", type: .image(.png))
        errorOpt.url = "\(HOME)/Desktop/passport-scan.png".fileURL
        errorOpt.thumbnail = NSImage(resource: .passport)
        errorOpt.finish(error: "Already optimised")

        let pdfRunning = Optimiser(id: "scans.pdf", type: .pdf, running: true, progress: pdfProgress)
        pdfRunning.url = "\(HOME)/Documents/scans.pdf".fileURL
        pdfRunning.operation = "Optimising"
        pdfRunning.thumbnail = NSImage(resource: .scansPdf)

        let videoOpt = Optimiser(id: "Movies/meeting-recording.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "\(HOME)/Movies/meeting-recording.mov".fileURL
        videoOpt.operation = "Scaling to 50%"
        videoOpt.thumbnail = NSImage(resource: .sonomaVideo)
        videoOpt.changePlaybackSpeedFactor = 2.0

        let videoToGIF = Optimiser(id: "Videos/app-ui-demo.mov", type: .video(.quickTimeMovie), running: true, progress: videoToGIFProgress)
        videoToGIF.url = "\(HOME)/Videos/app-ui-demo.mov".fileURL
        videoToGIF.operation = "Converting to GIF"
        videoToGIF.thumbnail = NSImage(resource: .appUiDemo)

        let pdfEnd = Optimiser(id: "Low-Tech Whistle.pdf", type: .pdf)
        pdfEnd.thumbnail = NSImage(resource: .previewPdfThumb)
        pdfEnd.finish(oldBytes: 12_250_190, newBytes: 15_211_932)

        let audioEnd = Optimiser(id: "Evening guitar.m4a", type: .audio(.mpeg4Audio))
        audioEnd.url = "\(HOME)/Music/Evening guitar.m4a".fileURL
        audioEnd.thumbnail = NSImage(resource: .guitarCover)
        audioEnd.coverArtSize = CGSize(width: 1012, height: 1012)
        audioEnd.finish(oldBytes: 2_834_000, newBytes: 1_027_608, oldBitrate: 256, newBitrate: 96)

        let gifOpt = Optimiser(id: "https://files.lowtechguys.com/moon.gif", type: .url, running: true, progress: gifProgress)
        gifOpt.url = "https://files.lowtechguys.com/moon.gif".url!
        gifOpt.operation = "Downloading"

        let pngIndeterminate = Optimiser(id: "png-indeterminate", type: .image(.png), running: true)
        pngIndeterminate.url = "\(HOME)/Desktop/device_hierarchy.png".fileURL
        pngIndeterminate.thumbnail = NSImage(resource: .deviceHierarchy)
        pngIndeterminate.operation = "Scaling to 50%"

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.webP))
        clipEnd.thumbnail = NSImage(resource: .previewImageThumb)
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: NSSize(width: 1880, height: 1000), newSize: NSSize(width: 1200, height: 600))

        let proErrorOpt = Optimiser(id: Optimiser.IDs.pro, type: .unknown)
        proErrorOpt.isPreview = true
        proErrorOpt.finish(error: "You've optimised 5 files this session", notice: "Get Clop Pro to remove the limit and unlock all features.\nRelaunch the app to reset the counter.")

        let noticeOpt = Optimiser(id: "notice", type: .unknown, operation: "")
        noticeOpt.finish(notice: "**Paused**\nNext clipboard event will be ignored")

        // Record which bundled sample backs each finished card; the temp files are only written when
        // the Floating Results settings tab appears (materializeSamples), to avoid I/O on launch.
        CompactPreview.sampleSpecs = [
            (clipEnd, "preview-sample-image", "downscale-images.webp"),
            (pdfEnd, "preview-sample-pdf", "Low-Tech Whistle.pdf"),
            (audioEnd, "preview-sample-audio", "Evening guitar.m4a"),
        ]

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
            audioEnd,
            videoToGIF,
        ]
        for opt in o.optimisers {
            opt.isPreview = true
        }
        mainActor {
            o.updateProgress()
            o.visibleCount = o.visibleOptimisers.count
            o.doneCount = o.visibleOptimisers.filter { !$0.running && $0.error == nil }.count
            o.failedCount = o.visibleOptimisers.filter { !$0.running && $0.error != nil }.count
            SM.selectableCount = o.visibleOptimisers.filter { !$0.running && $0.url != nil }.count
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

struct CompactResult_Previews: PreviewProvider {
    static var previews: some View {
        CompactPreview()
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

@MainActor
struct CompactPreviewAllStates: View {
    static var om: OptimisationManager = {
        let o = CompactPreview.om
        let proErrorOpt = Optimiser(id: Optimiser.IDs.pro, type: .unknown)
        proErrorOpt.isPreview = true
        proErrorOpt.finish(error: "You've optimised 5 files this session", notice: "Get Clop Pro to remove the limit and unlock all features.\nRelaunch the app to reset the counter.")
        o.optimisers.insert(proErrorOpt)
        mainActor {
            o.failedCount += 1
            o.visibleCount += 1
        }
        return o
    }()

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }
}

struct CompactResultAllStates_Previews: PreviewProvider {
    static var previews: some View {
        CompactPreviewAllStates()
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            .previewDisplayName("All States")
    }
}
