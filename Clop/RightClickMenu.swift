//
//  RightClickMenu.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.09.2023.
//

import Defaults
import Foundation
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
        Button(optimiser.running ? "Stop" : "Close") {
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
                optimiser.hotkeyMessage = "Copied"
            }
            .keyboardShortcut("c")

            Button("Show in Finder") {
                optimiser.showInFinder()
            }
            .keyboardShortcut("f")

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
            Button("Downscale") {
                optimiser.downscale()
            }
            .keyboardShortcut("-")
            .disabled(optimiser.downscaleFactor <= 0.1)

            Menu("    to specific factor") {
                DownscaleMenu(optimiser: optimiser)
            }

            if optimiser.canSpeedUp() {
                Button("Speed up") {
                    optimiser.speedUp()
                }
                .keyboardShortcut("x")
                .disabled(optimiser.speedUpFactor >= 10)

                Menu("    by specific factor") {
                    SpeedUpMenu(optimiser: optimiser)
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

            Menu("Run workflow") {
                WorkflowMenu(optimiser: optimiser)
            }
        }
    }
}

struct WorkflowMenu: View {
    @ObservedObject var optimiser: Optimiser
    @State var shortcuts: [Shortcut]?

    var body: some View {
        if let shortcuts {
            ForEach(shortcuts) { shortcut in
                Button(shortcut.name) {
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
        } else {
            Text("Loading...").disabled(true)
                .onAppear {
                    DispatchQueue.global().async {
                        guard let shortcuts = getShortcuts() else {
                            return
                        }
                        mainActor {
                            self.shortcuts = shortcuts
                        }
                    }
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

struct SpeedUpMenu: View {
    @ObservedObject var optimiser: Optimiser

    var body: some View {
        let speedUpFactors = [1.25, 1.5, 1.75] + Array(stride(from: 2.0, to: 10.1, by: 1.0))
        let slowDownFactors = [0.25, 0.5, 0.75]

        Button("Restore normal playback speed (1x)") {
            optimiser.speedUp(byFactor: 1)
        }.disabled(optimiser.speedUpFactor == 1)

        Section("Playback speed up") {
            ForEach(speedUpFactors, id: \.self) { factor in
                Button("\(factor < 2 ? String(format: "%.2f", factor) : factor.i.s)x") {
                    optimiser.speedUp(byFactor: factor)
                }.disabled(factor == optimiser.speedUpFactor)
            }
        }
        Section("Playback slow down") {
            ForEach(slowDownFactors, id: \.self) { factor in
                Button("\(String(format: "%.2f", factor))x") {
                    optimiser.speedUp(byFactor: factor)
                }.disabled(factor == optimiser.speedUpFactor)
            }
        }
    }
}
