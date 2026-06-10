import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "PDFPipeline")

// MARK: - PDF Pipeline

/// Unified PDF pipeline replacing `optimisePDF()`.
@discardableResult
@MainActor func runPDFPipeline(
    _ pdf: PDF,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    copyToClipboard: Bool = false,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    dpiOverride: Int? = nil,
    source: OptimisationSource? = nil
) async throws -> PDF? {
    let path = pdf.path
    let pathString = path.string

    let aggressive = aggressiveOptimisation ?? false
    let opLabel = if debounceMS > 0 {
        "Waiting for PDF to be ready"
    } else {
        operationLabel(for: actions, filename: path.lastComponent?.string ?? "", aggressive: aggressive)
    }

    let pipelineId = id ?? pathString

    // Serialize per id: terminate the in-flight pipeline's running process and wait for it to unwind.
    if let previousPipeline = pdfPipelineInFlight[pipelineId] {
        opt(pipelineId)?.stop(remove: false)
        // Hash off the main actor while the in-flight pass unwinds: the lazy `pdf.hash`
        // would only read the file after the awaited pass has already replaced it.
        let contentHash = Task.detached { path.fileContentsHash }
        await previousPipeline.value

        // A duplicate plain-optimise request (e.g. several file-watcher events for one download)
        // queues up here behind the first pass: re-check the cache instead of re-optimising
        // content the awaited pass just finished.
        if actions.allSatisfy(\.isOptimise), !copyToClipboard, aggressiveOptimisation == nil, dpiOverride == nil,
           let hash = await contentHash.value, let cachedPath = OM.optimisedFilesByHash[hash], cachedPath.exists
        {
            log.debug("PDF \(pathString) was already optimised by the in-flight pipeline, using cached result \(cachedPath.string)")
            return PDF(cachedPath, thumb: false, id: id)
        }
    }

    let optimiser = OM.optimiser(id: pipelineId, type: .pdf, operation: opLabel, hidden: hideFloatingResult, source: source)

    // Extract crop size and shortcut from actions
    var cropSize: CropSize?
    var shortcutAction: Shortcut?
    for action in actions {
        if case let .downscale(_, cs) = action { cropSize = cs }
        if case let .runShortcut(s) = action { shortcutAction = s }
    }

    var done = false
    var result: PDF?

    pdfOptimiseDebouncers[pathString]?.cancel()
    let workItem = mainAsyncAfter(ms: debounceMS) {
        let finalOpLabel = (Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)") + (aggressive ? " (aggressive)" : "")
        optimiser.operation = finalOpLabel
        optimiser.originalURL = path.url
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let fileSize = pdf.fileSize
        var previouslyCached = true

        pdfOptimisationQueue.addOperation {
            var optimisedPDF: PDF?
            defer {
                mainActor {
                    pdfOptimiseDebouncers.removeValue(forKey: pathString)
                    done = true
                }
            }
            do {
                if !hideFloatingResult {
                    mainActor { OM.current = optimiser }
                }

                log.debug("Running PDF pipeline \(actions) for \(pathString)")

                let backupPath = pdf.path.clopBackupPath
                optimisedPDF = try pdf.optimise(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation, dpi: dpiOverride)
                if let cropSize {
                    if let rect = cropSize.cropRect, !rect.isFullFrame {
                        optimisedPDF!.cropTo(rect: rect)
                    } else {
                        optimisedPDF!.cropTo(aspectRatio: cropSize.longEdge ? cropSize.fractionalAspectRatio : cropSize.aspectRatio)
                    }
                }
                if !allowLarger, cropSize == nil, optimisedPDF!.fileSize >= fileSize {
                    pdf.path.restore(backupPath: backupPath ?? pdf.path.clopBackupPath, force: true)
                    mainActor {
                        optimiser.oldBytes = fileSize
                        optimiser.url = pdf.path.url
                    }
                    throw ClopError.pdfSizeLarger(path)
                }

                // Save optimised PDF path to cache to avoid re-optimising it after it is saved to file
                mainActor {
                    if OM.optimisedFilesByHash[pdf.hash] == nil {
                        previouslyCached = false
                        OM.optimisedFilesByHash[pdf.hash] = optimisedPDF!.path
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in PDF pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedPDF = pdf
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in PDF pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in PDF pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard var optimisedPDF else { return }

            var shortcutChangedPDF = false
            if let shortcutAction, let changedPDF = try? optimisedPDF.runThroughShortcut(
                shortcut: shortcutAction, optimiser: optimiser,
                allowLarger: allowLarger,
                aggressiveOptimisation: aggressive,
                source: source
            ) {
                optimisedPDF = changedPDF
                mainActor { optimiser.url = changedPDF.path.url }
                shortcutChangedPDF = true
            }

            mainActor {
                result = optimisedPDF
                optimiser.url = optimisedPDF.path.url
                optimiser.finish(oldBytes: fileSize, newBytes: optimisedPDF.fileSize, oldSize: optimisedPDF.size, removeAfterMs: hideFilesAfter)

                if copyToClipboard {
                    optimiser.copyToClipboard()
                }

                if !shortcutChangedPDF, !previouslyCached {
                    OM.optimisedFilesByHash[pdf.hash] = optimisedPDF.path
                }
            }
        }
    }
    pdfOptimiseDebouncers[pathString] = workItem

    let pipelineTask = Task<Void, Never> { @MainActor in
        while !done, !workItem.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    pdfPipelineInFlight[pipelineId] = pipelineTask
    await pipelineTask.value
    if pdfPipelineInFlight[pipelineId] == pipelineTask {
        pdfPipelineInFlight.removeValue(forKey: pipelineId)
    }
    return result
}
