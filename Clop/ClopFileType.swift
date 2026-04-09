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

    var optimisedBehaviourKey: Defaults.Key<OptimisedFileBehaviour> {
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

    var optimisedFileBehaviour: OptimisedFileBehaviour {
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
