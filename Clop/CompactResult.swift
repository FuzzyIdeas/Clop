import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

#if !SETAPP
    import LowtechPro
#endif

struct CompactResult: View {
    static let improvementColor = Color(light: FloatingResult.darkBlue, dark: FloatingResult.yellow)

    @ObservedObject var sm = SM
    @ObservedObject var optimiser: Optimiser
    @State var hovering = false

    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.neverShowProError) var neverShowProError
    @Default(.showCompactImages) var showCompactImages

    @Environment(\.openWindow) var openWindow
    @Environment(\.preview) var preview
    @Environment(\.openURL) var openURL
    @Environment(\.colorScheme) var colorScheme

    var isEven: Bool

    @ViewBuilder var pathView: some View {
        if let url = optimiser.url, url.isFileURL {
            Text(url.filePath!.shellString)
                .medium(9)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder var nameView: some View {
        if let url = optimiser.url, url.isFileURL {
            Text(url.lastPathComponent)
                .medium(9)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder var progressURLView: some View {
        if optimiser.type.isURL, let url = optimiser.url {
            HStack(spacing: 2) {
                SwiftUI.Image(systemName: "link")
                    .font(.medium(10))
                    .foregroundColor(.secondary.opacity(0.75))

                Link(url.absoluteString, destination: url)
                    .font(.medium(10))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .truncationMode(.middle)
            }
        }
    }
    @ViewBuilder var progressView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if optimiser.progress.isIndeterminate {
                VStack(alignment: .leading) {
                    Text(optimiser.operation)
                    ProgressView(optimiser.progress)
                        .progressViewStyle(.linear)
                        .allowsTightening(false)
                    nameView
                }
                progressURLView.padding(.vertical, 4)
            } else {
                VStack(alignment: .leading) {
                    Spacer()
                    ProgressView(optimiser.progress).progressViewStyle(.linear).allowsTightening(false)
                    Spacer()
                    nameView
                }
                progressURLView
                    .padding(.vertical, 4)
            }
        }
    }
    @ViewBuilder var sizeDiff: some View {
        if let oldSize = optimiser.oldSize, !sm.selecting {
            ResolutionField(optimiser: optimiser, size: oldSize)
                .buttonStyle(FlatButton(color: .bg.warm, textColor: .fg.warm.opacity(0.8), radius: 4, horizontalPadding: 3, verticalPadding: 1, shadowSize: 1))
                .font(.round(10, weight: .medium))
                .foregroundColor(.fg.warm)
                .fixedSize()
                .disabled(!optimiser.canCrop())
        }
    }

    @ViewBuilder var fileSizeDiff: some View {
        let improvement = optimiser.newBytes > 0 && optimiser.newBytes < optimiser.oldBytes

        HStack {
            Text(optimiser.oldBytes.humanSize)
                .mono(11, weight: .semibold)
                .foregroundColor(
                    !sm.selecting
                        ? (improvement ? Color.red : Color.secondary)
                        : (improvement ? Color.secondary : Color.primary)
                )
            if optimiser.newBytes > 0, optimiser.newBytes != optimiser.oldBytes {
                SwiftUI.Image(systemName: "arrow.right")
                    .font(.medium(11))
                Text(optimiser.newBytes.humanSize)
                    .mono(11, weight: .semibold)
                    .foregroundColor(
                        improvement
                            ? (!sm.selecting ? Self.improvementColor : .primary)
                            : (!sm.selecting ? FloatingResult.red : .secondary)
                    )
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder var errorView: some View {
        let proError = optimiser.id == Optimiser.IDs.pro
        if let error = optimiser.error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .medium(12)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if let notice = optimiser.notice {
                    Text(notice)
                        .round(10)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                #if !SETAPP
                    if proError {
                        HStack {
                            Button("Get Clop Pro") {
                                settingsViewManager.tab = .about
                                openWindow(id: "settings")

                                PRO?.manageLicence()
                                focus()
                            }
                            .buttonStyle(FlatButton(color: .inverted, textColor: .mauvish, radius: 5, verticalPadding: 2))
                            .font(.round(10, weight: .heavy))
                            .colorMultiply(.mauvish.blended(withFraction: 0.8, of: .white))
                            Spacer()
                            Button("Never show this again") {
                                neverShowProError = true
                                hoveredOptimiserID = nil
                                optimiser.remove(after: 200, withAnimation: true)
                            }
                            .buttonStyle(FlatButton(color: .inverted.opacity(0.8), textColor: .secondary, radius: 5, verticalPadding: 2))
                            .font(.round(10, weight: .semibold))
                        }
                    }
                #endif
                pathView
            }
            .allowsTightening(true)
        }
    }
    @ViewBuilder var thumbnail: some View {
        if showCompactImages {
            VStack {
                if let image = optimiser.thumbnail {
                    SwiftUI.Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    SwiftUI.Image(systemName: optimiser.type.icon)
                        .font(.system(size: 22))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
    @ViewBuilder var noticeView: some View {
        if let notice = optimiser.notice {
            VStack(alignment: .leading) {
                ForEach(notice.components(separatedBy: "\n"), id: \.self) { line in
                    Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
                pathView
            }
            .allowsTightening(true)
        }
    }

    var body: some View {
        HStack {
            thumbnail

            if optimiser.running {
                progressView
                    .controlSize(.small)
                    .font(.medium(12)).lineLimit(1)
            } else if optimiser.error != nil {
                errorView
            } else if optimiser.notice != nil {
                noticeView
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let url = (optimiser.url ?? optimiser.originalURL), url.isFileURL {
                        FileNameField(optimiser: optimiser)
                            .foregroundColor(.primary)
                            .font(.medium(12)).lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: THUMB_SIZE.width * 0.6, alignment: .leading)
                    }
                    HStack {
                        fileSizeDiff
                        Spacer()
                        sizeDiff
                    }
                    if !sm.selecting {
                        ActionButtons(optimiser: optimiser, size: 18)
                            .padding(.top, 2)
                            .hfill(.leading)
                            .roundbg(
                                radius: 10, verticalPadding: 3, horizontalPadding: 2,
                                color: .primary.opacity(colorScheme == .dark ? 0.1 : 0.04)
                            )
                            .focusable(false)
                            .frame(height: 26)
                    }
                }
            }
        }
        .padding(.top, 3)
        .frame(height: 70)
        .hfill(.leading)
        .if(!sm.selecting) { view in
            view
                .overlay(alignment: .topTrailing) {
                    CompactCloseStopButton(optimiser: optimiser)
                        .buttonStyle(FlatButton(color: .bg.warm, textColor: Color.mauvish.opacity(0.8)))
                        .focusable(false)
                        .shadow(color: Color.shadow.opacity(colorScheme == .dark ? 0.5 : 0.1), radius: colorScheme == .dark ? 4 : 2, x: 0, y: 1)
                        .offset(x: 4, y: 0)
                        .opacity(hovering ? (hoveringCloseStopButton ? 1 : 0.4) : 0)
                        .onHover(perform: { hovering in
                            hoveringCloseStopButton = hovering
                        })
                }
        }
        .onHover(perform: updateHover(_:))
        .ifLet(optimiser.url, transform: { view, url in
            view
                .onDrag {
                    guard !preview else {
                        return NSItemProvider()
                    }

                    log.debug("Dragging \(url)")
                    if Defaults[.dismissCompactResultOnDrop] {
                        optimiser.remove(after: 100, withAnimation: true)
                    }
                    return NSItemProvider(object: url as NSURL)
                } preview: {
                    DragPreview(optimiser: optimiser)
                }

        })
    }

    func updateHover(_ hovering: Bool) {
        if hovering, !preview {
            hoveredOptimiserID = optimiser.id
        }
        withAnimation(.easeOut(duration: 0.15)) {
            self.hovering = hovering
        }
    }

    @State private var hoveringCloseStopButton = false

}

struct CompactCloseStopButton: View {
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
            label: {
                HStack(spacing: 2) {
                    SwiftUI.Image(systemName: optimiser.running ? "stop.fill" : "xmark").font(.heavy(8))
                    Text(optimiser.running ? "Stop" : "Close").font(.medium(9))
                }
            }
        )

    }
}

struct OverlayMessageView: View {
    @ObservedObject var optimiser: Optimiser
    var color: Color

    @State var opacity = 1.0

    var body: some View {
        if optimiser.overlayMessage.isNotEmpty {
            Text(optimiser.overlayMessage)
                .foregroundColor(color == .black ? .white : .primary)
                .roundbg(radius: 12, padding: 6, color: color)
                .fill()
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow, state: .active, appearance: color == .black ? .vibrantDark : .none).scaleEffect(1.1)
                )
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.15)) {
                        opacity = 1.0
                    }
                    withAnimation(.easeIn(duration: 0.5).delay(0.3)) {
                        opacity = 0.0
                    }
                }
        }
    }
}

struct DeselectButton: View {
    var body: some View {
        let img = SwiftUI.Image(systemName: "xmark.rectangle.fill")
        Button("\(img) Clear selection") { SM.selection = [] }
    }
}

struct StopSelectionButton: View {
    var body: some View {
        let img = SwiftUI.Image(systemName: "chevron.backward.circle.fill")
        Button("\(img) Back") { SM.selecting = false }
    }
}

@MainActor
class SelectionManager: ObservableObject {
    @Published var selection = Set<String>()
    @Published var selectableCount = 0

    @Published var selecting = false {
        didSet {
            if selecting {
                for opt in OM.optimisers {
                    opt.editingFilename = false
                }
            }
        }
    }
    var optimisers: [Optimiser] { OM.optimisers.filter { selection.contains($0.id) } }

    func save() {
        let paths: [String: FilePath] = optimisers.dict { o in
            guard let path = o.url?.existingFilePath else { return nil }
            return (o.id, path)
        }
        guard !paths.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.level = .modalPanel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            var savedURLs = [URL]()
            for (id, path) in paths {
                if let savedPath = try? path.copy(to: url.filePath!, force: true), let opt = opt(id) {
                    let url = savedPath.url
                    savedURLs.append(url)

                    opt.url = url
                    opt.path = savedPath
                    opt.filename = savedPath.name.string

                    try? path.setOptimisationStatusXattr("true")
                }
            }

            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        }
    }

    func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(optimisers.compactMap { $0.url as NSURL? })
    }

    func restoreOriginal() {
        for optimiser in optimisers {
            optimiser.restoreOriginal()
        }
    }

    func quicklook() {
        OM.quicklook()
    }

    func uploadWithDropshare() {
        OM.uploadWithDropshare(optimisers: optimisers)
    }

}

@MainActor let SM = SelectionManager()

struct SelectButton: View {
    var body: some View {
        let img = SwiftUI.Image(systemName: "checkmark.rectangle.stack.fill")
        Button("\(img) Select all") { SM.selection = OM.visibleOptimisers.filter(!\.running).map(\.id).set }
    }
}

struct StartSelectionButton: View {
    var body: some View {
        let img = SwiftUI.Image(systemName: "checkmark.rectangle.fill")
        Button("\(img) Select") { SM.selecting = true }
    }
}

struct CompactActionButtons: View {
    @ObservedObject var sm = SM

    var body: some View {
        HStack {
            if !sm.selecting {
                StartSelectionButton()
            } else {
                if sm.selection.count == 0 {
                    StopSelectionButton()
                } else {
                    DeselectButton()
                }
                if sm.selection.count < sm.selectableCount {
                    SelectButton()
                }
                Text("\(sm.selection.count)/\(sm.selectableCount)")
                    .foregroundColor(.secondary)
                    .roundbg(radius: 7, padding: 2, color: .inverted.opacity(0.3))
            }
        }
        .buttonStyle(FlatButton(color: Color.bg.warm, textColor: .primary.opacity(0.7), width: 22, height: 22, horizontalPadding: 6, verticalPadding: 2))
        .lineLimit(1)
        .font(.bold(11))
        .allowsTightening(false)
    }
}

@MainActor struct CompactOptimiser: Identifiable {
    let optimiser: Optimiser
    let isLast: Bool
    let isEven: Bool
    let index: Int

    var id: String { optimiser.id }
    var running: Bool { optimiser.running }

    var selected: Bool {
        SM.selection.contains(id)
    }
}

struct DragHandle: View {
    @State var hovering = false
    @State var hoveringDots = false

    var body: some View {
        VStack(spacing: -1) {
            Group {
                SwiftUI.Image(systemName: "square.grid.4x3.fill")
                    .scaledToFill()
                SwiftUI.Image(systemName: "square.grid.4x3.fill")
                    .scaledToFill()
            }
            .onHover { h in
                withAnimation(.easeOut(duration: 0.15)) {
                    hoveringDots = h
                }
            }
        }
        .vfill()
        .frame(width: 20)
        .foregroundColor(hoveringDots ? .red.opacity(0.5) : .secondary.opacity(0.5))
        .roundbg(color: .primary.opacity(hovering ? 0.1 : 0.05))
        .scaleEffect(hovering ? 1.05 : 1)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = h
                if !h {
                    hoveringDots = false
                }
            }
        }
    }
}

struct CompactResultList: View {
    @State var hovering = false
    @State var showList = false
    @State var size = NSSize(width: 50, height: 50)

    var optimisers: [Optimiser]
    var progress: Progress?

    var doneCount: Int
    var failedCount: Int
    var visibleCount: Int

    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.showCompactImages) var showCompactImages
    @Default(.keyComboModifiers) var keyComboModifiers

    @Environment(\.preview) var preview
    @Environment(\.colorScheme) var colorScheme

    @ObservedObject var sm = SM

    @State var opts: [CompactOptimiser] = []

    @State var hoveringBatchActions = false

    @ViewBuilder var topButtons: some View {
        let hasRunningOptimisers = visibleCount > (doneCount + failedCount)

        HStack {
            #if !SETAPP
                if floatingResultsCorner.isTrailing {
                    UpdateButton(short: !showCompactImages)
                    Spacer()
                }
            #endif

            if hasRunningOptimisers {
                Button("Stop all") {
                    for optimiser in OM.optimisers.filter(\.running) {
                        optimiser.stop(remove: false)
                        optimiser.uiStop()
                    }
                }
            }
            Button(hasRunningOptimisers ? "Stop and clear" : "Clear all") {
                OM.clearVisibleOptimisers(stop: true)
            }
            .help("Stop all running optimisations and dismiss all results (\(keyComboModifiers.str) esc)")

            #if !SETAPP
                if !floatingResultsCorner.isTrailing {
                    Spacer()
                    UpdateButton(short: !showCompactImages)
                }
            #endif
        }
        .buttonStyle(FlatButton(color: .inverted.opacity(0.9), textColor: .mauvish, radius: 7, verticalPadding: 2))
        .font(.medium(11))
        .opacity(hovering && showList ? 1 : 0)
        .focusable(false)
        .frame(width: size.width, alignment: floatingResultsCorner.isTrailing ? .trailing : .leading)
    }

    var body: some View {
        let isTrailing = floatingResultsCorner.isTrailing

        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 5) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                if !sm.selecting {
                    topButtons
                }

                ZStack(alignment: .bottom) {
                    List(opts, selection: $sm.selection) { opt in
                        HStack {
                            if sm.selecting {
                                DragHandle()
                            }
                            CompactResult(optimiser: opt.optimiser, isEven: opt.isEven)
//                                .roundbg(radius: 8, padding: 4, color: .fg.warm.opacity(0.1))
                                .if(!sm.selecting) {
                                    $0.overlay(
                                        OverlayMessageView(optimiser: opt.optimiser, color: .inverted)
                                            .foregroundColor(.primary)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    )
                                }
                                .tag(opt.id)
                        }
                        .if(!sm.selecting && !opt.optimiser.inRemoval) { view in
                            view.contextMenu {
                                RightClickMenuView(optimiser: opt.optimiser)
                            }
                        }
                        .if(opt.selected) { view in
                            view
                                .draggable(opt.optimiser.url ?? URL(fileURLWithPath: "/tmp")) { DragPreview(optimiser: opt.optimiser) }
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
//                    .listStyle(.bordered)
                    .listItemTint(.monochrome)
                    .padding(.bottom, progress == nil ? 0 : 18)
                    .frame(width: size.width, height: size.height, alignment: .center)
                    .fixedSize()
                    .background(Color.inverted.brightness(0.1))
                    .if(!sm.selection.isEmpty) {
                        $0.contextMenu { BatchRightClickMenuView() }
                    }
                    .onHover { hovering in
                        if !hovering {
                            hoveredOptimiserID = nil
                        }
                    }
                    .onChange(of: sm.selection) { sel in
                        guard !sel.isEmpty else {
                            floatingResultsWindow.allowToBecomeKey = false
                            sm.selecting = false
                            return
                        }
                        sm.selecting = true
                        if !floatingResultsWindow.allowToBecomeKey {
                            floatingResultsWindow.allowToBecomeKey = true
                            focus()
                            floatingResultsWindow.becomeFirstResponder()
                            floatingResultsWindow.makeKeyAndOrderFront(nil)
                            floatingResultsWindow.orderFrontRegardless()
                        }
                    }

                    if progress != nil {
                        ProgressView(" Done: \(doneCount)/\(visibleCount)  |  Failed: \(failedCount)/\(visibleCount)", value: (doneCount + failedCount).d, total: visibleCount.d)
                            .controlSize(.small)
                            .frame(width: THUMB_SIZE.width + (showCompactImages ? 40 : -10))
                            .padding(.top, 4)
                            .background(VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow, state: .active).scaleEffect(1.1))
                            .offset(y: 6)
                            .font(.mono(9))
                    }
                    if !sm.selection.isEmpty {
                        VStack(spacing: 4) {
                            HStack {
                                Button("Save to folder") {
                                    sm.save()
                                    sm.selection = []
                                }
                                BatchCropButton()
                                Menu("Downscale") {
                                    BatchDownscaleMenu(optimisers: sm.selection.compactMap { opt($0) })
                                }
                            }
                            .font(.round(10))
                            .buttonStyle(FlatButton(color: .inverted.opacity(0.7), textColor: .primary.opacity(0.7), shadowSize: 1))
                            .opacity(hoveringBatchActions ? 1.0 : 0.3)
//                            Text("Right click for more actions")
//                                .round(9).foregroundColor(.inverted)
//                                .roundbg(radius: 4, color: .primary.opacity(0.9))
//                                .opacity(hoveringBatchActions ? 1.0 : 0.0)
//                                .allowsHitTesting(false)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 2)
                        .onHover { hovering in
                            withAnimation { hoveringBatchActions = hovering }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.bg.warm, lineWidth: 2)
                )
                .shadow(radius: preview ? 0 : 10)
                .opacity(showList ? 1 : 0)
                .allowsHitTesting(showList)

                HStack {
                    FlipGroup(if: !floatingResultsCorner.isTrailing) {
                        if showList, !preview {
                            if !floatingResultsCorner.isTrailing {
                                Spacer()
                            }
                            CompactActionButtons()
                                .offset(y: floatingResultsCorner.isTop ? 12 : -12)
                                .opacity(hovering ? 1 : 0)
                            if floatingResultsCorner.isTrailing {
                                Spacer()
                            }
                        }
                        ToggleCompactResultListButton(showList: $showList, badge: optimisers.count.s, progress: progress)
                            .offset(x: isTrailing ? 10 : -10)
                    }
                }
                .frame(width: size.width, alignment: isTrailing ? .trailing : .leading)
            }
        }
        .padding(isTrailing ? .trailing : .leading)
        .onHover { hovered in
            withAnimation(.easeIn(duration: 0.35)) {
                hovering = hovered
            }
        }
        .onChange(of: showList) { showList in
            setSize(showList: showList)
        }
        .onChange(of: optimisers) { optimisers in
            filterOpts(optimisers)
            setSize(count: optimisers.count)
        }
        .onChange(of: showCompactImages) { compactImages in setSize(compactImages: compactImages) }
        .onAppear {
            filterOpts()
            showList = preview || optimisers.count <= 3
            setSize()
        }
    }

    func filterOpts(_ optimisers: [Optimiser]? = nil) {
        let optimisers = optimisers ?? self.optimisers
        opts = optimisers.isEmpty
            ? []
            : optimisers
                .dropLast().enumerated()
                .map { n, x in
                    CompactOptimiser(optimiser: x, isLast: false, isEven: (n + 1).isMultiple(of: 2), index: n)
                } + [CompactOptimiser(optimiser: optimisers.last!, isLast: true, isEven: optimisers.count.isMultiple(of: 2), index: optimisers.count - 1)]
    }

    func setSize(showList: Bool? = nil, count: Int? = nil, compactImages: Bool? = nil) {
        size = NSSize(
            width: (showList ?? self.showList) ? (THUMB_SIZE.width + ((compactImages ?? showCompactImages) ? 50 : 0)) : 50,
            height: (showList ?? self.showList) ? min(360, ((count ?? optimisers.count) * 80).cg) : 50
        )
    }

    @State private var lastSelectedIndex = 0

}

struct DragPreview: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        ZStack {
            if let thumb = optimiser.thumbnail {
                SwiftUI.Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                SwiftUI.Image(systemName: optimiser.type.isVideo ? "video.fill" : (optimiser.type.isPDF ? "doc.fill" : "photo.fill"))
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.primary)
            }
        }
        .frame(width: THUMB_SIZE.width * 0.5, height: THUMB_SIZE.height * 0.5)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ToggleCompactResultListButton: View {
    @Binding var showList: Bool
    var badge: String
    var progress: Progress?

    var body: some View {
        VStack(spacing: 0) {
            FlipGroup(if: floatingResultsCorner.isTop) {
                Button(
                    action: {
                        showList.toggle()
                        if !showList {
                            hoveredOptimiserID = nil
                        }
                    },
                    label: {
                        ZStack(alignment: floatingResultsCorner.isTrailing ? .topLeading : .topTrailing) {
                            if progress == nil || showList {
                                SwiftUI.Image("clop")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 32, height: 32, alignment: .center)
                                    .opacity(hovering ? 1 : 0.5)
                            }
                            if !showList {
                                if let progress {
                                    ZStack {
                                        ProgressView(value: progress.fractionCompleted, total: 1)
                                            .progressViewStyle(.circular)
                                            .controlSize(.regular)
                                            .font(.regular(1))
                                            .background(.thinMaterial)
                                            .clipShape(Circle())
                                        Text((progress.totalUnitCount - progress.completedUnitCount).s)
                                            .round(13, weight: .semibold)
                                            .foregroundColor(.primary)
                                    }
                                    .opacity(hovering ? 1 : 0.6)
                                } else {
                                    Text(badge)
                                        .round(10)
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Circle().fill(Color.darkGray))
                                        .opacity(0.75)

                                }
                            }
                        }
                    }
                )
                .buttonStyle(FlatButton(color: .clear, textColor: .primary, radius: 7, verticalPadding: 2))

                Text(showList ? "Hide" : "Show")
                    .font(.medium(10))
                    .roundbg(radius: 5, padding: 2, color: .inverted.opacity(0.9), noFG: true)
                    .foregroundColor(.primary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                self.hovering = hovering
            }
        }
    }

    @Default(.floatingResultsCorner) private var floatingResultsCorner
    @State private var hovering = false

}

@MainActor
struct CompactPreview: View {
    static var om: OptimisationManager = {
        let o = OptimisationManager()
        let thumbSize = THUMB_SIZE.applying(.init(scaleX: 3, y: 3))

        let errorOpt = Optimiser(id: "file-with-error", type: .image(.png))
        errorOpt.url = "\(HOME)/Desktop/passport-scan.png".fileURL
        errorOpt.thumbnail = NSImage(resource: .passport)
        errorOpt.finish(error: "Already optimised")

        let pdfRunning = Optimiser(id: "scans.pdf", type: .pdf, running: true, progress: pdfProgress)
        pdfRunning.url = "\(HOME)/Documents/scans.pdf".fileURL
        pdfRunning.operation = "Optimising"
        pdfRunning.thumbnail = NSImage(resource: .scansPdf)

        let videoOpt = Optimiser(id: "Movies/meeting-recording.mov", type: .video(.quickTimeMovie), running: true, progress: videoProgress)
        videoOpt.url = "\(HOME)/Movies/meeting-recording.mov".fileURL
        videoOpt.operation = "Scaling to 50%"
        videoOpt.thumbnail = NSImage(resource: .sonomaVideo)
        videoOpt.changePlaybackSpeedFactor = 2.0

        let videoToGIF = Optimiser(id: "Videos/app-ui-demo.mov", type: .video(.quickTimeMovie), running: true, progress: videoToGIFProgress)
        videoToGIF.url = "\(HOME)/Videos/app-ui-demo.mov".fileURL
        videoToGIF.operation = "Converting to GIF"
        videoToGIF.thumbnail = NSImage(resource: .appUiDemo)

        let pdfEnd = Optimiser(id: "pages.pdf", type: .pdf)
        pdfEnd.url = "\(HOME)/Documents/pages.pdf".fileURL
        pdfEnd.thumbnail = NSImage(resource: .pagesPdf)
        pdfEnd.finish(oldBytes: 12_250_190, newBytes: 15_211_932)

        let gifOpt = Optimiser(id: "https://files.lowtechguys.com/moon.gif", type: .url, running: true, progress: gifProgress)
        gifOpt.url = "https://files.lowtechguys.com/moon.gif".url!
        gifOpt.operation = "Downloading"

        let pngIndeterminate = Optimiser(id: "png-indeterminate", type: .image(.png), running: true)
        pngIndeterminate.url = "\(HOME)/Desktop/device_hierarchy.png".fileURL
        pngIndeterminate.thumbnail = NSImage(resource: .deviceHierarchy)
        pngIndeterminate.operation = "Scaling to 50%"

        let clipEnd = Optimiser(id: Optimiser.IDs.clipboardImage, type: .image(.png))
        clipEnd.url = "\(HOME)/Desktop/sonoma-shot.png".fileURL
        clipEnd.thumbnail = NSImage(resource: .sonomaShot)
        clipEnd.finish(oldBytes: 750_190, newBytes: 211_932, oldSize: NSSize(width: 1880, height: 1000), newSize: NSSize(width: 1200, height: 600))

        let proErrorOpt = Optimiser(id: Optimiser.IDs.pro, type: .unknown)
        proErrorOpt.finish(error: "Free version limits reached", notice: "Only 5 file optimisations per session\nare included in the free version")

        let noticeOpt = Optimiser(id: "notice", type: .unknown, operation: "")
        noticeOpt.finish(notice: "**Paused**\nNext clipboard event will be ignored")

        o.optimisers = [
            clipEnd,
            videoOpt,
//            proErrorOpt,
            gifOpt,
            errorOpt,
            pngIndeterminate,
            pdfRunning,
//            noticeOpt,
            pdfEnd,
            videoToGIF,
        ]
        mainActor {
            o.updateProgress()
            o.visibleCount = o.visibleOptimisers.count
            o.doneCount = o.visibleOptimisers.filter { !$0.running && $0.error == nil }.count
            o.failedCount = o.visibleOptimisers.filter { !$0.running && $0.error != nil }.count
            SM.selectableCount = o.visibleOptimisers.filter { !$0.running && $0.url != nil }.count
        }
        return o
    }()

    static var videoProgress: Progress = {
        let p = Progress(totalUnitCount: 103_021_021)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 32_473_200
        p.localizedAdditionalDescription = "\(p.completedUnitCount.hmsString) of \(p.totalUnitCount.hmsString)"
        return p
    }()

    static var videoToGIFProgress: Progress = {
        let p = Progress(totalUnitCount: 492)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 201
        p.localizedAdditionalDescription = "Frame \(p.completedUnitCount) of \(p.totalUnitCount)"
        return p
    }()

    static var gifProgress: Progress = {
        let p = Progress(totalUnitCount: 23_421_021)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 17_473_200
        p.localizedAdditionalDescription = "\(p.completedUnitCount) of \(p.totalUnitCount) bytes"
        return p
    }()

    static var pdfProgress: Progress = {
        let p = Progress(totalUnitCount: 231)
        p.fileOperationKind = .optimising
        p.completedUnitCount = 35
        p.localizedAdditionalDescription = "Page \(p.completedUnitCount) of \(p.totalUnitCount)"
        return p
    }()

    var body: some View {
        FloatingResultContainer(om: Self.om, isPreview: true)
    }

}

struct CompactResult_Previews: PreviewProvider {
    static var previews: some View {
        CompactPreview()
            .background(LinearGradient(colors: [Color.red, .orange, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
