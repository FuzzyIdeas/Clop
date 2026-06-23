import Defaults
import Foundation
import SwiftUI
import System

enum ClopFileType: String, CaseIterable, CustomStringConvertible, Codable {
    case image
    case video
    case audio
    case pdf

    var defaultNameTemplatePath: FilePath {
        switch self {
        case .image:
            "~/Desktop/shot.png".filePath!
        case .video:
            "~/Desktop/rec.mp4".filePath!
        case .audio:
            "~/Desktop/rec.m4a".filePath!
        case .pdf:
            "~/Desktop/doc.pdf".filePath!
        }
    }

    var optimisedBehaviourKey: Defaults.Key<FileBehaviour> {
        switch self {
        case .image:
            .optimisedImageBehaviour
        case .video:
            .optimisedVideoBehaviour
        case .audio:
            .optimisedAudioBehaviour
        case .pdf:
            .optimisedPDFBehaviour
        }
    }

    func behaviourKey(for kind: OutputKind) -> Defaults.Key<FileBehaviour>? {
        switch kind {
        case .optimised:
            return optimisedBehaviourKey
        case .autoConvert:
            switch self {
            case .image: return .convertedImageBehaviour
            case .video: return .convertedVideoBehaviour
            case .audio: return .convertedAudioBehaviour
            case .pdf: return nil
            }
        case .manualConvert:
            switch self {
            case .image: return .manualConvertedImageBehaviour
            case .video: return .manualConvertedVideoBehaviour
            case .audio: return .manualConvertedAudioBehaviour
            case .pdf: return nil
            }
        }
    }

    func behaviour(for kind: OutputKind) -> FileBehaviour? {
        behaviourKey(for: kind).map { Defaults[$0] }
    }

    func sameFolderTemplateKey(for kind: OutputKind) -> Defaults.Key<String>? {
        switch kind {
        case .optimised:
            return sameFolderNameTemplateKey
        case .autoConvert, .manualConvert:
            switch self {
            case .image: return .convertedSameFolderNameTemplateImage
            case .video: return .convertedSameFolderNameTemplateVideo
            case .audio: return .convertedSameFolderNameTemplateAudio
            case .pdf: return nil
            }
        }
    }

    func specificFolderTemplateKey(for kind: OutputKind) -> Defaults.Key<String>? {
        switch kind {
        case .optimised:
            return specificFolderNameTemplateKey
        case .autoConvert, .manualConvert:
            switch self {
            case .image: return .convertedSpecificFolderNameTemplateImage
            case .video: return .convertedSpecificFolderNameTemplateVideo
            case .audio: return .convertedSpecificFolderNameTemplateAudio
            case .pdf: return nil
            }
        }
    }

    var sameFolderNameTemplateKey: Defaults.Key<String> {
        switch self {
        case .image:
            .sameFolderNameTemplateImage
        case .video:
            .sameFolderNameTemplateVideo
        case .audio:
            .sameFolderNameTemplateAudio
        case .pdf:
            .sameFolderNameTemplatePDF
        }
    }

    var specificFolderNameTemplateKey: Defaults.Key<String> {
        switch self {
        case .image:
            .specificFolderNameTemplateImage
        case .video:
            .specificFolderNameTemplateVideo
        case .audio:
            .specificFolderNameTemplateAudio
        case .pdf:
            .specificFolderNameTemplatePDF
        }
    }

    var optimisedFileBehaviour: FileBehaviour {
        Defaults[optimisedBehaviourKey]
    }

    var description: String {
        switch self {
        case .image:
            "image"
        case .video:
            "video"
        case .audio:
            "audio"
        case .pdf:
            "PDF"
        }
    }

    var otherCases: [ClopFileType] {
        ClopFileType.allCases.filter { $0 != self }
    }
    var tab: SettingsView.Tabs {
        switch self {
        case .image:
            .images
        case .video:
            .video
        case .audio:
            .audio
        case .pdf:
            .pdf
        }
    }

    var symbolName: String {
        switch self {
        case .image:
            "photo"
        case .video:
            "film"
        case .audio:
            "waveform"
        case .pdf:
            "doc"
        }
    }

    var pipelineKey: Defaults.Key<[String: [Pipeline]]> {
        switch self {
        case .image: .pipelinesToRunOnImage
        case .video: .pipelinesToRunOnVideo
        case .pdf: .pipelinesToRunOnPdf
        case .audio: .pipelinesToRunOnAudio
        }
    }

    var dirsKey: Defaults.Key<[String]> {
        switch self {
        case .image: .imageDirs
        case .video: .videoDirs
        case .pdf: .pdfDirs
        case .audio: .audioDirs
        }
    }

    var color: Color {
        switch self {
        case .image: .blue
        case .video: .red
        case .audio: .purple
        case .pdf: .orange
        }
    }
}
