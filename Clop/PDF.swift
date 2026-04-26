import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import PDFKit
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "PDF")

var GS = BIN_DIR.appendingPathComponent("gs").filePath!

// DPI = 300 means no downsampling; below that we let Ghostscript downsample.
let PDF_DPI_NO_DOWNSAMPLE = 300
let PDF_DPI_MIN = 48
let PDF_DPI_MAX = 300
// Snap points used by the DPI slider, ordered high to low.
let PDF_DPI_STOPS: [Int] = [300, 250, 200, 150, 100, 72, 48]

func gsLossyArgs(downsample: Bool) -> [String] {
    [
        "-dAutoFilterColorImages=false",
        "-dAutoFilterGrayImages=false",
        "-dAutoFilterMonoImages=true",
        "-dColorImageFilter=/DCTEncode",
        "-dDownsampleColorImages=\(downsample)",
        "-dDownsampleGrayImages=\(downsample)",
        "-dDownsampleMonoImages=\(downsample)",
        "-dGrayImageFilter=/DCTEncode",
        "-dPassThroughJPEGImages=false",
        "-dPassThroughJPXImages=false",
        "-dShowAcroForm=false",
    ]
}

func gsLosslessArgs(downsample: Bool) -> [String] {
    [
        "-dAutoFilterColorImages=false",
        "-dAutoFilterGrayImages=false",
        "-dAutoFilterMonoImages=false",
        "-dColorImageFilter=/DCTEncode",
        "-dDownsampleColorImages=\(downsample)",
        "-dDownsampleGrayImages=\(downsample)",
        "-dDownsampleMonoImages=\(downsample)",
        "-dGrayImageFilter=/DCTEncode",
        // PassThrough only works when not downsampling — preserves originals byte-for-byte.
        "-dPassThroughJPEGImages=\(!downsample)",
        "-dPassThroughJPXImages=\(!downsample)",
        "-dShowAcroForm=true",
    ]
}

func gsResolutionArgs(dpi: Int) -> [String] {
    [
        "-dColorImageDownsampleThreshold=1.0",
        "-dColorImageDownsampleType=/Bicubic",
        "-dColorImageResolution=\(dpi)",
        "-dGrayImageDownsampleThreshold=1.0",
        "-dGrayImageDownsampleType=/Bicubic",
        "-dGrayImageResolution=\(dpi)",
        "-dMonoImageDownsampleThreshold=1.0",
        "-dMonoImageDownsampleType=/Bicubic",
        // Mono (1-bit) images compress poorly below 300 dpi; clamp.
        "-dMonoImageResolution=\(max(dpi, 300))",
    ]
}

let GS_BASE_ARGS: [String] = [
    "-dALLOWPSTRANSPARENCY",
    "-dAutoRotatePages=/None",
    "-dBATCH",
    "-dCannotEmbedFontPolicy=/Warning",
    "-dColorConversionStrategy=/sRGB",
    "-dCompatibilityLevel=1.6",
    "-dCompressFonts=true",
    "-dCompressPages=true",
    "-dCompressStreams=true",
    "-dConvertCMYKImagesToRGB=true",
    "-dConvertImagesToIndexed=false",
    "-dCreateJobTicket=false",
    "-dDetectDuplicateImages=true",
    "-dDoThumbnails=false",
    "-dEmbedAllFonts=true",
    "-dEncodeColorImages=true",
    "-dEncodeGrayImages=true",
    "-dEncodeMonoImages=true",
    "-dFastWebView=false",
    "-dGrayDetection=true",
    "-dHaveTransparency=true",
    "-dLZWEncodePages=true",
    "-dMaxBitmap=0",
    "-dMonoImageFilter=/CCITTFaxEncode",
    "-dNOPAUSE",
    "-dNOPROMPT",
    "-dOptimize=true",
    "-dParseDSCComments=false",
    "-dParseDSCCommentsForDocInfo=false",
    "-dPDFNOCIDFALLBACK",
    "-dPDFSETTINGS=/screen",
    "-dPreserveAnnots=true",
    "-dPreserveCopyPage=false",
    "-dPreserveDeviceN=true",
    "-dPreserveEPSInfo=false",
    "-dPreserveHalftoneInfo=false",
    "-dPreserveOPIComments=false",
    "-dPreserveOverprintSettings=true",
    "-dPreserveSeparation=true",
    "-dPrinted=false",
    "-dProcessColorModel=/DeviceRGB",
    "-dSAFER",
    "-dSubsetFonts=true",
    "-dTransferFunctionInfo=/Apply",
    "-dUCRandBGInfo=/Remove",
]

let GS_PRE_ARGS: [String] = [
    "-c",
    "<< /ColorImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /ColorACSImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /GrayImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /GrayACSImageDict << /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /AlwaysEmbed [ ] >> setdistillerparams << /NeverEmbed [/Courier /Courier-Bold /Courier-Oblique /Courier-BoldOblique /Helvetica /Helvetica-Bold /Helvetica-Oblique /Helvetica-BoldOblique /Times-Roman /Times-Bold /Times-Italic /Times-BoldItalic /Symbol /ZapfDingbats /Arial] >> setdistillerparams",
    "-f",
    "-c",
    "/originalpdfmark { //pdfmark } bind def /pdfmark { { { counttomark pop } stopped { /pdfmark errordict /unmatchedmark get exec stop } if dup type /nametype ne { /pdfmark errordict /typecheck get exec stop } if dup /DOCINFO eq { (Skipping DOCINFO pdfmark\n) print cleartomark exit } if originalpdfmark exit } loop } def",
    "-f",
]
let GS_POST_ARGS: [String] = [
    "-c", "/pdfmark { originalpdfmark } bind def", "-f",
    "-c", "[ /Producer () /ModDate () /CreationDate () /DOCINFO pdfmark", "-f",
]

func gsArgs(_ input: String, _ output: String, lossy: Bool, dpi: Int) -> [String] {
    let clampedDPI = min(max(dpi, PDF_DPI_MIN), PDF_DPI_MAX)
    let downsample = clampedDPI < PDF_DPI_NO_DOWNSAMPLE
    let optArgs: [String] = lossy ? gsLossyArgs(downsample: downsample) : gsLosslessArgs(downsample: downsample)
    let resArgs: [String] = gsResolutionArgs(dpi: clampedDPI)
    let outArgs: [String] = ["-sDEVICE=pdfwrite", "-sFONTPATH=\(FONT_PATH)", "-o", output]
    return GS_BASE_ARGS + resArgs + optArgs + outArgs + GS_PRE_ARGS + [input] + GS_POST_ARGS
}

let FONT_PATH: String = [
    "\(NSHomeDirectory())/Library/Fonts",
    "/Library/Fonts/",
    "/System/Library/Fonts/",
    "/Library/Fonts/Microsoft/",
    "/Library/Application Support/Adobe/Fonts/",
].filter { FileManager.default.fileExists(atPath: $0) }.joined(separator: ":")

let GS_PAGE_REGEX = try! Regex(#"^\s*Processing pages \d+ through (\d+)."#, as: (Substring, Substring).self).anchorsMatchLineEndings(true)

func isPDFValid(path: FilePath) -> Bool {
    guard let document = PDFDocument(url: path.url) else {
        return false
    }
    return document.pageCount > 0
}

@MainActor func updateProgressGS(pipe: Pipe, url: URL, optimiser: Optimiser, pageCount: Int? = nil) {
    mainActor {
        optimiser.progress = Progress(totalUnitCount: pageCount?.i64 ?? 100)
        optimiser.progress.fileURL = url
        optimiser.progress.localizedDescription = optimiser.operation
        optimiser.progress.localizedAdditionalDescription = "Calculating progress"
        optimiser.progress.publish()
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            mainActor { optimiser.progress.unpublish() }
            return
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return
        }

        // match `Processing pages 1 through 247.`
        if pageCount == nil, let match = try? GS_PAGE_REGEX.firstMatch(in: string) {
            mainActor {
                optimiser.progress.totalUnitCount = Int64(match.1)!
            }
        }

        let lines = string.components(separatedBy: .newlines)
        for line in lines where line.starts(with: "Page ") {
            guard let currentPage = Int64(line.suffix(line.count - 5)), currentPage > 0 else {
                continue
            }
            mainActor {
                optimiser.progress.completedUnitCount = min(currentPage, optimiser.progress.totalUnitCount)
                optimiser.progress.localizedAdditionalDescription = "Page \(currentPage) of \(optimiser.progress.totalUnitCount)"
            }
        }
    }
}

class PDF: Optimisable {
    override class var dir: FilePath { .pdfs }

    lazy var document: PDFDocument? = PDFDocument(url: path.url)
    lazy var size: NSSize? = document?.page(at: 1)?.bounds(for: .cropBox).size
    lazy var originalSize: NSSize? = document?.page(at: 1)?.bounds(for: .mediaBox).size

    var pageCount: Int { document?.pageCount ?? 0 }

    @discardableResult
    func uncrop(saveTo newPath: FilePath? = nil) -> Bool {
        guard let document, !document.isEncrypted else {
            return false
        }
        document.uncrop()
        return document.write(to: newPath?.url ?? path.url)
    }

    @discardableResult
    func cropTo(aspectRatio: Double, alwaysPortrait: Bool = false, alwaysLandscape: Bool = false, saveTo newPath: FilePath? = nil) -> Bool {
        guard let document, !document.isEncrypted else {
            return false
        }

        document.cropTo(aspectRatio: aspectRatio, alwaysPortrait: alwaysPortrait, alwaysLandscape: alwaysLandscape)
        return document.write(to: newPath?.url ?? path.url)
    }

    func optimise(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, dpi: Int? = nil) throws -> PDF {
        guard let document else {
            throw ClopError.invalidPDF(path)
        }
        guard !document.isEncrypted else {
            throw ClopError.encryptedPDF(path)
        }

        try? path.setOptimisationStatusXattr("pending")
        let tempFile = FilePath.pdfs.appending(path.lastComponent?.string ?? "clop.pdf")

        let aggressiveOptimisation = aggressiveOptimisation ?? Defaults[.useAggressiveOptimisationPDF]
        mainActor { optimiser.aggressive = aggressiveOptimisation }

        let effectiveDPI = dpi ?? Defaults[aggressiveOptimisation ? .pdfDPIAggressive : .pdfDPI]
        let args = gsArgs(path.string, tempFile.string, lossy: aggressiveOptimisation, dpi: effectiveDPI)
        let proc = try tryProc(GS.string, args: args, tries: 3, captureOutput: true, env: GHOSTSCRIPT_ENV) { proc in
            mainActor { [weak self] in
                guard let self else { return }
                optimiser.processes = [proc]
                updateProgressGS(pipe: proc.standardOutput as! Pipe, url: path.url, optimiser: optimiser, pageCount: document.pageCount)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopProcError.processError(proc)
        }
        path.backup(path: path.clopBackupPath, operation: .copy)

        tempFile.waitForFile(for: 2)
        try? tempFile.setOptimisationStatusXattr("true")
        if tempFile != path {
            if Defaults[.preserveDates] {
                tempFile.copyCreationModificationDates(from: path)
            }
            try tempFile.copy(to: path, force: true)
        }

        return PDF(path)
    }

    func renderPage(pageIndex: Int, format: NSBitmapImageRep.FileType = .jpeg, scale: CGFloat = 2.0) -> Data? {
        guard let page = document?.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let scaledSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let image = NSImage(size: scaledSize)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        if format == .jpeg {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: scaledSize))
        }
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }

        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg ? [.compressionFactor: 0.9] : [:]
        return bitmap.representation(using: format, properties: properties)
    }
}

@MainActor func cancelPDFOptimisation(path: FilePath) {
    pdfOptimiseDebouncers[path.string]?.cancel()
    pdfOptimiseDebouncers.removeValue(forKey: path.string)

    guard let optimiser = opt(path.string) else {
        return
    }
    optimiser.stop(animateRemoval: false)
    optimiser.remove(after: 0, withAnimation: false)
}

@MainActor func shouldHandlePDF(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."),
          let ext = path.extension?.lowercased(), ext == "pdf"
    else {
        return false

    }

    log.debug("\(path.shellString): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.clopBackups.string),
          flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
          !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0, size < Defaults[.maxPDFSizeMB] * 1_000_000, pdfOptimiseDebouncers[event.path] == nil
    else {
        if flag.contains(.itemRemoved) || !fm.fileExists(atPath: event.path) {
            pdfOptimiseDebouncers[event.path]?.cancel()
            pdfOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }
    return true
}

let GHOSTSCRIPT_ENV = ["GS_LIB": BIN_DIR.appending(path: "share/ghostscript/10.06.0/Resource/Init").path]
