//
//  ClopUtils.swift
//  Clop
//
//  Created by Alin Panaitiu on 12.07.2023.
//
import Atomics
import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "ClopUtils")

extension String {
    /// `safeFilename`, shortened to always fit in one path component.
    ///
    /// A component can't exceed 255 bytes, and a command line with full binary and file paths in it
    /// routinely lands around 380. `FileManager.createFile` just returns false for those, so the
    /// process-log `FileHandle` came back nil and `shellProc` returned nil for the whole command.
    /// Keep a readable head and append a stable digest of the rest so two commands never share a log.
    var safeShortFilename: String {
        let safe = safeFilename
        guard safe.utf8.count > 180 else { return safe }

        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in safe.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return "\(safe.prefix(150))-\(String(hash, radix: 36))"
    }
}

// MARK: - ProcessOutputBuffer

/// What a child wrote to a `Pipe`, kept alive for as long as the pipe is.
///
/// A pipe holds 64KB and then blocks the writer. Nothing ever read the stdout
/// pipe and only some calls installed a progress handler on stderr, so a tool
/// that printed more than that (a vips or pngquant warning storm on a broken
/// file) stalled in `write()` forever and took `waitUntilExit()` down with it.
/// Everything is drained as it arrives now, and kept so the error paths have
/// something to log: they used to read the pipe again from scratch, which for
/// any process with a progress handler returned nothing at all because the
/// handler had already consumed every byte.
final class ProcessOutputBuffer {
    /// Head and tail, so a chatty process can't grow this without bound. The
    /// head holds the banner where ffmpeg prints `Duration:`, the tail holds
    /// the error that actually killed the run.
    static let maxBytes = 256 * 1024

    var text: String {
        lock.lock()
        defer { lock.unlock() }

        let start = head.s ?? ""
        let end = tail.s ?? ""
        guard dropped > 0 else { return start + end }
        return "\(start)\n… \(dropped) bytes dropped …\n\(end)"
    }

    /// The drain hit EOF, so everything the child wrote is in here.
    func finish() {
        lock.lock()
        let wasFinished = finished
        finished = true
        lock.unlock()

        guard !wasFinished else { return }
        finishedSignal.signal()
    }

    /// Wait for the drain to hit EOF. The child exiting isn't enough on its own:
    /// its last chunk is still in flight on the handler's own queue.
    @discardableResult
    func waitUntilFinished(timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        let alreadyFinished = finished
        lock.unlock()
        if alreadyFinished { return true }

        guard finishedSignal.wait(timeout: .now() + timeout) == .success else { return false }
        lock.lock()
        finished = true
        lock.unlock()
        finishedSignal.signal()
        return true
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let half = Self.maxBytes / 2
        if head.count < half {
            let room = half - head.count
            head.append(data.prefix(room))
            guard data.count > room else { return }
            tail.append(data.dropFirst(room))
        } else {
            tail.append(data)
        }

        if tail.count > half {
            let excess = tail.count - half
            tail = Data(tail.dropFirst(excess))
            dropped += excess
        }
    }

    private let lock = NSLock()
    private let finishedSignal = DispatchSemaphore(value: 0)
    private var head = Data()
    private var tail = Data()
    private var dropped = 0
    private var finished = false
}

private let outputBufferKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
private let outputBufferLock = NSLock()

extension FileHandle {
    /// Attached to the pipe's read handle so it dies with the pipe, which means
    /// a retry that swaps in a fresh `Pipe` starts from an empty buffer.
    var outputBuffer: ProcessOutputBuffer {
        outputBufferLock.lock()
        defer { outputBufferLock.unlock() }

        if let existing = objc_getAssociatedObject(self, outputBufferKey) as? ProcessOutputBuffer {
            return existing
        }
        let buffer = ProcessOutputBuffer()
        objc_setAssociatedObject(self, outputBufferKey, buffer, .OBJC_ASSOCIATION_RETAIN)
        return buffer
    }
}

extension Pipe {
    /// Keep reading as the child writes so it can never block on a full pipe.
    ///
    /// A handler that needs the bytes for itself (the progress parsers) replaces
    /// this one and has to keep feeding `outputBuffer`, or the drain stops.
    func drainIntoBuffer() {
        let handle = fileHandleForReading
        _ = handle.outputBuffer
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                handle.outputBuffer.finish()
                return
            }
            handle.outputBuffer.append(data)
        }
    }

    /// Everything the child wrote, once the drain has seen EOF.
    ///
    /// Install `drainIntoBuffer()` before `run()` and read this after the exit,
    /// never `readDataToEndOfFile()` after `waitUntilExit()`: a pipe holds 64KB
    /// and then blocks the writer, so a child that prints more than that never
    /// reaches the exit the read is waiting for.
    func drainedText(timeout: TimeInterval = 5) -> String {
        let buffer = fileHandleForReading.outputBuffer
        if !buffer.waitUntilFinished(timeout: timeout) {
            fileHandleForReading.readabilityHandler = nil
        }
        return buffer.text
    }
}

/// Runs so far, to keep two identical command lines started at the same moment
/// from writing into one log file.
private let processLogCounter = ManagedAtomic<UInt64>(0)

func shellProc(_ launchPath: String = "/bin/zsh", args: [String], env: [String: String]? = nil, out: Pipe? = nil, err: Pipe? = nil) -> Process? {
    let run = processLogCounter.wrappingIncrementThenLoad(ordering: .relaxed)
    let outputDir = FilePath.processLogs.appending("\(launchPath) \(args)".safeShortFilename + "-\(run)")

    let task = Process()
    var env = env ?? ProcessInfo.processInfo.environment

    // Both handles have to be closed by hand if the launch never happens, so
    // hold them here rather than only on the Process.
    var openedHandles: [FileHandle] = []
    var launched = false
    defer {
        if !launched {
            for handle in openedHandles {
                try? handle.close()
            }
        }
    }

    if let out {
        task.standardOutput = out
        out.drainIntoBuffer()
    } else {
        let stdoutFilePath = outputDir.withExtension("out").string
        fm.createFile(atPath: stdoutFilePath, contents: nil, attributes: nil)
        guard let stdoutFile = FileHandle(forWritingAtPath: stdoutFilePath) else {
            log.error("Could not open the stdout log for \(launchPath) \(args)")
            return nil
        }
        openedHandles.append(stdoutFile)
        task.standardOutput = stdoutFile
        env["__swift_stdout"] = stdoutFilePath
    }

    if let err {
        task.standardError = err
        err.drainIntoBuffer()
    } else {
        let stderrFilePath = outputDir.withExtension("err").string
        fm.createFile(atPath: stderrFilePath, contents: nil, attributes: nil)
        guard let stderrFile = FileHandle(forWritingAtPath: stderrFilePath) else {
            log.error("Could not open the stderr log for \(launchPath) \(args)")
            return nil
        }
        openedHandles.append(stderrFile)
        task.standardError = stderrFile
        env["__swift_stderr"] = stderrFilePath
    }

    // Without this the child inherits our stdin, and anything that decides to
    // prompt (ffmpeg asking to overwrite) blocks forever on a descriptor
    // nobody will ever write to.
    task.standardInput = FileHandle.nullDevice
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    task.environment = env

    task.terminationHandler = { process in
        // Closed one at a time: a throw on the first used to skip the second and
        // leak that descriptor. Nothing is synchronized because the parent never
        // writes through these handles, the child has its own.
        if let stdoutFile = process.standardOutput as? FileHandle {
            try? stdoutFile.close()
        }
        if let stderrFile = process.standardError as? FileHandle {
            try? stderrFile.close()
        }
    }

    do {
        try task.run()
    } catch {
        log.error("Error running \(launchPath) \(args): \(error)")
        return nil
    }
    launched = true

    return task
}

extension Process {
    var out: String {
        if let path = environment?["__swift_stdout"], let contents = fm.contents(atPath: path)?.s {
            return contents
        }
        // Never re-read the pipe here: the bytes are gone the moment a
        // readability handler took them, and `readDataToEndOfFile()` on a
        // handle another handler is still reading is a race on top of that.
        if let pipe = standardOutput as? Pipe {
            return pipe.drainedText(timeout: 2)
        }
        return ""
    }

    var err: String {
        if let path = environment?["__swift_stderr"], let contents = fm.contents(atPath: path)?.s {
            return contents
        }
        if let pipe = standardError as? Pipe {
            return pipe.drainedText(timeout: 2)
        }
        return ""
    }
}

// MARK: - ClopError

enum ClopProcError: Error, CustomStringConvertible {
    case processError(Process)

    var localizedDescription: String {
        description
    }
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

    var isImage: Bool {
        hasExtension(from: IMAGE_EXTENSIONS)
    }
    var isVideo: Bool {
        hasExtension(from: VIDEO_EXTENSIONS)
    }
    var isPDF: Bool {
        hasExtension(from: ["pdf"])
    }
    var isAudio: Bool {
        hasExtension(from: AUDIO_EXTENSIONS)
    }

    func hasExtension(from exts: [String]) -> Bool {
        exts.contains((pathExtension.split(separator: "@").last?.s ?? pathExtension).lowercased())
    }

}

extension FilePath {
    var isImage: Bool {
        hasExtension(from: IMAGE_EXTENSIONS)
    }
    var isVideo: Bool {
        hasExtension(from: VIDEO_EXTENSIONS)
    }
    var isPDF: Bool {
        hasExtension(from: ["pdf"])
    }
    var isAudio: Bool {
        hasExtension(from: AUDIO_EXTENSIONS)
    }

    static var workdir = FilePath.dir(Defaults[.workdir].resolvedPath, permissions: 0o755) {
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
    static var clopBackups: FilePath {
        FilePath.dir(workdir / "backups", permissions: 0o755)
    }
    /// Batch-mode CoW backups, one `batch-<id>` subfolder per run. Deliberately a separate root that
    /// the `fileCleaner` never enumerates: batch backups are the only pristine copy after an in-place
    /// rewrite and must survive until an explicit "Delete backups" or a verified restore.
    static var batchBackups: FilePath {
        FilePath.dir(workdir / "batch-backups", permissions: 0o755)
    }
    static var videos: FilePath {
        FilePath.dir(workdir / "videos", permissions: 0o755)
    }
    static var images: FilePath {
        FilePath.dir(workdir / "images", permissions: 0o755)
    }
    static var pdfs: FilePath {
        FilePath.dir(workdir / "pdfs", permissions: 0o755)
    }
    static var audios: FilePath {
        FilePath.dir(workdir / "audios", permissions: 0o755)
    }
    static var conversions: FilePath {
        FilePath.dir(workdir / "conversions", permissions: 0o755)
    }
    static var downloads: FilePath {
        FilePath.dir(workdir / "downloads", permissions: 0o755)
    }
    static var forResize: FilePath {
        FilePath.dir(workdir / "for-resize", permissions: 0o755)
    }
    static var forFilters: FilePath {
        FilePath.dir(workdir / "for-filters", permissions: 0o755)
    }
    static var processLogs: FilePath {
        FilePath.dir(workdir / "process-logs", permissions: 0o755)
    }
    static var finderQuickAction: FilePath {
        FilePath.dir(workdir / "finder-quick-action", permissions: 0o755)
    }

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
        // In-process replacement for `file -b --mime-type`: forking /usr/bin/file blocked the
        // main thread for 30s+ under memory pressure (CLOP-18X). Magic bytes win over the
        // extension so mislabeled files keep getting detected like `file` did.
        sniffMIMEType() ?? `extension`.flatMap { UTType(filenameExtension: $0)?.preferredMIMEType }
    }

    /// Detect the MIME type from magic bytes, in-process. Covers the formats Clop handles and
    /// mirrors the strings `file -b --mime-type` returns for them.
    func sniffMIMEType() -> String? {
        guard let fh = FileHandle(forReadingAtPath: string) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 512) else { return nil }
        return mimeTypeFromMagicBytes(data)
    }
}

/// `FilePath.sniffMIMEType()` on bytes that are already in memory, so a decoded file doesn't have to
/// be reopened just to identify it.
func mimeTypeFromMagicBytes(_ data: Data) -> String? {
    guard data.count >= 4 else { return nil }
    let b = [UInt8](data.prefix(512))

    func str(_ offset: Int, _ len: Int) -> String? {
        guard b.count >= offset + len else { return nil }
        return String(decoding: b[offset ..< offset + len], as: UTF8.self)
    }

    switch (b[0], b[1], b[2], b[3]) {
    case (0xFF, 0xD8, 0xFF, _): return "image/jpeg"
    case (0x89, 0x50, 0x4E, 0x47): return "image/png"
    case (0x47, 0x49, 0x46, 0x38): return "image/gif" // GIF87a / GIF89a
    case (0x49, 0x49, 0x2A, 0x00), (0x4D, 0x4D, 0x00, 0x2A): return "image/tiff"
    case (0xFF, 0x0A, _, _): return "image/jxl"
    case (0x42, 0x4D, _, _): return "image/bmp"
    case (0x1A, 0x45, 0xDF, 0xA3): // Matroska EBML: the DocType string is in the first bytes
        return String(decoding: b, as: UTF8.self).contains("webm") ? "video/webm" : "video/x-matroska"
    case (0x30, 0x26, 0xB2, 0x75): return "video/x-ms-wmv" // ASF
    case (0x46, 0x4C, 0x56, 0x01): return "video/x-flv"
    case (0x25, 0x50, 0x44, 0x46): return "application/pdf" // %PDF
    case (0x66, 0x4C, 0x61, 0x43): return "audio/flac" // fLaC
    case (0x4F, 0x67, 0x67, 0x53): // OggS: the codec ids are in the first pages
        let head = String(decoding: b, as: UTF8.self)
        if head.contains("theora") { return "video/ogg" }
        if head.contains("OpusHead") { return "audio/opus" }
        return "audio/ogg" // vorbis, speex, flac-in-ogg
    case (0x49, 0x44, 0x33, _): return "audio/mpeg" // ID3
    case (0xFE, 0xFF, _, _), (0xFF, 0xFE, _, _): return "text/plain" // UTF-16 BOM (FF FE also parses as an MP3 framesync)
    case (0x46, 0x4F, 0x52, 0x4D): // FORM (AIFF / AIFC)
        return str(8, 3) == "AIF" ? "audio/x-aiff" : nil
    case (0x52, 0x49, 0x46, 0x46): // RIFF
        switch str(8, 4) {
        case "WEBP": return "image/webp"
        case "WAVE": return "audio/x-wav"
        case "AVI ": return "video/x-msvideo"
        default: return nil
        }
    default: break
    }

    // ISO base media formats (ftyp box): images, video and audio share the container
    if str(4, 4) == "ftyp", let brand = str(8, 4)?.trimmingCharacters(in: .whitespaces).lowercased() {
        switch brand {
        case "heic", "heix", "hevc", "hevx", "heim", "heis": return "image/heic"
        case "mif1", "msf1": return "image/heif"
        case "avif", "avis": return "image/avif"
        case "qt": return "video/quicktime"
        case "m4v", "m4vp": return "video/x-m4v"
        case "m4a": return "audio/x-m4a"
        case "isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "mp4v", "avc1", "dash",
             "3gp4", "3gp5", "3gp6", "3gp7": return "video/mp4"
        default: return nil // raws and other ftyp-based formats Clop doesn't handle
        }
    }
    if b.count >= 12, b[0] == 0, b[1] == 0, b[2] == 0, b[3] == 0x0C, str(4, 4) == "JXL " {
        return "image/jxl"
    }
    if b[0] == 0, b[1] == 0, b[2] == 1, b[3] >= 0xB0 { // MPEG program stream / video stream
        return "video/x-mpeg"
    }
    if b[0] == 0xFF, b[1] & 0xE0 == 0xE0 { // MPEG audio frame sync
        return b[1] & 0x06 == 0 ? "audio/aac" : "audio/mpeg" // layer bits 00 = ADTS AAC
    }
    let head = String(decoding: b, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if head.hasPrefix("<!doctype html") || head.contains("<html") {
        return "text/html"
    }
    // Plain text (no NULs or control bytes): report it as such so a media extension on a text
    // file (e.g. checksum refs named *.ogg) doesn't get trusted by the extension fallback.
    if !b.contains(where: { $0 == 0 || $0 < 0x09 || ($0 > 0x0D && $0 < 0x20 && $0 != 0x1B) }) {
        return "text/plain"
    }
    return nil
}

extension FilePath {
    func stripExif() {
        let tempFile = URL.temporaryDirectory.appendingPathComponent(name.string).filePath!
        var args = [EXIFTOOL.string, "-XResolution=72", "-YResolution=72", "-all=", "-tagsFromFile", "@", "-XResolution", "-YResolution", "-Orientation"]
        if Defaults[.preserveColorMetadata] { args += ["-ColorSpaceTags", "-icc_profile"] }
        args += ["-o", tempFile.string, string]
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
            log.debug("\(args.joined(separator: " "))")
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

        // ImageIO returns nil (not a crash) when it can't read the source or can't create a
        // destination for `uttype` (unsupported writable type / unwritable destination volume).
        // Force-unwrapping those traps the process (EXC_BREAKPOINT), so bail out instead.
        guard let src = CGImageSourceCreateWithURL(source.url as CFURL, nil),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, uttype.identifier as CFString, 1, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
        else {
            log.error("Failed to copy EXIF metadata from \(source) to \(self)")
            return
        }

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

        var tagsToKeep: [String] = []
        if stripMetadata {
            tagsToKeep = ["-XResolution", "-YResolution", "-Orientation"]
            if !hdr, Defaults[.preserveColorMetadata] { tagsToKeep += ["-ColorSpaceTags", "-icc_profile"] }
        } else if isVideo {
            tagsToKeep = ["-All:All"]
        }
        var args = [EXIFTOOL.string, "-overwrite_original", "-XResolution=72", "-YResolution=72"]
        args += additionalArgs
        args += ["-extractEmbedded", "-tagsFromFile", source.string]
        args += tagsToKeep
        args += [string]

        log.debug("\(args.map { $0.shellString.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " "))")
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

func generateThumbnail(for url: URL, size: CGSize, onCompletion: @escaping (QLThumbnailRepresentation) -> Void, onFailure: (() -> Void)? = nil) {
    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: size,
        scale: SCREEN_SCALE,
        representationTypes: .all
    )

    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
        DispatchQueue.main.async {
            if let error {
                log.error("Error on generating thumbnail for \(url): \(error.localizedDescription)")
            }
            guard let thumbnail else {
                onFailure?()
                return
            }
            onCompletion(thumbnail)
        }
    }
}

extension Process {
    var commandLine: String {
        "\(executableURL?.path ?? "") \(arguments?.joined(separator: " ") ?? "")"
    }

    /// Was this killed by us, rather than failing on its own?
    ///
    /// Not memoized: `memoz` keys on object identity and caches the first
    /// answer, so a process asked before it was killed stayed "not terminated"
    /// for the rest of its life, and the retry loop treated a cancellation as a
    /// real failure and ran the command again.
    var terminated: Bool {
        _terminated
    }
    var _terminated: Bool {
        // terminationReason and terminationStatus raise an ObjC exception while
        // the process is still running, which no Swift catch can hold.
        if !isRunning, terminationReason == .uncaughtSignal, [SIGKILL, SIGTERM].contains(terminationStatus) {
            return true
        }
        return mainThread { processTerminated.contains(processIdentifier) }
    }
    func terminatedAsync() async -> Bool {
        if !isRunning, terminationReason == .uncaughtSignal, [SIGKILL, SIGTERM].contains(terminationStatus) {
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

    var cmdline: String {
        "\(cmd) \(args.joined(separator: " "))"
    }
}

func tryProcs(_ procs: [Proc], tries: Int, beforeWait: (([Proc: Process]) -> Void)? = nil) throws -> [Proc: Process] {
    var outPipes = procs.dict { ($0, Pipe()) }
    var errPipes = procs.dict { ($0, Pipe()) }

    let cmdline = procs.map(\.cmdline.shellString).joined(separator: "\n\t")
    log.debug("Starting\n\t\(cmdline)")
    var processes: [Proc: Process] = procs.dict { proc in
        guard let p = shellProc(proc.cmd, args: proc.args, out: outPipes[proc], err: errPipes[proc])
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
            // Force unwrapping the pipes here crashed in production (CLOP-12S, CLOP-28F). Detach the
            // old handlers only if the pipes are still around, and let the retry make its own.
            outPipes[p]?.fileHandleForReading.readabilityHandler = nil
            errPipes[p]?.fileHandleForReading.readabilityHandler = nil
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

func tryProc(_ cmd: String, argArray: [[String]], env: [String: String]? = nil, beforeWait: ((Process) -> Void)? = nil) throws -> Process {
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

func tryProc(_ cmd: String, args: [String], tries: Int, env: [String: String]? = nil, beforeWait: ((Process) -> Void)? = nil) throws -> Process {
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

func tryProcAsync(_ cmd: String, args: [String], tries: Int, env: [String: String]? = nil, beforeWait: ((Process) -> Void)? = nil) async throws -> Process {
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

        // The standalone `clop` CLI resolves `applicationScriptsDirectory` to its own
        // bundle id (com.lowtechguys.Clop.CLI), so symlink that directory to the app's
        // own Application Scripts directory to let the CLI find the bundled binaries.
        let cliDir = GLOBAL_BIN_DIR_PARENT.deletingLastPathComponent().appendingPathComponent("\(GLOBAL_BIN_DIR_PARENT.lastPathComponent).CLI")
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
