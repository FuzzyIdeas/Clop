import Cocoa
import Defaults
import Foundation
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "ImagePipeline")

@MainActor func applyImageConversionBehaviour(original img: Image, converted: Image, originalPath: inout FilePath?) throws -> Image {
    let behaviour = Defaults[.convertedImageBehaviour]
    if behaviour == .inPlace, let backupPath = img.path.clopBackupPath {
        img.path.backup(path: backupPath, force: true, operation: .move)
    }
    if behaviour != .temporary {
        try converted.path.setOptimisationStatusXattr("pending")
        let path = try converted.path.copy(to: img.path.dir, force: true)
        originalPath = img.path
        return Image(data: converted.data, path: path, nsImage: converted.image, type: converted.type, optimised: converted.optimised, retinaDownscaled: converted.retinaDownscaled)
    }
    return converted
}

func decrementedDownscaleFactor(_ factor: Double) -> Double {
    max(factor > 0.5 ? factor - 0.25 : factor - 0.1, 0.1)
}

/// Compute the downscale factor for an image, handling auto-decrement when no explicit factor is given.
@MainActor func computeImageDownscaleFactor(id: String?, factor: Double?, cropSize: CropSize?, imageSize: NSSize) -> Double {
    if let cropSize {
        return cropSize.factor(from: imageSize)
    }
    if let factor {
        return factor
    }
    let pathID = id ?? ""
    if let currentFactor = opt(pathID)?.downscaleFactor {
        return decrementedDownscaleFactor(currentFactor)
    }
    if let current = OM.current, current.id == pathID {
        let f = decrementedDownscaleFactor(current.downscaleFactor)
        current.downscaleFactor = f
        return f
    }
    return decrementedDownscaleFactor(scalingFactor)
}

/// Compute the downscale factor for a video.
@MainActor func computeVideoDownscaleFactor(id: String?, factor: Double?, cropSize: CropSize?, videoSize: CGSize) -> Double {
    if let cropSize {
        return cropSize.factor(from: videoSize)
    }
    if let factor {
        return factor
    }
    if let currentFactor = opt(id ?? "")?.downscaleFactor {
        return decrementedDownscaleFactor(currentFactor)
    }
    return decrementedDownscaleFactor(scalingFactor)
}

/// Compute the speed change factor for a video.
@MainActor func computeSpeedFactor(id: String?, factor: Double?) -> Double {
    if let factor {
        return factor
    }
    if let currentFactor = opt(id ?? "")?.changePlaybackSpeedFactor {
        return min(currentFactor < 2 ? currentFactor + 0.25 : currentFactor + 1.0, 10)
    }
    return 1.25
}

/// Build the operation label for the optimiser UI.
@MainActor func operationLabel(
    for actions: [PipelineAction],
    filename: String,
    imageSize: NSSize? = nil,
    videoSize: CGSize? = nil,
    aggressive: Bool
) -> String {
    let showFilename = !Defaults[.showImages]

    if let downscale = actions.first(where: \.isDownscale), case let .downscale(factor, cropSize) = downscale {
        let size = imageSize ?? videoSize ?? .zero
        let scaleString = if let cs = cropSize?.computedSize(from: size) {
            "\(cs.width > 0 ? cs.width.i.s : "Auto")×\(cs.height > 0 ? cs.height.i.s : "Auto")"
        } else if let factor {
            "\((factor * 100).intround)%"
        } else {
            "?"
        }
        return "Scaling to \(scaleString)" + (aggressive ? " (aggressive)" : "")
    }

    if let speed = actions.first(where: \.isChangePlaybackSpeed), case let .changePlaybackSpeed(factor) = speed {
        let label = if factor > 1 {
            "Speeding up by \(factor < 2 ? factor.str(decimals: 2) : factor.i.s)x"
        } else if factor == 1 {
            "Reverting to original speed"
        } else {
            "Slowing down to \(factor != 0.5 ? factor.str(decimals: 2) : "0.5")x"
        }
        return label + (aggressive ? " (aggressive)" : "")
    }

    let base = showFilename ? "Optimising \(filename)" : "Optimising"
    return base + (aggressive ? " (aggressive)" : "")
}

// MARK: - Image Pipeline

/// Unified image pipeline replacing `optimiseImage()` and `downscaleImage()`.
///
/// Handles: auto-conversion from settings, cache lookup, debouncing, backup creation,
/// sequential action execution (convert → optimise → downscale → shortcut),
/// error handling, finalization, clipboard copy, and cache update.
@discardableResult
@MainActor func runImagePipeline(
    _ img: Image,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    saveTo savePath: FilePath? = nil,
    copyToClipboard: Bool = false,
    allowTiff: Bool? = nil,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    adaptiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil,
    skipCache: Bool = false
) async throws -> Image? {
    let path = img.path
    var img = img

    // Guard: already optimised
    guard !img.optimised else {
        throw ClopError.alreadyOptimised(path)
    }
    var pathString = path.string

    // Guard: TIFF setting
    guard img.type != .tiff || (allowTiff ?? Defaults[.optimiseTIFF]) else {
        log.debug("Skipping image \(pathString) because TIFF optimisation is disabled")
        throw ClopError.skippedType("TIFF optimisation is disabled")
    }

    // Guard: clipboard pause
    if id == Optimiser.IDs.clipboardImage, pauseForNextClipboardEvent {
        log.debug("Skipping image \(pathString) because it was paused")
        pauseForNextClipboardEvent = false
        throw ClopError.optimisationPaused(path)
    }

    var allowLarger = allowLarger
    var originalPath: FilePath?

    let hasDownscale = actions.contains(where: \.isDownscale)

    // Auto-detect conversion from settings (unless explicit .convert action exists)
    let hasExplicitConvert = actions.contains(where: \.isConvert)
    let autoConversionFormat: UTType? = if hasExplicitConvert {
        nil
    } else {
        Defaults[.formatsToConvertToJPEG].contains(img.type)
            ? .jpeg
            : (Defaults[.formatsToConvertToPNG].contains(img.type) ? .png : nil)
    }

    if let autoConversionFormat {
        let converted = try img.convert(to: autoConversionFormat, asTempFile: true)
        img = try applyImageConversionBehaviour(original: img, converted: converted, originalPath: &originalPath)
        pathString = img.path.string
        allowLarger = true
    } else if !skipCache, !hasExplicitConvert, !hasDownscale, let optImg = try getCachedOptimisedImage(img: img, id: id, retinaDownscaled: false) {
        log.debug("Using cached optimised image \(optImg.path)")
        return optImg
    }

    // Compute effective downscale factor (including auto-decrement for repeated presses)
    var effectiveDownscaleFactor: Double?
    if hasDownscale, case let .downscale(factor, cropSize) = actions.first(where: \.isDownscale)! {
        effectiveDownscaleFactor = computeImageDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: cropSize, imageSize: img.size)
        scalingFactor = effectiveDownscaleFactor!
    }

    let aggressive = aggressiveOptimisation ?? opt(id ?? pathString)?.aggressive ?? false

    // Build operation label
    var effectiveActions = actions
    if let effectiveDownscaleFactor, hasDownscale {
        // Replace downscale action with computed factor
        effectiveActions = actions.map { action in
            if case let .downscale(_, cropSize) = action {
                return .downscale(factor: effectiveDownscaleFactor, cropSize: cropSize)
            }
            return action
        }
    }
    let opLabel = operationLabel(for: effectiveActions, filename: img.path.lastComponent?.string ?? "", imageSize: img.size, aggressive: aggressive)

    // Set up optimiser
    let optimiser = OM.optimiser(
        id: id ?? pathString, type: .image(img.type),
        operation: opLabel,
        hidden: hideFloatingResult, source: source, indeterminateProgress: true
    )
    if !hideFloatingResult {
        optimiser.thumbnail = img.image
    }
    if hasDownscale {
        optimiser.downscaleFactor = effectiveDownscaleFactor ?? scalingFactor
        optimiser.remover = nil
        optimiser.inRemoval = false
        optimiser.stop(remove: false)
    } else {
        optimiser.downscaleFactor = 1.0
    }
    optimiser.newSize = nil
    optimiser.newBytes = -1
    if let url = originalPath?.url {
        optimiser.convertedFromURL = url
    }

    var done = false
    var result: Image?

    // Cancel existing debouncers for this path
    imageOptimiseDebouncers[pathString]?.cancel()
    imageResizeDebouncers[pathString]?.cancel()

    let workItem = mainAsyncAfter(ms: debounceMS) {
        if !hasDownscale {
            scalingFactor = 1.0
        }
        optimiser.stop(remove: false)
        optimiser.operation = opLabel
        if optimiser.originalURL == nil {
            optimiser.originalURL = img.path.backup(path: img.path.clopBackupPath, force: false, operation: .copy)?.url ?? img.path.url
        }
        optimiser.url = (savePath ?? img.path).url
        if id == Optimiser.IDs.clipboardImage, optimiser.startingURL == nil {
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
        let effectiveActions = effectiveActions
        var previouslyCached = true

        imageOptimisationQueue.addOperation {
            defer {
                mainActor { done = true }
            }

            var currentImage: Image? = img
            var shortcutChanged = false
            do {
                log.debug("Running image pipeline \(effectiveActions) for \(pathString)")

                for action in effectiveActions {
                    guard let ci = currentImage else { break }

                    switch action {
                    case let .convert(format):
                        let converted = try ci.convert(to: format, asTempFile: true)
                        currentImage = converted
                        mainActor {
                            optimiser.operation = "Converting to \(format.preferredFilenameExtension?.uppercased() ?? "?")"
                            optimiser.url = converted.path.url
                            optimiser.type = .image(converted.type)
                        }

                    case .optimise:
                        mainActor {
                            let base = Defaults[.showImages] ? "Optimising" : "Optimising \(optimiser.filename)"
                            optimiser.operation = base + (aggressive ? " (aggressive)" : "")
                        }
                        currentImage = try ci.optimise(
                            optimiser: optimiser,
                            allowLarger: allowLarger,
                            aggressiveOptimisation: aggressiveOptimisation,
                            adaptiveSize: adaptiveOptimisation ?? Defaults[.adaptiveImageSize]
                        )
                        if currentImage!.type == img.type {
                            currentImage = try currentImage?.copyWithPath(currentImage!.path.copy(to: img.path, force: true))
                        } else {
                            mainActor {
                                optimiser.url = currentImage!.path.url
                                optimiser.type = .image(currentImage!.type)
                            }
                        }

                    case let .downscale(_, cropSize):
                        if let cropSize, cropSize.width > 0, cropSize.height > 0 {
                            currentImage = try ci.resize(
                                toSize: cropSize,
                                optimiser: optimiser,
                                aggressiveOptimisation: aggressive,
                                adaptiveSize: adaptiveOptimisation ?? false
                            )
                        } else {
                            if let s = cropSize?.ns {
                                scalingFactor = s.width == 0 ? s.height / ci.size.height : s.width / ci.size.width
                            }
                            currentImage = try ci.resize(
                                toFraction: effectiveDownscaleFactor ?? scalingFactor,
                                optimiser: optimiser,
                                aggressiveOptimisation: aggressive,
                                adaptiveSize: adaptiveOptimisation ?? false
                            )
                        }
                        // Copy result to target path
                        if id != Optimiser.IDs.clipboardImage, currentImage!.type == img.type {
                            let newURL = try (currentImage!.path.copy(to: savePath ?? img.path, force: true)).url
                            mainActor {
                                optimiser.url = newURL
                                optimiser.type = .image(currentImage!.type)
                            }
                        }

                    case let .runShortcut(shortcut):
                        if let changedImage = try? ci.runThroughShortcut(
                            shortcut: shortcut, optimiser: optimiser,
                            allowLarger: allowLarger,
                            aggressiveOptimisation: aggressive,
                            source: source
                        ) {
                            currentImage = changedImage
                            mainActor {
                                optimiser.url = changedImage.path.url
                                optimiser.type = .image(changedImage.type)
                            }
                            shortcutChanged = true
                        }

                    default:
                        break // skip video-only actions
                    }
                }

                // Save optimised image path to cache to avoid re-optimising it after it is saved to file
                if let currentImage {
                    mainActor {
                        if OM.optimisedFilesByHash[img.hash] == nil {
                            previouslyCached = false
                            OM.optimisedFilesByHash[img.hash] = currentImage.path
                        }
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in image pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger,
                ClopError.alreadyOptimised, ClopError.alreadyResized
            {
                if currentImage == nil { currentImage = img }
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in image pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in image pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard let optimisedImage = currentImage else { return }

            mainActor {
                if !hideFloatingResult {
                    OM.current = optimiser
                }
                optimiser.finish(
                    oldBytes: img.data.count, newBytes: optimisedImage.data.count,
                    oldSize: img.size, newSize: optimisedImage.size,
                    removeAfterMs: id == Optimiser.IDs.clipboardImage ? hideClipboardAfter : hideFilesAfter
                )

                if id == Optimiser.IDs.clipboardImage, Defaults[.copyImageFilePath], Defaults[.useCustomNameTemplateForClipboardImages] {
                    optimiser.rename(to: generateFileName(template: Defaults[.customNameTemplateForClipboardImages] ?! DEFAULT_NAME_TEMPLATE, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber]))
                    if let path = optimiser.path {
                        result = Image(data: optimisedImage.data, path: path, nsImage: optimisedImage.image, type: optimisedImage.type, optimised: optimisedImage.optimised, retinaDownscaled: optimisedImage.retinaDownscaled)
                    } else {
                        result = optimisedImage
                    }
                } else {
                    result = optimisedImage
                }

                if copyToClipboard {
                    if Defaults[.appendClipboardResults], Defaults[.copyConsecutiveClipboardImages] {
                        OM.copyAllClipboardImagesToClipboard()
                    } else {
                        (result ?? optimisedImage).copyToClipboard()
                    }
                }
                if !shortcutChanged, !previouslyCached {
                    OM.optimisedFilesByHash[img.hash] = (result ?? optimisedImage).path
                }
            }
        }
    }

    imageOptimiseDebouncers[pathString] = workItem
    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}
