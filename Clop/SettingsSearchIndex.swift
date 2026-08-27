import Foundation

// MARK: - SettingEntry

/// One row of the Settings window, described in the words the user reads.
///
/// The index exists twice over: it backs the search field in Settings, and it is what an agent reads
/// through MCP. Both need the same wording, so a row is described once here rather than once for
/// people and once for machines.
///
/// `keys` names the `Defaults` keys the row writes, in the order the row shows them. A row that hosts
/// no single key (a folder list, a preset gallery, a permissions block) carries none, and still
/// appears so a search can point at the pane.
struct SettingEntry: Identifiable, Hashable {
    let id: String
    let keys: [String]
    let title: String
    let subtitle: String
    /// Words a person would search for that the title and subtitle do not already contain. The point
    /// is the vocabulary mismatch: someone types "mov" or "replace the original", the row says
    /// "Auto-conversion behaviour".
    let keywords: [String]
    let tab: SettingsView.Tabs
    let section: String

    /// The words of each field, kept apart so a hit in the title can outrank one buried in a subtitle.
    var searchFields: [(weight: Double, words: [String])] {
        [
            (3.0, SettingsSearchIndex.words(title)),
            (2.5, keywords.flatMap { SettingsSearchIndex.words($0) }),
            (1.0, SettingsSearchIndex.words(subtitle)),
            (0.6, SettingsSearchIndex.words(section) + SettingsSearchIndex.words(tab.title)),
        ]
    }

    /// The same fields unsplit, for the subsequence pass. It runs across word boundaries, so it needs
    /// the text rather than the words: "autoconv" is nowhere in `searchFields` and sits right there in
    /// "Auto-conversion behaviour".
    var searchTexts: [(weight: Double, text: String)] {
        [
            (3.0, title.lowercased()),
            (2.5, keywords.joined(separator: " ").lowercased()),
            (1.0, subtitle.lowercased()),
            (0.6, "\(section) \(tab.title)".lowercased()),
        ]
    }
}

// MARK: - SettingsSearchIndex

enum SettingsSearchIndex {
    /// Every user-facing row. Hand-maintained; `Scripts/settings-index-audit.py` fails the commit when
    /// a key named here stops existing, or a key gains a control and never gets an entry.
    static let all: [SettingEntry] = [
        SettingEntry(
            id: "general.main.syncSettingsCloud", keys: ["syncSettingsCloud"],
            title: "Sync settings with other Macs via iCloud",
            subtitle: "",
            keywords: ["icloud", "sync", "other macs", "settings"], tab: .general, section: ""
        ),
        SettingEntry(
            id: "general.main.defaultLinkExpiration", keys: ["defaultLinkExpiration"],
            title: "Default link expiration",
            subtitle: "How long a Send securely link stays alive",
            keywords: [], tab: .general, section: ""
        ),
        SettingEntry(
            id: "general.workingdirectory.workdirCleanupInterval", keys: ["workdirCleanupInterval"],
            title: "Working directory cleanup",
            subtitle: "Periodically delete files older than this from Clop's working directory",
            keywords: [], tab: .general, section: "Working directory"
        ),
        SettingEntry(
            id: "general.optimisation.stripMetadata", keys: ["stripMetadata"],
            title: "Strip EXIF Metadata",
            subtitle: "Deleted identifiable metadata from files (e.g. camera that took the photo, location, date and time etc.)",
            keywords: ["exif", "metadata", "gps", "location", "privacy", "camera"], tab: .general, section: "Optimisation"
        ),
        SettingEntry(
            id: "general.optimisation.preserveColorMetadata", keys: ["preserveColorMetadata"],
            title: "Preserve color profile metadata",
            subtitle: "Keep color profile metadata tags untouched when stripping EXIF metadata",
            keywords: [], tab: .general, section: "Optimisation"
        ),
        SettingEntry(
            id: "general.optimisation.preserveDates", keys: ["preserveDates"],
            title: "Preserve file creation and modification dates",
            subtitle: "The optimised file will have the same creation and modification dates as the original file",
            keywords: ["timestamp", "created", "modified", "date", "mtime"], tab: .general, section: "Optimisation"
        ),
        SettingEntry(
            id: "general.optimisation.optimisedFileProtectionMs", keys: ["optimisedFileProtectionMs"],
            title: "Re-optimisation loop detection window",
            subtitle: "Increase if files on iCloud Drive get optimised twice",
            keywords: [], tab: .general, section: "Optimisation"
        ),

        SettingEntry(
            id: "clipboard.clipboard.enableClipboardOptimiser", keys: ["enableClipboardOptimiser"],
            title: "Enable clipboard optimiser",
            subtitle: "Watch for copied data and optimise it automatically",
            keywords: ["clipboard", "copy", "paste", "watch", "automatic"], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.optimiseTIFF", keys: ["optimiseTIFF"],
            title: "TIFF data",
            subtitle: "Usually from graphical design apps, sometimes better left alone",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.optimiseImagePathClipboard", keys: ["optimiseImagePathClipboard"],
            title: "Image files",
            subtitle: "Copying images from Finder results in file paths instead of image data",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.optimiseVideoClipboard", keys: ["optimiseVideoClipboard"],
            title: "Video files",
            subtitle: "Optimise copied video file paths",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.optimiseAudioClipboard", keys: ["optimiseAudioClipboard"],
            title: "Audio files",
            subtitle: "Optimise copied audio file paths",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.optimisePDFClipboard", keys: ["optimisePDFClipboard"],
            title: "PDF files",
            subtitle: "Optimise copied PDF file paths",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.appendClipboardResults", keys: ["appendClipboardResults"],
            title: "Keep all clipboard results",
            subtitle: "Show each clipboard optimisation as a separate result instead of replacing the previous one",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.copyConsecutiveClipboardImages", keys: ["copyConsecutiveClipboardImages"],
            title: "Accumulate optimised images in clipboard",
            subtitle: "Each new optimised image is added to a file list in the clipboard, so you can paste them all at once into image editor apps like Pixelmator or Affinity, or into notes",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),
        SettingEntry(
            id: "clipboard.clipboard.clipboardAccumulationTimeout", keys: ["clipboardAccumulationTimeout"],
            title: "Accumulation timeout",
            subtitle: "How long consecutive copied images keep accumulating into one file list",
            keywords: [], tab: .clipboard, section: "Clipboard"
        ),

        SettingEntry(
            id: "files.images.optimisedImageBehaviour", keys: ["optimisedImageBehaviour"],
            title: "Optimised file placement",
            subtitle: "Where the smaller file is saved, and whether it replaces the original",
            keywords: ["placement", "where", "save", "saved", "replace", "original", "in place", "copy", "same folder", "specific folder", "overwrite", "output"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "files.images.convertedImageBehaviour", keys: ["convertedImageBehaviour"],
            title: "Auto-conversion behaviour for compatible formats",
            subtitle: "Formats that many apps cannot open well are converted to a widely supported one automatically before optimising.",
            keywords: ["webp", "avif", "heic", "bmp", "png", "jpeg", "convert", "conversion", "replace", "original", "in place", "copy", "keep", "beside", "automatic", "compatibility"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "files.images.manualConvertedImageBehaviour", keys: ["manualConvertedImageBehaviour"],
            title: "Manual conversion behaviour",
            subtitle: "When you pick a new format by clicking the file extension on a floating result, or via the submenu **Convert to...** in the right-click menu.",
            keywords: ["convert to", "manual", "right click", "extension", "click", "replace", "original", "in place", "copy"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "files.videos.optimisedVideoBehaviour", keys: ["optimisedVideoBehaviour"],
            title: "Optimised file placement",
            subtitle: "Where the smaller file is saved, and whether it replaces the original",
            keywords: ["placement", "where", "save", "saved", "replace", "original", "in place", "copy", "same folder", "specific folder", "overwrite", "output"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "files.videos.convertedVideoBehaviour", keys: ["convertedVideoBehaviour"],
            title: "Auto-conversion behaviour for compatible formats",
            subtitle: "Formats that many apps cannot open well are converted to a widely supported one automatically before optimising.",
            keywords: ["mov", "mkv", "webm", "mp4", "convert", "conversion", "replace", "original", "in place", "copy", "keep", "leftover", "beside", "automatic", "compatibility"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "files.videos.manualConvertedVideoBehaviour", keys: ["manualConvertedVideoBehaviour"],
            title: "Manual conversion behaviour",
            subtitle: "When you pick a new format by clicking the file extension on a floating result, or via the submenu **Convert to...** in the right-click menu.",
            keywords: ["convert to", "manual", "right click", "extension", "click", "replace", "original", "in place", "copy"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "files.audio.optimisedAudioBehaviour", keys: ["optimisedAudioBehaviour"],
            title: "Optimised file placement",
            subtitle: "Where the smaller file is saved, and whether it replaces the original",
            keywords: ["placement", "where", "save", "saved", "replace", "original", "in place", "copy", "same folder", "specific folder", "overwrite", "output"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "files.audio.convertedAudioBehaviour", keys: ["convertedAudioBehaviour"],
            title: "Auto-conversion behaviour for compatible formats",
            subtitle: "Formats that many apps cannot open well are converted to a widely supported one automatically before optimising.",
            keywords: ["wav", "aiff", "flac", "aac", "mp3", "convert", "conversion", "replace", "original", "in place", "copy", "keep", "beside", "automatic", "compatibility"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "files.audio.manualConvertedAudioBehaviour", keys: ["manualConvertedAudioBehaviour"],
            title: "Manual conversion behaviour",
            subtitle: "When you pick a new format by clicking the file extension on a floating result, or via the submenu **Convert to...** in the right-click menu.",
            keywords: ["convert to", "manual", "right click", "extension", "click", "replace", "original", "in place", "copy"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "files.pdf.optimisedPDFBehaviour", keys: ["optimisedPDFBehaviour"],
            title: "Optimised file placement",
            subtitle: "Where the smaller file is saved, and whether it replaces the original",
            keywords: ["placement", "where", "save", "saved", "replace", "original", "in place", "copy", "same folder", "specific folder", "overwrite", "output"], tab: .files, section: "PDF"
        ),

        SettingEntry(
            id: "video.optimisationrules.removeAudioFromVideos", keys: ["removeAudioFromVideos"],
            title: "Remove audio on optimised videos",
            subtitle: "",
            keywords: ["mute", "silent", "sound", "audio track", "strip"], tab: .video, section: "Optimisation rules"
        ),
        SettingEntry(
            id: "video.optimisationrules.capVideoFPS", keys: ["capVideoFPS", "targetVideoFPS"],
            title: "Cap frames per second",
            subtitle: "",
            keywords: ["fps", "frame rate", "frames per second", "30fps", "60fps", "smooth", "slow", "half", "quarter", "1/2 of source", "1/4 of source", "choppy", "screen recording", "stuttering"], tab: .video,
            section: "Optimisation rules"
        ),
        SettingEntry(
            id: "video.optimisationrules.playbackSpeedFrameBehaviour", keys: ["playbackSpeedFrameBehaviour"],
            title: "Playback speed change",
            subtitle: "Whether changing speed drops frames or re-times them",
            keywords: [], tab: .video, section: "Optimisation rules"
        ),
        SettingEntry(
            id: "video.compatibility.convertAudioToAAC", keys: ["convertAudioToAAC"],
            title: "Convert audio to AAC",
            subtitle: "Re-encode a video's audio track to AAC for compatibility",
            keywords: [], tab: .video, section: "Compatibility"
        ),

        SettingEntry(
            id: "audio.optimisationrules.audioCoverArt", keys: ["audioCoverArt"],
            title: "Cover art",
            subtitle: "Cover art is kept only for formats that can store it (AAC, MP3, FLAC); it is dropped for others.",
            keywords: ["artwork", "thumbnail", "picture", "embedded", "id3", "m4a", "strip", "remove", "metadata", "tag", "album"], tab: .audio, section: "Optimisation rules"
        ),

        SettingEntry(
            id: "images.main.customNameTemplateForClipboardImages", keys: ["customNameTemplateForClipboardImages"],
            title: "Name template for clipboard images",
            subtitle: "Pattern for naming images saved from the clipboard",
            keywords: [], tab: .images, section: ""
        ),
        SettingEntry(
            id: "images.main.photoCropOrientation", keys: ["photoCropOrientation"],
            title: "Photos crop orientation",
            subtitle: "Which way to crop images coming from Photos.app",
            keywords: [], tab: .images, section: ""
        ),
        SettingEntry(
            id: "images.filenamehandling.copyImageFilePath", keys: ["copyImageFilePath"],
            title: "Copy image paths",
            subtitle: "When copying optimised image data, also copy the path of the image file",
            keywords: [], tab: .images, section: "File name handling"
        ),
        SettingEntry(
            id: "images.filenamehandling.useCustomNameTemplateForClipboardImages", keys: ["useCustomNameTemplateForClipboardImages"],
            title: "Use a name template for clipboard images",
            subtitle: "",
            keywords: [], tab: .images, section: "File name handling"
        ),
        SettingEntry(
            id: "images.photosintegration.enablePhotosIntegration", keys: ["enablePhotosIntegration"],
            title: "Optimise images copied from Photos.app",
            subtitle: "",
            keywords: [], tab: .images, section: "Photos integration"
        ),
        SettingEntry(
            id: "images.optimisationrules.gifFrameDropBehaviour", keys: ["gifFrameDropBehaviour"],
            title: "GIF frame dropping",
            subtitle: "Compression factors above 80% drop every 4th, 3rd or 2nd frame of animated GIFs. The animation can either play faster with the remaining frames, or keep its duration by showing each frame longer",
            keywords: ["gif", "animation", "frames", "drop", "choppy", "smooth"], tab: .images, section: "Optimisation rules"
        ),

        SettingEntry(
            id: "dropzone.dropzone.enableDragAndDrop", keys: ["enableDragAndDrop"],
            title: "Enable drop zone",
            subtitle: "Allows dragging files, paths and URLs to a global drop zone for optimisation",
            keywords: ["drop zone", "drag", "drop"], tab: .dropzone, section: "Drop zone"
        ),
        SettingEntry(
            id: "dropzone.dropzone.onlyShowDropZoneOnOption", keys: ["onlyShowDropZoneOnOption"],
            title: "Require pressing ⌥ Option to show drop zone",
            subtitle: "Hide drop zone by default to avoid distractions while dragging files, show it by manually pressing ⌥ Option once",
            keywords: [], tab: .dropzone, section: "Drop zone"
        ),
        SettingEntry(
            id: "dropzone.dropzone.autoCopyToClipboard", keys: ["autoCopyToClipboard"],
            title: "Auto Copy optimised files to clipboard",
            subtitle: "Copy files resulting from drop zone or file watch optimisation so they can be pasted right after optimisation ends",
            keywords: [], tab: .dropzone, section: "Drop zone"
        ),
        SettingEntry(
            id: "dropzone.batchmode.useBatchModeForFolders", keys: ["useBatchModeForFolders"],
            title: "Use batch mode for large drops",
            subtitle: "Dropping many files at once (or a folder with many files) opens a single batch window that optimises them all efficiently. Originals are backed up first and can be restored.",
            keywords: [], tab: .dropzone, section: "Batch mode"
        ),
        SettingEntry(
            id: "dropzone.batchmode.batchModeFileCountThreshold", keys: ["batchModeFileCountThreshold"],
            title: "Batch mode file threshold",
            subtitle: "Drops with more files than this use batch mode",
            keywords: [], tab: .dropzone, section: "Batch mode"
        ),

        SettingEntry(
            id: "presetZones.showingpresetzones.onlyShowPresetZonesOnControlTapped", keys: ["onlyShowPresetZonesOnControlTapped"],
            title: "Show preset zones by holding or tapping Control",
            subtitle: "Hold reveals them while the key is down; tap leaves them up",
            keywords: [], tab: .presetZones, section: "Showing preset zones"
        ),

        SettingEntry(
            id: "floating.main.enableFloatingResults", keys: ["enableFloatingResults"],
            title: "Show floating results",
            subtitle: "Disabling this will make Clop run in an UI-less mode, but keep optimising files in the background. Drop zone can be disabled separately in the Drop zone tab",
            keywords: [], tab: .floating, section: ""
        ),
        SettingEntry(
            id: "floating.layout.floatingResultsCorner", keys: ["floatingResultsCorner"],
            title: "Position on screen",
            subtitle: "Which corner floating results appear in",
            keywords: [], tab: .floating, section: "Layout"
        ),
        SettingEntry(
            id: "floating.layout.followCursorScreen", keys: ["followCursorScreen"],
            title: "Follow the cursor across screens",
            subtitle: "When the cursor stays on another screen for a couple of seconds, move the results to that screen",
            keywords: [], tab: .floating, section: "Layout"
        ),
        SettingEntry(
            id: "floating.layout.hideFloatingResultTooltips", keys: ["hideFloatingResultTooltips"],
            title: "Hide button tooltips",
            subtitle: "Don't show the action name labels that pop up while hovering result buttons",
            keywords: [], tab: .floating, section: "Layout"
        ),
        SettingEntry(
            id: "floating.layout.alwaysShowCompactResults", keys: ["alwaysShowCompactResults"],
            title: "Always use compact layout",
            subtitle: "By default, the layout switches to compact automatically when there are more than 5 results on the screen",
            keywords: [], tab: .floating, section: "Layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.formatPickerStyle", keys: ["formatPickerStyle"],
            title: "Change format by",
            subtitle: "How the format control on a floating result behaves",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.showCopyClearButtons", keys: ["showCopyClearButtons"],
            title: "Show Copy all and Clear all buttons",
            subtitle: "",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.dismissFloatingResultOnDrop", keys: ["dismissFloatingResultOnDrop"],
            title: "Dismiss result on drag and drop outside",
            subtitle: "",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.dismissFloatingResultOnUpload", keys: ["dismissFloatingResultOnUpload"],
            title: "Dismiss result on upload to Dropshare",
            subtitle: "",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.autoHideFloatingResults", keys: ["autoHideFloatingResults"],
            title: "Auto hide floating results",
            subtitle: "",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.autoHideFloatingResultsAfter", keys: ["autoHideFloatingResultsAfter"],
            title: "Auto hide file results after",
            subtitle: "Seconds before a file result disappears",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.fulllayout.autoHideClipboardResultAfter", keys: ["autoHideClipboardResultAfter"],
            title: "Auto hide clipboard results after",
            subtitle: "Seconds before a clipboard result disappears",
            keywords: [], tab: .floating, section: "Full layout"
        ),
        SettingEntry(
            id: "floating.compactlayout.showCompactImages", keys: ["showCompactImages"],
            title: "Show images in compact results",
            subtitle: "",
            keywords: [], tab: .floating, section: "Compact layout"
        ),
        SettingEntry(
            id: "floating.compactlayout.dismissCompactResultOnDrop", keys: ["dismissCompactResultOnDrop"],
            title: "Dismiss compact result on drag and drop outside",
            subtitle: "",
            keywords: [], tab: .floating, section: "Compact layout"
        ),
        SettingEntry(
            id: "floating.compactlayout.dismissCompactResultOnUpload", keys: ["dismissCompactResultOnUpload"],
            title: "Dismiss compact result on upload to Dropshare",
            subtitle: "",
            keywords: [], tab: .floating, section: "Compact layout"
        ),
        SettingEntry(
            id: "floating.compactlayout.autoClearAllCompactResultsAfter", keys: ["autoClearAllCompactResultsAfter"],
            title: "Auto clear all compact results after",
            subtitle: "Seconds before every compact result is cleared",
            keywords: [], tab: .floating, section: "Compact layout"
        ),

        SettingEntry(
            id: "mcp.main.mcpEnabled", keys: ["mcpEnabled"],
            title: "Accept changes from agents",
            subtitle: "Optimising files, changing settings, saving pipelines. Reading settings and pipelines stays allowed either way",
            keywords: ["mcp", "agent", "ai", "claude", "cursor", "llm", "automation"], tab: .mcp, section: ""
        ),
        SettingEntry(
            id: "mcp.main.mcpAllowScriptSteps", keys: ["mcpAllowScriptSteps"],
            title: "Allow agents to write script steps",
            subtitle: "A script step runs arbitrary code. Off means Clop refuses a pipeline from an agent that contains one, and names the step. Scripts you write yourself are unaffected",
            keywords: ["mcp", "agent", "script", "shell", "code", "pipeline", "dangerous"], tab: .mcp, section: ""
        ),

        // MARK: added from the domain sweep

        SettingEntry(
            id: "video.watchpaths.videoDirs", keys: [],
            title: "Watch paths",
            subtitle: "Optimise videos as they appear in these folders",
            keywords: ["directory", "desktop", "downloads", "monitor", "automatic", "add", "clopignore", "ignore rules", "not picking up", "nothing happens", "unwatched"], tab: .video, section: "Watch paths"
        ),
        SettingEntry(
            id: "video.watchpaths.enableAutomaticVideoOptimisations", keys: ["enableAutomaticVideoOptimisations"],
            title: "Enable video auto-optimiser",
            subtitle: "",
            keywords: ["watch", "folders", "background", "monitor", "stopped working", "disabled", "paused", "desktop", "nothing happens", "turn off"], tab: .video, section: "Watch paths"
        ),
        SettingEntry(
            id: "video.optimisationrules.videoCompression", keys: ["videoCompression"],
            title: "Compression",
            subtitle: "",
            keywords: ["encoder", "hardware", "software", "adaptive", "visually lossless", "quality", "crf", "bitrate", "factor", "auto", "slower", "cpu", "battery", "smaller size", "better quality"], tab: .video,
            section: "Optimisation rules"
        ),
        SettingEntry(
            id: "video.optimisationrules.minVideoFPS", keys: ["minVideoFPS"],
            title: "but no less than",
            subtitle: "",
            keywords: ["fps", "minimum", "floor", "10fps", "24fps", "30fps", "60fps", "1/2 of source", "1/4 of source", "fraction", "frame rate", "too slow", "choppy", "stuttering"], tab: .video, section: "Optimisation rules"
        ),
        SettingEntry(
            id: "video.watchedfilefilters.minVideoSizeKB", keys: ["minVideoSizeKB", "maxVideoSizeMB"],
            title: "File size",
            subtitle: "Only optimises files between the set sizes",
            keywords: ["mb", "kb", "gb", "skipped", "ignored", "too big", "too large", "too small", "threshold", "limit", "range", "untouched"], tab: .video, section: "Watched file filters"
        ),
        SettingEntry(
            id: "video.watchedfilefilters.minVideoResolution", keys: ["minVideoResolution", "maxVideoResolution"],
            title: "Resolution",
            subtitle: "Only optimises files with width and height between the set values",
            keywords: ["px", "pixels", "4k", "1080p", "tiny", "thumbnail", "upscaled", "skipped", "ignored", "threshold", "limit", "range", "dimensions"], tab: .video, section: "Watched file filters"
        ),
        SettingEntry(
            id: "video.watchedfilefilters.maxVideoFileCount", keys: ["maxVideoFileCount"],
            title: "File count",
            subtitle: "Skips optimisation when more than this many videos are copied or moved at once",
            keywords: ["batch", "bulk", "drag", "import", "multiple", "dozens", "threshold", "limit", "nothing happens", "ignored"], tab: .video, section: "Watched file filters"
        ),
        SettingEntry(
            id: "video.watchedfilefilters.videoFormatsToSkip", keys: ["videoFormatsToSkip"],
            title: "Ignore videos with extension",
            subtitle: "",
            keywords: ["mkv", "m4v", "avi", "webm", "mov", "mp4", "mpeg", "skip", "exclude", "deny list", "format", "untouched", "left alone"], tab: .video, section: "Watched file filters"
        ),
        SettingEntry(
            id: "video.compatibility.formatsToConvertToMP4", keys: ["formatsToConvertToMP4"],
            title: "Convert to mp4",
            subtitle: "",
            keywords: ["mov", "webm", "mkv", "avi", "mpeg", "m4v", "quicktime", "container", "remux", "incompatible", "cannot open", "unsupported", "automatic"], tab: .video, section: "Compatibility"
        ),
        SettingEntry(
            id: "general.editwithexternalapp.editorAppVideo", keys: ["editorAppVideo"],
            title: "Videos",
            subtitle: "",
            keywords: ["editor", "external app", "open with", "capcut", "final cut", "premiere", "davinci", "cmd e", "right click", "choose app", "bundle path"], tab: .general, section: "Edit with external app"
        ),
        SettingEntry(
            id: "files.videos.sameFolderNameTemplateVideo", keys: ["sameFolderNameTemplateVideo"],
            title: "Name template for optimised videos saved in the same folder",
            subtitle: "",
            keywords: ["pattern", "rename", "filename", "suffix", "counter", "date", "clop", "placeholder", "token", "variables"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "files.videos.specificFolderNameTemplateVideo", keys: ["specificFolderNameTemplateVideo"],
            title: "Path template for optimised videos saved in a specific folder",
            subtitle: "",
            keywords: ["destination", "output directory", "subfolder", "pattern", "rename", "filename", "where", "placeholder", "token", "location"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "files.videos.convertedSameFolderNameTemplateVideo", keys: ["convertedSameFolderNameTemplateVideo"],
            title: "Name template for converted videos saved in the same folder",
            subtitle: "",
            keywords: ["mp4", "mov", "pattern", "rename", "filename", "suffix", "leftover", "duplicate", "placeholder", "token"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "files.videos.convertedSpecificFolderNameTemplateVideo", keys: ["convertedSpecificFolderNameTemplateVideo"],
            title: "Path template for converted videos saved in a specific folder",
            subtitle: "",
            keywords: ["mp4", "mov", "destination", "output directory", "subfolder", "pattern", "where", "placeholder", "token", "location"], tab: .files, section: "Videos"
        ),
        SettingEntry(
            id: "images.watchpaths.imageDirs", keys: [],
            title: "Watch paths",
            subtitle: "Optimise images as they appear in these folders",
            keywords: ["directories", "desktop", "downloads", "screenshots", "monitor", "automatic", "clopignore", "ignore rules", "per-folder", "add", "remove"], tab: .images, section: "Watch paths"
        ),
        SettingEntry(
            id: "images.watchpaths.enableAutomaticImageOptimisations", keys: ["enableAutomaticImageOptimisations"],
            title: "Enable image auto-optimiser",
            subtitle: "",
            keywords: ["watch", "folder", "background", "screenshots", "stopped working", "nothing happens", "turn off", "pause", "monitor", "checkbox"], tab: .images, section: "Watch paths"
        ),
        SettingEntry(
            id: "images.photosintegration.maxCopiedPhotosCount", keys: ["maxCopiedPhotosCount"],
            title: "File count",
            subtitle: "",
            keywords: ["photos", "photos.app", "copied at once", "batch", "bulk", "how many", "limit", "threshold", "skip", "albums"], tab: .images, section: "Photos integration"
        ),
        SettingEntry(
            id: "images.photosintegration.maxPhotosLength", keys: ["maxPhotosLength"],
            title: "Downscale to",
            subtitle: "",
            keywords: ["photos", "px", "pixels", "resize", "longest edge", "shrink", "huge", "crop", "empty", "unlimited"], tab: .images, section: "Photos integration"
        ),
        SettingEntry(
            id: "images.optimisationrules.imageCompression", keys: ["imageCompression"],
            title: "Compression",
            subtitle: "",
            keywords: ["quality", "factor", "percent", "slider", "adaptive", "lossy", "aggressive", "smaller", "blurry", "artifacts", "entropy", "jpeg", "png", "file size"], tab: .images, section: "Optimisation rules"
        ),
        SettingEntry(
            id: "images.watchedfilefilters.minImageSizeKB", keys: ["minImageSizeKB", "maxImageSizeMB"],
            title: "File size",
            subtitle: "",
            keywords: ["skip", "limit", "range", "kb", "mb", "bytes", "megabytes", "too small", "too large", "threshold", "ignore", "not optimised"], tab: .images, section: "Watched file filters"
        ),
        SettingEntry(
            id: "images.watchedfilefilters.minImageResolution", keys: ["minImageResolution", "maxImageResolution"],
            title: "Resolution",
            subtitle: "",
            keywords: ["pixels", "px", "width", "height", "dimensions", "skip", "limit", "range", "icons", "thumbnails", "huge", "ignore"], tab: .images, section: "Watched file filters"
        ),
        SettingEntry(
            id: "images.watchedfilefilters.maxImageFileCount", keys: ["maxImageFileCount"],
            title: "File count",
            subtitle: "",
            keywords: ["batch", "bulk", "how many", "at once", "copied at once", "moved at once", "limit", "threshold", "skip", "mass copy"], tab: .images, section: "Watched file filters"
        ),
        SettingEntry(
            id: "images.watchedfilefilters.imageFormatsToSkip", keys: ["imageFormatsToSkip"],
            title: "Ignore images with extension",
            subtitle: "",
            keywords: ["tiff", "psd", "raw", "skip", "exclude", "never optimise", "leave alone", "format", "blacklist", "deny list"], tab: .images, section: "Watched file filters"
        ),
        SettingEntry(
            id: "images.compatibility.formatsToConvertToJPEG", keys: ["formatsToConvertToJPEG"],
            title: "Convert to jpeg",
            subtitle: "",
            keywords: ["webp", "avif", "heic", "bmp", "jxl", "tiff", "compatibility", "cannot open", "unsupported", "automatic", "before optimisation"], tab: .images, section: "Compatibility"
        ),
        SettingEntry(
            id: "images.compatibility.formatsToConvertToPNG", keys: ["formatsToConvertToPNG"],
            title: "Convert to png",
            subtitle: "",
            keywords: ["tiff", "bmp", "webp", "avif", "heic", "jxl", "transparency", "alpha", "lossless", "compatibility", "unsupported", "cannot open"], tab: .images, section: "Compatibility"
        ),
        SettingEntry(
            id: "files.images.sameFolderNameTemplateImage", keys: ["sameFolderNameTemplateImage"],
            title: "Name template for Same folder as original",
            subtitle: "",
            keywords: ["%f", "suffix", "optimised", "rename", "naming", "filename", "variables", "date", "counter", "overwrite"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "files.images.specificFolderNameTemplateImage", keys: ["specificFolderNameTemplateImage"],
            title: "Path template for Specific folder",
            subtitle: "",
            keywords: ["%P", "%f", "folder", "destination", "output path", "where", "naming", "pattern", "subfolder", "variables"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "files.images.convertedSameFolderNameTemplateImage", keys: ["convertedSameFolderNameTemplateImage"],
            title: "Converted file name template for Same folder as original",
            subtitle: "",
            keywords: ["%f", "webp", "heic", "jpeg", "conversion", "rename", "naming", "pattern", "leftover", "variables", "manual convert"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "files.images.convertedSpecificFolderNameTemplateImage", keys: ["convertedSpecificFolderNameTemplateImage"],
            title: "Converted file path template for Specific folder",
            subtitle: "",
            keywords: ["%P", "%f", "webp", "heic", "jpeg", "conversion", "destination", "output path", "subfolder", "naming", "manual convert"], tab: .files, section: "Images"
        ),
        SettingEntry(
            id: "general.editwithexternalapp.editorAppImage", keys: ["editorAppImage"],
            title: "Images",
            subtitle: "",
            keywords: ["editor", "external app", "open with", "photoshop", "pixelmator", "affinity", "preview", "edit with", "⌘e", "cmd e", "choose app"], tab: .general, section: "Edit with external app"
        ),
        SettingEntry(
            id: "audio.watchpaths.audioDirs", keys: [],
            title: "Watch paths",
            subtitle: "Optimise audio files as they appear in these folders",
            keywords: ["folder", "directory", "watched", "monitor", "add folder", "incoming", "music", "downloads", "automatic", "clopignore", "ignore rules", "path list"], tab: .audio, section: "Watch paths"
        ),
        SettingEntry(
            id: "audio.watchpaths.enableAutomaticAudioOptimisations", keys: ["enableAutomaticAudioOptimisations"],
            title: "Enable **audio** auto-optimiser",
            subtitle: "",
            keywords: ["watch", "watcher", "folder", "automatic", "background", "turn on", "turn off", "disable", "stop", "not optimising", "nothing happens"], tab: .audio, section: "Watch paths"
        ),
        SettingEntry(
            id: "audio.optimisationrules.audioCompression", keys: ["audioCompression"],
            title: "Compression",
            subtitle: "WAV, AIFF and FLAC are lossless, so the compression factor does not apply to them.",
            keywords: ["quality", "bitrate", "kbps", "percent", "slider", "smaller", "file size", "vbr", "variable bitrate", "aac", "mp3", "lossy", "aggressive"], tab: .audio, section: "Optimisation rules"
        ),
        SettingEntry(
            id: "audio.watchedfilefilters.minAudioSizeKB", keys: ["minAudioSizeKB", "maxAudioSizeMB"],
            title: "File size",
            subtitle: "",
            keywords: ["skip", "skipped", "ignore", "threshold", "too big", "too small", "limit", "range", "mb", "kb", "large", "small", "podcast", "untouched"], tab: .audio, section: "Watched file filters"
        ),
        SettingEntry(
            id: "audio.watchedfilefilters.maxAudioFileCount", keys: ["maxAudioFileCount"],
            title: "File count",
            subtitle: "",
            keywords: ["batch", "bulk", "many", "at once", "limit", "skip", "copied", "moved", "album", "import", "nothing happens", "too many"], tab: .audio, section: "Watched file filters"
        ),
        SettingEntry(
            id: "audio.compatibility.formatsToConvertToAAC", keys: ["formatsToConvertToAAC"],
            title: "Convert to AAC (M4A)",
            subtitle: "",
            keywords: ["m4a", "flac", "aiff", "wav", "lossless", "target", "output", "pills", "toggle", "re-encode", "exclusive"], tab: .audio, section: "Compatibility"
        ),
        SettingEntry(
            id: "audio.compatibility.formatsToConvertToMP3", keys: ["formatsToConvertToMP3"],
            title: "Convert to MP3",
            subtitle: "",
            keywords: ["wav", "flac", "aiff", "lossless", "target", "output", "pills", "toggle", "re-encode", "exclusive"], tab: .audio, section: "Compatibility"
        ),
        SettingEntry(
            id: "general.editwithexternalapp.editorAppAudio", keys: ["editorAppAudio"],
            title: "Audio",
            subtitle: "",
            keywords: ["editor", "external app", "open with", "choose", "edit", "cmd e", "audacity", "ferrite", "fission", "default", "waveform"], tab: .general, section: "Edit with external app"
        ),
        SettingEntry(
            id: "files.audio.sameFolderNameTemplateAudio", keys: ["sameFolderNameTemplateAudio"],
            title: "Optimised audio name template",
            subtitle: "",
            keywords: ["filename", "rename", "pattern", "%f", "variables", "placeholder", "same folder", "placement", "copy", "beside", "next to"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "files.audio.specificFolderNameTemplateAudio", keys: ["specificFolderNameTemplateAudio"],
            title: "Optimised audio path template",
            subtitle: "",
            keywords: ["filename", "rename", "pattern", "%p", "%f", "variables", "placeholder", "specific folder", "placement", "destination", "output"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "files.audio.convertedSameFolderNameTemplateAudio", keys: ["convertedSameFolderNameTemplateAudio"],
            title: "Converted audio name template",
            subtitle: "",
            keywords: ["filename", "rename", "pattern", "%f", "conversion", "wav", "mp3", "aac", "variables", "placeholder", "same folder", "beside"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "files.audio.convertedSpecificFolderNameTemplateAudio", keys: ["convertedSpecificFolderNameTemplateAudio"],
            title: "Converted audio path template",
            subtitle: "",
            keywords: ["filename", "rename", "pattern", "%p", "%f", "conversion", "wav", "mp3", "variables", "placeholder", "specific folder", "destination", "output"], tab: .files, section: "Audio"
        ),
        SettingEntry(
            id: "pdf.watchpaths.pdfDirs", keys: [],
            title: "Watch paths",
            subtitle: "Optimise PDFs as they appear in these folders",
            keywords: ["directories", "monitor", "downloads", "desktop", "clopignore", "ignore rules", "drop", "incoming"], tab: .pdf, section: "Watch paths"
        ),
        SettingEntry(
            id: "pdf.watchpaths.enableAutomaticPDFOptimisations", keys: ["enableAutomaticPDFOptimisations"],
            title: "Enable PDF auto-optimiser",
            subtitle: "",
            keywords: ["watch", "folder", "background", "monitor", "turn off", "disable", "stop", "incoming", "downloads", "not optimising"], tab: .pdf, section: "Watch paths"
        ),
        SettingEntry(
            id: "pdf.optimisationrules.pdfDPI", keys: ["pdfDPI"],
            title: "Compression",
            subtitle: "Clop automatically picks a per-PDF DPI from the source image density and downscales images above it",
            keywords: ["resolution", "quality", "adaptive", "scanned", "lossless", "150", "300", "blurry", "ghostscript", "shrink", "smaller", "file size", "text quality", "pixelated"], tab: .pdf, section: "Optimisation rules"
        ),
        SettingEntry(
            id: "pdf.watchedfilefilters.minPDFSizeKB", keys: ["minPDFSizeKB", "maxPDFSizeMB"],
            title: "File size",
            subtitle: "",
            keywords: ["skip", "too big", "too small", "ignored", "limit", "minimum", "maximum", "mb", "kb", "range", "large", "huge", "not optimised"], tab: .pdf, section: "Watched file filters"
        ),
        SettingEntry(
            id: "pdf.watchedfilefilters.maxPDFFileCount", keys: ["maxPDFFileCount"],
            title: "File count",
            subtitle: "Skips optimisation when more than this many PDFs are copied or moved at once",
            keywords: ["batch", "bulk", "threshold", "ignored", "watched folder", "nothing happened", "limit", "multiple files"], tab: .pdf, section: "Watched file filters"
        ),
        SettingEntry(
            id: "general.editwithexternalapp.editorAppPDF", keys: ["editorAppPDF"],
            title: "PDFs",
            subtitle: "",
            keywords: ["editor", "open with", "external app", "edit", "choose app", "preview", "acrobat", "pdf expert", "cmd e", "⌘e", "default app", "hand off"], tab: .general, section: "Edit with external app"
        ),
        SettingEntry(
            id: "files.pdf.sameFolderNameTemplatePDF", keys: ["sameFolderNameTemplatePDF"],
            title: "Same folder name template",
            subtitle: "",
            keywords: ["filename", "rename", "pattern", "suffix", "optimised", "tokens", "next to", "beside", "overwrite", "copy"], tab: .files, section: "PDF"
        ),
        SettingEntry(
            id: "files.pdf.specificFolderNameTemplatePDF", keys: ["specificFolderNameTemplatePDF"],
            title: "Specific folder name template",
            subtitle: "",
            keywords: ["path", "filename", "rename", "pattern", "destination", "output", "tokens", "where do they go", "subfolder"], tab: .files, section: "PDF"
        ),
        SettingEntry(
            id: "images.photosintegration.photoCropOrientation", keys: ["photoCropOrientation"],
            title: "Photos crop orientation",
            subtitle: "",
            keywords: ["portrait", "landscape", "adaptive", "longest edge", "height", "width", "resize", "aspect", "segmented", "picker"], tab: .images, section: "Photos integration"
        ),
        SettingEntry(
            id: "clipboard.ignoredapps.clipboardIgnoredAppBundleIds", keys: [],
            title: "Ignored apps",
            subtitle: "Skip clipboard optimisation while one of these apps is in front",
            keywords: ["denylist", "blacklist", "exclude", "exclusion", "bundle id", "frontmost", "foreground app", "pixelmator", "figma", "password manager", "copy", "paste", "per app"], tab: .clipboard, section: "Ignored apps"
        ),
        SettingEntry(
            id: "general.main.showMenubarIcon", keys: ["showMenubarIcon", "useClassicMenubarIcon", "useGeometricMenubarIcon"],
            title: "Menubar icon",
            subtitle: "",
            keywords: ["status bar", "tray", "hide", "hidden", "style", "classic", "geometric", "new", "eye slash", "top bar", "missing", "disappeared"], tab: .general, section: ""
        ),
        SettingEntry(
            id: "general.main.allowClopToAppearInScreenshots", keys: ["allowClopToAppearInScreenshots"],
            title: "Show Clop UI in screenshots",
            subtitle: "",
            keywords: ["screen recording", "capture", "floating results", "drop zone", "visible", "hidden", "cleanshot", "record", "demo", "share"], tab: .general, section: ""
        ),
        SettingEntry(
            id: "general.main.pauseAutomaticOptimisations", keys: ["pauseAutomaticOptimisations"],
            title: "Pause automatic optimisations",
            subtitle: "",
            keywords: ["resume", "stop", "disable", "snooze", "watcher", "watched folders", "clipboard", "nothing happens", "not working", "temporarily", "off"], tab: .general, section: ""
        ),
        SettingEntry(
            id: "general.workingdirectory.workdir", keys: ["workdir"],
            title: "Working directory path",
            subtitle: "",
            keywords: ["workdir", "folder", "cache", "temp", "temporary", "backups", "scratch", "disk space", "location", "move", "reset"], tab: .general, section: "Working directory"
        ),
        SettingEntry(
            id: "keys.triggerkeys.keyComboModifiers", keys: ["keyComboModifiers"],
            title: "Trigger keys",
            subtitle: "",
            keywords: ["modifier", "modifiers", "hotkey", "shortcut", "control", "shift", "option", "command", "ctrl", "hold", "combo", "global"], tab: .keys, section: "Trigger keys"
        ),
        SettingEntry(
            id: "keys.actionkeys.enabledKeys", keys: ["enabledKeys"],
            title: "Action keys",
            subtitle: "",
            keywords: [
                "hotkey",
                "shortcut",
                "downscale",
                "quicklook",
                "rename",
                "restore original",
                "pause",
                "escape",
                "dismiss",
                "clear all",
                "bring back",
                "speed up",
                "aggressive",
                "optimise aggressively",
                "optimise clipboard",
                "stop",
                "paste",
                "keycap",
            ], tab: .keys, section: "Action keys"
        ),
        SettingEntry(
            id: "keys.resizekeys.quickResizeKeys", keys: ["quickResizeKeys"],
            title: "Resize keys",
            subtitle: "",
            keywords: ["downscale", "percent", "percentage", "10%", "20%", "90%", "tens", "number row", "hotkey", "shortcut", "scale", "shrink", "smaller", "trigger", "hold", "quick"], tab: .keys, section: "Resize keys"
        ),
        SettingEntry(
            id: "floating.main.floatingResultActions", keys: ["floatingResultActions"],
            title: "Action buttons",
            subtitle: "",
            keywords: ["floating result", "grid", "icons", "share", "quicklook", "customise", "reorder", "remove", "add", "toolbar", "send securely", "aggressive", "downscale"], tab: .floating, section: ""
        ),
        SettingEntry(
            id: "floating.main.compactResultActions", keys: ["compactResultActions"],
            title: "Side actions",
            subtitle: "",
            keywords: ["compact result", "icons", "buttons", "row", "customise", "add", "remove", "quicklook", "share", "crop", "show in finder", "save as"], tab: .floating, section: ""
        ),
        SettingEntry(
            id: "images.watchpaths.dirsHideFloatingResult", keys: [],
            title: "Show floating results",
            subtitle: "Show the floating thumbnail and progress when files in this folder are optimised",
            keywords: ["watched", "silent", "quiet", "hide", "no popup", "background", "checkbox", "column", "notification", "per directory"], tab: .images, section: "Watch paths"
        ),
        SettingEntry(
            id: "presetZones.presetzones.presetZones", keys: [],
            title: "Preset zones",
            subtitle: "Click a zone to assign or create a pipeline. Drag files onto a zone to run its actions.",
            keywords: ["drop target", "quadrant", "corner", "control key", "image", "video", "audio", "pdf", "automation"], tab: .presetZones, section: "Preset zones"
        ),

    ]

    static let byID: [String: SettingEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Words a query carries and a settings row does not. Dropped rather than down-weighted, because
    /// `requireAll` is the problem: someone types "replacing the original video", the row that answers
    /// it has no "the" anywhere, and requiring the word throws the answer away and keeps whichever
    /// rows happen to have a full sentence for a subtitle.
    ///
    /// A fixed list rather than one read off the index. In 125 rows "the" looks rare enough to matter
    /// and it never does, so frequency is the wrong instrument here.
    static let stopWords: Set = [
        "an", "and", "any", "are", "as", "at", "be", "but", "by", "can", "do", "does", "for", "from",
        "get", "has", "have", "how", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not",
        "of", "on", "or", "so", "some", "that", "the", "their", "them", "then", "there", "these",
        "they", "this", "to", "was", "what", "when", "where", "which", "why", "will", "with", "would",
        "you", "your",
    ]

    /// Split into lowercase words. Shared by the index and the query so both are cut the same way.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// How well a query word matches an indexed word, 0 when it does not.
    ///
    /// Graded rather than yes/no, because the rungs have to outrank each other: typing "send" must put
    /// the row called "Send securely" above a row that merely mentions "sender" in a keyword.
    ///
    /// The prefix rung carries the field while you are still typing, and it has no minimum length on
    /// purpose. An earlier version needed four characters before it would look at a prefix at all,
    /// which meant "sen" found nothing and the field looked broken until the fourth keystroke.
    static func wordScore(_ query: String, _ indexed: String) -> Double {
        if query == indexed { return 1 }
        if indexed.hasPrefix(query) { return 0.9 }
        // Neither is a prefix of the other, and they can still be the same word: "replacing" and
        // "replace" part ways at the seventh letter. A strict prefix test scores that pair zero, which
        // is exactly how a question about Clop "replacing" the original missed the row whose keyword is
        // "replace". Scored by how much of the longer word the stem accounts for, so a real inflection
        // lands near a prefix hit and "compression" against "compatibility" lands nowhere.
        let stem = sharedPrefixLength(query, indexed)
        let ratio = Double(stem) / Double(max(query.count, indexed.count))
        if stem >= 4, ratio >= 0.5 { return 0.85 * ratio }
        if query.count >= 4, indexed.contains(query) { return 0.5 }
        return 0
    }

    /// Is `query` a subsequence of `text`, and how tightly packed? nil when it is not in there at all.
    ///
    /// The fzf trick, and the net for typos and abbreviations: "clipbord" and "metdata" are nobody's
    /// word, and both are one dropped letter from a row that exists. Runs of adjacent letters and
    /// letters landing on a word boundary score higher, which is what keeps the loose matches off rows
    /// that merely happen to contain the letters somewhere.
    ///
    /// Four characters minimum: below that the letters of a query are scattered through most of the
    /// index and the score means nothing.
    static func subsequenceScore(_ query: String, _ text: String) -> Double? {
        guard query.count >= 4, text.count >= query.count else { return nil }
        let q = Array(query), t = Array(text)
        var score = 0, streak = 0, ti = 0

        for ch in q {
            var found = false
            while ti < t.count {
                if t[ti] == ch {
                    let atWordStart = ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber)
                    streak += 1
                    score += 1 + streak * 3 + (atWordStart ? 6 : 0)
                    ti += 1
                    found = true
                    break
                }
                streak = 0
                ti += 1
            }
            guard found else { return nil }
        }

        // Against a perfect contiguous run starting at a word boundary, so a long subtitle that happens
        // to contain the letters cannot outscore a short title that spells them out.
        let perfect = q.indices.reduce(6) { $0 + 1 + ($1 + 1) * 3 }
        return min(1, Double(score) / Double(perfect))
    }

    /// The best any field of `entry` does with one query word.
    static func tokenScore(_ token: String, in entry: SettingEntry) -> Double {
        var best = 0.0
        for field in entry.searchFields {
            for word in field.words {
                let score = wordScore(token, word)
                guard score > 0 else { continue }
                best = max(best, field.weight * score)
            }
        }
        guard best == 0 else { return best }

        // Only once no whole word matched. Held below the weakest whole-word rung deliberately: a
        // subsequence hit is a guess, and it must never push a row that really carries the word down.
        for field in entry.searchTexts {
            guard let score = subsequenceScore(token, field.text) else { continue }
            best = max(best, field.weight * score * 0.4)
        }
        return best
    }

    /// Rows matching the query, best first.
    ///
    /// `requireAll` is what separates the two callers. The Settings field passes true, because someone
    /// typing two words expects both to count. An agent hands over a whole sentence full of words no
    /// row carries, so `MCPSettingsBridge.matches` passes false and leans on the scoring instead.
    static func rank(_ query: String, requireAll: Bool, limit: Int = 25) -> [SettingEntry] {
        var tokens = Array(Set(words(query).filter { $0.count > 1 && !stopWords.contains($0) }))
        // Unless the query is nothing but function words, in which case they are all there is to go on.
        if tokens.isEmpty { tokens = Array(Set(words(query).filter { $0.count > 1 })) }
        guard !tokens.isEmpty else { return [] }

        // Scored once per row and word, then reused for the weighting below. The weighting needs to
        // know how many rows each word hits, and running a fuzzy matcher over the whole index twice is
        // the expensive half of a keystroke.
        let scores = all.map { entry in tokens.map { tokenScore($0, in: entry) } }
        let hits = tokens.indices.map { t in scores.reduce(0.0) { $0 + ($1[t] > 0 ? 1 : 0) } }
        // Squared, so the one word that decides the answer dominates the ones every row carries. Plain
        // inverse document frequency damps too gently for a query that is a whole sentence: "the" is in
        // 37 rows and "mp4" is in 5, and a title match on "the" was outscoring the row that actually
        // answers the question.
        let weights = hits.map { pow(Foundation.log((Double(all.count) + 1) / ($0 + 1)) + 0.1, 2) }

        return zip(all, scores).compactMap { entry, rowScores -> (SettingEntry, Double)? in
            var total = 0.0
            var matched = 0
            for (t, score) in rowScores.enumerated() where score > 0 {
                matched += 1
                total += score * weights[t]
            }
            guard matched > 0 else { return nil }
            if requireAll, matched < tokens.count { return nil }
            return (entry, total)
        }
        .sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    /// What the Settings search field calls: rows matching every word, best first.
    ///
    /// Falling back to the partial match keeps the field from dead-ending. Someone types a phrase with
    /// one word no row carries and the answer is still one word away, so showing the rows that match
    /// the rest beats "Nothing matches".
    static func search(_ query: String) -> [SettingEntry] {
        let strict = rank(query, requireAll: true)
        return strict.isEmpty ? rank(query, requireAll: false) : strict
    }

    private static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

}
