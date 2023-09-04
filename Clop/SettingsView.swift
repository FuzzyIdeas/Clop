//
//  SettingsView.swift
//  Clop
//
//  Created by Alin Panaitiu on 10.07.2023.
//

import Defaults
import Foundation
import LaunchAtLogin
import Lowtech
import SwiftUI
import System

extension String: Identifiable {
    public var id: String { self }
}

let NOT_ALLOWED_TO_WATCH = [FilePath.backups.string, FilePath.images.string, FilePath.videos.string, FilePath.forResize.string, FilePath.conversions.string, FilePath.downloads.string]

struct DirListView: View {
    @Binding var dirs: [String]
    @State var selectedDirs: Set<String> = []
    @State var chooseFile = false

    var body: some View {
        VStack(alignment: .leading) {
            Table(dirs.sorted(), selection: $selectedDirs) {
                TableColumn("Path", content: { dir in Text(dir.replacingOccurrences(of: HOME.string, with: "~")).mono(12) })
            }

            HStack(spacing: 2) {
                Button(action: { chooseFile = true }, label: { SwiftUI.Image(systemName: "plus").font(.bold(12)) })
                    .fileImporter(
                        isPresented: $chooseFile,
                        allowedContentTypes: [.directory],
                        allowsMultipleSelection: true,
                        onCompletion: { result in
                            switch result {
                            case let .success(success):
                                dirs = (dirs + success.map(\.path)).uniqued.without(NOT_ALLOWED_TO_WATCH)
                            case let .failure(failure):
                                log.error(failure.localizedDescription)
                            }
                        }
                    )

                Button(
                    action: { dirs = Set(dirs).without(selectedDirs) },
                    label: { SwiftUI.Image(systemName: "minus").font(.bold(12)) }
                )
                .disabled(selectedDirs.isEmpty)
            }
        }
        .padding(4)
        .frame(minHeight: 150)
    }
}

struct PDFSettingsView: View {
    @Default(.pdfDirs) var pdfDirs
    @Default(.maxPDFSizeMB) var maxPDFSizeMB
    @Default(.maxPDFFileCount) var maxPDFFileCount
    @Default(.useAggresiveOptimisationPDF) var useAggresiveOptimisationPDF

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise PDFs as they appear in these folders")) {
                DirListView(dirs: $pdfDirs)
            }
            Section(header: SectionHeader(title: "Optimisation rules")) {
                HStack {
                    Text("Skip PDFs larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxPDFSizeMB, formatter: BoundFormatter(min: 1, max: 10000))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text("MB").mono(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxPDFFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text(maxPDFFileCount == 1 ? "PDF is dropped" : "PDFs are dropped").regular(13)
                }

                Toggle(isOn: $useAggresiveOptimisationPDF) {
                    Text("Use more aggressive optimisation").regular(13)
                        + Text("\nGenerates smaller files with slightly worse visual quality").round(11, weight: .regular)
                }
            }
        }.padding(4)
    }
}

struct VideoSettingsView: View {
    @Default(.videoDirs) var videoDirs
    @Default(.formatsToConvertToMP4) var formatsToConvertToMP4
    @Default(.maxVideoSizeMB) var maxVideoSizeMB
    @Default(.videoFormatsToSkip) var videoFormatsToSkip
    @Default(.adaptiveVideoSize) var adaptiveVideoSize
    @Default(.capVideoFPS) var capVideoFPS
    @Default(.targetVideoFPS) var targetVideoFPS
    @Default(.minVideoFPS) var minVideoFPS
    @Default(.convertedVideoBehaviour) var convertedVideoBehaviour
    @Default(.maxVideoFileCount) var maxVideoFileCount

    #if arch(arm64)
        @Default(.useCPUIntensiveEncoder) var useCPUIntensiveEncoder
    #endif
    @Default(.useAggresiveOptimisationMP4) var useAggresiveOptimisationMP4

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise videos as they appear in these folders")) {
                DirListView(dirs: $videoDirs)
            }
            Section(header: SectionHeader(title: "Optimisation rules")) {
                HStack {
                    Text("Skip videos larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxVideoSizeMB, formatter: BoundFormatter(min: 1, max: 10000))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text("MB").mono(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxVideoFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text(maxVideoFileCount == 1 ? "video is dropped" : "videos are dropped").regular(13)
                }
                HStack {
                    Text("Ignore videos with extension").regular(13).padding(.trailing, 10)
                    ForEach(VIDEO_FORMATS, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            videoFormatsToSkip.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { videoFormatsToSkip.contains(format) }))
                    }
                }
                #if arch(arm64)
                    Toggle(isOn: $adaptiveVideoSize) {
                        Text("Adaptive optimisation").regular(13)
                            + Text("\nUses the CPU intensive encoder for short workloads, and the battery efficient one for larger files").round(11, weight: .regular)
                    }
                    Toggle(isOn: $useCPUIntensiveEncoder.animation(.spring())) {
                        Text("Use CPU intensive encoder").regular(13)
                            + Text("\nGenerates smaller files with better visual quality but takes longer and uses more CPU").round(11, weight: .regular)
                    }
                    if useCPUIntensiveEncoder {
                        Toggle(isOn: $useAggresiveOptimisationMP4) {
                            Text("Aggressive optimisation").regular(13)
                                + Text("\nDecrease visual quality and increase processing time for even smaller files").round(11, weight: .regular)
                        }
                        .disabled(!useCPUIntensiveEncoder)
                        .padding(.leading)
                    }
                #else
                    Toggle(isOn: $useAggresiveOptimisationMP4) {
                        Text("Use more aggressive optimisation").regular(13)
                            + Text("\nGenerates smaller files with slightly worse visual quality but takes longer and uses more CPU").round(11, weight: .regular)
                    }
                #endif
                Toggle(isOn: $capVideoFPS.animation(.spring())) {
                    HStack {
                        Text("Cap frames per second to").regular(13).padding(.trailing, 10)
                        Button("30fps") {
                            withAnimation(.spring()) { targetVideoFPS = 30 }
                        }.buttonStyle(ToggleButton(isOn: .oneway { targetVideoFPS == 30 }))
                        Button("60fps") {
                            withAnimation(.spring()) { targetVideoFPS = 60 }
                        }.buttonStyle(ToggleButton(isOn: .oneway { targetVideoFPS == 60 }))
                        Button("1/2 of source") {
                            withAnimation(.spring()) { targetVideoFPS = -2 }
                        }.buttonStyle(ToggleButton(isOn: .oneway { targetVideoFPS == -2 }))
                        Button("1/4 of source") {
                            withAnimation(.spring()) { targetVideoFPS = -4 }
                        }.buttonStyle(ToggleButton(isOn: .oneway { targetVideoFPS == -4 }))
                    }.disabled(!capVideoFPS)
                }
                if targetVideoFPS < 0, capVideoFPS {
                    HStack {
                        Text("but no less than").regular(13).padding(.trailing, 10)
                        Button("10fps") {
                            minVideoFPS = 10
                        }.buttonStyle(ToggleButton(isOn: .oneway { minVideoFPS == 10 }))
                        Button("24fps") {
                            minVideoFPS = 24
                        }.buttonStyle(ToggleButton(isOn: .oneway { minVideoFPS == 24 }))
                        Button("30fps") {
                            minVideoFPS = 30
                        }.buttonStyle(ToggleButton(isOn: .oneway { minVideoFPS == 30 }))
                        Button("60fps") {
                            minVideoFPS = 60
                        }.buttonStyle(ToggleButton(isOn: .oneway { minVideoFPS == 60 }))
                    }
                    .padding(.leading, 10)
                }

            }
            Section(header: SectionHeader(title: "Compatibility", subtitle: "Converts less known formats to more compatible ones before optimisation")) {
                HStack {
                    (Text("Convert to ").regular(13) + Text("mp4").mono(13)).padding(.trailing, 10)
                    ForEach(FORMATS_CONVERTIBLE_TO_MP4, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToMP4.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToMP4.contains(format) }))
                    }
                }
                HStack {
                    Text("Converted video location").regular(13).padding(.trailing, 10)
                    Button("Temporary folder") {
                        convertedVideoBehaviour = .temporary
                    }.buttonStyle(ToggleButton(isOn: .oneway { convertedVideoBehaviour == .temporary }))
                    Button("In-place (replace original)") {
                        convertedVideoBehaviour = .inPlace
                    }.buttonStyle(ToggleButton(isOn: .oneway { convertedVideoBehaviour == .inPlace }))
                    Button("Same folder (as original)") {
                        convertedVideoBehaviour = .sameFolder
                    }.buttonStyle(ToggleButton(isOn: .oneway { convertedVideoBehaviour == .sameFolder }))
                }
            }
        }.padding(4)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        Text(title).round(15, weight: .semibold)
            + (subtitle.map { Text("\n\($0)").font(.caption) } ?? Text(""))
    }
}

struct ImagesSettingsView: View {
    @Default(.imageDirs) var imageDirs
    @Default(.formatsToConvertToJPEG) var formatsToConvertToJPEG
    @Default(.formatsToConvertToPNG) var formatsToConvertToPNG
    @Default(.maxImageSizeMB) var maxImageSizeMB
    @Default(.imageFormatsToSkip) var imageFormatsToSkip
    @Default(.adaptiveImageSize) var adaptiveImageSize
    @Default(.downscaleRetinaImages) var downscaleRetinaImages
    @Default(.convertedImageBehaviour) var convertedImageBehaviour
    @Default(.maxImageFileCount) var maxImageFileCount
    @Default(.copyImageFilePath) var copyImageFilePath

    @Default(.useAggresiveOptimisationJPEG) var useAggresiveOptimisationJPEG
    @Default(.useAggresiveOptimisationPNG) var useAggresiveOptimisationPNG
    @Default(.useAggresiveOptimisationGIF) var useAggresiveOptimisationGIF

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise images as they appear in these folders")) {
                DirListView(dirs: $imageDirs)
            }
            Toggle(isOn: $copyImageFilePath) {
                Text("Copy image paths").regular(13)
                    + Text("\nWhen copying optimised image data, also copy the path of the image file").round(11, weight: .regular)
            }

            Section(header: SectionHeader(title: "Optimisation rules")) {
                HStack {
                    Text("Skip images larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxImageSizeMB, formatter: BoundFormatter(min: 1, max: 500))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text("MB").mono(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxImageFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text(maxImageFileCount == 1 ? "image is dropped" : "images are dropped").regular(13)
                }

                HStack {
                    Text("Ignore images with extension").regular(13).padding(.trailing, 10)
                    ForEach(IMAGE_FORMATS, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            imageFormatsToSkip.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { imageFormatsToSkip.contains(format) }))
                    }
                }
                HStack {
                    Text("Use more aggressive optimisation for").regular(13).padding(.trailing, 10)
                    Button("jpeg") {
                        useAggresiveOptimisationJPEG.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggresiveOptimisationJPEG))
                    Button("png") {
                        useAggresiveOptimisationPNG.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggresiveOptimisationPNG))
                    Button("gif") {
                        useAggresiveOptimisationGIF.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggresiveOptimisationGIF))
                }
                Toggle(isOn: $adaptiveImageSize) {
                    Text("Adaptive optimisation").regular(13)
                        + Text("\nOptimise detail heavy images as JPEG and low-detail ones as PNG").round(11, weight: .regular)
                }
                Toggle(isOn: $downscaleRetinaImages) {
                    Text("Downscale HiDPI images to 72 DPI").regular(13)
                        + Text("\nScales down images taken on HiDPI screens to the standard DPI for web (e.g. Retina to 1x)").round(11, weight: .regular)
                }

            }
            Section(header: SectionHeader(title: "Compatibility", subtitle: "Converts less known formats to more compatible ones before optimisation")) {
                HStack {
                    (Text("Convert to ").regular(13) + Text("jpeg").mono(13)).padding(.trailing, 10)
                    ForEach(FORMATS_CONVERTIBLE_TO_JPEG, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToJPEG.toggle(format)
                            if formatsToConvertToJPEG.contains(format) {
                                formatsToConvertToPNG.remove(format)
                            }
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToJPEG.contains(format) }))
                    }
                }
                HStack {
                    (Text("Convert to ").regular(13) + Text("png").mono(13)).padding(.trailing, 10)
                    ForEach(FORMATS_CONVERTIBLE_TO_PNG, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToPNG.toggle(format)
                            if formatsToConvertToPNG.contains(format) {
                                formatsToConvertToJPEG.remove(format)
                            }
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToPNG.contains(format) }))
                    }
                }
                HStack {
                    Text("Converted image location").regular(13).padding(.trailing, 10)
                    Button("Temporary folder") {
                        convertedImageBehaviour = .temporary
                    }.buttonStyle(ToggleButton(isOn: .oneway { convertedImageBehaviour == .temporary }))
                    Button("In-place (replace original)") {
                        convertedImageBehaviour = .inPlace
                    }.buttonStyle(ToggleButton(isOn: .oneway { convertedImageBehaviour == .inPlace }))
                    Button("Same folder (as original)") {
                        convertedImageBehaviour = .sameFolder
                    }.buttonStyle(ToggleButton(isOn: .oneway { convertedImageBehaviour == .sameFolder }))
                }

            }

        }.padding(4)
    }
}

class BoundFormatter: Formatter {
    init(min: Int, max: Int) {
        self.max = max
        self.min = min
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    var min = 0
    var max = 0

    override func string(for obj: Any?) -> String? {
        guard let number = obj as? Int else {
            return nil
        }
        return String(number.capped(between: min, and: max))

    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard let number = Int(string) else {
            return false
        }

        obj?.pointee = number.capped(between: min, and: max) as AnyObject

        return true
    }
}

let RESIZE_KEYS = SauceKey.NUMBER_KEYS.suffix(from: 1).arr

let keyEnv = EnvState()
struct KeysSettingsView: View {
    @Default(.enabledKeys) var enabledKeys
    @Default(.quickResizeKeys) var quickResizeKeys
    @Default(.keyComboModifiers) var keyComboModifiers

    var resizeKeys: some View {
        ForEach(RESIZE_KEYS, id: \.QWERTYKeyCode) { key in
            let number = key.character
            VStack(spacing: 1) {
                Button(number) {
                    quickResizeKeys = quickResizeKeys.contains(key)
                        ? quickResizeKeys.without(key)
                        : quickResizeKeys.with(key)
                }
                .buttonStyle(
                    ToggleButton(isOn: .oneway { quickResizeKeys.contains(key) })
                )
                Text("\(number)0%")
                    .mono(10)
                    .foregroundColor(.secondary)
            }
        }
    }

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Trigger keys")) {
                HStack {
                    DirectionalModifierView(triggerKeys: $keyComboModifiers, disabled: .false)
                    Text(" + ")
                }
            }
            Section(header: SectionHeader(title: "Action keys")) {
                keyToggle(.minus, actionName: "Downscale", description: "Decrease resolution of the last image or video")
                keyToggle(.x, actionName: "Speed up video", description: "Make video playback faster by dropping frames")
                keyToggle(.delete, actionName: "Stop and Remove", description: "Stop the last running action and remove the floating result")
                keyToggle(.equal, actionName: "Bring Back", description: "Bring back the last removed floating result")
                keyToggle(.space, actionName: "QuickLook", description: "Preview the latest image or video")
                keyToggle(.z, actionName: "Restore original", description: "Revert optimisations and downscaling actions done on the latest image or video")
                keyToggle(.p, actionName: "Pause for next copy", description: "Don't apply optimisations on the next copied image")
                keyToggle(.c, actionName: "Optimise current clipboard", description: "Apply optimisations on the copied image, URL or path")
                keyToggle(.a, actionName: "Optimise aggressively", description: "Apply aggressive optimisations on the copied image, URL or path")
            }.padding(.leading, 20)
            Section(header: SectionHeader(title: "Resize keys")) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Press number key").round(12, weight: .regular)
                        Text("to downscale to").mono(10).foregroundColor(.secondary)
                    }
                    resizeKeys
                }.fixedSize()
            }.padding(.leading, 20)
        }
        .frame(maxWidth: .infinity)
        .environmentObject(keyEnv)
    }

    @ViewBuilder
    func keyToggle(_ key: SauceKey, actionName: String, description: String) -> some View {
        let binding = Binding(
            get: { enabledKeys.contains(key) },
            set: { enabledKeys = $0 ? enabledKeys.with(key) : enabledKeys.without(key) }
        )
        Toggle(isOn: binding, label: {
            HStack {
                DynamicKey(key: .constant(key))
                    .font(.mono(15, weight: SauceKey.ALPHANUMERIC_KEYS.contains(key) ? .medium : .heavy))
                VStack(alignment: .leading, spacing: -1) {
                    Text(actionName)
                    Text(description).mono(10)
                }
            }
        })
    }

}
import LowtechIndie
import LowtechPro
struct MadeBy: View {
    var body: some View {
        HStack(spacing: 6) {
            SwiftUI.Image("lowtech")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .opacity(0.7)
            Text("by")
            Link("The low-tech guys", destination: "https://lowtechguys.com/".url!)
                .bold()
                .foregroundColor(.primary)
                .underline()
        }
        .font(.mono(12, weight: .regular))
        .kerning(-0.5)
    }
}

struct AboutSettingsView: View {
    @ObservedObject var um: UpdateManager = UM
    @ObservedObject var pm: ProManager = PM

    @Default(.enableSentry) var enableSentry

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                SwiftUI.Image("clop")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                Text((PRO?.active ?? false) ? "Pro" : "")
                    .font(.mono(16, weight: .semibold))
                    .foregroundColor(.hotRed)
                    .offset(x: 5, y: 14)
            }
            Text("Clop")
                .font(.round(64, weight: .black))
                .padding(.top, -30)
            Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "v2")
                .font(.mono(16, weight: .regular))
                .foregroundColor(.secondary)

            if let updater = um.updater {
                VersionView(updater: updater)
                    .frame(width: 340)
            }
            if let pro = PM.pro {
                LicenseView(pro: pro)
                    .frame(width: 340)
            }
            Toggle("Send error reports to developer", isOn: $enableSentry)
                .frame(width: 340)
            HStack {
                Link("Source code", destination: "https://github.com/FuzzyIdeas/Clop".url!)
            }
            .underline()
            .opacity(0.7)
        }
        .padding(10)
        .fill()
    }
}

struct FloatingSettingsView: View {
    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.showImages) var showImages
    @Default(.autoHideFloatingResults) var autoHideFloatingResults
    @Default(.autoHideFloatingResultsAfter) var autoHideFloatingResultsAfter
    @Default(.autoHideClipboardResultAfter) var autoHideClipboardResultAfter
    @Default(.floatingResultsCorner) var floatingResultsCorner

    var settings: some View {
        Form {
            Section(header: SectionHeader(title: "Layout")) {
                Toggle("Show hat icon", isOn: $showFloatingHatIcon)
                Toggle("Show images", isOn: $showImages)
                Picker("Position on screen", selection: $floatingResultsCorner) {
                    Text("Bottom right").tag(ScreenCorner.bottomRight)
                    Text("Bottom left").tag(ScreenCorner.bottomLeft)
                    Text("Top right").tag(ScreenCorner.topRight)
                    Text("Top left").tag(ScreenCorner.topLeft)
                }
            }
            Section(header: SectionHeader(title: "Behaviour")) {
                Toggle("Auto hide", isOn: $autoHideFloatingResults)
                Picker("files after", selection: $autoHideFloatingResultsAfter) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("never").tag(0)
                }.disabled(!autoHideFloatingResults).padding(.leading, 20)
                Picker("clipboard after", selection: $autoHideClipboardResultAfter) {
                    Text("1 seconds").tag(1)
                    Text("2 seconds").tag(2)
                    Text("3 seconds").tag(3)
                    Text("4 seconds").tag(4)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("same as non-clipboard").tag(-1)
                    Text("never").tag(0)
                }.disabled(!autoHideFloatingResults).padding(.leading, 20)
            }
        }
        .frame(maxWidth: 380).fixedSize()
    }
    var body: some View {
        VStack {
            HStack(alignment: .top) {
                settings

                FloatingPreview()
            }
        }
        .padding()
        .hfill()
    }
}
struct GeneralSettingsView: View {
    @Default(.showMenubarIcon) var showMenubarIcon
    @Default(.optimiseTIFF) var optimiseTIFF
    @Default(.optimiseVideoClipboard) var optimiseVideoClipboard
    @Default(.optimiseImagePathClipboard) var optimiseImagePathClipboard
    @Default(.enableClipboardOptimiser) var enableClipboardOptimiser
    @Default(.autoCopyToClipboard) var autoCopyToClipboard
    @Default(.enableDragAndDrop) var enableDragAndDrop
    @Default(.stripMetadata) var stripMetadata
    @Default(.syncSettingsCloud) var syncSettingsCloud

    var body: some View {
        Form {
            Toggle("Show menubar icon", isOn: $showMenubarIcon)
            LaunchAtLogin.Toggle()
            Toggle("Sync settings with other Macs via iCloud", isOn: $syncSettingsCloud)
            Section(header: SectionHeader(title: "Clipboard")) {
                Toggle(isOn: $enableClipboardOptimiser) {
                    Text("Enable clipboard optimiser").regular(13)
                        + Text("\nWatch for copied images and optimise them automatically").round(11, weight: .regular)
                }
                Toggle(isOn: $optimiseTIFF) {
                    Text("Optimise copied TIFF data").regular(13)
                        + Text("\nUsually coming from graphical design apps, it's sometimes better to not optimise it").round(11, weight: .regular)
                }.disabled(!enableClipboardOptimiser)
                Toggle(isOn: $optimiseVideoClipboard) {
                    Text("Optimise copied video files").regular(13)
                        + Text("\nSystem pasteboard can't hold video data, only video file paths. This option automatically optimises copied paths").round(11, weight: .regular)
                }.disabled(!enableClipboardOptimiser)
                Toggle(isOn: $optimiseImagePathClipboard) {
                    Text("Optimise copied image files").regular(13)
                        + Text("\nCopying images from Finder results in file paths instead of image data. This option automatically optimises copied paths").round(11, weight: .regular)
                }.disabled(!enableClipboardOptimiser)
            }
            Section(header: SectionHeader(title: "Integrations")) {
                Toggle(isOn: $enableDragAndDrop) {
                    Text("Enable drop zone").regular(13)
                        + Text("\nAllows dragging files, paths and URLs to a global drop zone for optimisation").round(11, weight: .regular)
                }
                Toggle(isOn: $autoCopyToClipboard) {
                    Text("Auto Copy files to clipboard").regular(13)
                        + Text("\nCopy files resulting from drop zone or file watch optimisation so they can be pasted right after optimisation ends").round(11, weight: .regular)
                }
            }
            Section(header: SectionHeader(title: "Optimisation")) {
                Toggle(isOn: $stripMetadata) {
                    Text("Strip EXIF Metadata").regular(13)
                        + Text("\nDeleted identifiable metadata from files (e.g. camera that took the photo, location, date and time etc.)").round(11, weight: .regular)
                }
            }
        }
        .padding(.horizontal, 50)
        .padding(.vertical, 20)
    }
}

class SettingsViewManager: ObservableObject {
    @Published var tab: SettingsView.Tabs = SWIFTUI_PREVIEW ? .about : .general
}

let settingsViewManager = SettingsViewManager()

struct SettingsView: View {
    enum Tabs: Hashable {
        case general, advanced, video, images, floating, keys, about, pdf

        var next: Tabs {
            switch self {
            case .general:
                return .video
            case .video:
                return .images
            case .images:
                return .pdf
            case .pdf:
                return .floating
            case .floating:
                return .keys
            case .keys:
                return .about
            default:
                return self
            }
        }

        var previous: Tabs {
            switch self {
            case .video:
                return .general
            case .images:
                return .video
            case .pdf:
                return .images
            case .floating:
                return .pdf
            case .keys:
                return .floating
            case .about:
                return .keys
            default:
                return self
            }
        }

    }

    @ObservedObject var svm = settingsViewManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $svm.tab) {
                GeneralSettingsView()
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }
                    .tag(Tabs.general)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VideoSettingsView()
                    .tabItem {
                        Label("Video", systemImage: "video")
                    }
                    .tag(Tabs.video)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ImagesSettingsView()
                    .tabItem {
                        Label("Images", systemImage: "photo")
                    }
                    .tag(Tabs.images)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                PDFSettingsView()
                    .tabItem {
                        Label("PDF", systemImage: "doc")
                    }
                    .tag(Tabs.pdf)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                FloatingSettingsView()
                    .tabItem {
                        Label("Floating results", systemImage: "square.stack")
                    }
                    .tag(Tabs.floating)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                KeysSettingsView()
                    .tabItem {
                        Label("Keyboard shortcuts", systemImage: "command.square")
                    }
                    .tag(Tabs.keys)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                AboutSettingsView()
                    .tabItem {
                        Label("About", systemImage: "info.circle")
                    }
                    .tag(Tabs.about)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, 20)
            .onAppear {
                tabKeyMonitor.start()
            }
            .onDisappear {
                tabKeyMonitor.stop()
            }

            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent)
                .offset(x: -10, y: -15)
            if svm.tab == .about {
                MadeBy().fill(.bottomTrailing).offset(x: -6, y: 0)
            }
        }
        .formStyle(.grouped)
    }

}

@MainActor var tabKeyMonitor = LocalEventMonitor(mask: .keyDown) { event in
    guard let combo = event.keyCombo else { return event }

    if combo.modifierFlags == [.command, .shift] {
        switch combo.key {
        case .leftBracket:
            settingsViewManager.tab = settingsViewManager.tab.previous
        case .rightBracket:
            settingsViewManager.tab = settingsViewManager.tab.next
        default:
            return event
        }
        return nil
    }

    if combo.modifierFlags == [.command] {
        switch combo.key {
        case .one:
            settingsViewManager.tab = .general
        case .two:
            settingsViewManager.tab = .video
        case .three:
            settingsViewManager.tab = .images
        case .four:
            settingsViewManager.tab = .pdf
        case .five:
            settingsViewManager.tab = .floating
        case .six:
            settingsViewManager.tab = .keys
        case .seven:
            settingsViewManager.tab = .about
        default:
            return event
        }
        return nil
    }
    return event
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(minWidth: 850, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }
}
