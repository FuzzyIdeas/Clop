//
//  ClopShortcuts.swift
//  Clop
//
//  Created by Alin Panaitiu on 28.07.2023.
//

import AppIntents
import Foundation
import Lowtech
import PDFKit

extension IntentFile {
    var url: URL {
        if let fileURL {
            return fileURL
        }

        var fileURL = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: fm.homeDirectoryForCurrentUser, create: true)) ?? fm.temporaryDirectory
        fileURL.append(path: filename)
        fm.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case general
    case message(_ message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .message(message): "Error: \(message)"
        case .general: "Error"
        }
    }
}

var shortcutsOptimisationCount = 0

struct ChangePlaybackSpeedOptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Change video playback speed"
    static var description = IntentDescription("Optimises a video received as input and changes its playback speed by the specific factor.")

    static var parameterSummary: some ParameterSummary {
        When(\.$playbackSpeedFactor, ComparableComparisonOperator.greaterThanOrEqualTo, 1.0, {
            Summary("Speed up \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$removeAudio
            }
        }, otherwise: {
            Summary("Slow down \(\.$item) by \(\.$playbackSpeedFactor)x and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$removeAudio
            }
        })
    }

    @Parameter(title: "Video")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Playback speed factor", default: 1.5)
    var playbackSpeedFactor: Double

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to overwriting the original file).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %x	Playback speed factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f @ %xx.%e` on a file like `~/Desktop/video.mp4` will generate the file `~/Desktop/video @ 2x.mp4`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromURL(item.url)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                changePlaybackSpeedBy: playbackSpeedFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: false, source: "shortcuts",
                output: output,
                removeAudio: removeAudio
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't change playback speed for \(item)")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

struct CropOptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Crop image or video"
    static var description = IntentDescription("Resizes and does a smart crop on an image or video received as input. Use 0 for width or height to have it calculated automatically while keeping the original aspect ratio.")

    static var parameterSummary: some ParameterSummary {
        When(\.$longEdge, .equalTo, true, {
            Summary("Crop \(\.$item) to \(\.$size) over the longest edge and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$copyToClipboard
                \.$longEdge
                \.$removeAudio
            }
        }, otherwise: {
            Summary("Crop \(\.$item) to \(\.$width)x\(\.$height) and optimise") {
                \.$output
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$copyToClipboard
                \.$longEdge
                \.$removeAudio
            }
        })
    }

    @Parameter(title: "Video, image or PDF file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

    @Parameter(title: "Resize over long edge")
    var longEdge: Bool

    @Parameter(title: "Width")
    var width: Int?

    @Parameter(title: "Height")
    var height: Int?

    @Parameter(title: "Size")
    var size: Int?

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to overwriting the original file).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %z	Crop size
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f @ %zpx.%e` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image @ 128px.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        if longEdge, (size ?? 0) == 0 {
            throw $size.needsValueError()
        }
        if !longEdge, (width ?? 0) == 0, (height ?? 0) == 0 {
            throw IntentError.message("You need to specify at least one non-zero width or height")
        }

        let clip = ClipboardType.fromURL(item.url)
        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                cropTo: CropSize(width: (longEdge ? size : width) ?? 0, height: (longEdge ? size : height) ?? 0, longEdge: longEdge),
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts",
                output: output,
                removeAudio: removeAudio
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't crop \(item)")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

struct CropPDFIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Crop PDF"
    static var description = IntentDescription("Crops a PDF for a specific device, paper size or aspect ratio.")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            When(\.$usePaperSize, .equalTo, true, {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$paperSize) and \(\.$overwrite)") { \.$pageLayout }
            }, otherwise: {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$device) and \(\.$overwrite)") { \.$pageLayout }
            })
        }, otherwise: {
            When(\.$usePaperSize, .equalTo, true, {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$paperSize) and \(\.$overwrite) \(\.$output)") { \.$pageLayout }
            }, otherwise: {
                Summary("Crop \(\.$item) \(\.$usePaperSize) \(\.$device) and \(\.$overwrite) \(\.$output)") { \.$pageLayout }
            })
        })
    }

    @Parameter(title: "PDF")
    var item: IntentFile

    @Parameter(title: "Paper size or device", displayName: .init(true: "to paper size", false: "for device"))
    var usePaperSize: Bool

    @Parameter(title: "Page layout", description: """
    Allows forcing a page layout on all PDF pages:
        auto: Crop pages based on their longest edge, so that horizontal pages stay horizontal and vertical pages stay vertical
        portrait: Force all pages to be cropped to vertical or portrait layout
        landscape: Force all pages to be cropped to horizontal or landscape layout
    """, default: PageLayout.auto)
    var pageLayout: PageLayout

    @Parameter(title: "Paper", default: PaperSize.a4)
    var paperSize: PaperSize?

    @Parameter(title: "Device", default: Device.iPadAir)
    var device: Device?

    @Parameter(title: "Output path", description: "Where to save the cropped PDF (defaults to modifying the PDF in place).")
    var output: String?

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let aspectRatio = usePaperSize ? paperSize?.aspectRatio : device?.aspectRatio else {
            throw IntentError.message("Invalid aspect ratio")
        }

        let url = item.url
        guard let pdf = PDFDocument(url: url) else {
            throw IntentError.message("Couldn't parse PDF")
        }

        var outputURL = (overwrite ? nil : output?.filePath?.url) ?? pdf.documentURL ?? url
        if outputURL.filePath!.isDir {
            outputURL = outputURL.appendingPathComponent(url.lastPathComponent)
        }

        log.debug("Cropping \(pdf.documentURL?.path ?? "PDF") to aspect ratio \(aspectRatio)")
        pdf.cropTo(aspectRatio: aspectRatio, alwaysPortrait: pageLayout == .portrait, alwaysLandscape: pageLayout == .landscape)

        log.debug("Writing PDF to \(outputURL.path)")
        pdf.write(to: outputURL)

        let file = IntentFile(fileURL: outputURL, filename: outputURL.lastPathComponent)
        return .result(value: file)
    }
}

struct OptimiseFileIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise file"
    static var description = IntentDescription("Optimises an image, video or PDF received as input.")

    static var parameterSummary: some ParameterSummary {
        When(\.$overwrite, .equalTo, true, {
            Summary("Optimise \(\.$item) and \(\.$overwrite)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$downscaleFactor
                \.$copyToClipboard
                \.$removeAudio
            }
        }, otherwise: {
            Summary("Optimise \(\.$item) and \(\.$overwrite) \(\.$output)") {
                \.$hideFloatingResult
                \.$aggressiveOptimisation
                \.$downscaleFactor
                \.$copyToClipboard
                \.$removeAudio
            }
        })
    }

    @Parameter(title: "Video, image or PDF file")
    var item: IntentFile

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Overwrite original file", default: true, displayName: .init(true: "overwrite original file", false: "save to"))
    var overwrite: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

    @Parameter(title: "Downscale factor", description: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)", default: 1.0, controlStyle: .field, inclusiveRange: (0.1, 1.0))
    var downscaleFactor: Double

    @Parameter(title: "Output path", description: """
    Output file path or template (defaults to overwriting the original file).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised.%e` on a file like `~/Desktop/image.png` will generate the file `~/Desktop/image_optimised.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromURL(item.url)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts",
                output: overwrite ? nil : output,
                removeAudio: removeAudio
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't optimise item")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

struct OptimiseURLIntent: AppIntent {
    init() {}

    static var title: LocalizedStringResource = "Optimise URL"
    static var description = IntentDescription("Optimises an image, video or PDF that can be downloaded from a provided URL.")

    static var parameterSummary: some ParameterSummary {
        Summary("Optimise \(\.$item) and save to \(\.$output)") {
            \.$hideFloatingResult
            \.$aggressiveOptimisation
            \.$downscaleFactor
            \.$copyToClipboard
            \.$removeAudio
        }
    }

    @Parameter(title: "URL")
    var item: URL

    @Parameter(title: "Hide floating result")
    var hideFloatingResult: Bool

    @Parameter(title: "Use aggressive optimisation")
    var aggressiveOptimisation: Bool

    @Parameter(title: "Copy to clipboard")
    var copyToClipboard: Bool

    @Parameter(title: "Remove audio from video")
    var removeAudio: Bool

    @Parameter(title: "Downscale factor", description: "Makes the image or video smaller by a certain amount (1.0 means no resize, 0.5 means half the size)", default: 1.0, controlStyle: .field, inclusiveRange: (0.1, 1.0))
    var downscaleFactor: Double

    @Parameter(title: "Output path (or temporary folder)", description: """
    Output file path or template (defaults to saving to a temporary folder).

    The template may contain the following tokens on the filename:

    %y	Year
    %m	Month (numeric)
    %n	Month (name)
    %d	Day
    %w	Weekday

    %H	Hour
    %M	Minutes
    %S	Seconds
    %p	AM/PM

    %f	Source file name (without extension)
    %e	Source file extension

    %s	Scale factor
    %r	Random characters
    %i	Auto-incrementing number

    For example `~/Desktop/%f_optimised.%e` on an URL like `https://example.com/image.png` will generate the file `~/Desktop/image_optimised.png`.

    """)
    var output: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let clip = ClipboardType.fromURL(item)

        let result: ClipboardType?
        do {
            result = try await optimiseItem(
                clip,
                id: clip.id,
                hideFloatingResult: hideFloatingResult,
                downscaleTo: downscaleFactor,
                aggressiveOptimisation: aggressiveOptimisation,
                optimisationCount: &shortcutsOptimisationCount,
                copyToClipboard: copyToClipboard,
                source: "shortcuts",
                output: output,
                removeAudio: removeAudio
            )
        } catch let ClopError.alreadyOptimised(path) {
            guard path.exists else {
                throw IntentError.message("Couldn't find file at \(path)")
            }
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        } catch let error as ClopError {
            throw IntentError.message(error.description)
        } catch {
            log.error(error.localizedDescription)
            throw IntentError.message(error.localizedDescription)
        }

        guard let result else {
            throw IntentError.message("Couldn't optimise item")
        }

        switch result {
        case let .file(path):
            let file = IntentFile(fileURL: path.url, filename: path.name.string)
            return .result(value: file)
        case let .image(img):
            let file = IntentFile(fileURL: img.path.url, filename: img.path.name.string, type: img.type)
            return .result(value: file)
        default:
            throw IntentError.message("Bad optimisation result")
        }
    }
}

extension PageLayout: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Page Layout"
    }

    static var caseDisplayRepresentations: [PageLayout: DisplayRepresentation] {
        [
            .auto: DisplayRepresentation(
                title: "Auto",
                subtitle: "Crop pages based on their longest edge",
                image: .init(systemName: "sparkles.rectangle.stack.fill")
            ),
            .portrait: DisplayRepresentation(
                title: "Portrait",
                subtitle: "Force all pages to be vertical",
                image: .init(systemName: "rectangle.portrait.arrowtriangle.2.inward")
            ),
            .landscape: DisplayRepresentation(
                title: "Landscape",
                subtitle: "Force all pages to be horizontal",
                image: .init(systemName: "rectangle.arrowtriangle.2.inward")
            ),
        ]
    }
}

extension Device: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Device"
    }

    static var caseDisplayRepresentations: [Device: DisplayRepresentation] {
        [
            .iPhone15ProMax: "iPhone 15 Pro Max", .iPhone15Pro: "iPhone 15 Pro", .iPhone15Plus: "iPhone 15 Plus", .iPhone15: "iPhone 15",
            .iPadPro: "iPad Pro", .iPadPro6129Inch: "iPad Pro 6 12.9inch", .iPadPro611Inch: "iPad Pro 6 11inch",
            .iPad: "iPad", .iPad10: "iPad 10",
            .iPhone14Plus: "iPhone 14 Plus", .iPhone14ProMax: "iPhone 14 Pro Max", .iPhone14Pro: "iPhone 14 Pro", .iPhone14: "iPhone 14",
            .iPhoneSe3: "iPhone SE 3",
            .iPadAir: "iPad Air", .iPadAir5: "iPad Air 5",
            .iPhone13: "iPhone 13", .iPhone13Mini: "iPhone 13 mini", .iPhone13ProMax: "iPhone 13 Pro Max", .iPhone13Pro: "iPhone 13 Pro",
            .iPad9: "iPad 9", .iPadPro5129Inch: "iPad Pro 5 12.9inch", .iPadPro511Inch: "iPad Pro 5 11inch", .iPadAir4: "iPad Air 4",
            .iPhone12: "iPhone 12", .iPhone12Mini: "iPhone 12 mini", .iPhone12ProMax: "iPhone 12 Pro Max", .iPhone12Pro: "iPhone 12 Pro",
            .iPad8: "iPad 8",
            .iPhoneSe2: "iPhone SE 2",
            .iPadPro4129Inch: "iPad Pro 4 12.9inch", .iPadPro411Inch: "iPad Pro 4 11inch",
            .iPad7: "iPad 7",
            .iPhone11ProMax: "iPhone 11 Pro Max", .iPhone11Pro: "iPhone 11 Pro", .iPhone11: "iPhone 11",
            .iPodTouch7: "iPod touch 7",
            .iPadMini: "iPad mini", .iPadMini6: "iPad mini 6", .iPadMini5: "iPad mini 5", .iPadAir3: "iPad Air 3", .iPadPro3129Inch: "iPad Pro 3 12.9inch", .iPadPro311Inch: "iPad Pro 3 11inch",
            .iPhoneXr: "iPhone XR", .iPhoneXsMax: "iPhone XS Max", .iPhoneXs: "iPhone XS",
            .iPad6: "iPad 6",
            .iPhoneX: "iPhone X", .iPhone8Plus: "iPhone 8 Plus", .iPhone8: "iPhone 8",
            .iPadPro2129Inch: "iPad Pro 2 12.9inch",
            .iPadPro2105Inch: "iPad Pro 2 10.5inch",
            .iPad5: "iPad 5",
            .iPhone7Plus: "iPhone 7 Plus",
            .iPhone7: "iPhone 7",
            .iPhoneSe1: "iPhone SE 1",
            .iPadPro197Inch: "iPad Pro 1 9.7inch",
            .iPadPro1129Inch: "iPad Pro 1 12.9inch",
            .iPhone6SPlus: "iPhone 6s Plus",
            .iPhone6S: "iPhone 6s",
            .iPadMini4: "iPad mini 4",
            .iPodTouch6: "iPod touch 6",
            .iPadAir2: "iPad Air 2",
            .iPadMini3: "iPad mini 3",
            .iPhone6Plus: "iPhone 6 Plus",
            .iPhone6: "iPhone 6",
            .iPadMini2: "iPad mini 2",
            .iPadAir1: "iPad Air 1",
            .iPhone5C: "iPhone 5C",
            .iPhone5S: "iPhone 5S",
            .iPad4: "iPad 4",
            .iPodTouch5: "iPod touch 5",
            .iPhone5: "iPhone 5",
            .iPad3: "iPad 3",
            .iPhone4S: "iPhone 4S",
            .iPad2: "iPad 2",
            .iPodTouch4: "iPod touch 4",
            .iPhone4: "iPhone 4",
        ]
    }
}

extension PaperSize: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Paper Size"
    }

    static var caseDisplayRepresentations: [PaperSize: DisplayRepresentation] {
        [
            .a0: "A0", .a1: "A1", .a2: "A2", .a3: "A3", .a4: "A4", .a5: "A5", .a6: "A6", .a7: "A7", .a8: "A8", .a9: "A9", .a10: "A10", .a11: "A11", .a12: "A12", .a13: "A13",
            ._2A0: "2A0", ._4A0: "4A0", .a0plus: "A0+", .a1plus: "A1+", .a3plus: "A3+",
            .b0: "B0", .b1: "B1", .b2: "B2", .b3: "B3", .b4: "B4", .b5: "B5", .b6: "B6", .b7: "B7", .b8: "B8", .b9: "B9", .b10: "B10", .b11: "B11", .b12: "B12", .b13: "B13",
            .b0plus: "B0+", .b1plus: "B1+", .b2plus: "B2+", .letter: "Letter",
            .legal: "Legal", .tabloid: "Tabloid", .ledger: "Ledger", .juniorLegal: "Junior Legal", .halfLetter: "Half Letter", .governmentLetter: "Government Letter", .governmentLegal: "Government Legal",
            .ansiA: "ANSI A", .ansiB: "ANSI B", .ansiC: "ANSI C", .ansiD: "ANSI D", .ansiE: "ANSI E", .archA: "Arch A",
            .archB: "Arch B", .archC: "Arch C", .archD: "Arch D", .archE: "Arch E", .archE1: "Arch E1", .archE2: "Arch E2", .archE3: "Arch E3", .passport: "Passport",
            ._2R: "2R", .ldDsc: "LD, DSC", ._3RL: "3R, L", .lw: "LW", .kgd: "KGD", ._4RKg: "4R, KG", ._2LdDscw: "2LD, DSCW", ._5R2L: "5R, 2L", ._2Lw: "2LW", ._6R: "6R", ._8R6P: "8R, 6P", .s8R6Pw: "S8R, 6PW", ._11R: "11R",
            .a3SuperB: "A3+ Super B",
            .berliner: "Berliner", .broadsheet: "Broadsheet", .usBroadsheet: "US Broadsheet", .britishBroadsheet: "British Broadsheet", .southAfricanBroadsheet: "South African Broadsheet",
            .ciner: "Ciner", .compact: "Compact", .nordisch: "Nordisch", .rhenish: "Rhenish", .swiss: "Swiss",
            .newspaperTabloid: "Newspaper Tabloid", .canadianTabloid: "Canadian Tabloid", .norwegianTabloid: "Norwegian Tabloid", .newYorkTimes: "New York Times", .wallStreetJournal: "Wall Street Journal",
            .folio: "Folio", .quarto: "Quarto", .imperialOctavo: "Imperial Octavo", .superOctavo: "Super Octavo", .royalOctavo: "Royal Octavo", .mediumOctavo: "Medium Octavo", .octavo: "Octavo", .crownOctavo: "Crown Octavo",
            ._12Mo: "12mo", ._16Mo: "16mo", ._18Mo: "18mo", ._32Mo: "32mo", ._48Mo: "48mo", ._64Mo: "64mo",
            .aFormat: "A Format", .bFormat: "B Format", .cFormat: "C Format",
        ]
    }
}
