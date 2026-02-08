import Combine
import Defaults
import Lowtech

private let APP_HANG_DETECTION_INTERVAL: TimeInterval = 40.0
private let APP_HANG_CHECK_INTERVAL: TimeInterval = 1.0

private final class RepeatingHang {
    init(cause: String, expectedStackFrame: String) {
        self.cause = cause
        self.expectedStackFrame = expectedStackFrame
    }

    let cause: String
    let expectedStackFrame: String

    lazy var exceedsThreshold: Bool = {
        let exceeds = appHangStateQueue.sync {
            if count >= RepeatingHangState.threshold {
                log.warning("Detected repeating hangs due to \(cause) (\(count) in last \(RepeatingHangState.window) seconds)")
                return true
            }
            return false
        }

        if exceeds {
            clearTimestamps()
        }
        return exceeds
    }()

    lazy var count: Int = RepeatingHangState.count(cause: cause, now: Date().timeIntervalSince1970)

    func isCulprit(sampleOutput: String) -> Bool {
        guard sampleOutput.contains(expectedStackFrame) else {
            return false
        }
        log.warning("Hang detected with expected stack frame '\(expectedStackFrame)' in sample output")
        return true
    }

    func clearTimestamps() {
        appHangStateQueue.sync {
            var all = RepeatingHangState.loadTimestamps()
            all[cause] = []
            RepeatingHangState.saveTimestamps(all)
        }
    }

}

private enum RepeatingHangState {
    static let window: TimeInterval = 5 * 60
    static let threshold = 3
    static let fileName = "clop_hang_causes.json"
    static let hangs: [String: RepeatingHang] = [:]

    static func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    static func loadTimestamps() -> [String: [TimeInterval]] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [TimeInterval]].self, from: data)) ?? [:]
    }

    static func saveTimestamps(_ timestamps: [String: [TimeInterval]]) {
        let url = fileURL()
        guard let data = try? JSONEncoder().encode(timestamps) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func record(cause: String, at timestamp: TimeInterval) {
        var all = loadTimestamps()
        var timestamps = all[cause, default: []]
        timestamps.append(timestamp)
        timestamps.removeAll { timestamp - $0 > window }
        all[cause] = timestamps
        saveTimestamps(all)
    }

    static func count(cause: String, now: TimeInterval) -> Int {
        let all = loadTimestamps()
        let timestamps = all[cause, default: []]
        return timestamps.filter { now - $0 <= window }.count
    }
}

private let appHangStateQueue = DispatchQueue(label: "com.lowtechguys.Clop.appHangDetection.state")
@MainActor private var appHangTimer: DispatchSourceTimer?
private var lastMainThreadCheckin: TimeInterval = 0
private var appHangTriggered = false

@MainActor func configureAppHangDetection() {
    guard appHangTimer == nil else {
        return
    }

    appHangStateQueue.sync {
        lastMainThreadCheckin = Date().timeIntervalSince1970
        appHangTriggered = false
    }

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
    timer.schedule(
        deadline: .now() + APP_HANG_CHECK_INTERVAL,
        repeating: APP_HANG_CHECK_INTERVAL,
        leeway: .milliseconds(250)
    )
    timer.setEventHandler {
        let now = Date().timeIntervalSince1970
        var shouldTrigger = false

        appHangStateQueue.sync {
            if !appHangTriggered, now - lastMainThreadCheckin > APP_HANG_DETECTION_INTERVAL {
                appHangTriggered = true
                shouldTrigger = true
            }
        }

        if shouldTrigger {
            onAppHangDetected()
        }

        DispatchQueue.main.async {
            appHangStateQueue.async {
                lastMainThreadCheckin = Date().timeIntervalSince1970
            }
        }
    }
    appHangTimer = timer
    timer.resume()
}

private func mainThreadStack(from sampleOutput: String) -> String {
    let lines = sampleOutput.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [Substring] = []
    var inMainThread = false

    for line in lines {
        if line.contains("Thread_") {
            if inMainThread { break }
            if line.contains("com.apple.main-thread") {
                inMainThread = true
            }
        }
        if inMainThread {
            result.append(line)
        }
    }

    return result.joined(separator: "\n")
}

func onAppHangDetected() {
    log.warning("App Hanging!")

    let pid = ProcessInfo.processInfo.processIdentifier
    let sampleOutput = shell("/usr/bin/sample", args: ["\(pid)", "0.001"], timeout: 30) ?? ""
    let mainThread = mainThreadStack(from: sampleOutput)
    log.warning("Main thread sample:\n\(mainThread)")

    if Defaults[.autoRestartOnHang] {
        let now = Date().timeIntervalSince1970
        appHangStateQueue.async {
            if let hang = RepeatingHangState.hangs.values.first(where: { $0.isCulprit(sampleOutput: mainThread) }) {
                RepeatingHangState.record(cause: hang.cause, at: now)
            }
        }
        log.warning("Auto-restarting app due to hang detection.")
        asyncAfter(ms: 5000) { restart() }
    }
}
