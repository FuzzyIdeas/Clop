import Cocoa
import Defaults
import Foundation
import System
import UniformTypeIdentifiers

enum ItemType: Equatable, Identifiable {
    case image(UTType)
    case video(UTType)
    case audio(UTType)
    case pdf
    case url
    case unknown

    var id: String {
        switch self {
        case let .image(utType):
            utType.identifier
        case let .video(utType):
            utType.identifier
        case let .audio(utType):
            utType.identifier
        case .pdf:
            "pdf"
        case .url:
            "url"
        case .unknown:
            "unknown"
        }
    }

    var convertibleTypes: [UTType] {
        switch self {
        case .image:
            [.jpeg, .webP, .avif, .heic, .png, .jxl].compactMap { $0 }
        case .video:
            [.mpeg4Movie, .quickTimeMovie, .gif, .webm, .hevcVideo, .av1Video].compactMap { $0 }
        case .audio:
            [.m4a, .mp3, .oggAudio, .wav].compactMap { $0 }
        default:
            []
        }
    }

    var str: String {
        switch self {
        case .image:
            "image"
        case .video:
            "video"
        case .audio:
            "audio"
        case .pdf:
            "PDF"
        case .url:
            "file"
        case .unknown:
            "file"
        }
    }

    var icon: String {
        switch self {
        case .image:
            "photo"
        case .video:
            "film"
        case .audio:
            "waveform"
        case .pdf:
            "doc.text"
        case .url:
            "link"
        case .unknown:
            "questionmark"
        }
    }

    var ext: String? {
        switch self {
        case let .image(uTType):
            uTType.preferredFilenameExtension
        case let .video(uTType):
            uTType.preferredFilenameExtension
        case let .audio(uTType):
            uTType.preferredFilenameExtension
        case .pdf:
            "pdf"
        case .url:
            nil
        case .unknown:
            nil
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo.fill"
        case .video: "video.fill"
        case .audio: "waveform"
        case .pdf: "doc.fill"
        default: "doc.fill"
        }
    }

    var isImage: Bool {
        switch self {
        case .image:
            true
        default:
            false
        }
    }

    var isVideo: Bool {
        switch self {
        case .video:
            true
        default:
            false
        }
    }

    var isAudio: Bool {
        switch self {
        case .audio:
            true
        default:
            false
        }
    }

    var isPDF: Bool {
        switch self {
        case .pdf:
            true
        default:
            false
        }
    }

    var isURL: Bool {
        switch self {
        case .url:
            true
        default:
            false
        }
    }

    var utType: UTType? {
        switch self {
        case let .image(utType):
            utType
        case let .video(utType):
            utType
        case let .audio(utType):
            utType
        case .pdf:
            .pdf
        case .url:
            nil
        case .unknown:
            nil
        }
    }

    var pipelineKey: Defaults.Key<[String: [Pipeline]]>? {
        switch self {
        case .image:
            .pipelinesToRunOnImage
        case .video:
            .pipelinesToRunOnVideo
        case .pdf:
            .pipelinesToRunOnPdf
        case .audio:
            .pipelinesToRunOnAudio
        default:
            nil
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType? {
        switch self {
        case let .image(utType):
            utType.pasteboardType
        case let .video(utType):
            utType.pasteboardType
        case let .audio(utType):
            utType.pasteboardType
        case .pdf:
            .pdf
        case .url:
            .URL
        case .unknown:
            nil
        }
    }

    static func from(mimeType: String) -> ItemType {
        switch mimeType {
        case "image/jpeg", "image/png", "image/gif", "image/tiff", "image/webp", "image/heic", "image/heif", "image/avif":
            .image(UTType(mimeType: mimeType)!)
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/x-mpeg":
            .video(UTType(mimeType: mimeType)!)
        case "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff", "audio/flac", "audio/ogg", "audio/opus":
            .audio(UTType(mimeType: mimeType) ?? .mp3)
        case "application/pdf":
            .pdf
        case "text/html":
            .url
        default:
            .unknown
        }
    }
    static func from(filePath: FilePath) -> ItemType {
        guard let fileType = filePath.fetchFileType()?.split(separator: ";").first?.s else {
            return .unknown
        }

        switch fileType {
        case "image/jpeg", "image/png", "image/gif", "image/tiff", "image/webp", "image/heic", "image/heif", "image/avif":
            return .image(UTType(mimeType: fileType)!)
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/x-ms-wmv", "video/x-mpeg", "video/webm":
            return .video(UTType(mimeType: fileType)!)
        case "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff", "audio/flac", "audio/ogg", "audio/opus":
            return .audio(UTType(mimeType: fileType) ?? .mp3)
        case "application/pdf":
            return .pdf
        case "text/html":
            return .url
        default:
            return .unknown
        }
    }
}
