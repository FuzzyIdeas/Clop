import Cocoa
import Defaults
import Foundation
import ImageIO
import Lowtech
import System
import UniformTypeIdentifiers

enum PipelineAction: CustomStringConvertible {
    case convert(format: UTType)
    case optimise
    case downscale(factor: Double?, cropSize: CropSize?)
    case changePlaybackSpeed(factor: Double)
    case removeAudio
    case runShortcut(Shortcut)

    var description: String {
        switch self {
        case let .convert(format):
            "convert(\(format.preferredFilenameExtension ?? "?"))"
        case .optimise:
            "optimise"
        case let .downscale(factor, cropSize):
            if cropSize != nil { "downscale(crop)" }
            else if let factor { "downscale(\((factor * 100).intround)%)" }
            else { "downscale" }
        case let .changePlaybackSpeed(factor):
            "changePlaybackSpeed(\(factor)x)"
        case .removeAudio:
            "removeAudio"
        case let .runShortcut(shortcut):
            "runShortcut(\(shortcut.name))"
        }
    }

    var isDownscale: Bool {
        if case .downscale = self { return true }
        return false
    }

    var isOptimise: Bool {
        if case .optimise = self { return true }
        return false
    }

    var isConvert: Bool {
        if case .convert = self { return true }
        return false
    }

    var isChangePlaybackSpeed: Bool {
        if case .changePlaybackSpeed = self { return true }
        return false
    }

    var isRemoveAudio: Bool {
        if case .removeAudio = self { return true }
        return false
    }
}

// MARK: - Pipeline Step Data Model

enum EncoderQuality: String, Codable, CaseIterable, Defaults.Serializable {
    case aggressive, medium, lossless
}

enum VideoEncoderQuality: String, Codable, CaseIterable, Defaults.Serializable {
    case efficient, highQuality, lossless
}

enum VideoCodec: String, Codable, CaseIterable, Defaults.Serializable {
    case hevcVideoToolbox = "hevc_videotoolbox"
    case libx265
    case libsvtav1
}

enum ClipboardCopyFormat: String, Codable, CaseIterable, Defaults.Serializable {
    case path, imageData, markdown
}

enum StepLocation: String, Codable, CaseIterable, Defaults.Serializable {
    case inPlace, sameFolder, temporaryFolder
}

// MARK: - FilterCondition

struct FilterCondition: Codable, Hashable, Defaults.Serializable {
    var types: [String]?
    var regex: String?
    var nameContains: String?
    var nameIs: String?
    var fileSizeGreaterThan: Int?
    var fileSizeLowerThan: Int?
    var widthGreaterThan: Int?
    var widthLowerThan: Int?
    var heightGreaterThan: Int?
    var heightLowerThan: Int?

    var isEmpty: Bool {
        let noText: Bool = types == nil && regex == nil && nameContains == nil && nameIs == nil
        let noSize: Bool = fileSizeGreaterThan == nil && fileSizeLowerThan == nil
        let noDims: Bool = widthGreaterThan == nil && widthLowerThan == nil && heightGreaterThan == nil && heightLowerThan == nil
        return noText && noSize && noDims
    }

    func evaluate(file: FilePath, context: TemplateContext) -> (matches: Bool, captures: [String]) {
        let name = file.lastComponent?.string ?? ""
        var captures: [String] = []

        if let types, !types.isEmpty {
            let ext = file.extension ?? ""
            let fileUTType = UTType(filenameExtension: ext)
            let matchesType = types.contains { typeStr in
                guard let uttype = UTType(typeStr) else { return false }
                return fileUTType?.conforms(to: uttype) ?? false
            }
            if !matchesType { return (false, []) }
        }

        if let regex, !regex.isEmpty {
            guard let re = try? NSRegularExpression(pattern: regex) else { return (false, []) }
            let range = NSRange(name.startIndex..., in: name)
            guard let match = re.firstMatch(in: name, range: range) else { return (false, []) }
            for i in 1 ..< match.numberOfRanges {
                if let r = Range(match.range(at: i), in: name) {
                    captures.append(String(name[r]))
                }
            }
        }

        if let nameContains, !nameContains.isEmpty {
            if !name.localizedCaseInsensitiveContains(nameContains) { return (false, []) }
        }

        if let nameIs, !nameIs.isEmpty {
            if name != nameIs { return (false, []) }
        }

        if let fileSizeGreaterThan {
            guard let size = file.fileSize(), size > fileSizeGreaterThan else { return (false, []) }
        }

        if let fileSizeLowerThan {
            guard let size = file.fileSize(), size < fileSizeLowerThan else { return (false, []) }
        }

        if let widthGreaterThan {
            guard let w = imageWidth(file), w > widthGreaterThan else { return (false, []) }
        }

        if let widthLowerThan {
            guard let w = imageWidth(file), w < widthLowerThan else { return (false, []) }
        }

        if let heightGreaterThan {
            guard let h = imageHeight(file), h > heightGreaterThan else { return (false, []) }
        }

        if let heightLowerThan {
            guard let h = imageHeight(file), h < heightLowerThan else { return (false, []) }
        }

        return (true, captures)
    }
}

private func imageWidth(_ file: FilePath) -> Int? {
    guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int
    else { return nil }
    return w
}

private func imageHeight(_ file: FilePath) -> Int? {
    guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return h
}

// MARK: - PipelineStep

enum PipelineStep: Encodable, Hashable, Identifiable, Defaults.Serializable {
    // Processing steps (explicit, no implicit optimisation)
    case optimise(encoder: EncoderQuality = .medium, adaptive: Bool = false, videoEncoder: VideoEncoder? = nil, dpi: Int? = nil, location: String = "inPlace")
    case downscale(factor: Double, location: String = "inPlace")
    case lowerBitrate(kbps: Int, location: String = "inPlace")
    case convert(to: String, location: String = "sameFolder")
    case crop(width: Int? = nil, height: Int? = nil, keepAspectRatio: Bool = true, longEdge: Int? = nil, location: String = "inPlace")
    case extractPagesAsImages(format: String = "jpeg", quality: String = "medium", location: String = "sameFolder")

    // File path operations (template vars supported)
    case copy(to: String)
    case move(to: String)
    case rename(to: String)
    case delete(path: String = "sourceFile")

    // Filters (pipeline stops silently if condition fails)
    case filterIf(FilterCondition)
    case filterIfNot(FilterCondition)

    // Media-specific
    case removeAudio
    case changeSpeed(factor: Double)

    // Generic actions
    case runScript(path: String)
    case runShortcut(Shortcut)
    case copyToClipboard(format: ClipboardCopyFormat = .path, relativeTo: String? = nil)
    case copyLinkForSending

    // App integration
    case shelveWith(app: String)
    case uploadWith(app: String)
    case openWith(app: String)

    var id: String {
        switch self {
        case let .optimise(encoder, adaptive, videoEncoder, dpi, location): "optimise-\(videoEncoder?.rawValue ?? encoder.rawValue)-\(adaptive)-\(dpi ?? 0)-\(location)"
        case let .downscale(factor, location): "downscale-\(factor)-\(location)"
        case let .lowerBitrate(kbps, location): "lowerBitrate-\(kbps)-\(location)"
        case let .convert(to, location): "convert-\(to)-\(location)"
        case let .crop(width, height, _, longEdge, location): "crop-\(longEdge ?? width ?? 0)-\(height ?? 0)-\(location)"
        case let .extractPagesAsImages(format, quality, location): "extractPagesAsImages-\(format)-\(quality)-\(location)"
        case let .copy(to): "copy-\(to)"
        case let .move(to): "move-\(to)"
        case let .rename(to): "rename-\(to)"
        case let .delete(path): "delete-\(path)"
        case .filterIf: "filterIf"
        case .filterIfNot: "filterIfNot"
        case .removeAudio: "removeAudio"
        case let .changeSpeed(factor): "changeSpeed-\(factor)"
        case let .runScript(path): "runScript-\(path)"
        case let .runShortcut(shortcut): "runShortcut-\(shortcut.name)"
        case let .copyToClipboard(format, relativeTo): "copyToClipboard-\(format.rawValue)-\(relativeTo ?? "")"
        case .copyLinkForSending: "copyLinkForSending"
        case let .shelveWith(app): "shelveWith-\(app)"
        case let .uploadWith(app): "uploadWith-\(app)"
        case let .openWith(app): "openWith-\(app)"
        }
    }

    var stepName: String {
        switch self {
        case .optimise: "optimise"
        case .downscale: "downscale"
        case .lowerBitrate: "lowerBitrate"
        case .convert: "convert"
        case .crop: "crop"
        case .extractPagesAsImages: "extractPagesAsImages"
        case .copy: "copy"
        case .move: "move"
        case .rename: "rename"
        case .delete: "delete"
        case .filterIf: "if"
        case .filterIfNot: "ifNot"
        case .removeAudio: "removeAudio"
        case .changeSpeed: "changeSpeed"
        case .runScript: "runScript"
        case .runShortcut: "runShortcut"
        case .copyToClipboard: "copyToClipboard"
        case .copyLinkForSending: "copyLinkForSending"
        case .shelveWith: "shelveWith"
        case .uploadWith: "uploadWith"
        case .openWith: "openWith"
        }
    }

    var displayString: String {
        switch self {
        case let .optimise(encoder, adaptive, videoEncoder, dpi, location):
            var params = ["encoder: \(videoEncoder?.rawValue ?? encoder.rawValue)"]
            if adaptive { params.append("adaptive: true") }
            if let dpi { params.append("dpi: \(dpi)") }
            if location != "inPlace" { params.append("location: \(location)") }
            return "optimise(\(params.joined(separator: ", ")))"
        case let .downscale(factor, location):
            var params = ["factor: \(factor)"]
            if location != "inPlace" { params.append("location: \(location)") }
            return "downscale(\(params.joined(separator: ", ")))"
        case let .lowerBitrate(kbps, location):
            var params = ["kbps: \(kbps)"]
            if location != "inPlace" { params.append("location: \(location)") }
            return "lowerBitrate(\(params.joined(separator: ", ")))"
        case let .convert(to, location):
            var params = ["to: \(to)"]
            if location != "sameFolder" { params.append("location: \(location)") }
            return "convert(\(params.joined(separator: ", ")))"
        case let .crop(width, height, keepAspectRatio, longEdge, location):
            var params: [String] = []
            if let longEdge { params.append("longEdge: \(longEdge)") }
            if let width { params.append("width: \(width)") }
            if let height { params.append("height: \(height)") }
            if !keepAspectRatio { params.append("keepAspectRatio: false") }
            if location != "inPlace" { params.append("location: \(location)") }
            return "crop(\(params.joined(separator: ", ")))"
        case let .extractPagesAsImages(format, quality, location):
            var params: [String] = []
            if format != "jpeg" { params.append("format: \(format)") }
            if quality != "medium" { params.append("quality: \(quality)") }
            if location != "sameFolder" { params.append("location: \(location)") }
            return params.isEmpty ? "extractPagesAsImages" : "extractPagesAsImages(\(params.joined(separator: ", ")))"
        case let .copy(to): return "copy(to: \(to))"
        case let .move(to): return "move(to: \(to))"
        case let .rename(to): return "rename(to: \(to))"
        case let .delete(path): return "delete(path: \(path))"
        case let .filterIf(condition): return "if(\(condition.displayString))"
        case let .filterIfNot(condition): return "ifNot(\(condition.displayString))"
        case .removeAudio: return "removeAudio"
        case let .changeSpeed(factor): return "changeSpeed(factor: \(factor))"
        case let .runScript(path): return "runScript(path: \(path))"
        case let .runShortcut(shortcut): return "runShortcut(name: \(shortcut.name))"
        case let .copyToClipboard(format, relativeTo):
            var params = ["format: \(format.rawValue)"]
            if let relativeTo { params.append("relativeTo: \(relativeTo)") }
            return "copyToClipboard(\(params.joined(separator: ", ")))"
        case .copyLinkForSending: return "copyLinkForSending"
        case let .shelveWith(app): return "shelveWith(app: \(app))"
        case let .uploadWith(app): return "uploadWith(app: \(app))"
        case let .openWith(app): return "openWith(app: \(app))"
        }
    }

    var isProcessingStep: Bool {
        switch self {
        case .optimise, .downscale, .lowerBitrate, .convert, .crop, .extractPagesAsImages: true
        default: false
        }
    }

    var isFileOperation: Bool {
        switch self {
        case .copy, .move, .rename, .delete: true
        default: false
        }
    }

    var isFilter: Bool {
        switch self {
        case .filterIf, .filterIfNot: true
        default: false
        }
    }

    var category: StepCategory {
        switch self {
        case .optimise, .downscale, .lowerBitrate, .convert, .crop, .extractPagesAsImages: .processing
        case .copy, .move, .rename, .delete: .fileOperation
        case .filterIf, .filterIfNot: .filter
        case .removeAudio, .changeSpeed: .mediaSpecific
        case .runScript, .runShortcut, .copyToClipboard, .copyLinkForSending, .shelveWith, .uploadWith, .openWith: .action
        }
    }
}

enum StepCategory {
    case processing, fileOperation, filter, mediaSpecific, action

    var nsColor: NSColor {
        switch self {
        case .processing: .systemBlue
        case .fileOperation: .systemGreen
        case .filter: .systemOrange
        case .mediaSpecific: .systemTeal
        case .action: .systemIndigo
        }
    }
}

extension PipelineStep {
    var categoryNSColor: NSColor { category.nsColor }
}

// MARK: - Backward-compatible Decodable

// Custom decoder that uses decodeIfPresent with defaults for all defaultable
// parameters. This ensures old encoded data (missing newly added fields like
// `location`) decodes correctly instead of failing.
// Encodable is auto-synthesized on the enum declaration.
extension PipelineStep: Decodable {
    private struct DynKey: CodingKey {
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }

        var stringValue: String

        var intValue: Int? { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynKey.self)

        if container.contains(DynKey("optimise")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("optimise"))
            self = try .optimise(
                encoder: c.decodeIfPresent(EncoderQuality.self, forKey: DynKey("encoder")) ?? .medium,
                adaptive: c.decodeIfPresent(Bool.self, forKey: DynKey("adaptive")) ?? false,
                videoEncoder: c.decodeIfPresent(VideoEncoder.self, forKey: DynKey("videoEncoder")),
                dpi: c.decodeIfPresent(Int.self, forKey: DynKey("dpi")),
                location: c.decodeIfPresent(String.self, forKey: DynKey("location")) ?? "inPlace"
            )
        } else if container.contains(DynKey("downscale")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("downscale"))
            self = try .downscale(
                factor: c.decode(Double.self, forKey: DynKey("factor")),
                location: c.decodeIfPresent(String.self, forKey: DynKey("location")) ?? "inPlace"
            )
        } else if container.contains(DynKey("lowerBitrate")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("lowerBitrate"))
            self = try .lowerBitrate(
                kbps: c.decode(Int.self, forKey: DynKey("kbps")),
                location: c.decodeIfPresent(String.self, forKey: DynKey("location")) ?? "inPlace"
            )
        } else if container.contains(DynKey("convert")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("convert"))
            self = try .convert(
                to: c.decode(String.self, forKey: DynKey("to")),
                location: c.decodeIfPresent(String.self, forKey: DynKey("location")) ?? "sameFolder"
            )
        } else if container.contains(DynKey("crop")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("crop"))
            self = try .crop(
                width: c.decodeIfPresent(Int.self, forKey: DynKey("width")),
                height: c.decodeIfPresent(Int.self, forKey: DynKey("height")),
                keepAspectRatio: c.decodeIfPresent(Bool.self, forKey: DynKey("keepAspectRatio")) ?? true,
                longEdge: c.decodeIfPresent(Int.self, forKey: DynKey("longEdge")),
                location: c.decodeIfPresent(String.self, forKey: DynKey("location")) ?? "inPlace"
            )
        } else if container.contains(DynKey("extractPagesAsImages")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("extractPagesAsImages"))
            self = try .extractPagesAsImages(
                format: c.decodeIfPresent(String.self, forKey: DynKey("format")) ?? "jpeg",
                quality: c.decodeIfPresent(String.self, forKey: DynKey("quality")) ?? "medium",
                location: c.decodeIfPresent(String.self, forKey: DynKey("location")) ?? "sameFolder"
            )
        } else if container.contains(DynKey("copy")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("copy"))
            self = try .copy(to: c.decode(String.self, forKey: DynKey("to")))
        } else if container.contains(DynKey("move")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("move"))
            self = try .move(to: c.decode(String.self, forKey: DynKey("to")))
        } else if container.contains(DynKey("rename")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("rename"))
            self = try .rename(to: c.decode(String.self, forKey: DynKey("to")))
        } else if container.contains(DynKey("delete")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("delete"))
            self = try .delete(path: c.decodeIfPresent(String.self, forKey: DynKey("path")) ?? "sourceFile")
        } else if container.contains(DynKey("filterIf")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("filterIf"))
            self = try .filterIf(c.decode(FilterCondition.self, forKey: DynKey("_0")))
        } else if container.contains(DynKey("filterIfNot")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("filterIfNot"))
            self = try .filterIfNot(c.decode(FilterCondition.self, forKey: DynKey("_0")))
        } else if container.contains(DynKey("removeAudio")) {
            self = .removeAudio
        } else if container.contains(DynKey("changeSpeed")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("changeSpeed"))
            self = try .changeSpeed(factor: c.decode(Double.self, forKey: DynKey("factor")))
        } else if container.contains(DynKey("runScript")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("runScript"))
            self = try .runScript(path: c.decode(String.self, forKey: DynKey("path")))
        } else if container.contains(DynKey("runShortcut")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("runShortcut"))
            self = try .runShortcut(c.decode(Shortcut.self, forKey: DynKey("_0")))
        } else if container.contains(DynKey("copyToClipboard")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("copyToClipboard"))
            self = try .copyToClipboard(
                format: c.decodeIfPresent(ClipboardCopyFormat.self, forKey: DynKey("format")) ?? .path,
                relativeTo: c.decodeIfPresent(String.self, forKey: DynKey("relativeTo"))
            )
        } else if container.contains(DynKey("copyLinkForSending")) {
            self = .copyLinkForSending
        } else if container.contains(DynKey("shelveWith")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("shelveWith"))
            self = try .shelveWith(app: c.decode(String.self, forKey: DynKey("app")))
        } else if container.contains(DynKey("uploadWith")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("uploadWith"))
            self = try .uploadWith(app: c.decode(String.self, forKey: DynKey("app")))
        } else if container.contains(DynKey("openWith")) {
            let c = try container.nestedContainer(keyedBy: DynKey.self, forKey: DynKey("openWith"))
            self = try .openWith(app: c.decode(String.self, forKey: DynKey("app")))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Unknown PipelineStep case"))
        }
    }
}

extension FilterCondition {
    var displayString: String {
        var parts: [String] = []
        if let types, !types.isEmpty {
            parts.append("types: \(types.joined(separator: ", "))")
        }
        if let regex { parts.append("regex: \(regex)") }
        if let nameContains { parts.append("nameContains: \(nameContains)") }
        if let nameIs { parts.append("nameIs: \(nameIs)") }
        if let fileSizeGreaterThan { parts.append("size > \(fileSizeGreaterThan)") }
        if let fileSizeLowerThan { parts.append("size < \(fileSizeLowerThan)") }
        if let widthGreaterThan { parts.append("width > \(widthGreaterThan)") }
        if let widthLowerThan { parts.append("width < \(widthLowerThan)") }
        if let heightGreaterThan { parts.append("height > \(heightGreaterThan)") }
        if let heightLowerThan { parts.append("height < \(heightLowerThan)") }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
}
