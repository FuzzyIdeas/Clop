import Defaults
import Foundation
import Lowtech
import SwiftUI

enum FloatingAction: String, CaseIterable, Codable, Defaults.Serializable, Identifiable {
    case downscale
    case compression
    case crop
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
    static let defaultFloating: [FloatingAction] = [.downscale, .restoreOptimise, .compression, .aggressiveOptimisation, .share, .sendSecurely]
    static let defaultCompact: [FloatingAction] = [.downscale, .compression, .crop, .quickLook, .restoreOptimise, .showInFinder, .saveAs, .copyToClipboard, .share]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downscale: "Downscale"
        case .compression: "Compression"
        case .crop: "Crop and resize"
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
        case .compression: "slider.horizontal.3"
        case .crop: "crop"
        case .share: "square.and.arrow.up"
        case .restoreOptimise: "arrow.uturn.backward"
        case .aggressiveOptimisation: "bolt.horizontal"
        case .copyToClipboard: "doc.on.doc"
        case .showInFinder: "folder"
        case .quickLook: "eye"
        case .saveAs: "square.and.arrow.down"
        case .addToShelf: "tray.and.arrow.down"
        case .sendSecurely: "paperplane.fill"
        }
    }

    func label(for type: ItemType) -> String {
        switch self {
        case .downscale where type.isAudio: "Downscale cover art"
        case .downscale where type.isPDF: "Compression"
        default: label
        }
    }

}

// MARK: - Overlay card button styles

extension View {
    /// Slightly warm-tinted material used by every control on the floating card (corner buttons,
    /// grid buttons, name·format pill). Deliberately NOT Liquid Glass: glass picks up the colours
    /// of whatever thumbnail sits under it, while a tinted material stays consistent. `stroke`
    /// (not `strokeBorder`) because the shape is a generic `some Shape`, not `InsettableShape`.
    @ViewBuilder func warmControlBackground(in shape: some Shape) -> some View {
        background {
            shape.fill(.regularMaterial)
            shape.fill(Color.bg.warm.opacity(0.4))
        }
        .overlay { shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
    }
}

/// Small round button shared by the three floating-card corner controls (close, menu, crop).
/// Warm-tinted material; cheap opacity/scale hover (no geometry change).
struct FloatingCornerButtonStyle: ButtonStyle {
    var size: CGFloat = 23

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.heavy(10)).foregroundStyle(.primary)
            .frame(width: size, height: size)
            .warmControlBackground(in: Circle())
            .contentShape(Circle())
            .brightness(hovering ? 0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.9 : (hovering ? 1.08 : 1))
            .onHover { h in withAnimation(.fastTransition) { hovering = h } }
    }

    @State private var hovering = false
}

/// Larger squircle button for the floating-card action grid (r≈15, almost-but-not-quite round).
struct FloatingGridButtonStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        configuration.label
            .font(.heavy(11)).foregroundStyle(.primary)
            .frame(width: size, height: size)
            .warmControlBackground(in: shape)
            .contentShape(shape)
            .brightness(hovering ? 0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.92 : (hovering ? 1.06 : 1))
            .onHover { h in withAnimation(.fastTransition) { hovering = h } }
    }

    @State private var hovering = false
}

struct CloseStopButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                guard !preview else { return }

                // Drop the expensive glass/thumbnail render immediately so the result visually
                // vanishes on the click instead of paying for a full re-render during removal.
                optimiser.dismissing = true
                hoveredOptimiserID = nil
                // animateRemoval: false skips the slide-out animation used for swipe gestures, so a
                // button press dismisses on the next tick instead of sliding off-screen first.
                optimiser.stop(remove: !OM.compactResults || !optimiser.running, animateRemoval: false)
                optimiser.uiStop()
            },
            label: { SwiftUI.Image(systemName: optimiser.running ? "stop.fill" : "xmark") }
        )
        .buttonStyle(FloatingCornerButtonStyle())
    }
}

struct RestoreOptimiseButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        if optimiser.isOriginal {
            Button(
                action: { if !preview { optimiser.optimise(allowLarger: false); optimiser.collapseHoverOverlay = true } },
                label: { SwiftUI.Image(systemName: "goforward.plus").font(.heavy(9)) }
            )
            .contentShape(Rectangle())
        } else {
            Button(
                action: { if !preview { optimiser.restoreOriginal(); optimiser.overlayMessage = "Restored original"; optimiser.collapseHoverOverlay = true } },
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
                guard !preview, !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
                optimiser.showDownscaleSlider = true
            }
            .onRightClick {
                guard !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
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

// MARK: - Compression button + slider (per-result quality)

/// Maps the compression slider's normalized position (0 = top = least compression / best quality,
/// 1 = bottom = most compression / smallest file) to a `CompressionQuality` per item type, and back.
/// Video flows through Lossless → Fast (hardware) → Smaller (software CRF). Image is Adaptive → factor.
enum CompressionScale {
    static let videoLossless = 0.0
    static let videoFast = 0.15
    static let videoSmallerStart = 0.3
    static let imageAdaptive = 0.0
    static let imageFactorStart = 0.15

    /// Snap a raw 5...100 factor to the nearest multiple of 5 so the slider exposes round
    /// increments (5, 10, 15, …) instead of arbitrary values like 81 or 54.
    static func snapFactor(_ f: Double) -> Int {
        Int((max(5, min(100, f)) / 5).rounded()) * 5
    }

    static func quality(forPosition position: Double, type: ItemType) -> CompressionQuality {
        let p = max(0, min(1, position))
        if type.isVideo {
            if p < (videoLossless + videoFast) / 2 { return CompressionQuality(tier: .lossless, factor: 5) }
            if p < (videoFast + videoSmallerStart) / 2 { return CompressionQuality(tier: .fast, factor: 50) }
            let f = 5 + (p - videoSmallerStart) / (1 - videoSmallerStart) * 95
            return CompressionQuality(tier: .smaller, factor: snapFactor(f))
        }
        // Audio has no Adaptive tier: a plain 5…100% quality maps to a bitrate via audioBitrate(for:).
        if type.isAudio {
            return CompressionQuality(tier: .custom, factor: snapFactor(5 + p * 95))
        }
        if p < imageFactorStart / 2 { return CompressionQuality(tier: .adaptive, factor: 5) }
        let f = 5 + (p - imageFactorStart) / (1 - imageFactorStart) * 95
        return CompressionQuality(tier: .custom, factor: snapFactor(f))
    }

    static func position(for cq: CompressionQuality, type: ItemType) -> Double {
        if type.isVideo {
            switch cq.tier {
            case .lossless: return videoLossless
            case .fast: return videoFast
            default: return videoSmallerStart + Double(cq.factor - 5) / 95 * (1 - videoSmallerStart)
            }
        }
        if type.isAudio { return Double(cq.factor - 5) / 95 }
        if cq.tier == .adaptive { return imageAdaptive }
        return imageFactorStart + Double(cq.factor - 5) / 95 * (1 - imageFactorStart)
    }

    static func label(for cq: CompressionQuality, type: ItemType) -> String {
        if type.isVideo {
            switch cq.tier {
            case .lossless: return "Lossless"
            case .fast: return "Fast"
            default: return cq.videoUsesAutoCRF ? "Auto" : "\(cq.factor)%"
            }
        }
        if type.isAudio { return "\(cq.factor)%" }
        return cq.tier == .adaptive ? "Adaptive" : "\(cq.factor)%"
    }

    /// Spelled-out label shown in the centre of the result while dragging (the knob keeps the terse one).
    static func stepLabel(for cq: CompressionQuality, type: ItemType) -> String {
        if type.isVideo {
            switch cq.tier {
            case .lossless: return "Lossless"
            case .fast: return "Fast"
            default: return cq.videoUsesAutoCRF ? "Auto" : "\(cq.factor)% compression"
            }
        }
        if type.isAudio { return "\(cq.factor)% compression" }
        return cq.tier == .adaptive ? "Adaptive" : "\(cq.factor)% compression"
    }

    static func anchors(for type: ItemType) -> [Double] {
        if type.isVideo { return [videoLossless, videoFast, videoSmallerStart] }
        if type.isAudio { return [0.0, 0.25, 0.5, 0.75, 1.0] }
        return [imageAdaptive, imageFactorStart]
    }
}

@MainActor func currentCompressionQuality(for optimiser: Optimiser) -> CompressionQuality {
    if let override = optimiser.compressionOverride { return override }
    if optimiser.type.isVideo { return Defaults[.videoCompression] }
    if optimiser.type.isAudio { return Defaults[.audioCompression] }
    return Defaults[.imageCompression]
}

struct CompressionButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(action: {}, label: { SwiftUI.Image(systemName: "slider.horizontal.3").font(.heavy(9)) })
            .contentShape(Rectangle())
            .onMouseDown {
                guard !preview, !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
                optimiser.showCompressionSlider = true
            }
            .onRightClick {
                guard !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
                optimiser.showCompressionSlider = true
            }
    }
}

struct CompressionSlider: View {
    @ObservedObject var optimiser: Optimiser

    @Default(.floatingResultsCorner) var floatingResultsCorner
    var size: CGFloat

    var displayPosition: Double {
        dragPosition ?? CompressionScale.position(for: currentCompressionQuality(for: optimiser), type: optimiser.type)
    }

    var displayLabel: String {
        let cq = dragPosition.map { CompressionScale.quality(forPosition: $0, type: optimiser.type) } ?? currentCompressionQuality(for: optimiser)
        return CompressionScale.label(for: cq, type: optimiser.type)
    }

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

                ForEach(CompressionScale.anchors(for: optimiser.type), id: \.self) { anchor in
                    let y = yPosition(for: anchor, trackTop: trackTop, trackHeight: trackHeight)
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(0.3))
                        .frame(width: size * 0.55, height: 1.5)
                        .position(x: centerX, y: y)
                }

                let knobY = yPosition(for: displayPosition, trackTop: trackTop, trackHeight: trackHeight)
                let isTrailing = floatingResultsCorner.isTrailing
                let tooltipOffset = knobSize / 2 + 38
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay {
                        Text(displayLabel)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
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
                onDrag: { value in
                    let p = (1.0 - value) / 0.9
                    dragPosition = p
                    optimiser.stepIndicator = CompressionScale.stepLabel(for: CompressionScale.quality(forPosition: p, type: optimiser.type), type: optimiser.type)
                },
                onRelease: { value in
                    let p = (1.0 - value) / 0.9
                    let startCQ = currentCompressionQuality(for: optimiser)
                    dragPosition = nil
                    optimiser.stepIndicator = ""
                    optimiser.showCompressionSlider = false
                    let cq = CompressionScale.quality(forPosition: p, type: optimiser.type)
                    if cq != startCQ { optimiser.reoptimise(compression: cq) }
                },
                onCancel: {
                    dragPosition = nil
                    optimiser.stepIndicator = ""
                    optimiser.showCompressionSlider = false
                }
            )
        )
    }

    func yPosition(for position: Double, trackTop: CGFloat, trackHeight: CGFloat) -> CGFloat {
        trackTop + position * trackHeight
    }

    @State private var dragPosition: Double?

}

struct HorizontalCompressionSlider: View {
    @ObservedObject var optimiser: Optimiser

    var size: CGFloat

    var displayPosition: Double {
        dragPosition ?? CompressionScale.position(for: currentCompressionQuality(for: optimiser), type: optimiser.type)
    }

    var displayLabel: String {
        let cq = dragPosition.map { CompressionScale.quality(forPosition: $0, type: optimiser.type) } ?? currentCompressionQuality(for: optimiser)
        return CompressionScale.label(for: cq, type: optimiser.type)
    }

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

                ForEach(CompressionScale.anchors(for: optimiser.type), id: \.self) { anchor in
                    let x = xPosition(for: anchor, trackLeft: trackLeft, trackWidth: trackWidth)
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(0.3))
                        .frame(width: 1.5, height: size * 0.55)
                        .position(x: x, y: centerY)
                }

                let knobX = xPosition(for: displayPosition, trackLeft: trackLeft, trackWidth: trackWidth)
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .overlay {
                        Text(displayLabel)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(.primary)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .offset(y: -knobSize / 2 - 16)
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
                onDrag: { value in
                    let p = (1.0 - value) / 0.9
                    dragPosition = p
                    optimiser.stepIndicator = CompressionScale.stepLabel(for: CompressionScale.quality(forPosition: p, type: optimiser.type), type: optimiser.type)
                },
                onRelease: { value in
                    let p = (1.0 - value) / 0.9
                    let startCQ = currentCompressionQuality(for: optimiser)
                    dragPosition = nil
                    optimiser.stepIndicator = ""
                    optimiser.showCompressionSlider = false
                    let cq = CompressionScale.quality(forPosition: p, type: optimiser.type)
                    if cq != startCQ { optimiser.reoptimise(compression: cq) }
                },
                onCancel: {
                    dragPosition = nil
                    optimiser.stepIndicator = ""
                    optimiser.showCompressionSlider = false
                }
            )
        )
    }

    func xPosition(for position: Double, trackLeft: CGFloat, trackWidth: CGFloat) -> CGFloat {
        trackLeft + position * trackWidth
    }

    @State private var dragPosition: Double?

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

// MARK: - Thin card sliders (overlay-grid floating result)

/// Hairline horizontal slider for the in-thumbnail card: a value hint on top (the same descriptive
/// label the old external slider showed) and a thin track + small knob below — no thick capsule,
/// no on-knob tooltip. Reuses SliderEventOverlay so a press-and-drag from the grid button is one
/// continuous gesture. Position/anchors are normalised 0(left)…1(right); the overlay reports the
/// shared downscale-style factor (0.1…1.0) which each wrapper maps to its own domain.
struct CardSlider: View {
    let hint: String
    let position: Double
    let anchors: [Double]
    let onDrag: (Double) -> Void
    let onRelease: (Double) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            // White text on a dark blurred pill. Everything is clipped to the capsule so the blur
            // doesn't show as a rectangle behind a smaller rounded background.
            Text(hint)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    ZStack {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow, state: .active, appearance: .vibrantDark)
                        Color.black.opacity(0.4)
                    }
                    .clipShape(Capsule())
                )
                .fixedSize()
            GeometryReader { geo in
                let knob: CGFloat = 11
                let left = knob / 2
                let w = max(geo.size.width - knob, 1)
                let cy = geo.size.height / 2
                let p = min(max(position, 0), 1)
                ZStack {
                    Capsule().fill(.primary.opacity(0.25)).frame(height: 2.5).position(x: geo.size.width / 2, y: cy)
                    ForEach(anchors, id: \.self) { a in
                        Capsule().fill(.primary.opacity(0.4)).frame(width: 1.5, height: 6).position(x: left + min(max(a, 0), 1) * w, y: cy)
                    }
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .position(x: left + p * w, y: cy)
                }
            }
            .frame(height: 12)
        }
        .overlay(SliderEventOverlay(buttonSize: 11, isHorizontal: true, onDrag: onDrag, onRelease: onRelease, onCancel: onCancel))
        // Escape bails out without committing. The floating panel is non-activating, so it has to
        // be made key first for the keyboard shortcut (and the overlay's keyDown monitor) to fire.
        .background {
            Button("") { onCancel() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onAppear {
            guard !SWIFTUI_PREVIEW else { return }
            floatingResultsWindow.allowToBecomeKey = true
            floatingResultsWindow.makeKeyAndOrderFront(nil)
            floatingResultsWindow.orderFrontRegardless()
        }
    }
}

struct CardDownscaleSlider: View {
    @ObservedObject var optimiser: Optimiser

    var factor: Double { dragFactor ?? optimiser.downscaleFactor }

    var body: some View {
        CardSlider(
            hint: "\((factor * 100).intround)% scale",
            position: (1.0 - factor) / 0.9,
            anchors: [1.0, 0.75, 0.5, 0.25, 0.1].map { (1.0 - $0) / 0.9 },
            onDrag: { f in dragFactor = f },
            onRelease: { f in
                let start = optimiser.downscaleFactor
                dragFactor = nil
                optimiser.showDownscaleSlider = false
                if abs(f - start) > 0.01 {
                    optimiser.downscale(toFactor: f)
                    optimiser.collapseHoverOverlay = true
                }
            },
            onCancel: { dragFactor = nil; optimiser.showDownscaleSlider = false }
        )
    }

    @State private var dragFactor: Double?
}

/// Audio cover-art resize slider for the card. Reuses the downscale geometry but drives the
/// cover-only resize and labels itself clearly with the target resolution.
struct CardCoverArtSlider: View {
    @ObservedObject var optimiser: Optimiser

    var factor: Double { dragFactor ?? optimiser.coverDownscaleFactor }
    var hint: String {
        guard let base = optimiser.coverArtSize, base.width > 0, base.height > 0 else { return "Cover art" }
        let w = Int((base.width * factor).rounded())
        let h = Int((base.height * factor).rounded())
        return "Cover art \(w)×\(h)"
    }

    var body: some View {
        CardSlider(
            hint: hint,
            position: (1.0 - factor) / 0.9,
            anchors: [1.0, 0.75, 0.5, 0.25, 0.1].map { (1.0 - $0) / 0.9 },
            onDrag: { f in dragFactor = f },
            onRelease: { f in
                let start = optimiser.coverDownscaleFactor
                dragFactor = nil
                optimiser.showDownscaleSlider = false
                if abs(f - start) > 0.01 {
                    downscaleAudioCoverArt(optimiser: optimiser, toFactor: f)
                    optimiser.collapseHoverOverlay = true
                }
            },
            onCancel: { dragFactor = nil; optimiser.showDownscaleSlider = false }
        )
        .onAppear { loadAudioCoverArtSize(optimiser: optimiser) }
    }

    @State private var dragFactor: Double?

}

struct CardCompressionSlider: View {
    @ObservedObject var optimiser: Optimiser

    var pos: Double { dragPosition ?? CompressionScale.position(for: currentCompressionQuality(for: optimiser), type: optimiser.type) }
    var hint: String {
        let cq = dragPosition.map { CompressionScale.quality(forPosition: $0, type: optimiser.type) } ?? currentCompressionQuality(for: optimiser)
        return CompressionScale.stepLabel(for: cq, type: optimiser.type)
    }

    var body: some View {
        CardSlider(
            hint: hint,
            position: pos,
            anchors: CompressionScale.anchors(for: optimiser.type),
            onDrag: { v in dragPosition = (1.0 - v) / 0.9 },
            onRelease: { v in
                let p = (1.0 - v) / 0.9
                let start = currentCompressionQuality(for: optimiser)
                dragPosition = nil
                optimiser.showCompressionSlider = false
                let cq = CompressionScale.quality(forPosition: p, type: optimiser.type)
                if cq != start {
                    optimiser.reoptimise(compression: cq)
                    optimiser.collapseHoverOverlay = true
                }
            },
            onCancel: { dragPosition = nil; optimiser.showCompressionSlider = false }
        )
    }

    @State private var dragPosition: Double?
}

struct CardBitrateSlider: View {
    @ObservedObject var optimiser: Optimiser

    @Default(.audioFormat) var audioFormat
    @Default(.audioBitrate) var defaultBitrate

    var bitrates: [Int] { audioFormat.allowedBitrates }
    var current: Int { dragBitrate ?? optimiser.audioBitrateOverride ?? defaultBitrate }

    var body: some View {
        CardSlider(
            hint: "\(current) kbps",
            position: bitrates.firstIndex(of: current).map { position(forIndex: $0) } ?? 0,
            anchors: bitrates.indices.map { position(forIndex: $0) },
            onDrag: { f in dragBitrate = bitrates[index(forFactor: f)] },
            onRelease: { f in
                let nb = bitrates[index(forFactor: f)]
                let start = optimiser.audioBitrateOverride ?? defaultBitrate
                dragBitrate = nil
                optimiser.showDownscaleSlider = false
                if nb != start {
                    optimiser.lowerBitrate(to: nb)
                    optimiser.collapseHoverOverlay = true
                }
            },
            onCancel: { dragBitrate = nil; optimiser.showDownscaleSlider = false }
        )
    }

    func position(forIndex idx: Int) -> Double {
        bitrates.count > 1 ? Double(bitrates.count - 1 - idx) / Double(bitrates.count - 1) : 0
    }
    func index(forFactor factor: Double) -> Int {
        let c = bitrates.count
        guard c > 1 else { return 0 }
        let n = (factor - 0.1) / 0.9
        return max(0, min(c - 1, Int(round(n * Double(c - 1)))))
    }

    @State private var dragBitrate: Int?
}

struct CardPDFDPISlider: View {
    @ObservedObject var optimiser: Optimiser

    var stops: [Int] { PDF_DPI_STOPS }
    var current: Int { dragDPI ?? optimiser.pdfDPIOverride ?? optimiser.effectiveBasePDFDPI }

    var body: some View {
        CardSlider(
            hint: "\(current) DPI",
            position: nearestIndex(for: current).map { position(forIndex: $0) } ?? 0,
            anchors: stops.indices.map { position(forIndex: $0) },
            onDrag: { f in dragDPI = stops[index(forFactor: f)] },
            onRelease: { f in
                let newDPI = stops[index(forFactor: f)]
                let start = optimiser.pdfDPIOverride ?? optimiser.effectiveBasePDFDPI
                dragDPI = nil
                optimiser.showDownscaleSlider = false
                if newDPI != start {
                    optimiser.lowerPDFDPI(to: newDPI)
                    optimiser.collapseHoverOverlay = true
                }
            },
            onCancel: { dragDPI = nil; optimiser.showDownscaleSlider = false }
        )
    }

    func position(forIndex idx: Int) -> Double {
        stops.count > 1 ? Double(idx) / Double(stops.count - 1) : 0
    }
    func index(forFactor factor: Double) -> Int {
        let c = stops.count
        guard c > 1 else { return 0 }
        let n = (1.0 - factor) / 0.9
        return max(0, min(c - 1, Int(round(n * Double(c - 1)))))
    }
    func nearestIndex(for dpi: Int) -> Int? {
        guard !stops.isEmpty else { return nil }
        return stops.indices.min(by: { abs(stops[$0] - dpi) < abs(stops[$1] - dpi) })
    }

    @State private var dragDPI: Int?
}

// MARK: - PDFDPISlider (vertical)

struct PDFDPISlider: View {
    @ObservedObject var optimiser: Optimiser

    var size: CGFloat

    @Default(.pdfDPI) var defaultDPI
    @Default(.floatingResultsCorner) var floatingResultsCorner

    var stops: [Int] { PDF_DPI_STOPS }
    var currentDPI: Int { dragDPI ?? optimiser.pdfDPIOverride ?? optimiser.effectiveBasePDFDPI }

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

                ForEach(Array(stops.enumerated()), id: \.offset) { index, dpi in
                    let y = yPosition(for: index, trackTop: trackTop, trackHeight: trackHeight)
                    let isActive = dpi == currentDPI

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(isActive ? 0.7 : 0.3))
                        .frame(width: size * 0.55, height: isActive ? 2 : 1.5)
                        .position(x: centerX, y: y)
                }

                if let index = nearestStopIndex(for: currentDPI) {
                    let knobY = yPosition(for: index, trackTop: trackTop, trackHeight: trackHeight)
                    let isTrailing = floatingResultsCorner.isTrailing
                    let tooltipOffset = knobSize / 2 + 36
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .overlay {
                            Text("\(currentDPI) DPI")
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
                    let dpi = stops[dpiIndex(for: factor)]
                    dragDPI = dpi
                    optimiser.stepIndicator = "\(dpi) DPI"
                },
                onRelease: { factor in
                    let newDPI = stops[dpiIndex(for: factor)]
                    let startDPI = optimiser.pdfDPIOverride ?? optimiser.effectiveBasePDFDPI
                    dragDPI = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                    if newDPI != startDPI {
                        optimiser.lowerPDFDPI(to: newDPI)
                    }
                },
                onCancel: {
                    dragDPI = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                }
            )
        )
    }

    func yPosition(for index: Int, trackTop: CGFloat, trackHeight: CGFloat) -> CGFloat {
        let count = stops.count
        guard count > 1 else { return trackTop }
        // stops[0] is the highest DPI (300), at the top of the vertical track.
        return trackTop + CGFloat(index) / CGFloat(count - 1) * trackHeight
    }

    func dpiIndex(for factor: Double) -> Int {
        let count = stops.count
        guard count > 1 else { return 0 }
        // factor 1.0 (top of slider) = highest DPI = index 0; factor 0.1 = lowest = last index.
        let normalized = (1.0 - factor) / 0.9
        return max(0, min(count - 1, Int(round(normalized * Double(count - 1)))))
    }

    func nearestStopIndex(for dpi: Int) -> Int? {
        guard !stops.isEmpty else { return nil }
        return stops.indices.min(by: { abs(stops[$0] - dpi) < abs(stops[$1] - dpi) })
    }

    @State private var dragDPI: Int?
}

// MARK: - HorizontalPDFDPISlider

struct HorizontalPDFDPISlider: View {
    @ObservedObject var optimiser: Optimiser

    var size: CGFloat

    @Default(.pdfDPI) var defaultDPI

    var stops: [Int] { PDF_DPI_STOPS }
    var currentDPI: Int { dragDPI ?? optimiser.pdfDPIOverride ?? optimiser.effectiveBasePDFDPI }

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

                ForEach(Array(stops.enumerated()), id: \.offset) { index, dpi in
                    let x = xPosition(for: index, trackLeft: trackLeft, trackWidth: trackWidth)
                    let isActive = dpi == currentDPI

                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(.primary.opacity(isActive ? 0.7 : 0.3))
                        .frame(width: isActive ? 2 : 1.5, height: size * 0.55)
                        .position(x: x, y: centerY)
                }

                if let index = nearestStopIndex(for: currentDPI) {
                    let knobX = xPosition(for: index, trackLeft: trackLeft, trackWidth: trackWidth)
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .overlay(alignment: .top) {
                            Text("\(currentDPI) DPI")
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
                    let dpi = stops[dpiIndex(for: factor)]
                    dragDPI = dpi
                    optimiser.stepIndicator = "\(dpi) DPI"
                },
                onRelease: { factor in
                    let newDPI = stops[dpiIndex(for: factor)]
                    let startDPI = optimiser.pdfDPIOverride ?? optimiser.effectiveBasePDFDPI
                    dragDPI = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                    if newDPI != startDPI {
                        optimiser.lowerPDFDPI(to: newDPI)
                    }
                },
                onCancel: {
                    dragDPI = nil
                    optimiser.stepIndicator = ""
                    optimiser.showDownscaleSlider = false
                }
            )
        )
    }

    func xPosition(for index: Int, trackLeft: CGFloat, trackWidth: CGFloat) -> CGFloat {
        let count = stops.count
        guard count > 1 else { return trackLeft }
        // Highest DPI on the LEFT (factor 1.0), lowest DPI on the RIGHT, matching "minus button" UX.
        return trackLeft + CGFloat(index) / CGFloat(count - 1) * trackWidth
    }

    func dpiIndex(for factor: Double) -> Int {
        let count = stops.count
        guard count > 1 else { return 0 }
        // factor 1.0 (left) → index 0 (highest DPI); factor 0.1 (right) → last index (lowest DPI).
        let normalized = (1.0 - factor) / 0.9
        return max(0, min(count - 1, Int(round(normalized * Double(count - 1)))))
    }

    func nearestStopIndex(for dpi: Int) -> Int? {
        guard !stops.isEmpty else { return nil }
        return stops.indices.min(by: { abs(stops[$0] - dpi) < abs(stops[$1] - dpi) })
    }

    @State private var dragDPI: Int?
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
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self, window != nil else { return event }

                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event } // Esc bails out of the drag without committing
                    directTracking = false
                    didDrag = false
                    onCancel?()
                    return nil
                }

                // A fresh press outside the slider dismisses it without applying. The press-drag that
                // opened the slider fired its mouse-down before this monitor mounted, so it's not caught here.
                if event.type == .leftMouseDown {
                    let loc = convert(event.locationInWindow, from: nil)
                    if !bounds.contains(loc) {
                        directTracking = false
                        didDrag = false
                        onCancel?()
                        return nil
                    }
                    return event
                }

                guard !directTracking else { return event }

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

/// Audio's downscale button, repurposed to resize the embedded cover art. Opens the cover-art
/// slider band (the bitrate axis lives on the compression button now).
struct CoverArtDownscaleButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(action: {}, label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) })
            .contentShape(Rectangle())
            .onMouseDown {
                guard !preview, !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
                optimiser.showDownscaleSlider = true
            }
            .onRightClick {
                guard !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
                optimiser.showDownscaleSlider = true
            }
    }
}

struct LowerPDFDPIButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(action: {}, label: { SwiftUI.Image(systemName: "slider.horizontal.3").font(.heavy(9)) })
            .contentShape(Rectangle())
            .onMouseDown {
                guard !preview, !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
                optimiser.showDownscaleSlider = true
            }
            .onRightClick {
                guard !optimiser.showDownscaleSlider, !optimiser.showCompressionSlider else { return }
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

                optimiser.compressionOverride = nil
                let newAggressive = !optimiser.aggressive
                if optimiser.downscaleFactor < 1 {
                    optimiser.downscale(toFactor: optimiser.downscaleFactor, aggressiveOptimisation: newAggressive)
                } else {
                    optimiser.optimise(allowLarger: false, aggressiveOptimisation: newAggressive, fromOriginal: true)
                }
                optimiser.collapseHoverOverlay = true
            },
            label: {
                SwiftUI.Image(systemName: optimiser.aggressive ? "bolt.fill" : "bolt")
                    .font(.heavy(9))
                    .foregroundColor(optimiser.aggressive ? FloatingResult.yellow : nil)
                    // The pale "glow" yellow washes out on light thumbnails/backgrounds; a dark drop
                    // shadow keeps it legible on any background without losing the yellow identity.
                    .shadow(color: optimiser.aggressive ? .black.opacity(0.6) : .clear, radius: 1, y: 0.5)
            }
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
    @ObservedObject var wdm = WDM
    @Environment(\.preview) var preview

    @State private var glowing = false

    /// The current session from the manager (the passed-in copy goes stale after rescheduling).
    var liveSession: WarpDropSession { wdm.sessions.first { $0.id == session.id } ?? session }

    var body: some View {
        Menu {
            if let label = liveSession.expiresInLabel {
                Text(label)
            }
            Menu("Change expiration") {
                ForEach(LINK_EXPIRATION_PRESETS, id: \.self) { preset in
                    Button(expirationDurationLabel(preset)) {
                        if !preview { WDM.rescheduleExpiry(liveSession, to: preset) }
                    }
                }
                Divider()
                Button("Never expire") {
                    if !preview { WDM.rescheduleExpiry(liveSession, to: LINK_EXPIRATION_NEVER) }
                }
            }
            Divider()
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

/// Binding that maps the optimiser's `sendExpiration` seconds onto the preset index used by the
/// expiration sliders (so dragging snaps to 1m … 3d).
@MainActor
func sendExpirationIndexBinding(_ optimiser: Optimiser) -> Binding<Double> {
    Binding(
        get: { Double(nearestExpirationPresetIndex(optimiser.sendExpiration)) },
        set: { optimiser.sendExpiration = LINK_EXPIRATION_PRESETS[max(0, min(LINK_EXPIRATION_PRESETS.count - 1, Int($0.rounded())))] }
    )
}

/// The idle "Send securely" button. In the floating card it opens the in-card expiration overlay;
/// in compact mode it opens a popover. Confirming creates the link with the chosen expiration.
struct SendSecurelyStartButton: View {
    @ObservedObject var optimiser: Optimiser
    var inFloatingCard = false
    @Environment(\.preview) var preview
    @State private var showPopover = false

    var body: some View {
        Button(action: {
            guard !preview else { return }
            optimiser.sendExpiration = Defaults[.defaultLinkExpiration]
            if inFloatingCard {
                optimiser.showSendExpiration = true
            } else {
                showPopover = true
            }
        }) {
            SwiftUI.Image(systemName: "paperplane.fill").font(.heavy(9))
        }
        .contentShape(Rectangle())
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            SendExpirationPopover(optimiser: optimiser) { showPopover = false }
        }
    }
}

/// Compact-result popover: pick an expiration then create + copy the link.
struct SendExpirationPopover: View {
    @ObservedObject var optimiser: Optimiser
    var onSend: () -> Void
    @Environment(\.preview) var preview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link expires in \(expirationDurationLabel(optimiser.sendExpiration))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Slider(value: sendExpirationIndexBinding(optimiser), in: 0 ... Double(LINK_EXPIRATION_PRESETS.count - 1), step: 1)
            Button(action: {
                guard !preview else { return }
                warpDropSend(optimiser: optimiser, expiration: optimiser.sendExpiration)
                onSend()
            }) {
                Label("Copy link · expires in \(expirationShortLabel(optimiser.sendExpiration))", systemImage: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(width: 240)
    }
}

/// Floating-card expiration overlay band: label + snap slider. The confirm button lives at the
/// bottom of the card (SendExpirationConfirmButton).
struct CardSendExpirationSlider: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        VStack(spacing: 3) {
            Text("Link expires in \(expirationDurationLabel(optimiser.sendExpiration))")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Slider(value: sendExpirationIndexBinding(optimiser), in: 0 ... Double(LINK_EXPIRATION_PRESETS.count - 1), step: 1)
                .controlSize(.mini)
                .tint(.white)
        }
    }
}

/// Bottom-of-card confirm button for the floating expiration overlay.
struct SendExpirationConfirmButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        Button(action: {
            guard !preview else { return }
            optimiser.showSendExpiration = false
            warpDropSend(optimiser: optimiser, expiration: optimiser.sendExpiration)
        }) {
            Label("Copy link · expires in \(expirationShortLabel(optimiser.sendExpiration))", systemImage: "paperplane.fill")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(.white))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ActionButton: View {
    let action: FloatingAction
    @ObservedObject var optimiser: Optimiser
    /// In the floating card the send button opens the in-card expiration overlay; elsewhere (compact)
    /// it opens a popover instead.
    var inFloatingCard = false
    @Environment(\.preview) var preview

    var body: some View {
        switch action {
        case .downscale:
            if optimiser.type.isAudio {
                CoverArtDownscaleButton(optimiser: optimiser)
            } else if optimiser.type.isPDF {
                LowerPDFDPIButton(optimiser: optimiser)
            } else if !optimiser.type.isAudio {
                DownscaleButton(optimiser: optimiser)
            }
        case .compression:
            CompressionButton(optimiser: optimiser)
        case .crop:
            Button(action: { if !preview { optimiser.showCropWindow() } }) {
                SwiftUI.Image(systemName: "crop").font(.heavy(9))
            }
            .contentShape(Rectangle())
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
                SendSecurelyStartButton(optimiser: optimiser, inFloatingCard: inFloatingCard)
            }
        }
    }

    func isAvailable() -> Bool {
        switch action {
        case .downscale: optimiser.canDownscale()
        case .compression: optimiser.canCompress()
        case .crop: optimiser.canCrop()
        case .aggressiveOptimisation: optimiser.canReoptimise()
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
                            isPresented: .init(get: { hoveringAction == action && !optimiser.showDownscaleSlider && !optimiser.showCompressionSlider }, set: { if !$0 { hoveringAction = nil } }),
                            alignment: isTrailing ? .trailing : .leading,
                            offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                            action.label(for: optimiser.type)
                        )
                }
            }
        }
        .buttonStyle(FlatButton(
            color: (preview ? Color.black : Color.primary).opacity(0.02),
            textColor: (preview ? Color.black : Color.primary).opacity(0.7),
            hoverColor: (preview ? Color.black : Color.primary).opacity(0.1),
            width: size,
            height: size,
            circle: true
        ))
        .padding(.vertical, 2)
        .allowsHitTesting(!optimiser.showDownscaleSlider && !optimiser.showCompressionSlider)
        .sideButtonBackground(preview: preview)
        .overlay {
            if optimiser.showDownscaleSlider {
                if optimiser.type.isAudio {
                    BitrateSlider(optimiser: optimiser, size: size)
                } else if optimiser.type.isPDF {
                    PDFDPISlider(optimiser: optimiser, size: size)
                } else {
                    DownscaleSlider(optimiser: optimiser, size: size)
                }
            } else if optimiser.showCompressionSlider {
                CompressionSlider(optimiser: optimiser, size: size)
            }
        }
        .animation(.fastSpring, value: optimiser.aggressive)
        .onHover { if !$0 { hoveringAction = nil } }
    }
}

/// A floating-result grid action button that shows our custom HelpTag with the action name on hover.
struct FloatingGridActionButton: View {
    let action: FloatingAction
    @ObservedObject var optimiser: Optimiser
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        let button = ActionButton(action: action, optimiser: optimiser, inFloatingCard: true)
        button
            .buttonStyle(FloatingGridButtonStyle())
            .disabled(!button.isAvailable())
            .opacity(button.isAvailable() ? 1 : 0.4)
            .onHover { hovering = $0 }
            .topHelpTag(isPresented: $hovering, action.label)
            .contextMenu {
                Button("Remove from buttons", action: onRemove)
            }
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

/// Settings editor for the full floating result's action grid: the same 2×3 squircle layout and
/// metrics as the hover overlay, with a solid `Color.bg.warm` chip per button (the settings window is
/// opaque, so the overlay's translucent material is swapped for the equivalent solid). Tap a slot to
/// change it — filled slots offer Remove, empty slots a dashed `+` that assigns an action. Crop stays
/// out of the grid (it's a fixed corner button in the overlay), matching the overlay's handling.
struct FloatingActionGridPicker: View {
    @Binding var actions: [FloatingAction]

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text("Action buttons").medium(12).foregroundColor(.secondary)
                Text("Tap a button to change it").regular(8).foregroundColor(.secondary.opacity(0.5))
            }
            let cols = Array(repeating: GridItem(.fixed(side), spacing: 8), count: 3)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    if let action = slot {
                        GridPickerButton(action: action, side: side) {
                            actions.removeAll { $0 == action }
                        }
                    } else {
                        addPlaceholder
                    }
                }
            }
            .fixedSize()

            if actions != FloatingAction.defaultFloating {
                Button("Reset to default") { actions = FloatingAction.defaultFloating }
                    .buttonStyle(.plain)
                    .font(.medium(10))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // Same metrics as the overlay grid (FloatingGridButtonStyle: 34pt cells, 8pt gaps).
    private let side: CGFloat = 34

    private var configured: [FloatingAction] { actions.filter { $0 != .crop } }
    private var slots: [FloatingAction?] {
        var s: [FloatingAction?] = Array(configured.prefix(6)).map { Optional($0) }
        while s.count < 6 {
            s.append(nil)
        }
        return s
    }
    private var addable: [FloatingAction] {
        FloatingAction.allCases.filter { $0 != .crop && !configured.contains($0) }
    }

    private var addPlaceholder: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Menu {
            Section("Assign to a button") {
                ForEach(addable) { a in
                    Button(action: { actions.append(a) }) {
                        Label(a.label, systemImage: a.icon)
                    }
                }
            }
        } label: {
            SwiftUI.Image(systemName: "plus").font(.heavy(10)).foregroundStyle(.primary.opacity(0.45))
                .frame(width: side, height: side)
                .background(Color.primary.opacity(0.05), in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                .contentShape(shape)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(addable.isEmpty)
    }
}

/// One filled slot in the settings action grid: same squircle/metrics as the hover overlay, with our
/// custom HelpTag showing the action name on hover. It's a plain Button (a borderless Menu label
/// wouldn't render the chip background). The opaque settings window can't blur, so the chip uses a
/// solid `Color.bg.warm` fill plus a contrasting outline for separation. Tap removes the action.
private struct GridPickerButton: View {
    let action: FloatingAction
    let side: CGFloat
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        // A plain Button renders the label's background; a borderless Menu label did not, which is
        // why earlier fill changes were invisible. Tap removes the action (re-add via the + slot).
        return Button(action: onRemove) {
            SwiftUI.Image(systemName: action.icon)
                .font(.heavy(11))
                .foregroundStyle(Color.fg.primary)
                .frame(width: side, height: side)
                .background(Color.bg.warm, in: shape)
                // A contrasting outline so the warm chip (warmBlack in dark mode) still separates from
                // the same-shade settings panel behind it.
                .overlay { shape.stroke(Color.fg.primary.opacity(0.5), lineWidth: 1) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .topHelpTag(isPresented: $hovering, action.label)
    }

    @State private var hovering = false

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
                .sideButtonBackground(preview: true)

                let maxButtons = vertical ? FloatingAction.maxFloatingButtons : FloatingAction.maxCompactButtons
                if actions.count < maxButtons, !available.isEmpty {
                    addMenu
                }
            }
        }
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
                            isPresented: .init(get: { hoveringAction == action && !optimiser.showDownscaleSlider && !optimiser.showCompressionSlider }, set: { if !$0 { hoveringAction = nil } }),
                            action.label(for: optimiser.type)
                        )
                }
            }
        }
        .buttonStyle(FlatButton(
            color: (preview ? Color.black : Color.primary).opacity(0.02),
            textColor: (preview ? Color.black : Color.primary).opacity(0.7),
            hoverColor: (preview ? Color.black : Color.primary).opacity(0.1),
            width: size,
            height: size,
            circle: true
        ))
        .allowsHitTesting(!optimiser.showDownscaleSlider && !optimiser.showCompressionSlider)
        .sideButtonBackground(preview: preview)
        .overlay {
            if optimiser.showDownscaleSlider {
                if optimiser.type.isAudio {
                    HorizontalBitrateSlider(optimiser: optimiser, size: size)
                } else if optimiser.type.isPDF {
                    HorizontalPDFDPISlider(optimiser: optimiser, size: size)
                } else {
                    HorizontalDownscaleSlider(optimiser: optimiser, size: size)
                }
            } else if optimiser.showCompressionSlider {
                HorizontalCompressionSlider(optimiser: optimiser, size: size)
            }
        }
        .hfill()
        .animation(.fastSpring, value: optimiser.aggressive)
        .onHover { if !$0 { hoveringAction = nil } }
    }
}
