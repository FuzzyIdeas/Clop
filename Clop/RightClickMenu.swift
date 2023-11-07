//
//  RightClickMenu.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.09.2023.
//

import Defaults
import Foundation
import Lowtech
import SwiftUI

struct OpenWithMenuView: View {
    let fileURL: URL

    var body: some View {
        Menu("Open with...") {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL).compactMap { Bundle(url: $0) }
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

        Button("Restore original") {
            optimiser.restoreOriginal()
        }
        .keyboardShortcut("z")
        .disabled(optimiser.isOriginal)

        Button("QuickLook") {
            optimiser.quicklook()
        }
        .keyboardShortcut(" ")

        if !optimiser.running {
            Divider()
            Menu("Downscale") {
                DownscaleMenu(optimiser: optimiser)
            }
            .disabled(optimiser.downscaleFactor <= 0.1)

            if optimiser.canChangePlaybackSpeed() {
                Menu("Change playback speed") {
                    ChangePlaybackSpeedMenu(optimiser: optimiser)
                }
                .disabled(optimiser.changePlaybackSpeedFactor >= 10)
            }

            if optimiser.type.isVideo {
                Menu("Convert to GIF") {
                    ConvertToGIFMenu(optimiser: optimiser)
                }
            }

            Button("Aggressive optimisation") {
                if optimiser.downscaleFactor < 1 {
                    optimiser.downscale(toFactor: optimiser.downscaleFactor, aggressiveOptimisation: true)
                } else {
                    optimiser.optimise(allowLarger: false, aggressiveOptimisation: true, fromOriginal: true)
                }
            }
            .keyboardShortcut("a")
            .disabled(optimiser.aggresive)

            Divider()

//            ShareMenu(optimiser: optimiser)

            Button("Upload with Dropshare") {
                optimiser.uploadWithDropshare()
            }
            .keyboardShortcut("u")

            Menu("Run workflow") {
                WorkflowMenu(optimiser: optimiser)
            }
        }
    }
}

struct BatchRightClickMenuView: View {
    @ObservedObject var sm = SM

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
        Menu("Downscale") {
            BatchDownscaleMenu(optimisers: optimisers)
        }
        .disabled(optimisers.allSatisfy { $0.downscaleFactor <= 0.1 })

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
        .disabled(optimisers.allSatisfy(\.aggresive))

        Divider()

        Button("Upload with Dropshare") {
            sm.uploadWithDropshare()
            sm.selection = []
        }
    }
}

struct ShortcutChoiceMenu: View {
    @ObservedObject var shortcutsManager = SHM
    @Environment(\.preview) var preview

    var onShortcutChosen: ((Shortcut) -> Void)? = nil

    var body: some View {
        if let shortcutsMap = shortcutsManager.shortcutsMap {
            if shortcutsMap.isEmpty {
                Text("Create a Shortcut in the Clop folder to have it appear here").disabled(true)
            } else {
                if let clopShortcuts = shortcutsMap["Clop"] {
                    shortcutList(clopShortcuts)
                } else {
                    Text("Create a Shortcut in the Clop folder to have it appear here").disabled(true)
                    let shorts = shortcutsMap.sorted { $0.key < $1.key }

                    ForEach(shorts, id: \.key) { folder, shortcuts in
                        Section(folder) { shortcutList(shortcuts) }
                    }
                }
            }
        } else {
            Text("Loading...")
                .disabled(true)
                .onAppear {
                    guard !preview else { return }
                    shortcutsManager.fetch()
                }
        }
    }

    @ViewBuilder func shortcutList(_ shortcuts: [Shortcut]) -> some View {
        if let onShortcutChosen {
            ForEach(shortcuts) { shortcut in
                Button(shortcut.name) { onShortcutChosen(shortcut) }
            }
        } else {
            ForEach(shortcuts) { shortcut in
                Text(shortcut.name).tag(shortcut as Shortcut?)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

}

struct WorkflowMenu: View {
    @ObservedObject var optimiser: Optimiser
    @ObservedObject var shortcutsManager = SHM

    var body: some View {
        ShortcutChoiceMenu { shortcut in
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
        .onChange(of: shortcutsManager.cacheIsValid) { cacheIsValid in
            if !cacheIsValid, OM.optimisers.contains(optimiser) {
                log.debug("Re-fetching Shortcuts from WorkflowMenu.onChange")
                shortcutsManager.fetch()
            }
        }
        .onAppear {
            if !shortcutsManager.cacheIsValid {
                log.debug("Re-fetching Shortcuts from WorkflowMenu.onAppear")
                shortcutsManager.fetch()
            }
        }
    }

    func processPDF(shortcut: Shortcut) {
        DispatchQueue.global().async {
            guard let pdf = optimiser.pdf else {
                return
            }
            if let newPDF = try? pdf.runThroughShortcut(shortcut: shortcut, optimiser: optimiser, allowLarger: false, aggressiveOptimisation: Defaults[.useAggresiveOptimisationMP4], source: optimiser.source) {
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
            if let newVideo = try? video.runThroughShortcut(shortcut: shortcut, optimiser: optimiser, allowLarger: false, aggressiveOptimisation: Defaults[.useAggresiveOptimisationMP4], source: optimiser.source) {
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
