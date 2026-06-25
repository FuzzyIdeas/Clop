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

    /// Init that keeps an explicit, stable id so renaming a zone (name/type) doesn't change its identity.
    /// This matters for the single inline editor, which is looked up by id while you type.
    init(id: String, name: String, icon: String, type: ClopFileType? = nil, pipeline: Pipeline) {
        self.id = id
        self.name = name
        self.icon = icon
        self.type = type
        self.pipeline = pipeline
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
    var resolvedPipeline: Pipeline {
        pipeline.resolved
    }

    /// A name not already used by another zone, so the derived `id` (name+type) stays unique.
    static func uniqueName(_ base: String, in zones: [PresetZone]) -> String {
        let used = Set(zones.map(\.name))
        guard used.contains(base) else { return base }
        var i = 2
        while used.contains("\(base) \(i)") {
            i += 1
        }
        return "\(base) \(i)"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(icon, forKey: .icon)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encode(pipeline, forKey: .pipeline)
    }

}

// MARK: - Preset zone mutations

//
// Shared by the inline preview menus (the first-class spatial add/remove surface) and the editor rows.

/// Append a new preset zone for `type` with an empty inline pipeline and a default icon/name, returning
/// its id so the caller can open its editor row.
@MainActor func appendPresetZone(type: ClopFileType?) -> String {
    var zones = Defaults[.presetZones]
    let zone = PresetZone(
        id: UUID().uuidString,
        name: PresetZone.uniqueName("New preset", in: zones),
        icon: "wand.and.sparkles", type: type, pipeline: Pipeline(steps: [])
    )
    zones.append(zone)
    Defaults[.presetZones] = zones
    return zone.id
}

/// Append (or replace `existing` with) a preset zone for `type` that references the library `pipeline`.
@MainActor func assignPresetZone(library pipeline: Pipeline, type: ClopFileType?, replacing existing: PresetZone? = nil) {
    var zones = Defaults[.presetZones]
    // Adopt the assigned pipeline's name and icon so the zone visibly reflects what it now runs.
    let name = pipeline.name ?? existing?.name ?? PresetZone.uniqueName("Preset", in: zones)
    let zone = PresetZone(id: existing?.id ?? UUID().uuidString, name: name, icon: pipeline.icon ?? "wand.and.sparkles", type: type, pipeline: Pipeline.reference(to: pipeline))
    if let existing, let idx = zones.firstIndex(of: existing) {
        zones[idx] = zone
    } else {
        zones.append(zone)
    }
    Defaults[.presetZones] = zones
}

@MainActor func removePresetZone(_ zone: PresetZone) {
    Defaults[.presetZones] = Defaults[.presetZones].filter { $0.id != zone.id }
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

/// The single inline editor shown when a preset zone is being added or edited (opened from a zone's menu in
/// the preview). Always in editing mode and styled like the Pipelines-library row: icon + name, the
/// file-type menu, Pass/Show-Hide toggles, and the steps editor. Done commits and closes; Cancel closes and
/// discards a brand-new zone that never got any steps.
struct PresetZoneRow: View {
    let zone: PresetZone
    var onClose: () -> Void

    @Default(.presetZones) var presetZones
    @Default(.savedPipelines) var savedPipelines

    var typeMenu: some View {
        Menu {
            let types: [(String, ClopFileType?)] = [("Image", .image), ("Video", .video), ("Audio", .audio), ("PDF", .pdf)]
            ForEach(types, id: \.0) { label, t in
                Button {
                    if t != zone.type { replaceMeta(name: editName, icon: icon, type: t) }
                } label: {
                    HStack { Text(label); if zone.type == t { SwiftUI.Image(systemName: "checkmark") } }
                }
            }
        } label: {
            HStack(spacing: 3) {
                if let ft = zone.type {
                    SwiftUI.Image(systemName: ft.symbolName).foregroundColor(ft.color)
                } else {
                    SwiftUI.Image(systemName: "doc").foregroundColor(.secondary)
                }
                Text(zone.type.map { $0 == .pdf ? "PDF" : $0.description.capitalized } ?? "Any type")
                    .foregroundColor(.blue.opacity(0.7))
            }
            .font(.regular(10))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Move to another file type")
    }

    var confirmCancel: some View {
        HStack(spacing: 0) {
            Button(action: commit) {
                SwiftUI.Image(systemName: "checkmark").font(.regular(11)).foregroundColor(.green.opacity(0.8))
                    .padding(.horizontal, 7).padding(.vertical, 3)
            }.buttonStyle(.plain).help("Done")
            Button(action: cancel) {
                SwiftUI.Image(systemName: "xmark").font(.regular(11)).foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 7).padding(.vertical, 3)
            }.buttonStyle(.plain).help("Cancel")
        }
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconPickerView(icon: $icon)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .onChange(of: icon) { newIcon in
                        if newIcon != zone.icon { replaceMeta(name: editName, icon: newIcon, type: zone.type) }
                    }

                InlineNameField(name: $editName, size: 11, weight: .regular) {
                    let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != zone.name { replaceMeta(name: trimmed, icon: icon, type: zone.type) }
                }

                Spacer(minLength: 0)

                typeMenu
                PipelineFlagSegmentedToggle(
                    leading: "Pass", options: ("optimised", "original"), trailing: "file",
                    selection: resolved.skipOptimisation ? 1 : 0,
                    help: PipelineFlagCopy.skipOptimisation, tint: .orange
                ) { idx in setFlag(skip: idx == 1) }
                PipelineFlagSegmentedToggle(
                    leading: nil, options: ("Show", "Hide"), trailing: "floating result",
                    selection: resolved.hideResult ? 1 : 0,
                    help: PipelineFlagCopy.hideResult, tint: .red
                ) { idx in setFlag(hide: idx == 1) }
                confirmCancel
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08))

            Divider().opacity(0.5)

            PipelineTextView(
                text: $editText,
                fileType: zone.type,
                placeholder: "optimise, crop, copy, convert...",
                onEditingChanged: { isEditingSteps = $0 },
                onPrefixChanged: { currentPrefix = $0 },
                onSubmit: { commit() },
                onCancel: { cancel() },
                coordinatorRef: { coordHolder.value = $0 }
            )
            .frame(height: max(36, CGFloat(1 + editText.count / 80) * 18))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.bg.warm.opacity(0.9))
            if isEditingSteps {
                PipelineEditingSuggestions(prefix: currentPrefix, fileType: zone.type, coordinator: coordinator)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .card(radius: 6, fill: .clear, borderColor: .primary.opacity(0.2), borderWidth: 1)
        .onAppear {
            editName = zone.name
            icon = zone.icon
            editText = resolved.displayText
        }
    }

    func commit() {
        updatePipelineText(editText)
        onClose()
    }

    func cancel() {
        // A brand-new zone that never received any steps is noise; drop it on cancel.
        if resolved.steps.isEmpty, (resolved.rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removePresetZone(zone)
        }
        onClose()
    }

    @State private var editText = ""
    @State private var editName = ""
    @State private var icon = "wand.and.sparkles"
    @State private var coordHolder = RefHolder<PipelineTextView.Coordinator>()
    @State private var currentPrefix = ""
    @State private var isEditingSteps = false

    private var coordinator: PipelineTextView.Coordinator? {
        coordHolder.value
    }

    private var resolved: Pipeline {
        zone.resolvedPipeline
    }

    // MARK: - Persistence

    private func replaceZone(_ newZone: PresetZone) {
        guard let idx = presetZones.firstIndex(of: zone) else { return }
        presetZones[idx] = newZone
    }

    private func replaceMeta(name: String, icon: String, type: ClopFileType?) {
        replaceZone(PresetZone(id: zone.id, name: name, icon: icon, type: type, pipeline: zone.pipeline))
    }

    private func updatePipelineText(_ text: String) {
        if zone.pipeline.isLibraryReference, let libID = zone.pipeline.libraryID,
           let i = savedPipelines.firstIndex(where: { $0.id == libID })
        {
            savedPipelines[i].updateFromText(text)
        } else {
            var p = zone.pipeline
            p.updateFromText(text)
            replaceZone(PresetZone(id: zone.id, name: zone.name, icon: zone.icon, type: zone.type, pipeline: p))
        }
    }

    private func setFlag(skip: Bool? = nil, hide: Bool? = nil) {
        if zone.pipeline.isLibraryReference, let libID = zone.pipeline.libraryID,
           let i = savedPipelines.firstIndex(where: { $0.id == libID })
        {
            if let skip { savedPipelines[i].skipOptimisation = skip }
            if let hide { savedPipelines[i].hideResult = hide }
        } else {
            var p = zone.pipeline
            if let skip { p.skipOptimisation = skip }
            if let hide { p.hideResult = hide }
            replaceZone(PresetZone(id: zone.id, name: zone.name, icon: zone.icon, type: zone.type, pipeline: p))
        }
    }
}
