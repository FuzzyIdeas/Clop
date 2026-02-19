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
import Lowtech
import Photos
import System
import UniformTypeIdentifiers

var PNGQUANT = BIN_DIR.appendingPathComponent("pngquant").filePath!
var JPEGOPTIM = BIN_DIR.appendingPathComponent("jpegoptim").filePath!
var JPEGOPTIM_OLD = BIN_DIR.appendingPathComponent("jpegoptim-old").filePath!
var GIFSICLE = BIN_DIR.appendingPathComponent("gifsicle").filePath!
var VIPSTHUMBNAIL = BIN_DIR.appendingPathComponent("vipsthumbnail").filePath!

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
    var type: UTType? { cgImage(forProposedRect: nil, context: nil, hints: nil)?.utType.flatMap { t in UTType(t as String) } }
    var imgType: NSBitmapImageRep.FileType? { type?.imgType }

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
    var type: UTType? { utType.flatMap { t in UTType(t as String) } }
    var imgType: NSBitmapImageRep.FileType? { type?.imgType }
}

extension NSPasteboard.PasteboardType {
    static var optimisationStatus: NSPasteboard.PasteboardType = .init("clop.optimisation.status")
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

        guard let data = data ?? ((path != nil) ? fm.contents(atPath: path!.string) : nil), let nsImage = nsImage ?? NSImage(data: data) else {
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
    var size: NSSize { image.realSize }

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

        let proc: Process? = if let shortcut {
            optimiser.runShortcut(shortcut, outFile: shortcutOutFile, url: path.url)
        } else {
            optimiser.runAutomation(outFile: shortcutOutFile, source: source, url: path.url, type: .image(type))
        }
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
            outImg = (try? outImg.optimise(optimiser: optimiser, allowLarger: allowLarger, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: Defaults[.adaptiveImageSize])) ?? outImg
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

        let aggressiveOptimisation = aggressiveOptimisation ?? Defaults[.useAggressiveOptimisationGIF]
        mainActor { optimiser.aggressive = aggressiveOptimisation }

        let backup = path.backup(path: path.clopBackupPath, operation: .copy)
        let proc = try tryProc(
            GIFSICLE.string,
            args: [
                "-O\(aggressiveOptimisation ? 3 : 2)",
                "--lossy=\(aggressiveOptimisation ? 80 : 30)",
                "--threads=\(ProcessInfo.processInfo.activeProcessorCount)",
            ] +
                (aggressiveOptimisation ? ["--colors=256"] : []) +
                [
                    "--output",
                    tempFile.string,
                    (resizedFile ?? path).string,
                ],
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

        let aggressive = aggressiveOptimisation ?? Defaults[.useAggressiveOptimisationJPEG]
        mainActor { optimiser.aggressive = aggressive }

        #if arch(arm64)
            let archDependentArgs = ["--auto-mode"]
        #else
            let archDependentArgs: [String] = []
        #endif

        let jpegProc = Proc(cmd: JPEGOPTIM.string, args: [
            "--keep-all", "--force", "--max", aggressive ? "68" : "85",
        ] + archDependentArgs + [
            "--overwrite",
            "--dest",
            FilePath.images.string,
            path.string,
        ])

        var procs = [jpegProc]

        var pngOutFile: FilePath?
        if testPNG, let png = try? convert(to: .png, asTempFile: true) {
            let aggressive = aggressiveOptimisation ?? Defaults[.useAggressiveOptimisationPNG]
            pngOutFile = FilePath.images.appending(png.path.name.string)
            if pngOutFile != png.path {
                try? pngOutFile!.delete()
            }
            let pngProc = Proc(cmd: PNGQUANT.string, args: [
                "--force",
//                "--speed", aggressive ? "1" : "3",
                "--quality", aggressive ? "0-85" : "0-100",
            ] + (pngOutFile == png.path ? ["--ext", ".png"] : ["--output", pngOutFile!.string]) + [png.path.string])

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
                "--keep-all", "--force", "--max", aggressive ? "70" : "90",
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
                log.error(error.localizedDescription)
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

        let aggressive = aggressiveOptimisation ?? Defaults[.useAggressiveOptimisationPNG]
        mainActor { optimiser.aggressive = aggressive }

        let pngProc = Proc(cmd: PNGQUANT.string, args: [
            "--force",
//            "--speed", aggressive ? "1" : "3",
            "--quality", aggressive ? "0-85" : "0-100",
        ] + (tempFile == path ? ["--ext", ".png"] : ["--output", tempFile.string]) + [path.string])
        var procs = [pngProc]

        var jpegOutFile: FilePath?
        if testJPEG, !image.hasTransparentPixels, let jpeg = try? convert(to: .jpeg, asTempFile: true) {
            let aggressive = aggressiveOptimisation ?? Defaults[.useAggressiveOptimisationJPEG]

            let jpegProc = Proc(cmd: JPEGOPTIM.string, args: [
                "--keep-all", "--force", "--max", aggressive ? "70" : "90",
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
                log.error(error.localizedDescription)
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
        if path != pathForResize {
            try path.copy(to: pathForResize, force: true)
        }

        if type == .gif, let gif = Image(path: pathForResize, retinaDownscaled: retinaDownscaled) {
            return try gif.optimiseGIF(optimiser: optimiser, cropTo: cropSize, fromSize: self.size, aggressiveOptimisation: aggressiveOptimisation)
        }

        let size = cropSize.computedSize(from: size)
        let sizeStr = "\(size.width.evenInt)x\(size.height.evenInt)"
        let args = ["-s", sizeStr, "-o", "%s_\(sizeStr).\(path.extension!)[Q=100]", "--smartcrop", cropSize.smartCrop ? "attention" : "centre", pathForResize.string]
        let proc = try tryProc(VIPSTHUMBNAIL.string, args: args, tries: 3) { proc in
            mainActor { optimiser.processes = [proc] }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }

        let resizedPath = pathForResize.withSize(size)
        resizedPath.waitForFile(for: 2.0)
        if resizedPath != pathForResize {
            try resizedPath.copy(to: pathForResize, force: true)
        }

        guard let pbImage = Image(path: pathForResize, optimised: false, retinaDownscaled: retinaDownscaled) else {
            throw ClopError.downscaleFailed(pathForResize)
        }
        return try pbImage.optimise(optimiser: optimiser, allowLarger: true, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveSize)
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

    func convertToAVIF(asTempFile: Bool) throws -> Image {
        try convertWithProc(to: "avif", asTempFile: asTempFile)
    }
    func convertToHEIC(asTempFile: Bool) throws -> Image {
        try convertWithProc(to: "heic", asTempFile: asTempFile)
    }
    func convertToWEBP(asTempFile: Bool) throws -> Image {
        try convertWithProc(to: "webp", asTempFile: asTempFile)
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

    func convert(to type: UTType, asTempFile: Bool, optimiser: Optimiser? = nil) throws -> Image {
        guard let ext = type.preferredFilenameExtension else {
            throw ClopError.unknownImageType(path)
        }
        guard ext != path.extension else {
            throw ClopError.alreadyOptimised(path)
        }

        switch type {
        case .avif:
            guard self.type == .png || self.type == .jpeg else {
                let png = try convert(to: .png, asTempFile: asTempFile)
                return try png.convertToAVIF(asTempFile: asTempFile)
            }
            return try convertToAVIF(asTempFile: asTempFile)
        case .webP:
            guard self.type == .png || self.type == .jpeg else {
                let png = try convert(to: .png, asTempFile: asTempFile)
                return try png.convertToWEBP(asTempFile: asTempFile)
            }
            return try convertToWEBP(asTempFile: asTempFile)
        case .heic:
            guard self.type == .png || self.type == .jpeg else {
                let png = try convert(to: .png, asTempFile: asTempFile)
                return try png.convertToHEIC(asTempFile: asTempFile)
            }
            return try convertToHEIC(asTempFile: asTempFile)
        default:
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

    private func conversionArgs(to format: String, outPath: FilePath) -> [String] {
        switch format {
        case "avif": ["--avif", "-q", "60", "-o", outPath.string, path.string]
        case "heic": ["-q", "60", "-o", outPath.string, path.string]
        case "webp": ["-mt", "-q", "60", "-sharp_yuv", "-metadata", "all", path.string, "-o", outPath.string]
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

    private func convertWithProc(to format: String, asTempFile: Bool) throws -> Image {
        let tempFile = path.tempFile(ext: format)
        let args = conversionArgs(to: format, outPath: tempFile)
        let executable = conversionExecutable(to: format)

        let proc = try tryProc(executable, args: args, tries: 2)
        return try conversionImage(to: format, from: proc, asTempFile: asTempFile, outPath: tempFile)
    }
    private func convertWithProcAsync(to format: String, asTempFile: Bool) async throws -> Image {
        let tempFile = path.tempFile(ext: format)
        let args = conversionArgs(to: format, outPath: tempFile)
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

    Task.init {
        var optimisedImages: [Image] = []

        let images = getPhotos(for: identifiers)
        for image in images {
            let optimisedImage: Image? = if let cropSize {
                try? await downscaleImage(image, cropTo: cropSize, copyToClipboard: false, id: image.path.string, source: .clipboard)
            } else {
                try? await optimiseImage(image, copyToClipboard: false, id: image.path.string, source: .clipboard)
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

@MainActor func optimiseClipboardImage(image: Image? = nil, item: NSPasteboardItem? = nil) {
    guard let img = image ?? (try? Image.fromPasteboard(item: item)) else {
        return
    }

    let ignore = Defaults[.imageFormatsToSkip]
    if !ignore.isEmpty, let itemType = ItemType.from(filePath: img.path).utType, ignore.contains(itemType) {
        return
    }

    Task.init { try? await optimiseImage(img, copyToClipboard: true, id: Optimiser.IDs.clipboardImage, source: .clipboard) }
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

@MainActor func shouldHandleImage(event: EonilFSEventsEvent) -> Bool {
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

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.clopBackups.string),
          flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
          !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0, size < Defaults[.maxImageSizeMB] * 1_000_000, imageOptimiseDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            imageOptimiseDebouncers[event.path]?.cancel()
            imageOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    return true
}

extension FilePath {
    var fileContentsHash: String? {
        fm.contents(atPath: string)?.sha256
    }
}

@MainActor func getCachedOptimisedImage(img: Image, id: String?, retinaDownscaled: Bool) throws -> Image? {
    guard id != Optimiser.IDs.clipboard, let path = OM.optimisedFilesByHash[img.hash], path.exists,
          let clipOpt = OM.clipboardImageOptimiser, let clipOptHash = clipOpt.originalURL?.existingFilePath?.fileContentsHash,
          clipOptHash == img.hash, let optImg = Image(path: path, optimised: true, retinaDownscaled: retinaDownscaled)
    else {
        return nil
    }

    guard optImg.path != img.path else {
        return nil
    }

    if optImg.type == img.type {
        try optImg.path.copy(to: img.path, force: true)
    } else {
        try optImg.path.copy(to: img.path.dir, force: true)
    }
    return optImg
}

@discardableResult
@MainActor func optimiseImage(
    _ img: Image,
    copyToClipboard: Bool = false,
    id: String? = nil,
    debounceMS: Int = 0,
    allowTiff: Bool? = nil,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    adaptiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil,
    shortcut: Shortcut? = nil
) async throws -> Image? {
    let path = img.path
    var img = img
    guard !img.optimised else {
        throw ClopError.alreadyOptimised(path)
    }
    var pathString = path.string

    guard img.type != .tiff || (allowTiff ?? Defaults[.optimiseTIFF]) else {
        log.debug("Skipping image \(pathString) because TIFF optimisation is disabled")
        throw ClopError.skippedType("TIFF optimisation is disabled")
    }

    if id == Optimiser.IDs.clipboardImage, pauseForNextClipboardEvent {
        log.debug("Skipping image \(pathString) because it was paused")
        pauseForNextClipboardEvent = false
        throw ClopError.optimisationPaused(path)
    }

    var allowLarger = allowLarger
    var originalPath: FilePath?
    let applyConversionBehaviour: (Image, Image) throws -> Image = { img, converted in
        guard img.path.dir != FilePath.images else {
            return converted
        }

        let behaviour = Defaults[.convertedImageBehaviour]
        if behaviour == .inPlace, let backupPath = img.path.clopBackupPath {
            img.path.backup(path: backupPath, force: true, operation: .move)
        }
        if behaviour != .temporary {
            try converted.path.setOptimisationStatusXattr("pending")
            let path = try converted.path.copy(to: img.path.dir)
            originalPath = img.path
            return Image(data: converted.data, path: path, nsImage: converted.image, type: converted.type, optimised: converted.optimised, retinaDownscaled: converted.retinaDownscaled)
        }
        return converted
    }

    // let shouldDownscale = Defaults[.downscaleRetinaImages] && img.pixelScale > 1

    let conversionFormat: UTType? = Defaults[.formatsToConvertToJPEG].contains(img.type) ? .jpeg : (Defaults[.formatsToConvertToPNG].contains(img.type) ? .png : nil)
    if let conversionFormat {
        let converted = try img.convert(to: conversionFormat, asTempFile: true)

        img = try applyConversionBehaviour(img, converted)
        pathString = img.path.string
        allowLarger = true
    } else if let optImg = try getCachedOptimisedImage(img: img, id: id, retinaDownscaled: false) {
        log.debug("Using cached optimised image \(optImg.path)")
        return optImg
    }

    let optimiser = OM.optimiser(
        id: id ?? pathString, type: .image(img.type),
        operation: "Optimising" + (aggressiveOptimisation ?? false ? " (aggressive)" : ""),
        hidden: hideFloatingResult, source: source, indeterminateProgress: true
    )
    if !hideFloatingResult {
        optimiser.thumbnail = img.image
    }
    optimiser.downscaleFactor = 1.0
    optimiser.newSize = nil
    optimiser.newBytes = -1
    if let url = originalPath?.url {
        optimiser.convertedFromURL = url
    }

    var done = false
    var result: Image?

    imageOptimiseDebouncers[pathString]?.cancel()
    imageResizeDebouncers[pathString]?.cancel()

    let workItem = mainAsyncAfter(ms: debounceMS) {
        scalingFactor = 1.0
        optimiser.stop(remove: false)
        optimiser.operation = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressiveOptimisation ?? false ? " (aggressive)" : "")
        optimiser.originalURL = img.path.backup(path: img.path.clopBackupPath, force: false, operation: .copy)?.url ?? img.path.url
        optimiser.url = img.path.url
        if id == Optimiser.IDs.clipboardImage {
            optimiser.startingURL = optimiser.url
        }
        if !hideFloatingResult {
            OM.current = optimiser
        }

        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let img = img
        let pathString = pathString
        let allowLarger = allowLarger
        var previouslyCached = true

        imageOptimisationQueue.addOperation {
            defer {
                mainActor { done = true }
            }

            var optimisedImage: Image?
            do {
                log.debug("Optimising image \(pathString)")
//                if shouldDownscale {
//                    img.retinaDownscaled = true
//                    mainActor { optimiser.retinaDownscaled = true }
//                    optimisedImage = try img.resize(toFraction: (1.0 / img.pixelScale).d, optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveOptimisation ?? Defaults[.adaptiveImageSize])
//                    mainActor { optimiser.downscaleFactor = (1.0 / img.pixelScale).d }
//                } else {
                    optimisedImage = try img.optimise(optimiser: optimiser, allowLarger: allowLarger, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveOptimisation ?? Defaults[.adaptiveImageSize])
//                }
                if optimisedImage!.type == img.type {
                    optimisedImage = try optimisedImage?.copyWithPath(optimisedImage!.path.copy(to: img.path, force: true))
                } else {
                    mainActor {
                        optimiser.url = optimisedImage!.path.url
                        optimiser.type = .image(optimisedImage!.type)
                    }
                }

                // Save optimised image path to cache to avoid re-optimising it after it is saved to file
                mainActor {
                    if OM.optimisedFilesByHash[img.hash] == nil {
                        previouslyCached = false
                        OM.optimisedFilesByHash[img.hash] = optimisedImage!.path
                    }
                }

            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error optimising image \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedImage = img
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error optimising image \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error optimising image \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard var optimisedImage else { return }

            var newBytes = optimisedImage.data.count
            var newSize = optimisedImage.size

            var shortcutChangedImage = false
            if let changedImage = try? optimisedImage.runThroughShortcut(shortcut: shortcut, optimiser: optimiser, allowLarger: allowLarger, aggressiveOptimisation: aggressiveOptimisation ?? false, source: source) {
                optimisedImage = changedImage
                newBytes = changedImage.data.count
                newSize = changedImage.size
                mainActor {
                    optimiser.url = changedImage.path.url
                    optimiser.type = .image(changedImage.type)
                }

                shortcutChangedImage = true
            }

            mainActor {
                if !hideFloatingResult {
                    OM.current = optimiser
                }
                optimiser.finish(
                    oldBytes: img.data.count, newBytes: newBytes,
                    oldSize: img.size, newSize: newSize,
                    removeAfterMs: id == Optimiser.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
                )

                if id == Optimiser.IDs.clipboardImage, Defaults[.copyImageFilePath], Defaults[.useCustomNameTemplateForClipboardImages] {
                    optimiser.rename(to: generateFileName(template: Defaults[.customNameTemplateForClipboardImages] ?! DEFAULT_NAME_TEMPLATE, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber]))
                    if let path = optimiser.path {
                        optimisedImage = Image(data: optimisedImage.data, path: path, nsImage: optimisedImage.image, type: optimisedImage.type, optimised: optimisedImage.optimised, retinaDownscaled: optimisedImage.retinaDownscaled)
                    }
                }

                if copyToClipboard {
                    optimisedImage.copyToClipboard()
                }
                if !shortcutChangedImage, !previouslyCached {
                    OM.optimisedFilesByHash[img.hash] = optimisedImage.path
                }

                result = optimisedImage
            }
        }
    }

    imageOptimiseDebouncers[pathString] = workItem
    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}

@discardableResult
@MainActor func downscaleImage(
    _ img: Image,
    toFactor factor: Double? = nil,
    cropTo cropSize: CropSize? = nil,
    saveTo savePath: FilePath? = nil,
    copyToClipboard: Bool = false,
    id: String? = nil,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    adaptiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil
) async throws -> Image? {
    imageResizeDebouncers[img.path.string]?.cancel()
    if let cropSize {
        scalingFactor = cropSize.factor(from: img.size)
    } else if let factor {
        scalingFactor = factor
    } else if let currentFactor = opt(id ?? img.path.string)?.downscaleFactor {
        scalingFactor = max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    } else if let current = OM.current, current.id == (id ?? img.path.string) {
        scalingFactor = max(current.downscaleFactor > 0.5 ? current.downscaleFactor - 0.25 : current.downscaleFactor - 0.1, 0.1)
        current.downscaleFactor = scalingFactor
    } else {
        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
    }

    var img = img
    var pathString = img.path.string
    var originalPath: FilePath?
    let applyConversionBehaviour: (Image, Image) throws -> Image = { img, converted in
        guard img.path.dir != FilePath.images else {
            return converted
        }

        let behaviour = Defaults[.convertedImageBehaviour]
        if behaviour == .inPlace, let backupPath = img.path.clopBackupPath {
            img.path.backup(path: backupPath, force: true, operation: .move)
        }
        if behaviour != .temporary {
            try converted.path.setOptimisationStatusXattr("pending")
            let path = try converted.path.copy(to: img.path.dir)
            originalPath = img.path
            return Image(data: converted.data, path: path, nsImage: converted.image, type: converted.type, optimised: converted.optimised, retinaDownscaled: converted.retinaDownscaled)
        }
        return converted
    }

    let conversionFormat: UTType? = Defaults[.formatsToConvertToJPEG].contains(img.type) ? .jpeg : (Defaults[.formatsToConvertToPNG].contains(img.type) ? .png : nil)
    if let conversionFormat {
        let converted = try img.convert(to: conversionFormat, asTempFile: true)

        img = try applyConversionBehaviour(img, converted)
        pathString = img.path.string
    }

    let scaleString = if let size = cropSize?.computedSize(from: img.size) {
        "\(size.width > 0 ? size.width.i.s : "Auto")×\(size.height > 0 ? size.height.i.s : "Auto")"
    } else {
        "\((scalingFactor * 100).intround)%"
    }

    let optimiser = OM.optimiser(id: id ?? pathString, type: .image(img.type), operation: "Scaling to \(scaleString)", hidden: hideFloatingResult, source: source, indeterminateProgress: true)
    let aggressive = aggressiveOptimisation ?? optimiser.aggressive
    if aggressive {
        optimiser.operation += " (aggressive)"
    }
    optimiser.remover = nil
    optimiser.inRemoval = false
    optimiser.stop(remove: false)
    if !hideFloatingResult {
        optimiser.thumbnail = img.image
    }
    optimiser.downscaleFactor = scalingFactor
    if let url = originalPath?.url {
        optimiser.convertedFromURL = url
    }
    optimiser.originalURL = img.path.backup(path: img.path.clopBackupPath, force: false, operation: .copy)?.url ?? img.path.url

    var result: Image?
    var done = false

    imageOptimiseDebouncers[pathString]?.cancel()
    imageResizeDebouncers[pathString]?.cancel()

    let workItem = optimisationQueue.asyncAfter(ms: 500) {
        var resized: Image?
        defer {
            mainActor { done = true }
        }

        if !hideFloatingResult {
            mainActor {
                OM.current = optimiser
            }
        }
        do {
            if let cropSize, cropSize.width > 0, cropSize.height > 0 {
                resized = try img.resize(toSize: cropSize, optimiser: optimiser, aggressiveOptimisation: aggressive, adaptiveSize: adaptiveOptimisation ?? false)
            } else {
                if let s = cropSize?.ns {
                    scalingFactor = s.width == 0 ? s.height / img.size.height : s.width / img.size.width
                }
                resized = try img.resize(toFraction: scalingFactor, optimiser: optimiser, aggressiveOptimisation: aggressive, adaptiveSize: adaptiveOptimisation ?? false)
            }

            var newURL = resized!.path.url
            if id != Optimiser.IDs.clipboardImage, resized!.type == img.type {
                newURL = try (resized!.path.copy(to: savePath ?? img.path, force: true)).url
            }
            mainActor {
                optimiser.url = newURL
                optimiser.type = .image(resized!.type)
            }
        } catch let ClopProcError.processError(proc) {
            if proc.terminated {
                log.debug("Process terminated by us: \(proc.commandLine)")
            } else {
                log.error("Error downscaling image \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                mainActor { optimiser.finish(error: "Downscaling failed") }
            }
        } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
            log.warning("Image size larger than original: \(pathString)")

            resized = img
            mainActor { optimiser.info = "File already fully compressed" }
        } catch let error as ClopError {
            log.error("Error downscaling image \(pathString): \(error.description)")
            mainActor { optimiser.finish(error: error.humanDescription) }
        } catch {
            log.error("Error downscaling image \(pathString): \(error)")
            mainActor { optimiser.finish(error: "Optimisation failed") }
        }

        guard let resized else { return }

        mainActor {
            optimiser.finish(
                oldBytes: img.data.count, newBytes: resized.data.count,
                oldSize: img.size, newSize: resized.size,
                removeAfterMs: id == Optimiser.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
            )
            if copyToClipboard {
                resized.copyToClipboard()
            }
            result = resized
        }
    }

    imageResizeDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    return result
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
