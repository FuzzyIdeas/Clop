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
        guard let item = pb.pasteboardItems?.first, let nsImage = NSImage(pasteboard: pb)
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

        switch type {
        case .png:
            return try Self.optimizePNG(path: path)
        case .jpeg:
            return try Self.optimizeJPEG(path: path)
        case .gif:
            return try Self.optimizeGIF(path: path)
        default:
            throw ClopError.unknownImageType(path.string)
        }
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

func optimizeImage(_ image: PBImage? = nil) throws {
    let image = try (image ?? PBImage.fromPasteboard())
    let optimizedImage = try image.optimize()
    optimizedImage.copyToClipboard()
}

let SHOW_MENUBAR_ICON = "showMenubarIcon"

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var observers: [AnyCancellable] = []
    var timer: Timer?
    var pbChangeCount = NSPasteboard.general.changeCount

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.register(defaults: [SHOW_MENUBAR_ICON: true])

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            let newChangeCount = NSPasteboard.general.changeCount
            guard newChangeCount != pbChangeCount else {
                return
            }
            pbChangeCount = newChangeCount

            do {
                try optimizeImage(try PBImage.fromPasteboard())
            } catch let error as ClopError {
                print(error.description)
            } catch {
                print(error.localizedDescription)
            }
        }

        timer?.tolerance = 100

        if let window = NSApplication.shared.windows.first, UserDefaults.standard.bool(forKey: SHOW_MENUBAR_ICON) {
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    var body: some Scene {
        Window("Settings", id: "settings") {
            ContentView()
        }
        .onChange(of: scenePhase) { newScenePhase in
            switch newScenePhase {
            case .active:
                print("App is active")
                if !showMenubarIcon {
                    DispatchQueue.main.async {
                        openWindow(id: "settings")
                    }
                }
            case .inactive:
                print("App is inactive")
            case .background:
                print("App is in background")
            @unknown default:
                print("Oh - interesting: I received an unexpected new value.")
            }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Clop", image: "MenubarIcon", isInserted: $showMenubarIcon) {
            MenuView()
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: showMenubarIcon) { show in
            if !show {
                openWindow(id: "settings")
            } else {
                NSApplication.shared.keyWindow?.close()
            }
        }
    }
}
