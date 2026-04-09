import Cocoa
import Combine
import Defaults
import Foundation
#if !DEBUG
    import Ignore
#endif
import Lowtech
import os
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "FileOptimisationWatcher")

extension EonilFSEventsEvent: @retroactive Hashable {
    public static func == (lhs: EonilFSEventsEvent, rhs: EonilFSEventsEvent) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

@MainActor
class FileOptimisationWatcher {
    init(
        pathsKey: Defaults.Key<[String]>,
        enabledKey: Defaults.Key<Bool>,
        maxFilesToHandleKey: Defaults.Key<Int>,
        fileType: ClopFileType,
        shouldHandle: @escaping (EonilFSEventsEvent) -> Bool,
        cancel: @escaping (FilePath) -> Void,
        handler: @escaping (FilePath) -> Void
    ) {
        self.pathsKey = pathsKey
        self.enabledKey = enabledKey
        self.maxFilesToHandleKey = maxFilesToHandleKey
        self.fileType = fileType
        self.shouldHandle = shouldHandle
        self.cancel = cancel
        self.handler = handler

        pub(pathsKey).sink { [weak self] change in
            self?.paths = change.newValue
            self?.startWatching()
        }.store(in: &observers)

        pub(enabledKey).sink { [weak self] change in
            guard let self else { return }

            enabled = change.newValue
            if change.newValue {
                startWatching()
            } else if watching {
                watching = false
                LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
            }
        }.store(in: &observers)

        pub(maxFilesToHandleKey).sink { [weak self] change in
            self?.maxFilesToHandle = change.newValue
        }.store(in: &observers)

        pub(.pauseAutomaticOptimisations).sink { [weak self] change in
            guard let self else { return }

            if change.newValue {
                if watching {
                    watching = false
                    LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
                }
            } else {
                startWatching()
            }
        }.store(in: &observers)

        startWatching()
    }

    deinit {
        guard watching else { return }
        watching = false
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
    }

    var semaphore = DispatchSemaphore(value: 1)

    var watching = false
    var fileType: ClopFileType

    var pathsKey: Defaults.Key<[String]>
    var enabledKey: Defaults.Key<Bool>
    lazy var paths: [String] = Defaults[pathsKey]
    lazy var enabled: Bool = Defaults[enabledKey]

    var maxFilesToHandleKey: Defaults.Key<Int>
    lazy var maxFilesToHandle: Int = Defaults[maxFilesToHandleKey]

    var handler: (FilePath) -> Void
    var cancel: (FilePath) -> Void
    var shouldHandle: (EonilFSEventsEvent) -> Bool

    var observers = Set<AnyCancellable>()
    var justAddedFiles = Set<EonilFSEventsEvent>()
    var cancelledFiles = Set<FilePath>()
    var alreadyOptimisedFiles = Set<String>()
    var addedFileRemovers = [FilePath: DispatchWorkItem]()
    var alreadyOptimisedFileRemovers = [String: DispatchWorkItem]()

    let startedWatchingAt = Date()

    lazy var delayOptimiserID = "file-watcher-delay-\(fileType.rawValue)"
    var delayOptimiser: Optimiser?

    var addedFilesCleaner: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }
    var addedFilesProcessor: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    var clopIgnoreFileName: String {
        ".clopignore-\(fileType.rawValue)"
    }

    var withinSafeMeasureTime: Bool {
        startedWatchingAt.timeIntervalSinceNow > -30 && Defaults[.launchCount] == 1
    }

    static func waitForModificationDateToSettle(_ path: String) async {
        guard let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date else {
            log.warning("Failed to get modification date of \(path)")
            return
        }

        log.debug("Waiting for modification date of \(path) to settle")
        log.debug("Initial modification date: \(date)")
        var lastDate = date
        var validCheckCount = 0
        while true {
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            } catch {
                log.error("Failed to sleep: \(error)")
                return
            }

            guard let attrs = try? fm.attributesOfItem(atPath: path), let date = attrs[.modificationDate] as? Date else {
                log.warning("Failed to get modification date of \(path)")
                return
            }

            if date == lastDate, let path = path.filePath {
                if validCheckCount >= 5 {
                    log.debug("Modification date of \(path) settled at \(date) but final validity check failed too many times, returning")
                    return
                }

                var isValid = false
                do {
                    isValid = try await (path.isValid())
                } catch {
                    log.debug("File \(path) is still being modified, not valid yet: \(error)")
                    validCheckCount += 1
                    continue
                }
                if !isValid {
                    log.debug("File \(path) is still being modified, not valid yet")
                    validCheckCount += 1
                    continue
                }
                log.debug("Modification date of \(path) settled at \(date)")
                return
            }

            log.debug("Modification date of \(path) is still changing: \(lastDate) -> \(date)")
            lastDate = date
        }
    }

    func isAddedFile(event: EonilFSEventsEvent) -> Bool {
        guard let flag = event.flag, let path = event.path.existingFilePath, let stem = path.stem, !stem.starts(with: ".") else {
            return false
        }

        return flag.isDisjoint(with: [.historyDone, .itemRemoved]) &&
            flag.contains(.itemIsFile) &&
            flag.hasElements(from: [.itemCreated, .itemRenamed, .itemModified])
    }

    func stopWatching() {
        if watching {
            semaphore.wait()
            defer { semaphore.signal() }

            watching = false
            LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
        }
    }

    func startWatching() {
        stopWatching()
        guard !paths.isEmpty, enabled, !Defaults[.pauseAutomaticOptimisations] else { return }

        do {
            try LowtechFSEvents.startWatching(paths: paths, for: ObjectIdentifier(self), latency: 0.3, flags: [.noDefer, .fileEvents, .ignoreSelf, .markSelf]) { [weak self] event in
                guard event.flag?.contains(.ownEvent) == false else { return }
                self?.semaphore.wait()
                defer { self?.semaphore.signal() }

                guard !SWIFTUI_PREVIEW, !BM.decompressingBinaries, let self, enabled, isAddedFile(event: event),
                      !self.alreadyOptimisedFiles.contains(event.path),
                      !OM.optimisers.contains(where: { $0.url?.path == event.path }),
                      let path = event.path.existingFilePath, shouldHandle(event)
                else { return }

                let typeName = fileType.description
                addedFilesCleaner = nil
                log.debug("Added \(path.string) to justAddedFiles in the \(typeName) watcher")
                justAddedFiles.insert(event)
                cancelledFiles.remove(path)

                if !withinSafeMeasureTime {
                    addedFileRemovers[path]?.cancel()
                    addedFileRemovers[path] = mainAsyncAfter(ms: 1000) { [weak self] in
                        log.debug("Removed \(path.string) from justAddedFiles in the \(typeName) watcher")
                        self?.justAddedFiles.remove(event)
                        self?.addedFileRemovers.removeValue(forKey: path)
                    }
                }

                Task.init { [weak self] in await self?.checkEventAndProcess(event) }
            }
            watching = true
        } catch {
            log.error("Failed to start watching \(self.fileType.rawValue) folders: \(error)")
            return
        }
    }

    @MainActor
    func checkEventAndProcess(_ event: EonilFSEventsEvent) async {
        let shouldContinue = await MainActor.run { [weak self] in
            guard let self, enabled else { return false }
            // guard !alreadyOptimisedFiles.contains(event.path) else { return false }
            // guard shouldHandle(event) else { return false }

            if let root = paths.first(where: { event.path.hasPrefix($0) }), let ignorePath = "\(root)/\(clopIgnoreFileName)".existingFilePath, event.path.isIgnored(in: ignorePath.string) {
                log.debug("Ignoring \(event.path) because it's in \(ignorePath.string)")
                return false
            }

            guard !hasSpuriousEvent(event) else { return false }

            guard justAddedFiles.count <= maxFilesToHandle else {
                let notice = "More than \(maxFilesToHandle) \(fileType.rawValue)s appeared in the\n`\(justAddedFiles.first!.path.filePath?.dir.shellString ?? "folder")`, ignoring…"
                log.debug("\(notice)")
                showNotice(notice)
                for path in justAddedFiles.compactMap(\.path.existingFilePath).set.subtracting(cancelledFiles) {
                    log.debug("Cancelling optimisation on \(path)")
                    cancel(path)
                    cancelledFiles.insert(path)
                }
                addedFilesCleaner = mainAsyncAfter(ms: 1000) { [weak self] in
                    log.debug("Cleaning up justAddedFiles and cancelledFiles")
                    self?.cancelledFiles.removeAll()
                    self?.justAddedFiles.removeAll()
                }

                return false
            }

            return true
        }

        guard shouldContinue else { return }
        await Self.waitForModificationDateToSettle(event.path)

        if pauseForNextClipboardEvent {
            log.debug("Skipping \(self.fileType.description) \(event.path) because Clop was paused")
            pauseForNextClipboardEvent = false
            return
        }

        do {
            try await process(event: event)
        } catch {
            log.error("Failed to process \(self.fileType.rawValue) \(event.path) file event: \(error)")
        }
    }

    func hasSpuriousEvent(_ event: EonilFSEventsEvent) -> Bool {
        guard withinSafeMeasureTime, !justAddedFiles.isEmpty else {
            return false
        }

        guard justAddedFiles.count <= 5 else {
            log.warning("More than 5 file events on first launch (\(self.justAddedFiles.count))")

            addedFilesProcessor = nil
            enabled = false
            stopWatching()
            Defaults[enabledKey] = false
            justAddedFiles.removeAll()
            cancelledFiles.removeAll()

            delayOptimiser?.remove(after: 0)
            delayOptimiser = nil

            let alert = NSAlert()
            alert.messageText = "Too many file events"
            alert.informativeText = """
            Clop detected a large number of file change events that happened as soon as Clop started watching the folders.

            This is most likely caused by a third-party app that is constantly modifying files in the folders you selected to automatically optimise.

            To avoid altering files you don't intend to, Clop will stop automatic optimisation in these folders. You can re-enable this feature in the settings.
            """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings")
            alert.alertStyle = .critical
            focus()

            if alert.runModal() == .alertSecondButtonReturn {
                settingsViewManager.tab = fileType.tab
                WM.open("settings")
                focus()
            }

            return true
        }

        delayOptimiser = OM.optimiser(id: delayOptimiserID, type: .unknown, operation: "Initialising file watcher", hidden: false, source: .fileWatcher, indeterminateProgress: true)
        addedFilesProcessor = mainAsyncAfter(ms: 3000) { [weak self] in
            guard let self else { return }
            for event in justAddedFiles.filter({ ev in
                guard let path = ev.path.existingFilePath else { return false }
                return !self.cancelledFiles.contains(path)
            }) {
                Task.init { [weak self] in try await self?.process(event: event) }
            }
            justAddedFiles.removeAll()
            delayOptimiser?.remove(after: 0)
            delayOptimiser = nil
        }

        return true
    }

    @MainActor
    func process(event: EonilFSEventsEvent) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        guard var path = event.path.existingFilePath, !self.cancelledFiles.contains(path) else { return }

        let oldPath = path
        var resolvedNewPath: FilePath?
        if let newPath = try getTemplatedPath(type: fileType, path: path), newPath != path {
            alreadyOptimisedFiles.insert(newPath.string)
            alreadyOptimisedFiles.insert(path.string)
            path = try path.copy(to: newPath, force: true)
            try? oldPath.setOptimisationStatusXattr("original-processed")
            resolvedNewPath = newPath
        }

        var count = optimisedCount
        try? await proGuard(count: &count, limit: 5, url: path.url) {
            self.handler(path)
        }
        optimisedCount = count
        alreadyOptimisedFileRemovers[oldPath.string]?.cancel()
        let protectionMs = Defaults[.optimisedFileProtectionMs]
        alreadyOptimisedFileRemovers[oldPath.string] = mainAsyncAfter(ms: protectionMs) { [weak self] in
            self?.alreadyOptimisedFiles.remove(oldPath.string)
            self?.alreadyOptimisedFileRemovers.removeValue(forKey: oldPath.string)
        }
        if let newPathStr = resolvedNewPath?.string {
            alreadyOptimisedFileRemovers[newPathStr]?.cancel()
            alreadyOptimisedFileRemovers[newPathStr] = mainAsyncAfter(ms: protectionMs) { [weak self] in
                self?.alreadyOptimisedFiles.remove(newPathStr)
                self?.alreadyOptimisedFileRemovers.removeValue(forKey: newPathStr)
            }
        }
    }

    private var optimisedCount = 0
}
