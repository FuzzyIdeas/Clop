import AVFoundation
import Defaults
import Foundation
import Lowtech
import PDFKit
import SwiftUI
import System

let CROP_WINDOW_SIZE: CGFloat = 600

// MARK: - Window management

extension Optimiser {
    func showCropWindow() {
        if let window = cropWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            focus()
            return
        }
        guard canCrop(), url != nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CROP_WINDOW_SIZE * 1.7, height: CROP_WINDOW_SIZE + 60),
            styleMask: [.fullSizeContentView, .titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Crop: \(filename)"
        // The window controller owns the window; releasing on close too would double-release.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 780, height: 520)

        window.contentView = NSHostingView(
            rootView: CropView(optimiser: self)
                .frame(
                    minWidth: 780, idealWidth: CROP_WINDOW_SIZE * 1.7,
                    minHeight: 520, idealHeight: CROP_WINDOW_SIZE + 60
                )
                .background(.regularMaterial)
        )
        window.backgroundColor = .clear

        window.setFrameAutosaveName("Crop Window")
        if !window.setFrameUsingName("Crop Window") {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        focus()

        NotificationCenter.default.addObserver(self, selector: #selector(cropWindowWillClose), name: NSWindow.willCloseNotification, object: window)

        cropWindowController = NSWindowController(window: window)
    }

    @objc func cropWindowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: notification.object)
        cropWindowController = nil
    }
}

// MARK: - Crop selection model

enum CropFrameStyle: Equatable {
    case plain
    case paper
    case device

    func cornerRadius(for rect: CGRect) -> CGFloat {
        switch self {
        case .plain: 2
        case .paper: 0.5
        case .device: min(max(min(rect.width, rect.height) * 0.08, 6), 26)
        }
    }
}

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        default: false
        }
    }
    var isHorizontalEdge: Bool { self == .top || self == .bottom }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

// MARK: - Interactive selection overlay

struct CropSelectionOverlay: View {
    @Binding var rect: CropRect
    let viewSize: CGSize
    let sourceSize: NSSize
    var aspect: Double? = nil
    var frameStyle = CropFrameStyle.plain
    var label: String? = nil
    var unit = "px"
    var outputSize: NSSize? = nil
    var previewImage: NSImage? = nil
    var onEdit: () -> Void = {}
    var onReset: () -> Void = {}

    @State private var dragStart: CGRect? = nil
    @State private var interacting = false

    private static let minSide: CGFloat = 24

    private var disp: CGRect {
        CGRect(
            x: rect.x * viewSize.width, y: rect.y * viewSize.height,
            width: rect.width * viewSize.width, height: rect.height * viewSize.height
        )
    }
    private var pixelSize: NSSize { rect.computedSize(from: sourceSize) }
    private var cornerRadius: CGFloat { frameStyle.cornerRadius(for: disp) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming
            selectionFrame
            resultSizePreview
            if interacting {
                thirdsGrid.allowsHitTesting(false)
            }
            badges.allowsHitTesting(false)
            moveArea
            handles
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    /// How much the selection gets scaled down in the final file. 1 = no scaling.
    private var resultScaleFactor: CGFloat {
        guard let out = outputSize, pixelSize.width > 0 else { return 1 }
        return out.width / pixelSize.width
    }

    /// When the output is significantly smaller than the selection, float a render of the
    /// final image in the middle of the selection to give a sense of the real size.
    /// Hidden while the selection is being adjusted, fades in once it settles.
    @ViewBuilder private var resultSizePreview: some View {
        if let previewImage, resultScaleFactor <= 0.7, disp.width * resultScaleFactor >= 20, disp.height * resultScaleFactor >= 20 {
            let s = resultScaleFactor
            ZStack(alignment: .topLeading) {
                SwiftUI.Image(nsImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: viewSize.width * s, height: viewSize.height * s)
                    .offset(x: -disp.minX * s, y: -disp.minY * s)
            }
            .frame(width: disp.width * s, height: disp.height * s, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
            .position(x: disp.midX, y: disp.midY)
            .opacity(interacting ? 0 : 1)
            .animation(.easeOut(duration: 0.15).delay(interacting ? 0 : 0.3), value: interacting)
            .allowsHitTesting(false)
        }
    }

    private var dimming: some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: viewSize))
            p.addRoundedRect(in: disp, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }
        .fill(Color.black.opacity(interacting ? 0.55 : 0.45), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        .gesture(marqueeGesture)
    }

    private var selectionFrame: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(.white, lineWidth: frameStyle == .device ? 3 : (frameStyle == .paper ? 2.5 : 1.5))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .frame(width: disp.width, height: disp.height)
            .position(x: disp.midX, y: disp.midY)
            .allowsHitTesting(false)
    }

    private var thirdsGrid: some View {
        Path { p in
            for f in [1.0 / 3.0, 2.0 / 3.0] {
                p.move(to: CGPoint(x: disp.minX + disp.width * f, y: disp.minY))
                p.addLine(to: CGPoint(x: disp.minX + disp.width * f, y: disp.maxY))
                p.move(to: CGPoint(x: disp.minX, y: disp.minY + disp.height * f))
                p.addLine(to: CGPoint(x: disp.maxX, y: disp.minY + disp.height * f))
            }
        }
        .stroke(.white.opacity(0.4), lineWidth: 1)
    }

    @ViewBuilder private var badges: some View {
        let selection = pixelSize
        let scaled = outputSize.map { $0.width.i != selection.width.i || $0.height.i != selection.height.i } ?? false
        let sizeText = scaled
            ? "\(selection.width.i)×\(selection.height.i) → \(outputSize!.width.i)×\(outputSize!.height.i) \(unit)"
            : "\(selection.width.i)×\(selection.height.i) \(unit)"
        Text(sizeText)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.7)))
            .foregroundColor(.white)
            .position(x: disp.midX, y: min(disp.maxY + 14, viewSize.height - 10))

        if let label, label.isNotEmpty {
            Text(label)
                .font(.round(10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.7)))
                .foregroundColor(.white)
                .position(x: disp.midX, y: max(disp.minY - 14, 10))
        }
    }

    private var moveArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: max(disp.width, 1), height: max(disp.height, 1))
            .position(x: disp.midX, y: disp.midY)
            .gesture(moveGesture)
            .onTapGesture(count: 2) { onReset() }
    }

    private var handles: some View {
        ForEach(Array(CropHandle.allCases.enumerated()), id: \.offset) { _, handle in
            handleView(handle)
                .position(handle.point(in: disp))
                .gesture(resizeGesture(handle))
        }
    }

    @ViewBuilder private func handleView(_ handle: CropHandle) -> some View {
        Group {
            if handle.isCorner {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 9, height: 9)
            } else {
                Capsule()
                    .fill(.white)
                    .frame(
                        width: handle.isHorizontalEdge ? 22 : 5,
                        height: handle.isHorizontalEdge ? 5 : 22
                    )
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 1.5)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? disp
                dragStart = start
                interacting = true

                var r = start
                r.origin.x = min(max(start.minX + value.translation.width, 0), viewSize.width - start.width)
                r.origin.y = min(max(start.minY + value.translation.height, 0), viewSize.height - start.height)
                commit(r)
            }
            .onEnded { _ in endDrag() }
    }

    private func resizeGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? disp
                dragStart = start
                interacting = true
                commit(resized(start: start, handle: handle, translation: value.translation))
            }
            .onEnded { _ in endDrag() }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                interacting = true
                var w = value.location.x - value.startLocation.x
                var h = value.location.y - value.startLocation.y
                if let aspect {
                    if abs(w) / aspect >= abs(h) {
                        h = (abs(w) / aspect) * (h < 0 ? -1 : 1)
                    } else {
                        w = abs(h) * aspect * (w < 0 ? -1 : 1)
                    }
                }
                let r = CGRect(
                    x: w < 0 ? value.startLocation.x + w : value.startLocation.x,
                    y: h < 0 ? value.startLocation.y + h : value.startLocation.y,
                    width: abs(w), height: abs(h)
                ).intersection(CGRect(origin: .zero, size: viewSize))
                guard r.width >= 8, r.height >= 8 else { return }
                commit(r)
            }
            .onEnded { _ in endDrag() }
    }

    private func endDrag() {
        dragStart = nil
        interacting = false
    }

    private func commit(_ r: CGRect) {
        rect = CropRect(
            x: r.minX / viewSize.width, y: r.minY / viewSize.height,
            width: r.width / viewSize.width, height: r.height / viewSize.height
        ).clamped()
        onEdit()
    }

    private func resized(start: CGRect, handle: CropHandle, translation: CGSize) -> CGRect {
        let dx = translation.width
        let dy = translation.height

        // anchor: the point that must not move while resizing from this handle
        let anchor: CGPoint = switch handle {
        case .topLeft: CGPoint(x: start.maxX, y: start.maxY)
        case .top, .bottom: CGPoint(x: start.midX, y: handle == .top ? start.maxY : start.minY)
        case .topRight: CGPoint(x: start.minX, y: start.maxY)
        case .right, .left: CGPoint(x: handle == .right ? start.minX : start.maxX, y: start.midY)
        case .bottomRight: CGPoint(x: start.minX, y: start.minY)
        case .bottomLeft: CGPoint(x: start.maxX, y: start.minY)
        }

        let growsLeft = handle == .topLeft || handle == .left || handle == .bottomLeft
        let growsUp = handle == .topLeft || handle == .top || handle == .topRight

        var w = switch handle {
        case .top, .bottom: start.width
        default: start.width + (growsLeft ? -dx : dx)
        }
        var h = switch handle {
        case .left, .right: start.height
        default: start.height + (growsUp ? -dy : dy)
        }

        // space available from the anchor towards the directions the rect can grow into
        let availW = handle.isHorizontalEdge
            ? 2 * min(anchor.x, viewSize.width - anchor.x)
            : (growsLeft ? anchor.x : viewSize.width - anchor.x)
        let availH = (handle == .left || handle == .right)
            ? 2 * min(anchor.y, viewSize.height - anchor.y)
            : (growsUp ? anchor.y : viewSize.height - anchor.y)

        if let aspect {
            if handle.isCorner {
                // follow the dominant drag axis
                if abs(dx) * start.height >= abs(dy) * start.width {
                    h = w / aspect
                } else {
                    w = h * aspect
                }
            } else if handle.isHorizontalEdge {
                w = h * aspect
            } else {
                h = w / aspect
            }
            w = max(w, Self.minSide)
            h = w / aspect
            if h < Self.minSide { h = Self.minSide; w = h * aspect }
            if w > availW { w = availW; h = w / aspect }
            if h > availH { h = availH; w = h * aspect }
        } else {
            w = min(max(w, Self.minSide), availW)
            h = min(max(h, Self.minSide), availH)
        }

        let x = handle.isHorizontalEdge ? anchor.x - w / 2 : (growsLeft ? anchor.x - w : anchor.x)
        let y = (handle == .left || handle == .right) ? anchor.y - h / 2 : (growsUp ? anchor.y - h : anchor.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Crop view

/// A small accent-colored rectangle whose proportions mirror the preset's aspect ratio,
/// drawn in a fixed footprint so labels stay aligned.
struct AspectIcon: View {
    let aspect: Double
    var selected = false

    var body: some View {
        let maxW: CGFloat = 16
        let maxH: CGFloat = 10
        let w = min(maxW, maxH * aspect)
        let h = w / aspect

        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.accentColor.opacity(selected ? 1 : 0.55))
            .frame(width: max(w, 3), height: max(min(h, maxH), 3))
            .frame(width: maxW, height: maxH + 1)
    }
}

struct SizePresetRow: View {
    let size: CropSize
    let iconAspect: Double
    let selected: Bool
    let disabled: Bool
    var apply: () -> Void
    var delete: () -> Void

    @State private var hovering = false
    @State private var hoveringTrash = false

    var body: some View {
        Button(action: apply) {
            HStack(spacing: 6) {
                AspectIcon(aspect: iconAspect, selected: selected)
                Text(size.name)
                    .font(.round(11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    Text(size.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .opacity(hovering ? 0 : 1)
                    Button(action: delete) {
                        SwiftUI.Image(systemName: "trash.fill")
                            .font(.system(size: 9))
                            .foregroundColor(hoveringTrash ? .white : .red.opacity(0.85))
                            .padding(4)
                            .background(Circle().fill(hoveringTrash ? Color.red : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0)
                    .onHover { hoveringTrash = $0 }
                    .help("Delete preset")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovering ? 0.1 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .animation(.easeOut(duration: 0.1), value: hoveringTrash)
    }
}

/// Popup listing crop size groups with the member devices/papers as a native
/// menu item subtitle. SwiftUI's menu Picker flattens item views to plain
/// titles on macOS, so this drops down to NSPopUpButton.
struct CropSizeGroupPicker: NSViewRepresentable {
    final class Coordinator: NSObject {
        init(_ binding: Binding<CropSize?>) {
            selectionBinding = binding
        }

        var selectionBinding: Binding<CropSize?>

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            selectionBinding.wrappedValue = sender.selectedItem?.representedObject as? CropSize
        }
    }

    @Binding var selection: CropSize?
    let categories: [(category: String, groups: [CropSizeGroup])]

    func makeCoordinator() -> Coordinator {
        Coordinator($selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .menuFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "No selection", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for (category, groups) in categories {
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: category))
            } else {
                let header = NSMenuItem(title: category, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for group in groups {
                let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                item.representedObject = group.cropSize
                item.indentationLevel = 1
                if group.members.count > 1 {
                    if #available(macOS 14.4, *) {
                        item.subtitle = wrapped(group.subtitle)
                    }
                    item.toolTip = group.subtitle
                }
                menu.addItem(item)
            }
        }
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selectionBinding = $selection
        let index = button.menu?.items.firstIndex { ($0.representedObject as? CropSize) == selection }
        button.selectItem(at: index ?? 0)
    }

    /// Breaks a long member list into lines so the menu doesn't grow overly wide.
    private func wrapped(_ text: String, width: Int = 48) -> String {
        var lines = [""]
        for member in text.components(separatedBy: ", ") {
            let line = lines[lines.count - 1]
            if line.isEmpty {
                lines[lines.count - 1] = member
            } else if line.count + member.count + 2 <= width {
                lines[lines.count - 1] = "\(line), \(member)"
            } else {
                lines.append(member)
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct CropView: View {
    enum Field: Hashable {
        case width
        case height
        case name
    }

    @ObservedObject var optimiser: Optimiser
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var focused: Field?

    @State private var sourceSize = NSSize(width: 1, height: 1)
    @State private var rect = CropRect.full
    @State private var initialRect = CropRect.full
    @State private var lockedAspect: Double? = nil
    @State private var targetSize: NSSize? = nil
    @State private var presetName: String? = nil
    @State private var frameStyle = CropFrameStyle.plain
    @State private var cropOrientation = CropOrientation.adaptive
    @State private var rectEdited = false
    @State private var adaptiveAspect: CropSize? = nil
    @State private var paperSize: CropSize? = nil
    @State private var deviceSize: CropSize? = nil
    @State private var ratioSize: CropSize? = nil
    @State private var extendPage = false

    @State private var preview: NSImage? = nil
    @State private var pageIndex = 0
    @State private var pageCount = 1
    @State private var videoTime = 0.0
    @State private var saveName = ""

    @Default(.savedCropSizes) var savedCropSizes

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                previewArea
                previewBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            sidebar
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(Color.bg.warm.opacity(colorScheme == .dark ? 0.4 : 0.8))
        }
        .background(
            Button("") { optimiser.cropWindowController?.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .onAppear { setup() }
        .onChange(of: optimiser.running) { running in
            if running { optimiser.cropWindowController?.close() }
        }
        .task {
            // video preview is loaded by the time slider's task
            guard !optimiser.type.isVideo else { return }
            await loadPreview()
        }
    }

    var unit: String { optimiser.type.isPDF ? "pt" : "px" }

    // MARK: Preview

    var previewArea: some View {
        GeometryReader { geo in
            let fit = fittedSize(in: geo.size)
            ZStack {
                if let preview {
                    if extending, let aspect = adaptiveAspect {
                        extendedPreview(preview, aspect: aspect, container: geo.size)
                    } else {
                        SwiftUI.Image(nsImage: preview)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                            .overlay(
                                CropSelectionOverlay(
                                    rect: $rect,
                                    viewSize: fit,
                                    sourceSize: sourceSize,
                                    aspect: lockedAspect,
                                    frameStyle: frameStyle,
                                    label: presetName,
                                    unit: unit,
                                    outputSize: effectiveTargetSize(),
                                    previewImage: preview,
                                    onEdit: { rectEdited = true },
                                    onReset: { reset() }
                                )
                            )
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding([.horizontal, .top])
        .padding(.top, 14)
    }

    /// True when applying the preset will grow the page canvas instead of cropping it.
    var extending: Bool {
        optimiser.type.isPDF && extendPage && adaptiveAspect != nil
    }

    /// The space the selection rect is normalized to: the extended canvas when
    /// extending, the source page/image otherwise.
    var cropSpaceSize: NSSize {
        if extending, let aspect = adaptiveAspect {
            return extendedCanvasSize(aspect: aspect)
        }
        return sourceSize
    }

    func extendedCanvasSize(aspect: CropSize) -> NSSize {
        sourceSize.extendTo(
            aspectRatio: aspect.fractionalAspectRatio,
            alwaysPortrait: cropOrientation == .portrait,
            alwaysLandscape: cropOrientation == .landscape
        ).size
    }

    /// Page rendered at its real proportion inside the extended white canvas,
    /// previewing what the saved pages will look like. The selection rect stays
    /// interactive so the view can be zoomed/panned within the extended space.
    @ViewBuilder
    func extendedPreview(_ image: NSImage, aspect: CropSize, container: CGSize) -> some View {
        let canvas = extendedCanvasSize(aspect: aspect)
        let scale = min(container.width / canvas.width, container.height / canvas.height)
        let canvasFit = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white)
            SwiftUI.Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
        }
        .frame(width: canvasFit.width, height: canvasFit.height)
        .overlay(
            CropSelectionOverlay(
                rect: $rect,
                viewSize: canvasFit,
                sourceSize: canvas,
                aspect: lockedAspect,
                frameStyle: frameStyle,
                label: presetName,
                unit: unit,
                outputSize: effectiveTargetSize(),
                onEdit: { rectEdited = true },
                onReset: { reset() }
            )
        )
        // flatten canvas + page into one layer, otherwise .shadow is applied to
        // each subview separately and the page gets its own shadow on the canvas
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    @ViewBuilder var previewBar: some View {
        HStack {
            if optimiser.type.isPDF, pageCount > 1 {
                Button(action: { pageIndex = max(pageIndex - 1, 0) }) {
                    SwiftUI.Image(systemName: "chevron.left")
                }
                .disabled(pageIndex == 0)
                Text("Page \(pageIndex + 1) of \(pageCount)")
                    .font(.round(11))
                    .monospacedDigit()
                Button(action: { pageIndex = min(pageIndex + 1, pageCount - 1) }) {
                    SwiftUI.Image(systemName: "chevron.right")
                }
                .disabled(pageIndex == pageCount - 1)
            } else if optimiser.type.isVideo {
                SwiftUI.Image(systemName: "film")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Slider(value: $videoTime, in: 0 ... 1)
                    .frame(maxWidth: 300)
                    .controlSize(.small)
                    .help("Choose the video frame used for the crop preview")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
        .frame(height: 36)
        .onChange(of: pageIndex) { _ in Task { await loadPreview() } }
        .task(id: videoTimeDebounced) {
            guard optimiser.type.isVideo else { return }
            await loadPreview()
        }
    }

    var videoTimeDebounced: Int { (videoTime * 50).intround }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if optimiser.type.isPDF {
                        pdfPresets
                    } else {
                        aspectRatios
                        Divider()
                        sizePresets
                    }
                }
                .padding(.top, 30)
            }

            Spacer(minLength: 0)

            Divider()
            dimensionFields
            actionButtons
        }
        .padding([.horizontal, .bottom])
    }

    var aspectRatios: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Aspect ratio")
                Spacer()
                orientationPicker.fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4)], alignment: .leading, spacing: 4) {
                chip("Free", freeform: true, selected: lockedAspect == nil) { unlockAspect() }
                ForEach(DEFAULT_CROP_ASPECT_RATIOS.map { $0.withOrientation(cropOrientation, for: sourceSize) }) { size in
                    chip(size.name, aspect: size.aspectRatio, selected: presetName == size.name) { applyAspectPreset(size) }
                }
            }
        }
    }

    @ViewBuilder func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .kerning(0.7)
            .foregroundColor(.secondary)
    }

    @ViewBuilder func chip(_ title: String, aspect: Double? = nil, freeform: Bool = false, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if freeform {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .foregroundColor(selected ? Color.accentColor : .secondary)
                        .frame(width: 10, height: 10)
                        .frame(width: 16, height: 11)
                } else if let aspect {
                    AspectIcon(aspect: aspect, selected: selected)
                }
                Text(title)
                    .font(.round(10.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var orientationPicker: some View {
        Picker("", selection: $cropOrientation) {
            Label("Portrait", systemImage: "rectangle.portrait").tag(CropOrientation.portrait)
                .help("Crop the \(optimiser.type.str) to a portrait orientation.")
            if optimiser.type.isPDF {
                Label("Adaptive", systemImage: "sparkles.rectangle.stack").tag(CropOrientation.adaptive)
                    .help("Crop all pages to the specified size while keeping the original orientation of each page.")
            }
            Label("Landscape", systemImage: "rectangle").tag(CropOrientation.landscape)
                .help("Crop the \(optimiser.type.str) to a landscape orientation.")
        }
        .pickerStyle(.segmented)
        .labelStyle(IconOnlyLabelStyle())
        .font(.heavy(10))
        .onChange(of: cropOrientation) { orientation in
            guard orientation != .adaptive else { return }
            if let aspect = lockedAspect {
                let oriented = orientation == .landscape ? max(aspect, 1 / aspect) : min(aspect, 1 / aspect)
                guard oriented != aspect else { return }
                lockedAspect = oriented
                rect = centeredMaxRect(aspect: oriented)
            }
        }
    }

    var sizePresets: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Size presets")
            VStack(spacing: 3) {
                ForEach(savedCropSizes.filter { !$0.isAspectRatio && $0.cropRect == nil }.sorted(by: \.area)) { size in
                    let resolved = size.computedSize(from: sourceSize)
                    SizePresetRow(
                        size: size,
                        iconAspect: resolved.height > 0 ? resolved.width / resolved.height : 1,
                        selected: presetName == size.name && targetSize != nil,
                        disabled: size.width > sourceSize.width.i || size.height > sourceSize.height.i,
                        apply: { applySizePreset(size) },
                        delete: {
                            withAnimation(.easeOut(duration: 0.1)) {
                                savedCropSizes.removeAll(where: { $0.id == size.id })
                            }
                        }
                    )
                }
            }
            if !savedCropSizes.contains(where: { $0.width == pixelWidth && $0.height == pixelHeight }) {
                saveField
            }
            if !savedCropSizes.contains(DEFAULT_CROP_SIZES) {
                Button("Bring back default sizes") {
                    Defaults[.savedCropSizes] = DEFAULT_CROP_SIZES + Defaults[.savedCropSizes].without(DEFAULT_CROP_SIZES)
                }
                .buttonStyle(.link)
                .font(.round(10))
            }
        }
    }

    var saveField: some View {
        HStack(spacing: 4) {
            TextField("", text: $saveName, prompt: Text("Save \(pixelWidth.s)×\(pixelHeight.s) as…"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused, equals: .name)

            Button(action: {
                guard !saveName.isEmpty, pixelWidth > 0, pixelHeight > 0 else { return }
                savedCropSizes.append(CropSize(width: pixelWidth, height: pixelHeight, name: saveName))
                saveName = ""
            }, label: {
                SwiftUI.Image(systemName: "plus")
                    .font(.heavy(10))
                    .foregroundColor(.mauvish)
            })
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(saveName.isEmpty || savedCropSizes.contains(where: { $0.width == pixelWidth && $0.height == pixelHeight }))
        }
        .padding(.top, 2)
    }

    var pdfPresets: some View {
        VStack(alignment: .leading) {
            sectionHeader("Paper size")
            CropSizeGroupPicker(selection: $paperSize, categories: PAPER_SIZE_GROUPS)
            sectionHeader("Device size")
            CropSizeGroupPicker(selection: $deviceSize, categories: DEVICE_SIZE_GROUPS)
            sectionHeader("Aspect ratio")
            Picker("", selection: $ratioSize) {
                Text("No selection").tag(nil as CropSize?)
                Divider()
                ForEach(DEFAULT_CROP_ASPECT_RATIOS.filter { $0.name != "A4" && $0.name != "B5" }, id: \.name) { size in
                    Text(size.name).tag(size as CropSize?)
                }
            }.font(.medium(10))

            orientationPicker
                .fixedSize()
                .padding(.top, 4)

            Toggle("Extend instead of clipping", isOn: $extendPage)
                .toggleStyle(.checkbox)
                .font(.round(10))
                .padding(.top, 4)
                .help("Grows pages with empty paper instead of cutting content away. Useful for fitting a book page on a phone screen without losing text at the edges.")
                .onChange(of: extendPage) { extend in
                    guard adaptiveAspect != nil else { return }
                    // the selection space switches between page and extended canvas
                    rectEdited = false
                    rect = extend ? .full : (lockedAspect.map { centeredMaxRect(aspect: $0) } ?? initialRect)
                }

            uncropButton
        }
        .onChange(of: paperSize) { size in
            guard let size else { return }
            deviceSize = nil
            ratioSize = nil
            applyAspectPreset(size, style: .paper)
        }
        .onChange(of: deviceSize) { size in
            guard let size else { return }
            paperSize = nil
            ratioSize = nil
            applyAspectPreset(size, style: .device)
        }
        .onChange(of: ratioSize) { size in
            guard let size else { return }
            paperSize = nil
            deviceSize = nil
            applyAspectPreset(size)
        }
    }

    @ViewBuilder var uncropButton: some View {
        if let pdf = optimiser.pdf, let originalSize = pdf.originalSize, originalSize != pdf.size {
            Button("Uncrop to \(originalSize.s)") {
                pdf.uncrop()
                optimiser.oldSize = originalSize
                optimiser.newSize = nil
                reset()
                Task { await loadPreview() }
            }
            .font(.round(10))
        }
    }

    var dimensionFields: some View {
        HStack {
            TextField("", value: widthBinding, formatter: NumberFormatter.int, prompt: Text("Width"))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .width)
                .frame(width: 60, alignment: .center)
                .multilineTextAlignment(.center)
            Text("×")
            TextField("", value: heightBinding, formatter: NumberFormatter.int, prompt: Text("Height"))
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .height)
                .frame(width: 60, alignment: .center)
                .multilineTextAlignment(.center)
            Text(unit)
                .font(.round(10))
                .foregroundColor(.secondary)
            if !optimiser.type.isPDF {
                Spacer()
                orientationFreeIndicator
            }
        }
    }

    @ViewBuilder var orientationFreeIndicator: some View {
        if lockedAspect != nil {
            Button(action: { unlockAspect() }) {
                SwiftUI.Image(systemName: "lock.fill").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Aspect ratio locked, click to unlock")
        }
    }

    var actionButtons: some View {
        HStack {
            Button("Reset") { reset() }
                .buttonStyle(.bordered)
                .fontDesign(.rounded)

            Spacer()

            Button(action: { applyCrop() }, label: {
                Text(cropButtonTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            })
                .buttonStyle(.borderedProminent)
                .fontDesign(.rounded)
                .monospacedDigit()
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(optimiser.running || nothingToCrop)
                .help("Press ⌘⏎ to crop")
        }
    }

    var nothingToCrop: Bool {
        guard adaptiveAspect == nil else { return false }
        let target = effectiveTargetSize()
        let selection = rect.computedSize(from: sourceSize)
        let unchanged = rect == initialRect
        let noResize = target.width >= selection.width - 1 && target.height >= selection.height - 1
        return unchanged && noResize
    }

    var cropButtonTitle: String {
        if optimiser.type.isPDF, adaptiveAspect != nil, extendPage || !rectEdited {
            return "\(extendPage ? "Extend" : "Crop") PDF to \(presetShortName)"
        }
        let out = effectiveTargetSize()
        return "Crop to \(out.width.i)×\(out.height.i)"
    }

    /// Compact preset name for the apply button: the device category for device
    /// groups, the paper/ratio name without its ratio suffix otherwise.
    var presetShortName: String {
        guard let aspect = adaptiveAspect else { return "" }
        if let category = DEVICE_SIZE_GROUPS.first(where: { $0.groups.contains { $0.name == aspect.name } })?.category {
            return category
        }
        return aspect.name.components(separatedBy: " (").first ?? aspect.name
    }

    // the size of the file that will be produced (selection size, or the preset
    // target when the selection gets scaled down to it)
    var pixelWidth: Int { effectiveTargetSize().width.i }
    var pixelHeight: Int { effectiveTargetSize().height.i }

    var widthBinding: Binding<Int> {
        Binding(get: { pixelWidth }, set: { setPixelSize(width: $0) })
    }
    var heightBinding: Binding<Int> {
        Binding(get: { pixelHeight }, set: { setPixelSize(height: $0) })
    }

    // MARK: Logic

    func setup() {
        let size = optimiser.newSize ?? optimiser.oldSize ?? NSSize(width: 1, height: 1)
        sourceSize = size
        cropOrientation = optimiser.type.isPDF ? .adaptive : size.orientation

        // re-cropping starts from the uncropped original with the current crop pre-selected,
        // restoring the preset/ratio/target state it was applied with
        if !optimiser.type.isPDF, cropSourceURL != optimiser.url, let last = optimiser.lastCropSize, let lastRect = last.cropRect {
            if !lastRect.isFullFrame {
                initialRect = lastRect.clamped()
                rect = initialRect
            }
            if last.name.isNotEmpty {
                presetName = last.name
                lockedAspect = last.aspectRatio
                targetSize = last.ns
            } else if lastRect.isFullFrame {
                // a full-frame crop is a plain downscale: the target is the whole point
                targetSize = last.ns
            }
        }
    }

    func fittedSize(in container: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / sourceSize.width, container.height / sourceSize.height)
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }

    func unlockAspect() {
        lockedAspect = nil
        targetSize = nil
        presetName = nil
        frameStyle = .plain
        adaptiveAspect = nil
        paperSize = nil
        deviceSize = nil
        ratioSize = nil
    }

    func reset() {
        rect = initialRect
        rectEdited = false
        unlockAspect()
    }

    func centeredMaxRect(aspect: Double) -> CropRect {
        let space = cropSpaceSize
        let w = min(space.width, space.height * aspect)
        let h = w / aspect
        let rw = w / space.width
        let rh = h / space.height
        return CropRect(x: (1 - rw) / 2, y: (1 - rh) / 2, width: rw, height: rh).clamped()
    }

    func applyAspectPreset(_ size: CropSize, style: CropFrameStyle = .plain) {
        let oriented = size.withOrientation(optimiser.type.isPDF && cropOrientation == .adaptive ? sourceSize.orientation : cropOrientation, for: sourceSize)
        let aspect = oriented.width.d / oriented.height.d
        lockedAspect = aspect
        targetSize = nil
        presetName = size.name
        frameStyle = style
        adaptiveAspect = optimiser.type.isPDF ? size : nil
        rect = centeredMaxRect(aspect: aspect)
        rectEdited = false
        if !size.isAspectRatio, cropOrientation != .adaptive {
            cropOrientation = oriented.orientation
        }
    }

    func applySizePreset(_ size: CropSize) {
        // resolves Auto (zero) dimensions and long-edge presets against the source size
        let target = size.computedSize(from: sourceSize)
        guard target.width > 0, target.height > 0 else { return }

        let aspect = target.width / target.height
        lockedAspect = aspect
        targetSize = target
        presetName = size.name
        frameStyle = .plain
        adaptiveAspect = nil
        // match the optimisation behaviour: the maximal centered region of the
        // target aspect is kept, then scaled down to the preset size
        rect = centeredMaxRect(aspect: aspect)
        rectEdited = false
    }

    func setPixelSize(width: Int? = nil, height: Int? = nil) {
        var w = (width ?? pixelWidth).d
        var h = (height ?? pixelHeight).d
        if let aspect = lockedAspect {
            if width != nil {
                h = w / aspect
            } else {
                w = h * aspect
            }
        }
        let space = cropSpaceSize
        w = min(max(w, 8), space.width)
        h = min(max(h, 8), space.height)

        let center = CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        rect = CropRect(
            x: center.x - (w / space.width) / 2,
            y: center.y - (h / space.height) / 2,
            width: w / space.width,
            height: h / space.height
        ).clamped()
        rectEdited = true
        targetSize = nil
        presetName = nil
    }

    func effectiveTargetSize() -> NSSize {
        let rectPixels = rect.computedSize(from: cropSpaceSize)
        if let target = targetSize, target.width <= rectPixels.width, target.height <= rectPixels.height {
            return target
        }
        return rectPixels
    }

    func applyCrop() {
        defer { optimiser.cropWindowController?.close() }

        if optimiser.type.isPDF, let pdf = optimiser.pdf {
            if let aspect = adaptiveAspect, extendPage {
                // an edited selection is normalized to each page's extended canvas
                pdf.extendTo(
                    aspectRatio: aspect.fractionalAspectRatio,
                    alwaysPortrait: cropOrientation == .portrait,
                    alwaysLandscape: cropOrientation == .landscape,
                    rect: rectEdited ? rect.clamped() : nil
                )
            } else if let aspect = adaptiveAspect, !rectEdited {
                // aspect-based crop adapts to each page's size and orientation,
                // a shared rect would distort on mixed-orientation documents
                pdf.cropTo(
                    aspectRatio: aspect.fractionalAspectRatio,
                    alwaysPortrait: cropOrientation == .portrait,
                    alwaysLandscape: cropOrientation == .landscape
                )
            } else {
                pdf.cropTo(rect: rect)
            }
            optimiser.refetch()
            // extending rewrites the media box, so the pre-extend size is the reference
            optimiser.oldSize = extendPage ? sourceSize : (optimiser.pdf?.originalSize ?? sourceSize)
            optimiser.newSize = optimiser.pdf?.size
            return
        }

        let out = effectiveTargetSize()
        // the rect is attached even when full-frame (a plain downscale) so the operation
        // runs from the pristine original and can be re-opened with its state restored
        optimiser.crop(to: CropSize(
            width: out.width.evenInt, height: out.height.evenInt,
            name: presetName ?? "",
            cropRect: rect.clamped()
        ))
    }

    // MARK: Preview loading

    /// Re-crops start from the pristine original (the optimisation pipeline operates on
    /// the backup), so the preview must show the uncropped file
    var cropSourceURL: URL? {
        guard let url = optimiser.url else { return nil }
        guard !optimiser.type.isPDF else { return url }
        return optimiser.cropOriginalURL ?? url
    }

    func loadPreview() async {
        guard let url = cropSourceURL else { return }

        switch optimiser.type {
        case .image:
            let maxPixels = 2600.0
            let result = await Task.detached { () -> (NSImage, NSSize)? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

                var size = NSSize(width: cg.width.d, height: cg.height.d)
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   var w = props[kCGImagePropertyPixelWidth] as? Double,
                   var h = props[kCGImagePropertyPixelHeight] as? Double
                {
                    if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
                        swap(&w, &h)
                    }
                    size = NSSize(width: w, height: h)
                }
                return (NSImage(cgImage: cg, size: .zero), size)
            }.value
            if let (img, size) = result {
                preview = img
                sourceSize = size
            }
        case .video:
            let time = videoTime
            let result = await Task.detached { () async -> (NSImage, NSSize?)? in
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 2000, height: 2000)
                guard let duration = try? await asset.load(.duration) else { return nil }
                let cmTime = CMTime(seconds: duration.seconds * time, preferredTimescale: 600)
                guard let (cg, _) = try? await generator.image(at: cmTime) else { return nil }

                var size: NSSize? = nil
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let naturalSize = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform)
                {
                    let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
                    size = NSSize(width: abs(transformed.width), height: abs(transformed.height))
                }
                return (NSImage(cgImage: cg, size: .zero), size)
            }.value
            if let (img, size) = result {
                preview = img
                if let size, size.width > 0, size.height > 0 {
                    sourceSize = size
                }
            }
        case .pdf:
            guard let document = optimiser.pdf?.document ?? PDFDocument(url: url) else { return }
            pageCount = document.pageCount
            guard let page = document.page(at: min(pageIndex, max(pageCount - 1, 0))) else { return }

            let media = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            sourceSize = rotated ? NSSize(width: media.height, height: media.width) : media.size

            // start from the current crop box so re-cropping is visible and reversible
            let crop = page.bounds(for: .cropBox)
            if crop != media, media.width > 0, media.height > 0 {
                let mediaSpace = CropRect(
                    x: (crop.minX - media.minX) / media.width,
                    y: (media.maxY - crop.maxY) / media.height,
                    width: crop.width / media.width,
                    height: crop.height / media.height
                )
                initialRect = mediaSpace.rotated(by: 360 - page.rotation).clamped()
            } else {
                initialRect = .full
            }
            if !rectEdited, lockedAspect == nil {
                rect = initialRect
            }

            let scale = 2200 / max(sourceSize.width, sourceSize.height)
            let thumbSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            // PDFPage.thumbnail draws a bezel border around the page, which shows as
            // a seam when the page sits inside the extended white canvas, so the page
            // is rendered manually on plain white
            let img = NSImage(size: thumbSize)
            img.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                NSColor.white.setFill()
                CGRect(origin: .zero, size: thumbSize).fill()
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            img.unlockFocus()
            preview = img
        default:
            break
        }
    }
}
