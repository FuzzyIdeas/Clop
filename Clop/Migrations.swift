import Defaults
import Foundation
import Lowtech

enum Migrations {
    static func run() {
        clopIgnoreMigrate()
        portablePathsMigrate()
    }

    /// Rewrite every stored path into its portable form (`~/Pictures` instead of `/Users/alin/Pictures`).
    ///
    /// Settings sync between Macs through iCloud and the username can differ, so an absolute home
    /// path arrives on the other Mac pointing at a folder that isn't there: a watched folder that
    /// watches nothing, a folder automation keyed to a path no file will ever match. Runs on every
    /// launch, not once, so values pushed by a Mac still on an older version get normalised too.
    /// `portablePath` is idempotent, and each key is only written when something actually changed.
    static func portablePathsMigrate() {
        for key in [Defaults.Keys.imageDirs, .videoDirs, .pdfDirs, .audioDirs] {
            let dirs = Defaults[key].map(\.portablePath).uniqued
            if dirs != Defaults[key] {
                Defaults[key] = dirs
            }
        }

        let hidden = Set(Defaults[.dirsHideFloatingResult].map(\.portablePath))
        if hidden != Defaults[.dirsHideFloatingResult] {
            Defaults[.dirsHideFloatingResult] = hidden
        }

        for key in [
            Defaults.Keys.specificFolderNameTemplateImage, .specificFolderNameTemplateVideo,
            .specificFolderNameTemplateAudio, .specificFolderNameTemplatePDF,
            .convertedSpecificFolderNameTemplateImage, .convertedSpecificFolderNameTemplateVideo,
            .convertedSpecificFolderNameTemplateAudio,
            .workdir, .editorAppImage, .editorAppVideo, .editorAppAudio, .editorAppPDF,
        ] {
            let value = Defaults[key].portablePath
            if value != Defaults[key] {
                Defaults[key] = value
            }
        }

        for key in [
            Defaults.Keys.pipelinesToRunOnImage, .pipelinesToRunOnVideo,
            .pipelinesToRunOnPdf, .pipelinesToRunOnAudio,
        ] {
            // Folder automations are keyed by the folder path, so the key moves too. Merge instead
            // of overwriting, in case both forms of the same folder ended up stored.
            var migrated: [String: [Pipeline]] = [:]
            for (source, pipelines) in Defaults[key] {
                migrated[source.portablePath, default: []] += pipelines.map(\.portablePaths)
            }
            if migrated != Defaults[key] {
                Defaults[key] = migrated
            }
        }

        let saved = Defaults[.savedPipelines].map(\.portablePaths)
        if saved != Defaults[.savedPipelines] {
            Defaults[.savedPipelines] = saved
        }

        let zones = Defaults[.presetZones].map { zone -> PresetZone in
            var zone = zone
            zone.pipeline = zone.pipeline.portablePaths
            return zone
        }
        if zones != Defaults[.presetZones] {
            Defaults[.presetZones] = zones
        }
    }

    static func clopIgnoreMigrate() {
        for fileType in ClopFileType.allCases {
            let key = Defaults.Key<[String]?>("\(fileType.rawValue)Dirs")
            for dir in Defaults[key]?.compactMap(\.existingFilePath) ?? [] {
                let clopIgnore = dir / ".clopignore"
                guard clopIgnore.exists else {
                    continue
                }

                for otherFileType in fileType.otherCases {
                    let key = Defaults.Key<[String]?>("\(otherFileType.rawValue)Dirs")
                    guard let dirs = Defaults[key], dirs.contains(dir.string) else {
                        continue
                    }
                    let newClopIgnore = dir / ".clopignore-\(otherFileType.rawValue)"
                    _ = try? clopIgnore.copy(to: newClopIgnore)
                }

                let newClopIgnore = dir / ".clopignore-\(fileType.rawValue)"
                if newClopIgnore.exists {
                    try? clopIgnore.delete()
                } else {
                    _ = try? clopIgnore.move(to: newClopIgnore)
                }
            }
        }
    }
}
