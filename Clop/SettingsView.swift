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

extension String: Identifiable {
    public var id: String { self }
}

struct DirListView: View {
    @Binding var dirs: [String]
    @State var selectedDirs: Set<String> = []
    @State var chooseFile = false

    var body: some View {
        VStack(alignment: .leading) {
            Table(dirs, selection: $selectedDirs) {
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
                                dirs = (dirs + success.map(\.path)).uniqued
                            case let .failure(failure):
                                print(failure)
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

struct VideoSettingsView: View {
    @Default(.videoDirs) var videoDirs
    @Default(.formatsToConvertToMP4) var formatsToConvertToMP4
    @Default(.maxVideoSizeMB) var maxVideoSizeMB
    @Default(.videoFormatsToSkip) var videoFormatsToSkip
    @Default(.adaptiveVideoSize) var adaptiveVideoSize

    #if arch(arm64)
        @Default(.useCPUIntensiveEncoder) var useCPUIntensiveEncoder
    #endif
    @Default(.useAggresiveOptimizationMP4) var useAggresiveOptimizationMP4

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimize videos as they appear in these folders")) {
                DirListView(dirs: $videoDirs)
            }
            Section(header: SectionHeader(title: "Optimization rules")) {
                HStack {
                    Text("Skip videos larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxVideoSizeMB, formatter: BoundFormatter(min: 1, max: 10000))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text("MB").mono(13)
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
                        Text("Adaptive optimization").regular(13)
                            + Text("\nUses the CPU intensive encoder for short workloads, and the battery efficient one for larger files").round(11, weight: .regular)
                    }
                    Toggle(isOn: $useCPUIntensiveEncoder) {
                        Text("Use CPU intensive encoder").regular(13)
                            + Text("\nGenerates smaller files with better visual quality but takes longer and uses more CPU").round(11, weight: .regular)
                    }
                    Toggle(isOn: $useAggresiveOptimizationMP4) {
                        Text("Aggressive optimization").regular(13)
                            + Text("\nDecrease visual quality and increase processing time for even smaller files").round(11, weight: .regular)
                    }
                    .disabled(!useCPUIntensiveEncoder)
                    .padding(.leading)
                #else
                    Toggle(isOn: $useAggresiveOptimizationMP4) {
                        Text("Use more aggressive optimization").regular(13)
                            + Text("\nGenerates smaller files with slightly worse visual quality but takes longer and uses more CPU").round(11, weight: .regular)
                    }
                #endif
            }
            Section(header: SectionHeader(title: "Compatibility", subtitle: "Converts less known formats to more compatible ones before optimization")) {
                HStack {
                    (Text("Convert to ").regular(13) + Text("mp4").mono(13)).padding(.trailing, 10)
                    ForEach(FORMATS_CONVERTIBLE_TO_MP4, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToMP4.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToMP4.contains(format) }))
                    }
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

    @Default(.useAggresiveOptimizationJPEG) var useAggresiveOptimizationJPEG
    @Default(.useAggresiveOptimizationPNG) var useAggresiveOptimizationPNG
    @Default(.useAggresiveOptimizationGIF) var useAggresiveOptimizationGIF

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimize images as they appear in these folders")) {
                DirListView(dirs: $imageDirs)
            }
            Section(header: SectionHeader(title: "Optimization rules")) {
                HStack {
                    Text("Skip images larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxImageSizeMB, formatter: BoundFormatter(min: 1, max: 500))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1))
                    Text("MB").mono(13)
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
                    Text("Use more aggressive optimization for").regular(13).padding(.trailing, 10)
                    Button("jpeg") {
                        useAggresiveOptimizationJPEG.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggresiveOptimizationJPEG))
                    Button("png") {
                        useAggresiveOptimizationPNG.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggresiveOptimizationPNG))
                    Button("gif") {
                        useAggresiveOptimizationGIF.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggresiveOptimizationGIF))
                }
                Toggle(isOn: $adaptiveImageSize) {
                    Text("Adaptive optimization").regular(13)
                        + Text("\nOptimize detail heavy images as JPEG and low-detail ones as PNG").round(11, weight: .regular)
                }

            }
            Section(header: SectionHeader(title: "Compatibility", subtitle: "Converts less known formats to more compatible ones before optimization")) {
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
                keyToggle(.delete, actionName: "Stop and Remove", description: "Stop the last running action and remove the floating result")
                keyToggle(.equal, actionName: "Bring Back", description: "Bring back the last removed floating result")
                keyToggle(.space, actionName: "QuickLook", description: "Preview the latest image or video")
                keyToggle(.z, actionName: "Restore original", description: "Revert optimizations and downscaling actions done on the latest image or video")
                keyToggle(.p, actionName: "Pause for next copy", description: "Don't apply optimizations on the next copied image")
                keyToggle(.c, actionName: "Optimize current clipboard", description: "Apply optimizations on the copied image, URL or path")
                keyToggle(.a, actionName: "Optimize aggressively", description: "Apply aggressive optimizations on the copied image, URL or path")
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
    @Default(.optimizeTIFF) var optimizeTIFF

    var body: some View {
        Form {
            Toggle("Show menubar icon", isOn: $showMenubarIcon)
            LaunchAtLogin.Toggle()
            Section(header: SectionHeader(title: "Clipboard")) {
                Toggle("Optimize TIFF data", isOn: $optimizeTIFF)
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
        case general, advanced, video, images, floating, keys, about

        var next: Tabs {
            switch self {
            case .general:
                return .video
            case .video:
                return .images
            case .images:
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
            case .floating:
                return .images
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
            settingsViewManager.tab = .floating
        case .five:
            settingsViewManager.tab = .keys
        case .six:
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
