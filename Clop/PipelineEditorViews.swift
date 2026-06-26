import AppKit
import Defaults
import Lowtech
import SwiftUI

struct CompletionPanel: View {
    let suggestions: [CompletionSuggestion]
    let onSelect: (CompletionSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggestions")
                .dimmed(9, weight: .medium)
                .padding(.bottom, 3)
            ForEach(suggestions.prefix(10)) { suggestion in
                Button(action: { onSelect(suggestion) }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(suggestion.color)
                            .frame(width: 6, height: 6)
                        Text(suggestion.displayText)
                            .mono(11, weight: .medium)
                            .foregroundColor(suggestion.color)
                        if !suggestion.details.isEmpty {
                            Text(suggestion.details)
                                .regular(10)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// The completion panel + step grid shown under a pipeline editor while it is being edited. Shared by
/// the Automation, Pipelines library and Preset Zones editors so all three offer the same suggestions.
struct PipelineEditingSuggestions: View {
    let prefix: String
    let fileType: ClopFileType?
    let coordinator: PipelineTextView.Coordinator?

    var body: some View {
        let suggestions = pipelineSuggestions(prefix: prefix, fileType: fileType)
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty {
                CompletionPanel(suggestions: suggestions) { suggestion in
                    coordinator?.insertSuggestion(suggestion)
                    coordinator?.refocus()
                }
            }
            StepActionGrid(fileType: fileType) { text in
                coordinator?.appendStep(text)
                coordinator?.refocus()
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Pipeline Editor Row

struct PipelineEditorRow: View {
    let source: OptimisationSource
    let fileType: ClopFileType
    @Binding var pipelines: [String: [Pipeline]]
    @Binding var editingKey: String?

    var onRemoveSource: (() -> Void)?
    var hideInertRemoveButton = false

    var sourceIcon: String {
        switch source {
        case .clipboard: "doc.on.clipboard"
        case .dropZone: "square.dashed"
        default: "folder"
        }
    }

    var isDirSource: Bool {
        if case .dir = source { return true }
        return false
    }

    var isGlobalSource: Bool {
        switch source {
        case .clipboard, .dropZone: true
        default: false
        }
    }

    /// One-line scope hint shown only under the two global cards (Clipboard /
    /// Drop zone). Folder cards return nil, their scope is obvious from the path.
    var globalScopeSubtitle: String? {
        let noun = fileType == .pdf ? "PDF" : fileType.description.lowercased()
        switch source {
        case .clipboard: return "Runs on every \(noun) you copy"
        case .dropZone: return "Runs on every \(noun) you drop here"
        default: return nil
        }
    }

    var addPipelineMenu: some View {
        let sourceStr = source.string
        return Menu {
            Button("New pipeline") {
                var list = pipelines[sourceStr] ?? []
                list.append(Pipeline(steps: []))
                pipelines[sourceStr] = list
            }
            let saved: [Pipeline] = Defaults[.savedPipelines].filter { p in
                guard let name = p.name, !name.isEmpty else { return false }
                return p.fileType == nil || p.fileType == fileType
            }
            if !saved.isEmpty {
                Divider()
                ForEach(saved) { lib in
                    Button(lib.name ?? lib.id) {
                        var list = pipelines[sourceStr] ?? []
                        list.append(Pipeline.reference(to: lib))
                        pipelines[sourceStr] = list
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                // SwiftUI.Image(systemName: "plus.circle.fill")
                Text("Add pipeline")
            }
            .font(.regular(10))
            .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    var body: some View {
        let sourceStr = source.string
        let pipelineList = pipelines[sourceStr] ?? []
        let sourceLabel = isGlobalSource
            ? source.displayLabel
            : sourceStr.replacingOccurrences(of: HOME.string, with: "~")

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                SwiftUI.Image(systemName: sourceIcon)
                    .font(.regular(10))
                    .foregroundColor(.secondary)
                Text(sourceLabel)
                    .mono(11, weight: .bold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                addPipelineMenu
                if isDirSource || !hideInertRemoveButton {
                    Button(action: { onRemoveSource?() }) {
                        SwiftUI.Image(systemName: "xmark.circle.fill")
                            .font(.regular(11))
                            .foregroundColor(.secondary.opacity(isDirSource ? 0.6 : 0.15))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isDirSource || onRemoveSource == nil)
                    .allowsHitTesting(isDirSource)
                    .help(isDirSource ? "Remove this folder from automation" : "")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }

            if let subtitle = globalScopeSubtitle {
                Text(subtitle)
                    .regular(10)
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
            }

            if case .dropZone = source {
                Button(action: { settingsViewManager.tab = .presetZones }) {
                    HStack(spacing: 3) {
                        Text("Want different pipelines for specific drop targets?")
                        Text("Use Preset Zones")
                            .foregroundColor(.accentColor)
                    }
                    .font(.regular(10))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .help("Open the Preset Zones tab to set up per-target drop pipelines")
            }

            ForEach(Array(pipelineList.enumerated()), id: \.element.id) { index, pipeline in
                let key = "\(sourceStr):\(index)"
                PipelineFieldRow(
                    pipeline: pipeline,
                    fileType: fileType,
                    isEditing: editingKey == key,
                    onEditingChanged: { editing in
                        editingKey = editing ? key : nil
                    },
                    onPipelineChanged: { updated in
                        var list = pipelines[sourceStr] ?? []
                        guard index < list.count else { return }
                        list[index] = updated
                        pipelines[sourceStr] = list
                    },
                    onDelete: {
                        var list = pipelines[sourceStr] ?? []
                        guard index < list.count else { return }
                        list.remove(at: index)
                        pipelines[sourceStr] = list.isEmpty ? nil : list
                        if editingKey == key { editingKey = nil }
                    }
                )
            }
        }
        .padding(8)
        .card(radius: 8, fill: .primary.opacity(0.03), borderColor: .primary.opacity(0.08), borderWidth: 1)
    }
}

// MARK: - Pipeline Field Row

class RefHolder<T> {
    var value: T?
}

struct PipelineFlagSegmentedToggle: View {
    let leading: String?
    let options: (String, String)
    let trailing: String?
    let selection: Int
    let help: String
    let tint: Color
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let leading {
                Text(leading)
            }
            // Two-segment pill: the selected option sits on a raised light "pill" (like a native segmented
            // control) in the tint colour, so it's obvious at a glance which one is active; hovering an
            // inactive segment gives it a faint tint wash.
            HStack(spacing: 2) {
                ForEach(0 ..< 2, id: \.self) { idx in
                    let label = idx == 0 ? options.0 : options.1
                    let isSelected = selection == idx
                    let isHovered = hoveredIdx == idx
                    Button {
                        if !isSelected { onSelect(idx) }
                    } label: {
                        Text(label)
                            .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundColor(isSelected ? tint : (isHovered ? .primary : .secondary.opacity(0.45)))
                            .background {
                                if isSelected {
                                    Capsule().fill(Color.bg.warm)
                                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                                } else if isHovered {
                                    Capsule().fill(tint.opacity(0.18))
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { hoveredIdx = idx }
                        else if hoveredIdx == idx { hoveredIdx = nil }
                    }
                }
            }
            .padding(2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
            if let trailing {
                Text(trailing)
            }
        }
        .font(.regular(9))
        // Connective words (Pass … file / … floating result) stay legible so the control reads as a
        // sentence; the unselected option is faded above so the chosen word is what stands out.
        .foregroundColor(.primary.opacity(0.85))
        .padding(.leading, leading == nil ? 2 : 7)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.5))
        .help(help)
        .animation(.easeOut(duration: 0.12), value: selection)
        .animation(.easeOut(duration: 0.12), value: hoveredIdx)
    }

    @State private var hoveredIdx: Int? = nil

}

struct PipelineFieldRow: View {
    let pipeline: Pipeline
    let fileType: ClopFileType
    let isEditing: Bool
    var onEditingChanged: (Bool) -> Void
    var onPipelineChanged: (Pipeline) -> Void
    var onDelete: () -> Void

    var nameChip: some View {
        InlineNameField(name: $pipelineName, placeholder: "name", size: 11, weight: .regular) {
            syncToLibrary()
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder var editingSuggestions: some View {
        if isEditing {
            PipelineEditingSuggestions(prefix: currentPrefix, fileType: fileType, coordinator: coordinator)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                // Top bar: name + missing badge + spacer + pass picker + hide picker + divider + trash
                HStack(spacing: 6) {
                    nameChip

                    if pipeline.isLibraryReference, !pipeline.resolves {
                        Text("Missing")
                            .font(.regular(9))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.75)))
                            .help("The saved pipeline this refers to was deleted. Remove this entry or re-create the pipeline in the Pipelines tab.")
                    }

                    Spacer()

                    // Busy controls fade back to translucent unless the row is hovered or being edited,
                    // so only the name stays prominent at rest.
                    HStack(spacing: 6) {
                        trailingFlags
                    }
                    .opacity((hovering || isEditing) ? 1 : 0.35)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(PipelineTheme.topBarBackground)

                Divider()
                    .opacity(0.5)

                // Code editor: full width, slightly darker than top bar
                PipelineTextView(
                    text: $text,
                    fileType: fileType,
                    placeholder: "Type an action: optimise, crop, copy...",
                    onEditingChanged: onEditingChanged,
                    onPrefixChanged: { currentPrefix = $0 },
                    coordinatorRef: { coordHolder.value = $0 }
                )
                .frame(height: max(isEditing ? 36 : 22, CGFloat(1 + text.count / 80) * 18))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(PipelineTheme.editorBackground)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .card(radius: 10, fill: .clear, borderColor: .primary.opacity(isEditing ? 0.25 : 0.12), borderWidth: 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            editingSuggestions
        }
        .onAppear {
            let r = resolved
            text = r.rawText ?? r.steps.map(\.displayString).joined(separator: " -> ")
            pipelineName = r.name ?? ""
        }
        .onChange(of: text) { newText in
            var updated = pipeline
            if pipeline.isLibraryReference, let libID = pipeline.libraryID,
               let idx = savedPipelines.firstIndex(where: { $0.id == libID })
            {
                // Update the library entry directly
                savedPipelines[idx].updateFromText(newText)
            } else {
                updated.updateFromText(newText)
            }
            onPipelineChanged(updated)
        }
    }

    /// The trailing cluster of busy controls (pass/hide toggles + trash). Extracted so the whole group
    /// can be faded back to translucent at rest and brought to full opacity on hover.
    @ViewBuilder var trailingFlags: some View {
        PipelineFlagSegmentedToggle(
            leading: "Pass",
            options: ("optimised", "original"),
            trailing: "file",
            selection: resolved.skipOptimisation ? 1 : 0,
            help: PipelineFlagCopy.skipOptimisation,
            tint: .orange
        ) { idx in
            var updated = pipeline
            updated.skipOptimisation = (idx == 1)
            if pipeline.isLibraryReference, let libID = pipeline.libraryID,
               let idx2 = savedPipelines.firstIndex(where: { $0.id == libID })
            {
                savedPipelines[idx2].skipOptimisation = (idx == 1)
            }
            onPipelineChanged(updated)
        }

        PipelineFlagSegmentedToggle(
            leading: nil,
            options: ("Show", "Hide"),
            trailing: "floating result",
            selection: resolved.hideResult ? 1 : 0,
            help: PipelineFlagCopy.hideResult,
            tint: .red
        ) { idx in
            var updated = pipeline
            updated.hideResult = (idx == 1)
            if pipeline.isLibraryReference, let libID = pipeline.libraryID,
               let idx2 = savedPipelines.firstIndex(where: { $0.id == libID })
            {
                savedPipelines[idx2].hideResult = (idx == 1)
            }
            onPipelineChanged(updated)
        }

        Divider().frame(height: 12)

        // Trash trailing-right
        Button(action: onDelete) {
            SwiftUI.Image(systemName: "xmark.circle.fill")
                .font(.regular(10))
                .foregroundColor(.red.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help("Remove this pipeline")
    }

    /// When the name field is submitted: if name is non-empty, save/update in library.
    /// If name is cleared, remove from library and make inline.
    func syncToLibrary() {
        let trimmedName = pipelineName.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            // Remove from library, make inline
            if let libID = pipeline.libraryID {
                savedPipelines.removeAll { $0.id == libID }
            }
            var inlined = resolved
            inlined.libraryID = nil
            inlined.name = nil
            inlined.id = pipeline.id
            onPipelineChanged(inlined)
            return
        }

        if let libID = pipeline.libraryID,
           let idx = savedPipelines.firstIndex(where: { $0.id == libID })
        {
            // Update existing library entry name
            savedPipelines[idx].name = trimmedName
        } else if let idx = savedPipelines.firstIndex(where: { $0.name == trimmedName && $0.fileType == fileType }) {
            // Replace existing pipeline with same name and type
            savedPipelines[idx].updateFromText(text)
            savedPipelines[idx].skipOptimisation = pipeline.skipOptimisation
            onPipelineChanged(Pipeline.reference(to: savedPipelines[idx]))
        } else {
            // Save new to library
            var libPipeline = pipeline
            libPipeline.name = trimmedName
            libPipeline.fileType = fileType
            libPipeline.libraryID = nil
            savedPipelines.append(libPipeline)
            onPipelineChanged(Pipeline.reference(to: libPipeline))
        }
    }

    @State private var text = ""
    @State private var currentPrefix = ""
    @State private var coordHolder = RefHolder<PipelineTextView.Coordinator>()
    @State private var pipelineName = ""
    @State private var hovering = false

    @Default(.savedPipelines) private var savedPipelines

    private var coordinator: PipelineTextView.Coordinator? {
        coordHolder.value
    }
    private var resolved: Pipeline {
        pipeline.resolved
    }

}

// MARK: - Pipeline Type Section

struct PipelineTypeSectionView: View {
    let fileType: ClopFileType

    @Binding var pipelines: [String: [Pipeline]]

    @Default(.enableDragAndDrop) var enableDragAndDrop
    @Default(.enableClipboardOptimiser) var enableClipboardOptimiser
    @Default(.optimiseImagePathClipboard) var optimiseImagePathClipboard
    @Default(.optimiseVideoClipboard) var optimiseVideoClipboard

    @ObservedObject var svm = settingsViewManager

    @State var addedFolders: Set<String> = []
    @State var editingKey: String? = nil
    @State var highlightedFolder: String?

    var activeSources: [OptimisationSource] {
        var sources: [OptimisationSource] = []

        let hasClipboard: Bool = switch fileType {
        case .image: enableClipboardOptimiser || optimiseImagePathClipboard
        case .video: optimiseVideoClipboard
        case .audio: false
        case .pdf: false
        }
        if hasClipboard { sources.append(.clipboard) }
        if enableDragAndDrop { sources.append(.dropZone) }

        // Add folders that already have pipelines configured
        let configuredFolders = Set(pipelines.keys.filter { $0 != "clipboard" && $0 != "dropZone" })
        let watchedFolders = Set(Defaults[fileType.dirsKey])
        let allFolders = configuredFolders.union(addedFolders).intersection(watchedFolders)

        for folder in allFolders.sorted() {
            if let optSource = folder.optSource {
                sources.append(optSource)
            }
        }

        return sources
    }

    var availableFolders: [String] {
        let configured = Set(pipelines.keys.filter { $0 != "clipboard" && $0 != "dropZone" })
        let added = configured.union(addedFolders)
        return Defaults[fileType.dirsKey].filter { !added.contains($0) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 4) {
                    SwiftUI.Image(systemName: fileType.symbolName)
                        .frame(width: 14)
                    Text(fileType == .pdf ? "PDF" : fileType.description.capitalized)
                        .fontWeight(.medium)
                }
                .foregroundColor(fileType.color)

                Spacer()

                if !availableFolders.isEmpty {
                    Menu {
                        ForEach(availableFolders, id: \.self) { folder in
                            Button(folder.replacingOccurrences(of: HOME.string, with: "~")) {
                                addedFolders.insert(folder)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            SwiftUI.Image(systemName: "folder.badge.plus")
                            Text("Add folder")
                        }
                        .font(.regular(11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }

            ForEach(activeSources, id: \.self) { source in
                PipelineEditorRow(
                    source: source,
                    fileType: fileType,
                    pipelines: $pipelines,
                    editingKey: $editingKey,
                    onRemoveSource: {
                        guard case let .dir(folder) = source else { return }
                        pipelines[folder] = nil
                        addedFolders.remove(folder)
                        if highlightedFolder == folder { highlightedFolder = nil }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(fileType.color, lineWidth: 2)
                        .opacity(highlightedFolder == source.string ? 1 : 0)
                        .animation(.easeOut(duration: 0.3), value: highlightedFolder)
                )
            }

            if activeSources.isEmpty {
                Text("No automations yet. Turn on Clipboard or Drop zone above, or watch a folder, to run pipelines automatically.")
                    .regular(11)
                    .foregroundColor(.secondary)
                    .padding(.leading, 146)
                    .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onAppear { handleHighlightFolder() }
        .onChange(of: svm.highlightFolder) { _ in handleHighlightFolder() }
    }

    func handleHighlightFolder() {
        guard let req = svm.highlightFolder, req.fileType == fileType else { return }
        let folder = req.folder
        addedFolders.insert(folder)
        highlightedFolder = folder
        svm.highlightFolder = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { highlightedFolder = nil }
        }
    }

}

// MARK: - Automation Settings View

// MARK: - Saved Pipeline Row (Library)

/// Single-line AppKit text field. A SwiftUI `TextField` constrained to a compact fixed width wraps its
/// text onto a second line (growing tall) when focused; a native `NSTextField` in single-line mode
/// scrolls horizontally instead, so a small fixed-width name editor stays exactly one line.
struct SingleLineNameField: NSViewRepresentable {
    class Coordinator: NSObject, NSTextFieldDelegate {
        init(_ parent: SingleLineNameField) {
            self.parent = parent
        }

        var parent: SingleLineNameField
        var didFocus = false

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish { parent.onCommit() }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish { parent.onCancel() }
                return true
            }
            return false
        }

        /// Clicking away commits, matching a tap-to-rename field's expectation.
        func controlTextDidEndEditing(_ obj: Notification) {
            finish { parent.onCommit() }
        }

        /// Ensures commit/cancel fire exactly once (Enter, Esc and focus-loss can all arrive).
        private var finished = false

        private func finish(_ action: () -> Void) {
            guard !finished else { return }
            finished = true
            action()
        }
    }

    @Binding var text: String

    var placeholder: String
    var nsFont: NSFont
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = nsFont
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.allowsEditingTextAttributes = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = nsFont
        field.placeholderString = placeholder
        // Focus once, when the editor first appears.
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

}

/// Reusable inline-editable name label. Shows text, tap to edit in place.
struct InlineNameField: View {
    @Binding var name: String

    var placeholder = "name"
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    /// When true the editor fills the available width (used for the description, which sits on its own
    /// full-width line); otherwise it stays a compact fixed width so it can't push sibling controls.
    var fillWidth = false
    /// When true the resting (non-editing) label is rendered faintly with no background/border (used
    /// for the description); it only shows a faint chip on hover. The name keeps the default chip look.
    var subtle = false
    var onCommit: (() -> Void)?

    var body: some View {
        if isEditing {
            editor
        } else {
            Text(name.isEmpty ? placeholder : name)
                .font(swiftUIFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(restingTextColor)
                // Keep the same horizontal inset for name and description so their text lines up exactly.
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(subtle ? (isHovered ? 0.1 : 0.06) : (isHovered ? 0.12 : 0.06)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(subtle ? (isHovered ? 0.15 : 0.1) : (isHovered ? 0.25 : 0.15)), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { isEditing = true }
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help("Click to rename")
        }
    }

    @State private var isEditing = false
    @State private var isHovered = false

    private var restingTextColor: Color {
        if subtle {
            return .secondary.opacity(name.isEmpty ? 0.4 : 0.6)
        }
        return name.isEmpty ? .secondary.opacity(0.5) : .primary
    }

    private var swiftUIFont: Font {
        .system(size: size, weight: weight)
    }

    private var nsFont: NSFont {
        let nsWeight: NSFont.Weight = switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        case .light: .light
        default: .regular
        }
        return .systemFont(ofSize: size, weight: nsWeight)
    }

    @ViewBuilder private var editor: some View {
        let field = SingleLineNameField(
            text: $name,
            placeholder: placeholder,
            nsFont: nsFont,
            onCommit: {
                isEditing = false
                onCommit?()
            },
            onCancel: { isEditing = false }
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        )

        if fillWidth {
            field.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Compact fixed width so a long name can't push the field past its HStack; the native
            // field keeps it single-line and scrolls horizontally instead of wrapping.
            field.frame(width: 80)
        }
    }

}

/// One place a library pipeline is currently assigned to run. Drives the assignment pills.
private struct PipelineAssignment: Identifiable, Hashable {
    enum Target: Hashable {
        case clipboard
        case dropZone
        case folder(String)
        case presetZone(String)
    }

    let target: Target
    var fileTypes: Set<ClopFileType> = []

    var id: Target {
        target
    }
}

struct SavedPipelineRow: View {
    let pipeline: Pipeline
    var onUpdate: (Pipeline) -> Void
    var onDelete: () -> Void
    var startEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Single-row header: name + badge + spacer + file type + add to + divider + pass + hide + divider + [confirm/cancel] + trash
            // Header row + description stacked vertically so the description gets its own
            // full-width line below the header, instead of widening the name column and
            // cramming the controls (file type / pass / hide / trash) on the right.
            HStack(alignment: .center, spacing: 6) {
                IconPickerView(icon: $editIcon)
                    .buttonStyle(.plain)
                    // Larger now that it sits centred against the two-line name + description block, and a
                    // fixed square tile so the name column starts at the same x in every row regardless of
                    // symbol. The faint fill/border match the name and description chips for a cohesive look.
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                    .onChange(of: editIcon) { newIcon in
                        guard newIcon != (pipeline.icon ?? "wand.and.sparkles") else { return }
                        var updated = pipeline
                        updated.icon = newIcon
                        onUpdate(updated)
                    }

                // Name row and the description/pills line share one column to the right of the icon, so
                // the description always lines up under the name no matter how wide the chosen icon is.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        InlineNameField(name: $editName, size: 10, weight: .medium) {
                            var updated = pipeline
                            updated.name = editName
                            onUpdate(updated)
                        }

                        // Everything except the name, description, icon and trash fades fully out at rest and
                        // returns on hover/edit. The trash stays visible so deleting never needs a hover hunt.
                        HStack(spacing: 6) {
                            Group {
                                if pipeline.isBuiltin {
                                    Text("Built-in")
                                        .font(.regular(9))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(Color.secondary.opacity(0.15))
                                        )
                                        .help("Shipped with Clop. Delete to hide it; it returns only with a future built-in update.")
                                }

                                Spacer(minLength: 0)

                                PipelineFlagSegmentedToggle(
                                    leading: "Pass",
                                    options: ("optimised", "original"),
                                    trailing: "file",
                                    selection: pipeline.skipOptimisation ? 1 : 0,
                                    help: PipelineFlagCopy.skipOptimisation,
                                    tint: .orange
                                ) { idx in
                                    var updated = pipeline
                                    updated.skipOptimisation = (idx == 1)
                                    onUpdate(updated)
                                }

                                PipelineFlagSegmentedToggle(
                                    leading: nil,
                                    options: ("Show", "Hide"),
                                    trailing: "floating result",
                                    selection: pipeline.hideResult ? 1 : 0,
                                    help: PipelineFlagCopy.hideResult,
                                    tint: .red
                                ) { idx in
                                    var updated = pipeline
                                    updated.hideResult = (idx == 1)
                                    onUpdate(updated)
                                }

                                Divider().frame(height: 12)

                                if isEditingLib {
                                    // Confirm + cancel with scrim
                                    HStack(spacing: 0) {
                                        Button(action: { commitLibraryEdit() }) {
                                            SwiftUI.Image(systemName: "checkmark")
                                                .font(.regular(10))
                                                .foregroundColor(.green.opacity(0.7))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                        }
                                        .buttonStyle(.plain)

                                        Button(action: { isEditingLib = false }) {
                                            SwiftUI.Image(systemName: "xmark")
                                                .font(.regular(10))
                                                .foregroundColor(.red.opacity(0.7))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                                }
                            }
                            .opacity((hovering || isEditingLib) ? 1 : 0)

                            // Trash trailing-right, always visible.
                            Button(action: onDelete) {
                                SwiftUI.Image(systemName: "trash")
                                    .font(.regular(9))
                                    .foregroundColor(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Description + assignment pills share a line below the header. The description yields
                    // width to the pills (which show where this pipeline is assigned and host "Add to…"),
                    // so a long description truncates rather than pushing the pills off-screen.
                    HStack(spacing: 8) {
                        InlineNameField(name: $editDetails, placeholder: "description", size: 9, weight: .regular, fillWidth: true, subtle: true) {
                            var updated = pipeline
                            updated.details = editDetails.isEmpty ? nil : editDetails
                            onUpdate(updated)
                        }
                        Spacer(minLength: 8)
                        // Barely visible at rest so they don't clutter the row; full opacity on row hover
                        // (or while editing), matching the header controls but fainter.
                        assignmentPills
                            .layoutPriority(1)
                            .opacity((hovering || isEditingLib) ? 1 : 0)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(PipelineTheme.topBarBackground)

            Divider()
                .opacity(0.5)

            // Code area: full-width below the top bar, slightly darker than top bar
            if isEditingLib {
                PipelineTextView(
                    text: $editText,
                    fileType: pipeline.fileType,
                    placeholder: "Pipeline steps...",
                    onEditingChanged: { isEditingSteps = $0 },
                    onPrefixChanged: { currentPrefix = $0 },
                    onSubmit: { commitLibraryEdit() },
                    onCancel: { isEditingLib = false },
                    coordinatorRef: { coordHolder.value = $0 }
                )
                .frame(height: max(36, CGFloat(1 + editText.count / 80) * 18))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(PipelineTheme.editorBackground)
                if isEditingSteps {
                    PipelineEditingSuggestions(prefix: currentPrefix, fileType: pipeline.fileType, coordinator: coordinator)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            } else {
                let readOnlyText = pipeline.rawText ?? pipeline.steps.map(\.displayString).joined(separator: " -> ")
                // Syntax-highlight the read-only preview too (same colouring the editor uses), so steps
                // and params stay readable at a glance without entering edit mode.
                Text(AttributedString(highlightPipelineText(readOnlyText, fileType: pipeline.fileType, darkMode: colorScheme == .dark)))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    // Near-opaque white/black so the steps read on a clean surface; the muted top-bar tint
                    // and the divider keep the two bands visually separated.
                    .background(PipelineTheme.editorBackground)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editText = readOnlyText
                        editName = pipeline.name ?? ""
                        editIcon = pipeline.icon ?? "wand.and.sparkles"
                        editDetails = pipeline.details ?? ""
                        isEditingLib = true
                    }
                    .onHover { hovering in
                        isHoveredCode = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help("Click to edit")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .card(radius: 10, fill: .clear, borderColor: .primary.opacity(isEditingLib ? 0.2 : 0.08), borderWidth: 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onAppear {
            editName = pipeline.name ?? ""
            editIcon = pipeline.icon ?? "wand.and.sparkles"
            editDetails = pipeline.details ?? ""
            if startEditing, !isEditingLib {
                editText = pipeline.rawText ?? pipeline.steps.map(\.displayString).joined(separator: " -> ")
                isEditingLib = true
            }
        }
    }

    // MARK: Assignment pills

    /// Pills showing every source this pipeline is assigned to, plus the trailing "Add to…" entry point.
    var assignmentPills: some View {
        HStack(spacing: 4) {
            ForEach(assignments) { assignment in
                Menu {
                    Button("Go to") { goTo(assignment) }
                    Button("Remove", role: .destructive) { remove(assignment) }
                } label: {
                    assignmentPillLabel(assignment)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Assigned to \(assignmentHelp(assignment)). Click to go there or remove.")
            }
            addToMenu
            moveToMenu
        }
    }

    /// The trailing "Add to…" pill: assigns this pipeline to the clipboard, drop zone or an existing
    /// watched folder. For an "any type" pipeline it offers per-type submenus (plus "All types").
    var addToMenu: some View {
        Menu {
            if let concreteType = pipeline.fileType {
                addToButtons(for: concreteType)
            } else {
                ForEach(ClopFileType.allCases, id: \.self) { type in
                    Menu(type == .pdf ? "PDF" : type.description.capitalized) {
                        addToButtons(for: type)
                    }
                }
                Divider()
                Menu("All types") {
                    Button(OptimisationSource.clipboard.displayLabel) {
                        for type in ClopFileType.allCases {
                            attach(to: .clipboard, fileType: type)
                        }
                    }
                    Button(OptimisationSource.dropZone.displayLabel) {
                        for type in ClopFileType.allCases {
                            attach(to: .dropZone, fileType: type)
                        }
                    }
                    Button("Preset zone") { addToPresetZone(fileType: nil) }
                    let allFolders = ClopFileType.allCases.flatMap { existingFolderSources(for: $0) }
                    let uniqueFolders = allFolders.reduce(into: [OptimisationSource]()) { acc, s in
                        if !acc.contains(s) { acc.append(s) }
                    }
                    if !uniqueFolders.isEmpty {
                        Divider()
                        Text("Folders").foregroundColor(.secondary).disabled(true)
                        ForEach(uniqueFolders, id: \.self) { source in
                            Button(source.displayLabel) {
                                for type in ClopFileType.allCases {
                                    attach(to: source, fileType: type)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                SwiftUI.Image(systemName: "plus").font(.system(size: 8))
                Text("Add to").font(.regular(9))
            }
            .foregroundColor(.blue.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.blue.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.blue.opacity(0.18), lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Run this pipeline automatically on the clipboard, drop zone or a watched folder")
    }

    /// The "Move to" pill sitting right after "Add to…": changes which file type this library pipeline
    /// belongs to (previously the "File type" chip up in the header row).
    var moveToMenu: some View {
        Menu {
            let currentType = pipeline.fileType
            let types: [(String, ClopFileType?)] = [
                ("Image", .image),
                ("Video", .video),
                ("Audio", .audio),
                ("PDF", .pdf),
                ("Any type", nil),
            ]
            ForEach(types, id: \.0) { label, type in
                Button {
                    var updated = pipeline
                    updated.fileType = type
                    onUpdate(updated)
                } label: {
                    HStack {
                        Text(label)
                        if currentType == type {
                            SwiftUI.Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                if let ft = pipeline.fileType {
                    SwiftUI.Image(systemName: ft.symbolName).foregroundColor(ft.color)
                } else {
                    SwiftUI.Image(systemName: "doc").foregroundColor(.secondary)
                }
                Text("Move to").font(.regular(9))
            }
            .foregroundColor(.blue.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.blue.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.blue.opacity(0.18), lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move this pipeline to another file type")
    }

    @ViewBuilder func addToButtons(for type: ClopFileType) -> some View {
        Button(OptimisationSource.clipboard.displayLabel) { attach(to: .clipboard, fileType: type) }
        Button(OptimisationSource.dropZone.displayLabel) { attach(to: .dropZone, fileType: type) }
        Button("Preset zone") { addToPresetZone(fileType: type) }
        let folders = existingFolderSources(for: type)
        if !folders.isEmpty {
            Divider()
            Text("Folders").foregroundColor(.secondary).disabled(true)
            ForEach(folders, id: \.self) { source in
                Button(source.displayLabel) { attach(to: source, fileType: type) }
            }
        }
    }

    /// The folder-only sources for a given file type (excludes clipboard and drop zone).
    func existingFolderSources(for fileType: ClopFileType) -> [OptimisationSource] {
        Defaults[fileType.dirsKey].sorted().compactMap { folder -> OptimisationSource? in
            guard FileManager.default.fileExists(atPath: folder) else { return nil }
            return folder.optSource
        }
    }

    /// Attach this library pipeline as a reference under `fileType`'s automation
    /// dictionary, keyed by the source's persisted string. No-op if a reference
    /// to the same library id already exists for that source.
    func attach(to source: OptimisationSource, fileType: ClopFileType) {
        var dict = Defaults[fileType.pipelineKey]
        var list = dict[source.string] ?? []
        guard !list.contains(where: { $0.libraryID == pipeline.id }) else { return }
        list.append(Pipeline.reference(to: pipeline))
        dict[source.string] = list
        Defaults[fileType.pipelineKey] = dict
    }

    /// Add this library pipeline as a new preset zone scoped to `fileType` (nil = any type). No-op if a
    /// preset zone of the same type already references it, mirroring `attach`'s idempotency.
    func addToPresetZone(fileType: ClopFileType?) {
        guard !presetZones.contains(where: { $0.type == fileType && $0.pipeline.libraryID == pipeline.id }) else { return }
        assignPresetZone(library: pipeline, type: fileType)
    }

    @State private var isEditingLib = false
    @State private var isHoveredCode = false
    @State private var hovering = false
    @State private var editText = ""
    @State private var editName = ""
    @State private var editIcon = "wand.and.sparkles"
    @State private var editDetails = ""
    @State private var coordHolder = RefHolder<PipelineTextView.Coordinator>()
    @State private var currentPrefix = ""
    @State private var isEditingSteps = false
    @Environment(\.colorScheme) private var colorScheme

    // Observed so the assignment pills refresh the moment an assignment is added or removed.
    @Default(.pipelinesToRunOnImage) private var imagePipelines
    @Default(.pipelinesToRunOnVideo) private var videoPipelines
    @Default(.pipelinesToRunOnPdf) private var pdfPipelines
    @Default(.pipelinesToRunOnAudio) private var audioPipelines
    @Default(.presetZones) private var presetZones

    private var coordinator: PipelineTextView.Coordinator? {
        coordHolder.value
    }

    /// Every place this library pipeline is currently assigned (clipboard / drop zone / folders across
    /// all file types, plus preset zones referencing it). Reads the @Default-observed dictionaries so
    /// the pills update live as assignments are added or removed.
    private var assignments: [PipelineAssignment] {
        let pid = pipeline.id
        var sourceTypes: [PipelineAssignment.Target: Set<ClopFileType>] = [:]
        for ft in ClopFileType.allCases {
            for (sourceKey, list) in dict(for: ft) where list.contains(where: { $0.libraryID == pid }) {
                let target: PipelineAssignment.Target = if sourceKey == OptimisationSource.clipboard.string {
                    .clipboard
                } else if sourceKey == OptimisationSource.dropZone.string {
                    .dropZone
                } else {
                    .folder(sourceKey)
                }
                sourceTypes[target, default: []].insert(ft)
            }
        }

        var result: [PipelineAssignment] = []
        if let t = sourceTypes[.clipboard] { result.append(PipelineAssignment(target: .clipboard, fileTypes: t)) }
        if let t = sourceTypes[.dropZone] { result.append(PipelineAssignment(target: .dropZone, fileTypes: t)) }
        let folderPaths = sourceTypes.keys.compactMap { key -> String? in
            if case let .folder(path) = key { return path } else { return nil }
        }.sorted()
        for path in folderPaths {
            result.append(PipelineAssignment(target: .folder(path), fileTypes: sourceTypes[.folder(path)] ?? []))
        }
        for zone in presetZones where zone.pipeline.libraryID == pid {
            result.append(PipelineAssignment(target: .presetZone(zone.id), fileTypes: zone.type.map { [$0] } ?? []))
        }
        return result
    }

    private func assignmentPillLabel(_ a: PipelineAssignment) -> some View {
        let icon: String
        let label: String
        switch a.target {
        case .clipboard:
            icon = "doc.on.clipboard"
            label = "Clipboard"
        case .dropZone:
            icon = "square.dashed"
            label = "Drop zone"
        case let .folder(path):
            icon = "folder"
            label = OptimisationSource.dir(path).displayLabel
        case .presetZone:
            // A preset zone's name/icon always mirror this pipeline's, so a generic label reads clearer.
            icon = "square.grid.2x2"
            label = "Preset zone"
        }
        return HStack(spacing: 3) {
            SwiftUI.Image(systemName: icon).font(.system(size: 8))
            Text(label).font(.regular(9)).lineLimit(1)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// Save the in-progress library edits (name/icon/description/steps) and leave edit mode. Shared by
    /// the confirm button and by pressing Enter in the steps editor.
    private func commitLibraryEdit() {
        var updated = pipeline
        updated.name = editName.isEmpty ? pipeline.name : editName
        updated.icon = editIcon.isEmpty ? nil : editIcon
        updated.details = editDetails.isEmpty ? nil : editDetails
        updated.updateFromText(editText)
        onUpdate(updated)
        isEditingLib = false
    }

    private func assignmentHelp(_ a: PipelineAssignment) -> String {
        switch a.target {
        case .clipboard: "the clipboard"
        case .dropZone: "the drop zone"
        case let .folder(path): OptimisationSource.dir(path).displayLabel
        case .presetZone: "a preset zone"
        }
    }

    private func dict(for fileType: ClopFileType) -> [String: [Pipeline]] {
        switch fileType {
        case .image: imagePipelines
        case .video: videoPipelines
        case .pdf: pdfPipelines
        case .audio: audioPipelines
        }
    }

    /// Open the settings pane for an assignment so the user can see/manage it in context.
    private func goTo(_ a: PipelineAssignment) {
        let svm = settingsViewManager
        switch a.target {
        case .clipboard:
            svm.tab = .clipboard
            svm.scrollToAutomation = true
        case .dropZone:
            svm.tab = .dropzone
            svm.scrollToAutomation = true
        case let .folder(path):
            let ft = orderedFileType(in: a.fileTypes) ?? pipeline.fileType ?? .image
            svm.tab = .automation
            svm.scrollToFileType = ft
            svm.highlightFolder = HighlightedFolderRequest(fileType: ft, folder: path)
        case let .presetZone(zoneID):
            svm.tab = .presetZones
            svm.editingPresetZoneID = zoneID
        }
    }

    private func orderedFileType(in set: Set<ClopFileType>) -> ClopFileType? {
        [.image, .video, .audio, .pdf].first(where: set.contains)
    }

    /// Remove an assignment ("delete the link"): for clipboard / drop zone / folder, strip references to
    /// this pipeline from the relevant dictionaries; for a preset zone, remove the zone itself.
    private func remove(_ a: PipelineAssignment) {
        let pid = pipeline.id
        switch a.target {
        case .clipboard:
            detach(key: OptimisationSource.clipboard.string, from: a.fileTypes, pid: pid)
        case .dropZone:
            detach(key: OptimisationSource.dropZone.string, from: a.fileTypes, pid: pid)
        case let .folder(path):
            detach(key: path, from: a.fileTypes, pid: pid)
        case let .presetZone(zoneID):
            presetZones.removeAll { $0.id == zoneID }
        }
    }

    private func detach(key: String, from fileTypes: Set<ClopFileType>, pid: String) {
        for ft in fileTypes {
            var d = Defaults[ft.pipelineKey]
            d[key]?.removeAll { $0.libraryID == pid }
            if d[key]?.isEmpty ?? false { d[key] = nil }
            Defaults[ft.pipelineKey] = d
        }
    }

}

// MARK: - Automation Settings View

struct PipelinesSettingsView: View {
    @Default(.savedPipelines) var savedPipelines

    @ObservedObject var svm = settingsViewManager

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section(header: SectionHeader(
                    title: "Saved Pipelines",
                    subtitle: "Reusable pipelines available in automation, preset zones and right-click menus"
                )) {
                    ForEach(Self.sections, id: \.0) { label, fileType in
                        let pipelines = savedPipelines.filter { $0.fileType == fileType }
                        let headerColor: Color = fileType?.color ?? .secondary
                        let buttonLabel = fileType != nil ? "Create new \(label.lowercased()) pipeline" : "Create new pipeline"

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(label)
                                    .round(15, weight: .semibold)
                                    .foregroundColor(headerColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())

                                Button {
                                    let new = Pipeline(steps: [], name: "New pipeline", fileType: fileType)
                                    savedPipelines.append(new)
                                    newlyCreatedID = new.id
                                } label: {
                                    HStack(spacing: 4) {
                                        SwiftUI.Image(systemName: "plus.circle.fill")
                                        Text(buttonLabel)
                                    }
                                    .font(.regular(11))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                            }
                            .padding(.top, 6)

                            if pipelines.isEmpty {
                                Text("No pipelines yet")
                                    .round(11, weight: .regular)
                                    .foregroundColor(.secondary)
                                    .padding(.bottom, 4)
                            } else {
                                ForEach(pipelines) { pipeline in
                                    SavedPipelineRow(
                                        pipeline: pipeline,
                                        onUpdate: { updated in
                                            if let idx = savedPipelines.firstIndex(where: { $0.id == pipeline.id }) {
                                                savedPipelines[idx] = updated
                                            }
                                        },
                                        onDelete: {
                                            savedPipelines.removeAll { $0.id == pipeline.id }
                                        },
                                        startEditing: pipeline.id == newlyCreatedID
                                    )
                                    // .id + flashing border let a floating result's "Pipeline: …" menu jump
                                    // straight here and point out the exact pipeline that ran on it.
                                    .id(pipeline.id)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(headerColor, lineWidth: 2)
                                            .opacity(highlightedPipelineID == pipeline.id ? 1 : 0)
                                            .animation(.easeOut(duration: 0.3), value: highlightedPipelineID)
                                    )
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }
                }
            }
            .padding(4)
            .onAppear { handleHighlightPipeline(proxy) }
            .onChange(of: svm.highlightPipelineID) { _ in handleHighlightPipeline(proxy) }
        }
    }

    /// Scroll to the pipeline requested by `svm.highlightPipelineID` and flash its border for a few
    /// seconds, then clear it. Triggered both on first appearance (window just opened on this tab) and on
    /// change (tab already visible).
    func handleHighlightPipeline(_ proxy: ScrollViewProxy) {
        guard let id = svm.highlightPipelineID else { return }
        svm.highlightPipelineID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            highlightedPipelineID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { if highlightedPipelineID == id { highlightedPipelineID = nil } }
            }
        }
    }

    private static let sections: [(String, ClopFileType?)] = [
        ("Image", .image),
        ("Video", .video),
        ("Audio", .audio),
        ("PDF", .pdf),
        ("Any type", nil),
    ]

    @State private var newlyCreatedID: String?
    @State private var highlightedPipelineID: String?

}

struct AutomationSettingsView: View {
    @Default(.pipelinesToRunOnImage) var imagePipelines
    @Default(.pipelinesToRunOnVideo) var videoPipelines
    @Default(.pipelinesToRunOnPdf) var pdfPipelines
    @Default(.pipelinesToRunOnAudio) var audioPipelines

    @ObservedObject var svm = settingsViewManager

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section(header: SectionHeader(
                    title: "Automation",
                    subtitle: "Automatically run actions on files after (or before) optimisation: convert, crop, copy, rename and more\nType an action name and press Tab to fill in, Enter to finish"
                )) {
                    PipelineTypeSectionView(fileType: .image, pipelines: $imagePipelines)
                        .id(ClopFileType.image)
                    Divider()
                    PipelineTypeSectionView(fileType: .video, pipelines: $videoPipelines)
                        .id(ClopFileType.video)
                    Divider()
                    PipelineTypeSectionView(fileType: .audio, pipelines: $audioPipelines)
                        .id(ClopFileType.audio)
                    Divider()
                    PipelineTypeSectionView(fileType: .pdf, pipelines: $pdfPipelines)
                        .id(ClopFileType.pdf)
                }
            }
            .padding(4)
            .onAppear {
                guard let fileType = svm.scrollToFileType else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(fileType, anchor: .top)
                    }
                    svm.scrollToFileType = nil
                }
            }
            .onChange(of: svm.scrollToFileType) { fileType in
                guard let fileType else { return }
                withAnimation {
                    proxy.scrollTo(fileType, anchor: .top)
                }
                svm.scrollToFileType = nil
            }
        }
    }
}

struct AutomationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AutomationSettingsView()
            .frame(minWidth: 850, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .formStyle(.grouped)
    }
}
