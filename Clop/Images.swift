//
//  Images.swift
//  Clop
//
//  Created by Alin Panaitiu on 10.07.2023.
//

import Cocoa
import Defaults
import EonilFSEvents
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

let PNGQUANT = BIN_DIR.appendingPathComponent("pngquant").existingFilePath!
let JPEGOPTIM = BIN_DIR.appendingPathComponent("jpegoptim").existingFilePath!
let GIFSICLE = BIN_DIR.appendingPathComponent("gifsicle").existingFilePath!
let EXIFTOOL = BIN_DIR.appendingPathComponent("exiftool").existingFilePath!
let VIPSTHUMBNAIL = BIN_DIR.appendingPathComponent("vipsthumbnail").existingFilePath!

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
}

extension UTType {
    var imgType: NSBitmapImageRep.FileType {
        switch self {
        case .png:
            return .png
        case .jpeg:
            return .jpeg
        case .gif:
            return .gif
        default:
            return .png
        }
    }

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .png:
            return .png
        case .jpeg:
            return .jpeg
        case .gif:
            return .gif
        case .pdf:
            return .pdf
        default:
            return .png
        }
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

        var type = type ?? nsImage.type
        if let path {
            self.path = path
        } else {
            guard let ext = type?.preferredFilenameExtension else { return nil }

            let tempPath = fm.temporaryDirectory.appendingPathComponent("\(Int.random(in: 100 ... 100_000)).\(ext)").path
            guard fm.createFile(atPath: tempPath, contents: data) else { return nil }

            self.path = FilePath(tempPath)
        }
        type = type ?? UTType(filenameExtension: self.path.extension ?? "") ?? UTType(mimeType: self.path.fetchFileType() ?? "") ?? .png
        self.data = data
        self.type = type!
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

    init?(nsImage: NSImage, data: Data? = nil, type: UTType? = nil, optimised: Bool? = nil, retinaDownscaled: Bool) {
        guard let type = type ?? nsImage.type, let ext = type.preferredFilenameExtension,
              let data = data ?? nsImage.data
        else { return nil }

        image = nsImage
        self.data = data
        let tempPath = fm.temporaryDirectory.appendingPathComponent("\(Int.random(in: 100 ... 100_000)).\(ext)").path
        guard fm.createFile(atPath: tempPath, contents: data) else { return nil }

        path = FilePath(tempPath)
        self.type = type
        self.retinaDownscaled = retinaDownscaled
        self.optimised = optimised ?? false
    }

    static let PNG_HEADER: Data = .init([0x89, 0x50, 0x4E, 0x47])
    static let JPEG_HEADER: Data = .init([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    static let GIF_HEADER: Data = .init([0x47, 0x49, 0x46, 0x38, 0x39])

    static var NOT_IMAGE_TYPE_PATTERN =
        try! Regex(
            #"com\.microsoft\.ole\.source|com\.microsoft\.Art|com\.microsoft\.PowerPoint|com\.microsoft\.image-svg-xml|com\.microsoft\.DataObject|IBPasteboardType|IBDocument|com\.pixelmator|com\.adobe\.[^.]+\.local-private-clipboard-marker"#
        )
    static var NOT_IMAGE_TYPES: Set<NSPasteboard.PasteboardType> = [
        .init("com.apple.icns"),
        .init("public.svg-image"),
        .init("public.xml"),
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
    ]

    let data: Data
    let path: FilePath
    var image: NSImage

    lazy var optimised: Bool = {
        switch type {
        case .png:
            return path.string.hasSuffix(".clop.png")
        case .jpeg:
            return path.string.hasSuffix(".clop.jpg")
        case .gif:
            return path.string.hasSuffix(".clop.gif")
        default:
            return false
        }
    }()

    var type: UTType
    @Atomic var retinaDownscaled: Bool

    var pixelScale: Float {
        (image.realSize.width / image.size.width).f
    }
    var description: String {
        "<Image: \(path) (\(size.s)) [\(optimised ? "" : "NOT ")OPTIMIZED]>"
    }
    var size: NSSize { image.realSize }

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
            guard Defaults[.optimiseImagePathClipboard], let path = item.existingFilePath, path.isImage else {
                return nil
            }
            return NSImage(contentsOfFile: path.string)
        }

        var nsImage: NSImage?
        if !allowImage, !typeSet.intersectsSet(NOT_IMAGE_TYPES.without(.icon)), let img = nsImageFromPath() {
            nsImage = img
            allowImage = true
        }
        guard allowImage, let nsImage = nsImage ?? NSImage(pasteboard: pb) ?? nsImageFromPath() else {
            throw ClopError.noClipboardImage(item.filePath ?? .init())
        }

        let optimised = item.string(forType: .optimisationStatus) == "true"
        let data: Data? = [NSPasteboard.PasteboardType.png, .jpeg, .gif, .tiff].lazy.compactMap { t in
            item.data(forType: t)
        }.first

        if let originalPath = item.existingFilePath, let path = try? originalPath.copy(to: URL.temporaryDirectory.filePath, force: true),
           let img = Image(path: path, data: data, nsImage: nsImage, optimised: optimised, retinaDownscaled: false)
        {
            return img
        }

        guard let img = Image(nsImage: nsImage, data: data, optimised: optimised, retinaDownscaled: false) else {
            throw ClopError.noClipboardImage(item.filePath ?? .init())
        }

        return img
    }

    func optimiseGIF(optimiser: Optimiser, resizeTo newSize: CGSize? = nil, scaleTo scaleFactor: Double? = nil, fromSize: CGSize? = nil, aggressiveOptimisation: Bool? = nil) throws -> Image {
        let tempFile = FilePath.images.appending(path.lastComponent?.string ?? "clop.gif")

        var resizedFile: FilePath? = nil
        var resizeArgs: [String] = []
        var size = newSize ?? .zero
        if let newSize {
            resizeArgs = ["--resize", "\(newSize.width.i)x\(newSize.height.i)"]
        }
        if let scaleFactor {
            resizeArgs = ["--scale", "\(scaleFactor.str(decimals: 2))"]
            size = (fromSize ?? size).scaled(by: scaleFactor)
        }
        if resizeArgs.isNotEmpty {
            resizedFile = FilePath.forResize.appending(path.nameWithoutSize).withSize(size)
            let resizeProc = try tryProc(
                GIFSICLE.string,
                args: ["--unoptimise", "--threads=\(ProcessInfo.processInfo.activeProcessorCount)", "--resize-method=box", "--resize-colors=256"] +
                    resizeArgs +
                    ["--output", resizedFile!.string, path.string],
                tries: 3
            ) { proc in
                mainActor { optimiser.processes = [proc] }
            }
            guard resizeProc.terminationStatus == 0 else {
                throw ClopError.processError(resizeProc)
            }
        }

        let aggressiveOptimisation = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationGIF]
        mainActor { optimiser.aggresive = aggressiveOptimisation }

        let backup = path.backup(operation: .copy)
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
            throw ClopError.processError(proc)
        }

        tempFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimisationStatusXattr("true")
        return Image(data: data, path: tempFile, type: .gif, optimised: true, retinaDownscaled: retinaDownscaled)
    }

    func optimiseJPEG(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, testPNG: Bool = false) throws -> Image {
        var tempFile = FilePath.images.appending(path.lastComponent?.string ?? "clop.jpg")

        let aggressive = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationJPEG]
        mainActor { optimiser.aggresive = aggressive }

        let jpegProc = Proc(cmd: JPEGOPTIM.string, args: [
            "--strip-all", "--force", "--max", aggressive ? "70" : "90",
            "--all-progressive", "--overwrite",
            "--dest", FilePath.images.string, path.string,
        ])
        var procs = [jpegProc]

        var pngOutFile: FilePath?
        if testPNG, let png = try? convert(to: .png) {
            let aggressive = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationPNG]
            pngOutFile = FilePath.images.appending(png.path.name.string)
            if pngOutFile != png.path {
                try? pngOutFile!.delete()
            }
            let pngProc = Proc(cmd: PNGQUANT.string, args: [
                "--strip", "--force",
                "--speed", aggressive ? "1" : "3",
                "--quality", aggressive ? "0-90" : "0-100",
            ] + (pngOutFile == png.path ? ["--ext", ".png"] : ["--output", pngOutFile!.string]) + [png.path.string])

            procs.append(pngProc)
        }

        let backup = path.backup(operation: .copy)
        let procMaps = try tryProcs(procs, tries: 3) { procMap in
            mainActor { optimiser.processes = procMap.values.map { $0 } }
        }

        guard let proc = procMaps[jpegProc] else {
            throw ClopError.noProcess(jpegProc.cmdline)
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        var type = UTType.jpeg
        if let pngOutFile, pngOutFile.exists,
           let pngSize = pngOutFile.fileSize(), pngSize > 0,
           let jpegSize = tempFile.fileSize(),
           jpegSize - pngSize > 100_000
        {
            tempFile = pngOutFile
            type = .png

            if Defaults[.convertedImageBehaviour] != .temporary {
                justTry {
                    try pngOutFile.setOptimisationStatusXattr("true")
                    let newPath = try pngOutFile.copy(to: path.dir)
                    tempFile = newPath
                }
            }
        }

        tempFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
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
            return try img.optimiseJPEG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testPNG: adaptiveSize)
        }

        if data.starts(with: Image.GIF_HEADER) {
            let gif = path.withExtension("gif")
            try path.copy(to: gif, force: true)
            let img = Image(data: data, path: gif, type: .gif, retinaDownscaled: retinaDownscaled)
            return try img.optimiseGIF(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation)
        }

        if let img = Image(data: data, retinaDownscaled: retinaDownscaled), let png = try? img.convert(to: .png) {
            return try png.optimisePNG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testJPEG: adaptiveSize)
        }

        throw ClopError.unknownImageType(path)
    }

    func optimisePNG(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, testJPEG: Bool = false) throws -> Image {
        var tempFile = FilePath.images.appending(path.name.string)
        if tempFile != path {
            try? tempFile.delete()
        }

        let aggressive = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationPNG]
        mainActor { optimiser.aggresive = aggressive }

        let pngProc = Proc(cmd: PNGQUANT.string, args: [
            "--strip", "--force",
            "--speed", aggressive ? "1" : "3",
            "--quality", aggressive ? "0-90" : "0-100",
        ] + (tempFile == path ? ["--ext", ".png"] : ["--output", tempFile.string]) + [path.string])
        var procs = [pngProc]

        var jpegOutFile: FilePath?
        if testJPEG, let jpeg = try? convert(to: .jpeg) {
            let aggressive = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationJPEG]

            let jpegProc = Proc(cmd: JPEGOPTIM.string, args: [
                "--strip-all", "--force", "--max", aggressive ? "70" : "90",
                "--all-progressive", "--overwrite",
                "--dest", FilePath.images.string, jpeg.path.string,
            ])
            procs.append(jpegProc)
            jpegOutFile = FilePath.images.appending(jpeg.path.name.string)
        }

        let procMaps = try tryProcs(procs, tries: 3) { procMap in
            mainActor { optimiser.processes = procMap.values.map { $0 } }
        }

        let backup = path.backup(operation: .copy)
        guard let proc = procMaps[pngProc] else {
            throw ClopError.noProcess(pngProc.cmdline)
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        var type = UTType.png
        if let jpegOutFile, jpegOutFile.exists,
           let jpegSize = jpegOutFile.fileSize(), jpegSize > 0,
           let pngSize = tempFile.fileSize(),
           pngSize - jpegSize > 100_000
        {
            tempFile = jpegOutFile
            type = .jpeg

            if Defaults[.convertedImageBehaviour] != .temporary {
                justTry {
                    try jpegOutFile.setOptimisationStatusXattr("true")
                    let newPath = try jpegOutFile.copy(to: path.dir)
                    tempFile = newPath
                }
            }
        }

        tempFile.copyExif(from: backup ?? path, excludeTags: retinaDownscaled ? ["XResolution", "YResolution"] : nil, stripMetadata: Defaults[.stripMetadata])
        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimisationStatusXattr("true")
        return Image(data: data, path: tempFile, type: type, optimised: true, retinaDownscaled: retinaDownscaled)
    }

    func resize(toFraction fraction: Double, optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        let size = NSSize(width: (size.width * fraction).evenInt, height: (size.height * fraction).evenInt)
        let pathForResize = FilePath.forResize.appending(path.nameWithoutSize)
        try path.copy(to: pathForResize, force: true)

        if type == .gif, let gif = Image(path: pathForResize, retinaDownscaled: retinaDownscaled) {
            return try gif.optimiseGIF(optimiser: optimiser, scaleTo: fraction, fromSize: self.size, aggressiveOptimisation: aggressiveOptimisation)
        }

        let sizeStr = "\(size.width.i)x\(size.height.i)"
        let proc = try tryProc(VIPSTHUMBNAIL.string, args: ["-s", sizeStr, "-o", "%s_\(sizeStr).\(path.extension!)", "--linear", "--smartcrop", "attention", pathForResize.string], tries: 3) { proc in
            mainActor { optimiser.processes = [proc] }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }
        pathForResize.waitForFile(for: 2.0)

        guard let pbImage = Image(path: pathForResize.withSize(size), optimised: false, retinaDownscaled: retinaDownscaled) else {
            throw ClopError.downscaleFailed(pathForResize)
        }
        return try pbImage.optimise(optimiser: optimiser, allowLarger: false, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: adaptiveSize)
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
            img = try optimiseJPEG(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, testPNG: adaptiveSize)
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

    func convert(to type: UTType) throws -> Image {
        guard let ext = type.preferredFilenameExtension else {
            throw ClopError.unknownImageType(path)
        }

        let convPath = FilePath.conversions.appending("\(path.stem!).\(ext)")
        guard let data = image.data(using: type.imgType) else {
            throw ClopError.unknownImageType(path)
        }
        fm.createFile(atPath: convPath.string, contents: data)
        convPath.waitForFile(for: 2)
        guard convPath.exists, let img = Image(path: convPath, retinaDownscaled: retinaDownscaled) else {
            throw ClopError.conversionFailed(path)
        }
        return img
    }

    func copyToClipboard(withPath: Bool? = nil) {
        let item = NSPasteboardItem()
        item.setData(data, forType: type.pasteboardType)
        if withPath ?? Defaults[.copyImageFilePath] {
            item.setString(path.string, forType: .string)
            item.setString(URL(fileURLWithPath: path.string, isDirectory: false).absoluteString, forType: .fileURL)
        }
        item.setString("true", forType: .optimisationStatus)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }
}

@MainActor func optimiseClipboardImage(image: Image? = nil, item: NSPasteboardItem? = nil) {
    guard let img = image ?? (try? Image.fromPasteboard(item: item)) else {
        return
    }
    Task.init { try? await optimiseImage(img, copyToClipboard: true, id: Optimiser.IDs.clipboardImage) }
}

@MainActor func cancelImageOptimisation(path: FilePath) {
    imageOptimiseDebouncers[path.string]?.cancel()
    imageOptimiseDebouncers.removeValue(forKey: path.string)

    opt(path.string)?.stop(animateRemoval: false)
}

@MainActor func shouldHandleImage(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          IMAGE_EXTENSIONS.contains(ext), !Defaults[.imageFormatsToSkip].lazy.compactMap(\.preferredFilenameExtension).contains(ext)
    else {
        return false

    }

    log.debug("\(path.shellString): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.backups.string),
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

@discardableResult
@MainActor func optimiseImage(
    _ img: Image,
    copyToClipboard: Bool = false,
    id: String? = nil,
    debounceMS: Int = 0,
    allowTiff: Bool? = nil,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil
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
        if behaviour == .inPlace {
            img.path.backup(force: true, operation: .move)
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
        let converted = try img.convert(to: conversionFormat)

        img = try applyConversionBehaviour(img, converted)
        pathString = img.path.string
        allowLarger = true
    }

    let optimiser = OM.optimiser(
        id: id ?? pathString, type: .image(img.type),
        operation: "Optimising" + (aggressiveOptimisation ?? false ? " (aggressive)" : ""),
        hidden: hideFloatingResult
    )
    optimiser.downscaleFactor = 1.0
    optimiser.newSize = nil
    optimiser.newBytes = -1
    if let url = originalPath?.url {
        optimiser.convertedFromURL = url
    }

    var done = false
    var result: Image?

    imageOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        scalingFactor = 1.0
        optimiser.stop(remove: false)
        optimiser.operation = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressiveOptimisation ?? false ? " (aggressive)" : "")
        optimiser.thumbnail = img.image
        optimiser.originalURL = img.path.backup(force: false, operation: .copy)?.url ?? img.path.url
        optimiser.url = img.path.url
        if id == Optimiser.IDs.clipboardImage {
            optimiser.startingURL = optimiser.url
        }
        OM.current = optimiser

        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        imageOptimisationQueue.addOperation {
            defer {
                mainActor {
                    imageOptimiseDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }

            let shouldDownscale = Defaults[.downscaleRetinaImages] && img.pixelScale > 1
            var optimisedImage: Image?
            do {
                log.debug("Optimising image \(pathString)")
                if shouldDownscale {
                    img.retinaDownscaled = true
                    mainActor { optimiser.retinaDownscaled = true }
                    optimisedImage = try img.resize(toFraction: (1.0 / img.pixelScale).d, optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: Defaults[.adaptiveImageSize])
                    mainActor { optimiser.downscaleFactor = (1.0 / img.pixelScale).d }
                } else {
                    optimisedImage = try img.optimise(optimiser: optimiser, allowLarger: allowLarger, aggressiveOptimisation: aggressiveOptimisation, adaptiveSize: Defaults[.adaptiveImageSize])
                }
                if optimisedImage!.type == img.type {
                    try optimisedImage!.path.copy(to: img.path, force: true)
                } else {
                    mainActor { optimiser.url = optimisedImage!.path.url }
                }
            } catch let ClopError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error optimising image \(pathString): \(proc.commandLine)")
                    optimiser.finish(error: "Optimisation failed")
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedImage = img
            } catch let error as ClopError {
                log.error("Error optimising image \(pathString): \(error.description)")
                optimiser.finish(error: error.humanDescription)
            } catch {
                log.error("Error optimising image \(pathString): \(error)")
                optimiser.finish(error: "Optimisation failed")
            }

            guard let optimisedImage else { return }
            mainAsync {
                OM.current = optimiser
                optimiser.finish(
                    oldBytes: img.data.count, newBytes: optimisedImage.data.count,
                    oldSize: img.size, newSize: shouldDownscale ? optimisedImage.size : nil,
                    removeAfterMs: id == Optimiser.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
                )
            }

            if copyToClipboard {
                optimisedImage.copyToClipboard()
            }
            mainActor {
                result = optimisedImage
            }
        }
    }

    imageOptimiseDebouncers[pathString] = workItem
    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }
    return result
}

@discardableResult
@MainActor func downscaleImage(
    _ img: Image,
    toFactor factor: Double? = nil,
    saveTo savePath: FilePath? = nil,
    copyToClipboard: Bool = false,
    id: String? = nil,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil
) async throws -> Image? {
    imageResizeDebouncers[img.path.string]?.cancel()
    if let factor {
        scalingFactor = factor
    } else if let currentFactor = opt(id ?? img.path.string)?.downscaleFactor {
        scalingFactor = max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    } else if let current = OM.current, current.id == (id ?? img.path.string) {
        scalingFactor = max(current.downscaleFactor > 0.5 ? current.downscaleFactor - 0.25 : current.downscaleFactor - 0.1, 0.1)
        current.downscaleFactor = scalingFactor
    } else {
        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
    }

    let optimiser = OM.optimiser(id: id ?? img.path.string, type: .image(img.type), operation: "Scaling to \((scalingFactor * 100).intround)%", hidden: hideFloatingResult)
    let aggressive = aggressiveOptimisation ?? optimiser.aggresive
    if aggressive {
        optimiser.operation += " (aggressive)"
    }
    optimiser.remover = nil
    optimiser.inRemoval = false
    optimiser.stop(remove: false)
    optimiser.thumbnail = img.image
    optimiser.downscaleFactor = scalingFactor

    var result: Image?
    var done = false

    let workItem = optimisationQueue.asyncAfter(ms: 500) {
        var resized: Image?
        defer {
            mainActor {
                imageResizeDebouncers[img.path.string]?.cancel()
                imageResizeDebouncers.removeValue(forKey: img.path.string)
                done = true
            }
        }
        mainActor {
            OM.current = optimiser
        }
        do {
            resized = try img.resize(toFraction: scalingFactor, optimiser: optimiser, aggressiveOptimisation: aggressive, adaptiveSize: Defaults[.adaptiveImageSize])

            if id != Optimiser.IDs.clipboardImage, resized!.type == img.type {
                try resized!.path.copy(to: savePath ?? img.path, force: true)
            } else {
                mainActor { optimiser.url = resized!.path.url }
            }
        } catch let ClopError.processError(proc) {
            if proc.terminated {
                log.debug("Process terminated by us: \(proc.commandLine)")
            } else {
                log.error("Error downscaling image \(img.path.string): \(proc.commandLine)")
                mainActor { optimiser.finish(error: "Downscaling failed") }
            }
        } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
            resized = img
        } catch let error as ClopError {
            log.error("Error downscaling image \(img.path.string): \(error.description)")
            mainActor { optimiser.finish(error: error.humanDescription) }
        } catch {
            log.error("Error downscaling image \(img.path.string): \(error)")
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

    imageResizeDebouncers[img.path.string] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }

    return result
}
