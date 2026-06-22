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
                            .padding(.vertical, 2)
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
        InlineNameField(name: $pipelineName, placeholder: "name", font: .system(size: 11)) {
            syncToLibrary()
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder var editingSuggestions: some View {
        if isEditing {
            let suggestions = pipelineSuggestions(prefix: currentPrefix, fileType: fileType)
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
                .background(Color.white.opacity(0.08))

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
                .background(Color.black.opacity(0.06))
            }
            .card(radius: 6, fill: .clear, borderColor: .primary.opacity(isEditing ? 0.25 : 0.12), borderWidth: 1)
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

/// Reusable inline-editable name label. Shows text, tap to edit in place.
struct InlineNameField: View {
    @Binding var name: String

    var placeholder = "name"
    var font: Font = .system(size: 12, weight: .medium)
    var onCommit: (() -> Void)?

    var body: some View {
        if isEditing {
            TextField("", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(font)
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
                .focused($focused)
                .onSubmit {
                    isEditing = false
                    onCommit?()
                }
                .onExitCommand {
                    isEditing = false
                }
                .onAppear { focused = true }
                .frame(width: 90)
        } else {
            Text(name.isEmpty ? placeholder : name)
                .font(font)
                .foregroundColor(name.isEmpty ? .secondary.opacity(0.5) : .primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.12 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovered ? 0.25 : 0.15), lineWidth: 0.5)
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
    @FocusState private var focused: Bool

}

struct SavedPipelineRow: View {
    let pipeline: Pipeline
    var onUpdate: (Pipeline) -> Void
    var onDelete: () -> Void
    var startEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Single-row header: name + badge + spacer + file type + add to + divider + pass + hide + divider + [confirm/cancel] + trash
            HStack(spacing: 6) {
                IconPickerView(icon: $editIcon)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .onChange(of: editIcon) { newIcon in
                        guard newIcon != (pipeline.icon ?? "wand.and.sparkles") else { return }
                        var updated = pipeline
                        updated.icon = newIcon
                        onUpdate(updated)
                    }

                VStack(alignment: .leading, spacing: 0) {
                    InlineNameField(name: $editName, font: .system(size: 10, weight: .medium)) {
                        var updated = pipeline
                        updated.name = editName
                        onUpdate(updated)
                    }
                    InlineNameField(name: $editDetails, placeholder: "description", font: .system(size: 9)) {
                        var updated = pipeline
                        updated.details = editDetails.isEmpty ? nil : editDetails
                        onUpdate(updated)
                    }
                    .foregroundColor(.secondary)
                }

                // Everything except the name + description fades back to translucent at rest, opaque on hover/edit.
                HStack(spacing: 6) {
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

                    // Blue config cluster: File type + Add to… (hidden while editing)
                    if !isEditingLib {
                        HStack(spacing: 6) {
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
                                        SwiftUI.Image(systemName: ft.symbolName)
                                            .foregroundColor(ft.color)
                                    } else {
                                        SwiftUI.Image(systemName: "doc")
                                            .foregroundColor(.secondary)
                                    }
                                    Text("File type")
                                        .foregroundColor(.blue.opacity(0.7))
                                }
                                .font(.regular(10))
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Move to another file type")

                            Group {
                                if let concreteType = pipeline.fileType {
                                    Menu {
                                        Button(OptimisationSource.clipboard.displayLabel) {
                                            attach(to: .clipboard, fileType: concreteType)
                                        }
                                        Button(OptimisationSource.dropZone.displayLabel) {
                                            attach(to: .dropZone, fileType: concreteType)
                                        }
                                        let folders = existingFolderSources(for: concreteType)
                                        if !folders.isEmpty {
                                            Divider()
                                            Text("Folders").foregroundColor(.secondary).disabled(true)
                                            ForEach(folders, id: \.self) { source in
                                                Button(source.displayLabel) {
                                                    attach(to: source, fileType: concreteType)
                                                }
                                            }
                                        }
                                    } label: { addToLabel }
                                        .menuStyle(.button)
                                        .buttonStyle(.plain)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                        .help("Run this pipeline automatically on a source")
                                } else {
                                    Menu {
                                        ForEach(ClopFileType.allCases, id: \.self) { type in
                                            Menu(type == .pdf ? "PDF" : type.description.capitalized) {
                                                Button(OptimisationSource.clipboard.displayLabel) {
                                                    attach(to: .clipboard, fileType: type)
                                                }
                                                Button(OptimisationSource.dropZone.displayLabel) {
                                                    attach(to: .dropZone, fileType: type)
                                                }
                                                let folders = existingFolderSources(for: type)
                                                if !folders.isEmpty {
                                                    Divider()
                                                    Text("Folders").foregroundColor(.secondary).disabled(true)
                                                    ForEach(folders, id: \.self) { source in
                                                        Button(source.displayLabel) {
                                                            attach(to: source, fileType: type)
                                                        }
                                                    }
                                                }
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
                                    } label: { addToLabel }
                                        .menuStyle(.button)
                                        .buttonStyle(.plain)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                        .help("Run this pipeline automatically on a source, for one or all file types")
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.blue.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    } // end !isEditingLib

                    Divider().frame(height: 12)

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
                            Button(action: {
                                var updated = pipeline
                                updated.name = editName.isEmpty ? pipeline.name : editName
                                updated.icon = editIcon.isEmpty ? nil : editIcon
                                updated.details = editDetails.isEmpty ? nil : editDetails
                                updated.updateFromText(editText)
                                onUpdate(updated)
                                isEditingLib = false
                            }) {
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

                    // Trash trailing-right
                    Button(action: onDelete) {
                        SwiftUI.Image(systemName: "trash")
                            .font(.regular(9))
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .opacity((hovering || isEditingLib) ? 1 : 0.35)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08))

            Divider()
                .opacity(0.5)

            // Code area: full-width below the top bar, slightly darker than top bar
            if isEditingLib {
                PipelineTextView(
                    text: $editText,
                    fileType: pipeline.fileType,
                    placeholder: "Pipeline steps...",
                    coordinatorRef: { coordHolder.value = $0 }
                )
                .frame(height: max(36, CGFloat(1 + editText.count / 80) * 18))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.bg.warm.opacity(0.9))
            } else {
                let readOnlyText = pipeline.rawText ?? pipeline.steps.map(\.displayString).joined(separator: " -> ")
                // Syntax-highlight the read-only preview too (same colouring the editor uses), so steps
                // and params stay readable at a glance without entering edit mode.
                Text(AttributedString(highlightPipelineText(readOnlyText, fileType: pipeline.fileType)))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    // Near-opaque white/black so the steps read on a clean surface; the muted top-bar tint
                    // and the divider keep the two bands visually separated.
                    .background(Color.bg.warm.opacity(isHoveredCode ? 0.96 : 0.9))
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
        .card(radius: 6, fill: .clear, borderColor: .primary.opacity(isEditingLib ? 0.2 : 0.08), borderWidth: 1)
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

    var addToLabel: some View {
        HStack(spacing: 3) {
            SwiftUI.Image(systemName: "bolt.badge.clock")
            Text("Add to…")
                .foregroundColor(.blue.opacity(0.7))
        }
        .font(.regular(10))
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

    @State private var isEditingLib = false
    @State private var isHoveredCode = false
    @State private var hovering = false
    @State private var editText = ""
    @State private var editName = ""
    @State private var editIcon = "wand.and.sparkles"
    @State private var editDetails = ""
    @State private var coordHolder = RefHolder<PipelineTextView.Coordinator>()

}

// MARK: - Automation Settings View

struct PipelinesSettingsView: View {
    @Default(.savedPipelines) var savedPipelines

    var body: some View {
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
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }
            }
        }
        .padding(4)
    }

    private static let sections: [(String, ClopFileType?)] = [
        ("Image", .image),
        ("Video", .video),
        ("Audio", .audio),
        ("PDF", .pdf),
        ("Any type", nil),
    ]

    @State private var newlyCreatedID: String?

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
