import Defaults
import Foundation
import Lowtech

// MARK: - MCPSettingKey

/// One writable setting, typed. The closures capture the real `Defaults.Key`, so the type, the
/// accepted values and the write all come from the same declaration the app itself reads. A string
/// table would let a renamed enum case pass the audit and fail at runtime.
struct MCPSettingKey {
    let name: String
    let type: String
    let allowed: [String]?
    let read: @MainActor () -> String
    /// Returns nil on success, an explanation on a rejected value.
    let write: @MainActor (String) -> String?
}

// MARK: - MCPSettingsBridge

/// Settings discovery for agents.
///
/// The wording comes from `SettingsSearchIndex`, the same index the Settings window's search field
/// uses, so an agent reads what the user reads. This file adds the one thing an index row cannot
/// carry: how to read and write the key behind it.
///
/// Same shape as rcmd's `MCPSettingsBridge`; keep the two in step.
enum MCPSettingsBridge {
    // MARK: - Key registry

    @MainActor static let keys: [MCPSettingKey] = [
        // Placement and conversion. The reason this whole index exists: a question like "why is Clop
        // not replacing the mov with the optimised mp4" has to land on one of these.
        behaviour("optimisedImageBehaviour", .optimisedImageBehaviour),
        behaviour("optimisedVideoBehaviour", .optimisedVideoBehaviour),
        behaviour("optimisedAudioBehaviour", .optimisedAudioBehaviour),
        behaviour("optimisedPDFBehaviour", .optimisedPDFBehaviour),
        behaviour("convertedImageBehaviour", .convertedImageBehaviour),
        behaviour("convertedVideoBehaviour", .convertedVideoBehaviour),
        behaviour("convertedAudioBehaviour", .convertedAudioBehaviour),
        behaviour("manualConvertedImageBehaviour", .manualConvertedImageBehaviour),
        behaviour("manualConvertedVideoBehaviour", .manualConvertedVideoBehaviour),
        behaviour("manualConvertedAudioBehaviour", .manualConvertedAudioBehaviour),

        // General
        bool("syncSettingsCloud", .syncSettingsCloud),
        bool("stripMetadata", .stripMetadata),
        bool("preserveColorMetadata", .preserveColorMetadata),
        bool("preserveDates", .preserveDates),
        int("optimisedFileProtectionMs", .optimisedFileProtectionMs),

        // Clipboard
        bool("enableClipboardOptimiser", .enableClipboardOptimiser),
        bool("optimiseTIFF", .optimiseTIFF),
        bool("optimiseImagePathClipboard", .optimiseImagePathClipboard),
        bool("optimiseVideoClipboard", .optimiseVideoClipboard),
        bool("optimiseAudioClipboard", .optimiseAudioClipboard),
        bool("optimisePDFClipboard", .optimisePDFClipboard),
        bool("appendClipboardResults", .appendClipboardResults),
        bool("copyConsecutiveClipboardImages", .copyConsecutiveClipboardImages),
        int("clipboardAccumulationTimeout", .clipboardAccumulationTimeout),

        // Video
        bool("removeAudioFromVideos", .removeAudioFromVideos),
        bool("capVideoFPS", .capVideoFPS),
        bool("convertAudioToAAC", .convertAudioToAAC),
        enumCases(
            "playbackSpeedFrameBehaviour",
            .playbackSpeedFrameBehaviour,
            [("keepFrames", .keepFrames), ("dropFrames", .dropFrames)]
        ),

        // Images
        bool("copyImageFilePath", .copyImageFilePath),
        bool("enablePhotosIntegration", .enablePhotosIntegration),
        bool("useCustomNameTemplateForClipboardImages", .useCustomNameTemplateForClipboardImages),
        string("customNameTemplateForClipboardImages", .customNameTemplateForClipboardImages),
        enumCases(
            "gifFrameDropBehaviour",
            .gifFrameDropBehaviour,
            [("playFaster", .playFaster), ("keepDuration", .keepDuration)]
        ),
        rawValue("photoCropOrientation", .photoCropOrientation),

        // Audio
        rawValue("audioCoverArt", .audioCoverArt),

        // Drop zone
        bool("enableDragAndDrop", .enableDragAndDrop),
        bool("onlyShowDropZoneOnOption", .onlyShowDropZoneOnOption),
        bool("autoCopyToClipboard", .autoCopyToClipboard),
        bool("useBatchModeForFolders", .useBatchModeForFolders),
        int("batchModeFileCountThreshold", .batchModeFileCountThreshold),

        // Preset zones
        bool("onlyShowPresetZonesOnControlTapped", .onlyShowPresetZonesOnControlTapped),

        // Floating results
        bool("enableFloatingResults", .enableFloatingResults),
        bool("followCursorScreen", .followCursorScreen),
        bool("hideFloatingResultTooltips", .hideFloatingResultTooltips),
        bool("alwaysShowCompactResults", .alwaysShowCompactResults),
        bool("showCopyClearButtons", .showCopyClearButtons),
        bool("dismissFloatingResultOnDrop", .dismissFloatingResultOnDrop),
        bool("dismissFloatingResultOnUpload", .dismissFloatingResultOnUpload),
        bool("autoHideFloatingResults", .autoHideFloatingResults),
        int("autoHideFloatingResultsAfter", .autoHideFloatingResultsAfter),
        int("autoHideClipboardResultAfter", .autoHideClipboardResultAfter),
        bool("showCompactImages", .showCompactImages),
        bool("dismissCompactResultOnDrop", .dismissCompactResultOnDrop),
        bool("dismissCompactResultOnUpload", .dismissCompactResultOnUpload),
        int("autoClearAllCompactResultsAfter", .autoClearAllCompactResultsAfter),
        enumCases(
            "formatPickerStyle",
            .formatPickerStyle,
            [("bar", .bar), ("extensionHover", .extensionHover)]
        ),
        enumCases(
            "floatingResultsCorner",
            .floatingResultsCorner,
            [
                ("bottomRight", .bottomRight),
                ("bottomLeft", .bottomLeft),
                ("topRight", .topRight),
                ("topLeft", .topLeft),
            ]
        ),

        // MCP. Readable so an agent can see why it was refused; `mcpEnabled` is deliberately NOT
        // writable here, or the switch would be one the thing it gates could turn on for itself.
        bool("mcpAllowScriptSteps", .mcpAllowScriptSteps),
    ]

    @MainActor static var keysByName: [String: MCPSettingKey] {
        Dictionary(keys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Schema

    /// Every indexed setting with its live value. `filter` narrows it with the same matching the
    /// Settings search field uses, so an agent's plain-language question lands on the row a person's
    /// would.
    @MainActor static func schema(filter: String? = nil) -> [MCPSettingInfo] {
        let registry = keysByName
        let entries = if let filter, !filter.isEmpty { matches(filter) } else { SettingsSearchIndex.all }

        return entries.flatMap { entry -> [MCPSettingInfo] in
            guard entry.keys.isNotEmpty else { return [info(entry: entry, key: nil)] }
            return entry.keys.map { info(entry: entry, key: registry[$0]) }
        }
    }

    @MainActor static func get(_ name: String) -> MCPSettingInfo? {
        guard let key = keysByName[name] else { return nil }
        return info(entry: SettingsSearchIndex.all.first { $0.keys.contains(name) }, key: key)
    }

    /// Returns nil on success, an explanation otherwise.
    @MainActor static func set(_ name: String, to value: String) -> String? {
        guard let key = keysByName[name] else {
            return "no setting named '\(name)'. Call the schema tool to see every key."
        }
        return key.write(value)
    }

    /// What an agent's whole question should land on.
    ///
    /// The strict all-words match first, because when every word does hit, that ranking is the one the
    /// Settings field would have shown. Behind it, the same scoring with the all-words requirement
    /// dropped: "why is Clop not replacing the mov with the optimised mp4" has words no row carries,
    /// and the rare ones ("mov", "mp4", "replacing") are what should decide it.
    @MainActor static func matches(_ filter: String) -> [SettingEntry] {
        let strict = SettingsSearchIndex.search(filter)
        let seen = Set(strict.map(\.id))
        let relaxed = SettingsSearchIndex.rank(filter, requireAll: false, limit: 20)
            .filter { !seen.contains($0.id) }
        return strict + relaxed
    }

    @MainActor private static func info(entry: SettingEntry?, key: MCPSettingKey?) -> MCPSettingInfo {
        MCPSettingInfo(
            key: key?.name ?? "",
            type: key?.type ?? "none",
            value: key?.read() ?? "",
            allowed: key?.allowed,
            title: entry?.title ?? key?.name ?? "",
            subtitle: entry?.subtitle ?? "",
            keywords: entry?.keywords ?? [],
            pane: entry?.tab.title ?? "",
            section: entry?.section ?? "",
            entryID: entry?.id ?? ""
        )
    }

    // MARK: - Typed builders

    private static func bool(_ name: String, _ key: Defaults.Key<Bool>) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "bool", allowed: ["true", "false"]) {
            Defaults[key] ? "true" : "false"
        } write: { raw in
            switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "yes", "on", "1": Defaults[key] = true
            case "false", "no", "off", "0": Defaults[key] = false
            default: return "\(name) takes true or false, not '\(raw)'"
            }
            return nil
        }
    }

    private static func int(_ name: String, _ key: Defaults.Key<Int>) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "int", allowed: nil) {
            String(Defaults[key])
        } write: { raw in
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                return "\(name) takes a whole number, not '\(raw)'"
            }
            Defaults[key] = value
            return nil
        }
    }

    private static func string(_ name: String, _ key: Defaults.Key<String>) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "string", allowed: nil) {
            Defaults[key]
        } write: { raw in
            Defaults[key] = raw
            return nil
        }
    }

    /// Any `String`-backed enum. The allowed list comes from `CaseIterable`, so it cannot drift from
    /// the cases the app actually accepts.
    private static func rawValue<T>(_ name: String, _ key: Defaults.Key<T>) -> MCPSettingKey
        where T: RawRepresentable & CaseIterable & Defaults.Serializable, T.RawValue == String
    {
        MCPSettingKey(name: name, type: "enum", allowed: T.allCases.map(\.rawValue)) {
            Defaults[key].rawValue
        } write: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let value = T.allCases.first(where: { $0.rawValue.lowercased() == trimmed.lowercased() }) else {
                return "\(name) takes one of: \(T.allCases.map(\.rawValue).joined(separator: ", ")). Got '\(raw)'"
            }
            Defaults[key] = value
            return nil
        }
    }

    /// Any enum, with its cases named explicitly. For the ones that are not `CaseIterable` and for
    /// the `Int`-backed ones, where the raw value is a number no agent should ever see.
    private static func enumCases<T: Equatable & Defaults.Serializable>(_ name: String, _ key: Defaults.Key<T>, _ cases: [(String, T)]) -> MCPSettingKey {
        MCPSettingKey(name: name, type: "enum", allowed: cases.map(\.0)) {
            cases.first { $0.1 == Defaults[key] }?.0 ?? ""
        } write: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = cases.first(where: { $0.0.lowercased() == trimmed })?.1 else {
                return "\(name) takes one of: \(cases.map(\.0).joined(separator: ", ")). Got '\(raw)'"
            }
            Defaults[key] = value
            return nil
        }
    }

    /// `FileBehaviour` gets its own builder rather than going through `rawValue`: it is not
    /// `CaseIterable`, and the names people and agents use for it ("in place", "replace the original")
    /// are not its raw values.
    private static func behaviour(_ name: String, _ key: Defaults.Key<FileBehaviour>) -> MCPSettingKey {
        let names: [(String, FileBehaviour)] = [
            ("temporary", .temporary),
            ("inPlace", .inPlace),
            ("sameFolder", .sameFolder),
            ("specificFolder", .specificFolder),
        ]
        // What an agent is likely to say, mapped onto what the setting takes.
        let aliases: [String: FileBehaviour] = [
            "in place": .inPlace, "in-place": .inPlace, "inplace": .inPlace,
            "replace": .inPlace, "replace original": .inPlace, "overwrite": .inPlace,
            "same folder": .sameFolder, "same-folder": .sameFolder, "samefolder": .sameFolder,
            "beside": .sameFolder, "next to": .sameFolder, "copy": .sameFolder,
            "specific folder": .specificFolder, "specific-folder": .specificFolder,
            "temp": .temporary, "temporary folder": .temporary,
        ]
        return MCPSettingKey(name: name, type: "enum", allowed: names.map(\.0)) {
            names.first { $0.1 == Defaults[key] }?.0 ?? "\(Defaults[key])"
        } write: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = names.first(where: { $0.0.lowercased() == trimmed })?.1 ?? aliases[trimmed] {
                Defaults[key] = match
                return nil
            }
            return "\(name) takes one of: \(names.map(\.0).joined(separator: ", ")). Got '\(raw)'"
        }
    }
}

// MARK: - Request handling

extension MCPSettingsBridge {
    /// Answers a `SettingsRequest` from the CLI, and enforces the MCP gate.
    ///
    /// The gate lives here rather than in the CLI because the CLI is a binary the caller controls. A
    /// request that says it came from MCP is refused unless the user has a Pro licence and, for a
    /// write, has allowed agent changes. A request that does not claim MCP origin is somebody using
    /// their own CLI, which needs no permission from anyone.
    @MainActor static func handle(_ req: SettingsRequest) -> SettingsResponse {
        if req.origin == "mcp" {
            guard proactive else {
                return SettingsResponse(ok: false, error: "Clop's MCP server needs Clop Pro.")
            }
            if req.action == .set, !Defaults[.mcpEnabled] {
                return SettingsResponse(
                    ok: false,
                    error: "Clop is not accepting changes from agents. Ask the user to allow it in Clop Settings, MCP."
                )
            }
        }

        switch req.action {
        case .schema:
            return SettingsResponse(ok: true, settings: schema(filter: req.query))
        case .get:
            guard let name = req.key else {
                return SettingsResponse(ok: false, error: "get needs a key")
            }
            guard let found = get(name) else {
                return SettingsResponse(ok: false, error: "no setting named '\(name)'. Ask for the schema to see every key.")
            }
            return SettingsResponse(ok: true, settings: [found])
        case .set:
            guard let name = req.key, let value = req.value else {
                return SettingsResponse(ok: false, error: "set needs a key and a value")
            }
            if let problem = set(name, to: value) {
                return SettingsResponse(ok: false, error: problem)
            }
            return SettingsResponse(ok: true, settings: get(name).map { [$0] })
        }
    }
}
