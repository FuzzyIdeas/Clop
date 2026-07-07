//
//  Images.swift
//  Clop
//
//  Created by Alin Panaitiu on 10.07.2023.
//

import Accelerate
import Cocoa
import Defaults
import Foundation
import ImageIO
import JxlCoder
import Lowtech
import os
import Photos
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "Images")

/// Resolve the effective image compression for an encode pass. An explicit `aggressiveOptimisation`
/// override (from a pipeline EncoderQuality, the aggressive button, CLI, or Shortcuts) maps onto the
/// legacy normal/aggressive factor anchors; otherwise the unified `imageCompression` setting is used.
func effectiveImageCompression(_ aggressiveOptimisation: Bool?, override: CompressionQuality? = nil) -> CompressionQuality {
    if let override {
        return override
    }
    if let aggressiveOptimisation {
        return CompressionQuality(tier: .custom, factor: aggressiveOptimisation ? COMPRESSION_FACTOR_AGGRESSIVE : COMPRESSION_FACTOR_NORMAL)
    }
    return Defaults[.imageCompression]
}

func jxlNSImage(from data: Data) -> NSImage? {
    try? JXLCoder.decode(data: data)
}

var PNGQUANT = BIN_DIR.appendingPathComponent("pngquant").filePath!
var JPEGOPTIM = BIN_DIR.appendingPathComponent("jpegoptim").filePath!
var JPEGOPTIM_OLD = BIN_DIR.appendingPathComponent("jpegoptim-old").filePath!
var GIFSICLE = BIN_DIR.appendingPathComponent("gifsicle").filePath!
var VIPSTHUMBNAIL = BIN_DIR.appendingPathComponent("vipsthumbnail").filePath!
var TO_GAIN_MAP_HDR = BIN_DIR.appendingPathComponent("toGainMapHDR").filePath!

func isImageValid(path: FilePath) -> Bool {
    guard let image = NSImage(contentsOfFile: path.string) else {
        return false
    }
    return image.size != .zero
}

func requestPhotosAccess() async -> Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    if status == .authorized {
        return true
    }

    let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    return newStatus == .authorized
}

func getPhotoAssetIdentifiers(from pasteboard: NSPasteboard) -> [String] {
    pasteboard.pasteboardItems?.compactMap { item in
        (item.propertyList(forType: .photosReferenceAsset) as? [String: Any])?["localIdentifier"] as? String
    } ?? []
}

func getPhotos(for identifiers: [String]) -> [Image] {
    let fetchOptions = PHFetchOptions()
    let results = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: fetchOptions)

    guard results.count > 0 else {
        return []
    }

    let imageManager = PHImageManager.default()
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true
    options.version = .current

    var images: [Image] = []

    results.enumerateObjects { asset, _, _ in
        let id = asset.localIdentifier.safeFilename
        imageManager.requestImageDataAndOrientation(for: asset, options: options) {
            data, uti, orientation, info in
            guard let data, let nsImage = NSImage(data: data) else {
                return
            }

            let image = Image(nsImage: nsImage, data: data, type: UTType(uti ?? ""), optimised: false, retinaDownscaled: false, id: id)
            guard let image else {
                return
            }
            images.append(image)
        }
    }
    return images
}

extension NSPasteboard.PasteboardType {
    static let jpeg = NSPasteboard.PasteboardType(rawValue: "public.jpeg")
    static let gif = NSPasteboard.PasteboardType(rawValue: "com.compuserve.gif")
    static let webp = NSPasteboard.PasteboardType(rawValue: "org.webmproject.webp")
    static let heic = NSPasteboard.PasteboardType(rawValue: "public.heic")
    static let avif = NSPasteboard.PasteboardType(rawValue: "public.avif")
    static let bmp = NSPasteboard.PasteboardType(rawValue: "com.microsoft.bmp")
    static let icon = NSPasteboard.PasteboardType(rawValue: "com.apple.icns")

    static let webm = NSPasteboard.PasteboardType(rawValue: "org.webmproject.webm")
    static let mkv = NSPasteboard.PasteboardType(rawValue: "org.matroska.mkv")
    static let mpeg = NSPasteboard.PasteboardType(rawValue: "public.mpeg")
    static let wmv = NSPasteboard.PasteboardType(rawValue: "com.microsoft.windows-media-wmv")
    static let flv = NSPasteboard.PasteboardType(rawValue: "com.adobe.flash.video")
    static let m4v = NSPasteboard.PasteboardType(rawValue: "com.apple.m4v-video")

    static let promise = NSPasteboard.PasteboardType(rawValue: "com.apple.pasteboard.promised-file-content-type")
    static let promisedFileName = NSPasteboard.PasteboardType(rawValue: "com.apple.pasteboard.promised-file-name")
    static let promisedFileURL = NSPasteboard.PasteboardType(rawValue: "com.apple.pasteboard.promised-file-url")
    static let promisedSuggestedFileName = NSPasteboard.PasteboardType(rawValue: "com.apple.pasteboard.promised-suggested-file-name")
    static let promisedMetadata = NSPasteboard.PasteboardType(rawValue: "com.apple.NSFilePromiseItemMetaData")
    static let filenames = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
    static let finderNode = NSPasteboard.PasteboardType(rawValue: "com.apple.finder.node")
    static let finderNoderef = NSPasteboard.PasteboardType(rawValue: "com.apple.finder.noderef")

    static let photosReferenceAsset = NSPasteboard.PasteboardType(rawValue: "com.apple.photos.object-reference.asset")
}

extension UTType {
    var fileType: ClopFileType? {
        if conforms(to: UTType.image) {
            .image
        } else if conforms(to: UTType.movie) || conforms(to: UTType.video) {
            .video
        } else if conforms(to: UTType.audio) {
            .audio
        } else if conforms(to: UTType.pdf) {
            .pdf
        } else {
            nil
        }
    }

    var imgType: NSBitmapImageRep.FileType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .gif:
            .gif
        default:
            .png
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .gif:
            .gif
        case .pdf:
            .pdf
        default:
            .png
        }
    }

    var aggressiveOptimisation: Bool {
        switch self {
        case .png:
            Defaults[.useAggressiveOptimisationPNG]
        case .jpeg:
            Defaults[.useAggressiveOptimisationJPEG]
        case .gif:
            Defaults[.useAggressiveOptimisationGIF]
        default:
            false
        }
    }

    static func from(filePath: FilePath) -> UTType? {
        guard let fileType = filePath.fetchFileType()?.split(separator: ";").first?.s else {
            return nil
        }
        return UTType(mimeType: fileType)
    }
}

extension NSImage {
    var type: UTType? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)?.utType.flatMap { t in UTType(t as String) }
    }
    var imgType: NSBitmapImageRep.FileType? {
        type?.imgType
    }

    var data: Data? {
        guard size != .zero, let imgType,
              let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        return autoreleasepool {
            let imageRep = NSBitmapImageRep(cgImage: cgImage)
            imageRep.size = size
            return imageRep.representation(using: imgType, properties: [:])
        }
    }

    var hasTransparentPixels: Bool {
        if representations.allSatisfy(\.isOpaque) {
            return false
        }
        if let rep = representations.first(where: { $0.hasAlpha }) {
            // check for alpha pixels the fast way (use Accelerate)
            guard let cgImage = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return true
            }

            let alphaInfo = cgImage.alphaInfo
            if alphaInfo == .none || alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst {
                return false
            }

            let pixelCount = Int(size.width * size.height)
            let alphaBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
            defer { alphaBuffer.deallocate() }

            let context = CGContext(
                data: alphaBuffer,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: Int(size.width),
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )!
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))

            var alphaBufferFloat = [Float](repeating: 0, count: pixelCount)
            vDSP_vfltu8(alphaBuffer, 1, &alphaBufferFloat, 1, vDSP_Length(pixelCount))

            var alphaMin: Float = 0xFF
            vDSP_minv(alphaBufferFloat, 1, &alphaMin, vDSP_Length(pixelCount))

            return alphaMin < 0xFF
        }
        return false
    }
}

extension CGImage {
    var type: UTType? {
        utType.flatMap { t in UTType(t as String) }
    }
    var imgType: NSBitmapImageRep.FileType? {
        type?.imgType
    }
}

extension NSPasteboard.PasteboardType {
    static var optimisationStatus: NSPasteboard.PasteboardType = .init("clop.optimisation.status")
}

/// gifsicle args that drop every `everyNth` frame of an animated GIF (4 = 25% fewer frames, 3 = 33%, 2 = 50%).
/// With `.playFaster` the surviving delays are left untouched (smooth motion, shorter animation); with
/// `.keepDuration` each dropped frame's delay is folded into the previous kept frame (same duration,
/// choppier motion). Frame 0 is never dropped. Returns nil for GIFs with 8 frames or fewer, or when
/// the frame structure can't be read.
func gifsicleFrameDropArgs(gif path: FilePath, everyNth: Int) -> [String]? {
    guard everyNth >= 2, let source = CGImageSourceCreateWithURL(path.url as CFURL, nil) else {
        return nil
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 8 else {
        return nil
    }

    guard Defaults[.gifFrameDropBehaviour] == .keepDuration else {
        return ["--delete"] + (1 ..< frameCount).filter { $0.isMultiple(of: everyNth) }.map { "#\($0)" }
    }

    // Delays in centiseconds (the GIF wire unit), unclamped so 0.02s frames don't read as 0.1s.
    let delays: [Int] = (0 ..< frameCount).map { index in
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let seconds = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
        else {
            return 0
        }
        return Int((seconds * 100).rounded())
    }

    var args: [String] = []
    var index = 0
    while index < frameCount {
        var delay = delays[index]
        var next = index + 1
        while next < frameCount, next.isMultiple(of: everyNth) {
            delay += delays[next]
            next += 1
        }
        args += ["-d\(delay)", "#\(index)"]
        index = next
    }
    return args
}

// MARK: - Image

class Image: CustomStringConvertible {
    init(data: Data, path: FilePath, nsImage: NSImage? = nil, type: UTType? = nil, optimised: Bool? = nil, retinaDownscaled: Bool) {
        self.path = path
        self.data = data
        image = nsImage ?? NSImage(data: data)!
        self.type = type ?? image.type ?? UTType(filenameExtension: path.extension ?? "") ?? UTType(mimeType: path.fetchFileType() ?? "") ?? .png
        self.retinaDownscaled = retinaDownscaled

        if let optimised {
            self.optimised = optimised
        }
    }

    init?(path: FilePath? = nil, data: Data? = nil, nsImage: NSImage? = nil, type: UTType? = nil, optimised: Bool? = nil, retinaDownscaled: Bool) {
        guard path != nil || data != nil || nsImage != nil else {
            return nil
        }

        guard let data = data ?? ((path != nil) ? fm.contents(atPath: path!.string) : nil), let nsImage = nsImage ?? NSImage(data: data) ?? jxlNSImage(from: data) else {
            return nil
        }

        let type = type ?? nsImage.type
        let rpath: FilePath
        if let path {
            rpath = path
        } else {
            guard let ext = type?.preferredFilenameExtension else { return nil }

            let tempPath = FilePath.images / "\(Int.random(in: 100 ... 100_000)).\(ext)"
//            let tempPath = fm.temporaryDirectory.appendingPathComponent("\(Int.random(in: 100 ... 100_000)).\(ext)").path
            guard fm.createFile(atPath: tempPath.string, contents: data) else { return nil }

            rpath = tempPath
        }
        let rtype = type ?? UTType(filenameExtension: rpath.extension ?? "") ?? UTType(mimeType: rpath.fetchFileType() ?? "") ?? .png
        self.path = rpath
        self.data = data
        self.type = rtype
        image = nsImage
        self.retinaDownscaled = retinaDownscaled

        if let optimised {
            self.optimised = optimised
        }
    }

    convenience init?(data: Data, retinaDownscaled: Bool) {
        guard let nsImage = NSImage(data: data) else { return nil }
        self.init(nsImage: nsImage, data: data, retinaDownscaled: retinaDownscaled)
    }

    init?(nsImage: NSImage, data: Data? = nil, type: UTType? = nil, optimised: Bool? = nil, retinaDownscaled: Bool, id: String? = nil) {
        guard let type = type ?? nsImage.type, let ext = type.preferredFilenameExtension,
              let data = data ?? nsImage.data
        else { return nil }

        image = nsImage
        self.data = data
        let tempPath = FilePath.images / "\(id ?? Int.random(in: 100 ... 100_000).s).\(ext)"
//        let tempPath = fm.temporaryDirectory.appendingPathComponent("\(Int.random(in: 100 ... 100_000)).\(ext)").path
        guard fm.createFile(atPath: tempPath.string, contents: data) else { return nil }

        path = tempPath
        self.type = type
        self.retinaDownscaled = retinaDownscaled
        self.optimised = optimised ?? false
    }

    static let PNG_HEADER: Data = .init([0x89, 0x50, 0x4E, 0x47])
    static let JPEG_HEADER: Data = .init([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    static let GIF_HEADER: Data = .init([0x47, 0x49, 0x46, 0x38, 0x39])

    static var NOT_IMAGE_TYPE_PATTERN =
        try! Regex(
            #"com\.apple\.freeform\.CRLNative|com\.microsoft\.ole\.source|com\.microsoft\.Art|com\.microsoft\.PowerPoint|com\.microsoft\.image-svg-xml|com\.microsoft\.DataObject|IBPasteboardType|IBDocument|com\.pixelmator|com\.adobe\.[^.]+\.local-private-clipboard-marker|com\.apple\.iWork"#
        )
    static var NOT_IMAGE_TYPES: Set<NSPasteboard.PasteboardType> = [
        .icon,
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.AutoGeneratedType"),
        .init("public.svg-image"),
        .init("public.xml"),
        .init("com.trolltech.anymime.Kingsoft Data Descriptor"),
        .init("com.adobe.illustrator.ai-image"),
        .init("com.adobe.photoshop-image"),
        .init("com.adobe.photoshop-large-image"),
        .init("com.ilm.openexr-image"),
        .init("com.kodak.flashpix-image"),
        .init("com.sgi.sgi-image"),
        .init("com.truevision.tga-image"),
        .init("org.oasis-open.opendocument.image"),
        .init("org.oasis-open.opendocument.image-template"),
        .init("public.xbitmap-image"),
        .init("com.apple.notes.sketch"),
        .init("com.bohemiancoding.sketch.clouddrawing.single"),
        .init("com.bohemiancoding.sketch.drawing"),
        .init("com.bohemiancoding.sketch.drawing.single"),
        .init("com.apple.graphic-icon"),
        .init("com.apple.icon-decoration"),
        .init("com.apple.iconset"),
        .init("com.microsoft.Object-Descriptor"),
        .init("com.microsoft.appbundleid"),
        .init("com.adobe.pdf"),
        .init("com.apple.is-remote-clipboard"),
        .init("public.rtf"),
    ]

    lazy var hash: String = data.sha256
    let data: Data
    let path: FilePath
    var image: NSImage

    lazy var optimised: Bool = switch type {
    case .png:
        path.string.hasSuffix(".clop.png")
    case .jpeg:
        path.string.hasSuffix(".clop.jpg")
    case .gif:
        path.string.hasSuffix(".clop.gif")
    default:
        false
    }

    var type: UTType
    @Atomic var retinaDownscaled: Bool

    var pixelScale: Float {
        (image.realSize.width / image.size.width).f
    }
    var description: String {
        "<Image: \(path) (\(size.s)) [\(optimised ? "" : "NOT ")OPTIMIZED]>"
    }
    var size: NSSize {
        image.realSize
    }

    var canBeOptimised: Bool {
        [UTType.png, .jpeg, .gif, .tiff].contains(type)
    }

    static func isRaw(pasteboardItem: NSPasteboardItem) -> Bool {
        pasteboardItem.types.contains(where: { $0.rawValue.contains("raw-image") })
    }

    class func fromPasteboard(item: NSPasteboardItem? = nil, anyType: Bool = false) throws -> Image {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems, items.count == 1, let item = item ?? items.first else {
            #if DEBUG
                pb.pasteboardItems?.forEach { item in
                    item.types.filter { ![NSPasteboard.PasteboardType.rtf, NSPasteboard.PasteboardType(rawValue: "public.utf16-external-plain-text")].contains($0) }.forEach { type in
                        print(type.rawValue + " " + (item.string(forType: type) ?! String(describing: item.propertyList(forType: type) ?? item.data(forType: type) ?? "<EMPTY DATA>")))
                    }
                }
            #endif

            throw ClopError.noClipboardImage(.init())

        }
        let typeSet = NSOrderedSet(array: item.types)
        var allowImage = try anyType || (
            !typeSet.intersectsSet(NOT_IMAGE_TYPES) &&
                !isRaw(pasteboardItem: item) &&
                (NOT_IMAGE_TYPE_PATTERN.firstMatch(in: item.types.map(\.rawValue).joined(separator: " "))) == nil
        )
        let nsImageFromPath: () -> NSImage? = {
            guard Defaults[.optimiseImagePathClipboard], let path = item.existingFilePath, path.isImage, !path.hasOptimisationStatusXattr() else {
                return nil
            }
            return NSImage(contentsOfFile: path.string)
        }

        var nsImage: NSImage?
        if allowImage || typeSet.contains(NSPasteboard.PasteboardType.icon), let img = nsImageFromPath() {
            nsImage = img
            allowImage = true
        }
        guard allowImage, let nsImage = nsImage ?? NSImage(pasteboard: pb) ?? nsImageFromPath() else {
            throw ClopError.noClipboardImage(.init())
        }

        let optimised = item.string(forType: .optimisationStatus) == "true"
        let data: Data? = [NSPasteboard.PasteboardType.png, .jpeg, .gif, .tiff].lazy.compactMap { t in
            item.data(forType: t)
        }.first

        if let originalPath = item.existingFilePath, let path = try? originalPath.copy(to: FilePath.images, force: true),
           let img = Image(path: path, data: data, nsImage: nsImage, optimised: optimised, retinaDownscaled: false)
        {
            return img
        }

        guard let img = Image(nsImage: nsImage, data: data, optimised: optimised, retinaDownscaled: false) else {
            throw ClopError.noClipboardImage(.init())
        }

        return img
    }

    func runThroughShortcut(shortcut: Shortcut? = nil, optimiser: Optimiser, allowLarger: Bool, aggressiveOptimisation: Bool, source: OptimisationSource?) throws -> Image? {
        let shortcutOutFile = FilePath.images.appending("\(Date.now.timeIntervalSinceReferenceDate.i)-shortcut-output-for-\(path.stem!)")

        guard let shortcut else { return nil }
        let proc: Process? = optimiser.runShortcut(shortcut, outFile: shortcutOutFile, url: path.url)
        guard let proc else {
            return nil
        }

        proc.waitUntilExit()
        log.debug("Shortcut ran with status \(proc.terminationStatus)")
        shortcutOutFile.waitForFile(for: 2)
        guard shortcutOutFile.exists, (shortcutOutFile.fileSize() ?? 1) > 0 else {
            return nil
        }
        var outImg: Image?

        if let img = Image(path: shortcutOutFile, retinaDownscaled: retinaDownscaled) {
            outImg = img
        } else if let size = shortcutOutFile.fileSize(), size < 4096,
                  let path = (try? String(contentsOfFile: shortcutOutFile.string))?.existingFilePath, self.path != path
        {
            outImg = Image(path: path, retinaDownscaled: retinaDownscaled)
        }

        guard var outImg, outImg.hash != hash else {
            return nil
        }
        if let ext = outImg.type.preferredFilenameExtension ?? outImg.path.extension,
           let newPath = try? outImg.path.copy(to: outImg.path.withExtension(ext))
        {
            outImg = outImg.copyWithPath(newPath)
        }

        if outImg.canBeOptimised {
            outImg = (try? outImg.optimise(
                optimiser: optimiser,
                allowLarger: allowLarger,
                aggressiveOptimisation: aggressiveOptimisation,
                adaptiveSize: effectiveImageCompression(aggressiveOptimisation, override: optimiser.compressionOverride).tier == .adaptive
            )) ?? outImg
        }

        if outImg.path != path, outImg.type == type {
            try outImg.path.copy(to: path, force: true)
        }
        return outImg.copyWithPath(
            type == outImg.type
                ? path
                : path.withExtension(outImg.type.preferredFilenameExtension ?? outImg.path.extension ?? path.extension ?? "")
        )
    }

    func copyWithPath(_ path: FilePath) -> Image {
        Image(data: data, path: path, nsImage: image, type: type, optimised: optimised, retinaDownscaled: retinaDownscaled)
    }

    func optimiseGIF(optimiser: Optimiser, resizeTo newSize: CGSize? = nil, scaleTo scaleFactor: Double? = nil, cropTo cropSize: CropSize? = nil, fromSize: CGSize? = nil, aggressiveOptimisation: Bool? = nil) throws -> Image {
        let tempFile = FilePath.images.appending(path.lastComponent?.string ?? "clop.gif")

        var resizedFile: FilePath? = nil
        var resizeArgs: [String] = []
        var size = newSize ?? .zero
        if let newSize {
            resizeArgs = ["--resize", "\(newSize.width.i)x\(newSize.height.i)"]
        } else if let cropSize, let fromSize, let cropRect = cropSize.cropRect, !cropRect.isFullFrame {
            let rect = cropRect.pixelRect(in: fromSize)
            resizeArgs = ["--crop", "\(rect.origin.x.i),\(rect.origin.y.i)+\(rect.width.i)x\(rect.height.i)"]
            size = rect.size

            let target = cropSize.ns
            if target.width > 0, target.height > 0, target.width.i < rect.width.i || target.height.i < rect.height.i {
                resizeArgs += ["--resize", "\(target.width.i)x\(target.height.i)"]
                size = target
            }
        } else if let cropSize, let fromSize {
            let s = cropSize.isAspectRatio ? cropSize.computedSize(from: fromSize) : cropSize.ns
            if s.width > 0, s.height > 0, !cropSize.longEdge || cropSize.isAspectRatio {
                let cropString: String
                if (fromSize.width / s.width) > (fromSize.height / s.height) {
                    let newAspectRatio = s.width / s.height
                    let widthDiff = ((fromSize.width - (newAspectRatio * fromSize.height)) / 2).i
                    cropString = "\(widthDiff),0+-\(widthDiff)x0"
                } else {
                    let newAspectRatio = s.height / s.width
                    let heightDiff = ((fromSize.height - (newAspectRatio * fromSize.width)) / 2).i
                    cropString = "0,\(heightDiff)+0x-\(heightDiff)"
                }

                resizeArgs = ["--crop", cropString, "--resize", "\(s.width.i)x\(s.height.i)"]
                size = s
            } else {
                let scaleFactor = cropSize.factor(from: fromSize)
                resizeArgs = ["--scale", "\(scaleFactor.str(decimals: 2))"]
                size = fromSize.scaled(by: scaleFactor)
            }
        } else if let scaleFactor {
            resizeArgs = ["--scale", "\(scaleFactor.str(decimals: 2))"]
            size = (fromSize ?? size).scaled(by: scaleFactor)
        }

        if resizeArgs.isNotEmpty {
            resizedFile = FilePath.forResize.appending(path.nameWithoutSize).withSize(size)
            let resizeProc = try tryProc(
                GIFSICLE.string,
                args: ["--unoptimize", "--threads=\(ProcessInfo.processInfo.activeProcessorCount)", "--resize-method=box", "--resize-colors=256"] +
                    resizeArgs +
                    ["--output", resizedFile!.string, path.string],
                tries: 3
            ) { proc in
                mainActor { optimiser.processes = [proc] }
            }
            guard resizeProc.terminationStatus == 0 else {
                throw ClopProcError.processError(resizeProc)
            }
        }

        let cq = effectiveImageCompression(aggressiveOptimisation, override: optimiser.compressionOverride)
        mainActor { optimiser.aggressive = cq.imageIsAggressive }

        let inputFile = resizedFile ?? path
        let frameDropArgs = cq.gifFrameDropEveryNth.flatMap { gifsicleFrameDropArgs(gif: inputFile, everyNth: $0) } ?? []
        var args = cq.gifsicleArgs + ["--threads=\(ProcessInfo.processInfo.activeProcessorCount)", "--output", tempFile.string]
        if frameDropArgs.isEmpty {
            args.append(inputFile.string)
        } else {
            // Frame selections only apply after the input file; --unoptimize keeps frame-diffed
            // inputs intact through deletion, and -O3 re-optimises the output anyway.
            args = ["--unoptimize", inputFile.string] + frameDropArgs + args
        }

        let backup = path.backup(path: path.clopBackupPath, operation: .copy)
        let proc = try tryProc(
            GIFSICLE.string,
            args: args,
            tries: 3
        ) { proc in
            mainActor { optimiser.processes = [proc] }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        tempFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
        if Defaults[.preserveDates] {
            tempFile.copyCreationModificationDates(from: backup ?? path)
        }
        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimisationStatusXattr("true")
        return Image(data: data, path: tempFile, type: .gif, optimised: true, retinaDownscaled: retinaDownscaled)
    }

    func optimiseJPEG(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, testPNG: Bool = false) throws -> Image {
        let backupPath = path.clopBackupPath
        var tempFile = FilePath.images.appending(path.lastComponent?.string ?? "clop.jpg")

        let cq = effectiveImageCompression(aggressiveOptimisation, override: optimiser.compressionOverride)
        let aggressive = cq.imageIsAggressive
        mainActor { optimiser.aggressive = aggressive }

        #if arch(arm64)
            let archDependentArgs = ["--auto-mode"]
        #else
            let archDependentArgs: [String] = []
        #endif

        let jpegProc = Proc(cmd: JPEGOPTIM.string, args: [
            "--keep-all", "--force", "--max", "\(cq.jpegMaxQuality)",
        ] + archDependentArgs + [
            "--overwrite",
            "--dest",
            FilePath.images.string,
            path.string,
        ])

        var procs = [jpegProc]

        var pngOutFile: FilePath?
        if testPNG, let png = try? convert(to: .png, asTempFile: true) {
            pngOutFile = FilePath.images.appending(png.path.name.string)
            if pngOutFile != png.path {
                try? pngOutFile!.delete()
            }
            let pngProc = Proc(cmd: PNGQUANT.string, args: [
                "--force",
                "--speed", "\(cq.pngQuantSpeed)",
                "--quality", cq.pngQuantQuality,
            ] + (cq.pngQuantColors.map { ["\($0)"] } ?? []) + (pngOutFile == png.path ? ["--ext", ".png"] : ["--output", pngOutFile!.string]) + [png.path.string])

            procs.append(pngProc)
        }

        let backup = (backupPath?.exists ?? false) ? backupPath : path.backup(path: path.clopBackupPath, operation: .copy)
        let procMaps = try tryProcs(procs, tries: 2) { procMap in
            mainActor { optimiser.processes = procMap.values.map { $0 } }
        }

        guard let proc = procMaps[jpegProc] else {
            throw ClopError.noProcess(jpegProc.cmdline)
        }
        if proc.terminationStatus != 0 {
            let args = [
                "--keep-all", "--force", "--max", "\(cq.jpegSecondaryMaxQuality)",
                "--auto-mode", "--overwrite",
                "--dest", FilePath.images.string, path.string,
            ]
            let proc = try tryProc(JPEGOPTIM_OLD.string, args: args, tries: 2) { proc in
                mainActor { optimiser.processes = [proc] }
            }
            guard proc.terminationStatus == 0 else {
                throw ClopProcError.processError(proc)
            }
        }

        var type = UTType.jpeg
        if let pngOutFile, pngOutFile.exists,
           let pngSize = pngOutFile.fileSize(), pngSize > 0,
           let jpegSize = tempFile.fileSize(),
           jpegSize - pngSize > 100_000
        {
            var newOutFile = pngOutFile
            do {
                if Defaults[.convertedImageBehaviour] != .temporary {
                    pngOutFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
                    try pngOutFile.setOptimisationStatusXattr("true")

                    newOutFile = try pngOutFile.move(to: path.dir, force: true)
                    if Defaults[.convertedImageBehaviour] == .inPlace, let ext = path.extension, newOutFile.withExtension(ext).exists {
                        try? newOutFile.withExtension(ext).delete()
                    }
                }
                tempFile = pngOutFile
                type = .png
            } catch {
                log.error("\(error.localizedDescription)")
            }
        }

        if type == .jpeg || Defaults[.convertedImageBehaviour] == .temporary {
            tempFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
        }
        if Defaults[.preserveDates] {
            tempFile.copyCreationModificationDates(from: backup ?? path)
        }
        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimisationStatusXattr("true")
        return Image(data: data, path: tempFile, type: type, optimised: true, retinaDownscaled: retinaDownscaled)
    }

    func optimiseTIFF(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        guard let data = fm.contents(atPath: path.string) else {
            throw ClopError.fileNotFound(path)
        }

        if data.starts(with: Image.PNG_HEADER) {
            let png = path.withExtension("png")
            try path.copy(to: png, force: true)
            let img = Image(data: data, path: png, type: .png, retinaDownscaled: retinaDownscaled)
            return try img.optimisePNG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testJPEG: adaptiveSize)
        }

        if data.starts(with: Image.JPEG_HEADER) {
            let jpeg = path.withExtension("jpeg")
            try path.copy(to: jpeg, force: true)
            let img = Image(data: data, path: jpeg, type: .jpeg, retinaDownscaled: retinaDownscaled)
            return try img.optimiseJPEG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testPNG: adaptiveSize && (img.image.largeAreaEntropy ?? 0) < 5)
        }

        if data.starts(with: Image.GIF_HEADER) {
            let gif = path.withExtension("gif")
            try path.copy(to: gif, force: true)
            let img = Image(data: data, path: gif, type: .gif, retinaDownscaled: retinaDownscaled)
            return try img.optimiseGIF(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation)
        }

        if let img = Image(data: data, retinaDownscaled: retinaDownscaled), let png = try? img.convert(to: .png, asTempFile: true) {
            return try png.optimisePNG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testJPEG: adaptiveSize)
        }

        throw ClopError.unknownImageType(path)
    }

    func optimisePNG(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, testJPEG: Bool = false) throws -> Image {
        let backupPath = path.clopBackupPath
        var tempFile = FilePath.images.appending(path.name.string)
        if tempFile != path {
            try? tempFile.delete()
        }

        let cq = effectiveImageCompression(aggressiveOptimisation, override: optimiser.compressionOverride)
        let aggressive = cq.imageIsAggressive
        mainActor { optimiser.aggressive = aggressive }

        let pngProc = Proc(cmd: PNGQUANT.string, args: [
            "--force",
            "--speed", "\(cq.pngQuantSpeed)",
            "--quality", cq.pngQuantQuality,
        ] + (cq.pngQuantColors.map { ["\($0)"] } ?? []) + (tempFile == path ? ["--ext", ".png"] : ["--output", tempFile.string]) + [path.string])
        var procs = [pngProc]

        var jpegOutFile: FilePath?
        if testJPEG, !image.hasTransparentPixels, let jpeg = try? convert(to: .jpeg, asTempFile: true) {
            let jpegProc = Proc(cmd: JPEGOPTIM.string, args: [
                "--keep-all", "--force", "--max", "\(cq.jpegSecondaryMaxQuality)",
                "--auto-mode", "--overwrite",
                "--dest", FilePath.images.string, jpeg.path.string,
            ])
            procs.append(jpegProc)
            jpegOutFile = FilePath.images.appending(jpeg.path.name.string)
        }

        let procMaps = try tryProcs(procs, tries: 3) { procMap in
            mainActor { optimiser.processes = procMap.values.map { $0 } }
        }

        let backup = (backupPath?.exists ?? false) ? backupPath : path.backup(path: path.clopBackupPath, operation: .copy)
        guard let proc = procMaps[pngProc] else {
            throw ClopError.noProcess(pngProc.cmdline)
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        var type = UTType.png
        if let jpegOutFile, jpegOutFile.exists,
           let jpegSize = jpegOutFile.fileSize(), jpegSize > 0,
           let pngSize = tempFile.fileSize(),
           pngSize - jpegSize > 100_000
        {
            var newOutFile = jpegOutFile
            do {
                if Defaults[.convertedImageBehaviour] != .temporary {
                    jpegOutFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
                    try jpegOutFile.setOptimisationStatusXattr("true")

                    if jpegOutFile != path.dir.appending(jpegOutFile.name) {
                        newOutFile = try jpegOutFile.move(to: path.dir, force: true)
                        if Defaults[.convertedImageBehaviour] == .inPlace, let ext = path.extension, newOutFile.withExtension(ext).exists {
                            try? newOutFile.withExtension(ext).delete()
                        }
                    }

                }
                tempFile = newOutFile
                type = .jpeg
            } catch {
                log.error("\(error.localizedDescription)")
            }
        }

        if type == .png || Defaults[.convertedImageBehaviour] == .temporary {
            tempFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
        }
        if Defaults[.preserveDates] {
            tempFile.copyCreationModificationDates(from: backup ?? path)
        }
        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimisationStatusXattr("true")
        return Image(data: data, path: tempFile, type: type, optimised: true, retinaDownscaled: retinaDownscaled)
    }

    func resize(toFraction fraction: Double, optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        let size = CropSize(width: (size.width * fraction).evenInt, height: (size.height * fraction).evenInt)
        let pathForResize = FilePath.forResize.appending(path.nameWithoutSize)
        try path.copy(to: pathForResize, force: true)

        if type == .gif, let gif = Image(path: pathForResize, retinaDownscaled: retinaDownscaled) {
            return try gif.optimiseGIF(optimiser: optimiser, scaleTo: fraction, fromSize: self.size, aggressiveOptimisation: aggressiveOptimisation)
        }

        return try resize(toSize: size, optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveSize)
    }

    func resize(toSize cropSize: CropSize, optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        let pathForResize = FilePath.forResize.appending(path.nameWithoutSize)
        // rect crops are relative, so they can start from the pristine original instead
        // of cutting into an already cropped image
        let source: FilePath = if cropSize.cropRect != nil, let backup = path.clopBackupPath, backup.exists {
            backup
        } else {
            path
        }
        if source != pathForResize {
            try source.copy(to: pathForResize, force: true)
        }

        if type == .gif, let gif = Image(path: pathForResize, retinaDownscaled: retinaDownscaled) {
            return try gif.optimiseGIF(optimiser: optimiser, cropTo: cropSize, fromSize: gif.size, aggressiveOptimisation: aggressiveOptimisation)
        }

        let size = cropSize.computedSize(from: size)
        let sizeStr = "\(size.width.evenInt)x\(size.height.evenInt)"
        let args = ["-s", sizeStr, "-o", "%s_\(sizeStr).\(path.extension!)[Q=100]", "--smartcrop", cropSize.smartCrop ? "attention" : "centre", pathForResize.string]
        let resizedPath = pathForResize.withSize(size)

        if let cropRect = cropSize.cropRect, !cropRect.isFullFrame {
            // vipsthumbnail only supports centre/attention crops, arbitrary rects go through CoreGraphics
            try cropWithCGImage(source: pathForResize, dest: resizedPath, cropRect: cropRect, targetSize: size)
        } else {
            do {
                let proc = try tryProc(VIPSTHUMBNAIL.string, args: args, tries: 3) { proc in
                    mainActor { optimiser.processes = [proc] }
                }
                guard proc.terminationStatus == 0 else {
                    throw ClopProcError.processError(proc)
                }
                resizedPath.waitForFile(for: 2.0)
                guard resizedPath.exists else {
                    throw ClopError.downscaleFailed(pathForResize)
                }
            } catch {
                log.warning("vipsthumbnail resize failed for \(pathForResize.string), falling back to NSImage: \(String(describing: error))")
                try resizeWithNSImage(source: pathForResize, dest: resizedPath, targetSize: NSSize(width: size.width.evenInt.d, height: size.height.evenInt.d))
            }
        }

        if resizedPath != pathForResize {
            try resizedPath.copy(to: pathForResize, force: true)
        }

        guard let pbImage = Image(path: pathForResize, optimised: false, retinaDownscaled: retinaDownscaled) else {
            throw ClopError.downscaleFailed(pathForResize)
        }
        let originalBytes = data.count
        let result = try pbImage.optimise(optimiser: optimiser, allowLarger: true, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveSize)

        // A downscale of a flat, low-colour PNG can grow the file: high-quality resampling turns a few
        // crisp colours into many anti-aliased ones, so the default 256-colour pngquant overshoots the
        // tiny original. Re-quantize the resized image back toward the original's own colour count (with
        // progressively smaller fallbacks) until it beats the original. If nothing does, keep the
        // original untouched, since an optimiser should never grow a file.
        if result.type == .png, result.data.count > originalBytes {
            if let shrunk = downscaledPNGUnderOriginal(resized: pathForResize, originalBytes: originalBytes, optimiser: optimiser) {
                return shrunk
            }
            log.debug("Downscale grew the file (\(result.data.count) > \(originalBytes) bytes), keeping the original")
            return self
        }
        return result
    }

    func cropWithCGImage(source: FilePath, dest: FilePath, cropRect: CropRect, targetSize: NSSize? = nil) throws {
        guard let imgSource = CGImageSourceCreateWithURL(source.url as CFURL, nil) else {
            throw ClopError.downscaleFailed(source)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? Double) ?? size.width.d
        let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? Double) ?? size.height.d

        // Render with the EXIF orientation applied so the rect (defined in displayed coordinates) lines up
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let fullImage = CGImageSourceCreateThumbnailAtIndex(imgSource, 0, options as CFDictionary) else {
            throw ClopError.downscaleFailed(source)
        }

        let rect = cropRect.pixelRect(in: NSSize(width: fullImage.width.d, height: fullImage.height.d))
        guard !rect.isEmpty, var cropped = fullImage.cropping(to: rect) else {
            throw ClopError.downscaleFailed(source)
        }

        if let targetSize, targetSize.width.i < cropped.width || targetSize.height.i < cropped.height {
            let nsImage = NSImage(cgImage: cropped, size: .zero)
            guard let resized = nsImage.resize(to: targetSize),
                  let resizedCG = resized.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                throw ClopError.downscaleFailed(source)
            }
            cropped = resizedCG
        }

        let utType = (dest.extension.flatMap { UTType(filenameExtension: $0) } ?? type).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(dest.url as CFURL, utType, 1, nil) else {
            throw ClopError.downscaleFailed(source)
        }
        let destOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(destination, cropped, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ClopError.downscaleFailed(source)
        }
    }

    func resizeWithNSImage(source: FilePath, dest: FilePath, targetSize: NSSize) throws {
        guard let nsImage = NSImage(contentsOfFile: source.string) else {
            throw ClopError.downscaleFailed(source)
        }
        guard let resized = nsImage.resize(to: targetSize),
              let cgImage = resized.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw ClopError.downscaleFailed(source)
        }

        let utType = (dest.extension.flatMap { UTType(filenameExtension: $0) } ?? type).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(dest.url as CFURL, utType, 1, nil) else {
            throw ClopError.downscaleFailed(source)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ClopError.downscaleFailed(source)
        }
    }

    /// Overlay a still watermark image natively (no ffmpeg) using Core Graphics, then
    /// re-encode to the original format via Clop's per-format optimisers so quality and
    /// file size stay close to the original. Returns a temp-file `Image`; the caller places it.
    /// Animated GIFs are handled on the ffmpeg path instead (single-frame CG compositing
    /// would drop the animation).
    func watermarked(watermark wmPath: FilePath, position: String, opacity: Double, scale: Double, optimiser: Optimiser) throws -> Image {
        // Load the base orientation-aware so the watermark lands in the displayed corner.
        // ImageIO handles png/jpeg/tiff/gif/heic/avif/webp; JXL (which ImageIO can't decode)
        // falls back to the already-decoded NSImage.
        var loadedBase: CGImage?
        if let baseSource = CGImageSourceCreateWithURL(path.url as CFURL, nil) {
            let baseProps = CGImageSourceCopyPropertiesAtIndex(baseSource, 0, nil) as? [CFString: Any]
            let pixelWidth = (baseProps?[kCGImagePropertyPixelWidth] as? Double) ?? size.width.d
            let pixelHeight = (baseProps?[kCGImagePropertyPixelHeight] as? Double) ?? size.height.d
            let baseOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            loadedBase = CGImageSourceCreateThumbnailAtIndex(baseSource, 0, baseOptions as CFDictionary)
        }
        guard let baseImage = loadedBase ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ClopError.conversionFailed(path)
        }

        guard let wmSource = CGImageSourceCreateWithURL(wmPath.url as CFURL, nil),
              let wmImage = CGImageSourceCreateImageAtIndex(wmSource, 0, nil), wmImage.width > 0
        else {
            throw ClopError.conversionFailed(wmPath)
        }

        let W = baseImage.width
        let H = baseImage.height
        let wmW = max(16, Int((Double(W) * scale).rounded()))
        let wmH = max(1, Int((Double(wmW) * Double(wmImage.height) / Double(wmImage.width)).rounded()))
        let pad = 20

        // Core Graphics' origin is bottom-left, so flip the ffmpeg (top-left) Y coordinates
        let origin: (x: Int, y: Int) = switch position {
        case "topLeft": (pad, H - wmH - pad)
        case "topRight": (W - wmW - pad, H - wmH - pad)
        case "bottomLeft": (pad, pad)
        case "center": ((W - wmW) / 2, (H - wmH) / 2)
        default: (W - wmW - pad, pad) // bottomRight
        }

        let colorSpace = (baseImage.colorSpace?.model == .rgb ? baseImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            throw ClopError.conversionFailed(path)
        }
        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setAlpha(opacity)
        ctx.draw(wmImage, in: CGRect(x: origin.x, y: origin.y, width: wmW, height: wmH))
        guard let composited = ctx.makeImage() else {
            throw ClopError.conversionFailed(path)
        }

        // Re-encode to the original format, then optimise it the Clop way.
        switch type {
        case .png, .jpeg, .tiff:
            let ext = type.preferredFilenameExtension ?? "png"
            let interPath = path.tempFile(ext: ext)
            try writeCGImage(composited, to: interPath, as: type)
            guard let img = Image(path: interPath, type: type, optimised: false, retinaDownscaled: retinaDownscaled) else {
                throw ClopError.conversionFailed(interPath)
            }
            return try img.optimise(optimiser: optimiser, allowLarger: true)
        case .jxl, .avif, .webP, .heic:
            // ImageIO can't reliably encode these. Composite to a lossless PNG intermediate
            // and convert back to the original format, which applies that encoder's
            // quality/compression (the "optimise" pass for those types).
            let interPath = path.tempFile(ext: "png")
            try writeCGImage(composited, to: interPath, as: .png)
            guard let png = Image(path: interPath, type: .png, optimised: false, retinaDownscaled: retinaDownscaled) else {
                throw ClopError.conversionFailed(interPath)
            }
            switch type {
            case .jxl: return try png.convertToJXL(asTempFile: true)
            case .avif: return try png.convertToAVIF(asTempFile: true)
            case .webP: return try png.convertToWEBP(asTempFile: true)
            default: return try png.convertToHEIC(asTempFile: true)
            }
        default:
            // Any other ImageIO-encodable format (e.g. bmp): write it losslessly so the
            // extension and contents stay consistent. Clop converts these to jpeg in its
            // normal optimise flow anyway, so there's no dedicated optimiser to reuse here.
            let ext = type.preferredFilenameExtension ?? "png"
            let outPath = path.tempFile(ext: ext)
            try writeCGImage(composited, to: outPath, as: type)
            guard let img = Image(path: outPath, type: type, optimised: false, retinaDownscaled: retinaDownscaled) else {
                throw ClopError.conversionFailed(outPath)
            }
            return img
        }
    }

    func optimise(optimiser: Optimiser, allowLarger: Bool = false, aggressiveOptimisation: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        guard !optimised else {
            throw ClopError.alreadyOptimised(path)
        }

        let img: Image
        switch type {
        case .png:
            img = try optimisePNG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testJPEG: adaptiveSize)
        case .jpeg:
            img = try optimiseJPEG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testPNG: adaptiveSize && (image.largeAreaEntropy ?? 0) < 5)
        case .gif:
            img = try optimiseGIF(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation)
        case .tiff:
            img = try optimiseTIFF(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveSize)
        case .jxl:
            img = self
        default:
            throw ClopError.unknownImageType(path)
        }

        guard allowLarger || img.data.count < data.count else {
            let oldBytes = data.count
            mainActor { optimiser.oldBytes = oldBytes }

            throw ClopError.imageSizeLarger(path)
        }

        return img
    }

    func convertToAVIF(asTempFile: Bool, cq: CompressionQuality? = nil) throws -> Image {
        try convertWithProc(to: "avif", asTempFile: asTempFile, cq: cq)
    }
    func convertToHEIC(asTempFile: Bool, cq: CompressionQuality? = nil) throws -> Image {
        try convertWithProc(to: "heic", asTempFile: asTempFile, cq: cq)
    }
    func convertToWEBP(asTempFile: Bool, cq: CompressionQuality? = nil) throws -> Image {
        try convertWithProc(to: "webp", asTempFile: asTempFile, cq: cq)
    }
    func convertToJXL(asTempFile: Bool, cq cqOverride: CompressionQuality? = nil) throws -> Image {
        let cq = cqOverride ?? Defaults[.imageCompression]
        let jxlData = try JXLCoder.encode(image: image, effort: cq.jxlEffort, quality: cq.jxlQuality)
        let outPath = path.tempFile(ext: "jxl")
        fm.createFile(atPath: outPath.string, contents: jxlData)
        try? outPath.setOptimisationStatusXattr("true")
        let finalPath = asTempFile ? outPath : try outPath.move(to: path.withExtension("jxl"), force: true)
        guard let data = fm.contents(atPath: finalPath.string) else {
            throw ClopError.conversionFailed(path)
        }
        // Reuse the original NSImage instead of decoding the JXL back.
        // JXLCoder.decode creates NSImages via initWithCGImage:size:CGSizeZero
        // which loses DPI metadata, causing realSize to report doubled dimensions
        // for images originally at 144 DPI (e.g. 3870x2514 shows as 7740x5028).
        return Image(data: data, path: finalPath, nsImage: image, type: .jxl, retinaDownscaled: retinaDownscaled)
    }

    func convertToAVIFAsync(asTempFile: Bool) async throws -> Image {
        try await convertWithProcAsync(to: "avif", asTempFile: asTempFile)
    }
    func convertToHEICAsync(asTempFile: Bool) async throws -> Image {
        try await convertWithProcAsync(to: "heic", asTempFile: asTempFile)
    }
    func convertToWEBPAsync(asTempFile: Bool) async throws -> Image {
        try await convertWithProcAsync(to: "webp", asTempFile: asTempFile)
    }

    func convertHDRHEICToJPEG(asTempFile: Bool, optimiser: Optimiser? = nil) throws -> Image {
        let tempDir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).filePath!
        tempDir.mkdir(withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir.string) }

        let proc = try tryProc(TO_GAIN_MAP_HDR.string, args: [path.string, tempDir.string, "-q", "1.0", "-j"], tries: 2)
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        // toGainMapHDR outputs <stem>.jpg (not .jpeg) into the output folder
        let outputJPG = tempDir / "\(path.stem ?? "output").jpg"
        let convPath = path.tempFile(ext: "jpeg")
        try outputJPG.move(to: convPath, force: true)

        try? convPath.setOptimisationStatusXattr("true")
        let finalPath = if asTempFile || path.withExtension("jpeg") == convPath {
            convPath
        } else {
            try convPath.move(to: path.withExtension("jpeg"), force: true)
        }
        guard let data = fm.contents(atPath: finalPath.string), let img = NSImage(data: data) else {
            throw ClopError.conversionFailed(path)
        }
        let converted = Image(data: data, path: finalPath, nsImage: img, type: .jpeg, retinaDownscaled: retinaDownscaled)
        if let optimiser {
            return try converted.optimise(optimiser: optimiser, allowLarger: true, adaptiveSize: false)
        }
        return converted
    }

    func convert(to type: UTType, asTempFile: Bool, optimiser: Optimiser? = nil, cq: CompressionQuality? = nil) throws -> Image {
        guard let ext = type.preferredFilenameExtension else {
            throw ClopError.unknownImageType(path)
        }
        // Compare by UTType, not extension string, so `.jpg` and `.jpeg` (or `.tif`/`.tiff`)
        // count as the same format: a same-format convert is a no-op instead of a wasteful
        // re-encode at default quality.
        guard type != self.type else {
            throw ClopError.alreadyOptimised(path)
        }

        switch type {
        case .avif:
            guard self.type == .png || self.type == .jpeg else {
                let png = try convert(to: .png, asTempFile: asTempFile)
                return try png.convertToAVIF(asTempFile: asTempFile, cq: cq)
            }
            return try convertToAVIF(asTempFile: asTempFile, cq: cq)
        case .webP:
            guard self.type == .png || self.type == .jpeg else {
                let png = try convert(to: .png, asTempFile: asTempFile)
                return try png.convertToWEBP(asTempFile: asTempFile, cq: cq)
            }
            return try convertToWEBP(asTempFile: asTempFile, cq: cq)
        case .heic:
            guard self.type == .png || self.type == .jpeg else {
                let png = try convert(to: .png, asTempFile: asTempFile)
                return try png.convertToHEIC(asTempFile: asTempFile, cq: cq)
            }
            return try convertToHEIC(asTempFile: asTempFile, cq: cq)
        case .jxl:
            return try convertToJXL(asTempFile: asTempFile, cq: cq)
        default:
            if self.type == .heic, type == .jpeg, path.hasExifHDR() {
                return try convertHDRHEICToJPEG(asTempFile: asTempFile, optimiser: optimiser)
            }
            let convPath = path.tempFile(ext: ext)
            guard let data = image.data(using: type.imgType) else {
                throw ClopError.unknownImageType(path)
            }
            fm.createFile(atPath: convPath.string, contents: data)

            convPath.waitForFile(for: 2)
            let path = asTempFile ? convPath : try convPath.move(to: path.withExtension(ext), force: true)
            guard let data = fm.contents(atPath: path.string), let img = NSImage(data: data) else {
                throw ClopError.conversionFailed(self.path)
            }
            let converted = Image(data: data, path: path, nsImage: img, type: type, retinaDownscaled: retinaDownscaled)
            if let optimiser {
                return try converted.optimise(optimiser: optimiser, allowLarger: true, adaptiveSize: false)
            }
            return converted
        }
    }

    func copyToClipboard(withPath: Bool? = nil) {
        let item = NSPasteboardItem()
        if withPath ?? Defaults[.copyImageFilePath] {
            item.setString(URL(fileURLWithPath: path.string, isDirectory: false).absoluteString, forType: .fileURL)
            item.setData(data, forType: type.pasteboardType)
            item.setString(path.string, forType: .string)
        } else {
            item.setData(data, forType: type.pasteboardType)
        }
        item.setString("true", forType: .optimisationStatus)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// Re-quantize the freshly resized PNG to a small palette so a downscaled flat/low-colour image does
    /// not end up larger than the original. Tries the original's own colour count first (so a 6-colour
    /// logo stays ~6 colours), then progressively smaller fallbacks, returning the first result smaller
    /// than `originalBytes`. Returns nil if none beat it.
    private func downscaledPNGUnderOriginal(resized: FilePath, originalBytes: Int, optimiser: Optimiser) -> Image? {
        var candidates: [Int] = []
        if let n = uniqueColorCount(cap: 256) {
            candidates.append(min(max(n, 2), 256))
        }
        for c in [128, 64, 32, 16] where !candidates.contains(c) {
            candidates.append(c)
        }

        let backup = (path.clopBackupPath?.exists ?? false) ? path.clopBackupPath : path
        for colors in candidates {
            let out = FilePath.images.appending(resized.name.string)
            try? out.delete()
            do {
                let proc = try tryProc(PNGQUANT.string, args: [
                    "\(colors)", "--force", "--speed", "1", "--output", out.string, resized.string,
                ], tries: 2) { p in
                    mainActor { optimiser.processes = [p] }
                }
                guard proc.terminationStatus == 0, out.exists, let sz = out.fileSize(), sz > 0, sz < originalBytes,
                      let data = fm.contents(atPath: out.string), NSImage(data: data) != nil
                else { continue }

                out.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
                if Defaults[.preserveDates] {
                    out.copyCreationModificationDates(from: backup ?? path)
                }
                try? out.setOptimisationStatusXattr("true")
                log.debug("Downscale re-quantized to \(colors) colours: \(sz) < \(originalBytes) bytes")
                return Image(data: data, path: out, type: .png, optimised: true, retinaDownscaled: retinaDownscaled)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Count the image's distinct colours up to `cap`, stopping early once exceeded. Used to size the
    /// downscale's palette back toward the original's. Returns nil if the bitmap can't be read.
    ///
    /// To avoid scanning millions of pixels on large images, the source is first drawn into a small
    /// buffer (capped at `maxSamples` pixels) with nearest-neighbour sampling. Nearest-neighbour never
    /// blends, so it only ever reproduces existing colours: a flat/low-colour image keeps its exact
    /// palette while the per-pixel work stays bounded regardless of the source resolution. The actual
    /// resampling runs in Core Graphics' accelerated blitter, not in a Swift loop.
    private func uniqueColorCount(cap: Int) -> Int? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let srcW = cg.width, srcH = cg.height
        guard srcW > 0, srcH > 0 else { return nil }

        let maxSamples = 256 * 1024
        let scale = min(1.0, (Double(maxSamples) / Double(srcW * srcH)).squareRoot())
        let w = max(1, Int((Double(srcW) * scale).rounded()))
        let h = max(1, Int((Double(srcH) * scale).rounded()))

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none // nearest-neighbour: subsample without inventing new colours
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var seen = Set<UInt32>()
        seen.reserveCapacity(cap + 2)
        pixels.withUnsafeBytes { raw in
            for px in raw.bindMemory(to: UInt32.self) {
                seen.insert(px)
                if seen.count > cap { break }
            }
        }
        return seen.count
    }

    private func writeCGImage(_ cgImage: CGImage, to dest: FilePath, as type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(dest.url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ClopError.conversionFailed(dest)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ClopError.conversionFailed(dest)
        }
    }

    private func conversionArgs(to format: String, outPath: FilePath, cq: CompressionQuality?) -> [String] {
        let q = "\((cq ?? Defaults[.imageCompression]).conversionQuality)"
        return switch format {
        case "avif": ["--avif", "-q", q, "-o", outPath.string, path.string]
        case "heic": ["-q", q, "-o", outPath.string, path.string]
        case "webp": ["-mt", "-q", q, "-sharp_yuv", "-metadata", "all", path.string, "-o", outPath.string]
        default: []
        }
    }
    private func conversionExecutable(to format: String) -> String {
        switch format {
        case "avif": HEIF_ENC.string
        case "heic": HEIF_ENC.string
        case "webp": CWEBP.string
        default: ""
        }
    }
    private func conversionType(to format: String) -> UTType? {
        switch format {
        case "avif": .avif
        case "heic": .heic
        case "webp": .webP
        default: nil
        }
    }
    private func conversionImage(to format: String, from proc: Process, asTempFile: Bool, outPath: FilePath) throws -> Image {
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        try? outPath.setOptimisationStatusXattr("true")
        let path = asTempFile ? outPath : try outPath.move(to: path.withExtension(format), force: true)
        guard let data = fm.contents(atPath: path.string), let img = NSImage(data: data) else {
            throw ClopError.conversionFailed(self.path)
        }
        return Image(data: data, path: path, nsImage: img, type: conversionType(to: format), retinaDownscaled: retinaDownscaled)
    }

    private func convertWithProc(to format: String, asTempFile: Bool, cq: CompressionQuality? = nil) throws -> Image {
        let tempFile = path.tempFile(ext: format)
        let args = conversionArgs(to: format, outPath: tempFile, cq: cq)
        let executable = conversionExecutable(to: format)

        let proc = try tryProc(executable, args: args, tries: 2)
        return try conversionImage(to: format, from: proc, asTempFile: asTempFile, outPath: tempFile)
    }
    private func convertWithProcAsync(to format: String, asTempFile: Bool, cq: CompressionQuality? = nil) async throws -> Image {
        let tempFile = path.tempFile(ext: format)
        let args = conversionArgs(to: format, outPath: tempFile, cq: cq)
        let executable = conversionExecutable(to: format)

        let proc = try await tryProcAsync(executable, args: args, tries: 2)
        return try conversionImage(to: format, from: proc, asTempFile: asTempFile, outPath: tempFile)
    }

}

@MainActor func optimiseClipboardPhotos() {
    let pb = NSPasteboard.general

    guard Defaults[.enablePhotosIntegration] else {
        return
    }

    let identifiers = getPhotoAssetIdentifiers(from: pb)
    guard !identifiers.isEmpty else {
        return
    }

    if identifiers.count > Defaults[.maxCopiedPhotosCount] {
        log.debug("Skipping Photos optimisation for \(identifiers.count) items (over limit \(Defaults[.maxCopiedPhotosCount]))")
        return
    }
    Task { await requestPhotosAccess() }

    let maxLongestSide = Defaults[.maxPhotosLength]
    let cropOrientation: CropOrientation = Defaults[.photoCropOrientation]
    let cropSize: CropSize? = {
        guard let maxLongestSide, maxLongestSide > 0 else {
            return nil
        }
        switch cropOrientation {
        case .adaptive:
            return CropSize(width: maxLongestSide, height: maxLongestSide, longEdge: true)
        case .landscape:
            return CropSize(width: maxLongestSide, height: 0, longEdge: false)
        case .portrait:
            return CropSize(width: 0, height: maxLongestSide, longEdge: false)
        }
    }()

    Task {
        var optimisedImages: [Image] = []

        let images = getPhotos(for: identifiers)
        for image in images {
            let optimisedImage: Image? = if let cropSize {
                try? await runImagePipeline(image, actions: [.downscale(factor: nil, cropSize: cropSize)], id: image.path.string, copyToClipboard: false, source: .clipboard)
            } else {
                try? await runImagePipeline(image, actions: [.optimise], id: image.path.string, copyToClipboard: false, source: .clipboard)
            }

            if let optimisedImage {
                optimisedImages.append(optimisedImage)
            }

            // Copy all optimised images to clipboard at once
            if optimisedImages.count == identifiers.count {
                let pbItems: [NSPasteboardItem] = optimisedImages.compactMap { img in
                    guard let data = img.path.url.absoluteString.data(using: .utf8) else { return nil }
                    let item = NSPasteboardItem()
                    item.setData(data, forType: .fileURL)
                    item.setString("true", forType: .optimisationStatus)
                    return item
                }
                pb.clearContents()
                pb.writeObjects(pbItems)
            }
        }
    }
}

@MainActor var lastClipboardImageHash: String?

@MainActor func optimiseClipboardImage(image: Image? = nil, item: NSPasteboardItem? = nil) {
    guard let img = image ?? (try? Image.fromPasteboard(item: item)) else {
        return
    }

    if img.optimised {
        let type: ItemType = .image(img.type)
        let pipelines = pipelinesFor(type: type, source: .clipboard)
        if !pipelines.isEmpty {
            Task {
                let optimiser = OM.optimiser(id: img.path.string, type: type, operation: "Running pipeline", hidden: true, source: .clipboard)
                optimiser.url = img.path.url
                await runPipelinesAfterOptimisation(file: img.path, type: type, source: .clipboard, optimiser: optimiser)
            }
        }
        return
    }

    let imgHash = img.hash
    if !imgHash.isEmpty, imgHash == lastClipboardImageHash {
        return
    }
    lastClipboardImageHash = imgHash

    let ignore = Defaults[.imageFormatsToSkip]
    if !ignore.isEmpty, let itemType = ItemType.from(filePath: img.path).utType, ignore.contains(itemType) {
        return
    }

    let appendResults = Defaults[.appendClipboardResults]

    if appendResults {
        let timeout = Defaults[.clipboardAccumulationTimeout]
        if timeout > 0 {
            let now = Date().timeIntervalSince1970
            let lastTimestamp = OM.optimisers
                .filter { $0.id.hasPrefix(Optimiser.IDs.clipboardImage) }
                .compactMap { opt -> TimeInterval? in
                    guard let ts = opt.id.split(separator: " ").last, let t = TimeInterval(ts) else { return nil }
                    return t
                }
                .max()
            if let last = lastTimestamp, now - last > TimeInterval(timeout) {
                OM.optimisers = OM.optimisers.filter { !$0.id.hasPrefix(Optimiser.IDs.clipboardImage) }
            }
        }
    }

    let clipboardID = appendResults
        ? "\(Optimiser.IDs.clipboardImage) \(Int(Date().timeIntervalSince1970))"
        : Optimiser.IDs.clipboardImage
    let copyToClipboard = !appendResults || Defaults[.copyConsecutiveClipboardImages]
    let type: ItemType = .image(img.type)
    let imgPath = img.path
    Task {
        // When every clipboard pipeline skips optimisation (e.g. a `downscale(0.5)`-only
        // pipeline), don't run a separate visible optimise pass: it would show its own
        // floating result alongside the pipeline's final result. Mirror the file-watcher
        // `allSkip` path and let the pipeline produce the single result on a hidden parent.
        // When no pipeline condition matches, fall back to the normal optimise pass:
        // copying to clipboard is a strong optimisation intent, unlike file watching.
        let pipelines = pipelinesFor(type: type, source: .clipboard)
        let allSkip = !pipelines.isEmpty && pipelines.allSatisfy(\.skipsPreOptimisation)
        var handledByPipelines = false
        if allSkip {
            let optimiser = OM.optimiser(id: clipboardID, type: type, operation: "Running pipeline", hidden: true, source: .clipboard)
            optimiser.url = imgPath.url
            optimiser.startingURL = imgPath.url
            let (_, anyRan) = await runPipelinesAfterOptimisation(file: imgPath, type: type, source: .clipboard, optimiser: optimiser)
            handledByPipelines = anyRan
        }
        if !handledByPipelines {
            if let result = try? await runImagePipeline(img, actions: [.optimise], id: clipboardID, copyToClipboard: copyToClipboard, source: .clipboard) {
                if let optimiser = opt(clipboardID) {
                    await runPipelinesAfterOptimisation(file: result.path, type: type, source: .clipboard, optimiser: optimiser)
                }
            } else if let optimiser = opt(clipboardID) {
                await runPipelinesAfterOptimisation(file: imgPath, type: type, source: .clipboard, optimiser: optimiser)
            }
        }
    }
}

@MainActor func cancelImageOptimisation(path: FilePath) {
    imageOptimiseDebouncers[path.string]?.cancel()
    imageOptimiseDebouncers.removeValue(forKey: path.string)

    guard let optimiser = opt(path.string) else {
        return
    }
    optimiser.stop(animateRemoval: false)
    optimiser.remove(after: 0, withAnimation: false)
}

@MainActor func shouldHandleImage(event: EonilFSEventsEvent) async -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          IMAGE_EXTENSIONS.contains(ext)
    else {
        return false
    }

    let formatsToSkip = Defaults[.imageFormatsToSkip]
        .lazy
        .compactMap { $0 == .jpeg ? ["jpg", "jpeg"] : [$0.preferredFilenameExtension] }
        .joined()
    guard !formatsToSkip.contains(ext) else {
        return false
    }

    log.debug("\(path.shellString): \(flag)")

    // The content checks below do blocking filesystem I/O (xattr read, size stat, image-header
    // decode). The FSEvents callback is delivered on the main thread, so running them here would hang
    // the UI for tens of seconds on a burst of events or a slow/network volume (ANR). Only Defaults +
    // the filesystem are touched, so it's safe to run off the main actor; the debouncer bookkeeping
    // stays on the main actor below.
    let eventPath = event.path
    let io = await Task.detached { () -> (passes: Bool, exists: Bool) in
        let exists = fm.fileExists(atPath: eventPath)
        guard exists, !eventPath.contains(FilePath.clopBackups.string),
              flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
              !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0,
              Defaults[.maxImageSizeMB] == 0 || size < Defaults[.maxImageSizeMB] * 1_000_000,
              Defaults[.minImageSizeKB] == 0 || size >= Defaults[.minImageSizeKB] * 1000
        else {
            return (false, exists)
        }

        let minRes = Defaults[.minImageResolution]
        let maxRes = Defaults[.maxImageResolution]
        if minRes > 0 || maxRes > 0 {
            guard let source = CGImageSourceCreateWithURL(path.url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  minRes == 0 || (w >= minRes && h >= minRes),
                  maxRes == 0 || (w <= maxRes && h <= maxRes)
            else { return (false, exists) }
        }
        return (true, exists)
    }.value

    guard io.passes else {
        if flag.contains(.itemRemoved) || !io.exists {
            imageOptimiseDebouncers[event.path]?.cancel()
            imageOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    guard imageOptimiseDebouncers[event.path] == nil else { return false }
    return true
}

extension FilePath {
    var fileContentsHash: String? {
        fm.contents(atPath: string)?.sha256
    }

    /// True when the file is a GIF with more than one frame (animated). Static GIFs and
    /// non-GIF/unreadable files return false. Reads only the container index, not pixel data.
    var isAnimatedGIF: Bool {
        guard `extension`?.lowercased() == "gif" else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        return CGImageSourceGetCount(source) > 1
    }
}

@MainActor func getCachedOptimisedImage(img: Image, id: String?, retinaDownscaled: Bool) throws -> Image? {
    guard id != Optimiser.IDs.clipboard, let path = OM.optimisedFilesByHash[img.hash], path.exists,
          let clipOpt = OM.clipboardImageOptimiser, let clipOptHash = clipOpt.originalURL?.existingFilePath?.fileContentsHash,
          clipOptHash == img.hash, let optImg = Image(path: path, optimised: true, retinaDownscaled: retinaDownscaled)
    else {
        return nil
    }

    guard optImg.path != img.path, optImg.type == img.type else {
        return nil
    }

    try optImg.path.copy(to: img.path, force: true)
    return optImg
}

import Accelerate
import CoreGraphics

extension NSImage {
    var largeAreaEntropy: Double? {
        size.area > 1_000_000 ? entropy : nil
    }
    var entropy: Double? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return calculateShannonEntropy(from: cgImage)
    }
}

func calculateShannonEntropy(from cgImage: CGImage) -> Double? {
    guard let dataProvider = cgImage.dataProvider,
          let data = dataProvider.data
    else {
        return nil
    }

    let pixelData = CFDataGetBytePtr(data)
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = cgImage.bytesPerRow

    var buffer = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: pixelData),
        height: vImagePixelCount(height),
        width: vImagePixelCount(width),
        rowBytes: bytesPerRow
    )

    var histogramAlpha = [vImagePixelCount](repeating: 0, count: 256)
    var histogramRed = [vImagePixelCount](repeating: 0, count: 256)
    var histogramGreen = [vImagePixelCount](repeating: 0, count: 256)
    var histogramBlue = [vImagePixelCount](repeating: 0, count: 256)

    let error = histogramAlpha.withUnsafeMutableBufferPointer { zeroPtr in
        histogramRed.withUnsafeMutableBufferPointer { onePtr in
            histogramGreen.withUnsafeMutableBufferPointer { twoPtr in
                histogramBlue.withUnsafeMutableBufferPointer { threePtr in
                    var histogramBins = [
                        zeroPtr.baseAddress,
                        onePtr.baseAddress,
                        twoPtr.baseAddress,
                        threePtr.baseAddress,
                    ]

                    return histogramBins.withUnsafeMutableBufferPointer { histogramBinsPtr in
                        vImageHistogramCalculation_ARGB8888(
                            &buffer,
                            histogramBinsPtr.baseAddress!,
                            vImage_Flags(kvImageLeaveAlphaUnchanged)
                        )
                    }
                }
            }
        }
    }

    guard error == kvImageNoError else {
        return nil
    }

    let totalPixels = Double(width * height) * 3
    var entropy = 0.0

    let histogram = histogramRed + histogramGreen + histogramBlue
    for count in histogram.filter({ $0 > 0 }) {
        let probability = Double(count) / totalPixels
        entropy -= probability * log2(probability)
    }

    return entropy
}
