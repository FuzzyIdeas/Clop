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

    var searchCorpus: String {
        ([title, subtitle, section, tab.title] + keywords).joined(separator: " ").lowercased()
    }

    /// The words of each field, kept apart so a hit in the title can outrank one buried in a subtitle.
    var searchFields: [(weight: Double, words: [String])] {
        [
            (3.0, SettingsSearchIndex.words(title)),
            (2.5, keywords.flatMap { SettingsSearchIndex.words($0) }),
            (1.0, SettingsSearchIndex.words(subtitle)),
            (0.6, SettingsSearchIndex.words(section) + SettingsSearchIndex.words(tab.title)),
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
            id: "video.optimisationrules.capVideoFPS", keys: ["capVideoFPS"],
            title: "Cap frames per second",
            subtitle: "Limit the frame rate of optimised videos",
            keywords: ["fps", "frame rate", "frames per second", "30fps", "60fps", "smooth", "slow"], tab: .video, section: "Optimisation rules"
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
            subtitle: "What to do with embedded artwork when optimising audio",
            keywords: [], tab: .audio, section: "Optimisation rules"
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

    ]

    static let byID: [String: SettingEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Split into lowercase words. Shared by the index and the query so both are cut the same way.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Does a query word match an indexed word?
    ///
    /// Prefix, not equality, because people and agents inflect: someone asks why Clop is not
    /// "replacing" the file and the row's keyword is "replace". Four characters is the shortest prefix
    /// worth trusting; below that "in" would match "inPlace" and every other word starting in-.
    static func wordMatches(_ query: String, _ indexed: String) -> Bool {
        if query == indexed { return true }
        guard query.count >= 4, indexed.count >= 4 else { return false }
        return query.hasPrefix(indexed.prefix(4)) && (query.hasPrefix(indexed) || indexed.hasPrefix(query))
    }

    /// Rows matching the query, best first.
    ///
    /// `requireAll` is what separates the two callers. The Settings field passes true, because someone
    /// typing two words expects both to count. An agent hands over a whole sentence full of words no
    /// row carries, so `MCPSettingsBridge.matches` passes false and leans on the scoring instead.
    static func rank(_ query: String, requireAll: Bool, limit: Int = 25) -> [SettingEntry] {
        let queryWords = words(query).filter { $0.count > 1 }
        guard !queryWords.isEmpty else { return [] }
        let weights = Dictionary(uniqueKeysWithValues: Set(queryWords).map { ($0, idf($0)) })

        return all.compactMap { entry -> (SettingEntry, Double)? in
            var score = 0.0
            var matched = 0
            for word in Set(queryWords) {
                var best = 0.0
                for field in entry.searchFields where field.words.contains(where: { wordMatches(word, $0) }) {
                    best = max(best, field.weight)
                }
                guard best > 0 else { continue }
                matched += 1
                score += best * (weights[word] ?? 1)
            }
            guard matched > 0 else { return nil }
            if requireAll, matched < Set(queryWords).count { return nil }
            return (entry, score)
        }
        .sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    /// Rows matching every word of the query, best first. What the Settings search field calls.
    static func search(_ query: String) -> [SettingEntry] {
        rank(query, requireAll: true)
    }

    /// How much one query word is worth: a lot when few rows carry it, almost nothing when most do.
    ///
    /// Without this, a question like "why is Clop not replacing the mov with the optimised mp4" ranks
    /// by its most common word. "optimised" is in half the index and "mov" is in one row, and the
    /// answer is the row with "mov" in it. This is plain inverse document frequency, and it does the
    /// job a stop-word list would do without anyone having to maintain the list.
    private static func idf(_ word: String) -> Double {
        let total = Double(all.count)
        let hits = all.reduce(0.0) { count, entry in
            count + (entry.searchFields.contains { $0.words.contains { wordMatches(word, $0) } } ? 1 : 0)
        }
        return Foundation.log((total + 1) / (hits + 1)) + 0.1
    }

}
