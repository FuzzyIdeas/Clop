//
//  main.swift
//  ClopCLI
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import ArgumentParser
import Cocoa
import Foundation

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

struct Clop: ParsableCommand {
    struct Optimise: ParsableCommand {
        @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
        var gui = false

        @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Print progress to stderr")
        var progress = true

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation")
        var aggressive = false

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

        mutating func validate() throws {
            urls = try items.map { item in
                let url = item.contains(":") ? (URL(string: item) ?? URL(fileURLWithPath: item)) : URL(fileURLWithPath: item)
                if !skipErrors, url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
                    throw ValidationError("File \(url.path) does not exist")
                }
                return url
            }

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

            if progress {
                progressPrinter = ProgressPrinter(urls: urls)
                Task.init {
                    await progressPrinter!.startResponsesThread()
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

            if progress, let progressPrinter {
                for url in urls where url.isFileURL {
                    Task.init { await progressPrinter.startProgressListener(url: url) }
                }
            }

            let respData = try OPTIMISATION_PORT.sendAndWait(data: req.jsonData)
            guard let respData, let responses = [OptimisationResponse].from(respData) else {
                Clop.exit(withError: CLIError.optimisationError)
            }

            if progress, let progressPrinter {
                awaitSync { await progressPrinter.printProgress() }
            }
            print(responses.jsonString)
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
            let progressStr = String(format: "%.2f", progress.fractionCompleted * 100)
            if let desc = progress.localizedAdditionalDescription {
                printerr("\(url.isFileURL ? url.path : url.absoluteString): \(desc) (\(progressStr)%)")
            } else {
                printerr("\(url.isFileURL ? url.path : url.absoluteString): \(progressStr)%")
            }
        }
    }

    func startResponsesThread() {
        responsesThread = Thread {
            OPTIMISATION_RESPONSE_PORT.listen { data in
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
