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
    static let builtinPipelinesSeededVersion = Key<Int>("builtinPipelinesSeededVersion", default: 0)
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
    log.debug("Migrated shortcuts to pipelines: images=\(imagePipelines.count), videos=\(videoPipelines.count), pdfs=\(pdfPipelines.count)")
}

// MARK: - Step Catalog

struct ParamTemplate {
    let name: String
    let description: String
    let suggestions: [String]
    let freeText: Bool
    var needsQuotes = false
    var valueDescriptions: [String: String] = [:]
    var valueDescriptionsForType: [ClopFileType: [String: String]] = [:]
    var suggestionsForType: [ClopFileType: [String]] = [:]
    /// When set, the param is only suggested for these file types. nil means it
    /// applies to every file type (and to "any-type" library pipelines).
    var applicableTypes: Set<ClopFileType>?

    func suggestions(for fileType: ClopFileType?) -> [String] {
        guard let fileType else { return suggestions }
        return suggestionsForType[fileType] ?? suggestions
    }

    func valueDescriptions(for fileType: ClopFileType?) -> [String: String] {
        guard let fileType else { return valueDescriptions }
        return valueDescriptionsForType[fileType] ?? valueDescriptions
    }

    func applies(to fileType: ClopFileType?) -> Bool {
        guard let applicableTypes else { return true }
        guard let fileType else { return true }
        return applicableTypes.contains(fileType)
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

struct InstalledAppsInfo {
    let names: [String]
    let descriptions: [String: String]
}

private var _installedAppsCache: InstalledAppsInfo?

private func installedApps() -> InstalledAppsInfo {
    if let cache = _installedAppsCache { return cache }

    var descriptions = [String: String]()
    let fm = FileManager.default
    let searchPaths = ["/Applications", "\(NSHomeDirectory())/Applications"]

    for base in searchPaths {
        guard let enumerator = fm.enumerator(atPath: base) else { continue }
        while let path = enumerator.nextObject() as? String {
            guard path.hasSuffix(".app") else { continue }
            enumerator.skipDescendants()
            let fullPath = "\(base)/\(path)"
            guard isAppPathRelevant(fullPath) else { continue }
            guard let bundle = Bundle(path: fullPath) else { continue }
            let name = bundle.name
            let bundleID = bundle.bundleIdentifier ?? "unknown"
            descriptions[name] = "\(name) (\(bundleID))"
        }
    }

    let result = InstalledAppsInfo(names: descriptions.keys.sorted(), descriptions: descriptions)
    _installedAppsCache = result
    return result
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
                valueDescriptions: ["aggressive": "smallest file size", "medium": "balanced quality/size", "lossless": "no quality loss"],
                valueDescriptionsForType: [
                    .video: ["fast": "hardware encoder, quick and battery efficient", "slowHighQuality": "slow software encoder, smaller files", "visuallyLossless": "no perceptible quality loss (CRF 17)"],
                    .pdf: [
                        "aggressive": "lossy + downsample images to 100 DPI",
                        "medium": "adaptive downsampling, picks DPI per PDF based on embedded image resolutions",
                        "lossless": "no downsampling, preserves embedded image resolution",
                    ],
                ],
                suggestionsForType: [
                    .video: ["fast", "slowHighQuality", "visuallyLossless"],
                ]
            ),
            ParamTemplate(
                name: "adaptive",
                description: "auto-pick best format",
                suggestions: ["true", "false"],
                freeText: false,
                valueDescriptions: ["true": "may change file extension", "false": "keep original format"],
                applicableTypes: [.image]
            ),
            ParamTemplate(
                name: "dpi",
                description: "PDF only: image resolution, overrides encoder choice (300 = no downsampling)",
                suggestions: ["300", "250", "200", "150", "100", "72", "48"],
                freeText: true,
                valueDescriptions: [
                    "300": "no downsampling, preserves embedded image resolution",
                    "250": "lightly downsample, near print quality",
                    "200": "lightly downsample, good for screen reading",
                    "150": "downsample for screen reading",
                    "100": "smaller, readable but visibly degraded",
                    "72": "screen quality",
                    "48": "smallest, very low quality",
                ],
                applicableTypes: [.pdf]
            ),
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
        applicableTypes: [.image, .video, .pdf, .audio],
        create: { .optimise() }
    ),
    StepTemplate(
        name: "downscale", description: "Scale down by a factor, always keeps aspect ratio (lowers audio bitrate for audio files)",
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
        applicableTypes: [.image, .video, .audio],
        create: { .downscale(factor: 0.5) }
    ),
    StepTemplate(
        name: "lowerBitrate", description: "Lower the audio bitrate (never upscales, snaps to allowed bitrates)",
        mandatoryParams: [
            ParamTemplate(name: "kbps", description: "target bitrate in kbps", suggestions: ["192", "160", "128", "96", "64"], freeText: true),
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
        applicableTypes: [.audio],
        create: { .lowerBitrate(kbps: 128) }
    ),
    StepTemplate(
        name: "convert", description: "Convert to a different format",
        mandatoryParams: [
            ParamTemplate(
                name: "to", description: "target format extension",
                suggestions: ["webp", "avif", "heic", "jxl", "jpeg", "png", "gif", "mp4", "webm", "m4a", "mp3", "ogg", "flac"],
                freeText: true,
                valueDescriptions: [
                    "webp": "WebP image format",
                    "avif": "AV1 image format",
                    "heic": "HEIC image format",
                    "jxl": "JPEG XL image format",
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
                    .image: ["webp", "avif", "heic", "jxl", "jpeg", "png", "gif"],
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
        name: "extractPagesAsImages", description: "Extract PDF pages as images",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(
                name: "format",
                description: "image format for extracted pages",
                suggestions: ["jpeg", "png"],
                freeText: false,
                valueDescriptions: ["jpeg": "JPEG (smaller, white background)", "png": "PNG (transparency preserved)"]
            ),
            ParamTemplate(
                name: "quality",
                description: "render resolution",
                suggestions: ["low", "medium", "high"],
                freeText: false,
                valueDescriptions: ["low": "1x scale (72 DPI)", "medium": "2x scale (144 DPI)", "high": "3x scale (216 DPI)"]
            ),
            ParamTemplate(
                name: "location",
                description: "where to save extracted images",
                suggestions: ["sameFolder", "temporaryFolder", "template"],
                freeText: true,
                valueDescriptions: [
                    "sameFolder": "save next to original PDF",
                    "temporaryFolder": "save in temp directory",
                    "template": "custom path with %f (filename), %y (year), etc.",
                ]
            ),
        ],
        applicableTypes: [.pdf],
        create: { .extractPagesAsImages() }
    ),
    StepTemplate(
        name: "targetSize", description: "Compress until the file fits under a size limit (Discord 10MB, email 25MB, etc.)",
        mandatoryParams: [
            ParamTemplate(
                name: "size",
                description: "size limit, e.g. 10MB, 500KB",
                suggestions: ["240KB", "1MB", "5MB", "8MB", "10MB", "16MB", "25MB"],
                freeText: true,
                valueDescriptions: [
                    "240KB": "US visa photo limit",
                    "5MB": "Notion free plan",
                    "8MB": "Google Play screenshots",
                    "10MB": "Discord free, GitHub attachments",
                    "16MB": "WhatsApp media",
                    "25MB": "Gmail attachments",
                ]
            ),
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
        applicableTypes: [.image, .video, .pdf, .audio],
        create: { .targetSize(bytes: 10_000_000) }
    ),
    StepTemplate(
        name: "stripExif", description: "Remove EXIF and GPS metadata (privacy before sharing)",
        mandatoryParams: [],
        optionalParams: [],
        applicableTypes: [.image, .video],
        create: { .stripExif }
    ),
    StepTemplate(
        name: "watermark", description: "Overlay a watermark image",
        mandatoryParams: [
            ParamTemplate(name: "image", description: "path to the watermark image (PNG with transparency works best)", suggestions: [], freeText: true, needsQuotes: true),
        ],
        optionalParams: [
            ParamTemplate(
                name: "position",
                description: "corner or center placement",
                suggestions: ["bottomRight", "bottomLeft", "topRight", "topLeft", "center"],
                freeText: false
            ),
            ParamTemplate(name: "opacity", description: "0.0 to 1.0", suggestions: ["1.0", "0.5", "0.3"], freeText: true),
            ParamTemplate(name: "scale", description: "watermark width as a fraction of the file width", suggestions: ["0.15", "0.1", "0.25", "0.5"], freeText: true),
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
        create: { .watermark(image: "") }
    ),
    StepTemplate(
        name: "capFps", description: "Cap the video frame rate",
        mandatoryParams: [
            ParamTemplate(name: "fps", description: "maximum frames per second", suggestions: ["60", "30", "24", "15", "10"], freeText: true),
        ],
        optionalParams: [],
        applicableTypes: [.video],
        create: { .capFps(fps: 30) }
    ),
    StepTemplate(
        name: "normalize", description: "Normalize audio loudness",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(
                name: "lufs",
                description: "target integrated loudness",
                suggestions: ["-14", "-16", "-23"],
                freeText: true,
                valueDescriptions: [
                    "-14": "Spotify / YouTube",
                    "-16": "Apple Podcasts",
                    "-23": "EBU broadcast",
                ]
            ),
        ],
        applicableTypes: [.audio],
        create: { .normalize() }
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
            ParamTemplate(name: "regex", description: "pattern matched against filename (smart case), capture groups as $1, $2", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "types", description: "space-separated UTTypes: jpeg png webp heic", suggestions: [], freeText: true),
            ParamTemplate(name: "nameContains", description: "case-insensitive substring match", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "nameIs", description: "exact filename match", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "fileSizeGreaterThan", description: "min file size in bytes", suggestions: [], freeText: true),
            ParamTemplate(name: "fileSizeLowerThan", description: "max file size in bytes", suggestions: [], freeText: true),
            ParamTemplate(name: "widthGreaterThan", description: "min width in pixels", suggestions: [], freeText: true, applicableTypes: [.image]),
            ParamTemplate(name: "widthLowerThan", description: "max width in pixels", suggestions: [], freeText: true, applicableTypes: [.image]),
            ParamTemplate(name: "heightGreaterThan", description: "min height in pixels", suggestions: [], freeText: true, applicableTypes: [.image]),
            ParamTemplate(name: "heightLowerThan", description: "max height in pixels", suggestions: [], freeText: true, applicableTypes: [.image]),
            ParamTemplate(name: "dpiGreaterThan", description: "min DPI (images & PDFs)", suggestions: ["72", "150", "300"], freeText: true, applicableTypes: [.image, .pdf]),
            ParamTemplate(name: "dpiLowerThan", description: "max DPI (images & PDFs)", suggestions: ["72", "150", "300"], freeText: true, applicableTypes: [.image, .pdf]),
            ParamTemplate(name: "minFileSize", description: "minimum file size, e.g. 100kb or 2mb", suggestions: ["100kb", "1mb"], freeText: true),
            ParamTemplate(name: "minResolution", description: "minimum width & height in pixels, e.g. 100x100", suggestions: ["100x100", "640x480"], freeText: true, applicableTypes: [.image]),
            ParamTemplate(name: "copiedBy", description: "app that copied the item (clipboard only), fuzzy match on app name or bundle id", suggestions: [], freeText: true, needsQuotes: true),
        ],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .filterIf(FilterCondition(regex: "")) }
    ),
    StepTemplate(
        name: "ifNot", description: "Continue pipeline only if condition does NOT match",
        mandatoryParams: [],
        optionalParams: [
            ParamTemplate(name: "regex", description: "pattern matched against filename (smart case)", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "types", description: "space-separated UTTypes to exclude", suggestions: [], freeText: true),
            ParamTemplate(name: "nameContains", description: "case-insensitive substring to exclude", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "nameIs", description: "exact filename to exclude", suggestions: [], freeText: true, needsQuotes: true),
            ParamTemplate(name: "copiedBy", description: "exclude when copied by this app (clipboard only), fuzzy match on app name or bundle id", suggestions: [], freeText: true, needsQuotes: true),
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
                valueDescriptions: ["path": "file path, relative if relativeTo is set", "imageData": "raw image data", "markdown": "markdown link, relative if relativeTo is set"],
                suggestionsForType: [
                    .video: ["path", "markdown"],
                    .audio: ["path", "markdown"],
                    .pdf: ["path", "markdown"],
                ]
            ),
            ParamTemplate(name: "relativeTo", description: "base path, makes output relative (e.g. ~/Projects/blog)", suggestions: [], freeText: true, needsQuotes: true),
        ],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .copyToClipboard() }
    ),
    StepTemplate(
        name: "copyLinkForSending", description: "Send file securely and copy share link to clipboard",
        mandatoryParams: [],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .copyLinkForSending }
    ),
    StepTemplate(
        name: "shelveWith", description: "Send file to a shelf app",
        mandatoryParams: [
            ParamTemplate(
                name: "app",
                description: "shelf app to send to",
                suggestions: ["yoink", "dockside", "dropover"],
                freeText: false,
                valueDescriptions: [
                    "yoink": "Yoink shelf app",
                    "dockside": "Dockside shelf app",
                    "dropover": "Dropover shelf app",
                ]
            ),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .shelveWith(app: "yoink") }
    ),
    StepTemplate(
        name: "uploadWith", description: "Upload file via an upload app",
        mandatoryParams: [
            ParamTemplate(
                name: "app",
                description: "upload app to use",
                suggestions: ["dropshare"],
                freeText: false,
                valueDescriptions: [
                    "dropshare": "Dropshare file upload service",
                ]
            ),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .uploadWith(app: "dropshare") }
    ),
    StepTemplate(
        name: "openWith", description: "Open file with a specific app",
        mandatoryParams: [
            {
                let apps = installedApps()
                return ParamTemplate(
                    name: "app",
                    description: "application name (e.g. Preview, Pixelmator Pro)",
                    suggestions: apps.names,
                    freeText: true,
                    needsQuotes: false,
                    valueDescriptions: apps.descriptions
                )
            }(),
        ],
        optionalParams: [],
        applicableTypes: [.image, .video, .audio, .pdf],
        create: { .openWith(app: "") }
    ),
]

func stepTemplates(for fileType: ClopFileType?) -> [StepTemplate] {
    guard let fileType else { return ALL_STEP_TEMPLATES }
    return ALL_STEP_TEMPLATES.filter { $0.applicableTypes.contains(fileType) }
}

// MARK: - Pipeline Step Parsing

func parsePipelineStep(_ text: String) -> PipelineStep? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)

    // Handle no-param steps
    if trimmed == "removeAudio" { return .removeAudio }
    if trimmed == "copyLinkForSending" { return .copyLinkForSending }
    if trimmed == "copyToClipboard" { return .copyToClipboard() }
    if trimmed == "stripExif" { return .stripExif }
    if trimmed == "normalize" { return .normalize() }

    // Parse name(params) format
    guard let nameRegex = try? NSRegularExpression(pattern: #"^(\w+)(?:\((.*)\))?$"#),
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
        let encoderStr = params["encoder"] ?? "medium"
        let adaptive = params["adaptive"] == "true"
        let dpi = params["dpi"].flatMap { Int($0) }
        let location = params["location"] ?? "inPlace"
        if let videoEncoder = VideoEncoder(rawValue: encoderStr) {
            return .optimise(adaptive: adaptive, videoEncoder: videoEncoder, dpi: dpi, location: location)
        }
        return .optimise(encoder: EncoderQuality(rawValue: encoderStr) ?? .medium, adaptive: adaptive, dpi: dpi, location: location)

    case "downscale":
        guard let factor = params["factor"].flatMap({ Double($0) }), factor > 0, factor <= 1 else { return nil }
        let location = params["location"] ?? "inPlace"
        return .downscale(factor: factor, location: location)

    case "lowerBitrate":
        guard let kbps = params["kbps"].flatMap({ Int($0) }), kbps > 0 else { return nil }
        let location = params["location"] ?? "inPlace"
        return .lowerBitrate(kbps: kbps, location: location)

    case "convert":
        guard let to = params["to"], !to.isEmpty else { return nil }
        let location = params["location"] ?? "sameFolder"
        return .convert(to: to, location: location)

    case "crop":
        let width = params["width"].flatMap { Int($0) }
        let height = params["height"].flatMap { Int($0) }
        let longEdge = params["longEdge"].flatMap { Int($0) }
        guard width != nil || height != nil || longEdge != nil else { return nil }
        let location = params["location"] ?? "inPlace"
        return .crop(width: width, height: height, longEdge: longEdge, location: location)

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

    case "extractPagesAsImages":
        let format = params["format"] ?? "jpeg"
        let quality = params["quality"] ?? "medium"
        let location = params["location"] ?? "sameFolder"
        return .extractPagesAsImages(format: format, quality: quality, location: location)

    case "targetSize":
        guard let sizeStr = params["size"], let bytes = parseByteSize(sizeStr), bytes > 0 else { return nil }
        return .targetSize(bytes: bytes, location: params["location"] ?? "inPlace")

    case "stripExif":
        return .stripExif

    case "watermark":
        guard let image = params["image"], !image.isEmpty else { return nil }
        return .watermark(
            image: image,
            position: params["position"] ?? "bottomRight",
            opacity: params["opacity"].flatMap { Double($0) } ?? 1.0,
            scale: params["scale"].flatMap { Double($0) } ?? 0.15,
            location: params["location"] ?? "inPlace"
        )

    case "capFps":
        guard let fps = params["fps"].flatMap({ Int($0) }), fps > 0 else { return nil }
        return .capFps(fps: fps)

    case "normalize":
        return .normalize(lufs: params["lufs"].flatMap { Double($0) } ?? -16)

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
        let shortcuts = SHM.shortcuts
        let shortcut = shortcuts.first(where: { $0.name == shortcutName }) ?? Shortcut(name: shortcutName, identifier: shortcutName)
        return .runShortcut(shortcut)

    case "copyToClipboard":
        let format = ClipboardCopyFormat(rawValue: params["format"] ?? "path") ?? .path
        let relativeTo = params["relativeTo"]
        return .copyToClipboard(format: format, relativeTo: relativeTo)

    case "copyLinkForSending":
        return .copyLinkForSending

    case "shelveWith":
        guard let app = params["app"], ["yoink", "dockside", "dropover"].contains(app.lowercased()) else { return nil }
        return .shelveWith(app: app.lowercased())

    case "uploadWith":
        guard let app = params["app"], ["dropshare"].contains(app.lowercased()) else { return nil }
        return .uploadWith(app: app.lowercased())

    case "openWith":
        guard let app = params["app"], !app.isEmpty else { return nil }
        return .openWith(app: app)

    default:
        return nil
    }
}

private func parseParams(_ str: String) -> [String: String] {
    guard !str.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for part in splitOutsideQuotes(str, on: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        let kv = part.split(separator: ":", maxSplits: 1)
        guard kv.count == 2 else { continue }
        let key = kv[0].trimmingCharacters(in: .whitespaces)
        let value = kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        result[key] = value
    }
    return result
}

/// Split on a separator, ignoring separators inside single or double quotes so that
/// values like `regex: "\d{2,4}"` survive parameter parsing.
private func splitOutsideQuotes(_ str: String, on separator: Character) -> [String] {
    var parts: [String] = []
    var current = ""
    var quoteChar: Character?
    for ch in str {
        if ch == "\"" || ch == "'" {
            if quoteChar == ch {
                quoteChar = nil
            } else if quoteChar == nil {
                quoteChar = ch
            }
            current.append(ch)
        } else if ch == separator, quoteChar == nil {
            parts.append(current)
            current = ""
        } else {
            current.append(ch)
        }
    }
    parts.append(current)
    return parts
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
        heightLowerThan: params["heightLowerThan"].flatMap { Int($0) },
        dpiGreaterThan: params["dpiGreaterThan"].flatMap { Int($0) },
        dpiLowerThan: params["dpiLowerThan"].flatMap { Int($0) },
        minFileSize: params["minFileSize"].flatMap { parseByteSize($0) },
        minResolution: params["minResolution"].flatMap { parseResolution($0) },
        copiedBy: params["copiedBy"]
    )
}

/// Parse a human-friendly byte size like "100kb", "2mb", "1.5MiB" or a raw byte count.
private func parseByteSize(_ str: String) -> Int? {
    let s = str.trimmingCharacters(in: .whitespaces).lowercased()
    if let n = Int(s) { return n }
    // Longer suffixes first so "kib"/"mib" win over "kb"/"mb".
    let multipliers: [(String, Double)] = [
        ("gib", 1_073_741_824), ("gb", 1_000_000_000),
        ("mib", 1_048_576), ("mb", 1_000_000),
        ("kib", 1024), ("kb", 1000), ("b", 1),
    ]
    for (suffix, mult) in multipliers where s.hasSuffix(suffix) {
        if let num = Double(s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) {
            return Int(num * mult)
        }
    }
    return nil
}

/// Parse a resolution like "100" or "100x100" into a single minimum-edge value (the first number).
private func parseResolution(_ str: String) -> Int? {
    let parts = str.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" })
    guard let first = parts.first, let n = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
    return n
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
    var closesParens = false
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
func pipelineSuggestions(prefix: String, fileType: ClopFileType?) -> [CompletionSuggestion] {
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
        let allParams = (template.mandatoryParams + template.optionalParams).filter { $0.applies(to: fileType) }

        if lastPart.contains(":") {
            // User typed "paramName:" or "paramName: val" -> show values for this param
            let colonIdx = lastPart.firstIndex(of: ":")!
            let paramName = String(lastPart[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let typedValue = String(lastPart[lastPart.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            guard let param = allParams.first(where: { $0.name == paramName }) else { return [] }

            // Inside quotes -> show template variables when empty or after % so the
            // user discovers available tokens without having to know about them first.
            let insideQuotes = typedValue.hasPrefix("\"")
            let unquotedValue = insideQuotes ? String(typedValue.dropFirst()) : typedValue
            if insideQuotes, unquotedValue.isEmpty || unquotedValue.contains("%") {
                let afterPercent = unquotedValue.lastIndex(of: "%").map { String(unquotedValue.suffix(from: $0).dropFirst()) } ?? ""
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
            let filledNames = usedNames.union([paramName])
            let remainingParams = allParams.filter { !filledNames.contains($0.name) }
            let isLastParam = remainingParams.isEmpty
            let suggestions = paramSuggestions
                .filter { typedValue.isEmpty || $0.lowercased().hasPrefix(typedValue.lowercased()) }
                .map { value in
                    CompletionSuggestion(
                        insertText: value,
                        displayText: value,
                        details: param.valueDescriptions(for: fileType)[value] ?? param.description,
                        color: step.category.swiftUIColor,
                        opensParens: false,
                        needsQuotes: value == "template",
                        closesParens: isLastParam
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
    let fileType: ClopFileType?
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
