//
//  main.swift
//  ClopCLI
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import ArgumentParser
import Cocoa
import Foundation
import os
import PDFKit
import System
import UniformTypeIdentifiers

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "main")

let HOME_DIR_REGEX = (try? Regex("^/*?\(NSHomeDirectory())(/)?", as: (Substring, Substring?).self))?.ignoresCase()

extension String {
    var shellString: String {
        guard let homeDirRegex = HOME_DIR_REGEX else {
            return replacingFirstOccurrence(of: NSHomeDirectory(), with: "~")
        }
        return replacing(homeDirRegex, with: { "~" + ($0.1 ?? "") })
    }
}
extension URL {
    var shellString: String {
        isFileURL ? path.shellString : absoluteString
    }
}

extension UserDefaults {
    static let app: UserDefaults? = .init(suiteName: "com.lowtechguys.Clop")
}

var printSemaphore = DispatchSemaphore(value: 1)
func withPrintLock(_ action: () -> Void) {
    printSemaphore.wait()
    action()
    printSemaphore.signal()
}

let SIZE_REGEX = #/(\d+)\s*[xX×]\s*(\d+)/#
let RATIO_REGEX = #/(\d+)[.,]?(\d*)\s*:\s*(\d+)[.,]?(\d*)/#
let CLOP_APP: URL = {
    let u = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    return u.pathExtension == "app" ? u : URL(fileURLWithPath: "/Applications/Clop.app")
}()

var currentRequestIDs: [String] = []
func ensureAppIsRunning() {
    guard !isClopRunning() else {
        return
    }
    NSWorkspace.shared.open(CLOP_APP)
}

/// Whether the app's optimisation service port is registered and accepting requests.
func optimisationServiceIsReady() -> Bool {
    guard let port = CFMessagePortCreateRemote(nil, OPTIMISATION_PORT_ID as CFString) else {
        return false
    }
    CFMessagePortInvalidate(port)
    return true
}

/// Launch the app if needed and wait until its optimisation service is reachable.
/// When the app is already running, the port probe succeeds on the first try and
/// this adds no startup latency.
func waitForOptimisationService(timeout: TimeInterval = 15) {
    ensureAppIsRunning()
    let deadline = Date().addingTimeInterval(timeout)
    while !optimisationServiceIsReady(), Date() < deadline {
        usleep(50000)
    }
}

extension UTType: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        if argument == "video" || argument == "movie" {
            self = .movie
            return
        }
        if argument == "image" || argument == "picture" {
            self = .image
            return
        }
        if let type = UTType(argument), ALL_FORMATS.contains(type) {
            self = type
            return
        }
        if let type = UTType(filenameExtension: argument), ALL_FORMATS.contains(type) {
            self = type
            return
        }
        return nil
    }

    var argDescription: String {
        switch self {
        case .image: "image"
        case .movie, .video: "video"
        default: preferredFilenameExtension ?? identifier
        }
    }
}
extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: UTType) {
        appendInterpolation("\(value.argDescription)")
    }
}

extension PageLayout: ExpressibleByArgument {}
extension FilePath: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        guard FileManager.default.fileExists(atPath: argument) else {
            return nil
        }
        self.init(argument)
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
}

extension NSSize: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        if let size = Int(argument) {
            self.init(width: size, height: size)
            return
        }

        guard let match = try? SIZE_REGEX.firstMatch(in: argument) else {
            return nil
        }
        let width = Int(match.1)!
        let height = Int(match.2)!
        self.init(width: width, height: height)
    }
}

extension CropSize: ExpressibleByArgument {
    public init?(argument: String) {
        if let size = Int(argument) {
            self.init(width: size, height: size)
            return
        }

        if let match = try? RATIO_REGEX.firstMatch(in: argument) {
            var width = Int(match.1)!
            var height = Int(match.3)!
            var widthMagnitude = 0
            var heightMagnitude = 0

            if let decimals = Int(match.2) {
                width = width * pow(10, match.2.count.d).i + decimals
                widthMagnitude = match.2.count
            }
            if let decimals = Int(match.4) {
                height = height * pow(10, match.4.count.d).i + decimals
                heightMagnitude = match.4.count
            }

            if widthMagnitude > heightMagnitude {
                height = height * pow(10, (widthMagnitude - heightMagnitude).d).i
            } else if widthMagnitude < heightMagnitude {
                width = width * pow(10, (heightMagnitude - widthMagnitude).d).i
            }

            self.init(width: width, height: height, isAspectRatio: true)
            return
        }

        guard let match = try? SIZE_REGEX.firstMatch(in: argument) else {
            return nil
        }
        let width = Int(match.1)!
        let height = Int(match.2)!
        self.init(width: width, height: height)
    }
}

func groupListing(_ categories: [(category: String, groups: [CropSizeGroup])]) -> String {
    categories.map { category in
        "\(category.category):\n" + category.groups.map { group in
            let members = group.members.map { "\"\($0)\"" }.joined(separator: ", ")
            return group.members.count > 1 ? "  \(group.name)\n      \(members)" : "  \(group.name)"
        }.joined(separator: "\n")
    }.joined(separator: "\n\n")
}

let DEVICES_STR = """
Devices, grouped by screen aspect ratio.
Devices in a group share the same exact ratio, so cropping for any of them gives the same result.
Both group names and device names are accepted.

""" + groupListing(DEVICE_SIZE_GROUPS)

let PAPER_SIZES_STR = """
Paper sizes, grouped by aspect ratio.
Sizes in a group share the same ratio, so cropping to any of them gives the same result.
Both group names and paper size names are accepted.

""" + groupListing(PAPER_SIZE_GROUPS)

func validateItems(_ items: [String], recursive: Bool, skipErrors: Bool, types: [UTType]) throws -> [URL] {
    var dirs: [URL] = []
    var urls: [URL] = try items.compactMap { item in
        let url = item.contains(":") ? (URL(string: item) ?? URL(fileURLWithPath: item)) : URL(fileURLWithPath: item)
        var isDir = ObjCBool(false)

        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if skipErrors {
                return nil
            }

            throw ValidationError("File \(url.path) does not exist")
        }

        if isDir.boolValue {
            dirs.append(url)
            return nil
        }
        return url
    }.filter { isURLOptimisable($0, types: types) }
    urls += dirs.flatMap { getURLsFromFolder($0, recursive: recursive, types: types) }

    waitForOptimisationService()

    guard isClopRunning() else {
        Clop.exit(withError: CLIError.appNotRunning)
    }
    return urls
}

func sendRequest(urls: [URL], showProgress: Bool, async: Bool, gui: Bool, json: Bool, review: Bool = false, operation: String, _ requestCreator: () -> OptimisationRequest) throws {
    // --review opens the batch window for the user to tweak knobs and press Optimise; the CLI fires
    // the request and returns without waiting (nothing runs until the user confirms in the window).
    if review {
        let req = requestCreator()
        try OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
        printerr("Opened the batch window for \(urls.count) items. Press Optimise there to start.")
        Clop.exit()
    }

    if !async {
        progressPrinter = ProgressPrinter(urls: urls)
        Task {
            await progressPrinter!.startResponsesThread()

            guard showProgress else { return }
            await progressPrinter!.printProgress()
        }
    }

    currentRequestIDs = urls.map(\.absoluteString)
    let req = requestCreator()
    signal(SIGINT, stopCurrentRequests(_:))
    signal(SIGTERM, stopCurrentRequests(_:))

    if showProgress, !async, let progressPrinter {
        for url in urls where url.isFileURL {
            Task { await progressPrinter.startProgressListener(url: url) }
        }
    }

    guard !async else {
        try OPTIMISATION_PORT.sendAndForget(data: req.jsonData)
        printerr("Queued \(urls.count) items for \(operation)")
        if !gui {
            printerr("Use the `--gui` flag to see progress")
        }
        Clop.exit()
    }

    let respData = try OPTIMISATION_PORT.sendAndWait(data: req.jsonData)
    guard respData != nil else {
        Clop.exit(withError: CLIError.optimisationError)
    }

    var allItemsFailed = false
    awaitSync {
        await progressPrinter!.waitUntilDone()

        if showProgress {
            await progressPrinter!.printProgress()
            fflush(stderr)
        }
        await progressPrinter!.printResults(json: json)
        allItemsFailed = await progressPrinter!.allItemsFailed
    }
    if allItemsFailed {
        throw ExitCode.failure
    }
}

let ABSOLUTE_PATH_REGEX = /^(\/|%P)/

func normalizeRelativePath(_ path: FilePath) -> FilePath {
    guard path.isRelative else {
        return path
    }
    return FilePath("\(FileManager.default.currentDirectoryPath)/\(path.string.trimmingPrefix("./"))").lexicallyNormalized()
}

func normalizeRelativeOutput(_ output: String?) -> String? {
    guard let output = output?.ns.expandingTildeInPath else {
        return nil
    }

    if output.contains(ABSOLUTE_PATH_REGEX) {
        return output
    }

    return "\(FileManager.default.currentDirectoryPath)/\(output.trimmingPrefix("./"))"
}

func checkOutputIsDir(_ output: String?, itemCount: Int) throws {
    guard let output, output.contains("/"), !output.contains("%"), itemCount > 1 else {
        return
    }

    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: output, isDirectory: &isDir)
    if exists, !isDir.boolValue {
        throw ValidationError("Output path must be a folder when processing multiple files")
    }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true, attributes: nil)
}

extension UserDefaults {
    var lastAutoIncrementingNumber: Int {
        get {
            integer(forKey: "lastAutoIncrementingNumber")
        }
        set {
            set(newValue, forKey: "lastAutoIncrementingNumber")
        }
    }
}

func getPDFsFromFolder(_ folder: FilePath, recursive: Bool) -> [FilePath] {
    guard let enumerator = FileManager.default.enumerator(
        at: folder.url,
        includingPropertiesForKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey],
        options: [.skipsPackageDescendants]
    ) else {
        return []
    }

    var pdfs: [FilePath] = []

    for case let fileURL as URL in enumerator {
        guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .nameKey, .isDirectoryKey]),
              let isDirectory = resourceValues.isDirectory, let isRegularFile = resourceValues.isRegularFile, let name = resourceValues.name
        else {
            continue
        }

        if isDirectory {
            if !recursive || name.hasPrefix(".") || ["node_modules", ".git"].contains(name) {
                enumerator.skipDescendants()
            }
            continue
        }

        if !isRegularFile {
            continue
        }

        if !name.lowercased().hasSuffix(".pdf") {
            continue
        }
        pdfs.append(FilePath(fileURL.path))
    }
    return pdfs
}

enum ImageFormat: String, CaseIterable, Equatable, Decodable, ExpressibleByArgument {
    case avif, heic, webp

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }

    var utType: UTType? {
        switch self {
        case .avif: .avif
        case .heic: .heic
        case .webp: .webP
        }
    }
}

func parsePDFDPIArgument(_ value: String?, flag: String = "--pdf-dpi") throws -> Int? {
    guard let value, !value.isEmpty else { return nil }
    if value.lowercased() == "adaptive" {
        return PDF_DPI_ADAPTIVE
    }
    let allowed = PDF_DPI_STOPS.map(String.init).joined(separator: ", ")
    guard let int = Int(value) else {
        throw ValidationError("Invalid \(flag) value '\(value)': expected 'adaptive' or one of \(allowed)")
    }
    guard PDF_DPI_STOPS.contains(int) else {
        throw ValidationError("\(flag) must be 'adaptive' or one of \(allowed)")
    }
    return int
}

/// Parse a `--compression` argument: a factor 5..100, plus the keywords each
/// file type supports ('adaptive' for images, 'auto' for the video software encoder).
func parseCompressionArgument(_ value: String?, allowAdaptive: Bool, allowAuto: Bool, flag: String = "--compression") throws -> CompressionQuality? {
    guard let value, !value.isEmpty else { return nil }
    switch value.lowercased() {
    case "adaptive" where allowAdaptive:
        return CompressionQuality(tier: .adaptive, factor: COMPRESSION_FACTOR_NORMAL)
    case "auto" where allowAuto:
        return CompressionQuality(tier: .custom, factor: 0)
    default:
        var allowed = ["a factor between 5 (best quality) and 100 (smallest file)"]
        if allowAdaptive { allowed.append("'adaptive'") }
        if allowAuto { allowed.append("'auto'") }
        guard let factor = Int(value) else {
            throw ValidationError("Invalid \(flag) value '\(value)': expected \(allowed.joined(separator: " or "))")
        }
        guard (5 ... 100).contains(factor) else {
            throw ValidationError("\(flag) factor must be between 5 (best quality) and 100 (smallest file)")
        }
        return CompressionQuality(tier: .custom, factor: factor)
    }
}

func parseVideoEncoderArgument(_ value: String?) throws -> CompressionTier? {
    guard let value, !value.isEmpty else { return nil }
    switch value.lowercased() {
    case "hardware", "fast": return .fast
    case "software", "smaller", "efficient": return .smaller
    case "lossless", "visually-lossless": return .lossless
    case "adaptive": return .adaptive
    default: throw ValidationError("Invalid --encoder value '\(value)': expected 'hardware', 'software', 'lossless' or 'adaptive'")
    }
}

let OUTPUT_TEMPLATE_HELP = """
Output file path or template (defaults to modifying the file in place). In case of cropping multiple files, this needs to be a folder or a template.

The template may contain the following tokens on the filename:
          Date       |      Time
---------------------|--------------
Year              %y | Hour       %H
Month (numeric)   %m | Minutes    %M
Month (name)      %n | Seconds    %S
Day               %d | AM/PM      %p
Weekday           %w |

Source file path (without name)        %P
Source file name (without extension)   %f
Source file extension                  %e

Crop size                  %z
Scale factor               %s
Playback speed factor      %x
Random characters          %r
Auto-incrementing number   %i

For example `--output "~/Desktop/%f_optimised.png" image.png` will generate the file `~/Desktop/image_optimised.png`.

"""

struct CommonOptimisationOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
    var gui = false

    @Flag(name: .shortAndLong, help: "Don't print progress to stderr")
    var noProgress = false

    @Flag(name: .long, help: "Process files and items in the background")
    var async = false

    @Flag(name: .shortAndLong, help: "Optimise all files in subfolders (when using a folder as input)")
    var recursive = false

    @Flag(name: .shortAndLong, help: "Copy file to clipboard after optimisation")
    var copy = false

    @Flag(name: .shortAndLong, help: "Skips missing files and unreachable URLs")
    var skipErrors = false

    @Flag(name: .shortAndLong, help: "Output results as a JSON")
    var json = false

    @Flag(name: .long, help: "Open the batch adjustment window to review/tweak the per-type knobs before optimising, instead of starting immediately")
    var review = false

    @Option(name: .shortAndLong, help: "\(OUTPUT_TEMPLATE_HELP)")
    var output: String? = nil
}

/// Build and send the optimisation request shared by `optimise` and its type subcommands.
func sendOptimisationCommand(
    urls: [URL],
    options: CommonOptimisationOptions,
    crop: NSSize? = nil,
    downscaleFactor: Double? = nil,
    playbackSpeedFactor: Double? = nil,
    aggressive: Bool = false,
    adaptiveOptimisation: Bool? = nil,
    removeAudio: Bool? = nil,
    compression: CompressionQuality? = nil,
    audioBitrate: Int? = nil,
    pdfDPI: Int? = nil,
    pipeline: String? = nil,
    operation: String = "optimisation"
) throws {
    try sendRequest(urls: urls, showProgress: !options.noProgress, async: options.async, gui: options.gui, json: options.json, review: options.review, operation: operation) {
        var out = normalizeRelativeOutput(options.output)
        if urls.count == 1, let url = urls.first, let outExt = out?.filePath?.extension, let inExt = url.filePath?.extension, outExt == inExt {
            out = out!.replacingFirstOccurrence(of: ".\(inExt)", with: "")
        }
        return OptimisationRequest(
            id: String(Int.random(in: 1000 ... 100_000)),
            urls: urls,
            size: crop?.cropSize(),
            downscaleFactor: downscaleFactor,
            changePlaybackSpeedFactor: playbackSpeedFactor,
            hideFloatingResult: !options.gui,
            copyToClipboard: options.copy,
            aggressiveOptimisation: aggressive,
            adaptiveOptimisation: adaptiveOptimisation,
            source: "cli",
            output: out,
            removeAudio: removeAudio,
            pdfDPI: pdfDPI,
            compression: compression,
            audioBitrate: audioBitrate,
            pipeline: pipeline,
            prepareInBatch: options.review
        )
    }
}

/// Build the inline pipeline DSL for a `convert` subcommand run. The optional
/// output template becomes the convert step's `location` parameter.
func convertPipelineDSL(to format: String, output: String?) -> String {
    guard let output = normalizeRelativeOutput(output) else {
        return "convert(to: \(format))"
    }
    return "convert(to: \(format), location: \"\(output)\")"
}

/// Resolve a bundled binary installed by the Clop app. The standalone CLI resolves
/// `applicationScriptsDirectory` to its own bundle id (com.lowtechguys.Clop.CLI), which
/// may not have the bin symlink yet (e.g. before the app has run), so fall back to the
/// app's known Application Scripts locations.
func resolveBundledBinary(_ name: String) -> String? {
    let candidates = [
        BIN_DIR.appendingPathComponent(name).path,
        "\(NSHomeDirectory())/Library/Application Scripts/com.lowtechguys.Clop/bin/\(ARCH)/\(name)",
        "\(NSHomeDirectory())/Library/Application Scripts/com.lowtechguys.Clop-setapp/bin/\(ARCH)/\(name)",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

struct Clop: ParsableCommand {
    struct Convert: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Converts images, videos and audio files to other formats.",
            discussion: """
            Use a type subcommand for the full format list and compression controls:
                clop convert image --to webp photo.png
                clop convert video --to gif screencast.mov
                clop convert audio --to mp3 --bitrate 128 recording.wav

            The legacy direct conversion (`clop convert -f avif|heic|webp -q 60 <images>`)
            keeps working and runs locally without the Clop app.
            """,
            subcommands: [ConvertImageCommand.self, ConvertVideoCommand.self, ConvertAudioCommand.self, ConvertLegacyCommand.self],
            defaultSubcommand: ConvertLegacyCommand.self
        )
    }

    /// The legacy `clop convert` behaviour: avif/heic/webp images converted locally
    /// with the bundled binaries. Hidden default subcommand for backwards compatibility.
    struct ConvertLegacyCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "legacy",
            abstract: "Converts images to HEIC, WebP or AVIF locally, without the Clop app.",
            shouldDisplay: false
        )

        @Option(name: .shortAndLong, help: "Output format (avif, heic, webp)")
        var format: ImageFormat

        @Option(name: .shortAndLong, help: "Quality of the output image (0-100)")
        var quality = 60

        @Option(name: .shortAndLong, help: """
        Output file path or template (defaults to placing the converted file in the same folder as the original).

        The template may contain the following tokens on the filename:

        %y    Year
        %m    Month (numeric)
        %n    Month (name)
        %d    Day
        %w    Weekday

        %H    Hour
        %M    Minutes
        %S  Seconds
        %p  AM/PM

        %P  Source file path (without name)
        %f  Source file name (without extension)
        %e  Source file extension
        %q  Quality

        %r    Random characters
        %i    Auto-incrementing number

        For example `~/Desktop/%f[converted-from-%e]` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image[converted-from-png].webp`.
        The extension of the conversion format is automatically added.

        """)
        var output: String? = nil

        @Flag(name: .long, help: "Replace output file if it already exists")
        var force = false

        @Argument(help: "Files to convert (can be an image or list of images)")
        var files: [FilePath] = []

        var type: UTType!

        static func convertToAVIF(path: FilePath, outFilePath: FilePath, quality: Int) throws -> Bool {
            let args = ["--avif", "-q", "\(quality)", "-o", outFilePath.string, path.string]
            return try runConversionProcess(path: path, outFilePath: outFilePath, executable: "heif-enc", args: args)
        }

        static func convertToHEIC(path: FilePath, outFilePath: FilePath, quality: Int) throws -> Bool {
            let args = ["-q", "\(quality)", "-o", outFilePath.string, path.string]
            return try runConversionProcess(path: path, outFilePath: outFilePath, executable: "heif-enc", args: args)
        }

        static func convertToWebP(path: FilePath, outFilePath: FilePath, quality: Int) throws -> Bool {
            let args = ["-mt", "-q", "\(quality)", "-sharp_yuv", "-metadata", "all", path.string, "-o", outFilePath.string]
            return try runConversionProcess(path: path, outFilePath: outFilePath, executable: "cwebp", args: args)
        }

        @discardableResult
        static func runConversionProcess(path: FilePath, outFilePath: FilePath, executable: String, args: [String]) throws -> Bool {
            guard let launchPath = resolveBundledBinary(executable) else {
                printerr("\(ERROR_X) \(path.string.underline()) failed: `\(executable)` not found. Launch the Clop app once to install its binaries, or use `clop convert image` which runs through the app.")
                return false
            }
            let errPipe = Pipe()

            let process = Process()
            process.launchPath = launchPath
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            process.launch()
            process.waitUntilExit()

            if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: outFilePath.string) {
                printerr("\(ERROR_X) \(path.string.underline()) failed")
                printerr(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                return false
            }
            try? outFilePath.setOptimisationStatusXattr("true")
            return true
        }

        @discardableResult
        static func convert(path: FilePath, format: ImageFormat, quality: Int, output: String?, force: Bool) throws -> Bool {
            guard let stem = path.stem else {
                printerr("\(ERROR_X) Invalid path \(path.shellString.underline())")
                return false
            }
            guard let type = format.utType, let ext = type.preferredFilenameExtension else {
                printerr("\(ERROR_X) Invalid output format \(format) for \(path.shellString.underline())")
                return false
            }

            let output = normalizeRelativeOutput(output)?.replacingOccurrences(of: "%q", with: "\(quality)")
            var outFilePath: FilePath =
                if let output, let outPath = output.filePath {
                    try generateFilePath(
                        template: outPath,
                        for: normalizeRelativePath(path),
                        autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber,
                        mkdir: true
                    )
                } else {
                    path.removingLastComponent().appending(stem)
                }
            outFilePath = outFilePath.isDir ? outFilePath.appending("\(stem).\(ext)") : FilePath("\(outFilePath.string).\(ext)")

            print("\(CIRCLE) Converting \(path.shellString.underline()) to \(format.rawValue.bold())".dim())
            let tempFile = URL.temporaryDirectory.appendingPathComponent(outFilePath.name.string).filePath!
            try? FileManager.default.removeItem(at: tempFile.url)

            let converted = switch format {
            case .avif:
                try convertToAVIF(path: path, outFilePath: tempFile, quality: quality)
            case .heic:
                try convertToHEIC(path: path, outFilePath: tempFile, quality: quality)
            case .webp:
                try convertToWebP(path: path, outFilePath: tempFile, quality: quality)
            }
            guard converted else { return false }

            if FileManager.default.fileExists(atPath: outFilePath.string) {
                if force {
                    try FileManager.default.removeItem(at: outFilePath.url)
                } else {
                    printerr("\(ERROR_X) \(outFilePath.shellString.underline()) already exists, use `--force` to replace")
                    printerr("    \(ARROW) converted file kept at \(tempFile.shellString.underline())".dim())
                    return false
                }
            }
            try FileManager.default.moveItem(at: tempFile.url, to: outFilePath.url)
            print("\(CHECKMARK) \(path.shellString.underline()) \(ARROW) \(outFilePath.shellString.underline())")
            return true
        }

        mutating func validate() throws {
            guard !files.isEmpty else {
                throw ValidationError("At least one image must be specified")
            }
            guard let type = format.utType else {
                throw ValidationError("Invalid image format")
            }
            self.type = type

            files = files.filter { !$0.isDir && $0.exists }
        }

        mutating func run() throws {
            let files = files
            let format = format
            let quality = quality
            let output = output
            let force = force

            let lock = NSLock()
            var successCount = 0
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                do {
                    if try Self.convert(path: files[i], format: format, quality: quality, output: output, force: force) {
                        lock.withLock { successCount += 1 }
                    }
                } catch let error as ClopError {
                    printerr("\(ERROR_X) \(files[i].shellString.underline()) \(ARROW) \(error.localizedDescription)")
                } catch {
                    printerr("\(ERROR_X) \(files[i].shellString.underline()) \(ARROW) \(error.localizedDescription)")
                }
            }
            // Exit non-zero only when every file failed, so callers don't retry work
            // that partially succeeded.
            if successCount == 0, !files.isEmpty {
                throw ExitCode.failure
            }
        }
    }

    struct ConvertImageCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "image",
            abstract: "Convert images to another format through Clop."
        )

        static let allowedFormats = ["webp", "avif", "heic", "jxl", "jpeg", "jpg", "png"]

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: [.short, .long], help: "Target format: \(allowedFormats.joined(separator: ", "))")
        var to: String

        @Option(name: .long, help: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file). Defaults to the app's image compression setting.")
        var compression: String?

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Images, image folders or URLs to convert")
        var items: [String] = []

        mutating func validate() throws {
            to = to.lowercased()
            guard Self.allowedFormats.contains(to) else {
                throw ValidationError("Invalid --to format '\(to)': expected one of \(Self.allowedFormats.joined(separator: ", "))")
            }
            parsedCompression = try parseCompressionArgument(compression, allowAdaptive: false, allowAuto: false)
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: IMAGE_FORMATS)
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                compression: parsedCompression,
                pipeline: convertPipelineDSL(to: to, output: options.output),
                operation: "conversion"
            )
        }
    }

    struct ConvertVideoCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "video",
            abstract: "Convert videos to another format or codec through Clop."
        )

        static let allowedFormats = ["mp4", "gif", "webm", "hevc", "x265", "av1"]

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: [.short, .long], help: "Target format or codec: mp4 (H.264), gif (animated), webm (VP9), hevc (hardware H.265), x265 (software H.265), av1 (SVT-AV1 in MKV)")
        var to: String

        @Option(name: .long, help: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file), or 'auto'. Only applies to mp4 (H.264); the other codecs use tuned fixed settings.")
        var compression: String?

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Videos, video folders or URLs to convert")
        var items: [String] = []

        mutating func validate() throws {
            to = to.lowercased()
            guard Self.allowedFormats.contains(to) else {
                throw ValidationError("Invalid --to format '\(to)': expected one of \(Self.allowedFormats.joined(separator: ", "))")
            }
            parsedCompression = try parseCompressionArgument(compression, allowAdaptive: false, allowAuto: true)
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: VIDEO_FORMATS)
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                compression: parsedCompression,
                pipeline: convertPipelineDSL(to: to, output: options.output),
                operation: "conversion"
            )
        }
    }

    struct ConvertAudioCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "audio",
            abstract: "Convert audio files to another format through Clop."
        )

        static let allowedFormats = ["mp3", "aac", "m4a", "opus", "ogg", "flac", "wav", "aiff"]

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: [.short, .long], help: "Target format: \(allowedFormats.joined(separator: ", "))")
        var to: String

        @Option(name: .long, help: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file), mapped to a bitrate for the target format")
        var compression: String?

        @Option(name: .shortAndLong, help: "Target bitrate in kbps (e.g. 128). Takes priority over --compression. Never upscales, snaps to the allowed bitrates of the target format.")
        var bitrate: Int?

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Audio files, folders of audio files or URLs to convert")
        var items: [String] = []

        mutating func validate() throws {
            to = to.lowercased()
            guard Self.allowedFormats.contains(to) else {
                throw ValidationError("Invalid --to format '\(to)': expected one of \(Self.allowedFormats.joined(separator: ", "))")
            }
            if let bitrate, bitrate <= 0 {
                throw ValidationError("Invalid --bitrate, must be greater than 0")
            }
            parsedCompression = try parseCompressionArgument(compression, allowAdaptive: false, allowAuto: false)
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: AUDIO_FORMATS)
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                compression: parsedCompression,
                audioBitrate: bitrate,
                pipeline: convertPipelineDSL(to: to, output: options.output),
                operation: "conversion"
            )
        }
    }

    struct UncropPdf: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Brings back PDFs to their original size by removing the crop box from PDFs that were cropped non-destructively."
        )

        @Option(name: .shortAndLong, help: "Output file path (defaults to modifying the PDF in place). In case of uncropping multiple files, this needs to be a folder.")
        var output: String? = nil

        @Flag(name: .shortAndLong, help: "Uncrop all PDFs in subfolders (when using a folder as input)")
        var recursive = false

        @Argument(help: "PDFs to uncrop (can be a file, folder, or list of files)")
        var pdfs: [FilePath] = []

        var foundPDFs: [FilePath] = []

        mutating func validate() throws {
            guard output == nil || !output!.isEmpty else {
                throw ValidationError("Output path cannot be empty")
            }

            guard !pdfs.isEmpty else {
                throw ValidationError("At least one PDF file or folder must be specified")
            }

            var isDir: ObjCBool = false
            if let folder = pdfs.first, FileManager.default.fileExists(atPath: folder.string, isDirectory: &isDir), isDir.boolValue {
                foundPDFs = getPDFsFromFolder(folder, recursive: recursive)
            } else {
                foundPDFs = pdfs
            }
            try checkOutputIsDir(output, itemCount: foundPDFs.count)
        }

        mutating func run() throws {
            for pdf in foundPDFs.compactMap({ PDFDocument(url: $0.url) }) {
                let pdfPath = pdf.documentURL!.filePath!
                print("Uncropping \(pdfPath.string)", terminator: "")
                pdf.uncrop()

                let outFilePath: FilePath =
                    if let path = output?.filePath, path.string.contains("/"), path.string.starts(with: "/") {
                        path.isDir ? path.appending(pdfPath.name) : path.dir / generateFileName(template: path.name.string, for: pdfPath, autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber)
                    } else if let path = output?.filePath, path.string.contains("/"), let path = FileManager.default.currentDirectoryPath.filePath?.appending(path.string) {
                        path.isDir ? path.appending(pdfPath.name) : path.dir / generateFileName(template: path.name.string, for: pdfPath, autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber)
                    } else if let output {
                        pdfPath.dir / generateFileName(template: output, for: pdfPath, autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber)
                    } else {
                        pdfPath
                    }

                print(" -> saved to \(outFilePath.string)")
                pdf.write(to: outFilePath.url)
            }
        }
    }

    struct CropPdf: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Crops PDFs to a specific aspect ratio without optimising them. The operation is non-destructive and can be reversed with the `uncrop-pdf` command."
        )

        @Option(help: "Crops pages to fit the screen of a specific device (e.g. iPad Air)")
        var forDevice: String? = nil

        @Option(help: "Crops pages to fit a specific paper size (e.g. A4, Letter)")
        var paperSize: String? = nil

        @Option(help: "Crops pages to fit the aspect ratio of a resolution (e.g. 1640x2360) or a specific aspect ratio (e.g. 16:9)")
        var aspectRatio: CropSize? = nil

        @Flag(name: .shortAndLong, help: "Crop all PDFs in subfolders (when using a folder as input)")
        var recursive = false

        @Flag(name: .shortAndLong, help: "Extend pages with empty paper instead of clipping content, keeping everything visible (e.g. fit a book to a phone screen without cutting off text)")
        var extend = false

        @Flag(name: .long, help: "List possible devices that can be passed to --for-device")
        var listDevices = false

        @Flag(name: .long, help: "List possible paper sizes that can be passed to --paper-size")
        var listPaperSizes = false

        @Option(help: """
        Allows forcing a page layout on all PDF pages:
            auto: Crop pages based on their longest edge, so that horizontal pages stay horizontal and vertical pages stay vertical
            portrait: Force all pages to be cropped to vertical or portrait layout
            landscape: Force all pages to be cropped to horizontal or landscape layout
        """)
        var pageLayout = PageLayout.auto

        @Option(name: .shortAndLong, help: "Output file path (defaults to modifying the PDF in place). In case of cropping multiple files, this needs to be a folder.")
        var output: String? = nil

        @Argument(help: "PDFs to crop (can be a file, folder, or list of files)")
        var pdfs: [FilePath] = []

        var foundPDFs: [FilePath] = []
        var ratio: Double!

        mutating func validate() throws {
            if listDevices {
                print(DEVICES_STR)
                throw ExitCode.success
            }

            if listPaperSizes {
                print(PAPER_SIZES_STR)
                throw ExitCode.success
            }

            if let forDevice, findDeviceSize(named: forDevice) == nil {
                throw ValidationError("Unknown device \"\(forDevice)\", use --list-devices to see possible values")
            }
            if let paperSize, findPaperSize(named: paperSize) == nil {
                throw ValidationError("Unknown paper size \"\(paperSize)\", use --list-paper-sizes to see possible values")
            }
            ratio = forDevice.flatMap { findDeviceSize(named: $0)?.fractionalAspectRatio }
                ?? paperSize.flatMap { findPaperSize(named: $0)?.fractionalAspectRatio }
                ?? aspectRatio?.fractionalAspectRatio
            guard let ratio else {
                throw ValidationError("Invalid aspect ratio, at least one of --for-device, --paper-size or --aspect-ratio must be specified")
            }
            guard ratio > 0 else {
                throw ValidationError("Invalid aspect ratio, must be greater than 0")
            }
            guard output == nil || !output!.isEmpty else {
                throw ValidationError("Output path cannot be empty")
            }
            guard !pdfs.isEmpty else {
                throw ValidationError("At least one PDF file or folder must be specified")
            }

            var isDir: ObjCBool = false
            if let folder = pdfs.first, FileManager.default.fileExists(atPath: folder.string, isDirectory: &isDir), isDir.boolValue {
                foundPDFs = getPDFsFromFolder(folder, recursive: recursive)
            } else {
                foundPDFs = pdfs
            }
            try checkOutputIsDir(output, itemCount: foundPDFs.count)
        }

        mutating func run() throws {
            for pdf in foundPDFs.compactMap({ PDFDocument(url: $0.url) }) {
                let pdfPath = pdf.documentURL!.filePath!
                print("\(extend ? "Extending" : "Cropping") \(pdfPath.string) to aspect ratio \(factorStr(ratio!))", terminator: "")
                if extend {
                    pdf.extendTo(aspectRatio: ratio, alwaysPortrait: pageLayout == .portrait, alwaysLandscape: pageLayout == .landscape)
                } else {
                    pdf.cropTo(aspectRatio: ratio, alwaysPortrait: pageLayout == .portrait, alwaysLandscape: pageLayout == .landscape)
                }

                let outFilePath: FilePath =
                    if let path = output?.filePath, path.string.contains("/"), path.string.starts(with: "/") {
                        path.isDir ? path.appending(pdfPath.name) : path.dir / generateFileName(template: path.name.string, for: pdfPath, autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber)
                    } else if let path = output?.filePath, path.string.contains("/"), let path = FileManager.default.currentDirectoryPath.filePath?.appending(path.string) {
                        path.isDir ? path.appending(pdfPath.name) : path.dir / generateFileName(template: path.name.string, for: pdfPath, autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber)
                    } else if let output {
                        pdfPath.dir / generateFileName(template: output, for: pdfPath, autoIncrementingNumber: &UserDefaults.standard.lastAutoIncrementingNumber)
                    } else {
                        pdfPath
                    }

                print(" -> saved to \(outFilePath.string)")
                pdf.write(to: outFilePath.url)
            }
        }
    }

    struct StripExif: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Deletes EXIF metadata from images and videos."
        )

        @Flag(name: .shortAndLong, help: "Strip EXIF metadata from all files in subfolders (when using a folder as input)")
        var recursive = false

        @Option(name: .long, help: "Types of files to optimise (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`) (default: \(ALL_FORMATS.map(\.argDescription).joined(separator: ", ")))")
        var types: [UTType] = []

        @Option(name: .long, help: "Types of files to exclude from optimisation (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`)")
        var excludeTypes: [UTType] = []

        @Argument(help: "Images and videos to strip EXIF metadata from (can be a file, folder, or list of files)")
        var files: [FilePath] = []

        var foundPaths: [FilePath] = []

        @discardableResult
        static func strip(path: FilePath) -> Bool {
            guard FileManager.default.fileExists(atPath: path.string) else {
                printSemaphore.wait()
                printerr("\(ERROR_X) \(path.string.underline()) does not exist")
                printSemaphore.signal()
                return false
            }
            guard path.extension?.lowercased() != "pdf" else {
                printSemaphore.wait()
                printerr("\(EXCLAMATION) \(path.string.underline()) is a PDF and `strip-exif` does not work on this type of file")
                printSemaphore.signal()
                return false
            }
            guard let exiftool = resolveBundledBinary("exiftool") else {
                printSemaphore.wait()
                printerr("\(ERROR_X) \(path.string.underline()) failed: `exiftool` not found. Launch the Clop app once to install its binaries.")
                printSemaphore.signal()
                return false
            }

            let tempFile = URL.temporaryDirectory.appendingPathComponent(path.name.string).filePath!
            let args = [exiftool, "-XResolution=72", "-YResolution=72"]
                + ["-all=", "-tagsFromFile", "@"]
                + ["-XResolution", "-YResolution", "-Orientation"]
                + ["-o", tempFile.string, path.string]
            let errPipe = Pipe()

            let process = Process()
            process.launchPath = "/usr/bin/perl"
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            process.launch()
            process.waitUntilExit()

            printSemaphore.wait()
            defer {
                printSemaphore.signal()
            }

            if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: tempFile.string) {
                printerr("\(ERROR_X) \(path.string.underline()) failed")
                printerr(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                return false
            }
            if path.hasOptimisationStatusXattr() {
                try? tempFile.setOptimisationStatusXattr("true")
            }
            try? FileManager.default.removeItem(at: path.url)
            try? FileManager.default.moveItem(at: tempFile.url, to: path.url)

            print("\(CHECKMARK) \(path.string.underline()) done".dim())
            return true
        }

        mutating func validate() throws {
            guard !files.isEmpty else {
                throw ValidationError("At least one file or folder must be specified")
            }

            var isDir: ObjCBool = false
            if let folder = files.first, FileManager.default.fileExists(atPath: folder.string, isDirectory: &isDir), isDir.boolValue {
                if types.isEmpty {
                    types = ALL_FORMATS
                }

                if !excludeTypes.isEmpty {
                    foundPaths = getURLsFromFolder(folder.url, recursive: recursive, types: types.filter { !excludeTypes.contains($0) }).compactMap(\.filePath)
                } else {
                    foundPaths = getURLsFromFolder(folder.url, recursive: recursive, types: types).compactMap(\.filePath)
                }
            } else {
                foundPaths = files
            }
        }

        mutating func run() throws {
            let foundPaths = foundPaths
            let lock = NSLock()
            var successCount = 0
            DispatchQueue.concurrentPerform(iterations: foundPaths.count) { i in
                if Self.strip(path: foundPaths[i]) {
                    lock.withLock { successCount += 1 }
                }
            }
            // Exit non-zero only when every file failed, so callers don't retry work
            // that partially succeeded.
            if successCount == 0, !foundPaths.isEmpty {
                throw ExitCode.failure
            }
        }
    }

    struct Crop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Crop and optimise images, videos and PDFs to a specific size or aspect ratio."
        )

        @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
        var gui = false

        @Flag(name: .shortAndLong, help: "Don't print progress to stderr")
        var noProgress = false

        @Flag(name: .long, help: "Process files and items in the background")
        var async = false

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation")
        var aggressive = false

        @Option(name: .long, help: "PDF aggressive DPI: 'adaptive' or one of \(PDF_DPI_STOPS.map(String.init).joined(separator: ", ")). Overrides the app's stored aggressive DPI setting for this run.")
        var pdfDpi: String?

        @Flag(name: .long, inversion: .prefixedNo, help: "Convert detail heavy images to JPEG and low-detail ones to PNG for better compression")
        var adaptiveOptimisation: Bool = UserDefaults.app?.bool(forKey: "adaptiveImageSize") ?? false

        @Flag(name: .long, help: "Crop by centering on features in the image")
        var smartCrop = false

        @Flag(name: .long, help: "Removes audio from optimised videos")
        var removeAudio = false

        @Flag(name: .shortAndLong, help: "Optimise all files in subfolders (when using a folder as input)")
        var recursive = false

        @Option(name: .long, help: "Types of files to optimise (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`) (default: \(ALL_FORMATS.map(\.argDescription).joined(separator: ", ")))")
        var types: [UTType] = []

        @Option(name: .long, help: "Types of files to exclude from optimisation (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`)")
        var excludeTypes: [UTType] = []

        @Flag(name: .shortAndLong, help: "Copy file to clipboard after optimisation")
        var copy = false

        @Flag(name: .long, help: "Skips missing files and unreachable URLs\n")
        var skipErrors = false

        @Flag(name: .shortAndLong, help: "Output results as a JSON")
        var json = false

        @Flag(
            name: .shortAndLong,
            help: "When the size is specified as a single number, it will crop the longer of width or height to that number.\nThe shorter edge will be calculated automatically while keeping the original aspect ratio.\n\nExample: `clop crop --long-edge --size 1920` will crop a landscape 2400x1350 image to 1920x1080, and a portrait 1350x2400 image to 1080x1920\n"
        )
        var longEdge = false

        @Option(name: .shortAndLong, help: """
        Output file path or template (defaults to modifying the file in place). In case of cropping multiple files, this needs to be a folder or a template.

        The template may contain the following tokens on the filename:
                  Date       |      Time
        ---------------------|--------------
        Year              %y | Hour       %H
        Month (numeric)   %m | Minutes    %M
        Month (name)      %n | Seconds    %S
        Day               %d | AM/PM      %p
        Weekday           %w |

        Source file path (without name)        %P
        Source file name (without extension)   %f
        Source file extension                  %e

        Crop size                  %z
        Random characters          %r
        Auto-incrementing number   %i

        For example `--size 128 --output "~/Desktop/%f @ %zpx.png" image.png` will generate the file `~/Desktop/image @ 128px.png`.

        """)
        var output: String? = nil

        @Option(
            name: .shortAndLong,
            help: """
            Downscales and crops the image, video or PDF to a specific size (e.g. 1200x630) or aspect ratio (e.g. 16:9).

            When the size is specified as a single number, it will crop the longer of width or height to that number.
            Example: cropping an image from 100x120 to 50x50 will first downscale it to 50x60 and then crop it to 50x50

            Use 0 for width or height to have it calculated automatically while keeping the original aspect ratio. (e.g. `128x0` or `0x720`)
            """
        )
        var size: CropSize

        var urls: [URL] = []

        @Argument(help: "Images, videos, PDFs or URLs to crop (can be a file, folder, or list of files)")
        var items: [String] = []

        mutating func validate() throws {
            if longEdge, size.width != size.height {
                throw ValidationError("When using --long-edge, the size must be a single number")
            }
            if size == .zero {
                throw ValidationError("Invalid size, must be greater than 0")
            }

            if types.isEmpty {
                types = ALL_FORMATS
            }

            if !excludeTypes.isEmpty {
                urls = try validateItems(items, recursive: recursive, skipErrors: skipErrors, types: types.filter { !excludeTypes.contains($0) })
            } else {
                urls = try validateItems(items, recursive: recursive, skipErrors: skipErrors, types: types)
            }
        }

        mutating func run() throws {
            let parsedPdfDpi = try parsePDFDPIArgument(pdfDpi)
            try sendRequest(urls: urls, showProgress: !noProgress, async: async, gui: gui, json: json, operation: "cropping") {
                var out = normalizeRelativeOutput(output)
                if urls.count == 1, let url = urls.first, let outExt = out?.filePath?.extension, let inExt = url.filePath?.extension, outExt == inExt {
                    out = out!.replacingFirstOccurrence(of: ".\(inExt)", with: "")
                }
                return OptimisationRequest(
                    id: String(Int.random(in: 1000 ... 100_000)),
                    urls: urls,
                    size: size.withLongEdge(longEdge).withSmartCrop(smartCrop),
                    downscaleFactor: 0.9,
                    changePlaybackSpeedFactor: nil,
                    hideFloatingResult: !gui,
                    copyToClipboard: copy,
                    aggressiveOptimisation: aggressive,
                    adaptiveOptimisation: adaptiveOptimisation,
                    source: "cli",
                    output: out,
                    removeAudio: removeAudio,
                    pdfDPI: parsedPdfDpi
                )
            }
        }
    }

    struct Downscale: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Downscale and optimise images, videos and audio files by a certain factor. For audio, the factor is applied to the bitrate."
        )

        @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
        var gui = false

        @Flag(name: .shortAndLong, help: "Don't print progress to stderr")
        var noProgress = false

        @Flag(name: .long, help: "Process files and items in the background")
        var async = false

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation")
        var aggressive = false

        @Option(name: .long, help: "PDF aggressive DPI: 'adaptive' or one of \(PDF_DPI_STOPS.map(String.init).joined(separator: ", ")). Overrides the app's stored aggressive DPI setting for this run.")
        var pdfDpi: String?

        @Flag(name: .long, inversion: .prefixedNo, help: "Convert detail heavy images to JPEG and low-detail ones to PNG for better compression")
        var adaptiveOptimisation = false

        @Flag(name: .long, help: "Removes audio from optimised videos")
        var removeAudio = false

        @Flag(name: .shortAndLong, help: "Optimise all files in subfolders (when using a folder as input)")
        var recursive = false

        @Option(name: .long, help: "Types of files to optimise (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`) (default: \(ALL_FORMATS.map(\.argDescription).joined(separator: ", ")))")
        var types: [UTType] = []

        @Option(name: .long, help: "Types of files to exclude from optimisation (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`)")
        var excludeTypes: [UTType] = []

        @Flag(name: .shortAndLong, help: "Copy file to clipboard after optimisation")
        var copy = false

        @Flag(name: .shortAndLong, help: "Skips missing files and unreachable URLs")
        var skipErrors = false

        @Flag(name: .shortAndLong, help: "Output results as a JSON")
        var json = false

        @Option(name: .shortAndLong, help: """
        Output file path or template (defaults to modifying the file in place). In case of cropping multiple files, this needs to be a folder or a template.

        The template may contain the following tokens on the filename:
                  Date       |      Time
        ---------------------|--------------
        Year              %y | Hour       %H
        Month (numeric)   %m | Minutes    %M
        Month (name)      %n | Seconds    %S
        Day               %d | AM/PM      %p
        Weekday           %w |

        Source file path (without name)        %P
        Source file name (without extension)   %f
        Source file extension                  %e

        Scale factor               %s
        Random characters          %r
        Auto-incrementing number   %i

        For example `--factor 0.5 --output "~/Desktop/%f @ %sx.png" image.png` will generate the file `~/Desktop/image @ 0.5x.png`.

        """)
        var output: String? = nil

        @Option(help: "Makes the image, video or audio smaller by a certain amount (1.0 means no change, 0.5 means half the size / half the bitrate)")
        var factor = 0.5

        var urls: [URL] = []

        @Argument(help: "Images, videos, audio files or URLs to downscale (can be a file, folder, or list of files)")
        var items: [String] = []

        mutating func validate() throws {
            guard factor >= 0.01, factor <= 0.99 else {
                throw ValidationError("Invalid downscale factor, must be greater than 0 and less than 1")
            }

            if types.isEmpty {
                types = ALL_FORMATS
            }

            if !excludeTypes.isEmpty {
                urls = try validateItems(items, recursive: recursive, skipErrors: skipErrors, types: types.filter { !excludeTypes.contains($0) })
            } else {
                urls = try validateItems(items, recursive: recursive, skipErrors: skipErrors, types: types)
            }

            try checkOutputIsDir(output, itemCount: urls.count)
        }

        mutating func run() throws {
            let parsedPdfDpi = try parsePDFDPIArgument(pdfDpi)
            try sendRequest(urls: urls, showProgress: !noProgress, async: async, gui: gui, json: json, operation: "downscaling") {
                var out = normalizeRelativeOutput(output)
                if urls.count == 1, let url = urls.first, let outExt = out?.filePath?.extension, let inExt = url.filePath?.extension, outExt == inExt {
                    out = out!.replacingFirstOccurrence(of: ".\(inExt)", with: "")
                }
                return OptimisationRequest(
                    id: String(Int.random(in: 1000 ... 100_000)),
                    urls: urls,
                    size: nil,
                    downscaleFactor: factor,
                    changePlaybackSpeedFactor: nil,
                    hideFloatingResult: !gui,
                    copyToClipboard: copy,
                    aggressiveOptimisation: aggressive,
                    adaptiveOptimisation: adaptiveOptimisation,
                    source: "cli",
                    output: out,
                    removeAudio: removeAudio,
                    pdfDPI: parsedPdfDpi
                )
            }
        }
    }

    struct Optimise: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Optimise images, videos, audio files and PDFs.",
            discussion: """
            Use a type subcommand for type-specific options:
                clop optimise image --compression 70 photo.png
                clop optimise video --encoder software screencast.mov
                clop optimise pdf --dpi 96 document.pdf
                clop optimise audio --bitrate 128 recording.wav

            Or pass files and folders directly to optimise mixed types with shared options.
            """,
            subcommands: [ImageCommand.self, VideoCommand.self, PdfCommand.self, AudioCommand.self, FilesCommand.self],
            defaultSubcommand: FilesCommand.self
        )
    }

    /// The bare `clop optimise` behaviour: mixed file types, folders and the legacy
    /// flag set. Hidden default subcommand so `clop optimise <files>` keeps working.
    struct FilesCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "files",
            abstract: "Optimise mixed file types and folders (default when no subcommand is given).",
            shouldDisplay: false
        )

        @OptionGroup var options: CommonOptimisationOptions

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation (legacy preset, same as --compression \(COMPRESSION_FACTOR_AGGRESSIVE))")
        var aggressive = false

        @Option(
            name: .long,
            help: "How hard to compress images, videos and audio: a factor from 5 (best quality) to 100 (smallest file), 'adaptive' (best format per image) or 'auto' (let the video encoder pick). Takes priority over --aggressive."
        )
        var compression: String?

        @Option(name: .long, help: "PDF aggressive DPI: 'adaptive' or one of \(PDF_DPI_STOPS.map(String.init).joined(separator: ", ")). Overrides the app's stored aggressive DPI setting for this run.")
        var pdfDpi: String?

        @Flag(name: .long, inversion: .prefixedNo, help: "Convert detail heavy images to JPEG and low-detail ones to PNG for better compression (legacy, same as --compression adaptive)")
        var adaptiveOptimisation: Bool = UserDefaults.app?.bool(forKey: "adaptiveImageSize") ?? false

        @Option(name: .long, help: "Types of files to optimise (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`) (default: \(ALL_FORMATS.map(\.argDescription).joined(separator: ", ")))")
        var types: [UTType] = []

        @Option(name: .long, help: "Types of files to exclude from optimisation (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`)")
        var excludeTypes: [UTType] = []

        @Flag(name: .long, help: "Removes audio from optimised videos")
        var removeAudio = false

        @Option(help: "Speeds up or slow down the video by a certain amount (1 means no change, 2 means twice as fast, 0.5 means 2x slower)")
        var playbackSpeedFactor: Double? = nil

        @Option(help: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)")
        var downscaleFactor: Double? = nil

        @Option(help: "Downscales and crops the image, video or PDF to a specific size (e.g. 1200x630)\nExample: cropping an image from 100x120 to 50x50 will first downscale it to 50x60 and then crop it to 50x50")
        var crop: NSSize? = nil

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Images, videos, audio files, PDFs or URLs to optimise (can be a file, folder, or list of files)")
        var items: [String] = []

        mutating func validate() throws {
            if let size = crop, size == .zero {
                throw ValidationError("Invalid size, must be greater than 0")
            }
            if let factor = downscaleFactor, factor <= 0 || factor > 1 {
                throw ValidationError("Invalid downscale factor, must be greater than 0 and at most 1")
            }
            parsedCompression = try parseCompressionArgument(compression, allowAdaptive: true, allowAuto: true)

            if types.isEmpty {
                types = ALL_FORMATS
            }

            if !excludeTypes.isEmpty {
                urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: types.filter { !excludeTypes.contains($0) })
            } else {
                urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: types)
            }

            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                crop: crop,
                downscaleFactor: downscaleFactor,
                playbackSpeedFactor: playbackSpeedFactor,
                aggressive: aggressive,
                adaptiveOptimisation: adaptiveOptimisation,
                removeAudio: removeAudio,
                compression: parsedCompression,
                pdfDPI: parsePDFDPIArgument(pdfDpi)
            )
        }
    }

    struct ImageCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "image",
            abstract: "Optimise images with image-specific controls."
        )

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: .long, help: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file), or 'adaptive' to let Clop pick the best format per image")
        var compression: String?

        @Option(help: "Makes the image smaller by a certain amount (1.0 means no resize, 0.5 means half the size)")
        var downscaleFactor: Double? = nil

        @Option(help: "Downscales and crops the image to a specific size (e.g. 1200x630)")
        var crop: NSSize? = nil

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Images, image folders or URLs to optimise")
        var items: [String] = []

        mutating func validate() throws {
            if let size = crop, size == .zero {
                throw ValidationError("Invalid size, must be greater than 0")
            }
            if let factor = downscaleFactor, factor <= 0 || factor > 1 {
                throw ValidationError("Invalid downscale factor, must be greater than 0 and at most 1")
            }
            parsedCompression = try parseCompressionArgument(compression, allowAdaptive: true, allowAuto: false)
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: IMAGE_FORMATS)
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                crop: crop,
                downscaleFactor: downscaleFactor,
                compression: parsedCompression
            )
        }
    }

    struct VideoCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "video",
            abstract: "Optimise videos with video-specific controls."
        )

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: .long, help: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file), or 'auto' to let the software encoder pick the quality")
        var compression: String?

        @Option(name: .long, help: "Which encoder to use: 'hardware' (fast, larger files), 'software' (slow, smaller files), 'lossless' (no perceptible quality loss) or 'adaptive' (best encoder per file)")
        var encoder: String?

        @Flag(name: .long, help: "Removes audio from optimised videos")
        var removeAudio = false

        @Option(help: "Speeds up or slow down the video by a certain amount (1 means no change, 2 means twice as fast, 0.5 means 2x slower)")
        var playbackSpeedFactor: Double? = nil

        @Option(help: "Makes the video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)")
        var downscaleFactor: Double? = nil

        @Option(help: "Downscales and crops the video to a specific size (e.g. 1280x720)")
        var crop: NSSize? = nil

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Videos, video folders or URLs to optimise")
        var items: [String] = []

        mutating func validate() throws {
            if let size = crop, size == .zero {
                throw ValidationError("Invalid size, must be greater than 0")
            }
            if let factor = downscaleFactor, factor <= 0 || factor > 1 {
                throw ValidationError("Invalid downscale factor, must be greater than 0 and at most 1")
            }
            let tier = try parseVideoEncoderArgument(encoder)
            let cq = try parseCompressionArgument(compression, allowAdaptive: false, allowAuto: true)
            if tier != nil || cq != nil {
                parsedCompression = CompressionQuality(tier: tier ?? cq?.tier ?? .custom, factor: cq?.factor ?? 50)
            }
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: VIDEO_FORMATS)
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                crop: crop,
                downscaleFactor: downscaleFactor,
                playbackSpeedFactor: playbackSpeedFactor,
                removeAudio: removeAudio,
                compression: parsedCompression
            )
        }
    }

    struct PdfCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pdf",
            abstract: "Optimise PDFs with PDF-specific controls."
        )

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: .long, help: "Rendering DPI: 'adaptive' (pick per document) or one of \(PDF_DPI_STOPS.map(String.init).joined(separator: ", ")). Lower DPI means smaller files.")
        var dpi: String?

        @Option(help: "Downscales and crops the PDF pages to a specific size (e.g. 1200x630)")
        var crop: NSSize? = nil

        var urls: [URL] = []
        var parsedDPI: Int?

        @Argument(help: "PDFs, folders of PDFs or URLs to optimise")
        var items: [String] = []

        mutating func validate() throws {
            if let size = crop, size == .zero {
                throw ValidationError("Invalid size, must be greater than 0")
            }
            parsedDPI = try parsePDFDPIArgument(dpi, flag: "--dpi")
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: [.pdf])
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                crop: crop,
                pdfDPI: parsedDPI
            )
        }
    }

    struct AudioCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "audio",
            abstract: "Optimise audio files with audio-specific controls."
        )

        @OptionGroup var options: CommonOptimisationOptions

        @Option(name: .long, help: "How hard to compress: a factor from 5 (best quality) to 100 (smallest file), mapped to a bitrate for the output format")
        var compression: String?

        @Option(name: .shortAndLong, help: "Target bitrate in kbps (e.g. 128). Takes priority over --compression. Never upscales, snaps to the allowed bitrates of the output format.")
        var bitrate: Int?

        var urls: [URL] = []
        var parsedCompression: CompressionQuality?

        @Argument(help: "Audio files, folders of audio files or URLs to optimise")
        var items: [String] = []

        mutating func validate() throws {
            if let bitrate, bitrate <= 0 {
                throw ValidationError("Invalid --bitrate, must be greater than 0")
            }
            parsedCompression = try parseCompressionArgument(compression, allowAdaptive: false, allowAuto: false)
            urls = try validateItems(items, recursive: options.recursive, skipErrors: options.skipErrors, types: AUDIO_FORMATS)
            try checkOutputIsDir(options.output, itemCount: urls.count)
        }

        mutating func run() throws {
            try sendOptimisationCommand(
                urls: urls, options: options,
                compression: parsedCompression,
                audioBitrate: bitrate
            )
        }
    }

    struct PipelineCommand: ParsableCommand {
        struct List: ParsableCommand {
            /// Why an automation row would be hidden by default. `nil` means show it normally.
            enum HiddenReason: String { case orphaned, missing }

            static let configuration = CommandConfiguration(
                abstract: "List saved pipelines and folder automations."
            )

            @Flag(name: .shortAndLong, help: "Output as JSON")
            var json = false

            @Flag(name: .long, help: "Also show hidden entries: orphaned folder automations (folder no longer watched), empty pipelines, and broken references")
            var all = false

            /// Classify one automation row. `source` is the dict key (a dir path or a fixed
            /// source name), `resolved` is the pipeline after following any library reference,
            /// `isReference`/`resolvedExists` describe the reference state, `watchedDirs` is the
            /// list of currently-watched folders for this file type.
            static func hiddenReason(
                source: String, resolved: CLIPipeline, raw: CLIPipeline,
                watchedDirs: [String]
            ) -> HiddenReason? {
                // Broken reference: points at a library id that no longer exists.
                if raw.provenance == .reference, raw.libraryID != nil, resolved.id == raw.id {
                    return .missing
                }
                // Empty: no steps to run (displayText is the canonical "(no steps)" sentinel).
                if resolved.displayText == "(no steps)" {
                    return .missing
                }
                // Orphaned folder automation: source is an absolute path not in watchedDirs.
                if source.hasPrefix("/"), !watchedDirs.contains(source) {
                    return .orphaned
                }
                return nil
            }

            mutating func run() throws {
                let saved = readSavedPipelines()

                guard !json else {
                    var result: [String: Any] = ["saved": saved.map(\.rawDict)]
                    var automations: [String: Any] = [:]
                    for (key, label, _) in PIPELINE_AUTOMATION_KEYS {
                        guard let dict = UserDefaults.app?.dictionary(forKey: key) as? [String: [String]], !dict.isEmpty else { continue }
                        automations[label] = dict.mapValues { $0.compactMap { CLIPipeline.from(json: $0)?.rawDict } }
                    }
                    result["automations"] = automations
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: data, encoding: .utf8) ?? "{}")
                    return
                }

                if saved.isEmpty {
                    print("No saved pipelines".dim())
                } else {
                    print("Saved pipelines:".bold())
                    for p in saved {
                        let type = (p.fileType ?? "any").yellow()
                        let origin = p.provenance == .builtin ? " \("built-in".dim())" : ""
                        print("  \((p.name ?? p.id).green()) (\(type))\(origin)\(p.flagTags)")
                        print("    \(p.displayText)")
                    }
                }

                for (key, label, dirsKey) in PIPELINE_AUTOMATION_KEYS {
                    guard let dict = UserDefaults.app?.dictionary(forKey: key) as? [String: [String]], !dict.isEmpty else { continue }
                    let watchedDirs = UserDefaults.app?.array(forKey: dirsKey) as? [String] ?? []
                    var lines: [String] = []
                    for (source, pipelines) in dict.sorted(by: { $0.key < $1.key }) {
                        for pJSON in pipelines {
                            guard let p = CLIPipeline.from(json: pJSON) else { continue }
                            let resolved = p.resolve(in: saved)
                            let hidden = List.hiddenReason(source: source, resolved: resolved, raw: p, watchedDirs: watchedDirs)
                            if hidden != nil, !all { continue }
                            let name = resolved.name.map { " -> \($0.green())" } ?? ""
                            let origin = p.provenance == .reference ? " \("reference".dim())" : ""
                            let hiddenTag = hidden.map { " \($0.rawValue.red())" } ?? ""
                            lines.append("  \(source.shellString.yellow())\(name)\(origin)\(hiddenTag)\(resolved.flagTags)")
                            lines.append("    \(resolved.displayText)")
                        }
                    }
                    guard !lines.isEmpty else { continue }
                    print("\nAutomations for \(label.bold()):")
                    for line in lines {
                        print(line)
                    }
                }
            }

        }

        struct Show: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show the steps of a saved pipeline."
            )

            @Flag(name: .shortAndLong, help: "Output the raw pipeline JSON")
            var json = false

            @Argument(help: "Name of the saved pipeline")
            var name: String

            mutating func run() throws {
                guard let p = readSavedPipelines().first(where: { ($0.name ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                    throw ValidationError("No saved pipeline named '\(name)'. Use `clop pipeline list` to see available pipelines.")
                }
                if json {
                    let data = try JSONSerialization.data(withJSONObject: p.rawDict, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: data, encoding: .utf8) ?? "{}")
                } else {
                    print(p.displayText)
                }
            }
        }

        struct Run: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Run a pipeline on files: a saved pipeline name or inline steps.",
                discussion: """
                The pipeline argument can be the name of a saved pipeline, or inline steps like:

                    clop pipeline run 'crop(width: 1600) -> convert(to: webp)' image.png

                Inline pipelines run exactly the steps written (no implicit optimisation pass).
                Add an explicit `optimise` step if you want one. Saved pipelines keep their
                "skip optimisation" setting: when off, files are optimised before the steps run.

                Steps: optimise, downscale, lowerBitrate, convert, crop, extractPagesAsImages,
                copy, move, rename, delete, if, ifNot, removeAudio, changeSpeed, runScript,
                runShortcut, copyToClipboard, copyLinkForSending, shelveWith, uploadWith, openWith
                """
            )

            @Flag(name: .long, help: "Show the floating result thumbnail when the pipeline finishes")
            var showResult = false

            @Flag(name: .long, help: "Hide result. Run silently without showing the floating result thumbnail")
            var hideResult = false

            /// Backwards-compatible hidden alias for --show-result (was the only way before 3.1).
            @Flag(name: [.customShort("g"), .customLong("gui")], help: .hidden)
            var gui = false

            @Flag(name: .shortAndLong, help: "Don't print progress to stderr")
            var noProgress = false

            @Flag(name: .long, help: "Process files and items in the background")
            var async = false

            @Flag(name: .shortAndLong, help: "Optimise all files in subfolders (when using a folder as input)")
            var recursive = false

            @Flag(name: .shortAndLong, help: "Skips missing files and unreachable URLs")
            var skipErrors = false

            @Flag(name: .shortAndLong, help: "Output results as a JSON")
            var json = false

            @Option(name: .long, help: "Types of files to process (e.g. generic types like `image`, `video`, `pdf` or specific ones like `jpeg`, `png`, `mp4`)")
            var types: [UTType] = []

            @Argument(help: "Saved pipeline name or inline pipeline steps")
            var pipeline: String

            @Argument(help: "Files to run the pipeline on (can be a file, folder, or list of files)")
            var items: [String] = []

            var urls: [URL] = []

            /// Resolved visibility: hidden unless the user asked to show it. `--show-result`
            /// and the legacy `--gui` both reveal it; `--hide-result` is the explicit default.
            var resolvedHideResult: Bool {
                !(showResult || gui)
            }

            mutating func validate() throws {
                if showResult || gui, hideResult {
                    throw ValidationError("Pass either --show-result (or --gui) or --hide-result, not both")
                }

                let savedNames = readSavedPipelines().compactMap(\.name)
                let isSavedName = savedNames.contains { $0.localizedCaseInsensitiveCompare(pipeline) == .orderedSame }
                if !isSavedName {
                    let invalid = invalidPipelineSteps(pipeline)
                    guard invalid.isEmpty else {
                        throw ValidationError("""
                        '\(pipeline)' is not a saved pipeline name and contains unknown steps: \(invalid.joined(separator: ", "))
                        Known steps: \(KNOWN_PIPELINE_STEPS.joined(separator: ", "))
                        Saved pipelines: \(savedNames.isEmpty ? "none" : savedNames.joined(separator: ", "))
                        """)
                    }
                }

                if types.isEmpty {
                    types = ALL_FORMATS
                }
                urls = try validateItems(items, recursive: recursive, skipErrors: skipErrors, types: types)
                guard !urls.isEmpty else {
                    throw ValidationError("At least one file or folder must be specified")
                }
            }

            mutating func run() throws {
                let showUI = !resolvedHideResult
                try sendRequest(urls: urls, showProgress: !noProgress, async: async, gui: showUI, json: json, operation: "pipeline") {
                    OptimisationRequest(
                        id: String(Int.random(in: 1000 ... 100_000)),
                        urls: urls,
                        size: nil,
                        downscaleFactor: nil,
                        changePlaybackSpeedFactor: nil,
                        hideFloatingResult: resolvedHideResult,
                        copyToClipboard: false,
                        aggressiveOptimisation: false,
                        adaptiveOptimisation: nil,
                        source: "cli",
                        pipeline: pipeline
                    )
                }
            }
        }

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Save a pipeline to the library so it can be run by name and used in the app."
            )

            @Option(name: .long, help: "File type this pipeline applies to (image, video, pdf, audio). Omit for any type.")
            var fileType: String?

            @Flag(name: .long, help: "Skip optimisation. Pass the original file straight into the pipeline (use when convert/downscale/crop already shrink it)")
            var skipOptimisation = false

            @Flag(name: .long, help: "Hide result. Run silently without showing the floating result thumbnail")
            var hideResult = false

            @Flag(name: .long, help: "Replace an existing pipeline with the same name")
            var force = false

            @Argument(help: "Name for the pipeline")
            var name: String

            @Argument(help: "Pipeline steps, e.g. 'crop(width: 1600) -> convert(to: webp)'")
            var steps: String

            mutating func validate() throws {
                if let fileType, !["image", "video", "pdf", "audio"].contains(fileType) {
                    throw ValidationError("Invalid file type '\(fileType)': must be image, video, pdf or audio")
                }
                let invalid = invalidPipelineSteps(steps)
                guard invalid.isEmpty else {
                    throw ValidationError("Unknown steps: \(invalid.joined(separator: ", "))\nKnown steps: \(KNOWN_PIPELINE_STEPS.joined(separator: ", "))")
                }
            }

            mutating func run() throws {
                guard let defaults = UserDefaults.app else {
                    throw ValidationError("Can't access Clop defaults")
                }
                var pipelines = defaults.array(forKey: "savedPipelines") as? [String] ?? []
                let existingIdx = pipelines.firstIndex {
                    (CLIPipeline.from(json: $0)?.name ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
                }
                if existingIdx != nil, !force {
                    throw ValidationError("A pipeline named '\(name)' already exists, use `--force` to replace it")
                }

                // Steps are left empty on purpose: the app re-parses `rawText` on decode,
                // which keeps the CLI free of the full step model.
                var dict: [String: Any] = [
                    "id": UUID().uuidString,
                    "name": name,
                    "rawText": steps,
                    "steps": [Any](),
                    "skipOptimisation": skipOptimisation,
                    "hideResult": hideResult,
                ]
                if let fileType {
                    dict["fileType"] = fileType
                }
                let data = try JSONSerialization.data(withJSONObject: dict)
                let json = String(data: data, encoding: .utf8)!

                if let existingIdx {
                    pipelines[existingIdx] = json
                } else {
                    pipelines.append(json)
                }
                defaults.set(pipelines, forKey: "savedPipelines")
                print("\(CHECKMARK) Saved pipeline \(name.green()): \(steps)")
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete a saved pipeline."
            )

            @Argument(help: "Name of the saved pipeline to delete")
            var name: String

            mutating func run() throws {
                guard let defaults = UserDefaults.app else {
                    throw ValidationError("Can't access Clop defaults")
                }
                var pipelines = defaults.array(forKey: "savedPipelines") as? [String] ?? []
                let countBefore = pipelines.count
                let name = name
                pipelines.removeAll {
                    (CLIPipeline.from(json: $0)?.name ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
                }
                guard pipelines.count < countBefore else {
                    throw ValidationError("No saved pipeline named '\(name)'")
                }
                defaults.set(pipelines, forKey: "savedPipelines")
                print("\(CHECKMARK) Deleted pipeline \(name.green())")
            }
        }

        struct Prompt: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "prompt",
                abstract: "Print an LLM-ready reference of the pipeline DSL: every step, parameter, value set, caveat, and how to run or save a pipeline.",
                discussion: """
                Feed it to an LLM so it can author Clop pipelines for you. Append your request as
                the final argument and use -c/--copy to place the whole thing on the clipboard:

                    clop pipeline prompt -c "shrink all my screenshots to webp under 500KB"

                The LLM should reply with a single line: a bare pipeline string to run with
                `clop pipeline run`, or a full `clop pipeline add`/`attach` command when the request
                is to save or automate it.

                Use --compact for a much shorter prompt (~1.7k tokens) that fits small-context,
                on-device models; the default prompt is richer (~5.3k tokens) and suits larger models.
                """
            )

            @Flag(name: .shortAndLong, help: "Copy the generated prompt to the clipboard")
            var copy = false

            @Flag(name: .long, help: "Emit a shorter prompt that fits small-context models (e.g. on-device models limited to ~4k tokens)")
            var compact = false

            @Argument(help: "Optional task appended to the end as the request for the LLM")
            var task: [String] = []

            mutating func run() throws {
                let taskText = task.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = pipelinePromptContext(task: taskText.isEmpty ? nil : taskText, compact: compact)
                print(text)
                if copy {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    FileHandle.standardError.write("\n\(CHECKMARK) Copied prompt to clipboard.\n".data(using: .utf8) ?? Data())
                }
            }
        }

        // MARK: - Attach

        struct Attach: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Attach a pipeline to a source (clipboard, dropZone, or a folder path) for a specific file type."
            )

            @Argument(help: "Saved pipeline name/id or inline steps, e.g. 'crop(width: 1600) -> convert(to: webp)'.")
            var pipeline: String

            @Option(name: .long, help: "Source to attach to: clipboard, dropZone, or an absolute folder path.")
            var source: String

            @Option(name: .long, help: "File type: image, video, pdf, or audio.")
            var type: String

            @Flag(name: .long, help: "Skip optimisation pass before the pipeline runs.")
            var skipOptimisation = false

            @Flag(name: .long, help: "Hide the floating result thumbnail.")
            var hideResult = false

            mutating func validate() throws {
                guard ["image", "video", "pdf", "audio"].contains(type) else {
                    throw ValidationError("Invalid --type '\(type)': must be image, video, pdf, or audio")
                }
                let (resolved, _) = resolvePipelineArg(pipeline)
                if case let .invalid(unknown) = resolved {
                    let savedNames = readSavedPipelines().compactMap(\.name)
                    throw ValidationError("""
                    '\(pipeline)' is not a saved pipeline name/id and contains unknown steps: \(unknown.joined(separator: ", "))
                    Known steps: \(KNOWN_PIPELINE_STEPS.joined(separator: ", "))
                    Saved pipelines: \(savedNames.isEmpty ? "none" : savedNames.joined(separator: ", "))
                    """)
                }
            }

            mutating func run() throws {
                guard let defaults = UserDefaults.app else {
                    throw ValidationError("Can't access Clop defaults")
                }

                let pipelineJSON: String
                let label: String

                let (resolved, found) = resolvePipelineArg(pipeline)
                switch resolved {
                case .reference:
                    let f = found!
                    let dict: [String: Any] = [
                        "id": UUID().uuidString,
                        "libraryID": f.id,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: dict)
                    pipelineJSON = String(data: data, encoding: .utf8)!
                    label = f.name ?? f.id
                case .inline:
                    let pipelineData: [String: Any] = [
                        "id": UUID().uuidString,
                        "rawText": pipeline,
                        "steps": [Any](),
                        "skipOptimisation": skipOptimisation,
                        "hideResult": hideResult,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: pipelineData)
                    pipelineJSON = String(data: data, encoding: .utf8)!
                    label = pipeline
                case .invalid:
                    throw ValidationError("Invalid pipeline '\(pipeline)'")
                }

                // A folder source is keyed by its normalized absolute path, matching how the app
                // stores watched dirs and looks up folder automations.
                let folder = normalizedFolderSource(source)
                let storedSource = folder ?? source

                let key = automationKey(for: type)
                var automationDict = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
                var list = automationDict[storedSource] ?? []
                list.append(pipelineJSON)
                automationDict[storedSource] = list
                defaults.set(automationDict, forKey: key)

                // A folder automation only fires while Clop watches the folder AND automatic
                // processing for that type is enabled, so make sure both hold.
                var notes: [String] = []
                if let folder {
                    let dirsKey = watchedDirsKey(for: type)
                    var dirs = defaults.array(forKey: dirsKey) as? [String] ?? defaultWatchedDirs(for: type)
                    if !dirs.contains(folder) {
                        dirs.append(folder)
                        defaults.set(dirs, forKey: dirsKey)
                        notes.append("now watching this folder")
                    }
                    let (enabledKey, enabledDefault) = watcherEnabledKey(for: type)
                    if !(defaults.object(forKey: enabledKey) as? Bool ?? enabledDefault) {
                        defaults.set(true, forKey: enabledKey)
                        notes.append("enabled automatic \(type) processing")
                    }
                }

                let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))".dim()
                print("\(CHECKMARK) Attached to \(storedSource.yellow()) (\(type.green())): \(label)\(suffix)")
            }
        }

        // MARK: - Detach

        struct Detach: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove one or all pipelines attached to a source/type."
            )

            @Option(name: .long, help: "Source: clipboard, dropZone, or an absolute folder path.")
            var source: String

            @Option(name: .long, help: "File type: image, video, pdf, or audio.")
            var type: String

            @Option(name: .long, help: "0-based index of the pipeline to remove. Mutually exclusive with --all.")
            var index: Int?

            @Flag(name: .long, help: "Remove all pipelines for this source/type. Mutually exclusive with --index.")
            var all = false

            mutating func validate() throws {
                guard ["image", "video", "pdf", "audio"].contains(type) else {
                    throw ValidationError("Invalid --type '\(type)': must be image, video, pdf, or audio")
                }
                switch (index, all) {
                case (.some, true):
                    throw ValidationError("Pass either --index or --all, not both")
                case (.none, false):
                    throw ValidationError("Pass either --index <n> or --all")
                default:
                    break
                }
            }

            mutating func run() throws {
                guard let defaults = UserDefaults.app else {
                    throw ValidationError("Can't access Clop defaults")
                }

                let key = automationKey(for: type)
                var automationDict = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]

                // Resolve the stored key: a folder source normalizes to an absolute path, but fall
                // back to the raw source for automations saved before normalization existed.
                let folder = normalizedFolderSource(source)
                let storedSource: String = {
                    if let folder, automationDict[folder] != nil { return folder }
                    if automationDict[source] != nil { return source }
                    return folder ?? source
                }()

                guard var list = automationDict[storedSource], !list.isEmpty else {
                    throw ValidationError("No pipelines attached to '\(source)' for \(type)")
                }

                if all {
                    let removed = list.count
                    automationDict.removeValue(forKey: storedSource)
                    defaults.set(automationDict, forKey: key)
                    print("\(CHECKMARK) Removed \(removed) pipeline\(removed == 1 ? "" : "s") from \(storedSource.yellow()) (\(type.green()))")
                } else if let idx = index {
                    guard list.indices.contains(idx) else {
                        throw ValidationError("Index \(idx) is out of range (0..\(list.count - 1))")
                    }
                    list.remove(at: idx)
                    if list.isEmpty {
                        automationDict.removeValue(forKey: storedSource)
                    } else {
                        automationDict[storedSource] = list
                    }
                    defaults.set(automationDict, forKey: key)
                    print("\(CHECKMARK) Removed pipeline at index \(idx) from \(storedSource.yellow()) (\(type.green()))")
                }

                // If this was a folder and no automations remain for it, stop watching it for this
                // type (only touch an explicitly-stored dirs list, so we never materialize defaults).
                if let folder, automationDict[storedSource] == nil,
                   var dirs = defaults.array(forKey: watchedDirsKey(for: type)) as? [String],
                   dirs.contains(where: { $0 == folder || $0 == storedSource })
                {
                    dirs.removeAll { $0 == folder || $0 == storedSource }
                    defaults.set(dirs, forKey: watchedDirsKey(for: type))
                    print("  \("Stopped watching this folder for \(type)".dim())")
                }
            }
        }

        // MARK: - Preset

        struct Preset: ParsableCommand {
            struct Add: ParsableCommand {
                static let configuration = CommandConfiguration(
                    abstract: "Add a preset zone to the drop zone."
                )

                @Argument(help: "Name of the preset zone.")
                var name: String

                @Argument(help: "Saved pipeline name/id or inline steps, e.g. 'convert(to: webp)'.")
                var pipeline: String

                @Option(name: .long, help: "File type this preset applies to: image, video, pdf, or audio. Omit for all types.")
                var type: String?

                @Option(name: .long, help: "SF Symbol name for the preset zone icon.")
                var icon = "wand.and.stars"

                @Flag(name: .long, help: "Skip optimisation pass before the pipeline runs.")
                var skipOptimisation = false

                @Flag(name: .long, help: "Hide the floating result thumbnail.")
                var hideResult = false

                @Flag(name: .long, help: "Replace an existing preset zone with the same id.")
                var force = false

                mutating func validate() throws {
                    if let t = type, !["image", "video", "pdf", "audio"].contains(t) {
                        throw ValidationError("Invalid --type '\(t)': must be image, video, pdf, or audio")
                    }
                    let (resolved, _) = resolvePipelineArg(pipeline)
                    if case let .invalid(unknown) = resolved {
                        let savedNames = readSavedPipelines().compactMap(\.name)
                        throw ValidationError("""
                        '\(pipeline)' is not a saved pipeline name/id and contains unknown steps: \(unknown.joined(separator: ", "))
                        Known steps: \(KNOWN_PIPELINE_STEPS.joined(separator: ", "))
                        Saved pipelines: \(savedNames.isEmpty ? "none" : savedNames.joined(separator: ", "))
                        """)
                    }
                }

                mutating func run() throws {
                    guard let defaults = UserDefaults.app else {
                        throw ValidationError("Can't access Clop defaults")
                    }

                    let typeRawValue = type // already validated as image/video/pdf/audio or nil
                    let zoneID = "\(name)-\(typeRawValue ?? "all")"

                    let pipelineDict: [String: Any]
                    let (resolved, found) = resolvePipelineArg(pipeline)
                    switch resolved {
                    case .reference:
                        let f = found!
                        pipelineDict = [
                            "id": UUID().uuidString,
                            "libraryID": f.id,
                        ]
                    case .inline:
                        pipelineDict = [
                            "id": UUID().uuidString,
                            "rawText": pipeline,
                            "steps": [Any](),
                            "skipOptimisation": skipOptimisation,
                            "hideResult": hideResult,
                        ]
                    case .invalid:
                        throw ValidationError("Invalid pipeline '\(pipeline)'")
                    }

                    var zoneDict: [String: Any] = [
                        "id": zoneID,
                        "icon": icon,
                        "name": name,
                        "pipeline": pipelineDict,
                    ]
                    if let t = typeRawValue {
                        zoneDict["type"] = t
                    }

                    let data = try JSONSerialization.data(withJSONObject: zoneDict)
                    let zoneJSON = String(data: data, encoding: .utf8)!

                    var zones = defaults.array(forKey: "presetZones") as? [String] ?? []
                    if let existingIdx = zones.firstIndex(where: { zoneJSON in
                        guard let obj = (try? JSONSerialization.jsonObject(with: zoneJSON.data(using: .utf8) ?? Data())) as? [String: Any] else { return false }
                        return obj["id"] as? String == zoneID
                    }) {
                        guard force else {
                            throw ValidationError("A preset zone with id '\(zoneID)' already exists. Use --force to replace it.")
                        }
                        zones[existingIdx] = zoneJSON
                        print("\(CHECKMARK) Replaced preset zone \(name.green()) (type: \(typeRawValue ?? "all"))")
                    } else {
                        zones.append(zoneJSON)
                        print("\(CHECKMARK) Added preset zone \(name.green()) (type: \(typeRawValue ?? "all"))")
                    }
                    defaults.set(zones, forKey: "presetZones")
                }
            }

            struct Remove: ParsableCommand {
                static let configuration = CommandConfiguration(
                    abstract: "Remove a preset zone by name (and optional type)."
                )

                @Argument(help: "Name of the preset zone to remove.")
                var name: String

                @Option(name: .long, help: "File type of the preset zone: image, video, pdf, or audio. Omit for the 'all types' zone.")
                var type: String?

                mutating func validate() throws {
                    if let t = type, !["image", "video", "pdf", "audio"].contains(t) {
                        throw ValidationError("Invalid --type '\(t)': must be image, video, pdf, or audio")
                    }
                }

                mutating func run() throws {
                    guard let defaults = UserDefaults.app else {
                        throw ValidationError("Can't access Clop defaults")
                    }

                    let zoneID = "\(name)-\(type ?? "all")"
                    var zones = defaults.array(forKey: "presetZones") as? [String] ?? []
                    let countBefore = zones.count
                    zones.removeAll {
                        ((try? JSONSerialization.jsonObject(with: $0.data(using: .utf8) ?? Data())) as? [String: Any])?["id"] as? String == zoneID
                    }
                    guard zones.count < countBefore else {
                        throw ValidationError("No preset zone with id '\(zoneID)' found. Use `clop pipeline list` (or check preset zone names) to verify.")
                    }
                    defaults.set(zones, forKey: "presetZones")
                    print("\(CHECKMARK) Removed preset zone \(name.green()) (type: \(type ?? "all"))")
                }
            }

            static let configuration = CommandConfiguration(
                commandName: "preset",
                abstract: "Manage drop zone preset zones.",
                subcommands: [Add.self, Remove.self]
            )

        }

        static let configuration = CommandConfiguration(
            commandName: "pipeline",
            abstract: "Manage and run Clop pipelines (saved presets and inline step sequences).",
            subcommands: [List.self, Show.self, Run.self, Add.self, Delete.self, Prompt.self, Attach.self, Detach.self, Preset.self]
        )

    }

    static let configuration = CommandConfiguration(
        abstract: "Clop: optimise, crop and downscale images, videos, audio files and PDFs",
        subcommands: [
            Optimise.self,
            Crop.self,
            Downscale.self,
            Convert.self,
            CropPdf.self,
            UncropPdf.self,
            StripExif.self,
            PipelineCommand.self,
        ]
    )
}

// MARK: - Pipeline CLI helpers

/// Step names supported by the app's pipeline DSL. Used only for early CLI-side
/// validation; the app's `parsePipelineStep` in Automation.swift is the source of truth.
let KNOWN_PIPELINE_STEPS = [
    "optimise", "downscale", "lowerBitrate", "convert", "crop", "extractPagesAsImages",
    "targetSize", "stripExif", "watermark", "capFps", "normalize",
    "copy", "move", "rename", "delete", "if", "ifNot", "removeAudio", "changeSpeed",
    "runScript", "runShortcut", "copyToClipboard", "copyLinkForSending", "fork",
    "shelveWith", "uploadWith", "openWith",
]

/// (automation Defaults key, human label, watched-dirs Defaults key for that type).
/// The dirs key lists the folders Clop watches for that type; a folder automation
/// whose source path is NOT in that list is an orphan (the folder was removed but the
/// automation lingered). Fixed sources (clipboard, dropZone, …) are never orphans.
let PIPELINE_AUTOMATION_KEYS = [
    ("pipelinesToRunOnImage", "images", "imageDirs"),
    ("pipelinesToRunOnVideo", "videos", "videoDirs"),
    ("pipelinesToRunOnPdf", "PDFs", "pdfDirs"),
    ("pipelinesToRunOnAudio", "audio", "audioDirs"),
]

/// Append the user's task (if any) to a generated prompt, with a shared closing instruction.
func appendPipelineTask(_ task: String?, to out: String) -> String {
    guard let task, !task.isEmpty else { return out }
    return out + "\n\n---\n\n## Task\n\n\(task)\n\nReturn ONE line: a bare pipeline string, or a full `clop pipeline add`/`attach` command if the request is to save or automate it.\n"
}

/// Compact variant of `pipelinePromptContext`, ~1.7k tokens, for small-context (on-device) models.
/// Keep in sync with the full prompt and with the steps in Automation.swift.
func compactPipelinePromptContext(task: String?) -> String {
    let out = #"""
    # Clop pipeline DSL (compact)

    You write Clop pipelines that transform image/video/pdf/audio files. Reply with ONE line, nothing
    else (add a one-line note only if a caveat matters). That line is one of:
    - a bare pipeline string (`crop(longEdge: 1600) -> convert(to: webp)`) for a one-off on named files;
    - `clop pipeline attach '<steps>' --source <source> --type <type>` to run automatically on a source;
    - `clop pipeline add [--file-type <type>] <name> '<steps>'` to save a reusable named pipeline.

    Choosing the output:
    - Request names a folder ("photos in Downloads", "PDFs in ~/Reports"): attach with `--source <folder>`
      (`~` is fine). The folder starts being watched, so new files of that type run the pipeline.
    - "when I copy", "clipboard": `--source clipboard`. "dropped on Clop": `--source dropZone`.
    - "save a pipeline", "preset": `clop pipeline add` (or `clop pipeline preset add`).
    - otherwise: a bare pipeline string.
    With `--type`/`--file-type` the pipeline is ALREADY scoped to that broad type, so don't restate it
    with `if(types: <t>)` (redundant). But `types:` also takes specific formats, so still use it to
    NARROW further (e.g. `if(types: jpeg webp)` under `--type image`) or to split MIXED-type runs.

    Syntax: steps joined by `->`, left to right. `name(key: value, ...)`; no-param steps can be bare.
    Quote strings/paths/regex; bare values fine for enums/numbers. A step that doesn't fit the input type
    is skipped. Inline `run` does EXACTLY your steps (no implicit optimise; add `optimise` for smaller files).
    A saved/attached pipeline optimises first unless "skip optimisation" is set. Default location is
    `inPlace`, except `convert`/`extractPagesAsImages` default to `sameFolder`.

    ## Steps ([types]; defaults in (), value sets after :)
    - optimise(encoder, adaptive, dpi, location) [all]. encoder img/pdf/audio: medium|aggressive|lossless;
      video: fast|slowHighQuality|visuallyLossless. adaptive (img, may change ext). dpi (pdf): 300|150|72|48.
    - downscale(factor 0..1, location) [image,video,audio] (for audio this lowers the bitrate).
    - lowerBitrate(kbps) [audio]: 192|160|128|96|64 (never upscales; snaps to allowed).
    - convert(to, location) [image,video,audio] (sameFolder). img: webp|avif|heic|jxl|jpeg|png|gif;
      video: mp4|hevc|x265|av1|webm|gif (AV1 video = `av1`, NOT the `avif` image format);
      audio: m4a|mp3|ogg|flac|wav|aiff. No-op if already that format.
    - crop(width, height, longEdge, location) [image,video]. Give >=1; missing side keeps aspect; longEdge = longest side.
    - extractPagesAsImages(format jpeg|png, quality low|medium|high, location) [pdf] (sameFolder).
    - targetSize(size) [all]: iteratively compress under a limit, e.g. 500KB, 10MB, 25MB. No trailing `optimise`.
    - stripExif [image,video]. watermark(image, position bottomRight|bottomLeft|topRight|topLeft|center,
      opacity 0..1, scale 0.15, location) [image,video].
    - removeAudio [video]. changeSpeed(factor) [video,audio]. capFps(fps) [video]. normalize(lufs -16) [audio].
    - copy(to) / move(to) / rename(to) / delete(path)  (delete(path: "sourceFile") removes the input file).
    - runScript(path | code): inline `code` is one line, no `->`; file is $1 / $CLOP_INPUT_FILE; a path it
      prints replaces the file. runShortcut(name) [image,video,pdf].
    - copyToClipboard(format path|imageData|markdown, relativeTo). copyLinkForSending(expiration 1m|15m|1h|6h|1d|3d|never).
      fork(location) surfaces a second card. shelveWith(app yoink|dockside|dropover). uploadWith(app dropshare). openWith(app).

    ## Filters (if / ifNot gate the rest of the pipeline; no else, no branch)
    `if(...)` continues only when every key holds (AND); `ifNot(...)` inverts; a failed filter silently
    stops the file. Keys: regex (filename, capture groups -> $1..), types (e.g. `jpeg png webp`),
    nameContains, nameIs, fileSizeGreaterThan/fileSizeLowerThan (bytes), minFileSize (`2mb`),
    widthGreaterThan/widthLowerThan, heightGreaterThan/heightLowerThan, minResolution (`640x480`),
    dpiGreaterThan/dpiLowerThan, copiedBy (clipboard source app/bundle id).
    Mixed types: filters don't branch, so `if(types: image) -> ... -> if(types: video) -> ...` is broken
    (the 2nd gate never passes). "Do X to all, Y to one type" = narrow at the end:
    `optimise -> if(types: image) -> convert(to: webp)`. "Different output per type" = TWO commands, one
    per `--type` (no `--type image,video`): attach `convert(to: webp)` --type image, AND `convert(to: mp4)` --type video.

    ## location & path tokens
    location: inPlace | sameFolder | temporaryFolder | a path template. Tokens (usable in location,
    copy/move/rename `to`, watermark `image`): %f name, %e ext, %P parent, %F full path, %y year,
    %m month, %n month name, %d day, %w weekday, %H hour, %M min, %S sec, %p AM/PM, %r 5 random letters,
    %i counter. $1.. = regex capture groups. ~ = home. No extension in a template -> it's appended.

    ## Avoid double encoding
    crop/downscale/convert already re-encode AND compress, so don't add a trailing `optimise`. Consecutive
    inPlace steps batch into one pass; a non-inPlace location ends the batch and starts a new encode (this
    is how multi-output pipelines are built).

    ## Commands
    - run now:  `clop pipeline run '<steps>' file...`
    - save:     `clop pipeline add [--file-type t] [--skip-optimisation] [--hide-result] <name> '<steps>'`
    - automate: `clop pipeline attach '<steps>' --source <clipboard|dropZone|folder> --type <t>`
                (a folder source is auto-watched; remove with `clop pipeline detach --source <s> --type <t> --all`)
    - preset:   `clop pipeline preset add '<name>' '<steps>' [--type t] [--icon <sf-symbol>]`

    ## Examples
    - `optimise -> convert(to: webp)`
    - `targetSize(size: 10MB)`
    - `changeSpeed(factor: 2.0) -> removeAudio -> optimise(encoder: fast)`
    - `clop pipeline attach 'crop(longEdge: 1600) -> convert(to: webp, location: "~/Sync/Optimised/") -> copyToClipboard(format: markdown)' --source ~/Downloads --type image`
    - `clop pipeline attach 'convert(to: webp)' --source clipboard --type image`
    - `clop pipeline add --file-type image 'Web ready' 'convert(to: webp)'`
    """#
    return appendPipelineTask(task, to: out)
}

/// LLM-ready reference for the pipeline DSL, emitted by `clop pipeline prompt`.
/// Hand-maintained mirror of `ALL_STEP_TEMPLATES` + `parsePipelineStep` in Automation.swift
/// (which aren't in the CLI target). Keep in sync when steps/params change there.
/// `compact` emits a shorter variant for small-context models (see `compactPipelinePromptContext`).
func pipelinePromptContext(task: String?, compact: Bool = false) -> String {
    if compact { return compactPipelinePromptContext(task: task) }
    var out = #"""
    # Clop pipeline DSL

    You write Clop pipelines: ordered sequences of steps that transform image, video, PDF and
    audio files. Translate the request into ONE line and reply with just that line (plus a one-line
    note only if a caveat matters), nothing else. That line is one of:

    - a bare pipeline string like `crop(longEdge: 1600) -> convert(to: webp)`, for a one-off the user
      runs now on specific files (they will wrap it in `clop pipeline run`);
    - a full `clop pipeline attach '<steps>' --source <source> --type <type>` command, when the
      request is to run automatically on a source (a folder, the clipboard, the drop zone);
    - a full `clop pipeline add [--file-type <type>] <name> '<steps>'` command, when the request is
      to save a reusable named pipeline to the library.

    ## Choosing what to output

    - The request names a folder ("every photo in Downloads", "all PDFs in ~/Reports", "whenever I
      save a video to ~/Movies"): attach to that folder with `--source <that folder path>`. `~` is
      fine; the folder starts being watched, so every new file of that type added to it runs the pipeline.
    - "whenever I copy ...", "from the clipboard", "anything I paste": use `--source clipboard`.
      "dropped on Clop", "the drop zone": use `--source dropZone`.
    - "save a pipeline called X", "make a preset I can reuse": use `clop pipeline add` (or
      `clop pipeline preset add` for a drop-zone preset zone).
    - Anything else (a one-off on specific files the user names): a bare pipeline string.

    Prefer ONE command. A single `attach` with inline steps both starts watching the folder and runs
    the pipeline; you don't need a separate `add` first unless the user explicitly wants it saved by name.

    ## File-type filtering (IMPORTANT)

    When you emit `attach --type <t>` or `add --file-type <t>`, the pipeline is ALREADY scoped to that
    broad type (image/video/pdf/audio), so do NOT restate the SAME broad type with `if(types: <t>)`:
    `if(types: image)` under `--type image` is redundant noise, and a step that doesn't apply to the
    input type is skipped on its own anyway. You SHOULD still use `if(types: ...)` when you need to
    narrow FURTHER, because `types:` also takes specific formats/extensions: e.g. `if(types: jpeg png
    webp)` to act only on those image formats even under `--type image`. And use it to discriminate
    between types in a MIXED-type run (an all-types drop-zone preset, or a bare `clop pipeline run`
    over a folder of mixed files).

    ## Syntax

    - Steps are separated by `->`, evaluated left to right: `crop(width: 1600) -> convert(to: webp)`.
    - Each step is `name(key: value, key: value)`. No-parameter steps can be bare: `removeAudio`,
      `stripExif`, `normalize`, `copyToClipboard`, `copyLinkForSending`.
    - Quote string, path and regex values: `move(to: "~/Pictures/%y/")`, `if(regex: "^IMG_")`.
      Bare values are fine for enums/numbers: `convert(to: webp)`, `downscale(factor: 0.5)`.
    - File types: `image`, `video`, `pdf`, `audio`. Each step lists the types it applies to;
      a step that doesn't apply to the input is skipped.

    ## Execution model (IMPORTANT)

    - An inline pipeline (`clop pipeline run '...'`) runs EXACTLY the steps you write, with NO
      implicit optimisation pass. If you want compression, add an explicit `optimise` step.
    - A saved pipeline honours its "skip optimisation" flag: when off, files are optimised first,
      then your steps run.
    - Most processing steps default to `location: inPlace` (replace the original). `convert` and
      `extractPagesAsImages` default to `location: sameFolder`.

    ## Steps

    ### Processing

    - `optimise(encoder, adaptive, dpi, location)`: compress in place. [image, video, pdf, audio]
      - `encoder`: images/pdf/audio use `medium` (default), `aggressive`, `lossless`;
        video uses `fast` (hardware H.264), `slowHighQuality` (software, smaller), `visuallyLossless`.
      - `adaptive`: `true`/`false` (images only; may change the extension, e.g. PNG↔JPEG).
      - `dpi`: PDF only, overrides encoder. 300 = no downsampling, 150 = screen reading, 72 = screen, 48 = smallest.
    - `downscale(factor, location)`: scale down, keeps aspect ratio. [image, video, audio]
      - `factor`: 0.0–1.0 (0.5 = half, 0.75 = 75%). For audio this lowers the bitrate.
    - `lowerBitrate(kbps, location)`: set audio bitrate. Never upscales, snaps to allowed bitrates. [audio]
      - `kbps`: e.g. 192, 160, 128, 96, 64.
    - `convert(to, location)`: change format, then re-encode and compress to that format during the same pass. [image, video, audio] (default location: sameFolder)
      - `to`: image → webp, avif, heic, jxl, jpeg, png, gif; video → mp4 (H.264), hevc (H.265 hardware),
        x265 (software, smaller), av1, webm, gif; audio → m4a, mp3, ogg, flac, wav, aiff.
        Watch the AV1 collision: the AV1 *video* codec is `av1`; `avif` is the still-*image* format.
      - Converting to the format the file is already in is an idempotent no-op: it does NO work and the
        file is passed through unchanged (jpg/jpeg and tif/tiff count as the same format). So `convert`
        only re-encodes when the input isn't already that format.
    - `crop(width, height, longEdge, location)`: resize to exact pixels. [image, video]
      - Provide at least one. `width`/`height` in px (the missing one is computed, aspect kept).
        `longEdge` sets the longest side instead of width/height.
    - `extractPagesAsImages(format, quality, location)`: render PDF pages to images. [pdf]
      - `format`: jpeg (default), png. `quality`: low (1x/72dpi), medium (2x/144dpi, default), high (3x/216dpi).
    - `targetSize(size, location)`: compress iteratively until the file fits under a limit. [image, video, pdf, audio]
      Never follow it with `optimise`: it already compresses to fit, so a trailing `optimise` is wasteful double encoding.
      - `size`: `500KB`, `10MB`, `25MB` (kb/mb/gb or kib/mib/gib, or raw bytes). Handy limits:
        Discord/GitHub 10MB, WhatsApp 16MB, Gmail 25MB.
    - `stripExif`: remove EXIF and GPS metadata (privacy before sharing). [image, video]
    - `watermark(image, position, opacity, scale, location)`: overlay a watermark image. [image, video]
      - `image`: path (quote it; PNG with transparency works best). `position`: bottomRight (default),
        bottomLeft, topRight, topLeft, center. `opacity`: 0.0–1.0 (default 1.0). `scale`: width fraction (default 0.15).

    ### Media-specific

    - `removeAudio`: strip the audio track. [video]
    - `changeSpeed(factor)`: playback speed multiplier (2.0 = 2x, 0.5 = half). [video, audio]
    - `capFps(fps)`: cap the frame rate (60, 30, 24, …). [video]
    - `normalize(lufs)`: normalise loudness. `lufs` default -16 (-14 Spotify/YouTube, -16 Apple Podcasts, -23 EBU). [audio]

    ### Filters (if / ifNot: gate the rest of the pipeline, no branching)

    - `if(...)` and `ifNot(...)` are filters, NOT branches. There is no `else`, no nested block and
      no `;` separator: a step is one `if(...)` and the rest of the pipeline that follows it.
    - `if(...)` continues only when the condition holds; when it fails the file silently stops here
      (no error, no result). `ifNot(...)` inverts the WHOLE condition: it stops the file when the
      condition holds and continues only when it does not.
    - Multiple condition keys inside one `if`/`ifNot` combine with AND; every key must hold. To OR
      conditions, use two separate pipelines.
    - Condition keys:
      - `regex`: pattern matched against the filename (smart case; capture groups become $1, $2). Quote it.
      - `types`: space-separated types/extensions, e.g. `types: jpeg png webp`.
      - `nameContains`: case-insensitive substring. `nameIs`: exact filename.
      - `fileSizeGreaterThan` / `fileSizeLowerThan`: raw bytes. `minFileSize`: human size (`100kb`, `2mb`).
      - `widthGreaterThan` / `widthLowerThan` / `heightGreaterThan` / `heightLowerThan`: pixels (images).
      - `minResolution`: `WxH`, e.g. `640x480` (images).
      - `dpiGreaterThan` / `dpiLowerThan`: DPI (images & PDFs).
      - `copiedBy`: app name or bundle id substring (clipboard source only), e.g. `copiedBy: "safari"`.

    ### Mixed file types (filters do NOT branch, so handle each type separately)

    Because a filter only gates the steps AFTER it and there is no `else`, you cannot give two file
    types different treatment in one linear pipeline. Chaining gates like
    `if(types: image) -> convert(to: webp) -> if(types: video) -> convert(to: mp4)` is broken: a video
    fails the first gate and stops, an image that passes is no longer a video at the second gate, so the
    second half never runs.

    - "Do X to everything, then ALSO do Y to only one type": one pipeline works, narrow at the END.
      e.g. optimise all, only images go on to webp: `optimise -> if(types: image) -> convert(to: webp)`.
    - "Give each type a DIFFERENT output": emit TWO commands, one per `--type` (a `--type`/`--file-type`
      can only be a single type). e.g. for a folder of images and videos:
        clop pipeline attach 'convert(to: webp)' --source <folder> --type image
        clop pipeline attach 'convert(to: mp4)'  --source <folder> --type video
      (Output both lines; do not invent `--type image,video`.)

    ### File operations (template tokens supported, see below)

    - `copy(to)`: copy to a path/template. `move(to)`: move. `rename(to)`: new name.
    - `delete(path)`: delete a path; `delete(path: "sourceFile")` removes the input file.

    ### Actions

    - `runScript(path)` or `runScript(code)`: run a script file/executable, or inline shell code via
      `zsh -c`. The file is passed as $1 and in $CLOP_INPUT_FILE; if the script prints a file path to
      stdout, that file replaces the one the pipeline carries forward. e.g. `runScript(code: "sips -Z 800 $1")`.
      Inline `code` must be one line and must NOT contain `->` (the step separator) or newlines; chain with `;` or `&&`.
    - `runShortcut(name)`: run a macOS Shortcut by its name. [image, video, pdf]
    - `copyToClipboard(format, relativeTo)`: `format`: path (default), imageData (images), markdown.
      `relativeTo`: a base path that makes the copied path/link relative (e.g. `~/Projects/blog`).
    - `copyLinkForSending(expiration)`: send the file securely and copy the share link. `expiration`
      auto-stops the link (and closes the room) after `1m`/`15m`/`1h`/`6h`/`1d`/`3d` or `never`; omit it to
      use the default from Preferences. Transfer is peer-to-peer, so the Mac must stay awake until then.
    - `fork(location)`: surface the result-so-far as a SECOND card, then keep processing the main line
      into the first card. The forked card never changes the file the pipeline carries forward, so the
      result path is preserved for later steps (e.g. `optimise -> fork -> convert(to: webp)` yields both
      the optimised original AND the webp). [image, video, audio, pdf]
      - Omit `location`: the forked file stays in a temp folder and is draggable (drag it out to save).
        Clop copies it only if a LATER step would clobber it (an in-place / move / rename / delete that
        would overwrite the same file); otherwise the forked card just points at the file in place.
      - Give a `location` (e.g. `sameFolder`, or a path template): the forked file is persisted there,
        using the same location rules as every other step, without disturbing the main line.
    - `shelveWith(app)`: yoink, dockside, dropover. `uploadWith(app)`: dropshare. `openWith(app)`: e.g. Preview.

    ## location parameter & path templates

    - `location` values: `inPlace` (replace original), `sameFolder` (next to original),
      `temporaryFolder`, or a path template. With `convert`+`inPlace` the original is trashed and replaced.
    - Path/template tokens (usable in `location`, copy/move/rename/delete `to`/`path`, watermark `image`):
      `%f` filename (no extension), `%e` extension, `%P` parent folder, `%F` full path,
      `%y` year, `%m` month (01–12), `%n` month name, `%d` day, `%w` weekday, `%H` hour, `%M` minute,
      `%S` second, `%p` AM/PM, `%r` 5 random letters, `%i` auto-incrementing number.
    - `$1`, `$2`, … are capture groups from a preceding `if(regex: ...)`. `~` expands to home.
      When a template has no extension, the output extension is appended automatically.

    ## Caveats

    - Inline = no implicit optimise; add `optimise` yourself when you want smaller files.
    - Audio bitrate is never increased; `lowerBitrate` snaps to the format's allowed bitrates.
    - Filters are not branches: a failed `if` (or a matched `ifNot`) silently stops the file at that
      point; the remaining steps simply don't run. There is no `else` and no way to resume.
    - Keep steps appropriate to the file type. Only gate with `if(types: ...)` when the pipeline runs
      over MIXED types; a pipeline attached/added with a fixed `--type`/`--file-type` is already scoped,
      so type gating there is redundant.

    ## Avoiding double encoding

    Every `crop`, `downscale` and `convert` already re-encodes AND compresses the file during its own
    pass; they are not just geometry/format changes. So a separate `optimise` after them usually just
    re-encodes an already-compressed file: slower, and for lossy formats it loses a little more quality
    each time.

    - Consecutive in-place processing steps are compiled into ONE ffmpeg/vips pass, so they encode only
      once. A step with a non-`inPlace` `location` ends that batch and starts a fresh encode (this is how
      multi-output pipelines are built). `targetSize`, `stripExif`, `watermark`, `capFps`, `normalize`
      and any GIF conversion never batch; they always run as their own pass.
    - Prefer letting `convert`, `downscale` or `crop` produce the final encoding instead of adding a
      trailing `optimise`. e.g. write `crop(width: 1600) -> convert(to: webp)`, not
      `crop(width: 1600) -> convert(to: webp) -> optimise`.
    - For a SAVED pipeline whose steps already encode the file (any `convert`/`downscale`/`crop`), turn
      on "Skip optimisation" so Clop doesn't optimise the original before running your steps. Inline
      `clop pipeline run` never adds an implicit optimise, so there's nothing to skip there.

    ## Running and saving

    - Test now: `clop pipeline run '<steps>' file1 [file2 ...]`
      Flags: `--show-result` show the floating result thumbnail (default hidden), `--hide-result`,
      `--async`, `-r` recurse into folders, `-s` skip errors, `-j` JSON output,
      `--types image,video,…`, `-n` no progress.
    - Save to the library (runnable by name and shown in the app's Settings → Automation):
      `clop pipeline add [--file-type image|video|pdf|audio] [--skip-optimisation] [--hide-result] [--force] <name> '<steps>'`
    - Inspect: `clop pipeline list`, `clop pipeline show <name>`. Remove: `clop pipeline delete <name>`.
    - In the app, saved pipelines appear as presets in Settings → Automation and can be assigned to run
      automatically per watched folder or input source.

    ## Automations and preset zones

    ### attach: run a pipeline automatically on a source

    `clop pipeline attach '<pipeline>' --source <source> --type <type>`

    Attaches a pipeline to a source so it runs automatically on every file of that type coming from
    that source. The pipeline argument is either a saved pipeline's name or id (attached as a
    reference so it tracks library edits) or inline steps (validated and stored verbatim).

    - `--source`: `clipboard`, `dropZone`, or a folder path (`~` is expanded, e.g. `~/Downloads`).
    - `--type`: `image`, `video`, `pdf`, or `audio`.
    - `--skip-optimisation`: skip the implicit optimise pass before the pipeline runs (inline only).
    - `--hide-result`: suppress the floating result thumbnail (inline only).
    - A source can hold several attached pipelines for the same type; each `attach` appends one.
    - Attaching to a FOLDER also starts watching it: the folder is added to Clop's watched folders for
      that type and automatic processing for that type is enabled, so the pipeline fires on its own.
      No `if(types: <type>)` step is needed: the attachment is already scoped to `--type`.

    Examples:
      # Auto-convert every clipboard image to WebP (inline)
      clop pipeline attach 'convert(to: webp)' --source clipboard --type image

      # Run a saved pipeline on every video dropped into the drop zone (reference by name)
      clop pipeline attach 'Social clip' --source dropZone --type video

      # Watermark and move every image saved into a watched folder (inline)
      clop pipeline attach 'watermark(image: "~/logo.png") -> move(to: "~/Watermarked/")' \
        --source /Users/me/Desktop --type image

    ### detach: remove attached pipeline(s) from a source

    `clop pipeline detach --source <source> --type <type> (--all | --index <n>)`

    - `--all`: remove every pipeline attached to that source/type pair.
    - `--index <n>`: remove only the pipeline at 0-based position `n` (use `clop pipeline list` to check order).
    - When the last automation for a FOLDER/type is removed, Clop also stops watching that folder for
      that type (the reverse of what `attach` set up).

    Examples:
      clop pipeline detach --source clipboard --type image --all
      clop pipeline detach --source ~/Downloads --type video --index 1

    ### preset: manage drop zone preset zones

    Preset zones appear when you Control-drag a file onto the Clop drop zone; dropping onto one
    immediately runs its pipeline on that file.

    Add a preset zone:
      `clop pipeline preset add '<name>' '<pipeline>' [--type <type>] [--icon <sf-symbol>] [--skip-optimisation] [--hide-result] [--force]`

      The pipeline argument is either a saved pipeline's name or id (attached as a reference) or
      inline steps (stored verbatim). Same auto-detection as `attach`.

      - `--type`: restrict the zone to one file type; omit for an all-types zone.
      - `--icon`: SF Symbol name for the zone icon (default: `wand.and.stars`).
      - `--force`: replace an existing zone with the same id.

    Remove a preset zone:
      `clop pipeline preset remove '<name>' [--type <type>]`
      Omit `--type` to target the all-types zone with that name.

    Examples:
      # All-types "Optimise" zone (inline)
      clop pipeline preset add 'Optimise' 'optimise' --icon 'bolt.fill'

      # Image-only "Web ready" zone (inline)
      clop pipeline preset add 'Web ready' 'optimise -> convert(to: webp)' --type image --icon 'globe'

      # Video zone that references a saved library pipeline (by name)
      clop pipeline preset add 'Social clip' 'Social clip' --type video

      # Remove the image-only zone
      clop pipeline preset remove 'Web ready' --type image

    ## Examples

    - Image for the web:            `optimise -> convert(to: webp)`
    - Just convert (no separate optimise step): `convert(to: avif)`  (no-op if the file is already AVIF)
    - Sort screenshots:             `if(regex: "^(screen ?shot|cleanshot)") -> optimise() -> move(to: "~/Pictures/Screenshots/%y/%m/")`
    - Fit under Discord's 10MB:      `targetSize(size: 10MB)`
    - Video to 1080p MP4:           `crop(width: 1920) -> optimise(encoder: slowHighQuality)`
    - Video to GIF:                 `crop(longEdge: 800) -> convert(to: gif)`
    - 2× silent screencast:         `changeSpeed(factor: 2.0) -> removeAudio -> optimise(encoder: fast)`
    - Audio to 128k MP3:            `convert(to: mp3) -> lowerBitrate(kbps: 128)`
    - PDF pages to JPEGs:           `extractPagesAsImages(format: jpeg, quality: high)`
    - Watermark then optimise:      `watermark(image: "%P/logo.png", position: bottomRight) -> optimise`

    ### As full commands (when the request names a folder / source)

    - Every photo in Downloads to WebP at max 1600px, into a Sync folder, copy a markdown link:
      `clop pipeline attach 'crop(longEdge: 1600) -> convert(to: webp, location: "~/Sync/Optimised/") -> copyToClipboard(format: markdown)' --source ~/Downloads --type image`
      (no `if(types: image)` needed: `--type image` already scopes it.)
    - Auto-convert every clipboard image to WebP:
      `clop pipeline attach 'convert(to: webp)' --source clipboard --type image`
    - Compress every video saved to ~/Movies for sharing:
      `clop pipeline attach 'targetSize(size: 25MB)' --source ~/Movies --type video`
    - Save a reusable "Web ready" image pipeline to the library:
      `clop pipeline add --file-type image 'Web ready' 'convert(to: webp)'`
    """#

    return appendPipelineTask(task, to: out)
}

/// Resolution result for a pipeline argument that may be a saved pipeline name/id or inline steps.
enum PipelineArgResolution {
    case reference // matches a saved pipeline by name or id
    case inline // not a saved pipeline; steps validated as known DSL
    case invalid([String]) // not a saved pipeline and contains unknown step names
}

/// Resolve a pipeline argument: check saved pipelines first (by name, case-insensitive, or by id),
/// then treat as inline steps and validate against known DSL steps.
/// Returns the resolution and, for `.reference`, the matched saved pipeline.
func resolvePipelineArg(_ arg: String) -> (PipelineArgResolution, CLIPipeline?) {
    let saved = readSavedPipelines()
    if let found = saved.first(where: {
        ($0.name ?? "").localizedCaseInsensitiveCompare(arg) == .orderedSame || $0.id == arg
    }) {
        return (.reference, found)
    }
    let unknown = invalidPipelineSteps(arg)
    if unknown.isEmpty {
        return (.inline, nil)
    }
    return (.invalid(unknown), nil)
}

/// Return step names from an inline pipeline that are not known DSL steps.
func invalidPipelineSteps(_ text: String) -> [String] {
    text.components(separatedBy: "->")
        .flatMap { $0.components(separatedBy: "\n") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .compactMap { step in
            guard let parenIdx = step.firstIndex(of: "(") else {
                return KNOWN_PIPELINE_STEPS.contains(step) ? nil : step
            }
            let name = String(step[..<parenIdx]).trimmingCharacters(in: .whitespaces)
            return KNOWN_PIPELINE_STEPS.contains(name) ? nil : name
        }
}

/// Lightweight mirror of the app's `Pipeline` model, enough for listing and editing
/// the JSON strings stored in the `savedPipelines` default.
struct CLIPipeline: Codable {
    /// How a list entry was created: a bundled built-in (stable `builtin-` id),
    /// a user-saved pipeline (UUID id), or a reference to a library entry.
    enum Provenance: String {
        case builtin
        case user
        case reference
    }

    var id: String
    var name: String?
    var rawText: String?
    var skipOptimisation: Bool?
    var hideResult: Bool?
    var libraryID: String?
    var fileType: String?

    var rawJSON = "{}"

    var rawDict: [String: Any] {
        (try? JSONSerialization.jsonObject(with: rawJSON.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]
    }

    var displayText: String {
        if let rawText, !rawText.isEmpty {
            return rawText
        }
        // Visually-built pipelines may have no rawText: reconstruct a compact
        // description from the encoded step objects.
        guard let steps = rawDict["steps"] as? [[String: Any]], !steps.isEmpty else {
            return "(no steps)"
        }
        return steps.compactMap { step -> String? in
            guard let (name, params) = step.first else { return nil }
            guard let paramDict = params as? [String: Any], !paramDict.isEmpty else { return name }
            let paramStr = paramDict.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return "\(name)(\(paramStr))"
        }.joined(separator: " -> ")
    }

    var provenance: Provenance {
        if libraryID != nil { return .reference }
        if id.hasPrefix("builtin-") { return .builtin }
        return .user
    }

    /// Short, dimmed tags describing the skip-optimisation / hide-result flags,
    /// using the canonical wording shared with the app's editor.
    var flagTags: String {
        var tags: [String] = []
        if skipOptimisation == true { tags.append("Skip optimisation") }
        if hideResult == true { tags.append("Hide result") }
        guard !tags.isEmpty else { return "" }
        return " " + tags.map { "[\($0)]".dim() }.joined(separator: " ")
    }

    static func from(json: String) -> CLIPipeline? {
        guard let data = json.data(using: .utf8),
              var pipeline = try? JSONDecoder().decode(CLIPipeline.self, from: data)
        else { return nil }
        pipeline.rawJSON = json
        return pipeline
    }

    /// Follow a library reference to the saved pipeline it points at.
    func resolve(in saved: [CLIPipeline]) -> CLIPipeline {
        guard let libraryID else { return self }
        return saved.first(where: { $0.id == libraryID }) ?? self
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rawText, skipOptimisation, hideResult, libraryID, fileType
    }

}

func readSavedPipelines() -> [CLIPipeline] {
    (UserDefaults.app?.array(forKey: "savedPipelines") as? [String])?.compactMap { CLIPipeline.from(json: $0) } ?? []
}

/// Return the `pipelinesToRunOn*` UserDefaults key for the given file type string.
func automationKey(for type: String) -> String {
    switch type {
    case "image": "pipelinesToRunOnImage"
    case "video": "pipelinesToRunOnVideo"
    case "pdf": "pipelinesToRunOnPdf"
    case "audio": "pipelinesToRunOnAudio"
    default: fatalError("unhandled file type: \(type)")
    }
}

/// Watched-dirs Defaults key for a file type (mirror of PIPELINE_AUTOMATION_KEYS).
func watchedDirsKey(for type: String) -> String {
    switch type {
    case "image": "imageDirs"
    case "video": "videoDirs"
    case "pdf": "pdfDirs"
    case "audio": "audioDirs"
    default: fatalError("unhandled file type: \(type)")
    }
}

/// Per-type folder-watcher toggle key and its registered default (mirror of Settings.swift).
func watcherEnabledKey(for type: String) -> (key: String, default: Bool) {
    switch type {
    case "image": ("enableAutomaticImageOptimisations", true)
    case "video": ("enableAutomaticVideoOptimisations", true)
    case "pdf": ("enableAutomaticPDFOptimisations", true)
    case "audio": ("enableAutomaticAudioOptimisations", false)
    default: fatalError("unhandled file type: \(type)")
    }
}

/// Registered default for a type's watched-dirs list (mirror of Settings.swift: image/video watch
/// the Desktop by default, pdf/audio watch nothing). Used so the first explicit write from the CLI
/// doesn't silently drop the implicit default folders.
func defaultWatchedDirs(for type: String) -> [String] {
    switch type {
    case "image", "video": [URL.desktopDirectory.path]
    default: []
    }
}

/// Fixed source keywords understood by the automation system. Anything else is a folder path.
let FIXED_AUTOMATION_SOURCES: Set = [
    "clipboard", "dropZone", "drop-zone", "drop zone",
    "fileWatcher", "file-watcher", "file watcher",
    "openWith", "open-with", "open with",
    "service", "photos", "shortcuts", "cli", "finder",
]

/// If `source` names a folder (not a fixed keyword), return its normalized absolute path
/// (expanding `~`, standardizing). The app keys folder automations and watched dirs by this exact
/// absolute path, so attach/detach must normalize identically. Returns nil for keyword sources.
func normalizedFolderSource(_ source: String) -> String? {
    guard !FIXED_AUTOMATION_SOURCES.contains(source) else { return nil }
    let expanded = (source as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

let CHECKMARK = "✓".green()
let EXCLAMATION = "!".magenta()
let CIRCLE = "◌".yellow()
let ERROR_X = "✘".red()
let ARROW = "->".dim()

var progressPrinter: ProgressPrinter?

struct CLIResult: Codable {
    let done: [OptimisationResponse]
    let failed: [OptimisationResponseError]
}

@discardableResult
@inline(__always) public func mainThread<T>(_ action: () -> T) -> T {
    guard !Thread.isMainThread else {
        return action()
    }
    return DispatchQueue.main.sync { action() }
}

actor ProgressPrinter {
    init(urls: [URL]) {
        urlsToProcess = urls
    }

    var urlsToProcess: [URL]

    var responses: [URL: OptimisationResponse] = [:]
    var errors: [URL: OptimisationResponseError] = [:]

    var progressFractionObserver: [URL: NSKeyValueObservation] = [:]
    var progressSubscribers: [URL: Any] = [:]
    var progressProxies: [URL: Progress] = [:]

    func markDone(response: OptimisationResponse) {
        log.debug("Got response \(response.jsonString) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        responses[response.forURL] = response
    }

    func markError(response: OptimisationResponseError) {
        log.debug("Got error response \(response.error) for \(response.forURL)")

        removeProgressSubscriber(url: response.forURL)
        errors[response.forURL] = response
    }

    func addProgressSubscriber(url: URL, progress: Progress) {
        progressFractionObserver[url] = progress.observe(\.fractionCompleted) { _, change in
            Task { await self.printProgress() }
        }
        progressProxies[url] = progress
    }

    func removeProgressSubscriber(url: URL) {
        if let sub = progressSubscribers.removeValue(forKey: url) {
            Progress.removeSubscriber(sub)
        }
        progressProxies.removeValue(forKey: url)
        if let observer = progressFractionObserver[url] {
            observer.invalidate()
        }
        progressFractionObserver.removeValue(forKey: url)
        printProgress()
    }

    func startProgressListener(url: URL) {
        let sub = Progress.addSubscriber(forFileURL: url) { progress in
            Task { await self.addProgressSubscriber(url: url, progress: progress) }
            return {
                Task { await self.removeProgressSubscriber(url: url) }
            }
        }
        progressSubscribers[url] = sub
    }

    var lastPrintedLinesCount = 0

    func printProgress() {
        printerr([String](repeating: "\(LINE_UP)\(LINE_CLEAR)", count: lastPrintedLinesCount).joined(separator: ""), terminator: "")

        let done = responses.count
        let failed = errors.count
        let total = urlsToProcess.count

        lastPrintedLinesCount = progressProxies.count + 1
        printerr("Processed \(done + failed) of \(total) | Success: \(done) | Failed: \(failed)")

        for (url, progress) in progressProxies {
            let progressInt = Int(round(progress.fractionCompleted * 100))
            let progressBarStr = String(repeating: "█", count: Int(progress.fractionCompleted * 20)) + String(repeating: "░", count: 20 - Int(progress.fractionCompleted * 20))
            var itemStr = (url.isFileURL ? url.path : url.absoluteString)
            if itemStr.count > 50 {
                itemStr = "..." + itemStr.suffix(40)
            }
            if let desc = mainThread({ progress.localizedAdditionalDescription }) {
                printerr("\(itemStr): \(desc) \(progressBarStr) (\(progressInt)%)")
            } else {
                printerr("\(itemStr): \(progressBarStr) \(progressInt)%")
            }
        }
    }

    func waitUntilDone() async {
        while responses.count + errors.count < urlsToProcess.count {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// True when every item errored and none succeeded. Used to decide the CLI exit
    /// code: a partial success exits 0 so callers don't retry already-processed files.
    var allItemsFailed: Bool {
        responses.isEmpty && !errors.isEmpty
    }

    func printResults(json: Bool) {
        guard !json else {
            let result = CLIResult(done: responses.values.sorted { $0.forURL.path < $1.forURL.path }, failed: errors.values.sorted { $0.forURL.path < $1.forURL.path })
            print(result.jsonString)
            return
        }

        for response in responses.values.sorted(by: { $0.forURL.path < $1.forURL.path }) {
            guard response.newBytes != response.oldBytes, response.newBytes > 0, abs(response.newBytes - response.oldBytes) > 100 else {
                print("\(EXCLAMATION) \(response.forURL.shellString.underline()): \((response.oldBytes ?! response.newBytes).humanSize.yellow()) (no change)".dim())
                continue
            }
            let isSmaller = response.newBytes < response.oldBytes
            let perc = "\(response.percentageSaved.str(decimals: 2))%".foregroundColor(isSmaller ? .green : .red)
            let percentageSaved = " (\(perc) \(isSmaller ? "smaller" : "larger"))".dim()
            let resolutionChangeStr = if let old = response.oldWidthHeight, let new = response.newWidthHeight, old != new {
                " [\(old.s.dim()) \(ARROW) \(new.s.yellow())]"
            } else {
                ""
            }
            let bitrateChangeStr = if let old = response.oldBitrate, let new = response.newBitrate, old != new {
                " [\("\(old) kbps".dim()) \(ARROW) \("\(new) kbps".yellow())]"
            } else {
                ""
            }
            let dpiChangeStr = if let old = response.oldDPI, let new = response.newDPI, old != new {
                " [\("\(old) DPI".dim()) \(ARROW) \("\(new) DPI".yellow())]"
            } else if let old = response.oldDPI, response.newDPI == nil || response.newDPI == old {
                " [\("\(old) DPI".dim())]"
            } else {
                ""
            }
            let savedAs = if let original = response.forURL.filePath ?? response.convertedFrom?.filePath, let optimised = response.path.filePath, original != optimised {
                " saved as \(optimised.shellString.underline())".dim()
            } else {
                ""
            }
            print(
                "\(CHECKMARK) \(response.forURL.shellString.underline()): \(response.oldBytes.humanSize.foregroundColor(isSmaller ? .red : .green)) \(ARROW) \(response.newBytes.humanSize.foregroundColor(isSmaller ? .green : .red).bold())\(resolutionChangeStr)\(bitrateChangeStr)\(dpiChangeStr)\(percentageSaved)\(savedAs)"
            )
        }
        for response in errors.values.sorted(by: { $0.forURL.path < $1.forURL.path }) {
            let url = response.forURL
            let err = response.error
                .replacingOccurrences(of: ": \(url.path)", with: "")
                .replacingOccurrences(of: ": \(url.shellString)", with: "")
            print("\(ERROR_X) \(url.shellString.underline()): \(err.foregroundColor(.red))")
        }
        if responses.count > 1 {
            let totalOldBytes = responses.values.map(\.oldBytes).reduce(0, +)
            let totalNewBytes = responses.values.map(\.newBytes).reduce(0, +)
            guard totalNewBytes != totalOldBytes else {
                return
            }
            let isSmaller = totalNewBytes < totalOldBytes

            let totalPerc = "\((100 - (Double(totalNewBytes) / Double(totalOldBytes) * 100)).str(decimals: 2))%".foregroundColor(isSmaller ? .green : .red)
            let totalPercentageSaved = "(\(totalPerc))".dim()
            let totalBytesSaved = (totalOldBytes - totalNewBytes).humanSize.foregroundColor(isSmaller ? .green : .red)
            let totalBytesSavedStr = "\(isSmaller ? "saving" : "adding"): \(totalBytesSaved)"
            print(
                "\(CHECKMARK) \("TOTAL".underline()): \(totalOldBytes.humanSize.foregroundColor(isSmaller ? .red : .green)) \(ARROW) \(totalNewBytes.humanSize.foregroundColor(isSmaller ? .green : .red).bold()) \(totalBytesSavedStr) \(totalPercentageSaved)"
            )
        }
    }

    func startResponsesThread() {
        responsesThread = Thread {
            OPTIMISATION_CLI_RESPONSE_PORT.listen { data in
                log.debug("Received optimisation response: \(data?.count ?? 0) bytes")

                guard let data else {
                    return nil
                }
                if let resp = OptimisationResponse.from(data) {
                    Task { await self.markDone(response: resp) }
                }
                if let resp = OptimisationResponseError.from(data) {
                    Task { await self.markError(response: resp) }
                }
                return nil
            }
            RunLoop.current.run()
        }
        responsesThread?.start()
    }
}

let HOME = FilePath(NSHomeDirectory())
extension FilePath {
    var shellString: String {
        string.replacingFirstOccurrence(of: HOME.string, with: "~")
    }
}

let LINE_UP = "\u{1B}[1A"
let LINE_CLEAR = "\u{1B}[2K"
var responsesThread: Thread?

enum CLIError: Error {
    case optimisationError
    case appNotRunning
}

func stopCurrentRequests(_ signal: Int32) {
    let req = StopOptimisationRequest(ids: currentRequestIDs, remove: false)
    try? OPTIMISATION_STOP_PORT.sendAndForget(data: req.jsonData)
    Clop.exit()
}

Clop.main()
