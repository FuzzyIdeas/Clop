import Cocoa
import Defaults
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

// MARK: - Pipeline Action

/// A discrete action in the optimisation pipeline.
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

// MARK: - Build Pipeline

/// Build a pipeline from the parameters that callers currently pass to `optimiseItem` / `optimiseURL`.
///
/// The returned actions follow the existing mutual-exclusivity rules:
///  - downscale OR changePlaybackSpeed OR optimise (never more than one of these)
///  - removeAudio and runShortcut can be appended to any of the above
@MainActor func buildPipeline(
    scalingFactor: Double? = nil,
    cropSize: CropSize? = nil,
    changePlaybackSpeedFactor: Double? = nil,
    removeAudio: Bool? = nil,
    shortcut: Shortcut? = nil
) -> [PipelineAction] {
    var actions: [PipelineAction] = []

    if cropSize != nil || (scalingFactor != nil && scalingFactor! < 1) {
        actions.append(.downscale(factor: scalingFactor, cropSize: cropSize))
    } else if let changePlaybackSpeedFactor, changePlaybackSpeedFactor != 1, changePlaybackSpeedFactor != 0 {
        actions.append(.changePlaybackSpeed(factor: changePlaybackSpeedFactor))
    } else {
        actions.append(.optimise)
    }

    if removeAudio == true {
        actions.append(.removeAudio)
    }

    if let shortcut {
        actions.append(.runShortcut(shortcut))
    }

    return actions
}

// MARK: - Shared Helpers

/// Apply conversion behaviour settings when an image is converted to a different format.
///
/// Handles backup of original (for `.inPlace`) and copying converted file to the original directory (for non-`.temporary`).
/// Returns the image to use going forward (possibly with updated path) and sets `originalPath` if the original was preserved.
@MainActor func applyImageConversionBehaviour(original img: Image, converted: Image, originalPath: inout FilePath?) throws -> Image {
    guard img.path.dir != FilePath.images else {
        return converted
    }

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
        return max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    }
    if let current = OM.current, current.id == pathID {
        let f = max(current.downscaleFactor > 0.5 ? current.downscaleFactor - 0.25 : current.downscaleFactor - 0.1, 0.1)
        current.downscaleFactor = f
        return f
    }
    return max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
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
        return max(currentFactor > 0.5 ? currentFactor - 0.25 : currentFactor - 0.1, 0.1)
    }
    return max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
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
    source: OptimisationSource? = nil
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
    } else if !hasExplicitConvert, !hasDownscale, let optImg = try getCachedOptimisedImage(img: img, id: id, retinaDownscaled: false) {
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
        optimiser.originalURL = img.path.backup(path: img.path.clopBackupPath, force: false, operation: .copy)?.url ?? img.path.url
        optimiser.url = (savePath ?? img.path).url
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
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                currentImage = img
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
                    (result ?? optimisedImage).copyToClipboard()
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

// MARK: - Video Pipeline

/// Unified video pipeline replacing `optimiseVideo()`, `downscaleVideo()`, and `changePlaybackSpeedVideo()`.
///
/// Actions are "compiled" into parameters for one `Video.optimise()` call (since ffmpeg can do
/// resize + speed change + audio removal + encoding in a single pass).
@discardableResult
@MainActor func runVideoPipeline(
    _ video: Video,
    actions: [PipelineAction],
    id: String? = nil,
    debounceMS: Int = 0,
    originalPath: FilePath? = nil,
    copyToClipboard: Bool = false,
    allowLarger: Bool = false,
    hideFloatingResult: Bool = false,
    aggressiveOptimisation: Bool? = nil,
    source: OptimisationSource? = nil
) async throws -> Video? {
    let path = video.path
    let pathString = path.string
    let itemType = ItemType.from(filePath: path)

    let hasDownscale = actions.contains(where: \.isDownscale)
    let hasSpeedChange = actions.contains(where: \.isChangePlaybackSpeed)
    let hasRemoveAudio = actions.contains(where: \.isRemoveAudio)

    // Compile actions into Video.optimise() parameters
    var resizeTo: CGSize?
    var cropTo: CropSize?
    var speedFactor: Double?
    var removeAudio: Bool?
    var shortcutAction: Shortcut?

    for action in actions {
        switch action {
        case let .downscale(factor, cropSize):
            cropTo = cropSize
            if let resolution = video.size {
                let effectiveFactor: Double = if let cropSize {
                    computeVideoDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: cropSize, videoSize: resolution)
                } else {
                    computeVideoDownscaleFactor(id: id ?? pathString, factor: factor, cropSize: nil, videoSize: resolution)
                }
                scalingFactor = effectiveFactor
                resizeTo = cropSize?.computedSize(from: resolution) ?? resolution.scaled(by: effectiveFactor)
            }
        case let .changePlaybackSpeed(factor):
            speedFactor = computeSpeedFactor(id: id ?? pathString, factor: factor)
        case .removeAudio:
            removeAudio = true
        case let .runShortcut(shortcut):
            shortcutAction = shortcut
        default:
            break // .optimise and .convert handled below
        }
    }

    // Determine forceMP4 from settings (auto-conversion)
    let forceMP4 = actions.contains(where: \.isConvert) || Defaults[.formatsToConvertToMP4].contains(itemType.utType ?? .mpeg4Movie)

    let resolution = video.size
    let aggressive = aggressiveOptimisation ?? opt(id ?? pathString)?.aggressive ?? false

    // Build operation label
    var labelActions = actions
    if hasDownscale, let resizeTo, let resolution {
        labelActions = actions.map { action in
            if case let .downscale(_, cropSize) = action {
                return .downscale(factor: scalingFactor, cropSize: cropSize)
            }
            return action
        }
    }
    if hasSpeedChange, let speedFactor {
        labelActions = labelActions.map { action in
            if case .changePlaybackSpeed = action {
                return .changePlaybackSpeed(factor: speedFactor)
            }
            return action
        }
    }
    let opLabel = if debounceMS > 0, !hasDownscale, !hasSpeedChange {
        "Waiting for video to be ready"
    } else {
        operationLabel(for: labelActions, filename: path.lastComponent?.string ?? "", videoSize: resolution, aggressive: aggressive)
    }

    // Set up optimiser
    let optimiser = OM.optimiser(id: id ?? pathString, type: itemType, operation: opLabel, hidden: hideFloatingResult, source: source)
    if optimiser.oldBytes == 0 {
        optimiser.oldBytes = video.fileSize
    }
    if optimiser.oldSize == nil {
        optimiser.oldSize = resolution
    }
    if optimiser.url == nil {
        optimiser.url = path.url
    }
    if hasDownscale {
        optimiser.downscaleFactor = scalingFactor
        optimiser.remover = nil
        optimiser.inRemoval = false
        optimiser.stop(remove: false)
    }
    if hasSpeedChange {
        optimiser.changePlaybackSpeedFactor = speedFactor ?? 1.0
        optimiser.remover = nil
        optimiser.inRemoval = false
        optimiser.stop(remove: false)
    }

    // If this is a re-downscale or speed-change, inherit the other setting
    if hasDownscale, !hasSpeedChange {
        speedFactor = optimiser.changePlaybackSpeedFactor != 1.0 ? optimiser.changePlaybackSpeedFactor : nil
    }
    if hasSpeedChange, !hasDownscale {
        if let existingSize = optimiser.newSize {
            resizeTo = existingSize
        }
    }

    // Compute originalPath for backup (used by Video.optimise)
    let effectiveOriginalPath: FilePath? = if hasDownscale || hasSpeedChange {
        [.cli, .finder, .service, .dropZone].contains(source) ? video.path : originalPath
    } else {
        nil
    }

    var done = false
    var result: Video?

    videoOptimiseDebouncers[pathString]?.cancel()

    let workItem = mainAsyncAfter(ms: debounceMS) {
        let finalOpLabel = operationLabel(for: labelActions, filename: optimiser.filename, videoSize: resolution, aggressive: aggressive)
        optimiser.operation = finalOpLabel
        if !hasDownscale, !hasSpeedChange {
            optimiser.originalURL = path.url
        }
        OM.optimisers = OM.optimisers.without(optimiser).with(optimiser)
        showFloatingThumbnails()

        let fileSize = video.fileSize
        var previouslyCached = true

        videoOptimisationQueue.addOperation {
            var optimisedVideo: Video?
            defer {
                mainActor { done = true }
            }

            do {
                if !hideFloatingResult {
                    mainActor { OM.current = optimiser }
                }

                log.debug("Running video pipeline \(actions) for \(pathString)")

                optimisedVideo = try video.optimise(
                    optimiser: optimiser,
                    forceMP4: forceMP4,
                    resizeTo: resizeTo,
                    cropTo: cropTo,
                    changePlaybackSpeedBy: speedFactor,
                    originalPath: effectiveOriginalPath,
                    aggressiveOptimisation: aggressive,
                    removeAudio: removeAudio
                )

                // Move result to original location if same extension but different path
                if optimisedVideo!.path.extension == video.path.extension, optimisedVideo!.path != video.path {
                    let newPath = try optimisedVideo!.path.move(to: video.path, force: true)
                    optimisedVideo = optimisedVideo?.copyWithPath(newPath)
                }

                // Size check: only for plain optimise (no resize/speed change)
                if !hasDownscale, !hasSpeedChange,
                   optimisedVideo!.convertedFrom == nil,
                   optimisedVideo!.fileSize >= fileSize, !allowLarger
                {
                    video.path.restore(backupPath: video.path.clopBackupPath, force: true)
                    mainActor {
                        optimiser.oldBytes = fileSize
                        optimiser.url = video.path.url
                    }
                    throw ClopError.videoSizeLarger(path)
                }

                // Save to cache (only for plain optimise)
                if !hasDownscale, !hasSpeedChange {
                    mainActor {
                        if OM.optimisedFilesByHash[video.hash] == nil {
                            previouslyCached = false
                            OM.optimisedFilesByHash[video.hash] = optimisedVideo!.path
                        }
                    }
                }
            } catch let ClopProcError.processError(proc) {
                if proc.terminated {
                    log.debug("Process terminated by us: \(proc.commandLine)")
                } else {
                    log.error("Error in video pipeline \(pathString): \(proc.commandLine)\nOUT: \(proc.out)\nERR: \(proc.err)")
                    mainActor { optimiser.finish(error: "Optimisation failed") }
                }
            } catch ClopError.imageSizeLarger, ClopError.videoSizeLarger, ClopError.pdfSizeLarger {
                optimisedVideo = video
                mainActor { optimiser.info = "File already fully compressed" }
            } catch let error as ClopError {
                log.error("Error in video pipeline \(pathString): \(error.description)")
                mainActor { optimiser.finish(error: error.humanDescription) }
            } catch {
                log.error("Error in video pipeline \(pathString): \(error)")
                mainActor { optimiser.finish(error: "Optimisation failed") }
            }

            guard var optimisedVideo else { return }

            // Run shortcut if present
            var shortcutChangedVideo = false
            if let shortcutAction, let changedVideo = try? optimisedVideo.runThroughShortcut(
                shortcut: shortcutAction, optimiser: optimiser,
                allowLarger: allowLarger,
                aggressiveOptimisation: aggressive,
                source: source
            ) {
                optimisedVideo = changedVideo
                mainActor { optimiser.url = changedVideo.path.url }
                shortcutChangedVideo = true
            }

            mainActor {
                result = optimisedVideo
                optimiser.url = optimisedVideo.path.url
                if !hideFloatingResult {
                    OM.current = optimiser
                }

                if hasDownscale {
                    optimiser.finish(
                        oldBytes: fileSize, newBytes: optimisedVideo.fileSize,
                        oldSize: resolution, newSize: resizeTo,
                        removeAfterMs: hideFilesAfter
                    )
                } else {
                    optimiser.finish(
                        oldBytes: fileSize, newBytes: optimisedVideo.fileSize,
                        removeAfterMs: hideFilesAfter
                    )
                }

                if copyToClipboard {
                    optimiser.copyToClipboard()
                }

                if !shortcutChangedVideo, !previouslyCached, !hasDownscale, !hasSpeedChange {
                    OM.optimisedFilesByHash[video.hash] = optimisedVideo.path
                }
            }
        }
    }
    videoOptimiseDebouncers[pathString] = workItem

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}

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

    let optimiser = OM.optimiser(id: id ?? pathString, type: .pdf, operation: opLabel, hidden: hideFloatingResult, source: source)

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
                optimisedPDF = try pdf.optimise(optimiser: optimiser, aggressiveOptimisation: aggressiveOptimisation)
                if let cropSize {
                    optimisedPDF!.cropTo(aspectRatio: cropSize.longEdge ? cropSize.fractionalAspectRatio : cropSize.aspectRatio)
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

    while !done, !workItem.isCancelled {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return result
}
