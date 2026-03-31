import Defaults
import Foundation
import Lowtech
import os
import SwiftUI
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Automation")

extension Defaults.Keys {
    static let shortcutToRunOnImage = Key<[String: Shortcut]>("shortcutToRunOnImage", default: [:])
    static let shortcutToRunOnVideo = Key<[String: Shortcut]>("shortcutToRunOnVideo", default: [:])
    static let shortcutToRunOnPdf = Key<[String: Shortcut]>("shortcutToRunOnPdf", default: [:])

    static let pipelinesToRunOnImage = Key<[String: [Pipeline]]>("pipelinesToRunOnImage", default: [:])
    static let pipelinesToRunOnVideo = Key<[String: [Pipeline]]>("pipelinesToRunOnVideo", default: [:])
    static let pipelinesToRunOnPdf = Key<[String: [Pipeline]]>("pipelinesToRunOnPdf", default: [:])
    static let pipelinesToRunOnAudio = Key<[String: [Pipeline]]>("pipelinesToRunOnAudio", default: [:])
    static let pipelinesMigrated = Key<Bool>("pipelinesMigrated", default: false)
    static let savedScriptPaths = Key<[String: String]>("savedScriptPaths", default: [:])
    static let savedPipelines = Key<[Pipeline]>("savedPipelines", default: [])
}

extension Optimiser {
    nonisolated func runShortcut(_ shortcut: Shortcut, outFile: FilePath, url: URL) -> Process? {
        guard let proc = runShortcutProcess(shortcut, url.path, outFile: outFile.string) else {
            return nil
        }

        mainActor { [weak self] in
            self?.running = true
            self?.progress = Progress()
            self?.operation = "❯ \(shortcut.name)"
            self?.processes = [proc]
        }
        return proc
    }
}

// MARK: - Pipeline Migration

func migrateShortcutsToPipelines() {
    guard !Defaults[.pipelinesMigrated] else { return }

    var imagePipelines = Defaults[.pipelinesToRunOnImage]
    for (source, shortcut) in Defaults[.shortcutToRunOnImage] {
        imagePipelines[source, default: []].append(Pipeline(steps: [.runShortcut(shortcut)]))
    }
    if !imagePipelines.isEmpty { Defaults[.pipelinesToRunOnImage] = imagePipelines }

    var videoPipelines = Defaults[.pipelinesToRunOnVideo]
    for (source, shortcut) in Defaults[.shortcutToRunOnVideo] {
        videoPipelines[source, default: []].append(Pipeline(steps: [.runShortcut(shortcut)]))
    }
    if !videoPipelines.isEmpty { Defaults[.pipelinesToRunOnVideo] = videoPipelines }

    var pdfPipelines = Defaults[.pipelinesToRunOnPdf]
    for (source, shortcut) in Defaults[.shortcutToRunOnPdf] {
        pdfPipelines[source, default: []].append(Pipeline(steps: [.runShortcut(shortcut)]))
    }
    if !pdfPipelines.isEmpty { Defaults[.pipelinesToRunOnPdf] = pdfPipelines }

    Defaults[.pipelinesMigrated] = true
    log.info("Migrated shortcuts to pipelines: images=\(imagePipelines.count), videos=\(videoPipelines.count), pdfs=\(pdfPipelines.count)")
}

struct Shortcut: Codable, Hashable, Defaults.Serializable, Identifiable {
    var name: String
    var identifier: String

    var id: String { identifier }
    var url: URL {
        if let url = identifier.url {
            return url
        }
        guard let id = identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "shortcuts://".url!
        }
        return "shortcuts://open-shortcut?id=\(id)".url!
    }
}

struct CachedShortcuts {
    var shortcuts: [Shortcut] = []
    var lastUpdate = Date()
    var folder: String?
}
struct CachedShortcutsMap {
    var shortcuts: [String: [Shortcut]] = [:]
    var lastUpdate = Date()
}

var shortcutsCacheByFolder: [String?: CachedShortcuts] = [:]
var shortcutsMapCache: CachedShortcutsMap?

func getShortcutsOrCached(folder: String? = nil) -> [Shortcut]? {
    if let cached = mainThread({ shortcutsCacheByFolder[folder] }), cached.lastUpdate.timeIntervalSinceNow > -60 {
        return cached.shortcuts
    }

    guard let shortcuts = getShortcuts(folder: folder) else {
        return nil
    }

    mainAsync {
        shortcutsCacheByFolder[folder] = CachedShortcuts(shortcuts: shortcuts, lastUpdate: Date(), folder: folder)
    }
    return shortcuts
}

func getShortcutsMapOrCached() -> [String: [Shortcut]] {
    if let cached = mainThread({ shortcutsMapCache }), cached.lastUpdate.timeIntervalSinceNow > -60 {
        return cached.shortcuts
    }

    let shortcutsMap = getShortcutsMap()

    mainAsync {
        shortcutsMapCache = CachedShortcutsMap(shortcuts: shortcutsMap, lastUpdate: Date())
    }
    return shortcutsMap
}

func getShortcuts(folder: String? = nil) -> [Shortcut]? {
    guard !SWIFTUI_PREVIEW else { return nil }
    log.debug("Getting shortcuts for folder \(folder ?? "nil")")

    let additionalArgs = folder.map { ["--folder-name", $0] } ?? []
    guard let output = shell("/usr/bin/shortcuts", args: ["list", "--show-identifiers"] + additionalArgs, timeout: 2).o else {
        return nil
    }

    let lines = output.split(separator: "\n")
    var shortcuts: [Shortcut] = []
    for line in lines {
        let parts = line.split(separator: " ")
        guard let identifier = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: "()")) else {
            continue
        }
        let name = parts.dropLast().joined(separator: " ")
        shortcuts.append(Shortcut(name: name, identifier: identifier))
    }

    guard shortcuts.count > 0 else {
        return nil
    }

    return shortcuts
}

func getShortcutsMap() -> [String: [Shortcut]] {
    guard let folders: [String] = shell("/usr/bin/shortcuts", args: ["list", "--folders"], timeout: 2).o?.split(separator: "\n").map({ s in String(s) })
    else { return [:] }

    if let cached = mainThread({ shortcutsMapCache }), cached.lastUpdate.timeIntervalSinceNow > -60 {
        return cached.shortcuts
    }

    return (folders + ["none"]).compactMap { folder -> (String, [Shortcut])? in
        guard let shortcuts = getShortcutsOrCached(folder: folder) else {
            return nil
        }
        return (folder == "none" ? "Other" : folder, shortcuts)
    }.reduce(into: [:]) { $0[$1.0] = $1.1 }
}

func runShortcutProcess(_ shortcut: Shortcut, _ file: String, outFile: String) -> Process? {
    let cmd =
        "/usr/bin/shortcuts run $'\(shortcut.identifier.replacingOccurrences(of: "'", with: "\\'"))' --input-path '\(file.replacingOccurrences(of: "'", with: "\\'"))' --output-path '\(outFile.replacingOccurrences(of: "'", with: "\\'"))'"
    log.debug("Running: \(cmd)")
    let ps = shell(command: cmd)
    return ps.process
}

struct ShortcutsIcon: View {
    var size: CGFloat = 20

    var body: some View {
        VStack(spacing: -size / 1.8) {
            RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(hue: 0.02, saturation: 0.61, brightness: 0.89, opacity: 1.00), location: 0),
                    .init(color: Color(hue: 0.87, saturation: 0.51, brightness: 0.89, opacity: 0.9), location: 0.5),
                    .init(color: Color(hue: 0.87, saturation: 0.51, brightness: 0.89, opacity: 0.3), location: 0.9),
                ], startPoint: .leading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.7), radius: size / 4, y: 2)
                .rotationEffect(.degrees(-45))
                .scaleEffect(y: 0.85)
            RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(hue: 0.59, saturation: 0.49, brightness: 0.48, opacity: 1.00), location: 0),
                    .init(color: Color(hue: 0.46, saturation: 0.46, brightness: 0.74, opacity: 0.9), location: 0.5),
                    .init(color: Color(hue: 0.61, saturation: 0.76, brightness: 0.94, opacity: 1.00), location: 0.9),
                ], startPoint: .top, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-45))
                .scaleEffect(y: 0.85)
                .zIndex(-1)
        }
    }
}

var shortcutCacheResetTask: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}

func startShortcutWatcher() {
    guard fm.fileExists(atPath: "\(HOME)/Library/Shortcuts") else {
        guard hasShortcutsDB() else { return }
        return
    }

    do {
        try LowtechFSEvents.startWatching(paths: ["\(HOME)/Library/Shortcuts"], for: ObjectIdentifier(AppDelegate.instance), latency: 0.9) { event in
            guard !SWIFTUI_PREVIEW else { return }

            shortcutCacheResetTask = mainAsyncAfter(ms: 100) {
                SHM.invalidateCache()
            }
        }
    } catch {
        log.error("Failed to start Shortcut watcher: \(error)")
    }
}

struct AutomationRowView: View {
    @Binding var shortcuts: [String: Shortcut]

    var icon: String
    var type: String
    var color: Color
    var sources: [OptimisationSource] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("On optimised")
                HStack {
                    SwiftUI.Image(systemName: icon).frame(width: 14)
                    Text(type)
                }.roundbg(radius: 6, color: color.opacity(0.1), noFG: true)

                Spacer()

                Menu(content: {
                    Button("From scratch") {
                        NSWorkspace.shared.open(
                            Bundle.main.url(forResource: "Clop - \(type)", withExtension: "shortcut")!
                        )
                    }
                    Section("Templates") {
                        ForEach(CLOP_SHORTCUTS, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                }, label: {
                    HStack {
                        ShortcutsIcon(size: 12)
                        Text("New Shortcut")
                    }
                })
                .buttonStyle(FlatButton(color: .mauve.opacity(0.8), textColor: .white))
                .font(.medium(12))
                .saturation(1.5)
            }
            ForEach(sources, id: \.self) { s in
                picker(source: s.string)
                    .padding(.leading)
            }
        }
    }

    @ViewBuilder
    func picker(source: String) -> some View {
        let binding = Binding<Shortcut?>(
            get: { shortcuts[source] },
            set: {
                if let shortcut = $0, let url = shortcut.identifier.url {
                    NSWorkspace.shared.open(url)
                    return
                }

                if let shortcut = $0 {
                    shortcuts = shortcuts.copyWith(key: source, value: shortcut)
                } else {
                    shortcuts = shortcuts.copyWithout(key: source)
                }
            }
        )

        HStack {
            Picker(
                selection: binding,
                content: {
                    Text("do nothing").tag(nil as Shortcut?)
                    Divider()
                    ShortcutChoiceMenu()
                    DefaultShortcutList()
                },
                label: {
                    HStack {
                        (Text("from  ").round(12, weight: .regular).foregroundColor(.secondary) + Text(source.replacingOccurrences(of: HOME.string, with: "~")).mono(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            )
            Button("\(SwiftUI.Image(systemName: binding.wrappedValue == nil ? "hammer" : "hammer.fill"))") {
                if let url = binding.wrappedValue?.url {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Opens the shortcut in the Shortcuts app for editing")
            .buttonStyle(FlatButton())
            .disabled(binding.wrappedValue == nil)
        }
    }

}

struct DefaultShortcutList: View {
    var body: some View {
        let shortcutNames = SHM.shortcutsMap?.values.joined().map(\.name) ?? []
        Section("Default Shortcuts") {
            let shorts = CLOP_SHORTCUTS.filter { sh in
                !shortcutNames.contains(sh.deletingPathExtension().lastPathComponent)
            }
            ForEach(shorts, id: \.self) { url in
                Text(url.deletingPathExtension().lastPathComponent)
                    .tag(Shortcut(name: url.deletingPathExtension().lastPathComponent, identifier: url.absoluteString))
            }
        }
    }
}

let CLOP_SHORTCUTS = Bundle.main
    .urls(forResourcesWithExtension: "shortcut", subdirectory: nil)!
    .filter { !$0.lastPathComponent.hasPrefix("Clop - ") }
    .sorted(by: \.lastPathComponent)

// MARK: - Step Catalog

struct ParamTemplate {
    let name: String
    let description: String
    let suggestions: [String]
    let freeText: Bool
    var needsQuotes = false
    var valueDescriptions: [String: String] = [:]
    var suggestionsForType: [ClopFileType: [String]] = [:]

    func suggestions(for fileType: ClopFileType) -> [String] {
        suggestionsForType[fileType] ?? suggestions
    }
}

struct StepTemplate {
    let name: String
    let description: String
    let mandatoryParams: [ParamTemplate]
    let optionalParams: [ParamTemplate]
    let applicableTypes: Set<ClopFileType>
    let create: () -> PipelineStep
}

let ALL_STEP_TEMPLATES: [StepTemplate] = [
    StepTemplate(
        name: "optimise", description: "Optimise file size",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(
                name: "encoder",
                description: "compression quality preset",
                suggestions: ["aggressive", "medium", "lossless"],
                freeText: false,
                valueDescriptions: ["aggressive": "smallest file size", "medium": "balanced quality/size", "lossless": "no quality loss"]
            ),
            ParamTemplate(name: "adaptive", description: "auto-pick best format", suggestions: ["true", "false"], freeText: false, valueDescriptions: ["true": "may change file extension", "false": "keep original format"]),
        ],
        applicableTypes: [.image, .video, .pdf, .audio],
        create: { .optimise() }
    ),
    StepTemplate(
        name: "downscale", description: "Scale down by a factor, always keeps aspect ratio",
        mandatoryParams: [
            ParamTemplate(name: "factor", description: "0.0 to 1.0 (e.g. 0.5 = half size, 0.75 = 75%)", suggestions: ["0.5", "0.75", "0.25"], freeText: true),
        ],
        optionalParams: [
            ParamTemplate(
                name: "location",
                description: "where to save the result",
                suggestions: ["inPlace", "sameFolder", "temporaryFolder", "template"],
                freeText: true,
                valueDescriptions: [
                    "inPlace": "replace original file",
                    "sameFolder": "save next to original",
                    "temporaryFolder": "save in temp directory",
                    "template": "custom path with %f (filename), %y (year), etc. Output extension is added automatically",
                ]
            ),
        ],
        applicableTypes: [.image, .video],
        create: { .downscale(factor: 0.5) }
    ),
    StepTemplate(
        name: "convert", description: "Convert to a different format",
        mandatoryParams: [
            ParamTemplate(
                name: "to", description: "target format extension",
                suggestions: ["webp", "avif", "heic", "jpeg", "png", "gif", "mp4", "webm", "m4a", "mp3", "ogg", "flac"],
                freeText: true,
                valueDescriptions: [
                    "webp": "WebP image format",
                    "avif": "AV1 image format",
                    "heic": "HEIC image format",
                    "jpeg": "JPEG image format",
                    "png": "PNG image format",
                    "gif": "animated GIF",
                    "webm": "WebM video (VP9)",
                    "hevc": "MP4 encoded with HEVC/H.265 hardware encoder (fast, battery efficient)",
                    "x265": "MP4 encoded with x265 software encoder (better compression, but slower)",
                    "av1": "AV1 video (libsvtav1)",
                    "mp4": "MP4 video (H.264)",
                    "m4a": "AAC audio",
                    "mp3": "MP3 audio",
                    "ogg": "Ogg Vorbis audio",
                    "flac": "FLAC lossless audio",
                    "wav": "WAV uncompressed audio",
                    "aiff": "AIFF uncompressed audio",
                ],
                suggestionsForType: [
                    .image: ["webp", "avif", "heic", "jpeg", "png", "gif"],
                    .video: ["gif", "webm", "hevc", "x265", "av1"],
                    .audio: ["m4a", "mp3", "ogg", "flac", "wav", "aiff"],
                ]
            ),
        ],
        optionalParams: [
            ParamTemplate(
                name: "location",
                description: "where to save the result",
                suggestions: ["sameFolder", "inPlace", "temporaryFolder", "template"],
                freeText: true,
                valueDescriptions: [
                    "sameFolder": "save next to original",
                    "inPlace": "replace original file",
                    "temporaryFolder": "save in temp directory",
                    "template": "custom path with %f (filename), %y (year), etc. Output extension is added automatically",
                ]
            ),
        ],
        applicableTypes: [.image, .video, .audio],
        create: { .convert(to: "webp") }
    ),
    StepTemplate(
        name: "crop", description: "Resize to exact pixel dimensions",
        mandatoryParams: [
            ParamTemplate(name: "width", description: "max width in pixels, height is computed if not set", suggestions: ["1920", "1600", "1280", "1024", "96"], freeText: true),
        ],
        optionalParams: [
            ParamTemplate(name: "height", description: "max height in pixels, width is computed if not set", suggestions: ["1080", "900", "720", "1024", "96"], freeText: true),
            ParamTemplate(name: "longEdge", description: "target size for longest dimension (use instead of width/height)", suggestions: ["1920", "1600", "1280", "1024", "512"], freeText: true),
            ParamTemplate(name: "keepAspectRatio", description: "maintain proportions", suggestions: ["true", "false"], freeText: false, valueDescriptions: ["true": "maintain proportions", "false": "stretch to exact dimensions"]),
            ParamTemplate(
                name: "location",
                description: "where to save the result",
                suggestions: ["inPlace", "sameFolder", "temporaryFolder", "template"],
                freeText: true,
                valueDescriptions: [
                    "inPlace": "replace original file",
                    "sameFolder": "save next to original",
                    "temporaryFolder": "save in temp directory",
                    "template": "custom path with %f (filename), %y (year), etc. Output extension is added automatically",
                ]
            ),
        ],
        applicableTypes: [.image, .video],
        create: { .crop(width: 1920) }
    ),
    StepTemplate(
        name: "copy", description: "Copy file to a path",
        mandatoryParams: [
            ParamTemplate(name: "to", description: "destination path, supports sourceFolder, sourceFileName, $1, $2", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .copy(to: "") }
    ),
    StepTemplate(
        name: "move", description: "Move file to a path",
        mandatoryParams: [
            ParamTemplate(name: "to", description: "destination path, supports sourceFolder, sourceFileName, $1, $2", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .move(to: "") }
    ),
    StepTemplate(
        name: "rename", description: "Rename the file",
        mandatoryParams: [
            ParamTemplate(name: "to", description: "new name, supports sourceFileName, $1, $2", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .rename(to: "") }
    ),
    StepTemplate(
        name: "delete", description: "Delete a file",
        mandatoryParams: [
            ParamTemplate(name: "path", description: "path to delete, supports %P, %f, %e and other template tokens", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .delete(path: "") }
    ),
    StepTemplate(
        name: "if", description: "Continue pipeline only if condition matches",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(name: "regex", description: "pattern matched against filename, capture groups as $1, $2", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "types", description: "space-separated UTTypes: jpeg png webp heic", suggestions: [], freeText: true),
            ParamTemplate(name: "nameContains", description: "case-insensitive substring match", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "nameIs", description: "exact filename match", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "fileSizeGreaterThan", description: "min file size in bytes", suggestions: [], freeText: true),
            ParamTemplate(name: "fileSizeLowerThan", description: "max file size in bytes", suggestions: [], freeText: true),
            ParamTemplate(name: "widthGreaterThan", description: "min width in pixels", suggestions: [], freeText: true),
            ParamTemplate(name: "widthLowerThan", description: "max width in pixels", suggestions: [], freeText: true),
            ParamTemplate(name: "heightGreaterThan", description: "min height in pixels", suggestions: [], freeText: true),
            ParamTemplate(name: "heightLowerThan", description: "max height in pixels", suggestions: [], freeText: true),
        ],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .filterIf(FilterCondition(regex: "")) }
    ),
    StepTemplate(
        name: "ifNot", description: "Continue pipeline only if condition does NOT match",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(name: "regex", description: "pattern matched against filename", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "types", description: "space-separated UTTypes to exclude", suggestions: [], freeText: true),
            ParamTemplate(name: "nameContains", description: "case-insensitive substring to exclude", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "nameIs", description: "exact filename to exclude", suggestions: [], freeText: true, needsQuotes: true),
        ],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .filterIfNot(FilterCondition(regex: "")) }
    ),
    StepTemplate(
        name: "removeAudio", description: "Strip the audio track",
        mandatoryParams: [],
        optionalParams: [],
        applicableTypes: [.video],
        create: { .removeAudio }
    ),
    StepTemplate(
        name: "changeSpeed", description: "Change playback speed",
        mandatoryParams: [
            ParamTemplate(name: "factor", description: "speed multiplier (e.g. 2.0 = 2x, 0.5 = half speed)", suggestions: ["1.5", "2.0", "0.5", "0.75"], freeText: true),
        ],
        optionalParams: [],
        applicableTypes: [.video, .audio],
        create: { .changeSpeed(factor: 1.5) }
    ),
    StepTemplate(
        name: "runScript", description: "Run a script or executable, input file passed as $1 and CLOP_INPUT_FILE",
        mandatoryParams: [
            ParamTemplate(name: "path", description: "path to script or executable", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .runScript(path: "") }
    ),
    StepTemplate(
        name: "runShortcut", description: "Run a macOS Shortcut",
        mandatoryParams: [
            ParamTemplate(name: "name", description: "shortcut name as shown in Shortcuts.app", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .pdf],
        create: { .runShortcut(Shortcut(name: "", identifier: "")) }
    ),
    StepTemplate(
        name: "copyToClipboard", description: "Copy file reference to clipboard",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(
                name: "format",
                description: "clipboard content format",
                suggestions: ["path", "imageData", "markdown"],
                freeText: false,
                valueDescriptions: ["path": "file path, relative if relativeTo is set", "imageData": "raw image data", "markdown": "markdown link, relative if relativeTo is set"]
            ),
            ParamTemplate(name: "relativeTo", description: "base path, makes output relative (e.g. ~/Projects/blog)", suggestions: [], freeText: true, needsQuotes: true),
        ],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .copyToClipboard() }
    ),
]

func stepTemplates(for fileType: ClopFileType) -> [StepTemplate] {
    ALL_STEP_TEMPLATES.filter { $0.applicableTypes.contains(fileType) }
}

// MARK: - Pipeline Step Parsing

func parsePipelineStep(_ text: String) -> PipelineStep? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)

    // Handle no-param steps
    if trimmed == "removeAudio" { return .removeAudio }

    // Parse name(params) format
    guard let nameRegex = try? NSRegularExpression(pattern: #"^(\w+)(?:\((.+)\))?$"#),
          let match = nameRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
          let nameRange = Range(match.range(at: 1), in: trimmed)
    else { return nil }

    let name = String(trimmed[nameRange])
    let paramsStr = if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: trimmed) {
        String(trimmed[r])
    } else {
        ""
    }

    // Parse comma-separated params, handling key: value and bare values
    let params = parseParams(paramsStr)

    switch name {
    case "optimise":
        let encoder = params["encoder"] ?? "medium"
        return .optimise(encoder: EncoderQuality(rawValue: encoder) ?? .medium, adaptive: params["adaptive"] == "true")

    case "downscale":
        guard let factor = params["factor"].flatMap({ Double($0) }), factor > 0, factor <= 1 else { return nil }
        let location = params["location"] ?? "inPlace"
        return .downscale(factor: factor, location: location)

    case "convert":
        guard let to = params["to"], !to.isEmpty else { return nil }
        let location = params["location"] ?? "sameFolder"
        return .convert(to: to, location: location)

    case "crop":
        let width = params["width"].flatMap { Int($0) }
        let height = params["height"].flatMap { Int($0) }
        let longEdge = params["longEdge"].flatMap { Int($0) }
        guard width != nil || height != nil || longEdge != nil else { return nil }
        let keepAR = params["keepAspectRatio"] != "false"
        let location = params["location"] ?? "inPlace"
        return .crop(width: width, height: height, keepAspectRatio: keepAR, longEdge: longEdge, location: location)

    case "copy":
        guard let to = params["to"], !to.isEmpty else { return nil }
        return .copy(to: to)

    case "move":
        guard let to = params["to"], !to.isEmpty else { return nil }
        return .move(to: to)

    case "rename":
        guard let to = params["to"], !to.isEmpty else { return nil }
        return .rename(to: to)

    case "delete":
        guard let path = params["path"], !path.isEmpty else { return nil }
        return .delete(path: path)

    case "if":
        let condition = parseFilterCondition(params)
        guard !condition.isEmpty else { return nil }
        return .filterIf(condition)

    case "ifNot":
        let condition = parseFilterCondition(params)
        guard !condition.isEmpty else { return nil }
        return .filterIfNot(condition)

    case "changeSpeed":
        guard let factor = params["factor"].flatMap({ Double($0) }) else { return nil }
        return .changeSpeed(factor: factor)

    case "runScript":
        guard let scriptPath = params["path"], !scriptPath.isEmpty else { return nil }
        return .runScript(path: scriptPath)

    case "runShortcut":
        guard let shortcutName = params["name"], !shortcutName.isEmpty else { return nil }
        let shortcuts = SHM.shortcutsMap?.values.flatMap { $0 } ?? []
        let shortcut = shortcuts.first(where: { $0.name == shortcutName }) ?? Shortcut(name: shortcutName, identifier: shortcutName)
        return .runShortcut(shortcut)

    case "copyToClipboard":
        let format = ClipboardCopyFormat(rawValue: params["format"] ?? "path") ?? .path
        let relativeTo = params["relativeTo"]
        return .copyToClipboard(format: format, relativeTo: relativeTo)

    default:
        return nil
    }
}

private func parseParams(_ str: String) -> [String: String] {
    guard !str.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for part in str.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        let kv = part.split(separator: ":", maxSplits: 1)
        guard kv.count == 2 else { continue }
        let key = kv[0].trimmingCharacters(in: .whitespaces)
        let value = kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        result[key] = value
    }
    return result
}

private func parseFilterCondition(_ params: [String: String]) -> FilterCondition {
    FilterCondition(
        types: params["types"]?.split(separator: " ").map(String.init),
        regex: params["regex"],
        nameContains: params["nameContains"],
        nameIs: params["nameIs"],
        fileSizeGreaterThan: params["fileSizeGreaterThan"].flatMap { Int($0) },
        fileSizeLowerThan: params["fileSizeLowerThan"].flatMap { Int($0) },
        widthGreaterThan: params["widthGreaterThan"].flatMap { Int($0) },
        widthLowerThan: params["widthLowerThan"].flatMap { Int($0) },
        heightGreaterThan: params["heightGreaterThan"].flatMap { Int($0) },
        heightLowerThan: params["heightLowerThan"].flatMap { Int($0) }
    )
}

// MARK: - Pipeline Text Completions

struct CompletionSuggestion: Identifiable {
    let id = UUID()
    let insertText: String
    let displayText: String
    let details: String
    let color: Color
    let opensParens: Bool
    var needsQuotes = false
    var isTemplateVar = false
}

struct TemplateVariable {
    let token: String
    let name: String
    let description: String
}

let TEMPLATE_VARIABLES: [TemplateVariable] = [
    TemplateVariable(token: "%f", name: "filename", description: "source file name without extension"),
    TemplateVariable(token: "%e", name: "extension", description: "source file extension without dot (note: output extension is always added automatically)"),
    TemplateVariable(token: "%P", name: "path", description: "source file directory path"),
    TemplateVariable(token: "%F", name: "fullPath", description: "full source file path including filename"),
    TemplateVariable(token: "%y", name: "year", description: "current year (e.g. 2026)"),
    TemplateVariable(token: "%m", name: "month", description: "month number (01-12)"),
    TemplateVariable(token: "%n", name: "monthName", description: "month name (e.g. March)"),
    TemplateVariable(token: "%d", name: "day", description: "day of month (01-31)"),
    TemplateVariable(token: "%w", name: "weekday", description: "day of week (e.g. Friday)"),
    TemplateVariable(token: "%H", name: "hour", description: "hour (00-23)"),
    TemplateVariable(token: "%M", name: "minutes", description: "minutes (00-59)"),
    TemplateVariable(token: "%S", name: "seconds", description: "seconds (00-59)"),
    TemplateVariable(token: "%p", name: "amPm", description: "AM or PM"),
    TemplateVariable(token: "%r", name: "random", description: "random characters"),
    TemplateVariable(token: "%i", name: "counter", description: "auto-incrementing number"),
]

/// Determines context from the prefix and returns appropriate suggestions.
/// - Step name context: shows step names with descriptions
/// - Param list context: shows param names with descriptions
/// - Param value context: shows values for the specific param
func pipelineSuggestions(prefix: String, fileType: ClopFileType) -> [CompletionSuggestion] {
    let templates = stepTemplates(for: fileType)
    let trimmed = prefix.trimmingCharacters(in: .whitespaces)

    // Inside parentheses -> show param suggestions
    if let openParen = trimmed.firstIndex(of: "(") {
        let stepName = String(trimmed[..<openParen])
        guard let template = templates.first(where: { $0.name == stepName }) else { return [] }

        let step = template.create()
        let afterParen = String(trimmed[trimmed.index(after: openParen)...])
        let parts = afterParen.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let lastPart = parts.last ?? ""

        // Already-used param names
        let usedNames = Set(parts.dropLast().compactMap { p in
            p.contains(":") ? String(p.split(separator: ":")[0]).trimmingCharacters(in: .whitespaces) : nil
        })
        // Also include the current part if it has a colon and a value
        let allParams = template.mandatoryParams + template.optionalParams

        if lastPart.contains(":") {
            // User typed "paramName:" or "paramName: val" -> show values for this param
            let colonIdx = lastPart.firstIndex(of: ":")!
            let paramName = String(lastPart[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let typedValue = String(lastPart[lastPart.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            guard let param = allParams.first(where: { $0.name == paramName }) else { return [] }

            // Inside quotes and typing % -> show template variables
            let insideQuotes = typedValue.hasPrefix("\"")
            let unquotedValue = insideQuotes ? String(typedValue.dropFirst()) : typedValue
            if insideQuotes, unquotedValue.contains("%") {
                let afterPercent = String(unquotedValue.suffix(from: unquotedValue.lastIndex(of: "%")!).dropFirst())
                return TEMPLATE_VARIABLES
                    .filter { afterPercent.isEmpty || $0.token.dropFirst().hasPrefix(afterPercent) || $0.name.lowercased().hasPrefix(afterPercent.lowercased()) }
                    .map { tv in
                        CompletionSuggestion(
                            insertText: tv.token,
                            displayText: tv.token,
                            details: tv.description,
                            color: step.category.swiftUIColor,
                            opensParens: false,
                            isTemplateVar: true
                        )
                    }
            }

            let paramSuggestions = param.suggestions(for: fileType)
            let suggestions = paramSuggestions
                .filter { typedValue.isEmpty || $0.lowercased().hasPrefix(typedValue.lowercased()) }
                .map { value in
                    CompletionSuggestion(
                        insertText: value,
                        displayText: value,
                        details: param.valueDescriptions[value] ?? param.description,
                        color: step.category.swiftUIColor,
                        opensParens: false,
                        needsQuotes: value == "template"
                    )
                }

            if suggestions.isEmpty, paramSuggestions.isEmpty { return [] }
            return suggestions
        } else {
            // Show available param names, filtered by what user is typing
            return allParams
                .filter { !usedNames.contains($0.name) }
                .filter { lastPart.isEmpty || $0.name.lowercased().hasPrefix(lastPart.lowercased()) || $0.name.lowercased().contains(lastPart.lowercased()) }
                .map { param in
                    CompletionSuggestion(
                        insertText: "\(param.name): ",
                        displayText: param.name,
                        details: param.description,
                        color: step.category.swiftUIColor,
                        opensParens: false,
                        needsQuotes: param.needsQuotes
                    )
                }
        }
    }

    // Typing step name (or empty)
    let lowered = trimmed.lowercased()
    return templates
        .filter { lowered.isEmpty || $0.name.lowercased().hasPrefix(lowered) || $0.name.lowercased().contains(lowered) }
        .map { template in
            let step = template.create()
            let hasParams = !template.mandatoryParams.isEmpty || !template.optionalParams.isEmpty
            // For steps with a single mandatory param, auto-include the param name
            let singleMandatory = template.mandatoryParams.count == 1 && template.optionalParams.isEmpty
            let quotes = singleMandatory && template.mandatoryParams[0].needsQuotes
            let insertText = if singleMandatory {
                "\(template.name)(\(template.mandatoryParams[0].name): " + (quotes ? "\"" : "")
            } else {
                template.name
            }
            return CompletionSuggestion(
                insertText: insertText,
                displayText: template.name,
                details: template.description,
                color: step.category.swiftUIColor,
                opensParens: hasParams && !singleMandatory,
                needsQuotes: quotes
            )
        }
}

extension StepCategory {
    var swiftUIColor: Color {
        switch self {
        case .processing: .blue
        case .fileOperation: .green
        case .filter: .orange
        case .mediaSpecific: .teal
        case .action: .purple
        }
    }
}

// MARK: - Step Action Grid

struct StepActionGrid: View {
    let fileType: ClopFileType
    let onSelect: (String) -> Void

    var templates: [StepTemplate] {
        stepTemplates(for: fileType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Possible actions")
                .dimmed(9, weight: .medium)
            FlowLayout(spacing: 4) {
                ForEach(templates, id: \.name) { template in
                    let color = colorForCategory(template)
                    Button(action: {
                        let hasParams = !template.mandatoryParams.isEmpty || !template.optionalParams.isEmpty
                        let singleMandatory = template.mandatoryParams.count == 1 && template.optionalParams.isEmpty
                        let text = if singleMandatory {
                            "\(template.name)(\(template.mandatoryParams[0].name): "
                        } else if hasParams {
                            "\(template.name)("
                        } else {
                            template.create().displayString
                        }
                        onSelect(text)
                    }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color)
                                .frame(width: 6, height: 6)
                            Text(template.name)
                                .mono(10, weight: .medium)
                        }
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(color.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(color.opacity(0.2), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(template.description)
                }
            }
        }
    }

    func colorForCategory(_ template: StepTemplate) -> Color {
        let step = template.create()
        switch step.category {
        case .processing: return .blue
        case .fileOperation: return .green
        case .filter: return .orange
        case .mediaSpecific: return .teal
        case .action: return .purple
        }
    }
}

/// A simple flow layout that wraps items to the next line when they exceed the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Pipeline Syntax Highlighting

private let PIPELINE_FONT = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
private let PIPELINE_FONT_BOLD = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

func highlightPipelineText(_ text: String, fileType: ClopFileType) -> NSAttributedString {
    let font = PIPELINE_FONT
    let baseAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
    ]
    let result = NSMutableAttributedString(string: text, attributes: baseAttrs)
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)

    // Color arrow separators
    let arrowRegex = try! NSRegularExpression(pattern: #"->"#)
    for match in arrowRegex.matches(in: text, range: fullRange) {
        result.addAttributes([
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.4),
        ], range: match.range)
    }

    // Split into step segments (between -> and newlines)
    let sepRegex = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
    let sepMatches = sepRegex.matches(in: text, range: fullRange)

    var segmentRanges: [NSRange] = []
    var start = 0
    for match in sepMatches {
        if match.range.location > start {
            segmentRanges.append(NSRange(location: start, length: match.range.location - start))
        }
        start = match.range.location + match.range.length
    }
    if start < nsText.length {
        segmentRanges.append(NSRange(location: start, length: nsText.length - start))
    }

    let templates = stepTemplates(for: fileType)
    let templateNames = Set(templates.map(\.name))

    for segRange in segmentRanges {
        let segText = nsText.substring(with: segRange).trimmingCharacters(in: .whitespaces)
        guard !segText.isEmpty else { continue }

        // Find the trimmed text position within the segment
        let trimmedRange = nsText.range(of: segText, range: segRange)
        guard trimmedRange.location != NSNotFound else { continue }

        // Extract step name
        let parenIndex = segText.firstIndex(of: "(")
        let stepName = parenIndex != nil ? String(segText[..<parenIndex!]) : segText

        if let template = templates.first(where: { $0.name == stepName }) {
            let step = template.create()
            let color = step.categoryNSColor

            // Color step name bold
            let nameRange = NSRange(location: trimmedRange.location, length: stepName.utf16.count)
            result.addAttributes([
                .foregroundColor: color,
                .font: PIPELINE_FONT_BOLD,
            ], range: nameRange)

            // Color params: dim param names, prominent param values
            if stepName.count < segText.count {
                let paramsStr = String(segText[segText.index(segText.startIndex, offsetBy: stepName.count)...])
                let paramsStart = trimmedRange.location + stepName.utf16.count

                // Default: dim everything in parens (parens, commas, colons)
                let paramsRange = NSRange(location: paramsStart, length: trimmedRange.length - stepName.utf16.count)
                result.addAttributes([
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.8),
                    .font: font,
                ], range: paramsRange)

                // Now highlight individual param values more prominently
                let paramPattern = try! NSRegularExpression(pattern: #"(\w+):\s*([^,\)]+)"#)
                let paramsNS = paramsStr as NSString
                let hsbColor = color.usingColorSpace(.displayP3) ?? color
                for match in paramPattern.matches(in: paramsStr, range: NSRange(location: 0, length: paramsNS.length)) {
                    // Param name: visible but secondary
                    let nameMatchRange = match.range(at: 1)
                    if nameMatchRange.location != NSNotFound {
                        let absRange = NSRange(location: paramsStart + nameMatchRange.location, length: nameMatchRange.length)
                        result.addAttributes([
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ], range: absRange)
                    }
                    // Param value: prominent with hue shift and boosted saturation
                    let valueMatchRange = match.range(at: 2)
                    if valueMatchRange.location != NSNotFound {
                        let valueStr = paramsNS.substring(with: valueMatchRange).trimmingCharacters(in: .whitespaces)
                        let trimmedValueRange = NSRange(
                            location: paramsStart + valueMatchRange.location + (valueMatchRange.length - valueStr.utf16.count),
                            length: valueStr.utf16.count
                        )
                        // Determine whether the system appearance is dark. We can't access SwiftUI's @Environment here,
                        // so use AppKit's effectiveAppearance to decide brightness adjustments.
                        let isDarkMode: Bool = {
                            if let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
                                return match == .darkAqua
                            }
                            return false
                        }()

                        // Check if this param value is invalid for the current file type
                        let paramNameStr = paramsNS.substring(with: nameMatchRange)
                        let allParams = template.mandatoryParams + template.optionalParams
                        let paramTemplate = allParams.first(where: { $0.name == paramNameStr })
                        let typeSpecific = paramTemplate?.suggestionsForType[fileType]
                        let unquotedValue = valueStr.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        let isInvalidValue = typeSpecific != nil && !typeSpecific!.contains(unquotedValue)

                        if isInvalidValue {
                            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                            result.addAttributes([
                                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7),
                                .font: italicFont,
                            ], range: trimmedValueRange)
                        } else {
                            let valueSatColor = NSColor(
                                hue: fmod(hsbColor.hueComponent + 0.01, 1.0),
                                saturation: min(hsbColor.saturationComponent * 0.8, 1.0),
                                brightness: min(hsbColor.brightnessComponent * (isDarkMode ? 1.1 : 0.6), 1.0),
                                alpha: 0.95
                            )
                            result.addAttributes([
                                .foregroundColor: valueSatColor,
                                .font: PIPELINE_FONT_BOLD,
                            ], range: trimmedValueRange)
                        }
                    }
                }
            }
        } else if !segText.isEmpty, !templateNames.contains(segText) {
            // Invalid step
            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            result.addAttributes([
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7),
                .font: italicFont,
            ], range: trimmedRange)
        }
    }

    return result
}

// MARK: - Pipeline Text View (NSTextView wrapper)

struct PipelineTextView: NSViewRepresentable {
    class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        init(_ parent: PipelineTextView) { self.parent = parent }

        var parent: PipelineTextView
        weak var textView: NSTextView?
        var isEditing = false
        var isHighlighting = false
        var endEditingWorkItem: DispatchWorkItem?
        var lastAppearanceName: NSAppearance.Name?

        func textDidBeginEditing(_ notification: Notification) {
            endEditingWorkItem?.cancel()
            endEditingWorkItem = nil
            isEditing = true
            parent.onEditingChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false

            // Clean up trailing arrow/whitespace
            if let textView {
                var cleaned = textView.string
                cleaned = cleaned.replacingOccurrences(of: #"\s*->\s*$"#, with: "", options: .regularExpression)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                textView.string = cleaned
                parent.text = cleaned
            }
            applySyntaxHighlighting()
            parent.onPrefixChanged?("")

            // Delay dismiss so button clicks in the suggestion/grid area can fire first
            endEditingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.endEditingWorkItem = nil
                self?.parent.onEditingChanged?(false)
            }
            endEditingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }

        func textDidChange(_ notification: Notification) {
            guard !isHighlighting, let textView else { return }

            // Auto-insert " -> " when user types after a closing paren without an arrow
            autoInsertArrow(in: textView)

            parent.text = textView.string
            applySyntaxHighlighting()
            updateCompletionPrefix()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if isEditing { updateCompletionPrefix() }
        }

        // MARK: - Line breaking

        func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
            guard let text = layoutManager.textStorage?.string else { return true }
            let nsText = text as NSString
            // Allow break only right before " -> " (so the arrow starts the next line)
            if charIndex + 3 <= nsText.length {
                let ahead = nsText.substring(with: NSRange(location: charIndex, length: 3))
                if ahead == "-> " || ahead == " ->" { return true }
            }
            return false
        }

        // MARK: - Key handling

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleEnter(textView)
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return handleTab(textView)
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishEditing(in: textView)
                return true
            }
            return false
        }

        // MARK: - Insertion

        /// Insert a completion suggestion at the current cursor position.
        func insertSuggestion(_ suggestion: CompletionSuggestion, in textView: NSTextView? = nil) {
            guard let textView = textView ?? self.textView else { return }
            let cursor = textView.selectedRange().location
            let text = textView.string
            let beforeCursor = String(text.prefix(cursor))

            let openCount = beforeCursor.filter { $0 == "(" }.count
            let closeCount = beforeCursor.filter { $0 == ")" }.count
            let insideParens = openCount > closeCount

            if insideParens {
                // Inside parens: figure out what to replace based on suggestion type
                let lastOpenParen: Int = beforeCursor.lastIndex(of: "(").map { beforeCursor.distance(from: beforeCursor.startIndex, to: $0) + 1 } ?? 0
                let lastComma: Int = beforeCursor.lastIndex(of: ",").map { beforeCursor.distance(from: beforeCursor.startIndex, to: $0) + 1 } ?? 0
                let lastSep = max(lastOpenParen, lastComma)
                let currentPart = String(beforeCursor.suffix(from: beforeCursor.index(beforeCursor.startIndex, offsetBy: lastSep)))

                if suggestion.isTemplateVar {
                    // Template variable: replace only the partial "%" at cursor, don't touch the rest
                    let percentPos = beforeCursor.lastIndex(of: "%")
                        .map { beforeCursor.distance(from: beforeCursor.startIndex, to: $0) } ?? cursor
                    let replaceRange = NSRange(location: percentPos, length: cursor - percentPos)
                    textView.replaceCharacters(in: replaceRange, with: suggestion.insertText)
                } else if currentPart.contains(":"), suggestion.needsQuotes {
                    // Value that needs quotes (e.g. "template"): replace value with "" and cursor inside
                    let colonPos = beforeCursor.lastIndex(of: ":")!
                    let replaceStart = beforeCursor.distance(from: beforeCursor.startIndex, to: colonPos) + 1
                    let replaceRange = NSRange(location: replaceStart, length: cursor - replaceStart)
                    textView.replaceCharacters(in: replaceRange, with: " \"\"")
                    let cursorPos = replaceStart + 2 // after the opening quote
                    textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                } else if currentPart.contains(":") {
                    // Completing a value after "paramName: partial" -> only replace after the colon
                    let colonPos = beforeCursor.lastIndex(of: ":")!
                    let replaceStart = beforeCursor.distance(from: beforeCursor.startIndex, to: colonPos) + 1
                    let replaceRange = NSRange(location: replaceStart, length: cursor - replaceStart)
                    textView.replaceCharacters(in: replaceRange, with: " " + suggestion.insertText + ", ")
                } else {
                    // Completing a param name -> replace from last separator
                    let replaceRange = NSRange(location: lastSep, length: cursor - lastSep)
                    let afterOpenParen = lastSep > 0 && beforeCursor[beforeCursor.index(beforeCursor.startIndex, offsetBy: lastSep - 1)] == "("
                    let prefix = afterOpenParen ? "" : " "
                    let suffix = suggestion.needsQuotes ? "\"\"" : ""
                    textView.replaceCharacters(in: replaceRange, with: prefix + suggestion.insertText + suffix)
                    if suggestion.needsQuotes {
                        // Place cursor between quotes: `paramName: "|"`
                        let cursorPos = lastSep + (prefix + suggestion.insertText).utf16.count + 1
                        textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                    }
                }
            } else {
                // Outside parens: replace current step segment
                let sepPattern = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
                let beforeMatches = sepPattern.matches(in: beforeCursor, range: NSRange(location: 0, length: beforeCursor.utf16.count))
                var segStart = beforeMatches.last.map { NSMaxRange($0.range) } ?? 0

                let nsText = text as NSString

                // Skip whitespace after separator so we don't eat the space in " -> "
                while segStart < nsText.length, nsText.substring(with: NSRange(location: segStart, length: 1)) == " " {
                    segStart += 1
                }

                let afterRange = NSRange(location: cursor, length: nsText.length - cursor)
                let afterMatches = sepPattern.matches(in: text, range: afterRange)
                let segEnd = afterMatches.first?.range.location ?? nsText.length

                let replaceRange = NSRange(location: segStart, length: segEnd - segStart)
                var insertText = suggestion.opensParens ? suggestion.insertText + "(" : suggestion.insertText
                if suggestion.needsQuotes, !suggestion.opensParens {
                    // Single mandatory param with quotes: `copy(to: "|")`
                    insertText += "\""
                }
                textView.replaceCharacters(in: replaceRange, with: insertText)
                if suggestion.needsQuotes, !suggestion.opensParens {
                    // Place cursor between quotes
                    let cursorPos = segStart + insertText.utf16.count - 1
                    textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                }
            }

            parent.text = textView.string
            applySyntaxHighlighting()
            updateCompletionPrefix()
        }

        /// Append a step at the end of the pipeline text.
        func appendStep(_ stepText: String) {
            guard let textView else { return }

            let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                textView.string = stepText
            } else {
                textView.string = trimmed + " -> " + stepText
            }
            parent.text = textView.string
            applySyntaxHighlighting()

            // Move cursor to end
            let endPos = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            updateCompletionPrefix()
        }

        /// Refocus the text view after an external button click.
        func refocus() {
            endEditingWorkItem?.cancel()
            endEditingWorkItem = nil
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            isEditing = true
            parent.onEditingChanged?(true)
        }

        // MARK: - Highlighting

        func applySyntaxHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let selectedRanges = textView.selectedRanges
            let highlighted = highlightPipelineText(textView.string, fileType: parent.fileType)

            storage.beginEditing()
            storage.setAttributedString(highlighted)
            storage.endEditing()

            textView.selectedRanges = selectedRanges
        }

        func updateCompletionPrefix() {
            guard let textView else { return }
            let prefix = extractCurrentStepPrefix(text: textView.string, cursor: textView.selectedRange().location)
            parent.onPrefixChanged?(prefix)
        }

        /// If the user typed a letter after `)` (with optional spaces) without ` -> `, insert the arrow.
        private func autoInsertArrow(in textView: NSTextView) {
            let text = textView.string
            let cursor = textView.selectedRange().location
            guard cursor >= 2 else { return }

            let nsText = text as NSString

            // The just-typed character must be a letter
            let typedChar = nsText.substring(with: NSRange(location: cursor - 1, length: 1))
            guard typedChar.rangeOfCharacter(from: .letters) != nil else { return }

            // Walk backwards from cursor-2 to find `)`, skipping spaces
            var pos = cursor - 2
            while pos >= 0, nsText.substring(with: NSRange(location: pos, length: 1)) == " " {
                pos -= 1
            }
            guard pos >= 0, nsText.substring(with: NSRange(location: pos, length: 1)) == ")" else { return }

            // Also make sure there isn't already a `->` between `)` and the typed char
            let between = nsText.substring(with: NSRange(location: pos + 1, length: cursor - 1 - (pos + 1)))
            guard !between.contains("->") else { return }

            // Replace spaces between ) and the typed char with " -> "
            let replaceRange = NSRange(location: pos + 1, length: cursor - 1 - (pos + 1))
            textView.replaceCharacters(in: replaceRange, with: " -> ")
            let newCursor = pos + 1 + 5 // after ") -> " then the typed char is already at +5
            textView.setSelectedRange(NSRange(location: newCursor, length: 0))
        }

        private func handleTab(_ textView: NSTextView) -> Bool {
            let prefix = extractCurrentStepPrefix(text: textView.string, cursor: textView.selectedRange().location)
            let suggestions = pipelineSuggestions(prefix: prefix, fileType: parent.fileType)

            if suggestions.isEmpty {
                // No suggestions left - if inside parens, all params used, commit step
                let cursor = textView.selectedRange().location
                let beforeCursor = String(textView.string.prefix(cursor))
                let insideParens = beforeCursor.filter { $0 == "(" }.count > beforeCursor.filter { $0 == ")" }.count
                if insideParens {
                    commitCurrentStep(in: textView)
                }
                return true
            }

            let suggestion = suggestions.first!
            insertSuggestion(suggestion, in: textView)

            // After inserting a param value, check if all params are now used
            let isParamValue = !suggestion.opensParens && !suggestion.needsQuotes && !suggestion.insertText.hasSuffix(": ") && !suggestion.isTemplateVar
            if isParamValue {
                checkAutoCloseParens(in: textView)
            }
            return true
        }

        private func handleEnter(_ textView: NSTextView) -> Bool {
            let cursor = textView.selectedRange().location
            let text = textView.string

            // Check if cursor is inside parentheses
            let beforeCursor = String(text.prefix(cursor))
            let openCount = beforeCursor.filter { $0 == "(" }.count
            let closeCount = beforeCursor.filter { $0 == ")" }.count

            if openCount > closeCount {
                // Inside parens: commit step, close parens, add ->
                commitCurrentStep(in: textView)
            } else {
                finishEditing(in: textView)
            }
            return true
        }

        /// Clean up trailing arrow/whitespace and exit editing.
        private func finishEditing(in textView: NSTextView) {
            var cleaned = textView.string
            cleaned = cleaned.replacingOccurrences(of: #"\s*->\s*$"#, with: "", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            textView.string = cleaned
            parent.text = cleaned
            applySyntaxHighlighting()
            textView.window?.makeFirstResponder(nil)
        }

        /// Close the current step's parens, clean up trailing commas, add ` -> `.
        private func commitCurrentStep(in textView: NSTextView) {
            var text = textView.string
            let cursor = textView.selectedRange().location

            // Find the unclosed open paren
            let beforeCursor = String(text.prefix(cursor))
            guard let openParenIdx = beforeCursor.lastIndex(of: "(") else { return }
            let openPos = beforeCursor.distance(from: beforeCursor.startIndex, to: openParenIdx)

            // Find end of current step segment (next -> or end of text)
            let nsText = text as NSString
            let sepPattern = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
            let afterOpen = NSRange(location: openPos, length: nsText.length - openPos)
            let segEnd = sepPattern.firstMatch(in: text, range: afterOpen)?.range.location ?? nsText.length

            // Get content inside parens (from open paren to segment end)
            let insideStart = text.index(text.startIndex, offsetBy: openPos + 1)
            let insideEnd = text.index(text.startIndex, offsetBy: segEnd)
            var inside = String(text[insideStart ..< insideEnd])

            // Clean trailing comma, whitespace, unclosed quotes, existing close parens
            inside = inside.replacingOccurrences(of: #"[,\s\)]*$"#, with: "", options: .regularExpression)
            // Ensure balanced quotes
            let quoteCount = inside.filter { $0 == "\"" }.count
            if quoteCount % 2 != 0 { inside += "\"" }

            // Rebuild: everything before open paren + (inside) + -> + rest after segment end
            let before = String(text.prefix(openPos + 1))
            let after = segEnd < nsText.length ? String(text.suffix(from: text.index(text.startIndex, offsetBy: segEnd))) : ""
            text = before + inside + ")" + after + " -> "

            textView.string = text
            parent.text = text
            applySyntaxHighlighting()

            // Move cursor to end (after the ->)
            let endPos = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            updateCompletionPrefix()
        }

        /// After inserting a param value, check if all params for the current step are used.
        /// If so, auto-close parens and move to next step.
        private func checkAutoCloseParens(in textView: NSTextView) {
            let prefix = extractCurrentStepPrefix(text: textView.string, cursor: textView.selectedRange().location)
            let remaining = pipelineSuggestions(prefix: prefix, fileType: parent.fileType)
            if remaining.isEmpty {
                // All params used - commit
                commitCurrentStep(in: textView)
            }
        }

    }

    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    let fileType: ClopFileType
    let placeholder: String
    var onEditingChanged: ((Bool) -> Void)?
    var onPrefixChanged: ((String) -> Void)?
    var coordinatorRef: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = PIPELINE_FONT
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 3)
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        textView.layoutManager?.delegate = context.coordinator
        coordinatorRef?(context.coordinator)

        // Initial content
        textView.string = text
        context.coordinator.applySyntaxHighlighting()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        let currentAppearance = nsView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let appearanceChanged = currentAppearance != context.coordinator.lastAppearanceName
        if appearanceChanged {
            context.coordinator.lastAppearanceName = currentAppearance
        }

        // Don't stomp while user is editing or during delayed dismiss
        guard !context.coordinator.isEditing, context.coordinator.endEditingWorkItem == nil else { return }

        if textView.string != text {
            textView.string = text
            context.coordinator.applySyntaxHighlighting()
        } else if appearanceChanged {
            context.coordinator.applySyntaxHighlighting()
        }
    }

}

private func extractCurrentStepPrefix(text: String, cursor: Int) -> String {
    let nsText = text as NSString
    guard cursor <= nsText.length else { return "" }

    let beforeCursor = nsText.substring(to: cursor)

    // Find last separator (-> or newline)
    let sepPattern = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
    let matches = sepPattern.matches(in: beforeCursor, range: NSRange(location: 0, length: beforeCursor.utf16.count))

    let stepStart: Int = if let lastMatch = matches.last {
        NSMaxRange(lastMatch.range)
    } else {
        0
    }

    return nsText.substring(with: NSRange(location: stepStart, length: cursor - stepStart))
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - Completion Panel

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

    var sourceIcon: String {
        switch source {
        case .clipboard: "doc.on.clipboard"
        case .dropZone: "square.dashed"
        default: "folder"
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
                SwiftUI.Image(systemName: "plus.circle.fill")
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
                    .mono(11, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                addPipelineMenu
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
                .offset(x: -20, y: 42)
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

    @State var addedFolders: Set<String> = []
    @State var editingKey: String? = nil

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
                    editingKey: $editingKey
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
                    fileType: pipeline.fileType ?? .image,
                    placeholder: "Pipeline steps...",
                    coordinatorRef: { coordHolder.value = $0 }
                )
                .frame(minHeight: 26, maxHeight: 80)
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

struct AutomationSettingsView: View {
    @Default(.pipelinesToRunOnImage) var imagePipelines
    @Default(.pipelinesToRunOnVideo) var videoPipelines
    @Default(.pipelinesToRunOnPdf) var pdfPipelines
    @Default(.pipelinesToRunOnAudio) var audioPipelines
    @Default(.savedPipelines) var savedPipelines

    var body: some View {
        Form {
            Section(header: SectionHeader(
                title: "Automation",
                subtitle: "Automatically run actions on files after (or before) optimisation: convert, crop, copy, rename and more\nType an action name and press Tab to fill in, Enter to finish"
            )) {
                PipelineTypeSectionView(fileType: .image, pipelines: $imagePipelines)
                Divider()
                PipelineTypeSectionView(fileType: .video, pipelines: $videoPipelines)
                Divider()
                PipelineTypeSectionView(fileType: .audio, pipelines: $audioPipelines)
                Divider()
                PipelineTypeSectionView(fileType: .pdf, pipelines: $pdfPipelines)
            }

            if !savedPipelines.isEmpty {
                Section(header: SectionHeader(
                    title: "Saved Pipelines",
                    subtitle: "Reusable pipelines available in automation, preset zones and right-click menus"
                )) {
                    let grouped: [(String, ClopFileType?, [Pipeline])] = {
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
                    }()

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

struct AutomationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AutomationSettingsView()
            .frame(minWidth: 850, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .formStyle(.grouped)
    }
}

class ShortcutsManager: ObservableObject {
    init() {
        guard !SWIFTUI_PREVIEW else { return }
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
            }
        }
    }

    @Published var shortcutsMap: [String: [Shortcut]]? = !SWIFTUI_PREVIEW
        ? nil
        : [
            "Clop": [
                Shortcut(name: "Change video playback speed by 1.5x", identifier: "F2185611-9E75-4FC1-A4D1-67DB58B35992"),
                Shortcut(name: "Limit media size", identifier: "F1185611-9E75-4FC1-A4D1-67DB58B35992"),
                Shortcut(name: "Convert to WEBP", identifier: "FA6F8F4F-ACEB-4BCC-8F25-A6E5CC3BB46D"),
                Shortcut(name: "Blog images", identifier: "F28D4833-C074-48B2-BA85-A582F4940F5D"),
                Shortcut(name: "Menubar Icon", identifier: "666F6660-0B12-4628-A88B-A53899D6F39C"),
            ],
        ]
    @Published var cacheIsValid = true

    func invalidateCache() {
        guard !SWIFTUI_PREVIEW else { return }
        cacheIsValid = false
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil
    }

    func fetch() {
        guard !SWIFTUI_PREVIEW else { return }
        DispatchQueue.global().async { [self] in
            let shortcutsMap = getShortcutsMapOrCached()
            mainActor {
                self.shortcutsMap = shortcutsMap
                self.cacheIsValid = true
            }
        }
    }

    func refetch() {
        guard !SWIFTUI_PREVIEW else { return }
        if shortcutsCacheByFolder.isNotEmpty {
            shortcutsCacheByFolder = [:]
        }
        shortcutsMapCache = nil

        fetch()
    }
}

let SHM = ShortcutsManager()
