import Cocoa
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

let BASE64_PREFIX = #/(url\()?data:image/[^;]+;base64,/#

enum ClipboardType: Equatable {
    case image(Image)
    case file(FilePath)
    case url(URL)
    case unknown

    var isImage: Bool {
        switch self {
        case .image: true
        case let .file(path): path.isImage
        case let .url(url): url.isImage
        default: false
        }
    }

    var isVideo: Bool {
        switch self {
        case let .file(path): path.isVideo
        case let .url(url): url.isVideo
        default: false
        }
    }

    var isPDF: Bool {
        switch self {
        case let .file(path): path.isPDF
        case let .url(url): url.isPDF
        default: false
        }
    }

    var isAudio: Bool {
        switch self {
        case let .file(path): path.isAudio
        case let .url(url): url.isAudio
        default: false
        }
    }

    var id: String {
        switch self {
        case let .image(img): img.path.string
        case let .file(path): path.string
        case let .url(url): url.path
        case .unknown: ""
        }
    }

    var path: FilePath {
        switch self {
        case let .image(img): img.path
        case let .file(path): path
        case let .url(url): FilePath.downloads / url.lastPathComponent.safeFilename
        case .unknown: ""
        }
    }

    static func == (lhs: ClipboardType, rhs: ClipboardType) -> Bool {
        lhs.id == rhs.id
    }

    static func fromURL(_ url: URL) -> ClipboardType {
        if url.isFileURL {
            return .file(url.filePath!)
        }

        return .url(url)
    }

    static func fromString(_ str: String) -> ClipboardType {
        if let data = Data(base64Encoded: str.replacing(BASE64_PREFIX, with: "").trimmedPath), let img = Image(data: data, retinaDownscaled: false) {
            return .image(img)
        }

        let str = str.trimmedPath
        let path = str.starts(with: "file:") ? str.url?.filePath : str.existingFilePath
        if let path {
            return .file(path)
        }

        if str.contains(":"), let url = str.url {
            return .url(url)
        }

        return .unknown
    }

    static func lastItem() -> ClipboardType {
        guard let item = NSPasteboard.general.pasteboardItems?.first else {
            return .unknown
        }
        return fromPasteboardItem(item)
    }

    static func fromPasteboardItem(_ item: NSPasteboardItem) -> ClipboardType {
        if let path = item.string(forType: .fileURL)?.trimmedPath.url?.filePath ?? item.string(forType: .string)?.trimmedPath.existingFilePath {
            if path.isPDF || path.isVideo || path.isAudio {
                return .file(path)
            }
            if path.isImage, let img = Image(path: path, retinaDownscaled: false) {
                return .image(img)
            }
        }

        if let img = try? Image.fromPasteboard(item: item, anyType: true) {
            return .image(img)
        }

        if let str = item.string(forType: .string), let data = Data(base64Encoded: str.replacing(BASE64_PREFIX, with: "").trimmedPath), let img = Image(data: data, retinaDownscaled: false) {
            return .image(img)
        }

        if let path = item.string(forType: .fileURL)?.trimmedPath.url?.filePath ?? item.string(forType: .string)?.trimmedPath.existingFilePath {
            return .file(path)
        }

        if let url = item.string(forType: .URL)?.url ?? item.string(forType: .string)?.url {
            return .url(url)
        }

        return .unknown
    }
}
