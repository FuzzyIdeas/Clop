//
//  main.swift
//  ClopCLI
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import ArgumentParser
import Cocoa
import Foundation
import UniformTypeIdentifiers

let SIZE_REGEX = #/(\d+)[xX×](\d+)/#
let CLOP_APP: URL = {
    let u = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    return u.pathExtension == "app" ? u : URL(fileURLWithPath: "/Applications/Clop.app")
}()

var currentRequestIDs: [String] = []
func ensureAppIsRunning() {
    guard !isClopRunning() else {
        return
    }
    NSWorkspace.shared.open(CLOP_APP)
}

func isURLOptimisable(_ url: URL, type: UTType? = nil) -> Bool {
    guard url.isFileURL, let type = type ?? url.contentTypeResourceValue ?? url.fetchFileType() else {
        return true
    }
    return IMAGE_VIDEO_FORMATS.contains(type) || type == .pdf
}

struct Clop: ParsableCommand {
    struct Optimise: ParsableCommand {
        @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
        var gui = false

        @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Print progress to stderr")
        var progress = true

        @Flag(name: .long, help: "Process files and items in the background")
        var async = false

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation")
        var aggressive = false

        @Flag(name: .shortAndLong, help: "Optimise all files in subfolders (when using a folder as input)")
        var recursive = false

        @Flag(name: .shortAndLong, help: "Copy file to clipboard after optimisation")
        var copy = false

        @Flag(name: .shortAndLong, help: "Skips missing files and unreachable URLs")
        var skipErrors = false

        @Option(help: "Speeds up the video by a certain amount (1 means no change, 2 means twice as fast, 0.5 means 2x slower)")
        var speedUpFactor: Double? = nil

        @Option(help: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)")
        var downscaleFactor: Double? = nil

        @Option(help: "Downscales and crops the image, video or PDF to a specific size (e.g. 1200x630)\nExample: cropping an image from 100x120 to 50x50 will first downscale it to 50x60 and then crop it to 50x50")
        var crop: String? = nil

        var cropSize: NSSize?
        var urls: [URL] = []

        @Argument(help: "Images, videos, PDFs or URLs to optimise")
        var items: [String] = []

        func getURLsFromFolder(_ folder: URL) -> [URL] {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey, .contentTypeKey],
                options: [.skipsPackageDescendants]
            ) else {
                return []
            }

            var urls: [URL] = []

            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey, .contentTypeKey]),
                      let isDirectory = resourceValues.isDirectory, let isRegularFile = resourceValues.isRegularFile, let name = resourceValues.name
                else {
                    continue
                }

                if isDirectory {
                    if !recursive || name.hasPrefix(".") || ["node_modules", ".git"].contains(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if !isRegularFile {
                    continue
                }

                if !isURLOptimisable(fileURL, type: resourceValues.contentType) {
                    continue
                }
                urls.append(fileURL)
            }
            return urls
        }

        mutating func validate() throws {
            var dirs: [URL] = []
            urls = try items.compactMap { item in
                let url = item.contains(":") ? (URL(string: item) ?? URL(fileURLWithPath: item)) : URL(fileURLWithPath: item)
                var isDir = ObjCBool(false)

                if url.isFileURL, !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if skipErrors {
                        return nil
                    }

                    throw ValidationError("File \(url.path) does not exist")
                }

                if isDir.boolValue {
                    dirs.append(url)
                    return nil
                }
                return url
            }.filter { isURLOptimisable($0) }
            urls += dirs.flatMap(getURLsFromFolder)

            if let crop {
                if let match = try? SIZE_REGEX.firstMatch(in: crop) {
                    let width = Int(match.1)!
                    let height = Int(match.2)!
                    cropSize = NSSize(width: width, height: height)
                } else if let size = Int(crop) {
                    cropSize = NSSize(width: size, height: size)
                } else {
                    throw ValidationError("Invalid crop size: \(crop)")
                }
            }

            ensureAppIsRunning()
            sleep(1)

            guard isClopRunning() else {
                Clop.exit(withError: CLIError.appNotRunning)
            }
        }

        mutating func run() throws {
            let urls = urls
            let showProgress = progress

            if !async {
                progressPrinter = ProgressPrinter(urls: urls)
                Task.init {
                    await progressPrinter!.startResponsesThread()

                    guard showProgress else { return }
                    await progressPrinter!.printProgress()
                }
            }

            currentRequestIDs = urls.map(\.absoluteString)
            let req = OptimisationRequest(
                id: String(Int.random(in: 1000 ... 100_000)),
                urls: urls,
                size: cropSize,
                downscaleFactor: downscaleFactor,
                speedUpFactor: speedUpFactor,
                hideFloatingResult: !gui,
                copyToClipboard: copy,
                aggressiveOptimisation: aggressive,
                source: "cli"
            )
            signal(SIGINT, stopCurrentRequests(_:))
            signal(SIGTERM, stopCurrentRequests(_:))

            if progress, !async, let progressPrinter {
                for url in urls where url.isFileURL {
                    Task.init { await progressPrinter.startProgressListener(url: url) }
                }
            }

            guard !async else {
                try OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
                print("Queued \(urls.count) items for optimisation")
                if !gui {
                    printerr("Use the `--gui` flag to see progress")
                }
                Clop.exit()
            }

            let respData = try OPTIMISATION_PORT.sendAndWait(data: req.jsonData)
            guard respData != nil else {
                Clop.exit(withError: CLIError.optimisationError)
            }

            awaitSync {
                await progressPrinter!.waitUntilDone()

                if showProgress {
                    await progressPrinter!.printProgress()
                    fflush(stderr)
                }
                await progressPrinter!.printResults()
            }
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Clop",
        subcommands: [
            Optimise.self,
        ]
    )
}

var progressPrinter: ProgressPrinter?

struct CLIResult: Codable {
    let done: [OptimisationResponse]
    let failed: [OptimisationResponseError]
}

actor ProgressPrinter {
    init(urls: [URL]) {
        urlsToProcess = urls
    }

    var urlsToProcess: [URL]

    var responses: [URL: OptimisationResponse] = [:]
    var errors: [URL: OptimisationResponseError] = [:]

    var progressFractionObserver: [URL: NSKeyValueObservation] = [:]
    var progressSubscribers: [URL: Any] = [:]
    var progressProxies: [URL: Progress] = [:]

    func markDone(response: OptimisationResponse) {
        log.debug("Got response \(response.jsonString) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        responses[response.forURL] = response
    }

    func markError(response: OptimisationResponseError) {
        log.debug("Got error response \(response.error) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        errors[response.forURL] = response
    }

    func addProgressSubscriber(url: URL, progress: Progress) {
        progressFractionObserver[url] = progress.observe(\.fractionCompleted) { _, change in
            Task.init { await self.printProgress() }
        }
        progressProxies[url] = progress
    }

    func removeProgressSubscriber(url: URL) {
        if let sub = progressSubscribers.removeValue(forKey: url) {
            Progress.removeSubscriber(sub)
        }
        progressProxies.removeValue(forKey: url)
        if let observer = progressFractionObserver[url] {
            observer.invalidate()
        }
        progressFractionObserver.removeValue(forKey: url)
        printProgress()
    }

    func startProgressListener(url: URL) {
        let sub = Progress.addSubscriber(forFileURL: url) { progress in
            Task.init { await self.addProgressSubscriber(url: url, progress: progress) }
            return {
                Task.init { await self.removeProgressSubscriber(url: url) }
            }
        }
        progressSubscribers[url] = sub
    }

    var lastPrintedLinesCount = 0

    func printProgress() {
        printerr([String](repeating: "\(LINE_UP)\(LINE_CLEAR)", count: lastPrintedLinesCount).joined(separator: ""), terminator: "")

        let done = responses.count
        let failed = errors.count
        let total = urlsToProcess.count

        lastPrintedLinesCount = progressProxies.count + 1
        printerr("Processed \(done + failed) of \(total) | Success: \(done) | Failed: \(failed)")

        for (url, progress) in progressProxies {
            let progressInt = Int(round(progress.fractionCompleted * 100))
            let progressBarStr = String(repeating: "█", count: Int(progress.fractionCompleted * 20)) + String(repeating: "░", count: 20 - Int(progress.fractionCompleted * 20))
            var itemStr = (url.isFileURL ? url.path : url.absoluteString)
            if itemStr.count > 50 {
                itemStr = "..." + itemStr.suffix(40)
            }
            if let desc = progress.localizedAdditionalDescription {
                printerr("\(itemStr): \(desc) \(progressBarStr) (\(progressInt)%)")
            } else {
                printerr("\(itemStr): \(progressBarStr) \(progressInt)%")
            }
        }
    }

    func waitUntilDone() async {
        while responses.count + errors.count < urlsToProcess.count {
            try! await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func printResults() {
        let result = CLIResult(done: responses.values.sorted { $0.forURL.path < $1.forURL.path }, failed: errors.values.sorted { $0.forURL.path < $1.forURL.path })
        print(result.jsonString)
    }

    func startResponsesThread() {
        responsesThread = Thread {
            OPTIMISATION_CLI_RESPONSE_PORT.listen { data in
                log.debug("Received optimisation response: \(data?.count ?? 0) bytes")

                guard let data else {
                    return nil
                }
                if let resp = OptimisationResponse.from(data) {
                    Task.init { await self.markDone(response: resp) }
                }
                if let resp = OptimisationResponseError.from(data) {
                    Task.init { await self.markError(response: resp) }
                }
                return nil
            }
            RunLoop.current.run()
        }
        responsesThread?.start()
    }
}

let LINE_UP = "\u{1B}[1A"
let LINE_CLEAR = "\u{1B}[2K"
var responsesThread: Thread?

enum CLIError: Error {
    case optimisationError
    case appNotRunning
}

func stopCurrentRequests(_ signal: Int32) {
    let req = StopOptimisationRequest(ids: currentRequestIDs, remove: false)
    try? OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
    Clop.exit()
}

Clop.main()
