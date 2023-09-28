//
//  ActionRequestHandler.swift
//  FinderOptimiser
//
//  Created by Alin Panaitiu on 24.09.2023.
//

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
                    var tempURL = URL.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        tempURL = URL.temporaryDirectory.appendingPathComponent("\(Int.random(in: 10 ... 10000))-\(url.lastPathComponent)")
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                    try? FileManager.default.copyItem(at: url, to: tempURL)

                    Task.init { await self.requestSender.add(tempURL, type: type, attachment: attachment) }
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

            let outputItem = NSExtensionItem()
            outputItem.attachments = outputAttachments.map { att in
                if let (url, att) = att as? (URL, NSItemProvider), let response = responses[url] {
                    return NSItemProvider(contentsOf: response.path.url) ?? att
                }
                return att as! NSItemProvider
            }
            context.completeRequest(returningItems: [outputItem], completionHandler: nil)
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
            }
        }
    }
    private var urls: [URL] = []
    private var outputAttachments: [Any] = []
    private var observers: [AnyCancellable] = []

//    func complete() {
//        let outputItem = NSExtensionItem()
//        outputItem.attachments = outputAttachments
//        context.completeRequest(returningItems: [outputItem]) { expired in
//            guard !expired else { return }
//
//            log.error("Optimisation request was cancelled")
//            Task.init {
//                let ids = await self.urls.map(\.absoluteString)
//                let req = StopOptimisationRequest(ids: ids, remove: true)
//                try? OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
//                exit(0)
//            }
//        }
//    }

    func skipAttachment(_ attachment: NSItemProvider) {
        log.debug("Skipping attachment \(attachment.registeredContentTypes.first?.identifier ?? "unknown")")

        outputAttachments.append(attachment)
        processedAttachments += 1
    }

//    func observe(_ url: URL, completion: @escaping (URL?, Bool, Error?) -> Void) {
//        log.debug("Observing \(url) for file completion")
//
//        if let response = responses[url] {
//            completion(response.path.url, true, nil)
//            return
//        }
//        if let resp = errors[url] {
//            completion(nil, false, resp.error.err)
//            return
//        }
//
//        lastResponse.sink { resp in
//            guard resp.forURL == url else { return }
//            completion(url, true, nil)
//            self.processedURLs += 1
//        }.store(in: &observers)
//
//        lastResponseError.sink { resp in
//            guard resp.forURL == url else { return }
//            completion(nil, false, resp.error.err)
//            self.processedURLs += 1
//        }.store(in: &observers)
//    }
//
//    func observe(_ url: URL, completion: @escaping (NSSecureCoding?, Error?) -> Void) {
//        log.debug("Observing \(url) for data completion")
//
//        if let resp = responses[url] {
//            if let data = FileManager.default.contents(atPath: resp.path) {
//                completion(data as NSData, nil)
//            } else {
//                completion(nil, "File not found".err)
//            }
//            return
//        }
//        if let resp = errors[url] {
//            completion(nil, resp.error.err)
//            return
//        }
//
//        lastResponse.sink { resp in
//            guard resp.forURL == url else { return }
//            if let data = FileManager.default.contents(atPath: url.path) {
//                completion(data as NSData, nil)
//            } else {
//                completion(nil, "File not found".err)
//            }
//            self.processedURLs += 1
//        }.store(in: &observers)
//
//        lastResponseError.sink { resp in
//            guard resp.forURL == url else { return }
//            completion(nil, resp.error.err)
//            self.processedURLs += 1
//        }.store(in: &observers)
//    }

    func add(_ url: URL, type: UTType, attachment: NSItemProvider) {
        log.debug("Adding \(url) of type \(type.identifier) for processing")

        urls.append(url)
        startProgressListener(url: url)

//        let provider = NSItemProvider()
//        provider.registerFileRepresentation(for: type, openInPlace: true) { completion in
//            Task.init {
//                await self.observe(url, completion: completion)
//            }
//            log.debug("Loading file representation for optimised \(url)")
//            return DispatchQueue.main.sync { progressProxies[url] }
//        }
//        provider.registerItem(forTypeIdentifier: type.identifier) { completion, expectedValueClass, options in
//            guard let completion else { return }
//            Task.init {
//                await self.observe(url, completion: completion)
//            }
//            log.debug("Loading file representation for optimised \(url)")
        ////            return DispatchQueue.main.sync { progressProxies[url] }
//        }

        outputAttachments.append((url, attachment))
        processedAttachments += 1
    }

    func markDone(response: OptimisationResponse) {
        log.debug("Got response \(response.jsonString) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        responses[response.forURL] = response
//        lastResponse.send(response)
        processedURLs += 1
    }
    func markError(response: OptimisationResponseError) {
        log.debug("Got error response \(response.error) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        errors[response.forURL] = response
//        lastResponseError.send(response)
        processedURLs += 1
    }

    func send() {
        guard !sent else { return }
        sent = true

        log.debug("Sending optimisation request with \(urls.count) urls")
        let req = OptimisationRequest(
            id: String(Int.random(in: 1000 ... 100_000)),
            urls: urls.compactMap { $0 },
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
        if let sub = progressSubscribers.removeValue(forKey: url) {
            Progress.removeSubscriber(sub)
        }
        DispatchQueue.main.async { progressProxies.removeValue(forKey: url) }
    }

    func startProgressListener(url: URL) {
        let sub = Progress.addSubscriber(forFileURL: url) { progress in
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
