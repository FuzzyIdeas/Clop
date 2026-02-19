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

extension UTType: Defaults.Serializable {}

let FORMATS_CONVERTIBLE_TO_MP4: [UTType] = VIDEO_FORMATS.without([.mpeg4Movie])
let FORMATS_CONVERTIBLE_TO_JPEG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])
let FORMATS_CONVERTIBLE_TO_PNG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])

let VIDEO_EXTENSIONS = VIDEO_FORMATS.compactMap(\.preferredFilenameExtension)
let IMAGE_EXTENSIONS = IMAGE_FORMATS.compactMap(\.preferredFilenameExtension) + ["jpg"]

let VIDEO_PASTEBOARD_TYPES = VIDEO_FORMATS.compactMap { NSPasteboard.PasteboardType(rawValue: $0.identifier) }
let IMAGE_PASTEBOARD_TYPES = IMAGE_FORMATS.compactMap { NSPasteboard.PasteboardType(rawValue: $0.identifier) }
let IMAGE_VIDEO_PASTEBOARD_TYPES: Set<NSPasteboard.PasteboardType> = (IMAGE_PASTEBOARD_TYPES + VIDEO_PASTEBOARD_TYPES + [.fileContents]).set

let DEFAULT_HOVER_KEYS: [SauceKey] = [.minus, .delete, .space, .z, .c, .a, .s, .x, .r, .f, .o, .comma, .u, .d]
let DEFAULT_GLOBAL_KEYS: [SauceKey] = [.minus, .equal, .delete, .space, .z, .p, .c, .a, .x, .r, .escape]

enum CleanupInterval: TimeInterval, Codable, Defaults.Serializable {
    case every10Minutes = 600
    case hourly = 3600
    case every12Hours = 43200
    case daily = 86400
    case every3Days = 259_200
    case weekly = 604_800
    case monthly = 2_592_000
    case never = 0

    var title: String {
        switch self {
        case .every10Minutes: "10 minutes"
        case .hourly: "1 hour"
        case .every12Hours: "12 hours"
        case .daily: "1 day"
        case .every3Days: "3 days"
        case .weekly: "1 week"
        case .monthly: "1 month"
        case .never: "Never"
        }
    }
}

extension CropOrientation: Defaults.Serializable {}

extension Defaults.Keys {
    static let finishedOnboarding = Key<Bool>("finishedOnboarding", default: false)
    static let showMenubarIcon = Key<Bool>("showMenubarIcon", default: true)
    static let enableFloatingResults = Key<Bool>("enableFloatingResults", default: true)
    static let alwaysShowCompactResults = Key<Bool>("alwaysShowCompactResults", default: false)

    static let optimiseTIFF = Key<Bool>("optimiseTIFF", default: true)
    static let enableClipboardOptimiser = Key<Bool>("enableClipboardOptimiser", default: true)
    static let optimiseVideoClipboard = Key<Bool>("optimiseVideoClipboard", default: false)
    static let optimiseImagePathClipboard = Key<Bool>("optimiseImagePathClipboard", default: false)
    static let stripMetadata = Key<Bool>("stripMetadata", default: true)
    static let preserveDates = Key<Bool>("preserveDates", default: true)
    static let preserveColorMetadata = Key<Bool>("preserveColorMetadata", default: true)

    static let workdir = Key<String>("workdir", default: URL.cachesDirectory.appendingPathComponent("Clop", conformingTo: .directory).path)
    static let workdirCleanupInterval = Key<CleanupInterval>("workdirCleanupInterval", default: .every3Days)

    static let formatsToConvertToJPEG = Key<Set<UTType>>("formatsToConvertToJPEG", default: [UTType.webP, UTType.avif, UTType.heic, UTType.bmp].compactMap { $0 }.set)
    static let formatsToConvertToPNG = Key<Set<UTType>>("formatsToConvertToPNG", default: [.tiff])
    static let formatsToConvertToMP4 = Key<Set<UTType>>("formatsToConvertToMP4", default: [UTType.quickTimeMovie, UTType.mpeg2Video, UTType.mpeg, UTType.webm].compactMap { $0 }.set)
    static let convertedImageBehaviour = Key<ConvertedFileBehaviour>("convertedImageBehaviour", default: .sameFolder)
    static let convertedVideoBehaviour = Key<ConvertedFileBehaviour>("convertedVideoBehaviour", default: .sameFolder)

    static let optimisedImageBehaviour = Key<OptimisedFileBehaviour>("optimisedImageBehaviour", default: .inPlace)
    static let optimisedVideoBehaviour = Key<OptimisedFileBehaviour>("optimisedVideoBehaviour", default: .inPlace)
    static let optimisedPDFBehaviour = Key<OptimisedFileBehaviour>("optimisedPDFBehaviour", default: .inPlace)
    static let sameFolderNameTemplateImage = Key<String>("sameFolderNameTemplateImage", default: DEFAULT_SAME_FOLDER_NAME_TEMPLATE)
    static let sameFolderNameTemplateVideo = Key<String>("sameFolderNameTemplateVideo", default: DEFAULT_SAME_FOLDER_NAME_TEMPLATE)
    static let sameFolderNameTemplatePDF = Key<String>("sameFolderNameTemplatePDF", default: DEFAULT_SAME_FOLDER_NAME_TEMPLATE)
    static let specificFolderNameTemplateImage = Key<String>("specificFolderNameTemplateImage", default: DEFAULT_SPECIFIC_FOLDER_NAME_TEMPLATE)
    static let specificFolderNameTemplateVideo = Key<String>("specificFolderNameTemplateVideo", default: DEFAULT_SPECIFIC_FOLDER_NAME_TEMPLATE)
    static let specificFolderNameTemplatePDF = Key<String>("specificFolderNameTemplatePDF", default: DEFAULT_SPECIFIC_FOLDER_NAME_TEMPLATE)
    static let optimisedFileProtectionMs = Key<Int>("optimisedFileProtectionMs", default: 3000)

    static let capVideoFPS = Key<Bool>("capVideoFPS", default: true)
    static let targetVideoFPS = Key<Float>("targetVideoFPS", default: 60)
    static let minVideoFPS = Key<Float>("minVideoFPS", default: 30)
    static let removeAudioFromVideos = Key<Bool>("removeAudioFromVideos", default: false)
    static let convertAudioToAAC = Key<Bool>("convertAudioToAAC", default: false)

    #if arch(arm64)
        static let useCPUIntensiveEncoder = Key<Bool>("useCPUIntensiveEncoder", default: false)
    #endif
    static let useAggressiveOptimisationMP4 = Key<Bool>("useAggressiveOptimisationMP4", default: false)
    static let useAggressiveOptimisationJPEG = Key<Bool>("useAggressiveOptimisationJPEG", default: false)
    static let useAggressiveOptimisationPNG = Key<Bool>("useAggressiveOptimisationPNG", default: false)
    static let useAggressiveOptimisationGIF = Key<Bool>("useAggressiveOptimisationGIF", default: false)
    static let useAggressiveOptimisationPDF = Key<Bool>("useAggressiveOptimisationPDF", default: true)

    static let imageDirs = Key<[String]>("imageDirs", default: [URL.desktopDirectory.path])
    static let videoDirs = Key<[String]>("videoDirs", default: [URL.desktopDirectory.path])
    static let pdfDirs = Key<[String]>("pdfDirs", default: [])
    static let enableAutomaticImageOptimisations = Key<Bool>("enableAutomaticImageOptimisations", default: true)
    static let enableAutomaticVideoOptimisations = Key<Bool>("enableAutomaticVideoOptimisations", default: true)
    static let enableAutomaticPDFOptimisations = Key<Bool>("enableAutomaticPDFOptimisations", default: true)

    static let maxVideoSizeMB = Key<Int>("maxVideoSizeMB", default: 500)
    static let maxImageSizeMB = Key<Int>("maxImageSizeMB", default: 50)
    static let maxPDFSizeMB = Key<Int>("maxPDFSizeMB", default: 100)
    static let maxVideoFileCount = Key<Int>("maxVideoFileCount", default: 1)
    static let maxImageFileCount = Key<Int>("maxImageFileCount", default: 4)
    static let maxPDFFileCount = Key<Int>("maxPDFFileCount", default: 2)
    static let imageFormatsToSkip = Key<Set<UTType>>("imageFormatsToSkip", default: [.tiff])
    static let videoFormatsToSkip = Key<Set<UTType>>("videoFormatsToSkip", default: [UTType.mkv, UTType.m4v].compactMap { $0 }.set)
    static let adaptiveVideoSize = Key<Bool>("adaptiveVideoSize", default: true)
    static let adaptiveImageSize = Key<Bool>("adaptiveImageSize", default: false)
    // static let downscaleRetinaImages = Key<Bool>("downscaleRetinaImages", default: false)
    static let copyImageFilePath = Key<Bool>("copyImageFilePath", default: true)
    static let enablePhotosIntegration = Key<Bool>("enablePhotosIntegration", default: true)
    static let maxCopiedPhotosCount = Key<Int>("maxCopiedPhotosCount", default: 5)
    static let maxPhotosLength = Key<Int?>("maxPhotosLength", default: nil)
    static let photoCropOrientation = Key<CropOrientation>("photoCropOrientation", default: CropOrientation.adaptive)
    static let useCustomNameTemplateForClipboardImages = Key<Bool>("useCustomNameTemplateForClipboardImages", default: false)
    static let customNameTemplateForClipboardImages = Key<String>("customNameTemplateForClipboardImages", default: "")
    static let lastAutoIncrementingNumber = Key<Int>("lastAutoIncrementingNumber", default: 0)

    static let showFloatingHatIcon = Key<Bool>("showFloatingHatIcon", default: true)
    static let enableDragAndDrop = Key<Bool>("enableDragAndDrop", default: true)
    static let onlyShowDropZoneOnOption = Key<Bool>("onlyShowDropZoneOnOption", default: false)
    static let onlyShowPresetZonesOnControlTapped = Key<Bool>("onlyShowPresetZonesOnControlTapped", default: false)
    static let showImages = Key<Bool>("showImages", default: true)
    static let showCompactImages = Key<Bool>("showCompactImages", default: false)
    static let autoHideFloatingResults = Key<Bool>("autoHideFloatingResults", default: true)
    static let autoHideFloatingResultsAfter = Key<Int>("autoHideFloatingResultsAfter", default: 30)
    static let autoHideClipboardResultAfter = Key<Int>("autoHideClipboardResultAfter", default: 10)
    static let autoClearAllCompactResultsAfter = Key<Int>("autoClearAllCompactResultsAfter", default: 120)
    static let floatingResultsCorner = Key<ScreenCorner>("floatingResultsCorner", default: .bottomRight)
    static let neverShowProError = Key<Bool>("neverShowProError", default: false)

    static let dismissFloatingResultOnDrop = Key<Bool>("dismissFloatingResultOnDrop", default: true)
    static let dismissFloatingResultOnUpload = Key<Bool>("dismissFloatingResultOnUpload", default: true)
    static let dismissCompactResultOnDrop = Key<Bool>("dismissCompactResultOnDrop", default: false)
    static let dismissCompactResultOnUpload = Key<Bool>("dismissCompactResultOnUpload", default: false)

    static let autoCopyToClipboard = Key<Bool>("autoCopyToClipboard", default: true)
    static let cliInstalled = Key<Bool>("cliInstalled", default: true)

    static let keyComboModifiers = Key<[TriggerKey]>("keyComboModifiers", default: [.lctrl, .lshift])
    static let quickResizeKeys = Key<[SauceKey]>("quickResizeKeys", default: [.five, .three])
    static let enabledKeys = Key<[SauceKey]>("enabledKeys", default: DEFAULT_GLOBAL_KEYS)

    static let savedCropSizes = Key<[CropSize]>("savedCropSizes", default: DEFAULT_CROP_SIZES)
    static let pauseAutomaticOptimisations = Key<Bool>("pauseAutomaticOptimisations", default: false)
    static let presetZones = Key<[PresetZone]>("presetZones", default: [])

    static let syncSettingsCloud = Key<Bool>("syncSettingsCloud", default: true)
    static let allowClopToAppearInScreenshots = Key<Bool>("allowClopToAppearInScreenshots", default: false)
}

let DEFAULT_CROP_SIZES: [CropSize] = [
    CropSize(width: 1920, height: 1080, name: "1080p"),
    CropSize(width: 1280, height: 720, name: "720p"),
    CropSize(width: 1440, height: 900, name: "Mac App Store"),
    CropSize(width: 1200, height: 630, name: "OpenGraph"),
    CropSize(width: 1600, height: 900, name: "Twitter"),
    CropSize(width: 128, height: 128, name: "Small Square"),
    CropSize(width: 512, height: 512, name: "Medium Square"),
    CropSize(width: 1024, height: 1024, name: "Large Square"),
]
let DEFAULT_CROP_ASPECT_RATIOS: [CropSize] = [
    CropSize(width: 16, height: 9, name: "16:9", isAspectRatio: true),
    CropSize(width: 4, height: 3, name: "4:3", isAspectRatio: true),
    CropSize(width: 5, height: 3, name: "5:3", isAspectRatio: true),
    CropSize(width: 5, height: 4, name: "5:4", isAspectRatio: true),
    CropSize(width: 1618, height: 1000, name: "φ:1", isAspectRatio: true),
    CropSize(width: 16, height: 10, name: "16:10", isAspectRatio: true),
    CropSize(width: 3, height: 2, name: "3:2", isAspectRatio: true),
    CropSize(width: 1, height: 1, name: "1:1", isAspectRatio: true),
    CropSize(width: 2, height: 1, name: "2:1", isAspectRatio: true),
    CropSize(width: 210, height: 297, name: "A4", isAspectRatio: true),
    CropSize(width: 154, height: 100, name: "1.54:1", isAspectRatio: true),
    CropSize(width: 6, height: 13, name: "6:13", isAspectRatio: true),
    CropSize(width: 14, height: 9, name: "14:9", isAspectRatio: true),
    CropSize(width: 32, height: 9, name: "32:9", isAspectRatio: true),
    CropSize(width: 176, height: 250, name: "B5", isAspectRatio: true),
]

public enum ConvertedFileBehaviour: String, Defaults.Serializable {
    case temporary
    case inPlace
    case sameFolder
}

public enum OptimisedFileBehaviour: String, Defaults.Serializable {
    case temporary
    case inPlace
    case sameFolder
    case specificFolder
}

let SETTINGS_TO_SYNC: [Defaults._AnyKey] = [
    Defaults.Keys.showMenubarIcon,
    .adaptiveImageSize,
    .adaptiveVideoSize,
    .alwaysShowCompactResults,
    .autoClearAllCompactResultsAfter,
    .autoCopyToClipboard,
    .autoHideClipboardResultAfter,
    .autoHideFloatingResults,
    .autoHideFloatingResultsAfter,
    .capVideoFPS,
    .convertedImageBehaviour,
    .convertedVideoBehaviour,
    .copyImageFilePath,
    .customNameTemplateForClipboardImages,
    .dismissCompactResultOnDrop,
    .dismissFloatingResultOnDrop,
    // .downscaleRetinaImages,
    .enableClipboardOptimiser,
    .enabledKeys,
    .enableDragAndDrop,
    .onlyShowDropZoneOnOption,
    .onlyShowPresetZonesOnControlTapped,
    .enableFloatingResults,
    .floatingResultsCorner,
    .formatsToConvertToJPEG,
    .formatsToConvertToMP4,
    .formatsToConvertToPNG,
    .imageDirs,
    .imageFormatsToSkip,
    .keyComboModifiers,
    .enablePhotosIntegration,
    .maxImageFileCount,
    .maxImageSizeMB,
    .maxCopiedPhotosCount,
    .maxPhotosLength,
    .maxPDFFileCount,
    .maxPDFSizeMB,
    .maxVideoFileCount,
    .maxVideoSizeMB,
    .minVideoFPS,
    .removeAudioFromVideos,
    .convertAudioToAAC,
    .optimisedImageBehaviour,
    .optimisedVideoBehaviour,
    .optimisedPDFBehaviour,
    .sameFolderNameTemplateImage,
    .sameFolderNameTemplateVideo,
    .sameFolderNameTemplatePDF,
    .specificFolderNameTemplateImage,
    .specificFolderNameTemplateVideo,
    .specificFolderNameTemplatePDF,
    .optimiseImagePathClipboard,
    .optimiseTIFF,
    .optimiseVideoClipboard,
    .optimisedFileProtectionMs,
    .pdfDirs,
    .preserveDates,
    .preserveColorMetadata,
    .presetZones,
    .quickResizeKeys,
    .savedCropSizes,
    .shortcutToRunOnImage,
    .shortcutToRunOnVideo,
    .shortcutToRunOnPdf,
    .showCompactImages,
    .showFloatingHatIcon,
    .showImages,
    .stripMetadata,
    .targetVideoFPS,
    .useAggressiveOptimisationGIF,
    .useAggressiveOptimisationJPEG,
    .useAggressiveOptimisationMP4,
    .useAggressiveOptimisationPDF,
    .useAggressiveOptimisationPNG,
    .useCustomNameTemplateForClipboardImages,
    .videoDirs,
    .videoFormatsToSkip,
] + ARM64_SPECIFIC_SETTINGS

#if arch(arm64)
    let ARM64_SPECIFIC_SETTINGS: [Defaults._AnyKey] = [Defaults.Keys.useCPUIntensiveEncoder]
#else
    let ARM64_SPECIFIC_SETTINGS: [Defaults._AnyKey] = []
#endif
