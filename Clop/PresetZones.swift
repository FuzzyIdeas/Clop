import Defaults
import Foundation
import Lowtech
import SwiftUI

struct PresetZone: Codable, Hashable, Identifiable, Defaults.Serializable {
    init(name: String, icon: String, type: ClopFileType? = nil, pipeline: Pipeline) {
        self.name = name
        self.icon = icon
        self.type = type
        self.pipeline = pipeline
        id = "\(name)-\(type?.rawValue ?? "all")"
    }

    init(name: String, icon: String, type: ClopFileType? = nil, shortcut: Shortcut) {
        self.init(name: name, icon: icon, type: type, pipeline: Pipeline(steps: [.runShortcut(shortcut)]))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        icon = try container.decode(String.self, forKey: .icon)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(ClopFileType.self, forKey: .type)

        if let pipeline = try container.decodeIfPresent(Pipeline.self, forKey: .pipeline) {
            self.pipeline = pipeline
        } else if let shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) {
            pipeline = Pipeline(steps: [.runShortcut(shortcut)])
        } else {
            pipeline = Pipeline(steps: [])
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, icon, name, type, pipeline, shortcut
    }

    let id: String
    let icon: String
    let name: String
    let type: ClopFileType?
    var pipeline: Pipeline

    /// The effective pipeline, resolving library references.
    var resolvedPipeline: Pipeline { pipeline.resolved }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(icon, forKey: .icon)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encode(pipeline, forKey: .pipeline)
    }
}

struct DropZoneSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            DropZoneSettingsView()
                .formStyle(.grouped)
                .padding()
        }
        .frame(minWidth: WINDOW_MIN_SIZE.width, maxWidth: .infinity, minHeight: WINDOW_MIN_SIZE.height, maxHeight: .infinity)
    }
}

struct PresetZoneEditor: View {
    @Binding var zone: PresetZone?

    @State var icon = "wand.and.sparkles"
    @State var name = ""
    @State var pipelineText = ""
    @State var skipOptimisation = false
    @State var type: ClopFileType? = nil
    @State var coordHolder = RefHolder<PipelineTextView.Coordinator>()
    @State var showBoltTip = false
    @State var currentPrefix = ""
    @State var savedPipelineText = ""

    var onSubmit: (() -> Void)? = nil
    var type_: ClopFileType? = nil

    @Default(.presetZones) var presetZones
    @Default(.savedPipelines) var savedPipelines

    var editorFileType: ClopFileType { type ?? .image }
    var isEditing: Bool { zone != nil }
    var canSave: Bool { !name.isEmpty && !Pipeline.parseSteps(from: pipelineText).isEmpty }

    var applicableLibraryPipelines: [Pipeline] {
        savedPipelines.filter { p in
            guard let name = p.name, !name.isEmpty else { return false }
            return p.fileType == nil || p.fileType == type
        }
    }

    var headerRow: some View {
        HStack(spacing: 6) {
            IconPickerView(icon: $icon)
                .frame(width: 24, alignment: .center)

            HStack(spacing: 0) {
                TextField("", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)

                if !applicableLibraryPipelines.isEmpty {
                    Menu {
                        ForEach(applicableLibraryPipelines) { lib in
                            Button(lib.name ?? lib.id) {
                                name = lib.name ?? name
                                pipelineText = lib.displayText
                                skipOptimisation = lib.skipOptimisation
                            }
                        }
                    } label: {
                        Color.clear
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .card(radius: 4, fill: .primary.opacity(0.05), borderColor: .primary.opacity(0.3))
            .frame(width: 120, alignment: .leading)

            Picker("", selection: $type) {
                Text("any").tag(nil as ClopFileType?)
                ForEach(ClopFileType.allCases, id: \.self) { t in
                    Text(t == .pdf ? "PDF" : t.description).tag(t as ClopFileType?)
                }
            }
            .frame(width: 100, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            boltButton

            Spacer()

            Button(action: save) {
                HStack(spacing: 3) {
                    SwiftUI.Image(systemName: isEditing ? "checkmark.circle.fill" : "plus.circle.fill")
                    Text(isEditing ? "Save" : "Add")
                }
                .font(.medium(11))
            }
            .buttonStyle(.plain)
            .foregroundColor(canSave ? .accentColor : .secondary.opacity(0.8))
            .disabled(!canSave)

            Button(action: cancel) {
                Text("Cancel")
                    .regular(11)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    var boltButton: some View {
        Button(action: { skipOptimisation.toggle() }) {
            SwiftUI.Image(systemName: skipOptimisation ? "bolt.slash.fill" : "bolt.fill")
                .font(.regular(10))
                .foregroundColor(skipOptimisation ? .secondary.opacity(0.4) : .orange.opacity(0.7))
        }
        .buttonStyle(.plain)
        .scaleEffect(showBoltTip ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.15), value: showBoltTip)
        .onHover { showBoltTip = $0 }
        .overlay(alignment: .top) {
            if showBoltTip {
                Text(
                    skipOptimisation
                        ? "Click to enable optimisation.\nOriginal file is passed directly into the pipeline."
                        : "Click to skip optimisation.\nFile is optimised first, then passed into the pipeline."
                )
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(6)
                .background(.black, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .offset(y: -40)
                .allowsHitTesting(false)
                .zIndex(10)
            }
        }
    }

    var pipelineEditor: some View {
        PipelineTextView(
            text: $pipelineText,
            fileType: editorFileType,
            placeholder: "optimise, crop, copy, convert...",
            onPrefixChanged: { currentPrefix = $0 },
            coordinatorRef: { coordHolder.value = $0 }
        )
        .frame(height: max(isEditing ? 36 : 26, CGFloat(1 + pipelineText.count / 80) * 18))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .card(radius: 6, fill: .primary.opacity(0.04), borderColor: Color(.separatorColor).opacity(0.12), borderWidth: 1)
    }

    @ViewBuilder var suggestionsView: some View {
        if pipelineText != savedPipelineText {
            let suggestions = pipelineSuggestions(prefix: currentPrefix, fileType: editorFileType)
            if !suggestions.isEmpty {
                CompletionPanel(suggestions: suggestions) { suggestion in
                    coordHolder.value?.insertSuggestion(suggestion)
                    coordHolder.value?.refocus()
                }
                .padding(.horizontal, 8)
            }
        }

        StepActionGrid(fileType: editorFileType) { text in
            coordHolder.value?.appendStep(text)
            coordHolder.value?.refocus()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
                headerRow
                pipelineEditor
            }
            .padding(8)
            .card(radius: 8, fill: .primary.opacity(isEditing ? 0.04 : 0.025), borderColor: .primary.opacity(isEditing ? 0.12 : 0.06), borderWidth: isEditing ? 1 : 0.5)
            .onAppear {
                if let zone { setFields(zone: zone) }
            }
            .onChange(of: zone) { [zone] newZone in
                if let z = newZone { setFields(zone: z) }
                else if zone != nil { setFields(zone: nil) }
            }

            suggestionsView
        }
    }

    func save() {
        guard !name.isEmpty else { return }
        let trimmedText = pipelineText.trimmingCharacters(in: .whitespacesAndNewlines)
        let libPipeline: Pipeline
        if let existingLibID = zone?.pipeline.libraryID,
           let idx = savedPipelines.firstIndex(where: { $0.id == existingLibID })
        {
            savedPipelines[idx].updateFromText(pipelineText)
            savedPipelines[idx].name = name
            savedPipelines[idx].fileType = type
            savedPipelines[idx].skipOptimisation = skipOptimisation
            libPipeline = savedPipelines[idx]
        } else if let idx = savedPipelines.firstIndex(where: { $0.name == name && $0.fileType == type }) {
            // Replace existing pipeline with same name and type
            savedPipelines[idx].updateFromText(pipelineText)
            savedPipelines[idx].skipOptimisation = skipOptimisation
            libPipeline = savedPipelines[idx]
        } else {
            libPipeline = Pipeline(
                steps: Pipeline.parseSteps(from: pipelineText),
                name: name,
                rawText: trimmedText.isEmpty ? nil : pipelineText,
                skipOptimisation: skipOptimisation,
                fileType: type
            )
            savedPipelines.append(libPipeline)
        }
        let pipeline = Pipeline.reference(to: libPipeline)
        if let zone {
            presetZones = presetZones.replacing(zone, with: PresetZone(name: name, icon: icon, type: type, pipeline: pipeline))
            self.zone = nil
        } else {
            presetZones.append(PresetZone(name: name, icon: icon, type: type, pipeline: pipeline))
        }
        setFields(zone: nil)
        onSubmit?()
    }

    func cancel() {
        zone = nil
        setFields(zone: nil)
        onSubmit?()
    }

    func setFields(zone: PresetZone?) {
        icon = zone?.icon ?? "wand.and.sparkles"
        name = zone?.name ?? ""
        let resolved = zone?.resolvedPipeline
        let text = resolved?.displayText ?? ""
        pipelineText = text
        savedPipelineText = text
        skipOptimisation = resolved?.skipOptimisation ?? false
        type = zone?.type
    }
}
