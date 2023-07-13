//
//  Settings.swift
//  Clop
//
//  Created by Alin Panaitiu on 13.07.2023.
//

import Defaults
import Foundation
import Lowtech
import System
import UniformTypeIdentifiers

extension SauceKey: Defaults.Serializable {}
extension UTType: Defaults.Serializable {}

extension UTType {
    static let avif = UTType("public.avif")!
    static let webm = UTType("org.webmproject.webm")!
    static let mkv = UTType("org.matroska.mkv")!
    static let mpeg = UTType("public.mpeg")!
    static let wmv = UTType("com.microsoft.windows-media-wmv")!
    static let flv = UTType("com.adobe.flash.video")!
    static let m4v = UTType("com.apple.m4v-video")!
}

let VIDEO_FORMATS: [UTType] = [.quickTimeMovie, .mpeg4Movie, .webm, .mkv, .mpeg2Video, .avi, .m4v, .mpeg]
let FORMATS_CONVERTIBLE_TO_MP4: [UTType] = VIDEO_FORMATS.without([.mpeg4Movie])

let IMAGE_FORMATS: [UTType] = [.webP, .avif, .heic, .bmp, .tiff, .png, .jpeg, .gif]
let FORMATS_CONVERTIBLE_TO_JPEG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])
let FORMATS_CONVERTIBLE_TO_PNG: [UTType] = IMAGE_FORMATS.without([.png, .jpeg, .gif])

let VIDEO_EXTENSIONS = VIDEO_FORMATS.compactMap(\.preferredFilenameExtension)
let IMAGE_EXTENSIONS = IMAGE_FORMATS.compactMap(\.preferredFilenameExtension) + ["jpg"]

public extension Defaults.Keys {
    static let showMenubarIcon = Key<Bool>("showMenubarIcon", default: true)
    static let enableFloatingResults = Key<Bool>("enableFloatingResults", default: true)
    static let optimizeTIFF = Key<Bool>("optimizeTIFF", default: true)
    static let formatsToConvertToJPEG = Key<Set<UTType>>("formatsToConvertToJPEG", default: [.webP, .avif, .heic, .bmp])
    static let formatsToConvertToPNG = Key<Set<UTType>>("formatsToConvertToPNG", default: [.tiff])
    static let formatsToConvertToMP4 = Key<Set<UTType>>("formatsToConvertToMP4", default: [.quickTimeMovie, .mpeg2Video, .mpeg, .webm])
    #if arch(arm64)
        static let useCPUIntensiveEncoder = Key<Bool>("useCPUIntensiveEncoder", default: false)
    #endif
    static let useAggresiveOptimizationMP4 = Key<Bool>("useAggresiveOptimizationMP4", default: false)
    static let useAggresiveOptimizationJPEG = Key<Bool>("useAggresiveOptimizationJPEG", default: false)
    static let useAggresiveOptimizationPNG = Key<Bool>("useAggresiveOptimizationPNG", default: false)
    static let useAggresiveOptimizationGIF = Key<Bool>("useAggresiveOptimizationGIF", default: false)

    static let videoDirs = Key<[String]>("videoDirs", default: [URL.desktopDirectory.path])
    static let imageDirs = Key<[String]>("imageDirs", default: [URL.desktopDirectory.path])

    static let maxVideoSizeMB = Key<Int>("maxVideoSizeMB", default: 500)
    static let maxImageSizeMB = Key<Int>("maxImageSizeMB", default: 50)
    static let imageFormatsToSkip = Key<Set<UTType>>("imageFormatsToSkip", default: [.tiff])
    static let videoFormatsToSkip = Key<Set<UTType>>("videoFormatsToSkip", default: [.mkv, .m4v])
    static let adaptiveVideoSize = Key<Bool>("adaptiveVideoSize", default: true)
    static let adaptiveImageSize = Key<Bool>("adaptiveVideoSize", default: true)

    static let showFloatingHatIcon = Key<Bool>("showFloatingHatIcon", default: true)
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
