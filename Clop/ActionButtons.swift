import Defaults
import Foundation
import Lowtech
import SwiftUI

enum FloatingAction: String, CaseIterable, Codable, Defaults.Serializable, Identifiable {
    case downscale
    case compression
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
    static let defaultFloating: [FloatingAction] = [.downscale, .compression, .share, .restoreOptimise]
    static let defaultCompact: [FloatingAction] = [.downscale, .compression, .quickLook, .restoreOptimise, .showInFinder, .saveAs, .copyToClipboard, .share]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downscale: "Downscale"
        case .compression: "Compression"
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
        case .downscale where type.isAudio: "Lower bitrate"
        case .downscale where type.isPDF: "Compression"
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
        return cq.tier == .adaptive ? "Adaptive" : "\(cq.factor)% compression"
    }

    static func anchors(for type: ItemType) -> [Double] {
        type.isVideo ? [videoLossless, videoFast, videoSmallerStart] : [imageAdaptive, imageFactorStart]
    }
}

@MainActor func currentCompressionQuality(for optimiser: Optimiser) -> CompressionQuality {
    if let override = optimiser.compressionOverride { return override }
    return optimiser.type.isVideo ? Defaults[.videoCompression] : Defaults[.imageCompression]
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
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self, window != nil else { return event }

                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event } // Esc bails out of the drag without committing
                    directTracking = false
                    didDrag = false
                    onCancel?()
                    return nil
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

struct LowerBitrateButton: View {
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
            },
            label: {
                SwiftUI.Image(systemName: optimiser.aggressive ? "bolt.fill" : "bolt")
                    .font(.heavy(9))
                    .foregroundColor(optimiser.aggressive ? FloatingResult.yellow : nil)
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
            if optimiser.type.isAudio, optimiser.type.utType != .wav {
                LowerBitrateButton(optimiser: optimiser)
            } else if optimiser.type.isPDF {
                LowerPDFDPIButton(optimiser: optimiser)
            } else if !optimiser.type.isAudio {
                DownscaleButton(optimiser: optimiser)
            }
        case .compression:
            CompressionButton(optimiser: optimiser)
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
                    SwiftUI.Image(systemName: "paperplane.fill").font(.heavy(9))
                }
                .contentShape(Rectangle())
            }
        }
    }

    func isAvailable() -> Bool {
        switch action {
        case .downscale: optimiser.canDownscale()
        case .compression: optimiser.canReoptimise() && (optimiser.type.isImage || optimiser.type.isVideo)
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
