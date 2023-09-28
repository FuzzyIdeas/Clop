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

let FORMATS_CONVERTIBLE_TO_MP4: [UTType] = VIDEO_FORMATS.without([.mpeg4Movie])
let FORMATS_CONVERTIBLE_TO_JPEG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])
let FORMATS_CONVERTIBLE_TO_PNG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])

let VIDEO_EXTENSIONS = VIDEO_FORMATS.compactMap(\.preferredFilenameExtension)
let IMAGE_EXTENSIONS = IMAGE_FORMATS.compactMap(\.preferredFilenameExtension) + ["jpg"]

let VIDEO_PASTEBOARD_TYPES = VIDEO_FORMATS.compactMap { NSPasteboard.PasteboardType(rawValue: $0.identifier) }
let IMAGE_PASTEBOARD_TYPES = IMAGE_FORMATS.compactMap { NSPasteboard.PasteboardType(rawValue: $0.identifier) }
let IMAGE_VIDEO_PASTEBOARD_TYPES: Set<NSPasteboard.PasteboardType> = (IMAGE_PASTEBOARD_TYPES + VIDEO_PASTEBOARD_TYPES + [.fileContents]).set

let DEFAULT_HOVER_KEYS: [SauceKey] = [.minus, .delete, .space, .z, .c, .a, .s, .x, .r, .f]
let DEFAULT_GLOBAL_KEYS: [SauceKey] = [.minus, .equal, .delete, .space, .z, .p, .c, .a, .x, .r]

extension Defaults.Keys {
    static let showMenubarIcon = Key<Bool>("showMenubarIcon", default: true)
    static let enableFloatingResults = Key<Bool>("enableFloatingResults", default: true)
    static let optimiseTIFF = Key<Bool>("optimiseTIFF", default: true)
    static let enableClipboardOptimiser = Key<Bool>("enableClipboardOptimiser", default: true)
    static let optimiseVideoClipboard = Key<Bool>("optimiseVideoClipboard", default: false)
    static let optimiseImagePathClipboard = Key<Bool>("optimiseImagePathClipboard", default: false)
    static let stripMetadata = Key<Bool>("stripMetadata", default: true)

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
    static let useAggresiveOptimisationPDF = Key<Bool>("useAggresiveOptimisationPDF", default: true)

    static let imageDirs = Key<[String]>("imageDirs", default: [URL.desktopDirectory.path])
    static let videoDirs = Key<[String]>("videoDirs", default: [URL.desktopDirectory.path])
    static let pdfDirs = Key<[String]>("pdfDirs", default: [])

    static let maxVideoSizeMB = Key<Int>("maxVideoSizeMB", default: 500)
    static let maxImageSizeMB = Key<Int>("maxImageSizeMB", default: 50)
    static let maxPDFSizeMB = Key<Int>("maxPDFSizeMB", default: 100)
    static let maxVideoFileCount = Key<Int>("maxVideoFileCount", default: 1)
    static let maxImageFileCount = Key<Int>("maxImageFileCount", default: 4)
    static let maxPDFFileCount = Key<Int>("maxPDFFileCount", default: 2)
    static let imageFormatsToSkip = Key<Set<UTType>>("imageFormatsToSkip", default: [.tiff])
    static let videoFormatsToSkip = Key<Set<UTType>>("videoFormatsToSkip", default: [UTType.mkv, UTType.m4v].compactMap { $0 }.set)
    static let adaptiveVideoSize = Key<Bool>("adaptiveVideoSize", default: true)
    static let adaptiveImageSize = Key<Bool>("adaptiveImageSize", default: true)
    static let downscaleRetinaImages = Key<Bool>("downscaleRetinaImages", default: false)
    static let copyImageFilePath = Key<Bool>("copyImageFilePath", default: true)
    static let useCustomNameTemplateForClipboardImages = Key<Bool>("useCustomNameTemplateForClipboardImages", default: false)
    static let customNameTemplateForClipboardImages = Key<String>("customNameTemplateForClipboardImages", default: "")
    static let lastAutoIncrementingNumber = Key<Int>("lastAutoIncrementingNumber", default: 0)

    static let showFloatingHatIcon = Key<Bool>("showFloatingHatIcon", default: true)
    static let enableDragAndDrop = Key<Bool>("enableDragAndDrop", default: true)
    static let showImages = Key<Bool>("showImages", default: true)
    static let autoHideFloatingResults = Key<Bool>("autoHideFloatingResults", default: true)
    static let autoHideFloatingResultsAfter = Key<Int>("autoHideFloatingResultsAfter", default: 30)
    static let autoHideClipboardResultAfter = Key<Int>("autoHideClipboardResultAfter", default: 3)
    static let floatingResultsCorner = Key<ScreenCorner>("floatingResultsCorner", default: .bottomRight)
    static let neverShowProError = Key<Bool>("neverShowProError", default: false)

    static let autoCopyToClipboard = Key<Bool>("autoCopyToClipboard", default: true)

    static let keyComboModifiers = Key<[TriggerKey]>("keyComboModifiers", default: [.lctrl, .lshift])
    static let quickResizeKeys = Key<[SauceKey]>("quickResizeKeys", default: [.five, .three])
    static let enabledKeys = Key<[SauceKey]>("enabledKeys", default: DEFAULT_GLOBAL_KEYS)

    static let syncSettingsCloud = Key<Bool>("syncSettingsCloud", default: true)
}

public enum ConvertedFileBehaviour: String, Defaults.Serializable {
    case temporary
    case inPlace
    case sameFolder
}

let SETTINGS_TO_SYNC: [Defaults._AnyKey] = [
    Defaults.Keys.showMenubarIcon,
    .enableFloatingResults,
    .optimiseTIFF,
    .enableClipboardOptimiser,
    .optimiseVideoClipboard,
    .optimiseImagePathClipboard,
    .stripMetadata,
    .formatsToConvertToJPEG,
    .formatsToConvertToPNG,
    .formatsToConvertToMP4,
    .convertedImageBehaviour,
    .convertedVideoBehaviour,
    .capVideoFPS,
    .targetVideoFPS,
    .minVideoFPS,
    .useAggresiveOptimisationMP4,
    .useAggresiveOptimisationJPEG,
    .useAggresiveOptimisationPNG,
    .useAggresiveOptimisationGIF,
    .useAggresiveOptimisationPDF,
    .videoDirs,
    .imageDirs,
    .pdfDirs,
    .maxVideoSizeMB,
    .maxImageSizeMB,
    .maxPDFSizeMB,
    .maxVideoFileCount,
    .maxImageFileCount,
    .maxPDFFileCount,
    .imageFormatsToSkip,
    .videoFormatsToSkip,
    .adaptiveVideoSize,
    .adaptiveImageSize,
    .downscaleRetinaImages,
    .showFloatingHatIcon,
    .enableDragAndDrop,
    .showImages,
    .autoHideFloatingResults,
    .autoHideFloatingResultsAfter,
    .autoHideClipboardResultAfter,
    .floatingResultsCorner,
    .neverShowProError,
    .autoCopyToClipboard,
    .keyComboModifiers,
    .quickResizeKeys,
    .enabledKeys,
    .copyImageFilePath,
    .useCustomNameTemplateForClipboardImages,
    .customNameTemplateForClipboardImages,
    .shortcutToRunOnImage,
    .shortcutToRunOnVideo,
    .shortcutToRunOnPdf,
] + ARM64_SPECIFIC_SETTINGS

#if arch(arm64)
    let ARM64_SPECIFIC_SETTINGS: [Defaults._AnyKey] = [Defaults.Keys.useCPUIntensiveEncoder]
#else
    let ARM64_SPECIFIC_SETTINGS: [Defaults._AnyKey] = []
#endif
