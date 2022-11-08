//
//  ClopApp.swift
//  Clop
//
//  Created by Alin Panaitiu on 16.07.2022.
//

import SwiftUI

import Cocoa
import Combine
import Foundation
import ServiceManagement
import System
import UniformTypeIdentifiers

let fm = FileManager.default

extension Data {
    var str: String? {
        String(data: self, encoding: .utf8)
    }
}

// MARK: - Process + Sendable

extension Process: @unchecked Sendable {}

func shellProc(_ launchPath: String = "/bin/zsh", args: [String], env: [String: String]? = nil) -> Process? {
    let outputDir = try! fm.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: fm.homeDirectoryForCurrentUser,
        create: true
    )

    let stdoutFilePath = outputDir.appendingPathComponent("stdout").path
    fm.createFile(atPath: stdoutFilePath, contents: nil, attributes: nil)

    let stderrFilePath = outputDir.appendingPathComponent("stderr").path
    fm.createFile(atPath: stderrFilePath, contents: nil, attributes: nil)

    guard let stdoutFile = FileHandle(forWritingAtPath: stdoutFilePath),
          let stderrFile = FileHandle(forWritingAtPath: stderrFilePath)
    else {
        return nil
    }

    let task = Process()
    task.standardOutput = stdoutFile
    task.standardError = stderrFile
    task.launchPath = launchPath
    task.arguments = args

    var env = env ?? ProcessInfo.processInfo.environment
    env["__swift_stdout"] = stdoutFilePath
    env["__swift_stderr"] = stderrFilePath
    task.environment = env

    do {
        try task.run()
    } catch {
        print("Error running \(launchPath) \(args): \(error)")
        return nil
    }

    return task
}

let PNGQUANT = Bundle.main.url(forResource: "pngquant", withExtension: nil)!.path
let JPEGOPTIM = Bundle.main.url(forResource: "jpegoptim", withExtension: nil)!.path
let GIFSICLE = Bundle.main.url(forResource: "gifsicle", withExtension: nil)!.path

extension UTType {
    var imgType: NSBitmapImageRep.FileType {
        switch self {
        case .png:
            return .png
        case .jpeg:
            return .jpeg
        case .gif:
            return .gif
        default:
            return .png
        }
    }
}

extension NSPasteboard.PasteboardType {
    static var optimizationStatus: NSPasteboard.PasteboardType = .init("clop.optimization.status")
}

// MARK: - PBImage

class PBImage {
    // MARK: Lifecycle

    init(data: Data, path: FilePath, type: UTType? = nil, optimized: Bool? = nil) {
        self.path = path
        self.data = data
        if let type {
            self.type = type
        }
        if let optimized {
            self.optimized = optimized
        }
    }

    init?(path: FilePath, optimized: Bool? = nil) {
        self.path = path
        guard let data = fm.contents(atPath: path.string) else { return nil }
        self.data = data

        if let optimized {
            self.optimized = optimized
        }
    }

    convenience init?(data: Data) {
        guard let nsImage = NSImage(data: data) else { return nil }
        self.init(nsImage: nsImage)
    }

    init?(nsImage: NSImage, optimized: Bool? = nil) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let typeStr = cgImage.utType, let type = UTType(typeStr as String), let ext = type.preferredFilenameExtension,
              let data = (nsImage.representations.first as? NSBitmapImageRep)?.representation(using: type.imgType, properties: [:])
        else { return nil }

        self.data = data
        let tempPath = fm.temporaryDirectory.appendingPathComponent("\(Int.random(in: 100 ... 100_000)).\(ext)").path
        guard fm.createFile(atPath: tempPath, contents: data) else { return nil }

        path = FilePath(tempPath)
        self.nsImage = nsImage
        self.type = type
        self.optimized = optimized ?? false
    }

    // MARK: Internal

    static let PNG_HEADER: Data = .init([0x89, 0x50, 0x4E, 0x47])
    static let JPEG_HEADER: Data = .init([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    static let GIF_HEADER: Data = .init([0x47, 0x49, 0x46, 0x38, 0x39])

    static var NOT_IMAGE_TYPE_PATTERN =
        try! Regex(
            "com.microsoft.ole.source|com.microsoft.Art|com.microsoft.PowerPoint|com.microsoft.image-svg-xml|com.microsoft.DataObject"
        )
    static var NOT_IMAGE_TYPES: Set<NSPasteboard.PasteboardType> = [
        .init("com.apple.icns"),
        .init("public.svg-image"),
        .init("public.xml"),
        .init("com.adobe.illustrator.ai-image"),
        .init("com.adobe.photoshop-image"),
        .init("com.adobe.photoshop-large-image"),
        .init("com.ilm.openexr-image"),
        .init("com.kodak.flashpix-image"),
        .init("com.sgi.sgi-image"),
        .init("com.truevision.tga-image"),
        .init("org.oasis-open.opendocument.image"),
        .init("org.oasis-open.opendocument.image-template"),
        .init("public.xbitmap-image"),
        .init("com.apple.notes.sketch"),
        .init("com.bohemiancoding.sketch.clouddrawing.single"),
        .init("com.bohemiancoding.sketch.drawing"),
        .init("com.bohemiancoding.sketch.drawing.single"),
        .init("com.apple.graphic-icon"),
        .init("com.apple.icon-decoration"),
        .init("com.apple.iconset"),
        .init("com.microsoft.Object-Descriptor"),
        .init("com.microsoft.appbundleid"),
        .init("com.adobe.pdf"),
    ]

    let data: Data
    let path: FilePath

    lazy var nsImage: NSImage? = .init(data: data)
    lazy var optimized: Bool = {
        guard let type else { return false }

        switch type {
        case .png:
            return path.string.hasSuffix(".clop.png")
        case .jpeg:
            return path.string.hasSuffix(".clop.jpg")
        case .gif:
            return path.string.hasSuffix(".clop.gif")
        default:
            return false
        }
    }()

    lazy var type: UTType? = UTType(filenameExtension: path.extension ?? "")

    static func optimizeGIF(path: FilePath) throws -> PBImage {
        let tempDir = fm.temporaryDirectory.appending(path: path.stem ?? "clop", directoryHint: .isDirectory)
        let tempFile = tempDir.appending(path: path.lastComponent?.string ?? "clop.gif", directoryHint: .notDirectory)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let proc = shellProc(GIFSICLE, args: ["-j", "--optimize=3", "--lossy=30", "--output", tempFile.path, path.string]) else {
            throw ClopError.noProcess("jpegoptim")
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        let newPath = FilePath(tempFile.path)
        guard let data = fm.contents(atPath: newPath.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(newPath.string)
        }

        return PBImage(data: data, path: newPath, type: .gif, optimized: true)
    }

    static func optimizeJPEG(path: FilePath) throws -> PBImage {
        let tempDir = fm.temporaryDirectory.appending(path: path.stem ?? "clop", directoryHint: .isDirectory)
        let tempFile = tempDir.appending(path: path.lastComponent?.string ?? "clop.jpg", directoryHint: .notDirectory)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let proc = shellProc(JPEGOPTIM, args: ["--strip-all", "--max", "90", "--overwrite", "-d", tempDir.path, path.string]) else {
            throw ClopError.noProcess("jpegoptim")
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        let newPath = FilePath(tempFile.path)
        guard let data = fm.contents(atPath: newPath.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(newPath.string)
        }

        return PBImage(data: data, path: newPath, type: .jpeg, optimized: true)
    }

    static func optimizeTIFF(path: FilePath) throws -> PBImage {
        guard let data = fm.contents(atPath: path.string), let name = path.stem else {
            throw ClopError.fileNotFound(path.string)
        }

        if data.starts(with: PNG_HEADER) {
            let png = path.removingLastComponent().appending("\(name).png")
            try fm.moveItem(atPath: path.string, toPath: png.string)
            return try optimizePNG(path: png)
        }

        if data.starts(with: JPEG_HEADER) {
            let jpg = path.removingLastComponent().appending("\(name).jpg")
            try fm.moveItem(atPath: path.string, toPath: jpg.string)
            return try optimizeJPEG(path: jpg)
        }

        if data.starts(with: GIF_HEADER) {
            let gif = path.removingLastComponent().appending("\(name).gif")
            try fm.moveItem(atPath: path.string, toPath: gif.string)
            return try optimizeGIF(path: gif)
        }

        throw ClopError.unknownImageType(path.string)
    }

    static func optimizePNG(path: FilePath) throws -> PBImage {
        let tempDir = fm.temporaryDirectory.appending(path: path.stem ?? "clop", directoryHint: .isDirectory)
        let tempFile = tempDir.appending(path: path.lastComponent?.string ?? "clop.png", directoryHint: .notDirectory)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let proc = shellProc(PNGQUANT, args: ["--output", tempFile.path, "--strip", "-f", "-s", "1", path.string]) else {
            throw ClopError.noProcess("pngquant")
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ClopError.processError(proc)
        }

        let newPath = FilePath(tempFile.path)
        guard let data = fm.contents(atPath: newPath.string), NSImage(data: data) != nil else {
            throw ClopError.fileNotFound(newPath.string)
        }

        return PBImage(data: data, path: newPath, type: .png, optimized: true)
    }

    static func isRaw(pasteboardItem: NSPasteboardItem) -> Bool {
        pasteboardItem.types.contains(where: { $0.rawValue.contains("raw-image") })
    }

    class func fromCommandLine() throws -> PBImage {
        let impath = CommandLine.arguments[1]
        guard fm.fileExists(atPath: impath) else {
            throw ClopError.fileNotFound(impath)
        }

        guard let data = fm.contents(atPath: impath), NSImage(data: data) != nil else {
            throw ClopError.fileNotImage(impath)
        }
        return PBImage(data: data, path: FilePath(impath))
    }

    class func fromPasteboard() throws -> PBImage {
        let pb = NSPasteboard.general
        guard let item = pb.pasteboardItems?.first,
              !NSOrderedSet(array: item.types).intersectsSet(NOT_IMAGE_TYPES), !isRaw(pasteboardItem: item),
              (try NOT_IMAGE_TYPE_PATTERN.firstMatch(in: item.types.map(\.rawValue).joined(separator: " "))) == nil,
              let nsImage = NSImage(pasteboard: pb)
        else {
            throw ClopError.noClipboardImage(pb.pasteboardItems?.first?.string(forType: .fileURL) ?? "")
        }

        if let imgURLString = item.string(forType: .fileURL),
           let imgURL = URL(string: imgURLString), fm.fileExists(atPath: imgURL.path),
           let img = PBImage(path: FilePath(imgURL.path), optimized: item.string(forType: .optimizationStatus) == "true")
        {
            return img
        }

        guard let img = PBImage(nsImage: nsImage, optimized: item.string(forType: .optimizationStatus) == "true") else {
            throw ClopError.noClipboardImage(pb.pasteboardItems?.first?.string(forType: .fileURL) ?? "")
        }

        return img
    }

    func optimize() throws -> PBImage {
        guard !optimized, let type else {
            throw ClopError.alreadyOptimized(path.string)
        }

        let img: PBImage
        switch type {
        case .png:
            img = try Self.optimizePNG(path: path)
        case .jpeg:
            img = try Self.optimizeJPEG(path: path)
        case .gif:
            img = try Self.optimizeGIF(path: path)
        case .tiff:
            img = try Self.optimizeTIFF(path: path)
        default:
            throw ClopError.unknownImageType(path.string)
        }

        guard img.data.count < data.count else {
            throw ClopError.imageSizeLarger(path.string)
        }

        return img
    }

    func copyToClipboard() {
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        item.setString(URL(fileURLWithPath: path.string, isDirectory: false).absoluteString, forType: .fileURL)
        item.setString("true", forType: .optimizationStatus)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }
}

// MARK: - ClopError

enum ClopError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case fileNotImage(String)
    case noClipboardImage(String)
    case noProcess(String)
    case processError(Process)
    case alreadyOptimized(String)
    case unknownImageType(String)
    case imageSizeLarger(String)

    // MARK: Internal

    var description: String {
        switch self {
        case let .fileNotFound(string):
            return "File not found: \(string)"
        case let .fileNotImage(string):
            return "File is not an image: \(string)"
        case let .noClipboardImage(string):
            if string.isEmpty { return "No image in clipboard" }
            return "No image in clipboard: \(string.count > 100 ? string.prefix(50) + "..." + string.suffix(50) : string)"
        case let .noProcess(string):
            return "Can't start process: \(string)"
        case let .alreadyOptimized(string):
            return "Image is already optimized: \(string)"
        case let .imageSizeLarger(string):
            return "Optimized image size is larger: \(string)"
        case let .unknownImageType(string):
            return "Unknown image type: \(string)"
        case let .processError(proc):
            var desc = "Process error: \(([proc.launchPath ?? ""] + (proc.arguments ?? [])).joined(separator: " "))"
            guard let out = proc.standardOutput as? FileHandle, let err = proc.standardError as? FileHandle,
                  let outData = try? out.readToEnd(), let errData = try? err.readToEnd()
            else {
                return desc
            }
            desc += "\n\t" + (outData.str ?? "NON-UTF8 STDOUT")
            desc += "\n\t" + (errData.str ?? "NON-UTF8 STDERR")
            return desc
        }
    }
}

func optimizeImage(_ image: PBImage? = nil) throws -> PBImage {
    let image = try (image ?? PBImage.fromPasteboard())
    let optimizedImage = try image.optimize()
    optimizedImage.copyToClipboard()

    return optimizedImage
}

let SHOW_MENUBAR_ICON = "showMenubarIcon"
let SHOW_SIZE_NOTIFICATION = "showSizeNotification"
let OPTIMIZE_TIFF = "optimizeTIFF"

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var observers: [AnyCancellable] = []

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.register(defaults: [SHOW_MENUBAR_ICON: true, SHOW_SIZE_NOTIFICATION: true])
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if let window = NSApplication.shared.windows.first {
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - WindowModifierView

class WindowModifierView: NSView {
    // MARK: Lifecycle

    init(_ modifier: @escaping (NSWindow) -> Void) {
        self.modifier = modifier
        super.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: Internal

    var modifier: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        if let window, let modifier {
            modifier(window)
        }
        super.viewDidMoveToWindow()
    }
}

// MARK: - WindowModifier

struct WindowModifier: NSViewRepresentable {
    // MARK: Lifecycle

    init(_ modifier: @escaping (NSWindow) -> Void) {
        self.modifier = modifier
    }

    // MARK: Internal

    var modifier: (NSWindow) -> Void

    func makeNSView(context: Self.Context) -> NSView { WindowModifierView(modifier) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

var launchAtLogin = SMAppService.mainApp.status == .enabled
var startCount = 0

// MARK: - ImageOptimizationResult

struct ImageOptimizationResult: Identifiable, Codable, Hashable {
    let id: String
    let oldBytes: Int
    let newBytes: Int
}

// MARK: - Optimizer

class Optimizer: ObservableObject {
    // MARK: Lifecycle

    init(running: Bool = true, oldBytes: Int = 0, newBytes: Int = 0) {
        self.running = running
        self.oldBytes = oldBytes
        self.newBytes = newBytes
    }

    // MARK: Internal

    @Published var running = true
    @Published var oldBytes = 0
    @Published var newBytes = 0

    func finish(result: ImageOptimizationResult) {
        withAnimation(.spring()) {
            self.oldBytes = result.oldBytes
            self.newBytes = result.newBytes
            self.running = false
        }
    }

    func finish(oldBytes: Int, newBytes: Int) {
        withAnimation(.spring()) {
            self.oldBytes = oldBytes
            self.newBytes = newBytes
            self.running = false
        }
    }
}

// MARK: - ClopApp

@main
struct ClopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Environment(\.openWindow) var openWindow
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase

    @AppStorage(SHOW_MENUBAR_ICON) var showMenubarIcon = true
    @AppStorage(SHOW_SIZE_NOTIFICATION) var showSizeNotification = true
    @AppStorage(OPTIMIZE_TIFF) var optimizeTIFF = true

    @State var timer: Timer?
    @State var pbChangeCount = NSPasteboard.general.changeCount

    @State var sizeNotificationWindow: OSDWindow?

    var body: some Scene {
        Window("Settings", id: "settings") {
            ContentView()
                .background(WindowModifier { window in
                    window.isMovableByWindowBackground = true
                })
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .onChange(of: scenePhase) { newScenePhase in
            switch newScenePhase {
            case .active:
                print("App is active")
                start()
            case .inactive:
                print("App is inactive")
            case .background:
                print("App is in background")
            @unknown default:
                print("Oh - interesting: I received an unexpected new value.")
            }
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showMenubarIcon, content: { MenuView() }, label: { Image(nsImage: NSImage(named: "MenubarIcon")!) })
            .menuBarExtraStyle(.menu)
            .onChange(of: showMenubarIcon) { show in
                if !show {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    NSApplication.shared.keyWindow?.close()
                }
            }
    }

    func start() {
        startCount += 1
        if !showMenubarIcon, startCount > 1 {
            DispatchQueue.main.async {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            let newChangeCount = NSPasteboard.general.changeCount
            guard newChangeCount != pbChangeCount else {
                return
            }
            pbChangeCount = newChangeCount

            do {
                let img = try PBImage.fromPasteboard()
                guard !img.optimized else { return }
                guard img.type != .tiff || optimizeTIFF else {
                    print("Skipping image \(img.path) because TIFF optimization is disabled")
                    return
                }

                let optimizer = Optimizer()
                if showSizeNotification {
                    sizeNotificationWindow = OSDWindow(swiftuiView: AnyView(SizeNotificationView(optimizer: optimizer)))
                    sizeNotificationWindow?.show(fadeAfter: 5000, fadeDuration: 0.2, corner: .bottomRight)
                }

                let newImg = try optimizeImage(img)
                guard showSizeNotification else { return }

                optimizer
                    .finish(result: ImageOptimizationResult(id: img.path.string, oldBytes: img.data.count, newBytes: newImg.data.count))
                sizeNotificationWindow?.show(fadeAfter: 1500, fadeDuration: 0.2, corner: .bottomRight)
            } catch let error as ClopError {
                print(error.description)
            } catch {
                print(error.localizedDescription)
            }
        }

        timer?.tolerance = 100
    }
}
