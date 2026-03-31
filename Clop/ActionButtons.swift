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
        } else {
            Button(
                action: { if !preview { optimiser.restoreOriginal() } },
                label: { SwiftUI.Image(systemName: "arrow.uturn.left").font(.semibold(9)) }
            )
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
    }
}

struct ActionButton: View {
    let action: FloatingAction
    @ObservedObject var optimiser: Optimiser
    @Environment(\.preview) var preview

    var body: some View {
        switch action {
        case .downscale:
            DownscaleButton(optimiser: optimiser)
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
        case .showInFinder:
            ShowInFinderButton(optimiser: optimiser)
        case .quickLook:
            QuickLookButton(optimiser: optimiser)
        case .saveAs:
            Button(action: { if !preview { optimiser.save() } }) {
                SwiftUI.Image(systemName: "square.and.arrow.down").font(.heavy(9))
            }
        case .addToShelf:
            Button(action: { if !preview, let app = runningShelfApp() { app.open(optimiser: optimiser) } }) {
                SwiftUI.Image(systemName: "tray.and.arrow.down").font(.heavy(9))
            }
        case .sendSecurely:
            if let session = WDM.session(forOptimiser: optimiser) {
                Button(action: {
                    if !preview {
                        session.copyLink()
                        optimiser.overlayMessage = "Copied link"
                    }
                }) {
                    SwiftUI.Image(systemName: "link").font(.heavy(9))
                }
            } else {
                Button(action: { if !preview { warpDropSend(optimiser: optimiser) } }) {
                    SwiftUI.Image(systemName: "lock.shield").font(.heavy(9))
                }
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
                            isPresented: .init(get: { hoveringAction == action }, set: { if !$0 { hoveringAction = nil } }),
                            alignment: isTrailing ? .trailing : .leading,
                            offset: CGSize(width: isTrailing ? -30 : 30, height: 0),
                            action.label
                        )
                }
            }
        }
        .buttonStyle(FlatButton(color: .clear, textColor: .primary.opacity(0.7), width: size, height: size, circle: true))
        .sideButtonBackground()
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
                            isPresented: .init(get: { hoveringAction == action }, set: { if !$0 { hoveringAction = nil } }),
                            action.label
                        )
                }
            }
        }
        .buttonStyle(FlatButton(color: .clear, textColor: .primary.opacity(0.7), width: size, height: size, circle: true))
        .sideButtonBackground()
        .hfill()
        .animation(.fastSpring, value: optimiser.aggressive)
        .onHover { if !$0 { hoveringAction = nil } }
    }
}
