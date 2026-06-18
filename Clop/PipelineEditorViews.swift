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
        let sourceLabel = sourceStr.replacingOccurrences(of: HOME.string, with: "~")

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
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }

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

struct PipelineFieldRow: View {
    let pipeline: Pipeline
    let fileType: ClopFileType
    let isEditing: Bool
    var onEditingChanged: (Bool) -> Void
    var onPipelineChanged: (Pipeline) -> Void
    var onDelete: () -> Void

    var nameChip: some View {
        HStack(spacing: 3) {
            InlineNameField(name: $pipelineName, placeholder: "name", font: .system(size: 9)) {
                syncToLibrary()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.bg.warm)
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .offset(x: 4, y: -12)
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
            ZStack(alignment: .topLeading) {
                HStack(spacing: 6) {
                    PipelineTextView(
                        text: $text,
                        fileType: fileType,
                        placeholder: "Type an action: optimise, crop, copy...",
                        onEditingChanged: onEditingChanged,
                        onPrefixChanged: { currentPrefix = $0 },
                        coordinatorRef: { coordHolder.value = $0 }
                    )
                    .frame(height: max(isEditing ? 36 : 22, CGFloat(1 + text.count / 80) * 18))

                    boltButton

                    eyeButton

                    Button(action: onDelete) {
                        SwiftUI.Image(systemName: "xmark.circle.fill")
                            .font(.regular(11))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this pipeline")
                }
                nameChip
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .card(radius: 6, fill: .primary.opacity(pipeline.isLibraryReference ? 0.02 : 0.04), borderColor: .primary.opacity(isEditing ? 0.25 : 0.12), borderWidth: 1)
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

    var boltButton: some View {
        Button(action: {
            var updated = pipeline
            updated.skipOptimisation.toggle()
            if pipeline.isLibraryReference, let libID = pipeline.libraryID,
               let idx = savedPipelines.firstIndex(where: { $0.id == libID })
            {
                savedPipelines[idx].skipOptimisation.toggle()
            }
            onPipelineChanged(updated)
        }) {
            SwiftUI.Image(systemName: resolved.skipOptimisation ? "bolt.slash.fill" : "bolt.fill")
                .font(.regular(10))
                .foregroundColor(resolved.skipOptimisation ? .secondary.opacity(0.4) : .orange.opacity(0.7))
        }
        .buttonStyle(.plain)
        .scaleEffect(showBoltTip ? 1.4 : 1.0)
        .animation(.easeOut(duration: 0.15), value: showBoltTip)
        .onHover { showBoltTip = $0 }
        .overlay(alignment: .bottomTrailing) {
            if showBoltTip {
                Text(
                    resolved.skipOptimisation
                        ? "Click to enable optimisation.\nOriginal file is passed directly into the pipeline."
                        : "Click to skip optimisation.\nFile is optimised first, then passed into the pipeline."
                )
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 180)
                .multilineTextAlignment(.leading)
                .padding(6)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .offset(x: -20, y: 22)
                .allowsHitTesting(false)
                .zIndex(10)
            }
        }
    }

    var eyeButton: some View {
        Button(action: {
            var updated = pipeline
            updated.hideResult.toggle()
            if pipeline.isLibraryReference, let libID = pipeline.libraryID,
               let idx = savedPipelines.firstIndex(where: { $0.id == libID })
            {
                savedPipelines[idx].hideResult.toggle()
            }
            onPipelineChanged(updated)
        }) {
            SwiftUI.Image(systemName: resolved.hideResult ? "eye.slash.fill" : "eye.fill")
                .font(.regular(10))
                .foregroundColor(resolved.hideResult ? .secondary.opacity(0.4) : .blue.opacity(0.7))
        }
        .buttonStyle(.plain)
        .scaleEffect(showEyeTip ? 1.4 : 1.0)
        .animation(.easeOut(duration: 0.15), value: showEyeTip)
        .onHover { showEyeTip = $0 }
        .overlay(alignment: .bottomTrailing) {
            if showEyeTip {
                Text(
                    resolved.hideResult
                        ? "Click to show the floating result.\nThe pipeline currently runs silently in the background."
                        : "Click to hide the floating result.\nThe pipeline will run silently without showing a thumbnail."
                )
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 200)
                .multilineTextAlignment(.leading)
                .padding(6)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .offset(x: -20, y: 22)
                .allowsHitTesting(false)
                .zIndex(10)
            }
        }
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
    @State private var showBoltTip = false
    @State private var showEyeTip = false
    @State private var pipelineName = ""

    @Default(.savedPipelines) private var savedPipelines

    private var coordinator: PipelineTextView.Coordinator? { coordHolder.value }
    private var resolved: Pipeline { pipeline.resolved }

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
                Text("No active sources. Enable clipboard or drag-and-drop, or add watched folders.")
                    .regular(11)
                    .foregroundColor(.secondary)
                    .padding(.leading, 146)
                    .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onAppear { handleHighlightFolder() }
        .onChange(of: svm.highlightFolder) { _ in handleHighlightFolder() }
    }
}

// MARK: - Automation Settings View

// MARK: - Saved Pipeline Row (Library)

/// Reusable inline-editable name label. Shows text, tap to edit in place.
struct InlineNameField: View {
    @Binding var name: String

    var placeholder = "name"
    var font: Font = .system(size: 12, weight: .medium)
    var onCommit: (() -> Void)? = nil

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
                .onTapGesture { isEditing = true }
        }
    }

    @State private var isEditing = false
    @FocusState private var focused: Bool

}

struct SavedPipelineRow: View {
    let pipeline: Pipeline
    var onUpdate: (Pipeline) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                InlineNameField(name: $editName, font: .system(size: 12, weight: .medium)) {
                    var updated = pipeline
                    updated.name = editName
                    onUpdate(updated)
                }

                if !isEditingLib {
                    Text(pipeline.rawText ?? pipeline.steps.map(\.displayString).joined(separator: " -> "))
                        .mono(10)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Button(action: {
                    if isEditingLib {
                        var updated = pipeline
                        updated.name = editName.isEmpty ? pipeline.name : editName
                        updated.updateFromText(editText)
                        onUpdate(updated)
                        isEditingLib = false
                    } else {
                        editText = pipeline.rawText ?? pipeline.steps.map(\.displayString).joined(separator: " -> ")
                        editName = pipeline.name ?? ""
                        isEditingLib = true
                    }
                }) {
                    SwiftUI.Image(systemName: isEditingLib ? "checkmark" : "pencil")
                        .font(.regular(10))
                }
                .buttonStyle(.plain)

                if isEditingLib {
                    Button(action: { isEditingLib = false }) {
                        SwiftUI.Image(systemName: "xmark")
                            .font(.regular(10))
                            .foregroundColor(.yellow)
                    }
                    .buttonStyle(.plain)
                }

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
                    SwiftUI.Image(systemName: "arrow.right.arrow.left")
                        .font(.regular(10))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Move to another file type")

                Button(action: onDelete) {
                    SwiftUI.Image(systemName: "trash")
                        .font(.regular(10))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            if isEditingLib {
                PipelineTextView(
                    text: $editText,
                    fileType: pipeline.fileType,
                    placeholder: "Pipeline steps...",
                    coordinatorRef: { coordHolder.value = $0 }
                )
                .frame(height: max(36, CGFloat(1 + editText.count / 80) * 18))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .onAppear {
            editName = pipeline.name ?? ""
        }
    }

    @State private var isEditingLib = false
    @State private var editText = ""
    @State private var editName = ""
    @State private var coordHolder = RefHolder<PipelineTextView.Coordinator>()

}

// MARK: - Automation Settings View

struct PipelinesSettingsView: View {
    @Default(.savedPipelines) var savedPipelines

    var grouped: [(String, ClopFileType?, [Pipeline])] {
        var result: [(String, ClopFileType?, [Pipeline])] = []
        let types: [ClopFileType?] = [.image, .video, .audio, .pdf, nil]
        for t in types {
            let matching = savedPipelines.filter { $0.fileType == t }
            if !matching.isEmpty {
                let label = t.map { $0 == .pdf ? "PDF" : $0.description.capitalized } ?? "Any type"
                result.append((label, t, matching))
            }
        }
        return result
    }

    var body: some View {
        Form {
            Section(header: SectionHeader(
                title: "Saved Pipelines",
                subtitle: "Reusable pipelines available in automation, preset zones and right-click menus"
            )) {
                if savedPipelines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No saved pipelines yet").medium(13)
                        Text("Save a pipeline from Automation, a preset zone or the right-click menu to reuse it across Clop.")
                            .round(11, weight: .regular)
                            .foregroundColor(.secondary)
                    }
                    .hfill(.leading)
                    .padding(.vertical, 8)
                } else {
                    ForEach(grouped, id: \.0) { label, fileType, pipelines in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .semibold(10)
                                .foregroundColor(fileType?.color ?? .secondary)
                                .padding(.top, 4)
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
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(4)
    }
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
