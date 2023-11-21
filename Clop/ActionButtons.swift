import Defaults
import Foundation
import Lowtech
import SwiftUI

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
        )

    }
}

struct RestoreOptimiseButton: View {
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        if optimiser.url != nil, !optimiser.running {
            if optimiser.isOriginal {
                Button(
                    action: { if !preview { optimiser.optimise(allowLarger: false) } },
                    label: { SwiftUI.Image(systemName: "goforward.plus").font(.heavy(9)) }
                )
            } else {
                Button(
                    action: { if !preview { optimiser.restoreOriginal() } },
                    label: { SwiftUI.Image(systemName: "arrow.uturn.left").font(.semibold(9)) }
                )
            }
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
        Button(
            action: { if !preview { optimiser.downscale() }},
            label: { SwiftUI.Image(systemName: "minus").font(.heavy(9)) }
        )
        .contextMenu {
            DownscaleMenu(optimiser: optimiser)
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
    }
}

struct SideButtons: View {
    @ObservedObject var optimiser: Optimiser
    var size: CGFloat

    @Environment(\.preview) var preview
    @Default(.floatingResultsCorner) var floatingResultsCorner

    @State var hoveringDownscaleButton = false
    @State var hoveringShareButton = false
    @State var hoveringRestoreOptimiseButton = false
    @State var hoveringAggressiveOptimisationButton = false

    var body: some View {
        let isTrailing = floatingResultsCorner.isTrailing
        VStack {
            DownscaleButton(optimiser: optimiser)
                .onHover { hoveringDownscaleButton = $0 }
                .helpTag(
                    isPresented: $hoveringDownscaleButton,
                    alignment: isTrailing ? .trailing : .leading,
                    offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                    "Downscale (⌘-)"
                )
            ShareButton(optimiser: optimiser)
                .onHover { hoveringShareButton = $0 }
                .helpTag(
                    isPresented: $hoveringShareButton,
                    alignment: isTrailing ? .trailing : .leading,
                    offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                    "Share"
                )
            RestoreOptimiseButton(optimiser: optimiser)
                .onHover { hoveringRestoreOptimiseButton = $0 }
                .helpTag(
                    isPresented: $hoveringRestoreOptimiseButton,
                    alignment: isTrailing ? .trailing : .leading,
                    offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                    optimiser.isOriginal ? "Optimise" : "Restore original (⌘Z)"
                )

            if !optimiser.aggresive {
                AggressiveOptimisationButton(optimiser: optimiser)
                    .onHover { hoveringAggressiveOptimisationButton = $0 }
                    .helpTag(
                        isPresented: $hoveringAggressiveOptimisationButton,
                        alignment: isTrailing ? .trailing : .leading,
                        offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                        "Aggressive optimisation (⌘A)"
                    )
            }
        }
        .buttonStyle(FlatButton(color: .white.opacity(0.9), textColor: .black.opacity(0.7), width: size, height: size, circle: true))
        .animation(.fastSpring, value: optimiser.aggresive)
        .onHover { hovering in
            if !hovering {
                hoveringDownscaleButton = false
                hoveringShareButton = false
                hoveringRestoreOptimiseButton = false
                hoveringAggressiveOptimisationButton = false
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
    @Environment(\.colorScheme) var colorScheme

    @State var hovering = false

    @State var hoveringDownscaleButton = false
    @State var hoveringQuickLookButton = false
    @State var hoveringRestoreOptimiseButton = false
    @State var hoveringAggressiveOptimisationButton = false
    @State var hoveringShowInFinderButton = false
    @State var hoveringSaveAsButton = false
    @State var hoveringCopyToClipboardButton = false
    @State var hoveringShareButton = false

    var body: some View {
        HStack {
            DownscaleButton(optimiser: optimiser)
                .onHover { hoveringDownscaleButton = $0 }
                .topHelpTag(isPresented: $hoveringDownscaleButton, "Downscale (⌘-)")

            QuickLookButton(optimiser: optimiser)
                .onHover { hoveringQuickLookButton = $0 }
                .topHelpTag(isPresented: $hoveringQuickLookButton, "QuickLook (⌘space)")

            RestoreOptimiseButton(optimiser: optimiser)
                .onHover { hoveringRestoreOptimiseButton = $0 }
                .topHelpTag(isPresented: $hoveringRestoreOptimiseButton, optimiser.isOriginal ? "Optimise" : "Restore original (⌘Z)")

            if !optimiser.aggresive {
                AggressiveOptimisationButton(optimiser: optimiser)
                    .onHover { hoveringAggressiveOptimisationButton = $0 }
                    .topHelpTag(isPresented: $hoveringAggressiveOptimisationButton, "Aggressive optimisation (⌘A)")

            }

            Divider().background(.secondary).frame(width: 10)

            ShowInFinderButton(optimiser: optimiser)
                .onHover { hoveringShowInFinderButton = $0 }
                .topHelpTag(isPresented: $hoveringShowInFinderButton, "Show in Finder (⌘F)")

            SaveAsButton(optimiser: optimiser)
                .onHover { hoveringSaveAsButton = $0 }
                .topHelpTag(isPresented: $hoveringSaveAsButton, "Save as (⌘S)")

            CopyToClipboardButton(optimiser: optimiser)
                .onHover { hoveringCopyToClipboardButton = $0 }
                .topHelpTag(isPresented: $hoveringCopyToClipboardButton, "Copy to clipboard (⌘C)")

            ShareButton(optimiser: optimiser)
                .onHover { hoveringShareButton = $0 }
                .topHelpTag(isPresented: $hoveringShareButton, "Share")

        }
        .hfill()
        .buttonStyle(FlatButton(color: .bg.warm, textColor: .primary.opacity(0.7), width: size, height: size, circle: true, shadowSize: 1))
        .animation(.fastSpring, value: optimiser.aggresive)
        .onHover { hovering in
            self.hovering = hovering
            if !hovering {
                hoveringDownscaleButton = false
                hoveringQuickLookButton = false
                hoveringRestoreOptimiseButton = false
                hoveringAggressiveOptimisationButton = false
                hoveringShowInFinderButton = false
                hoveringSaveAsButton = false
                hoveringCopyToClipboardButton = false
                hoveringShareButton = false
            }
        }
    }
}
