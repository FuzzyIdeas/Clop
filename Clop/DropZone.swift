import Defaults
import Foundation
import Lowtech
import SwiftUI
import System
import UniformTypeIdentifiers

class DragManager: ObservableObject {
    @MainActor @Published var dragHovering = false
    @MainActor @Published var itemsToOptimise: [ClipboardType] = []
    @Atomic var optimisationCount = 0

    @MainActor var fileType: ClopFileType? {
        itemsToOptimise.allSatisfy(\.isImage)
            ? .image
            : itemsToOptimise.allSatisfy(\.isVideo)
                ? .video
                : itemsToOptimise.allSatisfy(\.isPDF) ? .pdf : nil
    }

    @MainActor @Published var dropped = true {
        didSet {
            dropZoneKeyGlobalMonitor.stop()
            dropZoneKeyLocalMonitor.stop()
            DM.showDropZone = false
        }
    }

    @MainActor @Published var showDropZone = false {
        didSet {
            guard showDropZone != oldValue else {
                return
            }
            if showDropZone {
                log.debug("Option pressed, showing drop zone")
                showFloatingThumbnails()
            } else {
                log.debug("Option pressed, hiding drop zone")
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
                settingsViewManager.tab = .dropzone
                WM.open("settings")
                focus()
            }
            return false
        }

        if DM.optimisationCount == 5 {
            DM.optimisationCount += 1
        }
        return optimiseDroppedItems(info.itemProviders(for: IMAGE_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf]), copy: NSEvent.modifierFlags.contains(.option), preset: preset)
    }
}

struct DropZonePresetsView: View {
    var type: ClopFileType?

    @Default(.presetZones) var presetZones
    @Default(.enableDragAndDrop) var enableDragAndDrop

    @State var imagePresetZones: [PresetZone] = []
    @State var videoPresetZones: [PresetZone] = []
    @State var pdfPresetZones: [PresetZone] = []
    @State var anyFilePresetZones: [PresetZone] = []
    @Environment(\.preview) var preview
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var dragManager = DM

    var presetZoneArray: [PresetZone] {
        switch type {
        case .image:
            imagePresetZones
        case .video:
            videoPresetZones
        case .pdf:
            pdfPresetZones
        default:
            anyFilePresetZones
        }
    }

    @State var showPresetEditor = false
    @State var editingZone: PresetZone?
    @State var selectedPresetIndex: Int?
    @Binding var selectedPreset: PresetZone?

    @ViewBuilder
    func zoneIcon(systemName: String) -> some View {
        SwiftUI.Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .padding(6)
            .background(
                roundRect(5, fill: .bg.warm.opacity(colorScheme == .dark ? 0.6 : 0.4))
                    .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 4)
            )
    }

    @ViewBuilder
    func zoneView(index: Int) -> some View {
        let zone = presetZoneArray[safe: index]
        let nextPreset = presetZoneArray.count == index
        let disabled = !nextPreset && zone == nil

        Button(action: {
            guard let w = NSApp.keyWindow, w.title != "Settings" else {
                settingsViewManager.tab = .dropzone
                WM.open("settings")
                focus()
                return
            }
            editingZone = zone
            showPresetEditor = true
        }) {
            VStack(spacing: 5) {
                zoneIcon(systemName: zone.map(\.icon) ?? (nextPreset ? "plus.square.dashed" : "square.dashed"))
                    .rotation3DEffect(.degrees(selectedPresetIndex == index ? 170 : 0), axis: (x: 0, y: 1, z: 0), perspective: 1.2)

                Text(zone.map(\.name) ?? (nextPreset ? "Add preset" : "No preset"))
                    .round(10)
                    .foregroundColor(nextPreset ? .fg.warm.opacity(0.7) : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(width: DROPZONE_SIZE.width / 2, height: 14)
            }.frame(width: DROPZONE_SIZE.width / 2 - 2, height: DROPZONE_SIZE.height / 2 + 2)
        }
        .buttonStyle(
            FlatButton(
                color: .primary.opacity(0.05), textColor: nextPreset ? .fg.warm.opacity(0.5) : .primary.opacity(0.8),
                radius: 0, shadowSize: 0, hoverColorEffects: false, hoverScaleEffects: false
            )
        )
        .sheet(isPresented: $showPresetEditor) {
            Form {
                PresetZoneEditor(zone: zone != nil ? $editingZone : .constant(nil), type: type) {
                    showPresetEditor = false
                }
                .fixedSize()
            }.formStyle(.grouped)
        }
        .if(preview) {
            $0.onHover { h in
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
        }
        .overlay { Color.peach.opacity(selectedPresetIndex == index ? 0.1 : 0.0) }
        .if(enableDragAndDrop && !preview) {
            $0.onDrop(
                of: IMAGE_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf],
                delegate: DropZonePresetsViewDelegate(preset: zone, isNextPreset: nextPreset) { h in
                    selectedPresetIndex = h && !disabled ? index : nil
                    selectedPreset = h && !disabled ? zone : nil
                }
            )
            .background(DragPileView().fill(.center))
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
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

    func cachePresetZones() {
        imagePresetZones = []
        videoPresetZones = []
        pdfPresetZones = []
        anyFilePresetZones = []

        for presetZone in presetZones {
            switch presetZone.type {
            case .image:
                imagePresetZones.append(presetZone)
            case .video:
                videoPresetZones.append(presetZone)
            case .pdf:
                pdfPresetZones.append(presetZone)
            case nil:
                anyFilePresetZones.append(presetZone)
            }
        }
        imagePresetZones += anyFilePresetZones
        videoPresetZones += anyFilePresetZones
        pdfPresetZones += anyFilePresetZones
    }
}

struct DropZoneView: View {
    var blurredBackground = true
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.enableDragAndDrop) var enableDragAndDrop

    @ObservedObject var dragManager = DM
    @ObservedObject var keysManager = KM
    @Namespace var namespace
    @Environment(\.preview) var preview

    @State var rotation: Angle = .degrees(0)
    @State var hovering = false
    @State var selectedPreset: PresetZone? = nil
    var ctrlPressed: Bool { keysManager.lctrl || keysManager.rctrl }
    var presetFileType: ClopFileType?

    var hoverState: Bool {
        (preview ? hovering : dragManager.dragHovering) || ctrlPressed || presetFileType != nil
    }

    @ViewBuilder var draggingOutsideView: some View {
        VStack {
            if ctrlPressed || presetFileType != nil {
                DropZonePresetsView(type: presetFileType ?? dragManager.fileType, selectedPreset: $selectedPreset)
                    .overlay(Color.mauvish.opacity(keysManager.flags.sideIndependentModifiers.contains(.command) ? 0.05 : 0.0))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                if hoverState {
                    SwiftUI.Image(systemName: "livephoto")
                        .font(.bold(hoverState ? 50 : 0))
                        .padding(hoverState ? 5 : 0)
                        .rotationEffect(rotation)
                        .onAppear {
                            guard !SWIFTUI_PREVIEW else { return }
                            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                                rotation = .degrees(359)
                            }
                        }
                        .onDisappear {
                            rotation = .degrees(0)
                        }
                }

                VStack(spacing: -1) {
                    Text(hoverState ? "Drop to optimise" : "Drop here to optimise")
                        .font(.system(size: hoverState ? 16 : 14, weight: hoverState ? .heavy : .semibold, design: .rounded))
                        .padding(.bottom, 8)

                    Text("^: show preset zones")
                        .medium(10)
                        .foregroundColor(.primary)
                        .opacity(0.8)
                    if !hoverState {
                        Text("⌥: dismiss this drop zone")
                            .medium(10)
                            .foregroundColor(.primary)
                            .opacity(0.8)
                    }
                    Text("⌘: use aggressive optimisation")
                        .medium(10)
                        .foregroundColor(keysManager.flags.sideIndependentModifiers.contains(.command) ? .mauvish : .primary)
                        .opacity(0.8)
                }
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .fixedSize()
                .matchedGeometryEffect(id: "text", in: namespace)
            }
        }
        .frame(
            width: hoverState ? DROPZONE_SIZE.width : nil,
            height: hoverState ? DROPZONE_SIZE.height : nil,
            alignment: .center
        )
        .padding(.horizontal, DROPZONE_PADDING.width)
        .padding(.vertical, DROPZONE_PADDING.height)
        .background(
            blurredBackground
                ? VisualEffectBlur(material: .hudWindow, blendingMode: preview ? .withinWindow : .behindWindow, state: .active)
                    .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3).any
                    .overlay(Color.calmGreen.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .any
                : Color.calmGreen.opacity(0.25)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .any
        )
        .onHover { hovering in
            withAnimation(.fastSpring) {
                self.hovering = hovering
            }
        }
    }

    var body: some View {
        HStack {
            FlipGroup(if: !floatingResultsCorner.isTrailing) {
                draggingOutsideView
                    .contentShape(Rectangle())

                SwiftUI.Image("clop")
                    .resizable()
                    .scaledToFit()
                    .frame(width: HAT_ICON_SIZE, height: HAT_ICON_SIZE, alignment: .center)
                    .opacity(showFloatingHatIcon ? 1 : 0)
            }
        }
        .frame(width: THUMB_SIZE.width, height: THUMB_SIZE.height / 2, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
        .padding()
        .fixedSize()
        .if(enableDragAndDrop && !preview && !ctrlPressed) {
            $0.onDrop(of: IMAGE_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf], delegate: self)
                .background(DragPileView().fill(.center))
        }
    }
}

let HAT_ICON_SIZE: CGFloat = 30
let DROPZONE_SIZE: CGSize = THUMB_SIZE.scaled(by: 0.5)
let DROPZONE_PADDING = CGSize(width: 14, height: 10)

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
        return optimiseDroppedItems(info.itemProviders(for: IMAGE_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf]), copy: NSEvent.modifierFlags.contains(.option), preset: selectedPreset)
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

@MainActor
func optimiseDroppedItems(_ itemProviders: [NSItemProvider], copy: Bool, preset: PresetZone? = nil) -> Bool {
    DM.dragging = false

    let aggressive = NSEvent.modifierFlags.contains(.command) ? true : nil
    let hasItemsToOptimise = itemProviders.contains { provider in
        (IMAGE_FORMATS + VIDEO_FORMATS).contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    } || DM.itemsToOptimise.isNotEmpty

    var output: String? = nil
    if copy {
        let url = URL.temporaryDirectory.appendingPathComponent("clop-dropzone-\(Int.random(in: 1000 ... 10_000_000))", conformingTo: .directory)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        output = url.path
    }

    let itemsToOptimise = DM.itemsToOptimise
    let itemProvidersCount = itemProviders.count
    let copyToClipboard = Defaults[.autoCopyToClipboard]
    for itemProvider in itemProviders {
        log.debug("Dropped itemProvider types: \(itemProvider.registeredTypeIdentifiers)")

        for identifier in itemProvider.registeredTypeIdentifiers {
            switch identifier {
            case [UTType.fileURL.identifier, UTType.aliasFile.identifier]:
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, shortcut: preset?.shortcut)
                }
            case UTType.pdf.identifier:
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, shortcut: preset?.shortcut)
                }
            case IMAGE_FORMATS.map(\.identifier):
                tryAsync {
                    let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier)
                    let path = item?.existingFilePath
                    let data = item as? Data
                    let nsImage = item as? NSImage ?? (data != nil ? NSImage(data: data!) : nil)

                    if path == nil, data == nil, nsImage == nil, itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                        try await optimiseItem(item, id: item.id, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: .dropZone, output: output, shortcut: preset?.shortcut)
                        return
                    }

                    guard let image = Image(
                        path: path, data: nsImage != nil ? data : nil, nsImage: nsImage,
                        type: UTType(identifier), optimised: false, retinaDownscaled: false
                    ) else {
                        return
                    }

                    try await optimiseItem(
                        .image(image),
                        id: image.path.string,
                        aggressiveOptimisation: aggressive,
                        optimisationCount: &DM.optimisationCount,
                        copyToClipboard: copyToClipboard,
                        source: .dropZone,
                        output: output,
                        shortcut: preset?.shortcut
                    )
                }
            case VIDEO_FORMATS.map(\.identifier):
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        if itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                            try await optimiseItem(
                                item,
                                id: item.id,
                                aggressiveOptimisation: aggressive,
                                optimisationCount: &DM.optimisationCount,
                                copyToClipboard: copyToClipboard,
                                source: .dropZone,
                                output: output,
                                shortcut: preset?.shortcut
                            )
                        }
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: .dropZone, output: output, shortcut: preset?.shortcut)
                }
            case [UTType.plainText.identifier, UTType.utf8PlainText.identifier]:
                tryAsync {
                    let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier)
                    if let path = item?.existingFilePath, path.isImage || path.isVideo {
                        try await optimiseItem(
                            .file(path),
                            id: path.string,
                            aggressiveOptimisation: aggressive,
                            optimisationCount: &DM.optimisationCount,
                            copyToClipboard: copyToClipboard,
                            source: .dropZone,
                            output: output,
                            shortcut: preset?.shortcut
                        )
                    }
                    if let url = item?.url, url.isImage || url.isVideo {
                        try await optimiseItem(
                            .url(url),
                            id: url.absoluteString,
                            aggressiveOptimisation: aggressive,
                            optimisationCount: &DM.optimisationCount,
                            copyToClipboard: copyToClipboard,
                            source: .dropZone,
                            output: output,
                            shortcut: preset?.shortcut
                        )
                    }
                }
            case UTType.url.identifier:
                tryAsync {
                    guard let url = try await itemProvider.loadItem(forTypeIdentifier: identifier) as? URL, url.isImage || url.isVideo else {
                        return
                    }
                    try await optimiseItem(
                        .url(url),
                        id: url.absoluteString,
                        aggressiveOptimisation: aggressive,
                        optimisationCount: &DM.optimisationCount,
                        copyToClipboard: copyToClipboard,
                        source: .dropZone,
                        output: output,
                        shortcut: preset?.shortcut
                    )
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
func optimiseDir(path dir: FilePath, aggressive: Bool? = nil, source: OptimisationSource? = nil, output: String? = nil, types: [UTType], shortcut: Shortcut? = nil) async throws {
    await withThrowingTaskGroup(of: Void.self, returning: Void.self) { group in
        for url in getURLsFromFolder(dir.url, recursive: true, types: types) {
            let path = url.filePath!
            let added = group.addTaskUnlessCancelled {
                _ = try await proGuard(count: &DM.optimisationCount, limit: 5, url: path.url) {
                    try await optimiseItem(.file(path), id: path.string, aggressiveOptimisation: aggressive, optimisationCount: &manualOptimisationCount, copyToClipboard: false, source: source, output: output, shortcut: shortcut)
                }
            }
            guard added else { break }
        }
    }
}

@MainActor
func optimiseFile(from item: NSSecureCoding?, identifier: String, aggressive: Bool? = nil, source: OptimisationSource? = nil, output: String? = nil, shortcut: Shortcut? = nil) async throws {
    guard let path = item?.existingFilePath, path.isImage || path.isVideo || path.isPDF || path.isDir else {
        return
    }

    guard !path.isDir else {
        try await optimiseDir(path: path, aggressive: aggressive, source: source, output: output, types: ALL_FORMATS, shortcut: shortcut)
        return
    }
    _ = try await proGuard(count: &DM.optimisationCount, limit: 5, url: path.url) {
        try await optimiseItem(
            .file(path),
            id: path.string,
            aggressiveOptimisation: aggressive,
            optimisationCount: &manualOptimisationCount,
            copyToClipboard: Defaults[.autoCopyToClipboard],
            source: source,
            output: output,
            shortcut: shortcut
        )
    }
}

let IMAGE_VIDEO_IDENTIFIERS: [String] = (IMAGE_FORMATS + VIDEO_FORMATS).map(\.identifier)

struct DropZoneView_Previews: PreviewProvider {
    static var previews: some View {
        DropZoneView()
            .padding()
            .background(LinearGradient(colors: [Color.red, Color.orange, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))

    }
}
