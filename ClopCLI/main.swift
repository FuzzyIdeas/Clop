//
//  main.swift
//  ClopCLI
//
//  Created by Alin Panaitiu on 25.09.2023.
//

import ArgumentParser
import Cocoa
import Foundation
import PDFKit
import System
import UniformTypeIdentifiers

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
    var shellString: String { isFileURL ? path.shellString : absoluteString }
}

extension UserDefaults {
    #if SETAPP
        static let app: UserDefaults? = .init(suiteName: "com.lowtechguys.Clop-setapp")
    #else
        static let app: UserDefaults? = .init(suiteName: "com.lowtechguys.Clop")
    #endif
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

let DEVICES_STR = """
Devices:
  iPad:        "iPad 3"  "iPad 4"  "iPad 5"  "iPad 6"
               "iPad 7"  "iPad 8"  "iPad 9"  "iPad 10"

  iPad Air:    "iPad Air 1"  "iPad Air 2"    "iPad Air 3"
               "iPad Air 4"  "iPad Air 5"

  iPad mini:   "iPad mini 1"   "iPad mini 2"   "iPad mini 3"
               "iPad mini 4"   "iPad mini 5"   "iPad mini 6"

  iPad Pro:    "iPad Pro 1 12.9inch"   "iPad Pro 1 9.7inch"
               "iPad Pro 2 10.5inch"   "iPad Pro 2 12.9inch"
               "iPad Pro 3 11inch"     "iPad Pro 3 12.9inch"
               "iPad Pro 4 11inch"     "iPad Pro 4 12.9inch"
               "iPad Pro 5 11inch"     "iPad Pro 5 12.9inch"
               "iPad Pro 6 11inch"     "iPad Pro 6 12.9inch"

  iPhone:      "iPhone 15"    "iPhone 15 Plus"  "iPhone 15 Pro"      "iPhone 15 Pro Max"
               "iPhone 14"    "iPhone 14 Plus"  "iPhone 14 Pro"      "iPhone 14 Pro Max"
               "iPhone 13"    "iPhone 13 mini"  "iPhone 13 Pro"      "iPhone 13 Pro Max"
               "iPhone 12"    "iPhone 12 mini"  "iPhone 12 Pro"      "iPhone 12 Pro Max"
               "iPhone 11"    "iPhone 11 Pro"   "iPhone 11 Pro Max"
               "iPhone X"     "iPhone XR"       "iPhone XS"          "iPhone XS Max"
               "iPhone SE 1"  "iPhone SE 2"     "iPhone SE 3"
               "iPhone 7"     "iPhone 7 Plus"   "iPhone 8"           "iPhone 8 Plus"
               "iPhone 6"     "iPhone 6 Plus"   "iPhone 6s"          "iPhone 6s Plus"
               "iPhone 4"     "iPhone 4S"       "iPhone 5"           "iPhone 5S"

  iPod touch:  "iPod touch 4" "iPod touch 5" "iPod touch 6" "iPod touch 7"
"""

let PAPER_SIZES_STR = """
Paper sizes:
  A:              "2A0"  "4A0"  "A0"   "A0+"  "A1"   "A1+"  "A10"  "A11"  "A12"  "A13"
                  "A2"   "A3"   "A3+"  "A4"   "A5"   "A6"   "A7"   "A8"   "A9"

  B:              "B0"   "B0+"  "B1"   "B1+"  "B10"  "B11"  "B12"  "B13"  "B2"   "B2+"
                  "B3"   "B4"   "B5"   "B6"   "B7"   "B8"   "B9"

  US:             "ANSI A"  "ANSI B"  "ANSI C"  "ANSI D"  "ANSI E"
                  "Arch A"  "Arch B"  "Arch C"  "Arch D"  "Arch E"  "Arch E1"  "Arch E2"  "Arch E3"
                  "Letter"  "Government Letter" "Half Letter"
                  "Government Legal"  "Junior Legal"  "Ledger"  "Legal"  "Tabloid"

  Photography:    "2LD, DSCW"    "2LW"  "2R"  "3R, L"    "4R, KG"    "5R, 2L"    "6R"
                  "A3+ Super B"  "KGD"  "LW"  "LD, DSC"  "Passport"  "S8R, 6PW"  "8R, 6P"

  Newspaper:      "British Broadsheet"  "South African Broadsheet"  "Broadsheet"   "US Broadsheet"
                  "Canadian Tabloid"    "Norwegian Tabloid"    "Newspaper Tabloid"
                  "Berliner"  "Ciner"   "Compact"     "Nordisch"         "Rhenish"
                  "Swiss"     "Wall Street Journal"   "New York Times"

  Books:          "12mo"  "16mo"  "18mo"  "32mo"  "48mo"  "64mo"
                  "A Format"  "B Format"  "C Format" "Folio"  "Quarto"
                  "Octavo"        "Royal Octavo"     "Medium Octavo"
                  "Crown Octavo"  "Imperial Octavo"  "Super Octavo"
"""

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

    ensureAppIsRunning()
    sleep(1)

    guard isClopRunning() else {
        Clop.exit(withError: CLIError.appNotRunning)
    }
    return urls
}

func sendRequest(urls: [URL], showProgress: Bool, async: Bool, gui: Bool, json: Bool, operation: String, _ requestCreator: () -> OptimisationRequest) throws {
    if !async {
        progressPrinter = ProgressPrinter(urls: urls)
        Task.init {
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
            Task.init { await progressPrinter.startProgressListener(url: url) }
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

    awaitSync {
        await progressPrinter!.waitUntilDone()

        if showProgress {
            await progressPrinter!.printProgress()
            fflush(stderr)
        }
        await progressPrinter!.printResults(json: json)
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

struct Clop: ParsableCommand {
    struct Convert: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Converts images to more efficient formats like HEIC, WebP, AVIF etc."
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

        static func convertToAVIF(path: FilePath, outFilePath: FilePath, quality: Int) throws {
            let args = ["--avif", "-q", "\(quality)", "-o", outFilePath.string, path.string]
            try runConversionProcess(path: path, outFilePath: outFilePath, executable: HEIF_ENC.string, args: args)
        }

        static func convertToHEIC(path: FilePath, outFilePath: FilePath, quality: Int) throws {
            let args = ["-q", "\(quality)", "-o", outFilePath.string, path.string]
            try runConversionProcess(path: path, outFilePath: outFilePath, executable: HEIF_ENC.string, args: args)
        }

        static func convertToWebP(path: FilePath, outFilePath: FilePath, quality: Int) throws {
            let args = ["-mt", "-q", "\(quality)", "-sharp_yuv", "-metadata", "all", path.string, "-o", outFilePath.string]
            try runConversionProcess(path: path, outFilePath: outFilePath, executable: CWEBP.string, args: args)
        }

        static func runConversionProcess(path: FilePath, outFilePath: FilePath, executable: String, args: [String]) throws {
            let errPipe = Pipe()

            let process = Process()
            process.launchPath = executable
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            process.launch()
            process.waitUntilExit()

            if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: outFilePath.string) {
                printerr("\(ERROR_X) \(path.string.underline()) failed")
                printerr(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                return
            }
            try? outFilePath.setOptimisationStatusXattr("true")
        }

        static func convert(path: FilePath, format: ImageFormat, quality: Int, output: String?, force: Bool) throws {
            guard let stem = path.stem else {
                printerr("\(ERROR_X) Invalid path \(path.shellString.underline())")
                return
            }
            guard let type = format.utType, let ext = type.preferredFilenameExtension else {
                printerr("\(ERROR_X) Invalid output format \(format) for \(path.shellString.underline())")
                return
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

            switch format {
            case .avif:
                try convertToAVIF(path: path, outFilePath: tempFile, quality: quality)
            case .heic:
                try convertToHEIC(path: path, outFilePath: tempFile, quality: quality)
            case .webp:
                try convertToWebP(path: path, outFilePath: tempFile, quality: quality)
            }

            if FileManager.default.fileExists(atPath: outFilePath.string) {
                if force {
                    try FileManager.default.removeItem(at: outFilePath.url)
                } else {
                    printerr("\(ERROR_X) \(outFilePath.shellString.underline()) already exists, use `--force` to replace")
                    printerr("    \(ARROW) converted file kept at \(tempFile.shellString.underline())".dim())
                    return
                }
            }
            try FileManager.default.moveItem(at: tempFile.url, to: outFilePath.url)
            print("\(CHECKMARK) \(path.shellString.underline()) \(ARROW) \(outFilePath.shellString.underline())")
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

            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                do {
                    try Self.convert(path: files[i], format: format, quality: quality, output: output, force: force)
                } catch let error as ClopError {
                    printerr("\(ERROR_X) \(files[i].shellString.underline()) \(ARROW) \(error.localizedDescription)")
                } catch {
                    printerr("\(ERROR_X) \(files[i].shellString.underline()) \(ARROW) \(error.localizedDescription)")
                }
            }
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

            ratio = DEVICE_SIZES[forDevice ?? ""]?.fractionalAspectRatio ?? PAPER_SIZES[paperSize ?? ""]?.fractionalAspectRatio ?? aspectRatio?.fractionalAspectRatio
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
                print("Cropping \(pdfPath.string) to aspect ratio \(factorStr(ratio!))", terminator: "")
                pdf.cropTo(aspectRatio: ratio, alwaysPortrait: pageLayout == .portrait, alwaysLandscape: pageLayout == .landscape)

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

        static func strip(path: FilePath) {
            guard FileManager.default.fileExists(atPath: path.string) else {
                printSemaphore.wait()
                printerr("\(ERROR_X) \(path.string.underline()) does not exist")
                printSemaphore.signal()
                return
            }
            guard path.extension?.lowercased() != "pdf" else {
                printSemaphore.wait()
                printerr("\(EXCLAMATION) \(path.string.underline()) is a PDF and `strip-exif` does not work on this type of file")
                printSemaphore.signal()
                return
            }

            let tempFile = URL.temporaryDirectory.appendingPathComponent(path.name.string).filePath!
            let args = [EXIFTOOL.string, "-XResolution=72", "-YResolution=72"]
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
                return
            }
            if path.hasOptimisationStatusXattr() {
                try? tempFile.setOptimisationStatusXattr("true")
            }
            try? FileManager.default.removeItem(at: path.url)
            try? FileManager.default.moveItem(at: tempFile.url, to: path.url)

            print("\(CHECKMARK) \(path.string.underline()) done".dim())
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
            DispatchQueue.concurrentPerform(iterations: foundPaths.count) { i in
                Self.strip(path: foundPaths[i])
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
                    removeAudio: removeAudio
                )
            }
        }
    }

    struct Downscale: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Downscale and optimise images and videos by a certain factor."
        )

        @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
        var gui = false

        @Flag(name: .shortAndLong, help: "Don't print progress to stderr")
        var noProgress = false

        @Flag(name: .long, help: "Process files and items in the background")
        var async = false

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation")
        var aggressive = false

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

        @Option(help: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)")
        var factor = 0.5

        var urls: [URL] = []

        @Argument(help: "Images, videos or URLs to downscale (can be a file, folder, or list of files)")
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
                    removeAudio: removeAudio
                )
            }
        }
    }

    struct Optimise: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Optimise images, videos and PDFs."
        )

        @Flag(name: .shortAndLong, help: "Whether to show or hide the floating result (the usual Clop UI)")
        var gui = false

        @Flag(name: .shortAndLong, help: "Don't print progress to stderr")
        var noProgress = false

        @Flag(name: .long, help: "Process files and items in the background")
        var async = false

        @Flag(name: .shortAndLong, help: "Use aggressive optimisation")
        var aggressive = false

        @Flag(name: .long, inversion: .prefixedNo, help: "Convert detail heavy images to JPEG and low-detail ones to PNG for better compression")
        var adaptiveOptimisation: Bool = UserDefaults.app?.bool(forKey: "adaptiveImageSize") ?? false

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

        @Flag(name: .long, help: "Removes audio from optimised videos")
        var removeAudio = false

        @Option(help: "Speeds up or slow down the video by a certain amount (1 means no change, 2 means twice as fast, 0.5 means 2x slower)")
        var playbackSpeedFactor: Double? = nil

        @Option(help: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)")
        var downscaleFactor: Double? = nil

        @Option(help: "Downscales and crops the image, video or PDF to a specific size (e.g. 1200x630)\nExample: cropping an image from 100x120 to 50x50 will first downscale it to 50x60 and then crop it to 50x50")
        var crop: NSSize? = nil

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

        Crop size                  %z
        Scale factor               %s
        Playback speed factor      %x
        Random characters          %r
        Auto-incrementing number   %i

        For example `--output "~/Desktop/%f_optimised.png" image.png` will generate the file `~/Desktop/image_optimised.png`.

        """)
        var output: String? = nil

        var urls: [URL] = []

        @Argument(help: "Images, videos, PDFs or URLs to optimise (can be a file, folder, or list of files)")
        var items: [String] = []

        mutating func validate() throws {
            if let size = crop, size == .zero {
                throw ValidationError("Invalid size, must be greater than 0")
            }
            if let factor = downscaleFactor, factor < 0.01, factor > 0.99 {
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
            try sendRequest(urls: urls, showProgress: !noProgress, async: async, gui: gui, json: json, operation: "optimisation") {
                var out = normalizeRelativeOutput(output)
                if urls.count == 1, let url = urls.first, let outExt = out?.filePath?.extension, let inExt = url.filePath?.extension, outExt == inExt {
                    out = out!.replacingFirstOccurrence(of: ".\(inExt)", with: "")
                }
                return OptimisationRequest(
                    id: String(Int.random(in: 1000 ... 100_000)),
                    urls: urls,
                    size: crop?.cropSize(),
                    downscaleFactor: downscaleFactor,
                    changePlaybackSpeedFactor: playbackSpeedFactor,
                    hideFloatingResult: !gui,
                    copyToClipboard: copy,
                    aggressiveOptimisation: aggressive,
                    adaptiveOptimisation: adaptiveOptimisation,
                    source: "cli",
                    output: out,
                    removeAudio: removeAudio
                )
            }
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Clop: optimise, crop and downscale images, videos and PDFs",
        subcommands: [
            Optimise.self,
            Crop.self,
            Downscale.self,
            Convert.self,
            CropPdf.self,
            UncropPdf.self,
            StripExif.self,
        ]
    )
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
            Task.init { await self.printProgress() }
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
            Task.init { await self.addProgressSubscriber(url: url, progress: progress) }
            return {
                Task.init { await self.removeProgressSubscriber(url: url) }
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
            if let desc = mainThread { progress.localizedAdditionalDescription } {
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
            let savedAs = if let original = response.forURL.filePath ?? response.convertedFrom?.filePath, let optimised = response.path.filePath, original != optimised {
                " saved as \(optimised.shellString.underline())".dim()
            } else {
                ""
            }
            print(
                "\(CHECKMARK) \(response.forURL.shellString.underline()): \(response.oldBytes.humanSize.foregroundColor(isSmaller ? .red : .green)) \(ARROW) \(response.newBytes.humanSize.foregroundColor(isSmaller ? .green : .red).bold())\(resolutionChangeStr)\(percentageSaved)\(savedAs)"
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
}

let HOME = FilePath(NSHomeDirectory())
extension FilePath {
    var shellString: String { string.replacingFirstOccurrence(of: HOME.string, with: "~") }
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
