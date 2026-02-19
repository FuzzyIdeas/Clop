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

func shellProc(_ launchPath: String = "/bin/zsh", args: [String], env: [String: String]? = nil, out: Pipe? = nil, err: Pipe? = nil) -> Process? {
    let outputDir = FilePath.processLogs.appending("\(launchPath) \(args)".safeFilename)

    let task = Process()
    var env = env ?? ProcessInfo.processInfo.environment

    if let out {
        task.standardOutput = out
    } else {
        let stdoutFilePath = outputDir.withExtension("out").string
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
        let stderrFilePath = outputDir.withExtension("err").string
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

    task.terminationHandler = { process in
        do {
            if let stdoutFile = process.standardOutput as? FileHandle {
                try stdoutFile.synchronize()
                try stdoutFile.close()
            }
            if let stderrFile = process.standardError as? FileHandle {
                try stderrFile.synchronize()
                try stderrFile.close()
            }
        } catch {
            log.error("Error handling termination of process \(launchPath) \(args) [PID: \(process.processIdentifier)]: \(error)")
        }
    }

    do {
        try task.run()
    } catch {
        log.error("Error running \(launchPath) \(args): \(error)")
        return nil
    }

    return task
}

extension Process {
    var out: String {
        let env: [String: String]? = environment
        if let env, let out = env["__swift_stdout"], let out = fm.contents(atPath: out)?.s {
            return out
        } else if let pipe = standardOutput as? Pipe {
            let handle = pipe.fileHandleForReading
            try? handle.seek(toOffset: 0)
            return handle.readDataToEndOfFile().s ?? ""
        }
        return ""
    }

    var err: String {
        let env: [String: String]? = environment
        if let env, let err = env["__swift_stderr"], let err = fm.contents(atPath: err)?.s {
            return err
        } else if let pipe = standardError as? Pipe {
            let handle = pipe.fileHandleForReading
            try? handle.seek(toOffset: 0)
            return handle.readDataToEndOfFile().s ?? ""
        }
        return ""
    }
}

// MARK: - ClopError

enum ClopProcError: Error, CustomStringConvertible {
    case processError(Process)

    var localizedDescription: String { description }
    var description: String {
        switch self {
        case let .processError(proc):
            var desc = "Process error: \(([proc.launchPath ?? ""] + (proc.arguments ?? [])).joined(separator: " "))"
            desc += "\n\t\(proc.out)"
            desc += "\n\t\(proc.err)"

            return desc
        }
    }
    var humanDescription: String {
        switch self {
        case .processError:
            "Process error"
        }
    }
}

extension Progress.FileOperationKind {
    static let analyzing = Self(rawValue: "Analyzing")
    static let optimising = Self(rawValue: "Optimising")
}

func setOptimisationStatusXattr(forFile url: inout URL, value: String) throws {
    try Xattr.set(named: "clop.optimisation.status", data: value.data(using: .utf8)!, atPath: url.path)
}

extension URL {
    func hasOptimisationStatusXattr() -> Bool {
        (try? Xattr.dataFor(named: "clop.optimisation.status", atPath: path))?.s ?? "false" == "true"
    }

    var isImage: Bool { hasExtension(from: IMAGE_EXTENSIONS) }
    var isVideo: Bool { hasExtension(from: VIDEO_EXTENSIONS) }
    var isPDF: Bool { hasExtension(from: ["pdf"]) }

    func hasExtension(from exts: [String]) -> Bool {
        exts.contains((pathExtension.split(separator: "@").last?.s ?? pathExtension).lowercased())
    }

}

extension FilePath {
    var isImage: Bool { hasExtension(from: IMAGE_EXTENSIONS) }
    var isVideo: Bool { hasExtension(from: VIDEO_EXTENSIONS) }
    var isPDF: Bool { hasExtension(from: ["pdf"]) }

    static var workdir = FilePath.dir(Defaults[.workdir], permissions: 0o755) {
        didSet {
            if !workdir.exists {
                workdir.mkdir(withIntermediateDirectories: true, permissions: 0o755)
            }
            guard workdir.exists else {
                log.error("Can't create workdir: \(workdir)")
                return
            }
        }
    }

    var clopBackupPath: FilePath? {
        FilePath.clopBackups.appending(nameWithHash)
    }
    static var clopBackups: FilePath { FilePath.dir(workdir / "backups", permissions: 0o755) }
    static var videos: FilePath { FilePath.dir(workdir / "videos", permissions: 0o755) }
    static var images: FilePath { FilePath.dir(workdir / "images", permissions: 0o755) }
    static var pdfs: FilePath { FilePath.dir(workdir / "pdfs", permissions: 0o755) }
    static var conversions: FilePath { FilePath.dir(workdir / "conversions", permissions: 0o755) }
    static var downloads: FilePath { FilePath.dir(workdir / "downloads", permissions: 0o755) }
    static var forResize: FilePath { FilePath.dir(workdir / "for-resize", permissions: 0o755) }
    static var forFilters: FilePath { FilePath.dir(workdir / "for-filters", permissions: 0o755) }
    static var processLogs: FilePath { FilePath.dir(workdir / "process-logs", permissions: 0o755) }
    static var finderQuickAction: FilePath { FilePath.dir(workdir / "finder-quick-action", permissions: 0o755) }

    func setOptimisationStatusXattr(_ value: String) throws {
        try Xattr.set(named: "clop.optimisation.status", data: value.data(using: .utf8)!, atPath: string)
    }

    func hasOptimisationStatusXattr() -> Bool {
        guard let data = (try? Xattr.dataFor(named: "clop.optimisation.status", atPath: string)) else {
            return false
        }
        return !data.isEmpty
    }

    func removeOptimisationStatusXattr() throws {
        try Xattr.remove(named: "clop.optimisation.status", atPath: string)
    }

    func fetchFileType() -> String? {
        shell("/usr/bin/file", args: ["-b", "--mime-type", string], timeout: 5).o
    }

    func stripExif() {
        let tempFile = URL.temporaryDirectory.appendingPathComponent(name.string).filePath!
        let args = [EXIFTOOL.string, "-XResolution=72", "-YResolution=72"]
            + ["-all=", "-tagsFromFile", "@"]
            + ["-XResolution", "-YResolution", "-Orientation"] + (Defaults[.preserveColorMetadata] ? ["-ColorSpaceTags", "-icc_profile"] : [])
            + ["-o", tempFile.string, string]
        let exifProc = shell("/usr/bin/perl", args: args, wait: true)

        guard tempFile.exists else {
            log.error("Error stripping EXIF from \(self): \(exifProc.e ?? "")")
            return
        }

        if hasOptimisationStatusXattr() {
            try? tempFile.setOptimisationStatusXattr("true")
        }
        _ = try? tempFile.move(to: self, force: true)

        #if DEBUG
            log.debug(args.joined(separator: " "))
            log.debug("\tout: \"\(exifProc.o ?? "")\" err: \"\(exifProc.e ?? "")\"")
        #endif
    }

    func copyCreationModificationDates(from source: FilePath) {
        let sourceURL = source.url
        var destURL = url

        do {
            let sourceValues = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            try destURL.setResourceValues(sourceValues)
        } catch {
            log.error("Error copying dates from \(source) to \(self): \(error)")
        }
    }

    func copyExifCGImage(from source: FilePath) {
        guard let fileType = fetchFileType()?.split(separator: ";").first?.s, let uttype = UTType(mimeType: fileType) else {
            return
        }

        let src = CGImageSourceCreateWithURL(source.url as CFURL, nil)!
        let dst = CGImageDestinationCreateWithURL(url as CFURL, uttype.identifier as CFString, 1, nil)!

        let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)!

        CGImageDestinationAddImageFromSource(dst, src, 0, metadata)
        CGImageDestinationFinalize(dst)

    }

    func hasExifHDR() -> Bool {
        let args = [EXIFTOOL.string, "-q", "-if", "$HDRHeadroom or $HDRGainMapHeadroom or defined $XMP-hdrgm:Version", "-filename", string]
        let exifProc = shell("/usr/bin/perl", args: args, wait: true)
        return exifProc.success
    }

    func copyExif(from source: FilePath, excludeTags: [String]? = nil, stripMetadata: Bool = true) {
        guard source != self else { return }

        if !stripMetadata, isImage {
            copyExifCGImage(from: source)
            return
        }

        if stripMetadata {
            _ = shell("/usr/bin/perl", args: [EXIFTOOL.string, "-overwrite_original", "-all=", string], wait: true)
        }
        let hdr = isImage && source.hasExifHDR()

        var additionalArgs: [String] = []
        if let excludeTags, excludeTags.isNotEmpty {
            additionalArgs += ["-x"] + excludeTags.map { [$0] }.joined(separator: ["-x"]).map { $0 }
        }

        let tagsToKeep = if stripMetadata {
            ["-XResolution", "-YResolution", "-Orientation"] + (!hdr && Defaults[.preserveColorMetadata] ? ["-ColorSpaceTags", "-icc_profile"] : [])
        } else {
            isVideo ? ["-All:All"] : []
        }
        let args = [EXIFTOOL.string, "-overwrite_original", "-XResolution=72", "-YResolution=72"]
            + additionalArgs
            + ["-extractEmbedded", "-tagsFromFile", source.string]
            + tagsToKeep
            + [string]

        log.debug(args.map { $0.shellString.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " "))
        let exifProc = shell("/usr/bin/perl", args: args, wait: true)
        log.debug("\tout: \"\(exifProc.o ?? "")\" err: \"\(exifProc.e ?? "")\"")
    }

}

let stripExifOperationQueue: OperationQueue = {
    let o = OperationQueue()
    o.name = "Strip EXIF"
    o.maxConcurrentOperationCount = 20
    o.underlyingQueue = DispatchQueue.global()
    return o
}()

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
    func terminatedAsync() async -> Bool {
        if terminationReason == .uncaughtSignal, [SIGKILL, SIGTERM].contains(terminationStatus) {
            return true
        }
        return await MainActor.run { processTerminated.contains(processIdentifier) }
    }

    func waitUntilExitAsync() async throws {
        while isRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
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

    let cmdline = procs.map(\.cmdline.shellString).joined(separator: "\n\t")
    log.debug("Starting\n\t\(cmdline)")
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

            log.debug("Retry \(tryNum): \(p.cmdline)")
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

func tryProc(_ cmd: String, argArray: [[String]], captureOutput: Bool = false, env: [String: String]? = nil, beforeWait: ((Process) -> Void)? = nil) throws -> Process {
    var outPipe = Pipe()
    var errPipe = Pipe()

    var proc: Process?
    for (tryNum, args) in argArray.enumerated() {
        let cmdline = "\(cmd.shellString.replacingOccurrences(of: " ", with: "\\ ")) \(args.map { $0.shellString.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " "))"
        log.debug("Starting\n\t\(cmdline)")

        guard let subproc = shellProc(cmd, args: args, env: env, out: outPipe, err: errPipe) else {
            throw ClopError.noProcess(cmd)
        }
        defer {
            proc = subproc
        }
        beforeWait?(subproc)

        subproc.waitUntilExit()
        if subproc.terminationStatus == 0 || subproc.terminated {
            mainThread { processTerminated.remove(subproc.processIdentifier) }
            break
        }

        log.debug("Retry \(tryNum): \(cmd)")
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe = Pipe()
        errPipe = Pipe()
    }

    guard let proc else {
        throw ClopError.noProcess(cmd)
    }
    if proc.isRunning {
        proc.waitUntilExit()
    }
    return proc

}

func tryProc(_ cmd: String, args: [String], tries: Int, captureOutput: Bool = false, env: [String: String]? = nil, beforeWait: ((Process) -> Void)? = nil) throws -> Process {
    var outPipe = Pipe()
    var errPipe = Pipe()

    let cmdline = "\(cmd.shellString.replacingOccurrences(of: " ", with: "\\ ")) \(args.map { $0.shellString.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " "))"
    log.debug("Starting\n\t\(cmdline)")
    guard var proc = shellProc(cmd, args: args, env: env, out: outPipe, err: errPipe) else {
        throw ClopError.noProcess(cmd)
    }
    for tryNum in 1 ... tries {
        beforeWait?(proc)

        proc.waitUntilExit()
        if proc.terminationStatus == 0 || proc.terminated {
            mainThread { processTerminated.remove(proc.processIdentifier) }
            break
        }

        log.debug("Retry \(tryNum): \(cmdline)")
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe = Pipe()
        errPipe = Pipe()
        guard let retryProc = shellProc(cmd, args: args, env: env, out: outPipe, err: errPipe) else {
            throw ClopError.noProcess(cmd)
        }
        proc = retryProc
    }
    if proc.isRunning {
        proc.waitUntilExit()
    }
    return proc
}

func tryProcAsync(_ cmd: String, args: [String], tries: Int, captureOutput: Bool = false, env: [String: String]? = nil, beforeWait: ((Process) -> Void)? = nil) async throws -> Process {
    var outPipe = Pipe()
    var errPipe = Pipe()

    let cmdline = "\(cmd.shellString.replacingOccurrences(of: " ", with: "\\ ")) \(args.map { $0.shellString.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " "))"
    log.debug("Starting\n\t\(cmdline)")
    guard var proc = shellProc(cmd, args: args, env: env, out: outPipe, err: errPipe) else {
        throw ClopError.noProcess(cmd)
    }
    for tryNum in 1 ... tries {
        beforeWait?(proc)

        try await proc.waitUntilExitAsync()

        let pid = proc.processIdentifier
        if proc.terminationStatus == 0 {
            let _ = await MainActor.run { processTerminated.remove(pid) }
            break
        }
        if await proc.terminatedAsync() {
            let _ = await MainActor.run { processTerminated.remove(pid) }
            break
        }

        log.debug("Retry \(tryNum): \(cmdline)")
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe = Pipe()
        errPipe = Pipe()
        guard let retryProc = shellProc(cmd, args: args, env: env, out: outPipe, err: errPipe) else {
            throw ClopError.noProcess(cmd)
        }
        proc = retryProc
    }
    if proc.isRunning {
        try await proc.waitUntilExitAsync()
    }
    return proc
}

let LRZIP = Bundle.main.url(forResource: "lrzip", withExtension: "")! // /Applications/Clop.app/Contents/Resources/lrzip
let BIN_ARCHIVE = Bundle.main.url(forResource: "bin", withExtension: "tar.lrz")! // /Applications/Clop.app/Contents/Resources/bin.tar.lrz
let BIN_ARCHIVE_HASH_PATH = Bundle.main.url(forResource: "bin", withExtension: "tar.lrz.sha256")! // /Applications/Clop.app/Contents/Resources/bin.tar.lrz.sha256

let OLD_BIN_DIRS = [
    APP_SCRIPTS_DIR.appendingPathComponent("com.lowtechguys.Clop"), // ~/Library/Application Scripts/com.lowtechguys.Clop/com.lowtechguys.Clop/
    APP_SCRIPTS_DIR.appendingPathComponent("bin-arm64"), // ~/Library/Application Scripts/com.lowtechguys.Clop/bin-arm64
    APP_SCRIPTS_DIR.appendingPathComponent("bin-x86"), // ~/Library/Application Scripts/com.lowtechguys.Clop/bin-x86
]
let BIN_ARCHIVE_HASH = fm.contents(atPath: BIN_ARCHIVE_HASH_PATH.path)! // f62955f10479b7df4d516f8a714290f2402faaf8960c6c44cae3dfc68f45aabd
let BIN_HASH_FILE = BIN_DIR.appendingPathComponent("sha256hash") // ~/Library/Application Scripts/com.lowtechguys.Clop/bin/sha256hash

func nsalert(error: String) {
    mainThread {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")

        print(error)
        alert.runModal()
    }
}

@MainActor func unarchiveBinaries() {
    DispatchQueue.global().async {
        for dir in OLD_BIN_DIRS where fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
            } catch {
                nsalert(error: "Error removing directory \(dir.path): \(error)")
                exit(1)
            }
        }

        if !fm.fileExists(atPath: GLOBAL_BIN_DIR.path) {
            do {
                try fm.createDirectory(at: GLOBAL_BIN_DIR, withIntermediateDirectories: true, attributes: nil)
            } catch {
                nsalert(error: "Error creating directory \(GLOBAL_BIN_DIR.path): \(error)")
                exit(1)
            }
        }

        if fm.contents(atPath: BIN_HASH_FILE.path) != BIN_ARCHIVE_HASH {
            mainActor { BM.decompressingBinaries = true }
            do {
                if fm.fileExists(atPath: GLOBAL_BIN_DIR.path) {
                    try fm.removeItem(at: GLOBAL_BIN_DIR)
                }
                try fm.createDirectory(at: GLOBAL_BIN_DIR, withIntermediateDirectories: true, attributes: nil)
            } catch {
                nsalert(error: "Error resetting directory \(GLOBAL_BIN_DIR.path): \(error)")
                mainActor { BM.decompressingBinaries = false }
                exit(1)
            }
            let proc = shell("/usr/bin/tar", args: ["-xvf", BIN_ARCHIVE.path, "-C", GLOBAL_BIN_DIR.path], env: ["PATH": "\(LRZIP.deletingLastPathComponent().path):/usr/bin:/bin"], wait: true)
            print("Running: /usr/bin/tar -xvf \(BIN_ARCHIVE.path) -C \(GLOBAL_BIN_DIR.path)")
            if !proc.success {
                // try again by deleting the bin dir
                try? fm.removeItem(at: GLOBAL_BIN_DIR)
                try? fm.createDirectory(at: GLOBAL_BIN_DIR, withIntermediateDirectories: true, attributes: nil)
                let proc = shell("/usr/bin/tar", args: ["-xvf", BIN_ARCHIVE.path, "-C", GLOBAL_BIN_DIR.path], env: ["PATH": "\(LRZIP.deletingLastPathComponent().path):/usr/bin:/bin"], wait: true)
                guard proc.success else {
                    nsalert(error: "Error unarchiving binaries \(BIN_ARCHIVE.path) into \(GLOBAL_BIN_DIR.path): \((proc.e ?? "").prefix(100)) \((proc.o ?? "").prefix(100))")
                    mainActor { BM.decompressingBinaries = false }
                    exit(1)
                }
            }
            fm.createFile(atPath: BIN_HASH_FILE.path, contents: BIN_ARCHIVE_HASH, attributes: nil)
        }
        defer {
            mainActor { BM.decompressingBinaries = false }
        }

        let cliDir = GLOBAL_BIN_DIR_PARENT.deletingLastPathComponent().appendingPathComponent("ClopCLI")
        if fm.fileExists(atPath: cliDir.path), (try? fm.destinationOfSymbolicLink(atPath: cliDir.path)) != GLOBAL_BIN_DIR_PARENT.path {
            do {
                try fm.removeItem(at: cliDir)
            } catch {
                nsalert(error: "Error removing symbolic link \(cliDir.path): \(error)")
                exit(1)
            }
        }
        if !fm.fileExists(atPath: cliDir.path) {
            do {
                try fm.createSymbolicLink(at: cliDir, withDestinationURL: GLOBAL_BIN_DIR_PARENT)
            } catch {
                log.error("Error creating symbolic link \(cliDir.path) -> \(GLOBAL_BIN_DIR_PARENT.path): \(error)")
            }
        }

        let finderOptimiserDir = GLOBAL_BIN_DIR_PARENT.deletingLastPathComponent().appendingPathComponent("\(GLOBAL_BIN_DIR_PARENT.lastPathComponent).FinderOptimiser")
        if fm.fileExists(atPath: finderOptimiserDir.path), (try? fm.destinationOfSymbolicLink(atPath: finderOptimiserDir.path)) != GLOBAL_BIN_DIR_PARENT.path {
            do {
                try fm.removeItem(at: finderOptimiserDir)
            } catch {
                nsalert(error: "Error removing symbolic link \(finderOptimiserDir.path): \(error)")
                exit(1)
            }
        }
        if !fm.fileExists(atPath: finderOptimiserDir.path) {
            do {
                try fm.createSymbolicLink(at: finderOptimiserDir, withDestinationURL: GLOBAL_BIN_DIR_PARENT)
            } catch {
                log.error("Error creating symbolic link \(finderOptimiserDir.path) -> \(GLOBAL_BIN_DIR_PARENT.path): \(error)")
            }
        }
        mainActor { setBinPaths() }
    }
}

@MainActor func setBinPaths() {
    EXIFTOOL = BIN_DIR.appendingPathComponent("exiftool").filePath!
    HEIF_ENC = BIN_DIR.appendingPathComponent("heif-enc").filePath!
    CWEBP = BIN_DIR.appendingPathComponent("cwebp").filePath!
    PNGQUANT = BIN_DIR.appendingPathComponent("pngquant").filePath!
    JPEGOPTIM = BIN_DIR.appendingPathComponent("jpegoptim").filePath!
    GIFSICLE = BIN_DIR.appendingPathComponent("gifsicle").filePath!
    VIPSTHUMBNAIL = BIN_DIR.appendingPathComponent("vipsthumbnail").filePath!
    FFMPEG = BIN_DIR.appendingPathComponent("ffmpeg").filePath!
    GIFSKI = BIN_DIR.appendingPathComponent("gifski").filePath!
    TO_GAIN_MAP_HDR = BIN_DIR.appendingPathComponent("toGainMapHDR").filePath!
}
