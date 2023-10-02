import Defaults
import Foundation
import Lowtech
import SwiftUI

struct CloseStopButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        Button(
            action: {
                guard !preview else { return }

                hoveredOptimiserID = nil
                optimiser.stop(animateRemoval: true)
            },
            label: { SwiftUI.Image(systemName: optimiser.running ? "stop.fill" : "xmark").font(.heavy(9)) }
        )
        .help((optimiser.running ? "Stop" : "Close") + " (\(keyComboModifiers.str)⌫)")
    }
}

struct RestoreOptimiseButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        if optimiser.url != nil, !optimiser.running {
            if optimiser.isOriginal {
                Button(
                    action: { if !preview { optimiser.optimise(allowLarger: false) } },
                    label: { SwiftUI.Image(systemName: "goforward.plus").font(.heavy(9)) }
                )
                .help("Optimise")
            } else {
                Button(
                    action: { if !preview { optimiser.restoreOriginal() } },
                    label: { SwiftUI.Image(systemName: "arrow.uturn.left").font(.semibold(9)) }
                )
                .help("Restore original (\(keyComboModifiers.str)Z)")
            }
        }
    }
}

struct ChangePlaybackSpeedButton: View {
    @ObservedObject var optimiser: Optimiser
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        let factor = optimiser.changePlaybackSpeedFactor.truncatingRemainder(dividingBy: 1) != 0
            ? String(format: "%.\(optimiser.changePlaybackSpeedFactor == 1.5 ? 1 : 2)f", optimiser.changePlaybackSpeedFactor)
            : optimiser.changePlaybackSpeedFactor.i.s
        Menu("\(factor)x") {
            ChangePlaybackSpeedMenu(optimiser: optimiser)
        }
        .menuButtonStyle(BorderlessButtonMenuButtonStyle())
        .help("Change Playback Speed" + " (\(keyComboModifiers.str)X)")
        .buttonStyle(FlatButton(color: .clear, textColor: .white, circle: optimiser.changePlaybackSpeedFactor >= 2))
        .font(.round(11, weight: .bold))
    }
}
struct DownscaleButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        Button(
            action: { if !preview { optimiser.downscale() }},
            label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) }
        )
        .help("Downscale (\(keyComboModifiers.str)-)")
        .contextMenu {
            DownscaleMenu(optimiser: optimiser)
        }
    }
}

struct QuickLookButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        Button(
            action: { if !preview { optimiser.quicklook() }},
            label: { SwiftUI.Image(systemName: "eye").font(.heavy(9)) }
        )
        .help("QuickLook (\(keyComboModifiers.str)space)")
    }
}

struct ShowInFinderButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        Button(
            action: { if !preview { optimiser.showInFinder() }},
            label: { SwiftUI.Image(systemName: "folder").font(.heavy(9)) }
        )
        .help("Show in Finder (\(keyComboModifiers.str)F)")
    }
}

struct SaveAsButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        Button(
            action: { if !preview { optimiser.save() }},
            label: { SwiftUI.Image(systemName: "square.and.arrow.down").font(.heavy(9)) }
        )
        .help("Save as (\(keyComboModifiers.str)S)")
    }
}

struct CopyToClipboardButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        Button(
            action: { if !preview {
                optimiser.copyToClipboard()
                optimiser.overlayMessage = "Copied"
            }},
            label: { SwiftUI.Image(systemName: "doc.on.doc").font(.heavy(9)) }
        )
        .help("Copy to clipboard (\(keyComboModifiers.str)C)")
    }
}

struct AggressiveOptimisationButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

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
        .help("Aggressive optimisation (\(keyComboModifiers.str)A)")
    }
}

struct SideButtons: View {
    @ObservedObject var optimiser: Optimiser
    var size: CGFloat

    @Environment(\.preview) var preview
    @Default(.keyComboModifiers) var keyComboModifiers

    var body: some View {
        VStack {
            DownscaleButton(optimiser: optimiser)
            QuickLookButton(optimiser: optimiser)
            RestoreOptimiseButton(optimiser: optimiser)

            if !optimiser.aggresive {
                AggressiveOptimisationButton(optimiser: optimiser)
            }
        }
        .buttonStyle(FlatButton(color: .white.opacity(0.9), textColor: .black.opacity(0.7), width: size, height: size, circle: true))
        .animation(.fastSpring, value: optimiser.aggresive)
    }
}

struct ActionButtons: View {
    @ObservedObject var optimiser: Optimiser
    var size: CGFloat

    @Environment(\.preview) var preview

    var body: some View {
        HStack(spacing: 1) {
            DownscaleButton(optimiser: optimiser)
            QuickLookButton(optimiser: optimiser)
            RestoreOptimiseButton(optimiser: optimiser)

            if !optimiser.aggresive {
                AggressiveOptimisationButton(optimiser: optimiser)
            }

            Spacer()
            Divider()
            Spacer()

            ShowInFinderButton(optimiser: optimiser)
            SaveAsButton(optimiser: optimiser)
            CopyToClipboardButton(optimiser: optimiser)
        }
        .buttonStyle(FlatButton(color: .inverted.opacity(0.8), textColor: .primary.opacity(0.9), width: size, height: size, circle: true))
        .animation(.fastSpring, value: optimiser.aggresive)
        .hfill(.leading)
        .roundbg(radius: 10, verticalPadding: 2, horizontalPadding: 2, color: .primary.opacity(0.05))
    }
}
