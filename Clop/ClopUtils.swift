//
//  ClopUtils.swift
//  Clop
//
//  Created by Alin Panaitiu on 12.07.2023.
//

import Defaults
import Foundation
import Lowtech
import System

// MARK: - Process + Sendable

extension Process: @unchecked Sendable {}

func shellProc(_ launchPath: String = "/bin/zsh", args: [String], env: [String: String]? = nil, out: Pipe? = nil, err: Pipe? = nil) -> Process? {
    let outputDir = try! fm.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: fm.homeDirectoryForCurrentUser,
        create: true
    )

    let task = Process()
    var env = env ?? ProcessInfo.processInfo.environment

    if let out {
        task.standardOutput = out
    } else {
        let stdoutFilePath = outputDir.appendingPathComponent("stdout").path
        fm.createFile(atPath: stdoutFilePath, contents: nil, attributes: nil)
        guard let stdoutFile = FileHandle(forWritingAtPath: stdoutFilePath) else {
            return nil
        }
        task.standardOutput = stdoutFile
        env["__swift_stdout"] = stdoutFilePath
    }

    if let err {
        task.standardError = err
    } else {
        let stderrFilePath = outputDir.appendingPathComponent("stderr").path
        fm.createFile(atPath: stderrFilePath, contents: nil, attributes: nil)
        guard let stderrFile = FileHandle(forWritingAtPath: stderrFilePath) else {
            return nil
        }
        task.standardError = stderrFile
        env["__swift_stderr"] = stderrFilePath
    }

    task.launchPath = launchPath
    task.arguments = args
    task.environment = env

    do {
        try task.run()
    } catch {
        print("Error running \(launchPath) \(args): \(error)")
        return nil
    }

    return task
}

// MARK: - ClopError

enum ClopError: Error, CustomStringConvertible {
    case fileNotFound(FilePath)
    case fileNotImage(FilePath)
    case noClipboardImage(FilePath)
    case noProcess(String)
    case processError(Process)
    case alreadyOptimized(FilePath)
    case unknownImageType(FilePath)
    case skippedType(String)
    case imageSizeLarger(FilePath)
    case videoSizeLarger(FilePath)
    case videoError(String)
    case downloadError(String)
    case optimizationPaused(FilePath)
    case conversionFailed(FilePath)
    case proError(String)
    case downscaleFailed(FilePath)
    case unknownType

    var localizedDescription: String { description }
    var description: String {
        switch self {
        case let .fileNotFound(p):
            return "File not found: \(p)"
        case let .fileNotImage(p):
            return "File is not an image: \(p)"
        case let .noClipboardImage(p):
            if p.string.isEmpty { return "No image in clipboard" }
            return "No image in clipboard: \(p.string.count > 100 ? p.string.prefix(50) + "..." + p.string.suffix(50) : p.string)"
        case let .noProcess(string):
            return "Can't start process: \(string)"
        case let .alreadyOptimized(p):
            return "Image is already optimized: \(p)"
        case let .imageSizeLarger(p):
            return "Optimized image size is larger: \(p)"
        case let .videoSizeLarger(p):
            return "Optimized video size is larger: \(p)"
        case let .unknownImageType(p):
            return "Unknown image type: \(p)"
        case let .videoError(string):
            return "Error optimizing video: \(string)"
        case let .downloadError(string):
            return "Download failed: \(string)"
        case let .skippedType(string):
            return "Type is skipped: \(string)"
        case let .optimizationPaused(p):
            return "Optimization paused: \(p)"
        case let .conversionFailed(p):
            return "Conversion failed: \(p)"
        case let .proError(string):
            return "Pro error: \(string)"
        case let .downscaleFailed(p):
            return "Downscale failed: \(p)"
        case .unknownType:
            return "Unknown type"

        case let .processError(proc):
            var desc = "Process error: \(([proc.launchPath ?? ""] + (proc.arguments ?? [])).joined(separator: " "))"

            var env: [String: String]? = proc.environment
            if let out = env?.removeValue(forKey: "__swift_stdout"), let outData = fm.contents(atPath: out) {
                desc += "\n\t" + (outData.s ?? "NON-UTF8 STDOUT")
            }
            if let err = env?.removeValue(forKey: "__swift_stderr"), let errData = fm.contents(atPath: err) {
                desc += "\n\t" + (errData.s ?? "NON-UTF8 STDERR")
            }
            return desc
        }
    }
    var humanDescription: String {
        switch self {
        case .fileNotFound:
            return "File not found"
        case .fileNotImage:
            return "Not an image"
        case .noClipboardImage:
            return "No image in clipboard"
        case .noProcess:
            return "Can't start process"
        case .alreadyOptimized:
            return "Already optimized"
        case .imageSizeLarger:
            return "Optimized image is larger"
        case .videoSizeLarger:
            return "Optimized video is larger"
        case .unknownImageType:
            return "Unknown image type"
        case .processError:
            return "Process error"
        case .videoError:
            return "Video error"
        case .downloadError:
            return "Download failed"
        case .skippedType:
            return "Type is skipped"
        case .optimizationPaused:
            return "Optimization paused"
        case .conversionFailed:
            return "Conversion failed"
        case .proError:
            return "Pro error"
        case .downscaleFailed:
            return "Downscale failed"
        case .unknownType:
            return "Unknown type"
        }
    }
}

extension Progress.FileOperationKind {
    static let analyzing = Self(rawValue: "Analyzing")
    static let optimizing = Self(rawValue: "Optimizing")
}

func setOptimizationStatusXattr(forFile url: inout URL, value: String) throws {
    try Xattr.set(named: "clop.optimization.status", data: value.data(using: .utf8)!, atPath: url.path)
}

extension URL {
    func hasOptimizationStatusXattr() -> Bool {
        (try? Xattr.dataFor(named: "clop.optimization.status", atPath: path))?.s ?? "false" == "true"
    }
}

extension FilePath {
    var isImage: Bool { hasExtension(from: IMAGE_EXTENSIONS) }
    var isVideo: Bool { hasExtension(from: VIDEO_EXTENSIONS) }

    static var videos = FilePath.dir("/tmp/clop/videos")
    static var images = FilePath.dir("/tmp/clop/images")
    static var conversions = FilePath.dir("/tmp/clop/conversions")
    static var downloads = FilePath.dir("/tmp/clop/downloads")
    static var forResize = FilePath.dir("/tmp/clop/for-resize")

    func setOptimizationStatusXattr(_ value: String) throws {
        try Xattr.set(named: "clop.optimization.status", data: value.data(using: .utf8)!, atPath: string)
    }

    func hasOptimizationStatusXattr() -> Bool {
        guard let data = (try? Xattr.dataFor(named: "clop.optimization.status", atPath: string)) else {
            return false
        }
        return !data.isEmpty
    }

    func fetchFileType() -> String? {
        shell("/usr/bin/file", args: ["-b", "--mime-type", string]).o
    }

    func copyExif(from source: FilePath) {
        let exifProc = shell("/usr/bin/perl5.30", args: [EXIFTOOL, "-overwrite_original", "-TagsFromFile", source.string, string], wait: true)
        #if DEBUG
            debug("EXIFTOOL: out=\(exifProc.o ?? "") err=\(exifProc.e ?? "")")
        #endif
    }

}

let HALF_HALF = sqrt(0.5)

import Cocoa
import QuickLookThumbnailing
let SCREEN_SCALE = NSScreen.main!.backingScaleFactor

func generateThumbnail(for url: URL, size: CGSize, onCompletion: @escaping (QLThumbnailRepresentation) -> Void) {
    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: size,
        scale: SCREEN_SCALE,
        representationTypes: .thumbnail
    )

    QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, type, error in
        DispatchQueue.main.async {
            if let error {
                log.error("Error on generating thumbnail for \(url): \(error.localizedDescription)")
            }
            guard let thumbnail else {
                return
            }
            onCompletion(thumbnail)
        }
    }
}

extension Process {
    var commandLine: String { "\(executableURL?.path ?? "") \(arguments?.joined(separator: " ") ?? "")" }

    var terminated: Bool { memoz._terminated }
    var _terminated: Bool {
        (terminationReason == .uncaughtSignal && [SIGKILL, SIGTERM].contains(terminationStatus)) ||
            mainThread { processTerminated.contains(processIdentifier) }
    }
}

struct Proc: Hashable {
    let cmd: String
    let args: [String]

    var cmdline: String { "\(cmd) \(args.joined(separator: " "))" }
}

func tryProcs(_ procs: [Proc], tries: Int, captureOutput: Bool = false, beforeWait: (([Proc: Process]) -> Void)? = nil) throws -> [Proc: Process] {
    var outPipes = procs.dict { ($0, Pipe()) }
    var errPipes = procs.dict { ($0, Pipe()) }

    print("Starting\n\t\(procs.map(\.cmdline).joined(separator: "\n\t"))")
    var processes: [Proc: Process] = procs.dict { proc in
        guard let p = shellProc(proc.cmd, args: proc.args, out: outPipes[proc]!, err: errPipes[proc]!)
        else { return nil }
        return (proc, p)
    }
    guard processes.isNotEmpty else {
        throw ClopError.noProcess(procs.first?.cmd ?? "")
    }

    for tryNum in 1 ... tries {
        beforeWait?(processes)

        processes.values.forEach { $0.waitUntilExit() }
        processes = processes.dict { p, proc in
            if proc.terminationStatus == 0 || proc.terminated {
                mainThread { processTerminated.remove(proc.processIdentifier) }
                return (p, proc)
            }

            print("Retry \(tryNum): \(p.cmdline)")
            outPipes[p]!.fileHandleForReading.readabilityHandler = nil
            errPipes[p]!.fileHandleForReading.readabilityHandler = nil
            outPipes[p] = Pipe()
            errPipes[p] = Pipe()
            guard let retryProc = shellProc(p.cmd, args: p.args, out: outPipes[p], err: errPipes[p]) else {
                return (p, proc)
            }
            return (p, retryProc)
        }
    }
    if processes.values.contains(where: \.isRunning) {
        processes.values.forEach { $0.waitUntilExit() }
    }
    return processes

}

func tryProc(_ cmd: String, args: [String], tries: Int, captureOutput: Bool = false, beforeWait: ((Process) -> Void)? = nil) throws -> Process {
    var outPipe = Pipe()
    var errPipe = Pipe()

    let cmdline = "\(cmd) \(args.joined(separator: " "))"
    print("Starting \(cmdline)")
    guard var proc = shellProc(cmd, args: args, out: outPipe, err: errPipe) else {
        throw ClopError.noProcess(cmd)
    }
    for tryNum in 1 ... tries {
        beforeWait?(proc)

        proc.waitUntilExit()
        if proc.terminationStatus == 0 || proc.terminated {
            mainThread { processTerminated.remove(proc.processIdentifier) }
            break
        }

        print("Retry \(tryNum): \(cmdline)")
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe = Pipe()
        errPipe = Pipe()
        guard let retryProc = shellProc(cmd, args: args, out: outPipe, err: errPipe) else {
            throw ClopError.noProcess(cmd)
        }
        proc = retryProc
    }
    if proc.isRunning {
        proc.waitUntilExit()
    }
    return proc
}
