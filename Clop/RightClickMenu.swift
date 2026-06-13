//
//  RightClickMenu.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.09.2023.
//

import Defaults
import Foundation
import Lowtech
import os
import SwiftUI
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "RightClickMenu")

extension Bundle {
    var lowercasedName: String {
        name.lowercased()
    }
}

struct OpenWithMenuView: View {
    let fileURL: URL

    var body: some View {
        Menu("Open with...") {
            let appsDict: [String: [Bundle]] = NSWorkspace.shared
                .urlsForApplications(toOpen: fileURL)
                .compactMap { Bundle(url: $0) }
                .group(by: \.bundleIdentifier)
            let apps = appsDict.values
                .compactMap { $0.min(by: \.bundlePath.count) }
                .sorted(by: \.lowercasedName)

            ForEach(apps, id: \.bundleURL) { app in
                let icon: NSImage = {
                    let i = NSWorkspace.shared.icon(forFile: app.bundlePath)
                    i.size = NSSize(width: 14, height: 14)
                    return i
                }()

                Button(action: {
                    NSWorkspace.shared.open([fileURL], withApplicationAt: app.bundleURL, configuration: .init(), completionHandler: { _, _ in })
                }) {
                    SwiftUI.Image(nsImage: icon)
                    Text(app.name)
                }
            }
        }
    }
}

struct RightClickMenuView: View {
    @ObservedObject var optimiser: Optimiser
    @ObservedObject var wdm = WDM

    var body: some View {
        Button(optimiser.running ? "Stop" : "Dismiss") {
            hoveredOptimiserID = nil
            optimiser.stop(animateRemoval: true)
        }
        .keyboardShortcut(.delete)
        Divider()

        if !optimiser.running {
            Button("Save as...") {
                optimiser.save()
            }
            .keyboardShortcut("s")

            Button("Copy to clipboard") {
                optimiser.copyToClipboard()
                optimiser.overlayMessage = "Copied"
            }
            .keyboardShortcut("c")

            Button("Show in Finder") {
                optimiser.showInFinder()
            }
            .keyboardShortcut("f")

            if let url = optimiser.url ?? optimiser.originalURL {
                Button("Open with default app") {
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut("o")
            }

            if let url = optimiser.url {
                OpenWithMenuView(fileURL: url)
            }

            Divider()
        }

        Button(optimiser.convertedFromVideo ? "Restore original video" : "Restore original") {
            optimiser.restoreOriginal()
        }
        .keyboardShortcut("z")
        .disabled(optimiser.isOriginal)

        Button("QuickLook") {
            optimiser.quicklook()
        }
        .keyboardShortcut(" ")

        if !optimiser.type.isAudio {
            Button("Compare (diff)") {
                optimiser.compare()
            }
            .disabled(optimiser.url == nil || optimiser.comparisonOriginalURL == nil)
            .keyboardShortcut("d")
        }

        if !optimiser.running {
            if optimiser.canDownscale() ||
                optimiser.canChangePlaybackSpeed() ||
                optimiser.type.isVideo ||
                optimiser.canReoptimise()
            {
                Divider()
            }
            if optimiser.canCrop() {
                Button("Crop and resize...") {
                    optimiser.showCropWindow()
                }
                .keyboardShortcut("k")
            }

            if optimiser.canDownscale() {
                if optimiser.type.isAudio, optimiser.type.utType != .wav {
                    Menu("Change bitrate") {
                        LowerBitrateMenu(optimiser: optimiser)
                    }
                } else if !optimiser.type.isAudio {
                    Menu("Downscale") {
                        DownscaleMenu(optimiser: optimiser)
                    }
                    .disabled(optimiser.downscaleFactor <= 0.1)
                }
            }

            // Mirrors the floating card's compression slider. Audio keeps "Change bitrate" above
            // (the bitrate is its compression axis), so this is image/video only.
            if optimiser.canCompress(), !optimiser.type.isAudio {
                Menu("Compression") {
                    CompressionMenu(optimiser: optimiser)
                }
            }

            if optimiser.canChangePlaybackSpeed() {
                Menu("Change playback speed") {
                    ChangePlaybackSpeedMenu(optimiser: optimiser)
                }
                .disabled(optimiser.changePlaybackSpeedFactor >= 10)
            }

            if optimiser.type.isVideo {
                Button("Remove audio") {
                    optimiser.removeAudio()
                }.disabled(!optimiser.canRemoveAudio())
                Menu("Convert to GIF") {
                    ConvertToGIFMenu(optimiser: optimiser)
                }
            }

            if optimiser.canReoptimise() {
                if optimiser.type.isVideo {
                    Menu("Re-optimise with encoder") {
                        ReoptimiseWithEncoderMenu(optimiser: optimiser)
                    }
                } else {
                    Button("Re-optimise") {
                        optimiser.reoptimise()
                    }
                    Button("Aggressive optimisation") {
                        if optimiser.downscaleFactor < 1 {
                            optimiser.downscale(toFactor: optimiser.downscaleFactor, aggressiveOptimisation: true)
                        } else {
                            optimiser.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
                        }
                    }
                    .keyboardShortcut("a")
                    .disabled(optimiser.aggressive)
                }
            }

            Divider()

            if let session = wdm.session(forOptimiser: optimiser) {
                Button("Copy send link") {
                    session.copyLink()
                    optimiser.overlayMessage = "Copied link"
                }
                .keyboardShortcut("w")
            } else {
                Button("Send file securely") {
                    warpDropSend(optimiser: optimiser)
                }
                .keyboardShortcut("w")
            }
            Button("Upload with Dropshare") {
                DROPSHARE.open(optimiser: optimiser)
            }
            .keyboardShortcut("u")
            Menu("Add to shelf\u{2026}") {
                Button("Add to Yoink") {
                    YOINK.open(optimiser: optimiser)
                }
                Button("Add to Dockside") {
                    DOCKSIDE.open(optimiser: optimiser)
                }
                Button("Add to Dropover") {
                    DROPOVER.open(optimiser: optimiser)
                }
                Button("Add to Atoll") {
                    ATOLL.open(optimiser: optimiser)
                }
            }

            Divider()

            if !optimiser.type.isPDF, !optimiser.type.isAudio {
                Button("Strip EXIF metadata") {
                    optimiser.path?.stripExif()
                    optimiser.overlayMessage = "Stripped"
                }
            }

            if optimiser.type.isPDF, let pdf = optimiser.pdf, pdf.pageCount > 0 {
                if pdf.pageCount == 1 {
                    Menu("Convert to image") {
                        Section("Best for photos and illustrations") {
                            Button("JPEG") { convertSinglePagePDFToImage(optimiser: optimiser, pdf: pdf, format: .jpeg) }
                        }
                        Section("Best for text and low-detail images") {
                            Button("PNG") { convertSinglePagePDFToImage(optimiser: optimiser, pdf: pdf, format: .png) }
                        }
                    }
                } else {
                    Menu("Extract pages as images") {
                        Section("Best for photos and illustrations") {
                            Button("JPEG") { extractPDFPagesAsImages(optimiser: optimiser, pdf: pdf, format: .jpeg) }
                        }
                        Section("Best for text and low-detail images") {
                            Button("PNG") { extractPDFPagesAsImages(optimiser: optimiser, pdf: pdf, format: .png) }
                        }
                    }
                }
            }

            if optimiser.convertibleTypes.isNotEmpty {
                Menu("Convert to…") {
                    ConvertMenu(optimiser: optimiser)
                }
            }

            Menu("Run pipeline") {
                RunPipelineMenu(optimiser: optimiser)
            }
            Menu("Run Shortcut") {
                WorkflowMenu(optimiser: optimiser)
            }
        }
    }
}

struct ConvertMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        ForEach(optimiser.convertibleTypes) { type in
            Button(type.preferredFilenameExtension ?? type.identifier) {
                optimiser.convert(to: type)
            }.disabled(optimiser.type.utType == type)
        }
    }
}

struct BatchRightClickMenuView: View {
    @ObservedObject var sm = SM
    @ObservedObject var wdm = WDM

    var body: some View {
        let optimisers = sm.optimisers

        Button("Save all to folder") {
            sm.save()
            sm.selection = []
        }

        Button("Copy to clipboard") {
            sm.copyToClipboard()
            sm.selection = []
        }

        Divider()

        Button("Restore original") {
            sm.restoreOriginal()
            sm.selection = []
        }
        .disabled(optimisers.allSatisfy(\.isOriginal))

        Button("QuickLook") {
            sm.quicklook()
        }

        Divider()
        if optimisers.contains(where: { !$0.type.isAudio }) {
            Menu("Downscale") {
                BatchDownscaleMenu(optimisers: optimisers.filter { !$0.type.isAudio })
            }
            .disabled(optimisers.filter { !$0.type.isAudio }.allSatisfy { $0.downscaleFactor <= 0.1 })
        }
        if optimisers.contains(where: { $0.type.isAudio && $0.type.utType != .wav }) {
            Menu("Change bitrate") {
                BatchBitrateMenu(optimisers: optimisers.filter { $0.type.isAudio && $0.type.utType != .wav })
            }
        }

        if optimisers.allSatisfy({ $0.canChangePlaybackSpeed() }) {
            Menu("Change playback speed") {
                BatchChangePlaybackSpeedMenu(optimisers: optimisers)
            }
            .disabled(optimisers.allSatisfy { $0.changePlaybackSpeedFactor >= 10 })
        }

        Button("Aggressive optimisation") {
            for optimiser in optimisers {
                if optimiser.downscaleFactor < 1 {
                    optimiser.downscale(toFactor: optimiser.downscaleFactor, aggressiveOptimisation: true)
                } else {
                    optimiser.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
                }
            }
            sm.selection = []
        }
        .disabled(optimisers.allSatisfy(\.aggressive))

        Divider()

        if sm.optimisers.allSatisfy({ wdm.session(forOptimiser: $0) != nil }) {
            Button("Copy all send links") {
                let links = sm.optimisers.compactMap { wdm.session(forOptimiser: $0)?.shareURL }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(links.joined(separator: "\n"), forType: .string)
                sm.selection = []
            }
        } else {
            Button("Send files securely") {
                warpDropSend(optimisers: sm.optimisers)
                sm.selection = []
            }
        }
        Button("Upload with Dropshare") {
            DROPSHARE.open(optimisers: sm.optimisers)
            sm.selection = []
        }
        Menu("Add to shelf\u{2026}") {
            Button("Add to Yoink") {
                YOINK.open(optimisers: sm.optimisers)
                sm.selection = []
            }
            Button("Add to Dockside") {
                DOCKSIDE.open(optimisers: sm.optimisers)
                sm.selection = []
            }
            Button("Add to Dropover") {
                DROPOVER.open(optimisers: sm.optimisers)
                sm.selection = []
            }
            Button("Add to Atoll") {
                ATOLL.open(optimisers: sm.optimisers)
                sm.selection = []
            }
        }

        Divider()

        Button("Strip EXIF metadata") {
            for optimiser in optimisers {
                optimiser.path?.stripExif()
            }
            sm.selection = []
        }
        .disabled(optimisers.allSatisfy { $0.type.isPDF || $0.type.isAudio })
    }
}

struct RunPipelineMenu: View {
    @ObservedObject var optimiser: Optimiser

    @Default(.savedPipelines) var savedPipelines

    var fileType: ClopFileType? {
        switch optimiser.type {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .pdf: .pdf
        default: nil
        }
    }

    var applicablePipelines: [Pipeline] {
        savedPipelines.filter { pipeline in
            guard let name = pipeline.name, !name.isEmpty else { return false }
            return pipeline.fileType == nil || pipeline.fileType == fileType
        }
    }

    var body: some View {
        if applicablePipelines.isEmpty {
            Text("No saved pipelines")
            Text("Save a pipeline in Settings > Automation")
        } else {
            ForEach(applicablePipelines) { pipeline in
                Button(pipeline.name ?? pipeline.id) {
                    runPipeline(pipeline)
                }
            }
        }
    }

    func runPipeline(_ pipeline: Pipeline) {
        guard let url = optimiser.url, let path = url.existingFilePath, let fileType else { return }

        // Replace the temp pipeline with this pipeline's steps
        optimiser.tempPipeline = pipeline.resolved.steps.filter { !$0.isFilter }
        optimiser.automationPipeline = pipeline

        Task { @MainActor in
            optimiser.running = true
            optimiser.operation = "Pipeline: \(pipeline.name ?? "unnamed")"
            do {
                let (resultFile, _, _) = try await executePipeline(
                    pipeline, file: path,
                    source: optimiser.source ?? .cli,
                    optimiser: optimiser,
                    fileType: fileType
                )
                optimiser.url = resultFile.url
                optimiser.finish(oldBytes: optimiser.oldBytes, newBytes: resultFile.fileSize() ?? optimiser.newBytes, oldSize: optimiser.oldSize)
            } catch {
                optimiser.finish(error: "Pipeline failed: \(error.localizedDescription)")
            }
        }
    }
}

struct WorkflowMenu: View {
    @ObservedObject var optimiser: Optimiser
    @ObservedObject var shortcutsManager = SHM

    var body: some View {
        ShortcutChoiceMenu { shortcut in
            // Track in temp pipeline
            optimiser.tempPipeline.append(.runShortcut(shortcut))

            switch optimiser.type {
            case .image:
                processImage(shortcut: shortcut)
            case .video:
                processVideo(shortcut: shortcut)
            case .pdf:
                processPDF(shortcut: shortcut)
            default:
                break
            }
        }
    }

    func processPDF(shortcut: Shortcut) {
        DispatchQueue.global().async {
            guard let pdf = optimiser.pdf else {
                return
            }
            if let newPDF = try? pdf.runThroughShortcut(shortcut: shortcut, optimiser: optimiser, allowLarger: false, aggressiveOptimisation: Defaults[.useAggressiveOptimisationMP4], source: optimiser.source) {
                mainActor {
                    optimiser.url = newPDF.path.url
                    optimiser.finish(oldBytes: optimiser.oldBytes, newBytes: newPDF.path.fileSize() ?? optimiser.newBytes)
                }
            } else {
                mainActor {
                    optimiser.running = false
                }
            }
        }
    }

    func processVideo(shortcut: Shortcut) {
        DispatchQueue.global().async {
            guard let video = optimiser.video else {
                return
            }
            if let newVideo = try? video.runThroughShortcut(shortcut: shortcut, optimiser: optimiser, allowLarger: false, aggressiveOptimisation: Defaults[.videoEncoder] == .slowHighQuality, source: optimiser.source) {
                mainActor {
                    optimiser.url = newVideo.path.url
                    optimiser.finish(oldBytes: optimiser.oldBytes, newBytes: newVideo.path.fileSize() ?? optimiser.newBytes, oldSize: optimiser.oldSize, newSize: newVideo.size)
                }
            } else {
                mainActor {
                    optimiser.running = false
                }
            }
        }

    }

    func processImage(shortcut: Shortcut) {
        DispatchQueue.global().async {
            guard let image = optimiser.image else {
                return
            }
            if let newImage = try? image.runThroughShortcut(shortcut: shortcut, optimiser: optimiser, allowLarger: false, aggressiveOptimisation: image.type.aggressiveOptimisation, source: optimiser.source) {
                mainActor {
                    optimiser.url = newImage.path.url
                    optimiser.finish(oldBytes: optimiser.oldBytes, newBytes: newImage.path.fileSize() ?? optimiser.newBytes, oldSize: optimiser.oldSize, newSize: newImage.size)
                }
            } else {
                mainActor {
                    optimiser.running = false
                }
            }
        }

    }

}

struct DownscaleMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        let factors = Array(stride(from: 0.9, to: 0.0, by: -0.1))
        Button("Restore original size (100%)") {
            optimiser.downscale(toFactor: 1)
        }.disabled(optimiser.downscaleFactor == 1)
        Section("Downscale resolution to") {
            ForEach(factors, id: \.self) { factor in
                Button("\((factor * 100).intround)%") {
                    optimiser.downscale(toFactor: factor)
                }.disabled(factor == optimiser.downscaleFactor)
            }
        }
    }
}

struct CompressionMenu: View {
    @ObservedObject var optimiser: Optimiser

    // Same round factor steps the compression slider snaps to, as discrete menu entries.
    // Higher factor = more compression = smaller file.
    let factors = Array(stride(from: 10, through: 90, by: 10))

    var body: some View {
        let current = currentCompressionQuality(for: optimiser)

        if optimiser.type.isImage {
            Button("Adaptive (best size and quality)") {
                optimiser.reoptimise(compression: CompressionQuality(tier: .adaptive, factor: 5))
            }.disabled(current.tier == .adaptive)
            Section("Compression factor") {
                ForEach(factors, id: \.self) { factor in
                    Button("\(factor)%") {
                        optimiser.reoptimise(compression: CompressionQuality(tier: .custom, factor: factor))
                    }.disabled(current.tier == .custom && current.factor == factor)
                }
            }
        } else if optimiser.type.isVideo {
            Button("Lossless") {
                optimiser.reoptimise(compression: CompressionQuality(tier: .lossless, factor: 5))
            }.disabled(current.tier == .lossless)
            Section("Compression factor") {
                ForEach(factors, id: \.self) { factor in
                    Button("\(factor)%") {
                        optimiser.reoptimise(compression: CompressionQuality(tier: .smaller, factor: factor))
                    }.disabled(current.tier == .smaller && current.factor == factor)
                }
            }
        }
    }
}

struct LowerBitrateMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        let format = Defaults[.audioFormat]
        let bitrates = format.allowedBitrates
        let currentBitrate = optimiser.audioBitrateOverride ?? Defaults[.audioBitrate]

        ForEach(bitrates, id: \.self) { bitrate in
            Button("\(bitrate) kbps") {
                optimiser.lowerBitrate(to: bitrate)
            }.disabled(bitrate == currentBitrate)
        }
    }
}

struct BatchBitrateMenu: View {
    var optimisers: [Optimiser]

    var body: some View {
        let format = Defaults[.audioFormat]
        let bitrates = format.allowedBitrates

        ForEach(bitrates, id: \.self) { bitrate in
            Button("\(bitrate) kbps") {
                for optimiser in optimisers {
                    optimiser.lowerBitrate(to: bitrate)
                }
                SM.selection = []
            }.disabled(optimisers.allSatisfy { ($0.audioBitrateOverride ?? Defaults[.audioBitrate]) == bitrate })
        }
    }
}

struct BatchDownscaleMenu: View {
    var optimisers: [Optimiser]

    var body: some View {
        let factors = Array(stride(from: 0.9, to: 0.0, by: -0.1))
        Button("Restore original size (100%)") {
            for optimiser in optimisers {
                optimiser.downscale(toFactor: 1)
            }
            SM.selection = []
        }.disabled(optimisers.allSatisfy { $0.downscaleFactor == 1 })
        Section("Downscale resolution to") {
            ForEach(factors, id: \.self) { factor in
                Button("\((factor * 100).intround)%") {
                    for optimiser in optimisers {
                        optimiser.downscale(toFactor: factor)
                    }
                    SM.selection = []
                }.disabled(optimisers.allSatisfy { $0.downscaleFactor == factor })
            }
        }
    }
}

struct ConvertToGIFMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        let widths = [1920, 1280, 800, 640, 480, 320]
        let frames = [24, 20, 15, 10]
        ForEach(frames, id: \.self) { fps in
            Section("\(fps)fps") {
                ForEach(widths, id: \.self) { width in
                    Button("\(width)px max width @ \(fps)fps\(fps == 20 && width == 800 ? " (recommended)" : "")") {
                        convertToGIF(width: width, fps: fps)
                    }
                }
            }
        }
    }

    func convertToGIF(width: Int, fps: Int) {
        videoOptimisationQueue.addOperation {
            guard let video = optimiser.video else {
                return
            }

            do {
                mainActor {
                    optimiser.remover = nil
                    optimiser.inRemoval = false
                    optimiser.stop(remove: false)

                    optimiser.running = true
                    optimiser.progress.completedUnitCount = 0
                    optimiser.isOriginal = false
                    optimiser.operation = "Converting to GIF"
                }

                let gif = try video.convertToGIF(optimiser: optimiser, maxWidth: width, fps: fps)

                mainActor {
                    optimiser.finish(oldBytes: optimiser.oldBytes, newBytes: gif.path.fileSize() ?? optimiser.newBytes, oldSize: optimiser.oldSize, newSize: gif.size)
                }
            } catch {
                mainActor {
                    optimiser.finish(error: error.localizedDescription)
                }
            }
        }
    }

}

@MainActor func convertSinglePagePDFToImage(optimiser: Optimiser, pdf: PDF, format: NSBitmapImageRep.FileType) {
    let ext = format == .png ? "png" : "jpg"
    guard let imageData = pdf.renderPage(pageIndex: 0, format: format) else {
        optimiser.overlayMessage = "Render failed"
        return
    }

    let stem = pdf.path.lastComponent?.stem ?? "page"
    let outputPath = FilePath.images.appending("\(stem).\(ext)")
    let fm = FileManager.default
    try? fm.createDirectory(atPath: FilePath.images.string, withIntermediateDirectories: true)

    guard fm.createFile(atPath: outputPath.string, contents: imageData) else {
        optimiser.overlayMessage = "Save failed"
        return
    }

    let id = "pdf-to-image-\(Int(Date().timeIntervalSince1970))"
    guard let img = Image(path: outputPath, retinaDownscaled: false) else {
        optimiser.overlayMessage = "Convert failed"
        return
    }
    Task {
        try? await runImagePipeline(img, actions: [.optimise], id: id, allowLarger: true, hideFloatingResult: false, source: optimiser.source)
    }
}

@MainActor func extractPDFPagesAsImages(optimiser: Optimiser, pdf: PDF, format: NSBitmapImageRep.FileType) {
    let ext = format == .png ? "png" : "jpg"
    let formatName = format == .png ? "PNGs" : "JPEGs"
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Save Pages"
    panel.message = "Choose a folder to save \(pdf.pageCount) pages as optimised \(formatName)"
    panel.level = .modalPanel
    NSApp.activate(ignoringOtherApps: true)

    panel.begin { response in
        guard response == .OK, let folderURL = panel.url else { return }

        let stem = pdf.path.lastComponent?.stem ?? "page"
        let pageCount = pdf.pageCount
        let fm = FileManager.default
        let originalOldBytes = optimiser.oldBytes

        mainActor {
            optimiser.running = true
            optimiser.progress = Progress(totalUnitCount: Int64(pageCount))
            optimiser.progress.completedUnitCount = 0
            optimiser.operation = "Saving pages"
        }

        let batchSize = ProcessInfo.processInfo.activeProcessorCount

        DispatchQueue.global().async {
            var totalSavedBytes = 0
            let lock = NSLock()

            for batchStart in stride(from: 0, to: pageCount, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, pageCount)
                let group = DispatchGroup()
                for i in batchStart ..< batchEnd {
                    group.enter()
                    DispatchQueue.global().async {
                        defer {
                            mainActor { optimiser.progress.completedUnitCount += 1 }
                            group.leave()
                        }

                        guard let imageData = pdf.renderPage(pageIndex: i, format: format) else { return }

                        let filename = "\(stem)-page\(i + 1).\(ext)"
                        let outputURL = folderURL.appendingPathComponent(filename)
                        fm.createFile(atPath: outputURL.path, contents: imageData)

                        let outputPath = FilePath(outputURL.path)
                        var bytes = imageData.count
                        if let img = Image(path: outputPath, retinaDownscaled: false) {
                            let optimised = try? img.optimise(optimiser: optimiser, allowLarger: true, aggressiveOptimisation: img.type.aggressiveOptimisation, adaptiveSize: false)
                            if let optimised, let newPath = try? optimised.path.copy(to: outputPath, force: true) {
                                bytes = newPath.fileSize() ?? bytes
                            } else {
                                bytes = outputPath.fileSize() ?? bytes
                            }
                        }

                        lock.lock()
                        totalSavedBytes += bytes
                        lock.unlock()
                    }
                }
                group.wait()
            }

            mainActor {
                optimiser.finish(oldBytes: originalOldBytes, newBytes: totalSavedBytes)
                optimiser.overlayMessage = "Saved \(pageCount) pages"
                NSWorkspace.shared.open(folderURL)
            }
        }
    }
}

struct ReoptimiseWithEncoderMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        ForEach(VideoEncoder.allCases, id: \.self) { encoder in
            Button("\(encoder.name)") {
                optimiser.reoptimiseWithEncoder(encoder)
            }
        }
    }
}

struct ChangePlaybackSpeedMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        let changePlaybackSpeedFactors = [1.25, 1.5, 1.75] + Array(stride(from: 2.0, to: 10.1, by: 1.0))
        let slowDownFactors = [0.25, 0.5, 0.75]

        Button("Restore normal playback speed (1x)") {
            optimiser.changePlaybackSpeed(byFactor: 1)
        }.disabled(optimiser.changePlaybackSpeedFactor == 1)

        Section("Playback speed up") {
            ForEach(changePlaybackSpeedFactors, id: \.self) { factor in
                Button("\(factor < 2 ? String(format: "%.2f", factor) : factor.i.s)x") {
                    optimiser.changePlaybackSpeed(byFactor: factor)
                }.disabled(factor == optimiser.changePlaybackSpeedFactor)
            }
        }
        Section("Playback slow down") {
            ForEach(slowDownFactors, id: \.self) { factor in
                Button("\(String(format: "%.2f", factor))x") {
                    optimiser.changePlaybackSpeed(byFactor: factor)
                }.disabled(factor == optimiser.changePlaybackSpeedFactor)
            }
        }
    }
}

struct BatchChangePlaybackSpeedMenu: View {
    var optimisers: [Optimiser]

    var body: some View {
        let changePlaybackSpeedFactors = [1.25, 1.5, 1.75] + Array(stride(from: 2.0, to: 10.1, by: 1.0))
        let slowDownFactors = [0.25, 0.5, 0.75]

        Button("Restore normal playback speed (1x)") {
            for optimiser in optimisers {
                optimiser.changePlaybackSpeed(byFactor: 1)
            }
            SM.selection = []
        }.disabled(optimisers.allSatisfy { $0.changePlaybackSpeedFactor == 1 })

        Section("Playback speed up") {
            ForEach(changePlaybackSpeedFactors, id: \.self) { factor in
                Button("\(factor < 2 ? String(format: "%.2f", factor) : factor.i.s)x") {
                    for optimiser in optimisers {
                        optimiser.changePlaybackSpeed(byFactor: factor)
                    }
                    SM.selection = []
                }.disabled(optimisers.allSatisfy { $0.changePlaybackSpeedFactor == factor })
            }
        }
        Section("Playback slow down") {
            ForEach(slowDownFactors, id: \.self) { factor in
                Button("\(String(format: "%.2f", factor))x") {
                    for optimiser in optimisers {
                        optimiser.changePlaybackSpeed(byFactor: factor)
                    }
                    SM.selection = []
                }.disabled(optimisers.allSatisfy { $0.changePlaybackSpeedFactor == factor })
            }
        }
    }
}
