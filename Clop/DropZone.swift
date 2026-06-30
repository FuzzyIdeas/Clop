import Defaults
import Foundation
import Lowtech
import os
import SwiftUI
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "DropZone")
let MAC26 = if #available(macOS 26.0, *) {
    true
} else {
    false
}

class DragManager: ObservableObject {
    @MainActor @Published var dragHovering = false
    @MainActor @Published var itemsToOptimise: [ClipboardType] = []
    @Atomic var optimisationCount = 0

    @MainActor @Published var dropZoneAtCursor = false

    @MainActor var fileType: ClopFileType? {
        itemsToOptimise.allSatisfy(\.isImage)
            ? .image
            : itemsToOptimise.allSatisfy(\.isVideo)
                ? .video
                : itemsToOptimise.allSatisfy(\.isAudio)
                    ? .audio
                    : itemsToOptimise.allSatisfy(\.isPDF) ? .pdf : nil
    }

    @MainActor @Published var dropped = true {
        didSet {
            dropZoneKeyGlobalMonitor.stop()
            dropZoneKeyLocalMonitor.stop()
            presetZonesKeyGlobalMonitor.stop()
            presetZonesKeyLocalMonitor.stop()
            DM.showDropZone = false
            DM.showPresetZones = false
        }
    }

    @MainActor @Published var showPresetZones = false {
        didSet {
            guard showPresetZones != oldValue else {
                return
            }
            if showPresetZones {
                log.debug("Control pressed, showing preset zones")
            } else {
                log.debug("Control pressed, hiding preset zones")
            }
        }
    }

    @MainActor @Published var showDropZone = false {
        didSet {
            guard showDropZone != oldValue else {
                return
            }
            if showDropZone {
                log.debug("Option pressed, showing drop zone")
                if dropZoneAtCursor {
                    showFloatingThumbnailsAtCursor()
                } else {
                    showFloatingThumbnails()
                }
            } else {
                log.debug("Option pressed, hiding drop zone")
                hideCursorDropZone()
                dropZoneAtCursor = false
                if !Defaults[.enableFloatingResults], floatingResultsWindow.isVisible {
                    floatingResultsWindow.close()
                }
            }
        }
    }
    @MainActor @Published var dragging = false {
        didSet {
            guard dragging != oldValue else {
                return
            }
            if dragging, !Defaults[.onlyShowDropZoneOnOption] {
                showDropZone = true
            }
        }
    }
}

@MainActor
let DM = DragManager()

private struct ZonePreviewHoverModifier: ViewModifier {
    let preview: Bool
    let disabled: Bool
    let index: Int
    let zone: PresetZone?

    @Binding var selectedPresetIndex: Int?
    @Binding var selectedPreset: PresetZone?

    func body(content: Content) -> some View {
        if preview {
            content
                .onHover { h in
                    if h {
                        withAnimation(.bouncy) {
                            selectedPresetIndex = index
                            selectedPreset = zone
                        }
                    }
                }
                .disabled(disabled)
                .onHover { h in
                    if h, disabled {
                        withAnimation(.bouncy) {
                            selectedPresetIndex = nil
                            selectedPreset = nil
                        }
                    }
                }
        } else {
            content
        }
    }
}

private struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

extension View {
    func glassBackground(in shape: some Shape) -> some View {
        modifier(GlassBackground(shape: shape))
    }

    func dropZoneGlassBackground() -> some View {
        glassBackground(in: DROPZONE_SHAPE)
    }
}

struct DropZonePresetsViewDelegate: DropDelegate {
    let preset: PresetZone?
    let isNextPreset: Bool
    let onHover: ((Bool) -> Void)?

    func dropEntered(info: DropInfo) {
        withAnimation(.bouncy) {
            DM.dragHovering = true
            onHover?(true)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropExited(info: DropInfo) {
        withAnimation(.bouncy) {
            DM.dragHovering = false
            onHover?(false)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        DM.dragHovering = false
        DM.dropped = true

        guard let preset else {
            if isNextPreset {
                settingsViewManager.tab = .presetZones
                WM.open("settings")
                focus()
            }
            return false
        }

        if DM.optimisationCount == 5 {
            DM.optimisationCount += 1
        }
        return optimiseDroppedItems(info.itemProviders(for: IMAGE_FORMATS + AUDIO_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf]), copy: NSEvent.modifierFlags.contains(.option), preset: preset)
    }
}

struct DropZonePresetsView: View {
    var type: ClopFileType?

    @Default(.presetZones) var presetZones
    @Default(.enableDragAndDrop) var enableDragAndDrop
    @Default(.savedPipelines) var savedPipelines

    @State var imagePresetZones: [PresetZone] = []
    @State var videoPresetZones: [PresetZone] = []
    @State var audioPresetZones: [PresetZone] = []
    @State var pdfPresetZones: [PresetZone] = []
    @State var anyFilePresetZones: [PresetZone] = []
    @Environment(\.preview) var preview
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var dragManager = DM
    @ObservedObject var keysManager = KM

    @State var selectedPresetIndex: Int?
    @Binding var selectedPreset: PresetZone?

    /// Library pipelines that can be assigned to a zone of this section's file type (type-specific or any).
    var applicableLibraryPipelines: [Pipeline] {
        savedPipelines.filter { p in
            guard let n = p.name, !n.isEmpty else { return false }
            return p.fileType == nil || p.fileType == type
        }
    }

    var presetZoneArray: [PresetZone] {
        switch type {
        case .image:
            imagePresetZones
        case .video:
            videoPresetZones
        case .audio:
            audioPresetZones
        case .pdf:
            pdfPresetZones
        default:
            anyFilePresetZones
        }
    }

    var cmdPressed: Bool {
        keysManager.lcmd || keysManager.rcmd
    }

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                zoneView(index: 0)
                zoneView(index: 1)
            }
            GridRow {
                zoneView(index: 2)
                zoneView(index: 3)
            }
        }
        .onHover { h in
            if !h {
                withAnimation(.bouncy) {
                    selectedPresetIndex = nil
                    selectedPreset = nil
                }
            }
        }
        .onAppear { cachePresetZones() }
        .onChange(of: presetZones) { _ in cachePresetZones() }

    }

    func zoneIcon(systemName: String) -> some View {
        SwiftUI.Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .padding(6)
//            .background(
//                roundRect(5, fill: .bg.warm.opacity(colorScheme == .dark ? 0.6 : 0.4))
//                    .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 4)
//            )
    }

    /// Native menu shown when a zone is clicked in the settings preview: assign an existing pipeline, create
    /// a new one (opens the inline editor row), or edit/remove the current one. Replaces the old sheet.
    @ViewBuilder
    func zoneMenuContent(zone: PresetZone?) -> some View {
        if let zone {
            Button("Edit pipeline") { settingsViewManager.editingPresetZoneID = zone.id }
            if zone.pipeline.isLibraryReference, let libID = zone.pipeline.libraryID {
                Button("Go to pipeline") {
                    settingsViewManager.tab = .pipelines
                    settingsViewManager.highlightPipelineID = libID
                }
            }
            if !applicableLibraryPipelines.isEmpty {
                Menu("Replace with") {
                    ForEach(applicableLibraryPipelines) { lib in
                        Button { assignPresetZone(library: lib, type: zone.type, replacing: zone) } label: { libMenuLabel(lib) }
                    }
                }
            }
            Divider()
            Button("Create new \(typeLabel(type)) pipeline") { settingsViewManager.editingPresetZoneID = appendPresetZone(type: type) }
            Divider()
            Button("Remove from zone", role: .destructive) { removePresetZone(zone) }
        } else {
            if !applicableLibraryPipelines.isEmpty {
                Section("Assign existing pipeline") {
                    ForEach(applicableLibraryPipelines) { lib in
                        Button { assignPresetZone(library: lib, type: type) } label: { libMenuLabel(lib) }
                    }
                }
                Divider()
            }
            Button("Create new \(typeLabel(type)) pipeline") { settingsViewManager.editingPresetZoneID = appendPresetZone(type: type) }
        }
    }

    /// Menu row for a library pipeline: icon + name + description subtitle. Every row uses the same
    /// layout: a default icon ("wand.and.sparkles") and a "No description" subtitle stand in for
    /// pipelines that lack them, so the menu never looks ragged. Because a subtitle is always present,
    /// we always use the title+subtitle form: SwiftUI's Menu strips a `Label`'s icon slot inside a
    /// nested submenu ("Replace with") but DOES render an SF Symbol interpolated into the title Text,
    /// and the subtitle Text must be a SIBLING of the title (stacks get flattened/ignored).
    @ViewBuilder
    func libMenuLabel(_ lib: Pipeline) -> some View {
        let symbol = lib.icon.flatMap { $0.isEmpty ? nil : $0 } ?? "wand.and.sparkles"
        let subtitle = lib.details.flatMap { $0.isEmpty ? nil : $0 } ?? "No description"
        Text("\(SwiftUI.Image(systemName: symbol))  \(lib.name ?? lib.id)")
        Text(subtitle)
    }

    @ViewBuilder
    func zoneLabel(zone: PresetZone?, nextPreset: Bool, hovered: Bool, index: Int) -> some View {
        let isLeft = index % 2 == 0

        VStack(spacing: 2) {
            zoneIcon(systemName: zone.map(\.icon) ?? (nextPreset ? "plus.square.dashed" : "square.dashed"))
                .rotation3DEffect(.degrees(hovered ? 170 : 0), axis: (x: 0, y: 1, z: 0), perspective: 1.2)

            Text(zone.map(\.name) ?? (nextPreset ? "Add preset" : "No preset"))
                .round(10)
                .foregroundColor(nextPreset ? .fg.warm.opacity(0.7) : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .frame(width: DROPZONE_SIZE.width / 2, height: 14)
        }
        .frame(width: DROPZONE_SIZE.width / 2 - 2, height: DROPZONE_SIZE.height / 2)
        .padding(.vertical, 4)
        .padding(isLeft ? .trailing : .leading, 4)
        // Make the whole quadrant the hit target (so the menu opens anywhere on the zone, not just on the
        // icon/label pixels).
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func zoneView(index: Int) -> some View {
        let zone = presetZoneArray[safe: index]
        let nextPreset = presetZoneArray.count == index
        let disabled = !nextPreset && zone == nil
        let hovered = selectedPresetIndex == index

        Group {
            if preview, !disabled {
                // In the settings preview the zone itself IS the add/remove/edit surface: a native menu.
                Menu {
                    zoneMenuContent(zone: zone)
                } label: {
                    zoneLabel(zone: zone, nextPreset: nextPreset, hovered: hovered, index: index)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            } else {
                Button(action: { zoneAction(zone: zone) }) {
                    zoneLabel(zone: zone, nextPreset: nextPreset, hovered: hovered, index: index)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
        .modifier(ZonePreviewHoverModifier(
            preview: preview, disabled: disabled, index: index, zone: zone,
            selectedPresetIndex: $selectedPresetIndex, selectedPreset: $selectedPreset
        ))
        .background {
            (cmdPressed ? Color.red : Color.peach).opacity(hovered ? 0.3 : 0.0)
                .clipShape(DROPZONE_SHAPE)
        }

        .if(enableDragAndDrop && !preview) {
            $0.dropZoneGlassBackground()
                .onDrop(
                    of: IMAGE_FORMATS + VIDEO_FORMATS + AUDIO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf],
                    delegate: DropZonePresetsViewDelegate(preset: zone, isNextPreset: nextPreset) { h in
                        selectedPresetIndex = h && !disabled ? index : nil
                        selectedPreset = h && !disabled ? zone : nil
                    }
                )
                .background(DragPileView().fill(.center))
        }
    }

    /// Used by the real floating drop zone (not the settings preview): jump to the Preset Zones tab and,
    /// if a specific zone was clicked, open its editor row there.
    func zoneAction(zone: PresetZone?) {
        settingsViewManager.tab = .presetZones
        WM.open("settings")
        focus()
        if let zone { settingsViewManager.editingPresetZoneID = zone.id }
    }

    func typeLabel(_ t: ClopFileType?) -> String {
        t.map { $0 == .pdf ? "PDF" : $0.description } ?? "any-type"
    }

    func cachePresetZones() {
        imagePresetZones = []
        videoPresetZones = []
        audioPresetZones = []
        pdfPresetZones = []
        anyFilePresetZones = []

        for presetZone in presetZones {
            switch presetZone.type {
            case .image:
                imagePresetZones.append(presetZone)
            case .video:
                videoPresetZones.append(presetZone)
            case .audio:
                audioPresetZones.append(presetZone)
            case .pdf:
                pdfPresetZones.append(presetZone)
            case nil:
                anyFilePresetZones.append(presetZone)
            }
        }
        // Only any-type zones (type == nil) belong in every section; type-specific zones stay in their own.
        imagePresetZones += anyFilePresetZones
        videoPresetZones += anyFilePresetZones
        audioPresetZones += anyFilePresetZones
        pdfPresetZones += anyFilePresetZones
    }
}

struct DropZoneView: View {
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.enableDragAndDrop) var enableDragAndDrop

    @ObservedObject var dragManager = DM
    @ObservedObject var keysManager = KM
    @Environment(\.preview) var preview
    @Environment(\.colorScheme) var colorScheme

    @State var rotation: Angle = .degrees(0)
    @State var hovering = false
    @State var selectedPreset: PresetZone? = nil

    var presetFileType: ClopFileType?

    var ctrlPressed: Bool {
        keysManager.lctrl || keysManager.rctrl
    }
    var cmdPressed: Bool {
        keysManager.lcmd || keysManager.rcmd
    }

    var hoverState: Bool {
        (preview ? hovering : dragManager.dragHovering) || dragManager.showPresetZones || presetFileType != nil
    }

    var draggingOutsideView: some View {
        VStack {
            if dragManager.showPresetZones || presetFileType != nil {
                DropZonePresetsView(type: presetFileType ?? dragManager.fileType, selectedPreset: $selectedPreset)
            } else {
                Text("Drop to optimise")
                    .round(14, weight: .heavy)
                    .padding(.top, 10)

                SwiftUI.Image(systemName: "livephoto")
                    .font(.bold(36))
                    .foregroundStyle(colorScheme == .dark ? Color.orange : Color.hotRed)
                    .padding(1)
                    .rotationEffect(rotation)
                    .onChange(of: hoverState) { hovering in
                        if hovering {
                            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                                rotation = .degrees(359)
                            }
                        } else {
                            withAnimation(.spring) {
                                rotation = .degrees(0)
                            }
                        }
                    }

                VStack(spacing: -1) {
                    Text("^: show preset zones")
                        .medium(10)
                        .foregroundColor(.primary)
                        .opacity(0.8)
                    Text(dragManager.dropZoneAtCursor ? "⌥: hide drop zone" : "⌥: show drop zone at cursor")
                        .medium(10)
                        .foregroundColor(.primary)
                        .opacity(0.8)
                    Text("⌘: use aggressive optimisation")
                        .medium(10)
                        .foregroundColor(keysManager.flags.sideIndependentModifiers.contains(.command) ? .red : .primary)
                        .opacity(0.8)
                        .padding(.bottom, 6)
                }
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .fixedSize()
            }
        }
        .frame(
            width: DROPZONE_SIZE.width,
            height: DROPZONE_SIZE.height,
            alignment: .center
        )
        .opacity(hoverState ? 1.0 : 0.85)
        .animation(.easeOut, value: hoverState)
        .padding(.horizontal, DROPZONE_PADDING.width)
        .padding(.vertical, DROPZONE_PADDING.height)
        .overlay {
            if !dragManager.showPresetZones {
                DROPZONE_SHAPE.stroke(Color.bg.primary.opacity(0.1), lineWidth: 4)
                    .shadow(color: colorScheme == .dark ? Color.orange : Color.hotRed, radius: 3)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(hoverState ? 1.02 : 1.0)
        .onHover { hovering in
            self.hovering = hovering
        }
    }

    var body: some View {
        HStack {
            draggingOutsideView
                .if(!dragManager.showPresetZones) {
                    $0.dropZoneGlassBackground()
                }
                .contentShape(Rectangle())
        }
        .frame(width: FloatingResult.cardW, height: FloatingResult.cardH, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
        .padding()
        .fixedSize()
        .onChange(of: ctrlPressed) { ctrlPressed in
            if !Defaults[.onlyShowPresetZonesOnControlTapped] {
                dragManager.showPresetZones = ctrlPressed
            }
        }
        .onChange(of: dragManager.showPresetZones) { showing in
            // Clear any stale preset selection when preset zones hide, so a
            // subsequent drop on the main zone doesn't inherit it.
            if !showing {
                selectedPreset = nil
            }
        }
        .if(enableDragAndDrop && !preview && !dragManager.showPresetZones) {
            $0.onDrop(of: IMAGE_FORMATS + VIDEO_FORMATS + AUDIO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf], delegate: self)
                .background(DragPileView().fill(.center))
        }
    }
}

let HAT_ICON_SIZE: CGFloat = 30
let DROPZONE_PADDING = CGSize(width: 14, height: 10)
// Match the floating result thumbnail card footprint (cardW × cardH); the inner content frame is
// the card size minus the dropzone's own padding so the bordered box ends up the same size.
let DROPZONE_SIZE = CGSize(width: FloatingResult.cardW - DROPZONE_PADDING.width * 2, height: FloatingResult.cardH - DROPZONE_PADDING.height * 2)
let DROPZONE_SHAPE = RoundedRectangle(cornerRadius: 22, style: .continuous)

extension DropZoneView: DropDelegate {
    func dropEntered(info: DropInfo) {
        withAnimation(.jumpySpring) {
            dragManager.dragHovering = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropExited(info: DropInfo) {
        withAnimation(.jumpySpring) {
            dragManager.dragHovering = false
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragManager.dragHovering = false
        dragManager.dropped = true
        if dragManager.optimisationCount == 5 {
            dragManager.optimisationCount += 1
        }

        let thumbnails: [NSItemProvider] = info.hasItemsConforming(to: VIDEO_FORMATS) ? info.itemProviders(for: IMAGE_FORMATS) : []
        let filenames: [NSItemProvider] = info.itemProviders(for: [.url, .fileURL, .aliasFile])
        let itemProviders = if info.hasItemsConforming(to: VIDEO_FORMATS) {
            info.itemProviders(for: VIDEO_FORMATS + [.url])
        } else if info.hasItemsConforming(to: IMAGE_FORMATS) {
            info.itemProviders(for: IMAGE_FORMATS + [.url])
        } else {
            info.itemProviders(for: [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf])
        }
        // Main drop zone: onDrop is gated on !showPresetZones, so this only
        // fires when the user dropped on the main area. selectedPreset may
        // still be stale from a prior preset zone drop, so ignore it here.
        return optimiseDroppedItems(itemProviders, copy: NSEvent.modifierFlags.contains(.option), preset: nil, thumbnails: thumbnails, filenames: filenames)
    }
}

class NSDragPile: NSView {
    var dragView: NSView? {
        superview?.superview?.subviews.first(where: { $0.className.contains("DraggingDestinationView") })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard identifier == nil, let dragView,
              let cls = object_getClass(dragView),
              let dragEnt = class_getInstanceMethod(cls, #selector(NSDraggingDestination.draggingEntered(_:)))
        else { return }

        let dragEnt2 = class_getInstanceMethod(object_getClass(self), #selector(NSDraggingDestination.draggingEntered(_:)))!
        method_exchangeImplementations(dragEnt, dragEnt2)
        identifier = .init("dragPile")
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingFormation = .pile
        return sender.draggingSourceOperationMask.intersection([.copy, .move])
    }
}
struct DragPileView: NSViewRepresentable {
    func updateNSView(_ nsView: NSDragPile, context: Context) {}

    func makeNSView(context: Context) -> NSDragPile {
        NSDragPile()
    }
}

/// Run the preset pipeline on the result of `optimiseItem`, matching the pattern in `optimiseFile`.
@MainActor
private func runPresetPipeline(_ pipeline: Pipeline?, result: ClipboardType?, id: String) async {
    guard let pipeline, !pipeline.isEmpty, let result, let optimiser = opt(id) else { return }
    let path = result.path
    let fileType: ClopFileType = path.isImage ? .image : path.isVideo ? .video : path.isPDF ? .pdf : .audio
    do {
        let (resultFile, _, _) = try await executePipeline(pipeline, file: path, source: .dropZone, optimiser: optimiser, fileType: fileType)
        if resultFile != path {
            optimiser.url = resultFile.url
            optimiser.type = .from(filePath: resultFile)
            if let newSize = resultFile.fileSize() {
                optimiser.newBytes = newSize
            }
        }
    } catch {
        log.error("Pipeline: preset pipeline failed: \(error)")
    }
}

/// If `pipeline` already contains an encoding step (optimise, downscale,
/// lowerBitrate, convert, crop, extractPagesAsImages), skip the implicit
/// pre-optimise and run the pipeline directly on `path`. Returns true when
/// the short-circuit was applied so callers should skip their normal
/// `optimiseItem` flow. Otherwise the underlying tools (ffmpeg, pngquant,
/// ghostscript, vips) would run twice: once for the default optimise pass
/// and again for the pipeline's own processing step. For audio this is an
/// audible quality regression; for video a silent quality loss; for images
/// and PDFs wasted CPU.
@MainActor
private func skipOptimiseAndRunPipelineIfEncoding(
    _ pipeline: Pipeline?,
    path: FilePath,
    id: String? = nil,
    source: OptimisationSource?,
    prepare: @MainActor (Optimiser) async -> Void = { _ in }
) async -> Bool {
    guard let pipeline, !pipeline.isEmpty, let source,
          pipeline.steps.contains(where: \.isProcessingStep)
    else { return false }

    let fileType: ClopFileType = path.isImage ? .image : path.isVideo ? .video : path.isPDF ? .pdf : .audio
    let optimiser = OM.optimiser(
        id: id ?? path.string,
        type: ItemType.from(filePath: path),
        operation: "Running pipeline",
        hidden: false,
        source: source
    )
    optimiser.url = path.url

    // Preload audio metadata so the floating result UI can show bitrate
    // immediately. Other types have their metadata populated by the
    // pipeline functions themselves during the first processing step.
    if fileType == .audio {
        let audio = await (try? Audio.byFetchingMetadata(path: path, thumb: true)) ?? Audio(path: path, thumb: true)
        optimiser.audio = audio
    }

    await prepare(optimiser)

    do {
        let (resultFile, shownVisible, didWork) = try await executePipeline(
            pipeline, file: path, source: source, optimiser: optimiser, fileType: fileType
        )
        // Finalize the parent optimiser. With the single-card model the pipeline steps render
        // into this same optimiser, so it IS the result; just make sure it's settled and not
        // left showing progress.
        if shownVisible {
            // Steps rendered into this card (it morphed through the pipeline). The last
            // renderable step already finished it; settle it if anything left it running.
            if optimiser.running { optimiser.finish(notice: "Pipeline completed") }
        } else if didWork, isRenderableResult(resultFile, from: path) {
            // No step surfaced a result and the pipeline produced a renderable file: turn
            // the parent into the result.
            let oldSize = path.fileSize() ?? 0
            let newSize = resultFile.fileSize() ?? 0
            optimiser.url = resultFile.url
            optimiser.type = .from(filePath: resultFile)
            if let img = NSImage(contentsOf: resultFile.url) {
                optimiser.thumbnail = img
            }
            optimiser.finish(oldBytes: oldSize, newBytes: newSize)
        } else {
            // No step rendered a result (a no-op crop/downscale already within target, an unmet
            // filter, or a side-effect-only pipeline): still show the dropped file with its size +
            // resolution so the drop always gives feedback; only remove if it can't be rendered.
            if !optimiser.showAsUnchanged(file: resultFile) {
                optimiser.remove(after: 0)
            }
        }
    } catch {
        log.error("Pipeline: preset pipeline failed: \(error)")
        optimiser.finish(error: "Pipeline failed")
    }
    return true
}

@MainActor
func optimiseDroppedItems(_ itemProviders: [NSItemProvider], copy: Bool, preset: PresetZone? = nil, thumbnails: [NSItemProvider] = [], filenames: [NSItemProvider] = []) -> Bool {
    DM.dragging = false
    var thumbnails = thumbnails
    var filenames = filenames

    let aggressive = NSEvent.modifierFlags.contains(.command) ? true : nil
    let pipeline = preset?.resolvedPipeline
    let hasItemsToOptimise = itemProviders.contains { provider in
        (IMAGE_FORMATS + VIDEO_FORMATS + AUDIO_FORMATS).contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    } || DM.itemsToOptimise.isNotEmpty

    var output: String? = nil
    if copy {
        let url = URL.temporaryDirectory.appendingPathComponent("clop-dropzone-\(Int.random(in: 1000 ... 10_000_000))", conformingTo: .directory)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        // Keep the original filename inside the temp copy dir (`%f` is the stem; the extension is
        // appended automatically). A bare directory template resolves to the dir's own random name,
        // so the result would otherwise lose the source name.
        output = url.appendingPathComponent("%f").path
    }

    let itemsToOptimise = DM.itemsToOptimise
    let itemProvidersCount = itemProviders.count
    let copyToClipboard = Defaults[.autoCopyToClipboard]

    // Batch mode: a large pile of dropped files goes to the lightweight engine + window instead of one
    // floating result each. SwiftUI hands image/video file drops back as content-typed providers
    // (e.g. `public.png`) in `itemProviders`, NOT `public.file-url`, so detect and resolve the pile via
    // the parallel `filenames` providers, which carry the file URLs. A single folder isn't caught here
    // (it goes through optimiseFile → optimiseDir, which has its own batch routing).
    let droppedFileProviders = filenames.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    if Defaults[.useBatchModeForFolders], droppedFileProviders.count > Defaults[.batchModeFileCountThreshold] {
        // Optimising more files than the batch threshold in one drop is a Pro feature: surface a
        // visible Pro error instead of silently optimising the whole pile one-by-one for free.
        guard proactive else {
            let optimiser = OM.optimiser(id: Optimiser.IDs.pro, type: .unknown, operation: "")
            optimiser.finish(
                error: "Batch optimisation is a Pro feature",
                notice: "Get Clop Pro to optimise large drops in one window,\nor drop fewer than \(Defaults[.batchModeFileCountThreshold]) files at a time.",
                keepFor: 7000
            )
            return true
        }
        tryAsync {
            var paths: [FilePath] = []
            for provider in droppedFileProviders {
                guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                      let path = item.existingFilePath else { continue }
                if path.isDir {
                    // Folders arrive as file URLs and pass the gate, but the batch scanner only keeps
                    // real media files, so expand each folder into its contents (else the batch is empty
                    // and nothing gets optimised). Scan off the main actor so a deep/slow tree (e.g. a
                    // network volume) doesn't beachball the UI before the window opens.
                    let dirURL = path.url
                    let expanded = await Task.detached {
                        getURLsFromFolder(dirURL, recursive: true, types: ALL_FORMATS).compactMap(\.existingFilePath)
                    }.value
                    paths.append(contentsOf: expanded)
                } else {
                    paths.append(path)
                }
            }
            guard !paths.isEmpty else { return }
            BAT.prepare(paths: paths, source: .dropZone)
            BAT.showWindow()
        }
        return true
    }

    // Free tier is limited to 5 optimisations. Optimising more than that in a single drop is a Pro
    // feature: gate it here, synchronously, before fanning each file out into its own concurrent task
    // (whose per-file proGuard count can't enforce a limit across concurrent tasks). A handful of
    // files still goes through for free.
    let droppedItemCount = max(itemProvidersCount, droppedFileProviders.count)
    if !proactive, droppedItemCount > 5 {
        let optimiser = OM.optimiser(id: Optimiser.IDs.pro, type: .unknown, operation: "")
        optimiser.finish(
            error: "Optimising more than 5 files at once is a Pro feature",
            notice: "Get Clop Pro to remove the limit,\nor drop 5 or fewer files at a time.",
            keepFor: 7000
        )
        return true
    }

    for itemProvider in itemProviders {
        log.debug("Dropped itemProvider types: \(itemProvider.registeredTypeIdentifiers)")

        for identifier in itemProvider.registeredTypeIdentifiers {
            switch identifier {
            case [UTType.fileURL.identifier, UTType.aliasFile.identifier]:
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, pipeline: preset?.resolvedPipeline)
                }
            case UTType.pdf.identifier:
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, pipeline: preset?.resolvedPipeline)
                }
            case IMAGE_FORMATS.map(\.identifier):
                tryAsync {
                    let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier)
                    let path = item?.existingFilePath
                    let data = item as? Data
                    let nsImage = item as? NSImage ?? (data != nil ? NSImage(data: data!) : nil)

                    if path == nil, data == nil, nsImage == nil, itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                        if case let .image(img) = item,
                           await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: img.path, id: item.id, source: .dropZone, prepare: { $0.image = img })
                        {
                            return
                        }
                        if case let .file(filePath) = item,
                           await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: filePath, id: item.id, source: .dropZone)
                        {
                            return
                        }
                        let result = try await optimiseItem(
                            item,
                            id: item.id,
                            aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                            optimisationCount: &DM.optimisationCount,
                            copyToClipboard: copyToClipboard,
                            source: .dropZone,
                            output: output,
                            skipPipelineLookup: pipeline != nil
                        )
                        await runPresetPipeline(pipeline, result: result, id: item.id)
                        return
                    }

                    // Constructing an Image reads the whole file into memory and decodes it; do that
                    // off the main thread so a large image or a slow/network volume doesn't block the
                    // main thread for tens of seconds and trip the ANR watchdog.
                    guard let image = await Task.detached(operation: {
                        Image(
                            path: path, data: nsImage != nil ? data : nil, nsImage: nsImage,
                            type: UTType(identifier), optimised: false, retinaDownscaled: false
                        )
                    }).value else {
                        return
                    }

                    if await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: image.path, source: .dropZone, prepare: { $0.image = image }) {
                        return
                    }

                    let result = try await optimiseItem(
                        .image(image),
                        id: image.path.string,
                        aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                        optimisationCount: &DM.optimisationCount,
                        copyToClipboard: copyToClipboard,
                        source: .dropZone,
                        output: output,
                        skipPipelineLookup: pipeline != nil
                    )
                    await runPresetPipeline(pipeline, result: result, id: image.path.string)
                }
            case VIDEO_FORMATS.map(\.identifier):
                tryAsync {
                    let optimiser = OM.optimiser(id: itemProvider.description, type: .video(itemProvider.registeredContentTypes.first ?? .mpeg4Movie), operation: "Loading", hidden: !Defaults[.enableFloatingResults], source: .dropZone)
                    if thumbnails.isNotEmpty {
                        let thumbnail = try? await thumbnails.removeFirst().loadItem(forTypeIdentifier: UTType.jpeg.identifier, options: [NSItemProviderPreferredImageSizeKey: NSValue(size: CGSize(width: 100, height: 100))])
                        if let nsImage = (thumbnail as? NSImage) {
                            optimiser.thumbnail = nsImage
                        } else if let data = (thumbnail as? Data), let nsImage = NSImage(data: data) {
                            optimiser.thumbnail = nsImage
                        } else if let url = thumbnail as? URL, let nsImage = NSImage(contentsOf: url) {
                            optimiser.thumbnail = nsImage
                        }
                    }
                    if filenames.isNotEmpty {
                        let filenameProvider = filenames.removeFirst()
                        var filename = try? await filenameProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        if filename == nil {
                            filename = try? await filenameProvider.loadItem(forTypeIdentifier: UTType.url.identifier)
                        }
                        if let url = filename as? URL {
                            optimiser.url = url
                        } else if let str = filename as? String, let url = URL(string: str) {
                            optimiser.url = url
                        }
                    }

                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        optimiser.remove(after: 0)
                        if itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                            if case let .file(filePath) = item,
                               await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: filePath, id: item.id, source: .dropZone)
                            {
                                return
                            }
                            let result = try await optimiseItem(
                                item,
                                id: item.id,
                                aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                                optimisationCount: &DM.optimisationCount,
                                copyToClipboard: copyToClipboard,
                                source: .dropZone,
                                output: output,
                                skipPipelineLookup: pipeline != nil
                            )
                            await runPresetPipeline(pipeline, result: result, id: item.id)
                        }
                        return
                    }
                    optimiser.remove(after: 0)
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, pipeline: preset?.resolvedPipeline)
                }
            case AUDIO_FORMATS.map(\.identifier):
                tryAsync {
                    let audioType = itemProvider.registeredContentTypes.first(where: { AUDIO_FORMATS.contains($0) }) ?? .mp3
                    let optimiser = OM.optimiser(id: itemProvider.description, type: .audio(audioType), operation: "Loading", hidden: !Defaults[.enableFloatingResults], source: .dropZone)
                    if filenames.isNotEmpty {
                        let filenameProvider = filenames.removeFirst()
                        var filename = try? await filenameProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        if filename == nil {
                            filename = try? await filenameProvider.loadItem(forTypeIdentifier: UTType.url.identifier)
                        }
                        if let url = filename as? URL {
                            optimiser.url = url
                        } else if let str = filename as? String, let url = URL(string: str) {
                            optimiser.url = url
                        }
                    }

                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        optimiser.remove(after: 0)
                        if itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                            if case let .file(filePath) = item,
                               await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: filePath, id: item.id, source: .dropZone)
                            {
                                return
                            }
                            let result = try await optimiseItem(
                                item,
                                id: item.id,
                                aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                                optimisationCount: &DM.optimisationCount,
                                copyToClipboard: copyToClipboard,
                                source: .dropZone,
                                output: output,
                                skipPipelineLookup: pipeline != nil
                            )
                            await runPresetPipeline(pipeline, result: result, id: item.id)
                        }
                        return
                    }
                    optimiser.remove(after: 0)
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, pipeline: preset?.resolvedPipeline)
                }
            case [UTType.plainText.identifier, UTType.utf8PlainText.identifier]:
                tryAsync {
                    let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier)
                    if let path = item?.existingFilePath, path.isImage || path.isVideo || path.isAudio {
                        if await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: path, source: .dropZone) {
                            return
                        }
                        let result = try await optimiseItem(
                            .file(path),
                            id: path.string,
                            aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                            optimisationCount: &DM.optimisationCount,
                            copyToClipboard: copyToClipboard,
                            source: .dropZone,
                            output: output,
                            skipPipelineLookup: pipeline != nil
                        )
                        await runPresetPipeline(pipeline, result: result, id: path.string)
                    }
                    if let url = item?.url, url.isImage || url.isVideo || url.isAudio {
                        let result = try await optimiseItem(
                            .url(url),
                            id: url.absoluteString,
                            aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                            optimisationCount: &DM.optimisationCount,
                            copyToClipboard: copyToClipboard,
                            source: .dropZone,
                            output: output,
                            skipPipelineLookup: pipeline != nil
                        )
                        await runPresetPipeline(pipeline, result: result, id: url.absoluteString)
                    }
                }
            case UTType.url.identifier:
                tryAsync {
                    guard let url = try await itemProvider.loadItem(forTypeIdentifier: identifier) as? URL, url.isImage || url.isVideo || url.isAudio else {
                        return
                    }
                    let result = try await optimiseItem(
                        .url(url),
                        id: url.absoluteString,
                        aggressiveOptimisation: pipeline?.skipOptimisation == true ? false : aggressive,
                        optimisationCount: &DM.optimisationCount,
                        copyToClipboard: copyToClipboard,
                        source: .dropZone,
                        output: output,
                        skipPipelineLookup: pipeline != nil
                    )
                    await runPresetPipeline(pipeline, result: result, id: url.absoluteString)
                }
            default:
                break
            }
        }
    }

    DM.itemsToOptimise = []
    return hasItemsToOptimise
}

extension NSSecureCoding {
    var existingFilePath: FilePath? {
        (self as? URL)?.existingFilePath ?? (self as? String)?.fileURL?.existingFilePath ?? (self as? Data)?.s?.fileURL?.existingFilePath
    }
    var url: URL? {
        (self as? URL) ?? (self as? String)?.url ?? (self as? Data)?.s?.url
    }
}

@MainActor
func optimiseDir(path dir: FilePath, aggressive: Bool? = nil, source: OptimisationSource? = nil, output: String? = nil, types: [UTType]) async throws {
    let urls = getURLsFromFolder(dir.url, recursive: true, types: types)

    // Batch mode: a large folder is handed to the lightweight engine + native window instead of one
    // heavy Optimiser/thumbnail per file. Pro-only; free users fall through to the per-file proGuard
    // path below (capped at the free limit).
    if Defaults[.useBatchModeForFolders], proactive, urls.count > Defaults[.batchModeFileCountThreshold] {
        let paths = urls.compactMap(\.filePath)
        // Drops open the prepare panel (review knobs, then Optimise); the CLI auto-starts instead.
        BAT.prepare(paths: paths, source: source ?? .dir(dir.string))
        BAT.showWindow()
        return
    }

    await withThrowingTaskGroup(of: Void.self, returning: Void.self) { group in
        for url in urls {
            let path = url.filePath!
            let added = group.addTaskUnlessCancelled {
                _ = try await proGuard(count: &DM.optimisationCount, limit: 5, url: path.url) {
                    try await optimiseItem(.file(path), id: path.string, aggressiveOptimisation: aggressive, optimisationCount: &manualOptimisationCount, copyToClipboard: false, source: source, output: output)
                }
            }
            guard added else { break }
        }
    }
}

@MainActor
func optimiseFile(from item: NSSecureCoding?, identifier: String, aggressive: Bool? = nil, source: OptimisationSource? = nil, output: String? = nil, pipeline: Pipeline? = nil) async throws {
    guard let path = item?.existingFilePath, path.isImage || path.isVideo || path.isAudio || path.isPDF || path.isDir else {
        return
    }

    guard !path.isDir else {
        try await optimiseDir(path: path, aggressive: aggressive, source: source, output: output, types: ALL_FORMATS)
        return
    }
    _ = try await proGuard(count: &DM.optimisationCount, limit: 5, url: path.url) { () async throws -> ClipboardType? in
        if await skipOptimiseAndRunPipelineIfEncoding(pipeline, path: path, source: source) {
            return nil
        }

        let skipOpt = pipeline?.skipOptimisation ?? false
        let result = try await optimiseItem(
            .file(path),
            id: path.string,
            aggressiveOptimisation: skipOpt ? false : aggressive,
            optimisationCount: &manualOptimisationCount,
            copyToClipboard: Defaults[.autoCopyToClipboard],
            source: source,
            output: output,
            skipPipelineLookup: pipeline != nil
        )

        // Run preset pipeline if configured
        if let pipeline, !pipeline.isEmpty, let source, let optimiser = opt(path.string) {
            let resultPath = result?.path ?? path
            let fileType: ClopFileType = path.isImage ? .image : path.isVideo ? .video : path.isPDF ? .pdf : .audio
            do {
                let (resultFile, _, _) = try await executePipeline(pipeline, file: resultPath, source: source, optimiser: optimiser, fileType: fileType)
                if resultFile != resultPath {
                    optimiser.url = resultFile.url
                    optimiser.type = .from(filePath: resultFile)
                    if let newSize = resultFile.fileSize() {
                        optimiser.newBytes = newSize
                    }
                }
            } catch {
                log.error("Pipeline: preset pipeline failed: \(error)")
            }
        }
        return result
    }
}

let IMAGE_VIDEO_IDENTIFIERS: [String] = (IMAGE_FORMATS + VIDEO_FORMATS).map(\.identifier)

struct DropZoneView_Previews: PreviewProvider {
    static var previews: some View {
        DropZoneView()
            .padding()
            .background(LinearGradient(
                colors: [Color.windowBackground, Color.textBackground, Color.tertiaryLabel],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
//            .background(LinearGradient(colors: [Color.red, Color.orange, Color.blue],
//                                       startPoint: .topLeading, endPoint: .bottomTrailing))

    }
}
