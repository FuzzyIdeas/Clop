import Cocoa
import Foundation
import Lowtech
import System

extension NSRunningApplication: @retroactive @unchecked Sendable {}
extension NSWorkspace.OpenConfiguration: @retroactive @unchecked Sendable {}

@MainActor
class Dropshare {
    static let BUNDLE_ID = "net.mkswap.Dropshare5"
    static let SETAPP_BUNDLE_ID = "net.mkswap.Dropshare-setapp"

    static var appURL = runningApp()?.bundleURL
    static var appQuery: MetaQuery?
    static let shared = Dropshare()

    static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE_ID).first
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: SETAPP_BUNDLE_ID).first
    }

    static func isRunning() -> Bool {
        runningApp() != nil
    }

    static func findApp(_ handler: @escaping (URL?) -> Void) -> MetaQuery {
        let sortByLastUsedDateAdded = [
            NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
            NSSortDescriptor(key: NSMetadataItemDateAddedKey, ascending: false),
        ]
        return MetaQuery(
            scopes: ["/"], queryString: "kMDItemContentTypeTree == 'com.apple.application-bundle' && (kMDItemFSName == 'Dropshare.app' || kMDItemFSName == 'Dropshare 5.app')", sortBy: sortByLastUsedDateAdded
        ) { items in
            guard let item = items.first(where: {
                item in item.path.hasSuffix("/Applications/Dropshare 5.app") || item.path.hasSuffix("/Setapp/Dropshare.app")
            }) ?? items.first,
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else {
                return
            }
            handler(url)
        }
    }

    static func upload(_ file: FilePath) async throws {
        try await upload([file])
    }

    static func upload(_ files: [FilePath]) async throws {
        guard files.isNotEmpty else { return }

        guard let appURL else {
            throw ClopError.dropshareNotRunning(files[0])
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.addsToRecentItems = false
        openConfiguration.arguments = files.map(\.string)

        _ = try await NSWorkspace.shared.open(files.map(\.url), withApplicationAt: appURL, configuration: openConfiguration)
    }

    static func waitToBeAvailable(for seconds: TimeInterval = 5.0) -> Bool {
        ensureAppIsRunning()

        var waitForDropshare = seconds
        while !isRunning(), waitForDropshare > 0 {
            Thread.sleep(forTimeInterval: 0.1)
            waitForDropshare -= 0.1
        }
        return isRunning()
    }

    static func fetchAppURL(completion: (() -> Void)? = nil) {
        guard appURL == nil else { return }

        if isRunning() {
            appURL = runningApp()?.bundleURL
            completion?()
            return
        }

        if FileManager.default.fileExists(atPath: "/Applications/Dropshare 5.app") {
            appURL = URL(fileURLWithPath: "/Applications/Dropshare 5.app")
            completion?()
            return
        }

        if FileManager.default.fileExists(atPath: "/Applications/Setapp/Dropshare.app") {
            appURL = URL(fileURLWithPath: "/Applications/Setapp/Dropshare.app")
            completion?()
            return
        }

        appQuery = findApp { url in
            guard let url else { return }

            mainActor {
                appURL = url
                completion?()
            }
        }
    }

    static func ensureAppIsRunning() {
        guard let appURL else {
            fetchAppURL {
                ensureAppIsRunning()
            }
            return
        }

        guard !isRunning() else { return }
        NSWorkspace.shared.open(appURL)
    }
}

class MetaQuery {
    init(scopes: [String], queryString: String, sortBy: [NSSortDescriptor] = [], handler: @escaping ([NSMetadataItem]) -> Void) {
        let q = NSMetadataQuery()
        q.searchScopes = scopes
        q.predicate = NSPredicate(fromMetadataQueryString: queryString)
        q.sortDescriptors = sortBy
        q.operationQueue = MetaQuery.queryOperationQueue

        MetaQuery.queryOperationQueue.addOperation {
            q.start()
        }
        query = q
        observer = NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: q, queue: MetaQuery.queryOperationQueue) { [weak self] notification in
            guard let query = notification.object as? NSMetadataQuery,
                  let items = query.results as? [NSMetadataItem]
            else {
                return
            }
            q.stop()
            if let observer = self?.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            mainAsync {
                handler(items)
            }
        }
    }

    deinit {
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static let queryOperationQueue = OperationQueue()

    let query: NSMetadataQuery
    var observer: NSObjectProtocol?
}

extension NSMetadataItem {
    var path: String {
        (value(forAttribute: NSMetadataItemPathKey) as? String) ?? ""
    }
}
