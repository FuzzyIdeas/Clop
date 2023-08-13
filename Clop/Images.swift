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

let PNGQUANT = Bundle.main.url(forResource: "pngquant", withExtension: nil)!.path
let JPEGOPTIM = Bundle.main.url(forResource: "jpegoptim", withExtension: nil)!.path
let GIFSICLE = Bundle.main.url(forResource: "gifsicle", withExtension: nil)!.path
let VIPSTHUMBNAIL = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/opt/sw/bin"].map { "\($0)/vipsthumbnail" }.first(where: { fm.fileExists(atPath: $0) })

extension NSPasteboard.PasteboardType {
    static let jpeg = NSPasteboard.PasteboardType(rawValue: "public.jpeg")
    static let gif = NSPasteboard.PasteboardType(rawValue: "com.compuserve.gif")
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
    static var optimizationStatus: NSPasteboard.PasteboardType = .init("clop.optimization.status")
}

// MARK: - Image

class Image: CustomStringConvertible {
    init(data: Data, path: FilePath, type: UTType? = nil, optimized: Bool? = nil) {
        self.path = path
        self.data = data
        image = NSImage(data: data)!
        self.type = type ?? image.type ?? UTType(filenameExtension: path.extension ?? "") ?? UTType(mimeType: path.fetchFileType() ?? "") ?? .png

        if let optimized {
            self.optimized = optimized
        }
    }

    init?(path: FilePath, optimized: Bool? = nil) {
        guard let data = fm.contents(atPath: path.string), let nsImage = NSImage(data: data) else {
            return nil
        }

        let type = nsImage.type ?? UTType(filenameExtension: path.extension ?? "") ?? UTType(mimeType: path.fetchFileType() ?? "") ?? .png
        self.path = path
        self.data = data
        self.type = type
        image = nsImage

        if let optimized {
            self.optimized = optimized
        }
    }

    convenience init?(data: Data) {
        guard let nsImage = NSImage(data: data) else { return nil }
        self.init(nsImage: nsImage)
    }

    init?(nsImage: NSImage, optimized: Bool? = nil) {
        guard let type = nsImage.type, let ext = type.preferredFilenameExtension,
              let data = nsImage.data
        else { return nil }

        image = nsImage
        self.data = data
        let tempPath = fm.temporaryDirectory.appendingPathComponent("\(Int.random(in: 100 ... 100_000)).\(ext)").path
        guard fm.createFile(atPath: tempPath, contents: data) else { return nil }

        path = FilePath(tempPath)
        self.type = type
        self.optimized = optimized ?? false
    }

    static let PNG_HEADER: Data = .init([0x89, 0x50, 0x4E, 0x47])
    static let JPEG_HEADER: Data = .init([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    static let GIF_HEADER: Data = .init([0x47, 0x49, 0x46, 0x38, 0x39])

    static var NOT_IMAGE_TYPE_PATTERN =
        try! Regex(
            "com.microsoft.ole.source|com.microsoft.Art|com.microsoft.PowerPoint|com.microsoft.image-svg-xml|com.microsoft.DataObject|IBPasteboardType|IBDocument|com.pixelmator"
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

    lazy var optimized: Bool = {
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

    var description: String {
        "<Image: \(path) (\(size.s)) [\(optimized ? "" : "NOT ")OPTIMIZED]>"
    }
    var size: NSSize { image.realSize }

    static func isRaw(pasteboardItem: NSPasteboardItem) -> Bool {
        pasteboardItem.types.contains(where: { $0.rawValue.contains("raw-image") })
    }

    class func fromCommandLine() throws -> Image {
        let impath = CommandLine.arguments[1]
        guard fm.fileExists(atPath: impath) else {
            throw ClopError.fileNotFound(FilePath(impath))
        }

        guard let data = fm.contents(atPath: impath), NSImage(data: data) != nil else {
            throw ClopError.fileNotImage(FilePath(impath))
        }
        return Image(data: data, path: FilePath(impath))
    }

    class func fromPasteboard(anyType: Bool = false) throws -> Image {
        let pb = NSPasteboard.general
        guard let item = pb.pasteboardItems?.first else {
            throw ClopError.noClipboardImage(pb.pasteboardItems?.first?.string(forType: .fileURL)?.fileURL.filePath ?? .init())

        }
        let allowImage = try anyType || (
            !NSOrderedSet(array: item.types).intersectsSet(NOT_IMAGE_TYPES) &&
                !isRaw(pasteboardItem: item) &&
                (NOT_IMAGE_TYPE_PATTERN.firstMatch(in: item.types.map(\.rawValue).joined(separator: " "))) == nil

        )
        guard allowImage, let nsImage = NSImage(pasteboard: pb)
        else {
            throw ClopError.noClipboardImage(item.string(forType: .fileURL)?.fileURL.filePath ?? .init())
        }

        if let imgURLString = item.string(forType: .fileURL),
           let imgURL = URL(string: imgURLString), fm.fileExists(atPath: imgURL.path),
           let img = Image(path: FilePath(imgURL.path), optimized: item.string(forType: .optimizationStatus) == "true")
        {
            return img
        }

        guard let img = Image(nsImage: nsImage, optimized: item.string(forType: .optimizationStatus) == "true") else {
            throw ClopError.noClipboardImage(pb.pasteboardItems?.first?.string(forType: .fileURL)?.fileURL.filePath ?? .init())
        }

        return img
    }

    func optimizeGIF(optimizer: Optimizer, resizeTo newSize: CGSize? = nil, scaleTo scaleFactor: Double? = nil, fromSize: CGSize? = nil, aggressiveOptimization: Bool? = nil) throws -> Image {
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
                GIFSICLE,
                args: ["--unoptimize", "--threads=\(ProcessInfo.processInfo.activeProcessorCount)", "--resize-method=box", "--resize-colors=256"] +
                    resizeArgs +
                    ["--output", resizedFile!.string, path.string],
                tries: 3
            ) { proc in
                mainActor { optimizer.processes = [proc] }
            }
            guard resizeProc.terminationStatus == 0 else {
                throw ClopError.processError(resizeProc)
            }
        }

        let aggressiveOptimization = aggressiveOptimization ?? Defaults[.useAggresiveOptimizationGIF]
        mainActor { optimizer.aggresive = aggressiveOptimization }

        let proc = try tryProc(GIFSICLE, args: [
            "--optimize", aggressiveOptimization ? "3" : "2", "--lossy",
            aggressiveOptimization ? "80" : "30",
            "--threads", ProcessInfo.processInfo.activeProcessorCount.s,
            "--output", tempFile.string, (resizedFile ?? path).string,
        ], tries: 3) { proc in
            mainActor { optimizer.processes = [proc] }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }
        path.backup(operation: .copy)

        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimizationStatusXattr("true")
        return Image(data: data, path: tempFile, type: .gif, optimized: true)
    }

    func optimizeJPEG(optimizer: Optimizer, aggressiveOptimization: Bool? = nil, testPNG: Bool = false) throws -> Image {
        var tempFile = FilePath.images.appending(path.lastComponent?.string ?? "clop.jpg")

        let aggressive = aggressiveOptimization ?? Defaults[.useAggresiveOptimizationJPEG]
        mainActor { optimizer.aggresive = aggressive }

        let jpegProc = Proc(cmd: JPEGOPTIM, args: [
            "--strip-all", "--max", aggressive ? "70" : "90",
            "--all-progressive", "--overwrite",
            "--dest", FilePath.images.string, path.string,
        ])
        var procs = [jpegProc]

        var pngOutFile: FilePath?
        if testPNG, let png = try? convert(to: .png) {
            let aggressive = aggressiveOptimization ?? Defaults[.useAggresiveOptimizationPNG]
            pngOutFile = FilePath.images.appending(png.path.name.string)
            if pngOutFile != png.path {
                try? pngOutFile!.delete()
            }
            let pngProc = Proc(cmd: PNGQUANT, args: [
                "--strip", "--force",
                "--speed", aggressive ? "1" : "3",
                "--quality", aggressive ? "0-90" : "0-100",
            ] + (pngOutFile == png.path ? ["--ext", ".png"] : ["--output", pngOutFile!.string]) + [png.path.string])

            procs.append(pngProc)
        }

        let procMaps = try tryProcs(procs, tries: 3) { procMap in
            mainActor { optimizer.processes = procMap.values.map { $0 } }
        }

        guard let proc = procMaps[jpegProc] else {
            throw ClopError.noProcess(jpegProc.cmdline)
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        path.backup(operation: .copy)

        var type = UTType.png
        if let pngOutFile, pngOutFile.exists,
           let pngSize = pngOutFile.fileSize(), pngSize > 0,
           let jpegSize = tempFile.fileSize(),
           jpegSize - pngSize > 100_000
        {
            tempFile = pngOutFile
            type = .png
        }

        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimizationStatusXattr("true")
        return Image(data: data, path: tempFile, type: type, optimized: true)
    }

    func optimizeTIFF(optimizer: Optimizer, aggressiveOptimization: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        guard let data = fm.contents(atPath: path.string) else {
            throw ClopError.fileNotFound(path)
        }

        if data.starts(with: Image.PNG_HEADER) {
            let png = path.withExtension("png")
            try path.copy(to: png, force: true)
            let img = Image(data: data, path: png, type: .png)
            return try img.optimizePNG(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, testJPEG: adaptiveSize)
        }

        if data.starts(with: Image.JPEG_HEADER) {
            let jpeg = path.withExtension("jpeg")
            try path.copy(to: jpeg, force: true)
            let img = Image(data: data, path: jpeg, type: .jpeg)
            return try img.optimizeJPEG(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, testPNG: adaptiveSize)
        }

        if data.starts(with: Image.GIF_HEADER) {
            let gif = path.withExtension("gif")
            try path.copy(to: gif, force: true)
            let img = Image(data: data, path: gif, type: .gif)
            return try img.optimizeGIF(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization)
        }

        if let img = Image(data: data), let png = try? img.convert(to: .png) {
            return try png.optimizePNG(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, testJPEG: adaptiveSize)
        }

        throw ClopError.unknownImageType(path)
    }

    func optimizePNG(optimizer: Optimizer, aggressiveOptimization: Bool? = nil, testJPEG: Bool = false) throws -> Image {
        var tempFile = FilePath.images.appending(path.name.string)
        if tempFile != path {
            try? tempFile.delete()
        }

        let aggressive = aggressiveOptimization ?? Defaults[.useAggresiveOptimizationPNG]
        mainActor { optimizer.aggresive = aggressive }

        let pngProc = Proc(cmd: PNGQUANT, args: [
            "--strip", "--force",
            "--speed", aggressive ? "1" : "3",
            "--quality", aggressive ? "0-90" : "0-100",
        ] + (tempFile == path ? ["--ext", ".png"] : ["--output", tempFile.string]) + [path.string])
        var procs = [pngProc]

        var jpegOutFile: FilePath?
        if testJPEG, let jpeg = try? convert(to: .jpeg) {
            let aggressive = aggressiveOptimization ?? Defaults[.useAggresiveOptimizationJPEG]

            let jpegProc = Proc(cmd: JPEGOPTIM, args: [
                "--strip-all", "--max", aggressive ? "70" : "90",
                "--all-progressive", "--overwrite",
                "--dest", FilePath.images.string, jpeg.path.string,
            ])
            procs.append(jpegProc)
            jpegOutFile = FilePath.images.appending(jpeg.path.name.string)
        }

        let procMaps = try tryProcs(procs, tries: 3) { procMap in
            mainActor { optimizer.processes = procMap.values.map { $0 } }
        }

        guard let proc = procMaps[pngProc] else {
            throw ClopError.noProcess(pngProc.cmdline)
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }
        path.backup(operation: .copy)

        var type = UTType.png
        if let jpegOutFile, jpegOutFile.exists,
           let jpegSize = jpegOutFile.fileSize(), jpegSize > 0,
           let pngSize = tempFile.fileSize(),
           pngSize - jpegSize > 100_000
        {
            tempFile = jpegOutFile
            type = .jpeg
        }

        guard let data = fm.contents(atPath: tempFile.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(tempFile)
        }

        try tempFile.setOptimizationStatusXattr("true")
        return Image(data: data, path: tempFile, type: type, optimized: true)
    }

    func resize(toFraction fraction: Double, optimizer: Optimizer, aggressiveOptimization: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        let size = NSSize(width: (size.width * fraction).evenInt, height: (size.height * fraction).evenInt)
        let pathForResize = FilePath.forResize.appending(path.nameWithoutSize)
        try path.copy(to: pathForResize, force: true)

        if type == .gif, let gif = Image(path: pathForResize) {
            return try gif.optimizeGIF(optimizer: optimizer, scaleTo: fraction, fromSize: self.size, aggressiveOptimization: aggressiveOptimization)
        }

        if let VIPSTHUMBNAIL {
            let sizeStr = "\(size.width.i)x\(size.height.i)"
            let proc = try tryProc(VIPSTHUMBNAIL, args: ["-s", sizeStr, "-o", "%s_\(sizeStr).\(path.extension!)", "--linear", "--smartcrop", "attention", pathForResize.string], tries: 3) { proc in
                mainActor { optimizer.processes = [proc] }
            }
            guard proc.terminationStatus == 0 else {
                throw ClopError.processError(proc)
            }
            pathForResize.waitForFile(for: 2.0)

            guard let pbImage = Image(path: pathForResize.withSize(size), optimized: false) else {
                throw ClopError.downscaleFailed(pathForResize)
            }
            return try pbImage.optimize(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, adaptiveSize: adaptiveSize)
        }

        guard let resized = image.resize(to: size), let data = resized.data(using: type.imgType)
        else {
            throw ClopError.fileNotImage(path)
        }
        let path = pathForResize.withSize(size)
        fm.createFile(atPath: path.string, contents: data)
        let pbImage = Image(data: data, path: path, type: type, optimized: false)

        return try pbImage.optimize(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, adaptiveSize: adaptiveSize)
    }

    func optimize(optimizer: Optimizer, allowLarger: Bool = false, aggressiveOptimization: Bool? = nil, adaptiveSize: Bool = false) throws -> Image {
        guard !optimized else {
            throw ClopError.alreadyOptimized(path)
        }

        let img: Image
        switch type {
        case .png:
            img = try optimizePNG(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, testJPEG: adaptiveSize)
        case .jpeg:
            img = try optimizeJPEG(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, testPNG: adaptiveSize)
        case .gif:
            img = try optimizeGIF(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization)
        case .tiff:
            img = try optimizeTIFF(optimizer: optimizer, aggressiveOptimization: aggressiveOptimization, adaptiveSize: adaptiveSize)
        default:
            throw ClopError.unknownImageType(path)
        }

        guard allowLarger || img.data.count < data.count else {
            let oldBytes = data.count
            mainActor { optimizer.oldBytes = oldBytes }

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
        guard convPath.exists, let img = Image(path: convPath) else {
            throw ClopError.conversionFailed(path)
        }
        return img
    }

    func copyToClipboard() {
        let item = NSPasteboardItem()
        item.setData(data, forType: type.pasteboardType)
        item.setString(URL(fileURLWithPath: path.string, isDirectory: false).absoluteString, forType: .fileURL)
        item.setString("true", forType: .optimizationStatus)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }
}

@MainActor func optimizeClipboardImage(image: Image? = nil) {
    guard let img = image ?? (try? Image.fromPasteboard()) else {
        return
    }
    Task.init { try? await optimizeImage(img, copyToClipboard: true, id: Optimizer.IDs.clipboardImage) }
}

@MainActor func shouldHandleImage(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."), let ext = path.extension?.lowercased(),
          IMAGE_EXTENSIONS.contains(ext), !Defaults[.imageFormatsToSkip].lazy.compactMap(\.preferredFilenameExtension).contains(ext)
    else {
        return false

    }

    print("\(event.path): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.backups.string),
          flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
          !path.hasOptimizationStatusXattr(), let size = path.fileSize(), size > 0, size < Defaults[.maxImageSizeMB] * 1_000_000, imageOptimizeDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            imageOptimizeDebouncers[event.path]?.cancel()
            imageOptimizeDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    return true
}

@discardableResult
@MainActor func optimizeImage(
    _ img: Image,
    copyToClipboard: Bool = false,
    id: String? = nil,
    debounceMS: Int = 0,
    allowTiff: Bool? = nil,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimization: Bool? = nil
) async throws -> Image? {
    let path = img.path
    var img = img
    guard !img.optimized else {
        throw ClopError.alreadyOptimized(path)
    }
    var pathString = path.string

    guard img.type != .tiff || (allowTiff ?? Defaults[.optimizeTIFF]) else {
        print("Skipping image \(pathString) because TIFF optimization is disabled")
        throw ClopError.skippedType("TIFF optimization is disabled")
    }

    if id == Optimizer.IDs.clipboardImage, pauseForNextClipboardEvent {
        print("Skipping image \(pathString) because it was paused")
        pauseForNextClipboardEvent = false
        throw ClopError.optimizationPaused(path)
    }

    var allowLarger = allowLarger

    switch img.type {
    case Defaults[.formatsToConvertToJPEG]:
        let converted = try img.convert(to: .jpeg)
        img = converted
        pathString = img.path.string
        allowLarger = true
    case Defaults[.formatsToConvertToPNG]:
        let converted = try img.convert(to: .png)
        img = converted
        pathString = img.path.string
        allowLarger = true
    default:
        break
    }

    let optimizer = OM.optimizer(
        id: id ?? pathString, type: .image(img.type),
        operation: "Optimizing" + (aggressiveOptimization ?? false ? " (aggressive)" : ""),
        hidden: hideFloatingResult
    )

    var done = false
    var result: Image?

    imageOptimizeDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        scalingFactor = 1.0
        optimizer.stop(remove: false)
        optimizer.operation = (Defaults[.showImages] ? "Optimizing" : "Optimizing \(optimizer.filename)") + (aggressiveOptimization ?? false ? " (aggressive)" : "")
        optimizer.thumbnail = img.image
        optimizer.originalURL = img.path.backup(force: false, operation: .copy)?.url ?? img.path.url
        optimizer.url = img.path.url
        OM.current = optimizer

        OM.optimizers = OM.optimizers.without(optimizer).with(optimizer)
        showFloatingThumbnails()

        imageOptimizationQueue.addOperation {
            defer {
                mainActor {
                    imageOptimizeDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }

            var optimizedImage: Image?
            do {
                print("Optimizing image \(pathString)")
                optimizedImage = try img.optimize(optimizer: optimizer, allowLarger: allowLarger, aggressiveOptimization: aggressiveOptimization, adaptiveSize: id == Optimizer.IDs.clipboardImage)
                if optimizedImage!.type == img.type {
                    try optimizedImage!.path.copy(to: img.path, force: true)
                } else {
                    mainActor { optimizer.url = optimizedImage!.path.url }
                }
            } catch let ClopError.processError(proc) {
                if proc.terminated {
                    debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    err("Error optimizing image \(pathString): \(proc.commandLine)")
                    optimizer.finish(error: "Optimization failed")
                }
            } catch let error as ClopError {
                err("Error optimizing image \(pathString): \(error.description)")
                optimizer.finish(error: error.humanDescription)
            } catch {
                err("Error optimizing image \(pathString): \(error)")
                optimizer.finish(error: "Optimization failed")
            }

            guard let optimizedImage else { return }
            mainAsync {
                OM.current = optimizer
                optimizer.finish(
                    oldBytes: img.data.count, newBytes: optimizedImage.data.count,
                    oldSize: img.size,
                    removeAfterMs: id == Optimizer.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
                )
            }

            if copyToClipboard {
                optimizedImage.copyToClipboard()
            }
            mainActor {
                result = optimizedImage
            }
        }
    }

    imageOptimizeDebouncers[pathString] = workItem
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
    aggressiveOptimization: Bool? = nil
) async throws -> Image? {
    imageResizeDebouncers[img.path.string]?.cancel()
    if let factor {
        scalingFactor = factor
    } else if let currentFactor = opt(id ?? img.path.string)?.downscaleFactor {
        scalingFactor = max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    } else {
        scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
    }

    let optimizer = OM.optimizer(id: id ?? img.path.string, type: .image(img.type), operation: "Scaling to \((scalingFactor * 100).intround)%", hidden: hideFloatingResult)
    let aggressive = aggressiveOptimization ?? optimizer.aggresive
    if aggressive {
        optimizer.operation += " (aggressive)"
    }
    optimizer.remover = nil
    optimizer.inRemoval = false
    optimizer.stop(remove: false)
    optimizer.thumbnail = img.image
    optimizer.downscaleFactor = scalingFactor

    var result: Image?
    var done = false

    let workItem = optimizationQueue.asyncAfter(ms: 500) {
        defer {
            mainActor {
                imageResizeDebouncers[img.path.string]?.cancel()
                imageResizeDebouncers.removeValue(forKey: img.path.string)
                done = true
            }
        }
        do {
            let resized = try img.resize(toFraction: scalingFactor, optimizer: optimizer, aggressiveOptimization: aggressive, adaptiveSize: id == Optimizer.IDs.clipboardImage)
            if id != Optimizer.IDs.clipboardImage, resized.type == img.type {
                try resized.path.copy(to: savePath ?? img.path, force: true)
            } else {
                mainActor { optimizer.url = resized.path.url }
            }

            mainActor {
                optimizer.finish(
                    oldBytes: img.data.count, newBytes: resized.data.count,
                    oldSize: img.size, newSize: resized.size,
                    removeAfterMs: id == Optimizer.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
                )
                if copyToClipboard {
                    resized.copyToClipboard()
                }
                result = resized
            }
        } catch let ClopError.processError(proc) {
            if proc.terminated {
                debug("Process terminated by us: \(proc.commandLine)")
            } else {
                err("Error downscaling image \(img.path.string): \(proc.commandLine)")
                mainActor { optimizer.finish(error: "Downscaling failed") }
            }
        } catch let error as ClopError {
            err("Error downscaling image \(img.path.string): \(error.description)")
            mainActor { optimizer.finish(error: error.humanDescription) }
        } catch {
            err("Error downscaling image \(img.path.string): \(error)")
            mainActor { optimizer.finish(error: "Optimization failed") }
        }
    }

    imageResizeDebouncers[img.path.string] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }

    return result
}
