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
        // PassThrough only works when not downsampling; preserves originals byte-for-byte.
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
    // /RGB (DeviceRGB), NOT /sRGB: Ghostscript's ICC/sRGB conversion silently drops
    // isolated transparency-group form XObjects (e.g. Bear callout icons). See the
    // trailing override in gsArgs() which re-applies this after /screen wins.
    "-dColorConversionStrategy=/RGB",
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
    // /Preserve, NOT /Apply: /Apply bakes transfer functions into content, but Ghostscript's
    // pdfwrite mis-applies a /TR on an /Alpha soft mask (e.g. Canva QR codes), driving the mask
    // fully transparent and erasing the masked image. /Preserve (also the gs default) keeps the
    // /TR in the output for the renderer to apply, so the QR survives. See the QR-erasure repro.
    "-dTransferFunctionInfo=/Preserve",
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
    // At the lowest DPI stops, also re-encode embedded images at lower JPEG quality with chroma
    // subsampling (QFactor is inverse: higher = smaller/worse; gs defaults to ~medium quality).
    let qFactorArgs: [String]
    if lossy, clampedDPI <= 100 {
        let qFactor = clampedDPI <= 48 ? 1.3 : (clampedDPI <= 72 ? 1.0 : 0.76)
        let imageDict = "<< /QFactor \(qFactor) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >>"
        qFactorArgs = ["-c", "<< /ColorImageDict \(imageDict) /GrayImageDict \(imageDict) >> setdistillerparams", "-f"]
    } else {
        qFactorArgs = []
    }
    // -dColorConversionStrategy must come AFTER -dPDFSETTINGS=/screen (which re-forces an
    // sRGB conversion) so DeviceRGB wins; otherwise transparency-group icons get flattened away.
    let outArgs: [String] = ["-dColorConversionStrategy=/RGB", "-sDEVICE=pdfwrite", "-sFONTPATH=\(FONT_PATH)", "-o", output]
    return GS_BASE_ARGS + resArgs + optArgs + outArgs + qFactorArgs + GS_PRE_ARGS + [input] + GS_POST_ARGS
}

private struct PDFImageDimensions {
    let widthPx: Int
    let heightPx: Int
    let pageWidthIn: Double
    let pageHeightIn: Double

    var dpi: Double {
        let wDPI = Double(widthPx) / pageWidthIn
        let hDPI = Double(heightPx) / pageHeightIn
        return (wDPI + hDPI) / 2
    }
}

private final class PDFImageDimensionsCollector {
    var images: [PDFImageDimensions] = []
    var pageWidthIn: Double = 0
    var pageHeightIn: Double = 0
}

private func collectPDFImageDimensions(at path: FilePath) -> [PDFImageDimensions] {
    guard let doc = CGPDFDocument(path.url as CFURL), doc.numberOfPages > 0 else { return [] }

    let collector = PDFImageDimensionsCollector()
    for pageNum in 1 ... doc.numberOfPages {
        guard let page = doc.page(at: pageNum) else { continue }
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { continue }
        collector.pageWidthIn = Double(mediaBox.width) / 72.0
        collector.pageHeightIn = Double(mediaBox.height) / 72.0

        guard let pageDict = page.dictionary else { continue }
        var resourcesDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesDict),
              let resourcesDict
        else { continue }

        var xobjectDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resourcesDict, "XObject", &xobjectDict),
              let xobjectDict
        else { continue }

        CGPDFDictionaryApplyBlock(xobjectDict, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream),
                  let stream,
                  let streamDict = CGPDFStreamGetDictionary(stream)
            else { return true }

            var subtypeName: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtypeName),
                  let subtypeName,
                  String(cString: subtypeName) == "Image"
            else { return true }

            var widthInt: CGPDFInteger = 0
            var heightInt: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(streamDict, "Width", &widthInt),
                  CGPDFDictionaryGetInteger(streamDict, "Height", &heightInt)
            else { return true }

            collector.images.append(PDFImageDimensions(
                widthPx: Int(widthInt),
                heightPx: Int(heightInt),
                pageWidthIn: collector.pageWidthIn,
                pageHeightIn: collector.pageHeightIn
            ))
            return true
        }, nil)
    }

    return collector.images
}

/// Lower Tukey fence that drops abnormally low DPI values that come from small
/// partial-page images mis-counted as low-DPI by the full-page heuristic.
private func dropLowDPIOutliers(_ values: [Double]) -> [Double] {
    guard values.count >= 4 else { return values }
    let sorted = values.sorted()
    func percentile(_ p: Double) -> Double {
        let idx = max(0, min(Double(sorted.count - 1), Double(sorted.count - 1) * p))
        let lo = Int(idx.rounded(.down))
        let hi = Int(idx.rounded(.up))
        let frac = idx - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
    let q1 = percentile(0.25)
    let q3 = percentile(0.75)
    let lo = q1 - 1.5 * (q3 - q1)
    return values.filter { $0 >= lo }
}

private let MIN_IMAGES_AT_DPI_STOP = 3

struct PDFDPIAnalysis {
    let chosen: Int
    let maxSourceDPI: Int?
}

/// Scan a PDF for image XObjects and return the highest filtered DPI, or nil
/// when the PDF has no countable images. Used to populate the source DPI label
/// when the user has chosen a fixed aggressive DPI (no adaptive choice needed).
func scanPDFMaxImageDPI(at path: FilePath) -> Int? {
    let images = collectPDFImageDimensions(at: path)
    guard !images.isEmpty else { return nil }
    let dpis = dropLowDPIOutliers(images.map(\.dpi))
    guard !dpis.isEmpty else { return nil }
    return Int((dpis.max() ?? 0).rounded())
}

/// Pick the highest stop ≤ `cap` where the cumulative count of images at-or-above
/// that stop exceeds `MIN_IMAGES_AT_DPI_STOP`. Returns `cap` when the PDF has no
/// images or no stop qualifies; preserves the existing user setting in those cases.
/// Also reports the max image DPI in the source (after low-outlier filtering).
func analyseAggressivePDFDPI(at path: FilePath, cap: Int) -> PDFDPIAnalysis {
    let images = collectPDFImageDimensions(at: path)
    guard !images.isEmpty else { return PDFDPIAnalysis(chosen: cap, maxSourceDPI: nil) }

    let dpis = dropLowDPIOutliers(images.map(\.dpi))
    guard !dpis.isEmpty else { return PDFDPIAnalysis(chosen: cap, maxSourceDPI: nil) }

    let maxSourceDPI = Int((dpis.max() ?? 0).rounded())
    let stops = PDF_DPI_STOPS.filter { $0 <= cap }
    var freq: [Int: Int] = [:]
    for dpi in dpis {
        guard let bucket = stops.first(where: { Double($0) <= dpi }) else { continue }
        freq[bucket, default: 0] += 1
    }

    var imagesAtOrAboveStop = 0
    for stop in stops {
        imagesAtOrAboveStop += freq[stop] ?? 0
        if imagesAtOrAboveStop > MIN_IMAGES_AT_DPI_STOP {
            return PDFDPIAnalysis(chosen: stop, maxSourceDPI: maxSourceDPI)
        }
    }
    return PDFDPIAnalysis(chosen: cap, maxSourceDPI: maxSourceDPI)
}

/// The next stop below `dpi`; stays at the lowest stop once reached.
func nextPDFDPIStepDown(from dpi: Int) -> Int {
    PDF_DPI_STOPS.first(where: { $0 < dpi }) ?? PDF_DPI_STOPS.last ?? dpi
}

/// Resolves the DPI a gs pass should render at. An explicit `dpi` override
/// (DPI stepper, CLI, Shortcuts) is used verbatim, otherwise the stored setting
/// decides: the adaptive analysis or a fixed stop. Aggressive has no DPI setting
/// of its own: it goes one stop below the resolved setting, so an aggressive
/// pass always produces a smaller file than a normal pass over the same input.
func resolvePDFDPI(at inputPath: FilePath, dpi: Int?, aggressive: Bool) -> PDFDPIAnalysis {
    let resolvedSetting = dpi ?? Defaults[.pdfDPI]

    var effectiveDPI: Int
    var sourceMaxDPI: Int?
    if resolvedSetting == PDF_DPI_ADAPTIVE {
        let analysis = analyseAggressivePDFDPI(at: inputPath, cap: PDF_DPI_NO_DOWNSAMPLE)
        effectiveDPI = analysis.chosen
        sourceMaxDPI = analysis.maxSourceDPI
        if let sourceMax = analysis.maxSourceDPI {
            log.debug("Adaptive PDF DPI for \(inputPath.string): chose \(analysis.chosen) (source max \(sourceMax))")
        }
    } else {
        effectiveDPI = resolvedSetting
    }
    if aggressive, dpi == nil {
        effectiveDPI = nextPDFDPIStepDown(from: effectiveDPI)
    }
    if resolvedSetting != PDF_DPI_ADAPTIVE, dpi != nil || effectiveDPI < PDF_DPI_NO_DOWNSAMPLE {
        sourceMaxDPI = scanPDFMaxImageDPI(at: inputPath)
    }
    return PDFDPIAnalysis(chosen: effectiveDPI, maxSourceDPI: sourceMaxDPI)
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
        optimiser.publishProgress()
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            mainActor { optimiser.unpublishProgress() }
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
    override class var dir: FilePath {
        .pdfs
    }

    lazy var document: PDFDocument? = PDFDocument(url: path.url)
    lazy var size: NSSize? = document?.page(at: 1)?.bounds(for: .cropBox).size
    lazy var originalSize: NSSize? = document?.page(at: 1)?.bounds(for: .mediaBox).size

    var pageCount: Int {
        document?.pageCount ?? 0
    }

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

    @discardableResult
    func cropTo(rect: CropRect, saveTo newPath: FilePath? = nil) -> Bool {
        guard let document, !document.isEncrypted else {
            return false
        }

        document.cropTo(rect: rect)
        return document.write(to: newPath?.url ?? path.url)
    }

    @discardableResult
    func extendTo(aspectRatio: Double, alwaysPortrait: Bool = false, alwaysLandscape: Bool = false, rect: CropRect? = nil, saveTo newPath: FilePath? = nil) -> Bool {
        guard let document, !document.isEncrypted else {
            return false
        }

        document.extendTo(aspectRatio: aspectRatio, alwaysPortrait: alwaysPortrait, alwaysLandscape: alwaysLandscape, rect: rect)
        return document.write(to: newPath?.url ?? path.url)
    }

    func optimise(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, dpi: Int? = nil) throws -> PDF {
        guard let document else {
            throw ClopError.invalidPDF(path)
        }
        guard !document.isEncrypted else {
            throw ClopError.encryptedPDF(path)
        }

        if document.pageCount > PARALLEL_PDF_PAGE_THRESHOLD {
            return try optimiseInParallel(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, dpi: dpi)
        }

        try? path.setOptimisationStatusXattr("pending")
        let tempFile = FilePath.pdfs.appending(path.lastComponent?.string ?? "clop.pdf")

        let aggressiveOptimisation = aggressiveOptimisation ?? false
        mainActor { optimiser.aggressive = aggressiveOptimisation }

        // Always run gs from the original (backed up on first optimisation) so
        // re-optimisations don't double-encode and the user can step the DPI
        // back up after stepping it down.
        let backupPath = path.clopBackupPath
        if let bp = backupPath, !bp.exists {
            path.backup(path: bp, operation: .copy)
        }
        let inputPath: FilePath = (backupPath?.exists ?? false) ? backupPath! : path

        let resolved = resolvePDFDPI(at: inputPath, dpi: dpi, aggressive: aggressiveOptimisation)
        let effectiveDPI = resolved.chosen
        let sourceMaxDPI = resolved.maxSourceDPI

        if let sourceMaxDPI {
            mainActor {
                if optimiser.oldDPI == nil {
                    optimiser.oldDPI = sourceMaxDPI
                }
                let baseDPI = optimiser.oldDPI ?? sourceMaxDPI
                optimiser.newDPI = min(baseDPI, effectiveDPI)
            }
        }
        // Recompress images (lossy) only when we're actually downsampling below full DPI.
        let args = gsArgs(inputPath.string, tempFile.string, lossy: effectiveDPI < PDF_DPI_NO_DOWNSAMPLE, dpi: effectiveDPI)
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

@MainActor func shouldHandlePDF(event: EonilFSEventsEvent) async -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."),
          let ext = path.extension?.lowercased(), ext == "pdf"
    else {
        return false

    }

    log.debug("\(path.shellString): \(flag)")

    // Run the blocking filesystem checks (xattr read, size stat) off the main actor; the FSEvents
    // callback is on the main thread, so doing them here would hang the UI on a burst of events or a
    // slow/network volume (ANR). The debouncer bookkeeping stays on the main actor below.
    let eventPath = event.path
    let io = await Task.detached { () -> (passes: Bool, exists: Bool) in
        let exists = fm.fileExists(atPath: eventPath)
        guard exists, !eventPath.contains(FilePath.clopBackups.string),
              flag.isDisjoint(with: [.historyDone, .itemRemoved]), flag.contains(.itemIsFile), flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified]),
              !path.hasOptimisationStatusXattr(), let size = path.fileSize(), size > 0,
              Defaults[.maxPDFSizeMB] == 0 || size < Defaults[.maxPDFSizeMB] * 1_000_000,
              Defaults[.minPDFSizeKB] == 0 || size >= Defaults[.minPDFSizeKB] * 1000
        else {
            return (false, exists)
        }
        return (true, exists)
    }.value

    guard io.passes else {
        if flag.contains(.itemRemoved) || !io.exists {
            pdfOptimiseDebouncers[event.path]?.cancel()
            pdfOptimiseDebouncers.removeValue(forKey: event.path)
        }
        return false
    }

    guard pdfOptimiseDebouncers[event.path] == nil else { return false }
    return true
}

/// gs is now a static build with all resources (fonts, ICC profiles, init files)
/// embedded via its %rom% filesystem, so it needs neither GS_LIB nor the on-disk
/// share/ghostscript Resource tree.
let GHOSTSCRIPT_ENV: [String: String] = [:]

// MARK: - Parallel PDF optimisation

private let PARALLEL_PDF_PAGE_THRESHOLD = 150
private let PARALLEL_PDF_CHUNK_SIZE = 100
private let PARALLEL_PDF_CONCURRENCY = 4

private final class ParallelGSProgress: @unchecked Sendable {
    init(optimiser: Optimiser, totalPages: Int) {
        self.optimiser = optimiser
        self.totalPages = totalPages
    }

    weak var optimiser: Optimiser?
    let totalPages: Int

    func increment(by n: Int) {
        lock.lock()
        completed += n
        let current = completed
        lock.unlock()
        let total = totalPages
        mainActor { [weak self] in
            guard let opt = self?.optimiser else { return }
            opt.progress.completedUnitCount = min(Int64(current), Int64(total))
            opt.progress.localizedAdditionalDescription = "Page \(current) of \(total)"
        }
    }

    private let lock = NSLock()
    private var completed = 0

}

extension PDF {
    func optimiseInParallel(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil, dpi: Int? = nil) throws -> PDF {
        guard let document else {
            throw ClopError.invalidPDF(path)
        }
        guard !document.isEncrypted else {
            throw ClopError.encryptedPDF(path)
        }

        try? path.setOptimisationStatusXattr("pending")
        let tempFile = FilePath.pdfs.appending(path.lastComponent?.string ?? "clop.pdf")

        let aggressive = aggressiveOptimisation ?? false
        mainActor { optimiser.aggressive = aggressive }

        let backupPath = path.clopBackupPath
        if let bp = backupPath, !bp.exists {
            path.backup(path: bp, operation: .copy)
        }
        let inputPath: FilePath = (backupPath?.exists ?? false) ? backupPath! : path

        let resolved = resolvePDFDPI(at: inputPath, dpi: dpi, aggressive: aggressive)
        let effectiveDPI = resolved.chosen
        let sourceMaxDPI = resolved.maxSourceDPI

        if let sourceMaxDPI {
            mainActor {
                if optimiser.oldDPI == nil {
                    optimiser.oldDPI = sourceMaxDPI
                }
                let baseDPI = optimiser.oldDPI ?? sourceMaxDPI
                optimiser.newDPI = min(baseDPI, effectiveDPI)
            }
        }

        let totalPages = document.pageCount
        let chunkDir = FilePath.pdfs.appending("parallel-\(UUID().uuidString)")
        try? fm.createDirectory(at: chunkDir.url, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: chunkDir.url) }

        var chunks: [(first: Int, last: Int, output: FilePath)] = []
        var pageStart = 1
        var idx = 0
        while pageStart <= totalPages {
            let pageEnd = min(pageStart + PARALLEL_PDF_CHUNK_SIZE - 1, totalPages)
            let outPath = chunkDir.appending("chunk-\(idx).pdf")
            chunks.append((pageStart, pageEnd, outPath))
            pageStart = pageEnd + 1
            idx += 1
        }

        log.debug("Parallel PDF optimisation: \(totalPages) pages → \(chunks.count) chunks (\(PARALLEL_PDF_CONCURRENCY)-way) for \(inputPath.string)")

        let progress = ParallelGSProgress(optimiser: optimiser, totalPages: totalPages)
        let url = path.url
        mainActor {
            optimiser.progress = Progress(totalUnitCount: Int64(totalPages))
            optimiser.progress.fileURL = url
            optimiser.progress.localizedDescription = optimiser.operation
            optimiser.progress.localizedAdditionalDescription = "Page 0 of \(totalPages)"
            optimiser.publishProgress()
        }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = PARALLEL_PDF_CONCURRENCY
        queue.name = "clop.pdf.parallel"

        let stateLock = NSLock()
        var anyError: Error?

        func setError(_ error: Error) {
            stateLock.lock()
            if anyError == nil { anyError = error }
            stateLock.unlock()
        }

        for chunk in chunks {
            queue.addOperation {
                stateLock.lock()
                let abort = anyError != nil
                stateLock.unlock()
                if abort { return }

                let baseArgs = gsArgs(inputPath.string, chunk.output.string, lossy: effectiveDPI < PDF_DPI_NO_DOWNSAMPLE, dpi: effectiveDPI)
                let args = ["-dFirstPage=\(chunk.first)", "-dLastPage=\(chunk.last)"] + baseArgs

                do {
                    let proc = try tryProc(GS.string, args: args, tries: 2, captureOutput: true, env: GHOSTSCRIPT_ENV) { p in
                        mainActor { optimiser.processes.append(p) }
                        if let pipe = p.standardOutput as? Pipe {
                            let handle = pipe.fileHandleForReading
                            handle.readabilityHandler = { pipe in
                                let data = pipe.availableData
                                guard !data.isEmpty else {
                                    handle.readabilityHandler = nil
                                    return
                                }
                                guard let string = String(data: data, encoding: .utf8) else { return }
                                var n = 0
                                for line in string.components(separatedBy: .newlines) where line.hasPrefix("Page ") {
                                    n += 1
                                }
                                if n > 0 { progress.increment(by: n) }
                            }
                        }
                    }
                    guard proc.terminationStatus == 0 else {
                        setError(ClopProcError.processError(proc))
                        queue.cancelAllOperations()
                        return
                    }
                } catch {
                    setError(error)
                    queue.cancelAllOperations()
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()

        if let anyError {
            mainActor { optimiser.unpublishProgress() }
            throw anyError
        }

        let merged = PDFDocument()
        var globalIdx = 0
        for chunk in chunks {
            guard let chunkDoc = PDFDocument(url: chunk.output.url) else {
                mainActor { optimiser.unpublishProgress() }
                throw ClopError.invalidPDF(chunk.output)
            }
            for p in 0 ..< chunkDoc.pageCount {
                if let page = chunkDoc.page(at: p) {
                    merged.insert(page, at: globalIdx)
                    globalIdx += 1
                }
            }
        }
        guard merged.write(to: tempFile.url) else {
            mainActor { optimiser.unpublishProgress() }
            throw ClopError.invalidPDF(tempFile)
        }

        tempFile.waitForFile(for: 2)
        try? tempFile.setOptimisationStatusXattr("true")
        if tempFile != path {
            if Defaults[.preserveDates] {
                tempFile.copyCreationModificationDates(from: path)
            }
            try tempFile.copy(to: path, force: true)
        }

        mainActor { optimiser.unpublishProgress() }

        return PDF(path)
    }
}
