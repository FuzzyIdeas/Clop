//
//  Settings.swift
//  Clop
//
//  Created by Alin Panaitiu on 13.07.2023.
//

import Cocoa
import Defaults
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

extension SauceKey: Defaults.Serializable {}
extension UTType: Defaults.Serializable {}

extension UTType {
    static let avif = UTType("public.avif")
    static let webm = UTType("org.webmproject.webm")
    static let mkv = UTType("org.matroska.mkv")
    static let mpeg = UTType("public.mpeg")
    static let wmv = UTType("com.microsoft.windows-media-wmv")
    static let flv = UTType("com.adobe.flash.video")
    static let m4v = UTType("com.apple.m4v-video")
}

let VIDEO_FORMATS: [UTType] = [.quickTimeMovie, .mpeg4Movie, .webm, .mkv, .mpeg2Video, .avi, .m4v, .mpeg].compactMap { $0 }
let FORMATS_CONVERTIBLE_TO_MP4: [UTType] = VIDEO_FORMATS.without([.mpeg4Movie])

let IMAGE_FORMATS: [UTType] = [.webP, .avif, .heic, .bmp, .tiff, .png, .jpeg, .gif].compactMap { $0 }
let FORMATS_CONVERTIBLE_TO_JPEG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])
let FORMATS_CONVERTIBLE_TO_PNG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])
let IMAGE_VIDEO_FORMATS = IMAGE_FORMATS + VIDEO_FORMATS

let VIDEO_EXTENSIONS = VIDEO_FORMATS.compactMap(\.preferredFilenameExtension)
let IMAGE_EXTENSIONS = IMAGE_FORMATS.compactMap(\.preferredFilenameExtension) + ["jpg"]

let VIDEO_PASTEBOARD_TYPES = VIDEO_FORMATS.compactMap { NSPasteboard.PasteboardType(rawValue: $0.identifier) }
let IMAGE_PASTEBOARD_TYPES = IMAGE_FORMATS.compactMap { NSPasteboard.PasteboardType(rawValue: $0.identifier) }
let IMAGE_VIDEO_PASTEBOARD_TYPES: Set<NSPasteboard.PasteboardType> = (IMAGE_PASTEBOARD_TYPES + VIDEO_PASTEBOARD_TYPES + [.fileContents]).set

public extension Defaults.Keys {
    static let showMenubarIcon = Key<Bool>("showMenubarIcon", default: true)
    static let enableFloatingResults = Key<Bool>("enableFloatingResults", default: true)
    static let optimiseTIFF = Key<Bool>("optimiseTIFF", default: true)
    static let enableClipboardOptimiser = Key<Bool>("enableClipboardOptimiser", default: true)
    static let optimiseVideoClipboard = Key<Bool>("optimiseVideoClipboard", default: false)
    static let optimiseImagePathClipboard = Key<Bool>("optimiseImagePathClipboard", default: false)

    static let formatsToConvertToJPEG = Key<Set<UTType>>("formatsToConvertToJPEG", default: [UTType.webP, UTType.avif, UTType.heic, UTType.bmp].compactMap { $0 }.set)
    static let formatsToConvertToPNG = Key<Set<UTType>>("formatsToConvertToPNG", default: [.tiff])
    static let formatsToConvertToMP4 = Key<Set<UTType>>("formatsToConvertToMP4", default: [UTType.quickTimeMovie, UTType.mpeg2Video, UTType.mpeg, UTType.webm].compactMap { $0 }.set)
    static let convertedImageBehaviour = Key<ConvertedFileBehaviour>("convertedImageBehaviour", default: .sameFolder)
    static let convertedVideoBehaviour = Key<ConvertedFileBehaviour>("convertedVideoBehaviour", default: .sameFolder)

    static let capVideoFPS = Key<Bool>("capVideoFPS", default: true)
    static let targetVideoFPS = Key<Float>("targetVideoFPS", default: 60)
    static let minVideoFPS = Key<Float>("minVideoFPS", default: 30)

    #if arch(arm64)
        static let useCPUIntensiveEncoder = Key<Bool>("useCPUIntensiveEncoder", default: false)
    #endif
    static let useAggresiveOptimisationMP4 = Key<Bool>("useAggresiveOptimisationMP4", default: false)
    static let useAggresiveOptimisationJPEG = Key<Bool>("useAggresiveOptimisationJPEG", default: false)
    static let useAggresiveOptimisationPNG = Key<Bool>("useAggresiveOptimisationPNG", default: false)
    static let useAggresiveOptimisationGIF = Key<Bool>("useAggresiveOptimisationGIF", default: false)

    static let videoDirs = Key<[String]>("videoDirs", default: [URL.desktopDirectory.path])
    static let imageDirs = Key<[String]>("imageDirs", default: [URL.desktopDirectory.path])

    static let maxVideoSizeMB = Key<Int>("maxVideoSizeMB", default: 500)
    static let maxImageSizeMB = Key<Int>("maxImageSizeMB", default: 50)
    static let imageFormatsToSkip = Key<Set<UTType>>("imageFormatsToSkip", default: [.tiff])
    static let videoFormatsToSkip = Key<Set<UTType>>("videoFormatsToSkip", default: [UTType.mkv, UTType.m4v].compactMap { $0 }.set)
    static let adaptiveVideoSize = Key<Bool>("adaptiveVideoSize", default: true)
    static let adaptiveImageSize = Key<Bool>("adaptiveImageSize", default: true)
    static let downscaleRetinaImages = Key<Bool>("downscaleRetinaImages", default: false)

    static let showFloatingHatIcon = Key<Bool>("showFloatingHatIcon", default: true)
    static let enableDragAndDrop = Key<Bool>("enableDragAndDrop", default: true)
    static let showImages = Key<Bool>("showImages", default: true)
    static let autoHideFloatingResults = Key<Bool>("autoHideFloatingResults", default: true)
    static let autoHideFloatingResultsAfter = Key<Int>("autoHideFloatingResultsAfter", default: 30)
    static let autoHideClipboardResultAfter = Key<Int>("autoHideClipboardResultAfter", default: 3)
    static let floatingResultsCorner = Key<ScreenCorner>("floatingResultsCorner", default: .bottomRight)
    static let neverShowProError = Key<Bool>("neverShowProError", default: false)

    static let keyComboModifiers = Key<[TriggerKey]>("keyComboModifiers", default: [.lctrl, .lshift])
    static let quickResizeKeys = Key<[SauceKey]>("quickResizeKeys", default: [.five, .three])
    static let enabledKeys = Key<[SauceKey]>("enabledKeys", default: [.minus, .equal, .delete, .space, .z, .p, .c, .a])
}

public enum ConvertedFileBehaviour: String, Defaults.Serializable {
    case temporary
    case inPlace
    case sameFolder
}
