//
//  ActionRequestHandler.swift
//  FinderOptimiser
//
//  Created by Alin Panaitiu on 24.09.2023.
//

import Cocoa
import Combine
import Foundation
import System
import UniformTypeIdentifiers

extension NSExtensionContext: @unchecked Sendable {}
extension NSItemProvider: @unchecked Sendable {}

let CLOP_APP: URL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    var requestSender: RequestSender!

    func beginRequest(with context: NSExtensionContext) {
        precondition(context.inputItems.count == 1)
        guard let inputItem = context.inputItems[0] as? NSExtensionItem else {
            preconditionFailure("Expected an extension item")
        }
        guard let inputAttachments = inputItem.attachments else {
            preconditionFailure("Expected a valid array of attachments")
        }
        precondition(inputAttachments.isEmpty == false, "Expected at least one attachment")

        guard isClopRunning() else {
            context.open(CLOP_APP) { clopRunning in
                guard clopRunning else {
                    context.cancelRequest(withError: "Clop is not running".err)
                    return
                }
                self.processAttachments(context, inputAttachments)
            }
            return
        }
        processAttachments(context, inputAttachments)
    }

    func processAttachments(_ context: NSExtensionContext, _ attachments: [NSItemProvider]) {
        requestSender = RequestSender(context: context, attachmentsToProcess: attachments.count)

        for attachment in attachments {
            guard let type = attachment.registeredContentTypes.first, type.isSubtype(of: .image) || type.isSubtype(of: .movie) || type.isSubtype(of: .video) || type == .pdf else {
                Task.init { await self.requestSender.skipAttachment(attachment) }
                continue
            }

            let _ = attachment.loadFileRepresentation(for: type, openInPlace: true) { url, inPlace, error in
                guard let url else {
                    Task.init { await self.requestSender.skipAttachment(attachment) }
                    return
                }

                let coordinator = NSFileCoordinator()
                coordinator.coordinate(readingItemAt: url, options: [], error: nil) { url in
                    guard let itemReplacementDirectory = try? FileManager.default.url(
                        for: .itemReplacementDirectory, in: .userDomainMask,
                        appropriateFor: URL(fileURLWithPath: NSHomeDirectory()), create: true
                    ) else { return }

                    let _tempURL = itemReplacementDirectory.appendingPathComponent(url.lastPathComponent)
                    let tempURL = FileManager.default.fileExists(atPath: _tempURL.path)
                        ? itemReplacementDirectory.appendingPathComponent("\(Int.random(in: 10 ... 10000))-\(url.lastPathComponent)")
                        : _tempURL

                    try? FileManager.default.removeItem(at: tempURL)
                    try? FileManager.default.copyItem(at: url, to: tempURL)

                    Task.init { await self.requestSender.add(tempURL, type: type, attachment: attachment, originalURL: url) }
                }
            }
        }
        log.debug("Waiting for \(attachments.count) attachments to be processed")
    }
}

actor RequestSender {
    let attachmentsToProcess: Int
    let context: NSExtensionContext

    init(context: NSExtensionContext, attachmentsToProcess: Int) {
        self.context = context
        self.attachmentsToProcess = attachmentsToProcess
    }

    private var sent = false
    private var processedURLs = 0 {
        didSet {
            guard processedURLs == urls.count else { return }

            // let outputItem = NSExtensionItem()
            // outputItem.attachments = outputAttachments.map { att in
            //     if let (url, att) = att as? (URL, NSItemProvider), let response = responses[url] {
            //         return NSItemProvider(contentsOf: response.path.url) ?? att
            //     }
            //     return att as! NSItemProvider
            // }
            // context.completeRequest(returningItems: [outputItem], completionHandler: nil)
        }
    }
    private var processedAttachments = 0 {
        didSet {
            if processedAttachments == attachmentsToProcess {
                guard !urls.isEmpty else {
                    context.cancelRequest(withError: "File type not supported".err)
                    return
                }
                send()
                complete()
            }
        }
    }
    private var urls: [URL] = []
    private var originalUrls: [URL: URL] = [:]
    private var outputAttachments: [NSItemProvider] = []
    private var observers: [AnyCancellable] = []

    func complete() {
        log.debug("Completing request with \(outputAttachments.count) attachments")

        let outputItem = NSExtensionItem()
        outputItem.attachments = outputAttachments

        context.completeRequest(returningItems: [outputItem]) { expired in
            guard expired else { return }

            log.error("Optimisation request was cancelled")
            awaitSync {
                let ids = await self.urls.map(\.absoluteString)
                let req = StopOptimisationRequest(ids: ids, remove: true)
                try? OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
                exit(0)
            }
        }
    }

    func skipAttachment(_ attachment: NSItemProvider) {
        log.debug("Skipping attachment \(attachment.registeredContentTypes.first?.identifier ?? "unknown")")

        outputAttachments.append(attachment)
        processedAttachments += 1
    }

    func observe(_ url: URL, type: UTType, completion: @escaping (URL?, Bool, Error?) -> Void) {
        if let response = responses[url], let urlType = response.path.url.fetchFileType() {
            guard urlType == type else {
                completion(nil, false, "Wrong type".err)
                return
            }

            log.debug("Item \(url) of type \(type.identifier) is ready, calling completion handler")
            completion(response.path.url, false, nil)
            return
        }
        if let resp = errors[url] {
            log.debug("Item \(url) failed, calling completion handler")
            completion(nil, false, resp.error.err)
            return
        }

        log.debug("Observing \(url) for file completion")

        lastResponse.sink { resp in
            guard resp.forURL == url, let urlType = resp.path.url.fetchFileType() else {
                return
            }
            guard urlType == type else {
                completion(nil, false, "Wrong type".err)
                return
            }
            log.debug("Received '\(resp.path)' of type \(type.identifier) for item \(url), calling completion handler")

            completion(url, false, nil)
            // self.processedURLs += 1
        }.store(in: &observers)

        lastResponseError.sink { resp in
            guard resp.forURL == url else { return }
            log.debug("Failed with '\(resp.error)' for item \(url), calling completion handler")

            completion(nil, false, resp.error.err)
            // self.processedURLs += 1
        }.store(in: &observers)
    }

    func add(_ url: URL, type: UTType, attachment: NSItemProvider, originalURL: URL? = nil) {
        log.debug("Adding \(url) of type \(type.identifier) for processing")

        urls.append(url)
        startProgressListener(url: url)

        let types = if type.isSubtype(of: .movie), type != .mpeg4Movie {
            [type, .mpeg4Movie]
        } else if type.isSubtype(of: .image), ![UTType.jpeg, UTType.png].contains(type) {
            [type, .jpeg, .png]
        } else {
            [type]
        }

        let provider = NSItemProvider()
        for type in types {
            provider.registerFileRepresentation(
                forTypeIdentifier: type.identifier, fileOptions: [.openInPlace],
                visibility: .all, loadHandler: { completion in
                    Task.init {
                        await self.observe(url, type: type, completion: completion)
                    }
                    log.debug("Loading file representation of type \(type) for optimised \(url)")
                    return DispatchQueue.main.sync { progressProxies[url] }
                }
            )
        }

        if let originalURL {
            originalUrls[url] = originalURL
        }

        // outputAttachments.append((url, attachment))
        outputAttachments.append(provider)
        processedAttachments += 1
    }

    func markDone(response: OptimisationResponse) {
        log.debug("Got response \(response.jsonString) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        responses[response.forURL] = response
        lastResponse.send(response)
        processedURLs += 1
    }
    func markError(response: OptimisationResponseError) {
        log.debug("Got error response \(response.error) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        errors[response.forURL] = response
        lastResponseError.send(response)
        processedURLs += 1
    }

    func send() {
        guard !sent else { return }
        sent = true

        log.debug("Sending optimisation request with \(urls.count) urls")
        let req = OptimisationRequest(
            id: String(Int.random(in: 1000 ... 100_000)),
            urls: urls.compactMap { $0 },
            originalUrls: originalUrls,
            size: nil,
            downscaleFactor: nil,
            speedUpFactor: nil,
            hideFloatingResult: false,
            copyToClipboard: false,
            aggressiveOptimisation: false,
            source: "finder"
        )
        do {
            try OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
        } catch {
            log.error(error.localizedDescription)
            context.cancelRequest(withError: error)
            return
        }

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

    private var lastResponse = PassthroughSubject<OptimisationResponse, Never>()
    private var lastResponseError = PassthroughSubject<OptimisationResponseError, Never>()
    private var responses: [URL: OptimisationResponse] = [:]
    private var errors: [URL: OptimisationResponseError] = [:]

    private var progressSubscribers: [URL: Any] = [:]

    func removeProgressSubscriber(url: URL) {
        log.debug("Removing progress subscriber for \(url)")

        if let sub = progressSubscribers.removeValue(forKey: url) {
            Progress.removeSubscriber(sub)
        }
        DispatchQueue.main.async { progressProxies.removeValue(forKey: url) }
    }

    func startProgressListener(url: URL) {
        let sub = Progress.addSubscriber(forFileURL: url) { progress in
            log.debug("Subscribed to Progress for \(url): \(progress.fractionCompleted)")

            DispatchQueue.main.async { progressProxies[url] = progress }
            return {
                Task.init { await self.removeProgressSubscriber(url: url) }
            }
        }
        progressSubscribers[url] = sub
    }
}

var progressProxies: [URL: Progress] = [:]
var responsesThread: Thread?

extension FilePath {
    var url: URL { URL(filePath: self)! }
}

extension String {
    var url: URL { URL(fileURLWithPath: self) }
}
