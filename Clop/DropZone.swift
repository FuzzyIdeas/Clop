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

struct DropZoneView: View {
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.enableDragAndDrop) var enableDragAndDrop

    @ObservedObject var dragManager = DM
    @ObservedObject var keysManager = KM
    @State var rotation: Angle = .degrees(0)
    @Namespace var namespace

    @ViewBuilder var draggingOutsideView: some View {
        VStack {
            if dragManager.dragHovering {
                SwiftUI.Image(systemName: "livephoto")
                    .font(.bold(dragManager.dragHovering ? 50 : 0))
                    .padding(dragManager.dragHovering ? 5 : 0)
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
                Text(dragManager.dragHovering ? "Drop to optimise" : "Drop here to optimise")
                    .font(.system(size: dragManager.dragHovering ? 16 : 14, weight: dragManager.dragHovering ? .heavy : .semibold, design: .rounded))
                    .padding(.bottom, 8)
                if !dragManager.dragHovering {
                    Text("⌥: dismiss this drop zone").medium(10)
                }
                Text("⌘: use aggressive optimisation").medium(10)
                    .foregroundColor(keysManager.flags.sideIndependentModifiers.contains(.command) ? .mauvish : .primary)
                    .opacity(0.8)
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .fixedSize()
            .matchedGeometryEffect(id: "text", in: namespace)
        }
        .frame(
            width: dragManager.dragHovering ? THUMB_SIZE.width / 2 : nil,
            height: dragManager.dragHovering ? THUMB_SIZE.height / 2 : nil,
            alignment: .center
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3).any
                .overlay(Color.calmGreen.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    var body: some View {
        HStack {
            FlipGroup(if: !floatingResultsCorner.isTrailing) {
                draggingOutsideView
                    .contentShape(Rectangle())

                SwiftUI.Image("clop")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30, alignment: .center)
                    .opacity(showFloatingHatIcon ? 1 : 0)
            }
        }
        .frame(width: THUMB_SIZE.width, height: THUMB_SIZE.height / 2, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
        .padding()
        .fixedSize()
        .if(enableDragAndDrop) {
            $0.onDrop(of: IMAGE_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf], delegate: self)
                .background(DragPileView().fill(.center))
        }
    }
}

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
        return optimiseDroppedItems(info.itemProviders(for: IMAGE_FORMATS + VIDEO_FORMATS + [.plainText, .utf8PlainText, .url, .fileURL, .aliasFile, .pdf]), copy: NSEvent.modifierFlags.contains(.option))
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
func optimiseDroppedItems(_ itemProviders: [NSItemProvider], copy: Bool) -> Bool {
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
    itemProviders.forEach { itemProvider in
        log.debug("Dropped itemProvider types: \(itemProvider.registeredTypeIdentifiers)")

        for identifier in itemProvider.registeredTypeIdentifiers {
            switch identifier {
            case [UTType.fileURL.identifier, UTType.aliasFile.identifier]:
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: "drop zone", output: output)
                }
            case UTType.pdf.identifier:
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: "drop zone", output: output)
                }
            case IMAGE_FORMATS.map(\.identifier):
                tryAsync {
                    let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier)
                    let path = item?.existingFilePath
                    let data = item as? Data
                    let nsImage = item as? NSImage ?? (data != nil ? NSImage(data: data!) : nil)

                    if path == nil, data == nil, nsImage == nil, itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                        try await optimiseItem(item, id: item.id, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: "drop zone", output: output)
                        return
                    }

                    guard let image = Image(
                        path: path, data: nsImage != nil ? data : nil, nsImage: nsImage,
                        type: UTType(identifier), optimised: false, retinaDownscaled: false
                    ) else {
                        return
                    }

                    try await optimiseItem(.image(image), id: image.path.string, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: "drop zone", output: output)
                }
            case VIDEO_FORMATS.map(\.identifier):
                tryAsync {
                    guard let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier) else {
                        if itemProvidersCount == 1, let item = itemsToOptimise.first, item != .file(FilePath.tmp) {
                            try await optimiseItem(item, id: item.id, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: "drop zone", output: output)
                        }
                        return
                    }
                    try await optimiseFile(from: item, identifier: identifier, aggressive: aggressive, source: "drop zone", output: output)
                }
            case [UTType.plainText.identifier, UTType.utf8PlainText.identifier]:
                tryAsync {
                    let item = try? await itemProvider.loadItem(forTypeIdentifier: identifier)
                    if let path = item?.existingFilePath, path.isImage || path.isVideo {
                        try await optimiseItem(.file(path), id: path.string, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: "drop zone", output: output)
                    }
                    if let url = item?.url, url.isImage || url.isVideo {
                        try await optimiseItem(.url(url), id: url.absoluteString, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: "drop zone", output: output)
                    }
                }
            case UTType.url.identifier:
                tryAsync {
                    guard let url = try await itemProvider.loadItem(forTypeIdentifier: identifier) as? URL, url.isImage || url.isVideo else {
                        return
                    }
                    try await optimiseItem(.url(url), id: url.absoluteString, aggressiveOptimisation: aggressive, optimisationCount: &DM.optimisationCount, copyToClipboard: copyToClipboard, source: "drop zone", output: output)
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
func optimiseDir(path dir: FilePath, aggressive: Bool? = nil, source: String? = nil, output: String? = nil) async throws {
    await withThrowingTaskGroup(of: Void.self, returning: Void.self) { group in
        for url in getURLsFromFolder(dir.url, recursive: true) {
            let path = url.filePath!
            _ = group.addTaskUnlessCancelled {
                _ = try await proGuard(count: &DM.optimisationCount, limit: 5, url: path.url) {
                    try await optimiseItem(.file(path), id: path.string, aggressiveOptimisation: aggressive, optimisationCount: &manualOptimisationCount, copyToClipboard: false, source: source, output: output)
                }
            }
        }
    }
}

@MainActor
func optimiseFile(from item: NSSecureCoding?, identifier: String, aggressive: Bool? = nil, source: String? = nil, output: String? = nil) async throws {
    guard let path = item?.existingFilePath, path.isImage || path.isVideo || path.isPDF || path.isDir else {
        return
    }

    guard !path.isDir else {
        try await optimiseDir(path: path, aggressive: aggressive, source: source, output: output)
        return
    }
    _ = try await proGuard(count: &DM.optimisationCount, limit: 5, url: path.url) {
        try await optimiseItem(.file(path), id: path.string, aggressiveOptimisation: aggressive, optimisationCount: &manualOptimisationCount, copyToClipboard: Defaults[.autoCopyToClipboard], source: source, output: output)
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
