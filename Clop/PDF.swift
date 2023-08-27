import Cocoa
import Defaults
import EonilFSEvents
import Foundation
import Lowtech
import PDFKit
import System
import UniformTypeIdentifiers

let GS = BIN_DIR.appendingPathComponent("gs").existingFilePath!

let GS_LOSSY_ARGS: [String] = [
    "-dAutoFilterGrayImages=true",
    "-dAutoFilterColorImages=true",
    "-dAutoFilterMonoImages=true",
    "-dColorImageFilter=/DCTEncode",
    "-dDownsampleColorImages=true",
    "-dDownsampleGrayImages=true",
    "-dDownsampleMonoImages=true",
    "-dGrayImageFilter=/DCTEncode",
    "-dPassThroughJPEGImages=false",
    "-dPassThroughJPXImages=false",
    "-dShowAcroForm=false",
]
let GS_LOSSLESS_ARGS: [String] = [
    "-dAutoFilterGrayImages=false",
    "-dAutoFilterColorImages=false",
    "-dAutoFilterMonoImages=false",
    "-dColorImageFilter=/FlateEncode",
    "-dDownsampleColorImages=false",
    "-dDownsampleGrayImages=false",
    "-dDownsampleMonoImages=false",
    "-dGrayImageFilter=/FlateEncode",
    "-dPassThroughJPEGImages=true",
    "-dPassThroughJPXImages=true",
    "-dShowAcroForm=true",
]

let GS_ARGS: [String] = [
    "-r150",
    "-dALLOWPSTRANSPARENCY",
    "-dAutoRotatePages=/None",
    "-dBATCH",
    "-dCannotEmbedFontPolicy=/Warning",
    "-dColorConversionStrategy=/LeaveColorUnchanged",
    "-dColorConversionStrategy=/sRGB",
    "-dColorImageDownsampleThreshold=1.0",
    "-dColorImageDownsampleType=/Bicubic",
    "-dColorImageResolution=150",
    "-dCompressFonts=true",
    "-dCompressPages=true",
    "-dCompressStreams=true",
    "-dConvertCMYKImagesToRGB=false",
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
    "-dGrayImageDownsampleThreshold=1.0",
    "-dGrayImageDownsampleType=/Bicubic",
    "-dGrayImageResolution=150",
    "-dHaveTransparency=true",
    "-dLZWEncodePages=true",
    "-dMaxBitmap=0",
    "-dMonoImageDownsampleThreshold=1.0",
    "-dMonoImageDownsampleType=/Bicubic",
    "-dMonoImageFilter=/CCITTFaxEncode",
    "-dMonoImageResolution=150",
    "-dNOPAUSE",
    "-dNOPROMPT",
    "-dOptimize=false",
    "-dParseDSCComments=false",
    "-dParseDSCCommentsForDocInfo=false",
    "-dPDFNOCIDFALLBACK",
    "-dPDFNOCIDFALLBACK",
    "-dPDFSETTINGS=/screen",
    "-dPDFSTOPONERROR",
    "-dPreserveAnnots=true",
    "-dPreserveCopyPage=false",
    "-dPreserveDeviceN=false",
    "-dPreserveDeviceN=true",
    "-dPreserveEPSInfo=false",
    "-dPreserveEPSInfo=false",
    "-dPreserveHalftoneInfo=false",
    "-dPreserveOPIComments=false",
    "-dPreserveOverprintSettings=false",
    "-dPreserveOverprintSettings=true",
    "-dPreserveSeparation=false",
    "-dPreserveSeparation=true",
    "-dPrinted=false",
    "-dProcessColorModel=/DeviceRGB",
    "-dSAFER",
    "-dSubsetFonts=true",
    "-dTransferFunctionInfo=/Apply",
    "-dTransferFunctionInfo=/Preserve",
    "-dUCRandBGInfo=/Remove",
]

let GS_PRE_ARGS: [String] = [
    "-c",
    "<< /ColorImageDict << /QFactor 0.76 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /ColorACSImageDict << /QFactor 0.76 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /GrayImageDict << /QFactor 0.76 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /GrayACSImageDict << /QFactor 0.76 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams << /AlwaysEmbed [ ] >> setdistillerparams << /NeverEmbed [/Courier /Courier-Bold /Courier-Oblique /Courier-BoldOblique /Helvetica /Helvetica-Bold /Helvetica-Oblique /Helvetica-BoldOblique /Times-Roman /Times-Bold /Times-Italic /Times-BoldItalic /Symbol /ZapfDingbats /Arial] >> setdistillerparams",
    "-f",
    "-c",
    "/originalpdfmark { //pdfmark } bind def /pdfmark { { { counttomark pop } stopped { /pdfmark errordict /unmatchedmark get exec stop } if dup type /nametype ne { /pdfmark errordict /typecheck get exec stop } if dup /DOCINFO eq { (Skipping DOCINFO pdfmark\n) print cleartomark exit } if originalpdfmark exit } loop } def",
    "-f",
]
let GS_POST_ARGS: [String] = [
    "-c", "/pdfmark { originalpdfmark } bind def", "-f",
    "-c", "[ /Producer () /ModDate () /CreationDate () /DOCINFO pdfmark", "-f",
]

func gsArgs(_ input: String, _ output: String, lossy: Bool) -> [String] {
    let optArgs: [String] = (lossy ? GS_LOSSY_ARGS : GS_LOSSLESS_ARGS)
    let outArgs: [String] = ["-sDEVICE=pdfwrite", "-sFONTPATH=\(FONT_PATH)", "-o", output]
    return GS_ARGS + optArgs + outArgs + GS_PRE_ARGS + [input] + GS_POST_ARGS
}

let FONT_PATH: String = [
    "\(NSHomeDirectory())/Library/Fonts",
    "/Library/Fonts/",
    "/System/Library/Fonts/",
    "/Library/Fonts/Microsoft/",
    "/Library/Application Support/Adobe/Fonts/",
].filter { FileManager.default.fileExists(atPath: $0) }.joined(separator: ":")

class Optimisable {
    init(_ path: FilePath, thumb: Bool = true, id: String? = nil) {
        self.path = path
        self.id = id

        if thumb {
            mainActor { self.fetchThumbnail() }
        }
    }

    let path: FilePath
    let id: String?

    lazy var fileSize: Int = path.fileSize() ?? 0

    @MainActor var optimiser: Optimiser? {
        OM.optimisers.first(where: { $0.id == id ?? path.string })
    }

    @MainActor func fetchThumbnail() {
        generateThumbnail(for: path.url, size: THUMB_SIZE) { [weak self] thumb in
            guard let self, let optimiser else {
                return
            }
            optimiser.thumbnail = NSImage(cgImage: thumb.cgImage, size: .zero)
        }
    }
}

let GS_PAGE_REGEX = try! Regex(#"^\s*Processing pages \d+ through (\d+)."#, as: (Substring, Substring).self).anchorsMatchLineEndings(true)

@MainActor func updateProgressGS(pipe: Pipe, url: URL, optimiser: Optimiser, pageCount: Int? = nil) {
    mainActor {
        optimiser.progress = Progress(totalUnitCount: pageCount?.i64 ?? 100)
        optimiser.progress.fileURL = url
        optimiser.progress.localizedDescription = optimiser.operation
        optimiser.progress.localizedAdditionalDescription = "Calculating progress"
    }

    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { pipe in
        let data = pipe.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
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
    lazy var document: PDFDocument? = PDFDocument(url: path.url)

    func optimise(optimiser: Optimiser, aggressiveOptimisation: Bool? = nil) throws -> PDF {
        let tempFile = FilePath.pdfs.appending(path.lastComponent?.string ?? "clop.pdf")

        let aggressiveOptimisation = aggressiveOptimisation ?? Defaults[.useAggresiveOptimisationPDF]
        mainActor { optimiser.aggresive = aggressiveOptimisation }

        let args = gsArgs(path.string, tempFile.string, lossy: aggressiveOptimisation)
        let proc = try tryProc(GS.string, args: args, tries: 3, captureOutput: true) { proc in
            mainActor { [weak self] in
                guard let self else { return }
                optimiser.processes = [proc]
                updateProgressGS(pipe: proc.standardOutput as! Pipe, url: self.path.url, optimiser: optimiser, pageCount: document?.pageCount)
            }
        }
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }
        path.backup(operation: .copy)

        tempFile.waitForFile(for: 2)
        try? tempFile.setOptimisationStatusXattr("true")
        if tempFile != path {
            try tempFile.copy(to: path, force: true)
        }

        return PDF(path)
    }
}

@MainActor func cancelPDFOptimisation(path: FilePath) {
    pdfOptimiseDebouncers[path.string]?.cancel()
    pdfOptimiseDebouncers.removeValue(forKey: path.string)

    opt(path.string)?.stop(animateRemoval: false)
}

@MainActor func shouldHandlePDF(event: EonilFSEventsEvent) -> Bool {
    let path = FilePath(event.path)
    guard let flag = event.flag, let stem = path.stem, !stem.starts(with: "."),
          let ext = path.extension?.lowercased(), ext == "pdf"
    else {
        return false

    }

    log.debug("\(path.shellString): \(flag)")

    guard fm.fileExists(atPath: event.path), !event.path.contains(FilePath.backups.string),
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

@discardableResult
@MainActor func optimisePDF(_ pdf: PDF, id: String? = nil, debounceMS: Int = 0, allowLarger: Bool = false, hideFloatingResult: Bool = false, aggressiveOptimisation: Bool? = nil) async throws -> PDF? {
    let path = pdf.path
    let pathString = path.string
    let optimiser = OM.optimiser(id: id ?? pathString, type: .pdf, operation: debounceMS > 0 ? "Waiting for PDF to be ready" : "Optimising", hidden: hideFloatingResult)

    var done = false
    var result: PDF?

    pdfOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        optimiser.operation = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressiveOptimisation ?? false ? " (aggressive)" : "")
        optimiser.originalURL = path.url
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        pdfOptimisationQueue.addOperation {
            defer {
                mainActor {
                    pdfOptimiseDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }
            do {
                mainAsync { OM.current = optimiser }

                let oldFileSize = pdf.fileSize

                let optimisedPDF = try pdf.optimise(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation)
                if optimisedPDF.fileSize >= oldFileSize, !allowLarger {
                    pdf.path.restore(force: true)
                    mainAsync {
                        optimiser.oldBytes = oldFileSize
                        optimiser.url = pdf.path.url
                    }

                    throw ClopError.pdfSizeLarger(path)
                }
                mainActor {
                    result = optimisedPDF
                }
                mainAsync {
                    optimiser.url = optimisedPDF.path.url
                    optimiser.finish(oldBytes: oldFileSize, newBytes: optimisedPDF.fileSize, removeAfterMs: hideFilesAfter)
                }
            } catch let ClopError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error optimising PDF \(pathString): \(proc.commandLine)")
                    optimiser.finish(error: "Optimisation failed")
                }
            } catch let error as ClopError {
                log.error("Error optimising PDF \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error optimising PDF \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }
        }
    }
    pdfOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100)
    }
    return result
}
