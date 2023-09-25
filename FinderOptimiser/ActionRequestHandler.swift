//
//  ActionRequestHandler.swift
//  FinderOptimiser
//
//  Created by Alin Panaitiu on 24.09.2023.
//

import Foundation
import System

class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        precondition(context.inputItems.count == 1)
        guard let inputItem = context.inputItems[0] as? NSExtensionItem else {
            preconditionFailure("Expected an extension item")
        }
        guard let inputAttachments = inputItem.attachments else {
            preconditionFailure("Expected a valid array of attachments")
        }
        precondition(inputAttachments.isEmpty == false, "Expected at least one attachment")

        var outputAttachments: [NSItemProvider] = []
        let dispatchGroup = DispatchGroup()

        for attachment in inputAttachments {
            dispatchGroup.enter()

            attachment.loadInPlaceFileRepresentation(forTypeIdentifier: "public.image") { [unowned self] url, inPlace, error in
                defer { dispatchGroup.leave() }
                guard let url else {
                    if let error {
                        print(error)
                    } else {
                        preconditionFailure("Expected either a valid URL or an error.")
                    }
                    outputAttachments.append(attachment)
                    return
                }

                guard let itemProvider = optimise(url) else {
                    outputAttachments.append(attachment)
                    return
                }
                outputAttachments.append(itemProvider)
            }
        }

        dispatchGroup.notify(queue: DispatchQueue.main) {
            let outputItem = NSExtensionItem()
            outputItem.attachments = outputAttachments
            context.completeRequest(returningItems: [outputItem], completionHandler: nil)
        }
    }

    func optimise(_ url: URL) -> NSItemProvider? {
        let req = OptimisationRequest(url: url, size: nil, downscaleFactor: nil, speedUpFactor: nil, hideFloatingResult: false, copyToClipboard: false, aggressiveOptimisation: false, source: "finder")
        guard let respData = OPTIMISATION_PORT.send(data: req.jsonData), let resp = OptimisationResponse.from(respData) else {
            return nil
        }
        return NSItemProvider(contentsOf: resp.path.url)
    }
}

extension FilePath {
    var url: URL { URL(filePath: self)! }
}
