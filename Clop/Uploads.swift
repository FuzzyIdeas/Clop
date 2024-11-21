import Cocoa
import Defaults
import Foundation
import Lowtech
import System

extension NSRunningApplication: @retroactive @unchecked Sendable {}
extension NSWorkspace.OpenConfiguration: @retroactive @unchecked Sendable {}

@MainActor
class Dropshare: AppIntegration {
    override var BUNDLE_ID: String { "net.mkswap.Dropshare5" }
    override var SETAPP_BUNDLE_ID: String? { "net.mkswap.Dropshare-setapp" }

    override var appNameQuery: String { "(kMDItemFSName == 'Dropshare.app' || kMDItemFSName == 'Dropshare 5.app')" }
    override var webURL: URL? { "https://dropshare.app/".url! }
    override var appPath: String { "/Applications/Dropshare 5.app" }
    override var setappAppPath: String { "Setapp/Dropshare.app" }
}

@MainActor
class Yoink: AppIntegration {
    override var BUNDLE_ID: String { "at.EternalStorms.Yoink-setapp" }
    override var SETAPP_BUNDLE_ID: String? { "at.EternalStorms.Yoink-setapp-setapp" }

    override var appNameQuery: String { "kMDItemFSName == 'Yoink.app'" }
    override var webURL: URL? { "https://eternalstorms.at/yoink/mac/".url! }
    override var appPath: String { "/Applications/Yoink.app" }
    override var setappAppPath: String { "Setapp/Yoink.app" }
}

@MainActor
class Dockside: AppIntegration {
    override var BUNDLE_ID: String { "com.hachipoo.Dockside" }

    override var appNameQuery: String { "kMDItemFSName == 'Dockside.app'" }
    override var webURL: URL? { "https://hachipoo.com/dockside-app".url! }
    override var appPath: String { "/Applications/Dockside.app" }
}

@MainActor let DROPSHARE = Dropshare()
@MainActor let YOINK = Yoink()
@MainActor let DOCKSIDE = Dockside()

@MainActor
class AppIntegration {
    required init() {}

    lazy var appURL: URL? = runningApp()?.bundleURL
    var appQuery: MetaQuery?

    var BUNDLE_ID: String { "" }
    var SETAPP_BUNDLE_ID: String? { nil }

    var webURL: URL? { nil }
    var appNameQuery: String { "" }
    var appPath: String { "" }
    var setappAppPath: String? { nil }

    func open(optimisers: [Optimiser]? = nil) {
        let workingWithSelection = optimisers != nil
        let optimisers = optimisers ?? OM.visibleOptimisers.arr

        guard !optimisers.isEmpty else { return }
        guard appURL != nil else {
            if let webURL {
                NSWorkspace.shared.open(webURL)
            }
            return
        }

        let files = optimisers.compactMap(\.url?.existingFilePath)

        tryAsync {
            try await self.open(files)
        }
        if Defaults[.dismissCompactResultOnUpload], !workingWithSelection {
            OM.clearVisibleOptimisers()
        }
    }

    func open(optimiser: Optimiser) {
        guard let file = optimiser.url?.existingFilePath else { return }
        guard appURL != nil else {
            if let webURL {
                NSWorkspace.shared.open(webURL)
            }
            return
        }

        tryAsync {
            try await self.open(file)
        }

        if OM.compactResults ? Defaults[.dismissCompactResultOnUpload] : Defaults[.dismissFloatingResultOnUpload] {
            optimiser.remove(after: 100, withAnimation: true)
        }
    }

    func runningApp() -> NSRunningApplication? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE_ID).first else {
            if let id = SETAPP_BUNDLE_ID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app
            }
            return nil
        }

        return app
    }

    func isRunning() -> Bool {
        runningApp() != nil
    }

    func findApp(_ handler: @escaping (URL?) -> Void) -> MetaQuery {
        let sortByLastUsedDateAdded = [
            NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
            NSSortDescriptor(key: NSMetadataItemDateAddedKey, ascending: false),
        ]
        return MetaQuery(
            scopes: ["/"], queryString: "kMDItemContentTypeTree == 'com.apple.application-bundle' && \(appNameQuery)", sortBy: sortByLastUsedDateAdded
        ) { [self] items in
            guard let item = items.first(where: {
                item in item.path.hasSuffix(appPath) || (setappAppPath == nil ? false : item.path.hasSuffix("/\(setappAppPath!)"))
            }) ?? items.first,
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else {
                return
            }
            handler(url)
        }
    }

    func open(_ file: FilePath) async throws {
        try await open([file])
    }

    func open(_ files: [FilePath]) async throws {
        guard files.isNotEmpty else { return }

        guard let appURL else {
            throw ClopError.appNotRunning(files[0])
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.addsToRecentItems = false
        openConfiguration.arguments = files.map(\.string)

        _ = try await NSWorkspace.shared.open(files.map(\.url), withApplicationAt: appURL, configuration: openConfiguration)
    }

    func waitToBeAvailable(for seconds: TimeInterval = 5.0) -> Bool {
        ensureAppIsRunning()

        var waitForApp = seconds
        while !isRunning(), waitForApp > 0 {
            Thread.sleep(forTimeInterval: 0.1)
            waitForApp -= 0.1
        }
        return isRunning()
    }

    func fetchAppURL(completion: (() -> Void)? = nil) {
        guard appURL == nil else { return }

        if isRunning() {
            appURL = runningApp()?.bundleURL
            completion?()
            return
        }

        if FileManager.default.fileExists(atPath: appPath) {
            appURL = URL(fileURLWithPath: appPath)
            completion?()
            return
        }

        if let setappAppPath, FileManager.default.fileExists(atPath: "/Applications/\(setappAppPath)") {
            appURL = URL(fileURLWithPath: "/Applications/\(setappAppPath)")
            completion?()
            return
        }

        appQuery = findApp { url in
            guard let url else { return }

            mainActor {
                self.appURL = url
                completion?()
            }
        }
    }

    func ensureAppIsRunning() {
        guard let appURL else {
            fetchAppURL {
                self.ensureAppIsRunning()
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
