import Defaults
import Foundation
import Lowtech
import SwiftUI

enum FloatingAction: String, CaseIterable, Codable, Defaults.Serializable, Identifiable {
    case downscale
    case share
    case restoreOptimise
    case aggressiveOptimisation
    case copyToClipboard
    case showInFinder
    case quickLook
    case saveAs
    case addToShelf
    case sendSecurely

    static let maxFloatingButtons = 5
    static let maxCompactButtons = 9
    static let defaultFloating: [FloatingAction] = [.downscale, .share, .restoreOptimise, .aggressiveOptimisation]
    static let defaultCompact: [FloatingAction] = [.downscale, .quickLook, .restoreOptimise, .aggressiveOptimisation, .showInFinder, .saveAs, .copyToClipboard, .share]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downscale: "Downscale"
        case .share: "Share"
        case .restoreOptimise: "Restore / Optimise"
        case .aggressiveOptimisation: "Aggressive optimisation"
        case .copyToClipboard: "Copy to clipboard"
        case .showInFinder: "Show in Finder"
        case .quickLook: "QuickLook"
        case .saveAs: "Save as..."
        case .addToShelf: "Add to shelf"
        case .sendSecurely: "Send securely"
        }
    }

    var icon: String {
        switch self {
        case .downscale: "minus"
        case .share: "square.and.arrow.up"
        case .restoreOptimise: "arrow.uturn.backward"
        case .aggressiveOptimisation: "bolt.horizontal"
        case .copyToClipboard: "doc.on.doc"
        case .showInFinder: "folder"
        case .quickLook: "eye"
        case .saveAs: "square.and.arrow.down"
        case .addToShelf: "tray.and.arrow.down"
        case .sendSecurely: "lock.shield"
        }
    }

    func label(for type: ItemType) -> String {
        switch self {
        case .downscale where type.isAudio: "Lower bitrate"
        default: label
        }
    }

}

struct CloseStopButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                guard !preview else { return }

                hoveredOptimiserID = nil
                optimiser.stop(remove: !OM.compactResults || !optimiser.running, animateRemoval: true)
                optimiser.uiStop()
            },
            label: { SwiftUI.Image(systemName: optimiser.running ? "stop.fill" : "xmark").font(.heavy(9)) }
        ).contentShape(Rectangle())

    }
}

struct RestoreOptimiseButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        if optimiser.isOriginal {
            Button(
                action: { if !preview { optimiser.optimise(allowLarger: false) } },
                label: { SwiftUI.Image(systemName: "goforward.plus").font(.heavy(9)) }
            )
            .contentShape(Rectangle())
        } else {
            Button(
                action: { if !preview { optimiser.restoreOriginal() } },
                label: { SwiftUI.Image(systemName: "arrow.uturn.left").font(.semibold(9)) }
            )
            .contentShape(Rectangle())
        }
    }
}

struct ChangePlaybackSpeedButton: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        let factor = optimiser.changePlaybackSpeedFactor.truncatingRemainder(dividingBy: 1) != 0
            ? String(format: "%.\(optimiser.changePlaybackSpeedFactor == 1.5 ? 1 : 2)f", optimiser.changePlaybackSpeedFactor)
            : optimiser.changePlaybackSpeedFactor.i.s
        Menu("\(factor)x") {
            ChangePlaybackSpeedMenu(optimiser: optimiser)
        }
        .menuButtonStyle(BorderlessButtonMenuButtonStyle())
        .buttonStyle(FlatButton(color: .clear, textColor: .white, circle: optimiser.changePlaybackSpeedFactor >= 2))
        .font(.round(11, weight: .bold))
    }
}

struct DownscaleButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(action: {}, label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) })
            .contentShape(Rectangle())
            .onMouseDown {
                guard !preview else { return }
                optimiser.showDownscaleSlider = true
            }
            .onRightClick {
                optimiser.showDownscaleSlider = true
            }
    }
}

// MARK: - DownscaleSlider

struct DownscaleSlider: View {
    static let thresholds: [Double] = [1.0, 0.75, 0.5, 0.25, 0.1]

    @ObservedObject var optimiser: Optimiser

    @Default(.floatingResultsCorner) var floatingResultsCorner

    var size: CGFloat

    var displayFactor: Double {
        dragFactor ?? optimiser.downscaleFactor
    }

    var body: some View {
        GeometryReader { geo in
            let knobSize = size * 0.8
            let trackTop = knobSize / 2
            let trackHeight = max(geo.size.height - knobSize, 1)
            let centerX = geo.size.width / 2

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.15))
                    .frame(width: 3, height: trackHeight)
                    .position(x: centerX, y: geo.size.height / 2)

                // Tick marks
                ForEach(Self.thresholds, id: \.self) { threshold in
                    let y = yPosition(for: threshold, trackTop: trackTop, trackHeight: trackHeight)
                    let isActive = abs(displayFactor - threshold) < 0.01

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(isActive ? 0.7 : 0.3))
                        .frame(width: size * 0.55, height: isActive ? 2 : 1.5)
                        .position(x: centerX, y: y)
                }

                // Knob with tooltip
                let knobY = yPosition(for: displayFactor, trackTop: trackTop, trackHeight: trackHeight)
                let isTrailing = floatingResultsCorner.isTrailing
                let tooltipOffset = knobSize / 2 + 34
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay {
                        Text("\((displayFactor * 100).intround)%")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .offset(x: isTrailing ? -tooltipOffset : tooltipOffset)
                    }
                    .position(x: centerX, y: knobY)
            }
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .overlay(
            SliderEventOverlay(
                buttonSize: size,
                onDrag: { factor in
                    dragFactor = factor
                    optimiser.stepIndicator = "\((factor * 100).intround)%"
                },
                onRelease: { factor in
                    let startFactor = optimiser.downscaleFactor
                    dragFactor = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                    if abs(factor - startFactor) > 0.01 {
                        optimiser.downscale(toFactor: factor)
                    }
                },
                onCancel: {
                    dragFactor = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                }
            )
        )
    }

    func yPosition(for factor: Double, trackTop: CGFloat, trackHeight: CGFloat) -> CGFloat {
        trackTop + (1.0 - factor) / 0.9 * trackHeight
    }

    @State private var dragFactor: Double?

}

// MARK: - HorizontalDownscaleSlider

struct HorizontalDownscaleSlider: View {
    static let thresholds: [Double] = [1.0, 0.75, 0.5, 0.25, 0.1]

    @ObservedObject var optimiser: Optimiser

    var size: CGFloat

    var displayFactor: Double {
        dragFactor ?? optimiser.downscaleFactor
    }

    var body: some View {
        GeometryReader { geo in
            let knobSize = size * 0.8
            let trackLeft = knobSize / 2
            let trackWidth = max(geo.size.width - knobSize, 1)
            let centerY = geo.size.height / 2

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.15))
                    .frame(width: trackWidth, height: 3)
                    .position(x: geo.size.width / 2, y: centerY)

                // Tick marks
                ForEach(Self.thresholds, id: \.self) { threshold in
                    let x = xPosition(for: threshold, trackLeft: trackLeft, trackWidth: trackWidth)
                    let isActive = abs(displayFactor - threshold) < 0.01

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(isActive ? 0.7 : 0.3))
                        .frame(width: isActive ? 2 : 1.5, height: size * 0.55)
                        .position(x: x, y: centerY)
                }

                // Knob with tooltip
                let knobX = xPosition(for: displayFactor, trackLeft: trackLeft, trackWidth: trackWidth)
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay(alignment: .top) {
                        Text("\((displayFactor * 100).intround)%")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .offset(y: -knobSize - 4)
                    }
                    .position(x: knobX, y: centerY)
            }
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .overlay(
            SliderEventOverlay(
                buttonSize: size,
                isHorizontal: true,
                onDrag: { factor in
                    dragFactor = factor
                    optimiser.stepIndicator = "\((factor * 100).intround)%"
                },
                onRelease: { factor in
                    let startFactor = optimiser.downscaleFactor
                    dragFactor = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                    if abs(factor - startFactor) > 0.01 {
                        optimiser.downscale(toFactor: factor)
                    }
                },
                onCancel: {
                    dragFactor = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                }
            )
        )
    }

    func xPosition(for factor: Double, trackLeft: CGFloat, trackWidth: CGFloat) -> CGFloat {
        trackLeft + (1.0 - factor) / 0.9 * trackWidth
    }

    @State private var dragFactor: Double?
}

// MARK: - BitrateSlider (vertical)

struct BitrateSlider: View {
    @ObservedObject var optimiser: Optimiser

    var size: CGFloat

    @Default(.audioFormat) var audioFormat
    @Default(.audioBitrate) var defaultBitrate
    @Default(.floatingResultsCorner) var floatingResultsCorner

    var bitrates: [Int] { audioFormat.allowedBitrates }
    var currentBitrate: Int { dragBitrate ?? optimiser.audioBitrateOverride ?? defaultBitrate }

    var body: some View {
        GeometryReader { geo in
            let knobSize = size * 0.8
            let trackTop = knobSize / 2
            let trackHeight = max(geo.size.height - knobSize, 1)
            let centerX = geo.size.width / 2

            ZStack {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.15))
                    .frame(width: 3, height: trackHeight)
                    .position(x: centerX, y: geo.size.height / 2)

                ForEach(Array(bitrates.enumerated()), id: \.offset) { index, bitrate in
                    let y = yPosition(for: index, trackTop: trackTop, trackHeight: trackHeight)
                    let isActive = bitrate == currentBitrate

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(isActive ? 0.7 : 0.3))
                        .frame(width: size * 0.55, height: isActive ? 2 : 1.5)
                        .position(x: centerX, y: y)
                }

                if let index = bitrates.firstIndex(of: currentBitrate) {
                    let knobY = yPosition(for: index, trackTop: trackTop, trackHeight: trackHeight)
                    let isTrailing = floatingResultsCorner.isTrailing
                    let tooltipOffset = knobSize / 2 + 40
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .overlay {
                            Text("\(currentBitrate) kbps")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundColor(.primary)
                                .fixedSize()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .offset(x: isTrailing ? -tooltipOffset : tooltipOffset)
                        }
                        .position(x: centerX, y: knobY)
                }
            }
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .overlay(
            SliderEventOverlay(
                buttonSize: size,
                onDrag: { factor in
                    let idx = bitrateIndex(for: factor)
                    dragBitrate = bitrates[idx]
                    optimiser.stepIndicator = "\(bitrates[idx]) kbps"
                },
                onRelease: { factor in
                    let idx = bitrateIndex(for: factor)
                    let newBitrate = bitrates[idx]
                    let startBitrate = optimiser.audioBitrateOverride ?? defaultBitrate
                    dragBitrate = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                    if newBitrate != startBitrate {
                        optimiser.lowerBitrate(to: newBitrate)
                    }
                },
                onCancel: {
                    dragBitrate = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                }
            )
        )
    }

    func yPosition(for index: Int, trackTop: CGFloat, trackHeight: CGFloat) -> CGFloat {
        let count = bitrates.count
        guard count > 1 else { return trackTop }
        return trackTop + CGFloat(count - 1 - index) / CGFloat(count - 1) * trackHeight
    }

    func bitrateIndex(for factor: Double) -> Int {
        let count = bitrates.count
        guard count > 1 else { return 0 }
        let normalized = (factor - 0.1) / 0.9
        return max(0, min(count - 1, Int(round(normalized * Double(count - 1)))))
    }

    @State private var dragBitrate: Int?
}

// MARK: - HorizontalBitrateSlider

struct HorizontalBitrateSlider: View {
    @ObservedObject var optimiser: Optimiser

    var size: CGFloat

    @Default(.audioFormat) var audioFormat
    @Default(.audioBitrate) var defaultBitrate

    var bitrates: [Int] { audioFormat.allowedBitrates }
    var currentBitrate: Int { dragBitrate ?? optimiser.audioBitrateOverride ?? defaultBitrate }

    var body: some View {
        GeometryReader { geo in
            let knobSize = size * 0.8
            let trackLeft = knobSize / 2
            let trackWidth = max(geo.size.width - knobSize, 1)
            let centerY = geo.size.height / 2

            ZStack {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.15))
                    .frame(width: trackWidth, height: 3)
                    .position(x: geo.size.width / 2, y: centerY)

                ForEach(Array(bitrates.enumerated()), id: \.offset) { index, bitrate in
                    let x = xPosition(for: index, trackLeft: trackLeft, trackWidth: trackWidth)
                    let isActive = bitrate == currentBitrate

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(isActive ? 0.7 : 0.3))
                        .frame(width: isActive ? 2 : 1.5, height: size * 0.55)
                        .position(x: x, y: centerY)
                }

                if let index = bitrates.firstIndex(of: currentBitrate) {
                    let knobX = xPosition(for: index, trackLeft: trackLeft, trackWidth: trackWidth)
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .overlay(alignment: .top) {
                            Text("\(currentBitrate) kbps")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundColor(.primary)
                                .fixedSize()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .offset(y: -knobSize - 4)
                        }
                        .position(x: knobX, y: centerY)
                }
            }
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .overlay(
            SliderEventOverlay(
                buttonSize: size,
                isHorizontal: true,
                onDrag: { factor in
                    let idx = bitrateIndex(for: factor)
                    dragBitrate = bitrates[idx]
                    optimiser.stepIndicator = "\(bitrates[idx]) kbps"
                },
                onRelease: { factor in
                    let idx = bitrateIndex(for: factor)
                    let newBitrate = bitrates[idx]
                    let startBitrate = optimiser.audioBitrateOverride ?? defaultBitrate
                    dragBitrate = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                    if newBitrate != startBitrate {
                        optimiser.lowerBitrate(to: newBitrate)
                    }
                },
                onCancel: {
                    dragBitrate = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                }
            )
        )
    }

    func xPosition(for index: Int, trackLeft: CGFloat, trackWidth: CGFloat) -> CGFloat {
        let count = bitrates.count
        guard count > 1 else { return trackLeft }
        return trackLeft + CGFloat(count - 1 - index) / CGFloat(count - 1) * trackWidth
    }

    func bitrateIndex(for factor: Double) -> Int {
        let count = bitrates.count
        guard count > 1 else { return 0 }
        let normalized = (factor - 0.1) / 0.9
        return max(0, min(count - 1, Int(round(normalized * Double(count - 1)))))
    }

    @State private var dragBitrate: Int?
}

// MARK: - Slider AppKit event handler

private struct SliderEventOverlay: NSViewRepresentable {
    class SliderEventView: NSView {
        static let thresholds: [Double] = [1.0, 0.75, 0.5, 0.25, 0.1]
        static let snapDistance = 0.04

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        var buttonSize: CGFloat = 24
        var isHorizontal = false
        var onDrag: ((Double) -> Void)?
        var onRelease: ((Double) -> Void)?
        var onCancel: (() -> Void)?

        var directTracking = false
        var didDrag = false
        var dragMonitor: Any?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Direct interaction (user clicks on the slider itself)
        override func mouseDown(with event: NSEvent) {
            directTracking = true
            didDrag = false
            let loc = convert(event.locationInWindow, from: nil)
            onDrag?(factorForLocation(loc))
        }

        override func mouseDragged(with event: NSEvent) {
            guard directTracking else { return }
            didDrag = true
            let loc = convert(event.locationInWindow, from: nil)
            onDrag?(factorForLocation(loc))
        }

        override func mouseUp(with event: NSEvent) {
            guard directTracking else { return }
            directTracking = false
            let loc = convert(event.locationInWindow, from: nil)
            onRelease?(factorForLocation(loc))
        }

        override func rightMouseDown(with event: NSEvent) {
            onCancel?()
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?() }
            else { super.keyDown(with: event) }
        }

        // Monitor for drags that started outside (on the button)
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, dragMonitor == nil else { return }
            didDrag = false
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, window != nil, !self.directTracking else { return event }

                let location = convert(event.locationInWindow, from: nil)
                let f = factorForLocation(location)

                switch event.type {
                case .leftMouseDragged:
                    didDrag = true
                    onDrag?(f)
                case .leftMouseUp:
                    if didDrag {
                        onRelease?(f)
                    }
                    didDrag = false
                default:
                    break
                }
                return event
            }
        }

        override func removeFromSuperview() {
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
            dragMonitor = nil
            super.removeFromSuperview()
        }

        func factorForLocation(_ loc: CGPoint) -> Double {
            isHorizontal ? factor(forX: loc.x) : factor(forY: loc.y)
        }

        func factor(forY y: CGFloat) -> Double {
            let knobSize = buttonSize * 0.8
            let trackTop = knobSize / 2
            let trackHeight = max(bounds.height - knobSize, 1)
            let normalized = (y - trackTop) / trackHeight
            let raw = 1.0 - normalized * 0.9
            let clamped = max(0.1, min(1.0, raw))
            for t in Self.thresholds where abs(clamped - t) < Self.snapDistance {
                return t
            }
            return (clamped * 20).rounded() / 20
        }

        func factor(forX x: CGFloat) -> Double {
            let knobSize = buttonSize * 0.8
            let trackLeft = knobSize / 2
            let trackWidth = max(bounds.width - knobSize, 1)
            let normalized = (x - trackLeft) / trackWidth
            let raw = 1.0 - normalized * 0.9
            let clamped = max(0.1, min(1.0, raw))
            for t in Self.thresholds where abs(clamped - t) < Self.snapDistance {
                return t
            }
            return (clamped * 20).rounded() / 20
        }

    }

    var buttonSize: CGFloat
    var isHorizontal = false
    var onDrag: (Double) -> Void
    var onRelease: (Double) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> SliderEventView {
        let view = SliderEventView()
        view.buttonSize = buttonSize
        view.isHorizontal = isHorizontal
        view.onDrag = onDrag
        view.onRelease = onRelease
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: SliderEventView, context: Context) {
        nsView.buttonSize = buttonSize
        nsView.isHorizontal = isHorizontal
        nsView.onDrag = onDrag
        nsView.onRelease = onRelease
        nsView.onCancel = onCancel
    }

}

// MARK: - Right-click handler

private struct RightClickCatcher: NSViewRepresentable {
    class RightClickNSView: NSView {
        var action: (() -> Void)?
        var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, window != nil else { return event }
                let locationInView = convert(event.locationInWindow, from: nil)
                if bounds.contains(locationInView) {
                    action?()
                    return nil
                }
                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        // Transparent to all normal hit testing (left clicks pass through to SwiftUI)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    var action: () -> Void

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.action = action
    }

}

private struct MouseDownCatcher: NSViewRepresentable {
    class MouseDownNSView: NSView {
        var action: (() -> Void)?
        var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, window != nil else { return event }
                let locationInView = convert(event.locationInWindow, from: nil)
                if bounds.contains(locationInView) {
                    action?()
                }
                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    var action: () -> Void

    func makeNSView(context: Context) -> MouseDownNSView {
        let view = MouseDownNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MouseDownNSView, context: Context) {
        nsView.action = action
    }
}

extension View {
    func onMouseDown(perform action: @escaping () -> Void) -> some View {
        overlay(MouseDownCatcher(action: action))
    }

    func onRightClick(perform action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}

struct LowerBitrateButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(action: {}, label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) })
            .contentShape(Rectangle())
            .onMouseDown {
                guard !preview else { return }
                optimiser.showDownscaleSlider = true
            }
            .onRightClick {
                optimiser.showDownscaleSlider = true
            }
    }
}

struct QuickLookButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: { if !preview { optimiser.quicklook() }},
            label: { SwiftUI.Image(systemName: "eye").font(.heavy(9)) }
        )
        .contentShape(Rectangle())
    }
}

struct ShowInFinderButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: { if !preview { optimiser.showInFinder() }},
            label: { SwiftUI.Image(systemName: "folder").font(.heavy(9)) }
        )
        .contentShape(Rectangle())
    }
}

struct SaveAsButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: { if !preview { optimiser.save() }},
            label: { SwiftUI.Image(systemName: "square.and.arrow.down").font(.heavy(9)) }
        )
        .contentShape(Rectangle())
    }
}

struct CopyToClipboardButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                if !preview {
                    optimiser.copyToClipboard()
                }
                optimiser.overlayMessage = "Copied"
            },
            label: { SwiftUI.Image(systemName: "doc.on.doc").font(.heavy(9)) }
        )
        .contentShape(Rectangle())
    }
}

let SHARING_MANAGER = SharingManager()

struct ShareButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                guard !preview else { return }
                optimiser.sharing = true
            },
            label: { SwiftUI.Image(systemName: "square.and.arrow.up").font(.heavy(9)) }
        )
        .contentShape(Rectangle())
        .background(SharingsPicker(isPresented: $optimiser.sharing, sharingItems: [optimiser.url as Any]))
    }
}

struct AggressiveOptimisationButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                guard !preview else { return }

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
        )
        .contentShape(Rectangle())
    }
}

struct VideoEncoderButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                guard !preview else { return }
                optimiser.reoptimiseWithEncoder(.slowHighQuality)
            },
            label: { SwiftUI.Image(systemName: "bolt").font(.heavy(9)) }
        )
        .contentShape(Rectangle())
    }
}

struct WarpDropActiveButton: View {
    let session: WarpDropSession
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    @State private var glowing = false

    var body: some View {
        Menu {
            Button {
                if !preview {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(session.directURL, forType: .string)
                    optimiser.overlayMessage = "Copied link"
                }
            } label: {
                Label("Copy Download Link", systemImage: "arrow.down.circle")
            }
            Button {
                if !preview {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(session.roomURL, forType: .string)
                    optimiser.overlayMessage = "Copied link"
                }
            } label: {
                Label("Copy Room Link", systemImage: "link")
            }
            Button {
                if !preview {
                    NSWorkspace.shared.open(URL(string: session.roomURL)!)
                }
            } label: {
                Label("Open Room", systemImage: "globe")
            }
            Divider()
            Button(role: .destructive) {
                if !preview {
                    WDM.stopSession(session)
                }
            } label: {
                Label("Stop Transfer", systemImage: "xmark.circle")
            }
        } label: {
            SwiftUI.Image(systemName: "link").font(.heavy(9))
                .foregroundColor(glowing ? Color.red : Color.primary)
                .shadow(color: .red.opacity(glowing ? 0.5 : 0), radius: glowing ? 4 : 0)
        }
        .menuButtonStyle(BorderlessButtonMenuButtonStyle())
        .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { glowing = true } }
        .onDisappear { glowing = false }
    }
}

struct ActionButton: View {
    let action: FloatingAction
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        switch action {
        case .downscale:
            if optimiser.type.isAudio {
                LowerBitrateButton(optimiser: optimiser)
            } else {
                DownscaleButton(optimiser: optimiser)
            }
        case .share:
            ShareButton(optimiser: optimiser)
        case .restoreOptimise:
            RestoreOptimiseButton(optimiser: optimiser)
                .disabled(optimiser.url == nil || optimiser.running)
        case .aggressiveOptimisation:
            if optimiser.type.isVideo {
                VideoEncoderButton(optimiser: optimiser)
            } else {
                AggressiveOptimisationButton(optimiser: optimiser)
            }
        case .copyToClipboard:
            Button(action: { if !preview { optimiser.copyToClipboard(); optimiser.overlayMessage = "Copied" } }) {
                SwiftUI.Image(systemName: "doc.on.doc").font(.heavy(9))
            }
            .contentShape(Rectangle())
        case .showInFinder:
            ShowInFinderButton(optimiser: optimiser)
        case .quickLook:
            QuickLookButton(optimiser: optimiser)
        case .saveAs:
            Button(action: { if !preview { optimiser.save() } }) {
                SwiftUI.Image(systemName: "square.and.arrow.down").font(.heavy(9))
            }
            .contentShape(Rectangle())
        case .addToShelf:
            Button(action: { if !preview, let app = runningShelfApp() { app.open(optimiser: optimiser) } }) {
                SwiftUI.Image(systemName: "tray.and.arrow.down").font(.heavy(9))
            }
            .contentShape(Rectangle())
        case .sendSecurely:
            if optimiser.warpDropConnecting {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else if let session = WDM.session(forOptimiser: optimiser) {
                WarpDropActiveButton(session: session, optimiser: optimiser)
            } else {
                Button(action: { if !preview { warpDropSend(optimiser: optimiser) } }) {
                    SwiftUI.Image(systemName: "link").font(.heavy(9))
                }
                .contentShape(Rectangle())
            }
        }
    }

    func isAvailable() -> Bool {
        switch action {
        case .downscale: optimiser.canDownscale()
        case .aggressiveOptimisation: optimiser.canReoptimise() && (optimiser.type.isVideo || !optimiser.aggressive)
        case .addToShelf: runningShelfApp() != nil
        default: true
        }
    }
}

struct SideButtons: View {
    @ObservedObject var optimiser: Optimiser
    var size: CGFloat
    var actions: [FloatingAction]? = nil

    @Environment(\.preview) var preview
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.floatingResultActions) var floatingResultActions

    @State var hoveringAction: FloatingAction?

    var effectiveActions: [FloatingAction] {
        actions ?? floatingResultActions
    }

    var body: some View {
        let isTrailing = floatingResultsCorner.isTrailing
        VStack(spacing: 2) {
            ForEach(effectiveActions) { action in
                let btn = ActionButton(action: action, optimiser: optimiser)
                if btn.isAvailable() {
                    btn
                        .onHover { h in hoveringAction = h ? action : nil }
                        .helpTag(
                            isPresented: .init(get: { hoveringAction == action && !optimiser.showDownscaleSlider }, set: { if !$0 { hoveringAction = nil } }),
                            alignment: isTrailing ? .trailing : .leading,
                            offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                            action.label(for: optimiser.type)
                        )
                }
            }
        }
        .buttonStyle(FlatButton(color: .primary.opacity(0.02), textColor: .primary.opacity(0.7), hoverColor: .primary.opacity(0.1), width: size, height: size, circle: true))
        .padding(.vertical, 2)
        .allowsHitTesting(!optimiser.showDownscaleSlider)
        .sideButtonBackground()
        .overlay {
            if optimiser.showDownscaleSlider {
                if optimiser.type.isAudio {
                    BitrateSlider(optimiser: optimiser, size: size)
                } else {
                    DownscaleSlider(optimiser: optimiser, size: size)
                }
            }
        }
        .animation(.fastSpring, value: optimiser.aggressive)
        .onHover { if !$0 { hoveringAction = nil } }
    }
}

struct ActionPickerButton: View {
    let action: FloatingAction
    let size: CGFloat
    let onRemove: () -> Void

    @State var hovering = false

    var body: some View {
        Button(action: onRemove) {
            SwiftUI.Image(systemName: action.icon)
                .font(.heavy(9))
        }
        .buttonStyle(FlatButton(color: .clear, textColor: .black.opacity(0.7), width: size, height: size, circle: true))
        .onHover { hovering = $0 }
        .topHelpTag(isPresented: $hovering, action.label)
    }
}

struct ActionListPicker: View {
    let label: String
    let vertical: Bool
    @Binding var actions: [FloatingAction]

    var available: [FloatingAction] {
        FloatingAction.allCases.filter { !actions.contains($0) }
    }

    var buttonSize: CGFloat { vertical ? 22 : 18 }

    var addMenu: some View {
        Menu {
            ForEach(available) { action in
                Button(action: { actions.append(action) }) {
                    Label(action.label, systemImage: action.icon)
                }
            }
        } label: {
            SwiftUI.Image(systemName: "plus.circle.fill")
                .font(.regular(14))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text(label).medium(12)
                    .foregroundColor(.secondary)
                Text("To remove an icon, click on it").regular(8)
                    .foregroundColor(.secondary.opacity(0.5))
            }

            HStack(spacing: 6) {
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
                layout {
                    ForEach(actions) { action in
                        ActionPickerButton(action: action, size: buttonSize) {
                            actions.removeAll { $0 == action }
                        }
                    }
                }
                .sideButtonBackground()

                let maxButtons = vertical ? FloatingAction.maxFloatingButtons : FloatingAction.maxCompactButtons
                if actions.count < maxButtons, !available.isEmpty {
                    addMenu
                }
            }
        }
    }
}

extension View {
    func bottomHelpTag(isPresented: Binding<Bool>, _ text: String) -> some View {
        helpTag(isPresented: isPresented, alignment: .bottom, offset: CGSize(width: 0, height: 15), text)
    }

    func topHelpTag(isPresented: Binding<Bool>, _ text: String) -> some View {
        helpTag(isPresented: isPresented, alignment: .top, offset: CGSize(width: 0, height: -15), text)
    }
}

struct ActionButtons: View {
    @ObservedObject var optimiser: Optimiser
    var size: CGFloat

    @Environment(\.preview) var preview
    @Default(.compactResultActions) var compactResultActions

    @State var hoveringAction: FloatingAction?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(compactResultActions) { action in
                let btn = ActionButton(action: action, optimiser: optimiser)
                if btn.isAvailable() {
                    btn
                        .hfill()
                        .onHover { h in hoveringAction = h ? action : nil }
                        .topHelpTag(
                            isPresented: .init(get: { hoveringAction == action && !optimiser.showDownscaleSlider }, set: { if !$0 { hoveringAction = nil } }),
                            action.label(for: optimiser.type)
                        )
                }
            }
        }
        .buttonStyle(FlatButton(color: .primary.opacity(0.02), textColor: .primary.opacity(0.7), hoverColor: .primary.opacity(0.1), width: size, height: size, circle: true))
        .allowsHitTesting(!optimiser.showDownscaleSlider)
        .sideButtonBackground()
        .overlay {
            if optimiser.showDownscaleSlider {
                if optimiser.type.isAudio {
                    HorizontalBitrateSlider(optimiser: optimiser, size: size)
                } else {
                    HorizontalDownscaleSlider(optimiser: optimiser, size: size)
                }
            }
        }
        .hfill()
        .animation(.fastSpring, value: optimiser.aggressive)
        .onHover { if !$0 { hoveringAction = nil } }
    }
}
