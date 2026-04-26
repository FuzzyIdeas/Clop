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
import os
import SwiftUI
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "SettingsView")

let TEXT_FIELD_OFFSET: CGFloat = if #available(macOS 15.0, *) {
    4
} else {
    0
}
let TEXT_FIELD_SCALE: CGFloat = if #available(macOS 15.0, *) {
    1.1
} else {
    1.0
}
let TEXT_FIELD_WIDTH: CGFloat = 550

extension String: @retroactive Identifiable {
    public var id: String { self }
}

let NOT_ALLOWED_TO_WATCH = [FilePath.clopBackups.string, FilePath.images.string, FilePath.videos.string, FilePath.forResize.string, FilePath.conversions.string, FilePath.downloads.string]

import Combine

class TextDebounce: ObservableObject {
    init(for time: DispatchQueue.SchedulerTimeType.Stride) {
        $text
            .debounce(for: time, scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, value != debouncedText else {
                    return
                }
                DirListView.shouldSave = true
                debouncedText = value
            }
            .store(in: &subscriptions)
    }

    @Published var debouncedText = ""
    @Published var text = ""

    private var subscriptions = Set<AnyCancellable>()
}

struct DirListView: View {
    static var shouldSave = false

    var fileType: ClopFileType
    @StateObject var textDebounce = TextDebounce(for: .seconds(2))

    @Binding var dirs: [String]
    @Binding var enabled: Bool
    @State var selectedDirs: Set<String> = []
    @State var chooseFile = false
    @State var clopignoreHelpVisible = false
    var hideIgnoreRules = false

    @Default(.dirsHideFloatingResult) var dirsHideFloatingResult

    func showFloatingBinding(for dir: String) -> Binding<Bool> {
        Binding(
            get: { !dirsHideFloatingResult.contains(dir) },
            set: { show in
                if show {
                    dirsHideFloatingResult.remove(dir)
                } else {
                    dirsHideFloatingResult.insert(dir)
                }
            }
        )
    }

    @ViewBuilder var ignoreRulesView: some View {
        if selectedDirs.count == 1, let dir = selectedDirs.first {
            HStack {
                Text("Ignore rules").semibold(12).fixedSize()
                Spacer()
                Text("\(dir.replacingOccurrences(of: HOME.string, with: "~"))/.clopignore-\(fileType.rawValue)")
                    .mono(11)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .frame(maxWidth: 400, alignment: .trailing)
            }.padding(.top, 2).opacity(0.8)
            TextEditor(text: $textDebounce.text)
                .font(.mono(12))
                .onChange(of: textDebounce.debouncedText, perform: { value in
                    guard Self.shouldSave else { return }
                    saveIgnoreRules(text: value)
                })
                .frame(height: 100)
            HStack {
                Text("Follows the standard .gitignore rules.").regular(10)
                Button("\(SwiftUI.Image(systemName: "arrowtriangle.down.square")) Click for more info") {
                    clopignoreHelpVisible.toggle()
                }
                .buttonStyle(.plain)
                .font(.semibold(10))
            }
            .opacity(0.8)

            if clopignoreHelpVisible {
                ScrollView {
                    Text("""
                    **Pattern syntax:**

                    1. **Wildcards**: You can use asterisks (`*`) as wildcards to match multiple characters or directories at any level. For example, `*.jpg` will match all files with the .jpg extension, such as `image.jpg` or `photo.jpg`. Similarly, `*.pdf` will match any PDF files.

                    2. **Directory names**: You can specify directories in patterns by ending the pattern with a slash (/). For instance, `images/` will match all files or directories named "images" or residing within an "images" directory.

                    3. **Negation**: Prefixing a pattern with an exclamation mark (!) negates the pattern, instructing the app to include files that would otherwise be excluded. For example, `!important.pdf` would include a file named "important.pdf" even if it satisfies other exclusion patterns.

                    4. **Comments**: You can include comments by adding a hash symbol (`#`) at the beginning of the line. These comments are ignored by the app and serve as helpful annotations for humans.

                    *More complex patterns can be found in the [gitignore documentation](https://git-scm.com/docs/gitignore#_pattern_format).*

                    **Examples:**

                    `# Ignore all files with the .jpg extension`
                    `*.jpg`
                    ` `
                    `# Ignore all folders and subfolders (like a non-recursive option)`
                    `*/*`
                    ` `
                    `# Exclude all files in a "DontOptimise" directory`
                    `DontOptimise/`
                    ` `
                    `# Exclude all MKV video files`
                    `*.mkv`
                    ` `
                    `# Exclude invoices (PDF files starting with "invoice-")`
                    `invoice-*.pdf`
                    ` `
                    `# Exclude a specific file named "confidential.pdf"`
                    `confidential.pdf`
                    ` `
                    `# Include a specific file named "important.pdf" even if it matches other patterns`
                    `!important.pdf`
                    """)
                    .foregroundColor(.secondary)
                }
                .roundbg(color: .black.opacity(0.05))
            }
        } else {
            (Text("Select a single path to edit its ") + Text("Ignore rules").bold())
                .padding(.top, 6)
                .opacity(0.8)
        }

    }

    func dirHasAutomation(_ dir: String) -> Bool {
        Defaults[fileType.pipelineKey][dir]?.isEmpty == false
    }

    func navigateToAutomation(folder: String) {
        settingsViewManager.scrollToFileType = fileType
        settingsViewManager.highlightFolder = HighlightedFolderRequest(fileType: fileType, folder: folder)
        settingsViewManager.tab = .automation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Table(dirs.sorted(), selection: $selectedDirs) {
                    TableColumn("Path") { dir in Text(dir.replacingOccurrences(of: HOME.string, with: "~")).mono(12) }
                    TableColumn("Show floating results") { dir in
                        Toggle("", isOn: showFloatingBinding(for: dir))
                            .toggleStyle(.checkbox)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help("Show the floating thumbnail and progress when files in this folder are optimised")
                    }
                    .width(130)
                    TableColumn("") { dir in
                        Button(dirHasAutomation(dir) ? "Edit automation" : "Add automation") {
                            navigateToAutomation(folder: dir)
                        }
                        .font(.round(10))
                        .buttonStyle(.borderless)
                        .foregroundColor(.accentColor)
                    }
                    .width(110)
                }
                .tableStyle(.inset)
                .frame(height: 150)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.6)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }.frame(height: 150)

            HStack(spacing: 2) {
                Button(action: { chooseFile = true }, label: { SwiftUI.Image(systemName: "plus").font(.bold(12)).frame(width: 16, height: 16) })
                    .fileImporter(
                        isPresented: $chooseFile,
                        allowedContentTypes: [.directory],
                        allowsMultipleSelection: true,
                        onCompletion: { result in
                            switch result {
                            case let .success(success):
                                dirs = (dirs + success.map(\.path)).uniqued.without(NOT_ALLOWED_TO_WATCH)
                            case let .failure(failure):
                                log.error("\(failure.localizedDescription)")
                            }
                        }
                    )
                    .disabled(!enabled)

                Button(
                    action: {
                        dirs = Set(dirs).without(selectedDirs)
                        selectedDirs = []
                    },
                    label: { SwiftUI.Image(systemName: "minus").font(.bold(12)).frame(width: 16, height: 16) }
                )
                .disabled(selectedDirs.isEmpty || !enabled)
                Spacer()
                Toggle(" Enable **\(fileType == .pdf ? "PDF" : fileType.rawValue)** auto-optimiser", isOn: $enabled)
                    .font(.round(11, weight: .regular))
                    .controlSize(.mini)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }

            if !hideIgnoreRules, enabled {
                ignoreRulesView
            }
        }
        .padding(4)
        .onChange(of: selectedDirs) { [selectedDirs] newSelectedDirs in
            Self.shouldSave = false
            guard newSelectedDirs.count == 1, let dir = newSelectedDirs.first else {
                return
            }
            if textDebounce.text != textDebounce.debouncedText {
                saveIgnoreRules(text: textDebounce.text, dir: selectedDirs.first)
            }

            textDebounce.debouncedText = (try? String(contentsOfFile: "\(dir)/.clopignore-\(fileType.rawValue)")) ?? ""
            textDebounce.text = textDebounce.debouncedText
        }
        .onChange(of: enabled) { enabled in
            if !enabled {
                selectedDirs = []
            }
        }
    }

    func saveIgnoreRules(text: String, dir: String? = nil) {
        guard let dir = dir ?? selectedDirs.first else { return }

        let clopIgnore = "\(dir)/.clopignore-\(fileType.rawValue)"
        guard text.isNotEmpty else {
            log.debug("Deleting \(clopIgnore)")
            try? fm.removeItem(atPath: clopIgnore)
            return
        }
        do {
            log.debug("Saving \(clopIgnore)")
            try text.write(toFile: clopIgnore, atomically: false, encoding: .utf8)
        } catch {
            log.error("\(error.localizedDescription)")
        }
    }
}

struct PDFSettingsView: View {
    @Default(.pdfDirs) var pdfDirs
    @Default(.maxPDFSizeMB) var maxPDFSizeMB
    @Default(.maxPDFFileCount) var maxPDFFileCount
    @Default(.useAggressiveOptimisationPDF) var useAggressiveOptimisationPDF
    @Default(.pdfDPI) var pdfDPI
    @Default(.pdfDPIAggressive) var pdfDPIAggressive
    @Default(.enableAutomaticPDFOptimisations) var enableAutomaticPDFOptimisations
    @Default(.optimisedPDFBehaviour) var optimisedPDFBehaviour
    @Default(.sameFolderNameTemplatePDF) var sameFolderNameTemplatePDF
    @Default(.specificFolderNameTemplatePDF) var specificFolderNameTemplatePDF

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise PDFs as they appear in these folders")) {
                DirListView(fileType: .pdf, dirs: $pdfDirs, enabled: $enableAutomaticPDFOptimisations)
            }
            Section(header: SectionHeader(title: "Optimisation rules")) {
                OptimisedFileBehaviourView(
                    type: .pdf, optimisedBehaviour: $optimisedPDFBehaviour,
                    sameFolderNameTemplate: $sameFolderNameTemplatePDF,
                    specificFolderNameTemplate: $specificFolderNameTemplatePDF
                )
                HStack {
                    Text("Skip when PDFs larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxPDFSizeMB, formatter: BoundFormatter(min: 1, max: 10000))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text("MB").mono(13)
                    Text("are copied or moved in watched folders").regular(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxPDFFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text(maxPDFFileCount == 1 ? "PDF is copied or moved in watched folders" : "PDFs are copied or moved in watched folders").regular(13)
                }

                Toggle(isOn: $useAggressiveOptimisationPDF) {
                    Text("Use more aggressive optimisation").regular(13)
                        + Text("\nGenerates smaller files with slightly worse visual quality").round(11, weight: .regular).foregroundColor(.secondary)
                }
                PDFDPIPickerView(label: "Image DPI for normal optimisation", binding: $pdfDPI)
                PDFDPIPickerView(label: "Image DPI for aggressive optimisation", binding: $pdfDPIAggressive, includeAdaptive: true)
            }
        }
        .scrollContentBackground(.hidden)
        .padding(4)
    }
}

struct PDFDPIPickerView: View {
    let label: String
    @Binding var binding: Int
    var includeAdaptive = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).regular(13)
                Text(
                    includeAdaptive
                        ? "Adaptive picks a per-PDF target based on the source image density. Specific values keep the picked DPI for every PDF."
                        : "300 DPI keeps images at full resolution. Lower values can make the PDF appear less sharp."
                )
                .round(11, weight: .regular).foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $binding) {
                if includeAdaptive {
                    Text("Adaptive").tag(PDF_DPI_ADAPTIVE)
                }
                ForEach(PDF_DPI_STOPS, id: \.self) { dpi in
                    Text(dpi == PDF_DPI_NO_DOWNSAMPLE ? "\(dpi) (no downsample)" : "\(dpi)").tag(dpi)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
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
    @Default(.optimisedVideoBehaviour) var optimisedVideoBehaviour
    @Default(.sameFolderNameTemplateVideo) var sameFolderNameTemplateVideo
    @Default(.specificFolderNameTemplateVideo) var specificFolderNameTemplateVideo
    @Default(.maxVideoFileCount) var maxVideoFileCount
    @Default(.removeAudioFromVideos) var removeAudioFromVideos
    @Default(.convertAudioToAAC) var convertAudioToAAC

    @Default(.videoEncoder) var videoEncoder
    #if arch(arm64)
        @Default(.useCPUIntensiveEncoder) var useCPUIntensiveEncoder
    #endif
    @Default(.useAggressiveOptimisationMP4) var useAggressiveOptimisationMP4
    @Default(.enableAutomaticVideoOptimisations) var enableAutomaticVideoOptimisations

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise videos as they appear in these folders")) {
                DirListView(fileType: .video, dirs: $videoDirs, enabled: $enableAutomaticVideoOptimisations)
            }
            Section(header: SectionHeader(title: "Optimisation rules")) {
                OptimisedFileBehaviourView(
                    type: .video, optimisedBehaviour: $optimisedVideoBehaviour,
                    sameFolderNameTemplate: $sameFolderNameTemplateVideo,
                    specificFolderNameTemplate: $specificFolderNameTemplateVideo
                )
                HStack {
                    Text("Skip when videos larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxVideoSizeMB, formatter: BoundFormatter(min: 1, max: 10000))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text("MB").mono(13)
                    Text("are copied or moved in watched folders").regular(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxVideoFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text(maxVideoFileCount == 1 ? "video is copied or moved in watched folders" : "videos are copied or moved in watched folders").regular(13)
                }
                HStack {
                    Text("Ignore videos with extension").regular(13).padding(.trailing, 10)
                    Spacer()

                    ForEach(VIDEO_FORMATS, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            videoFormatsToSkip.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { videoFormatsToSkip.contains(format) }))
                            .font(.mono(11))
                    }
                }
                Picker(selection: $videoEncoder) {
                    ForEach(VideoEncoder.allCases, id: \.self) { encoder in
                        Text(encoder.name).tag(encoder)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Video encoder").regular(13)
                        Text(videoEncoder.description).round(11, weight: .regular).foregroundColor(.secondary)
                    }
                }
                #if arch(arm64)
                    if videoEncoder != .fast {
                        Toggle(isOn: $adaptiveVideoSize) {
                            Text("Adaptive optimisation").regular(13)
                                + Text("\nFalls back to the fast encoder for large files to save time and battery").round(11, weight: .regular).foregroundColor(.secondary)
                        }
                    }
                #endif
                Toggle("Remove audio on optimised videos", isOn: $removeAudioFromVideos)
                Toggle(isOn: $capVideoFPS.animation(.spring())) {
                    HStack {
                        Text("Cap frames per second to").regular(13).padding(.trailing, 10)
                        Spacer()

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
                        Spacer()

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
                    Spacer()

                    ForEach(FORMATS_CONVERTIBLE_TO_MP4, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToMP4.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToMP4.contains(format) }))
                            .font(.mono(11))
                    }
                }
                Toggle("Convert audio to AAC", isOn: $convertAudioToAAC)
                convertedVideoLocation
            }
        }
        .scrollContentBackground(.hidden)
        .padding(4)
    }

    var convertedVideoLocation: some View {
        HStack {
            (
                Text("Converted video location").regular(13) +
                    Text("\nThis only applies to the MP4 files resulting\nfrom the conversion of the above formats").round(10)
                    .foregroundColor(.secondary)
            ).padding(.trailing, 10)

            Spacer()

            Button("Temporary\nfolder") {
                convertedVideoBehaviour = .temporary
            }.buttonStyle(ToggleButton(isOn: .oneway { convertedVideoBehaviour == .temporary }))
                .font(.round(10))
                .multilineTextAlignment(.center)
            Button("In-place\n(replace original)") {
                convertedVideoBehaviour = .inPlace
            }.buttonStyle(ToggleButton(isOn: .oneway { convertedVideoBehaviour == .inPlace }))
                .font(.round(10))
                .multilineTextAlignment(.center)
            Button("Same folder\n(as original)") {
                convertedVideoBehaviour = .sameFolder
            }.buttonStyle(ToggleButton(isOn: .oneway { convertedVideoBehaviour == .sameFolder }))
                .font(.round(10))
                .multilineTextAlignment(.center)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        Text(title).round(15, weight: .semibold)
            + (subtitle.map { Text("\n\($0)").font(.caption).foregroundColor(.secondary) } ?? Text(""))
    }
}

let DEFAULT_NAME_TEMPLATE = "clop_%y-%m-%d_%i"
let DEFAULT_SAME_FOLDER_NAME_TEMPLATE = "%f-optimised"
let DEFAULT_SPECIFIC_FOLDER_NAME_TEMPLATE = "%P/optimised/%f"

struct OptimisedFileBehaviourView: View {
    let type: ClopFileType
    @Binding var optimisedBehaviour: OptimisedFileBehaviour
    @Binding var sameFolderNameTemplate: String
    @Binding var specificFolderNameTemplate: String

    var body: some View {
        VStack {
            HStack {
                (
                    Text("Optimised \(type.description) location").regular(13) +
                        Text("\nWhere to place the optimised files").round(10).foregroundColor(.secondary)
                ).padding(.trailing, 10)

                Spacer()

                Button("Temporary\nfolder") {
                    optimisedBehaviour = .temporary
                }.buttonStyle(ToggleButton(isOn: .oneway { optimisedBehaviour == .temporary }))
                    .font(.round(10))
                    .multilineTextAlignment(.center)
                Button("In-place\n(replace original)") {
                    optimisedBehaviour = .inPlace
                }.buttonStyle(ToggleButton(isOn: .oneway { optimisedBehaviour == .inPlace }))
                    .font(.round(10))
                    .multilineTextAlignment(.center)
                Button("Same folder\n(as original)") {
                    optimisedBehaviour = .sameFolder
                }.buttonStyle(ToggleButton(isOn: .oneway { optimisedBehaviour == .sameFolder }))
                    .font(.round(10))
                    .multilineTextAlignment(.center)
                Button("Specific\nfolder") {
                    optimisedBehaviour = .specificFolder
                }.buttonStyle(ToggleButton(isOn: .oneway { optimisedBehaviour == .specificFolder }))
                    .font(.round(10))
                    .multilineTextAlignment(.center)
            }
            if optimisedBehaviour == .sameFolder {
                SameFolderNameTemplate(type: type, template: $sameFolderNameTemplate)
                    .roundbg(radius: 10, verticalPadding: 8, horizontalPadding: 8, color: .fg.warm.opacity(0.05))
            }
            if optimisedBehaviour == .specificFolder {
                SpecificFolderNameTemplate(type: type, template: $specificFolderNameTemplate)
                    .roundbg(radius: 10, verticalPadding: 8, horizontalPadding: 8, color: .fg.warm.opacity(0.05))
            }
        }
    }
}

struct SameFolderNameTemplate: View {
    let type: ClopFileType
    @Binding var template: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name template").medium(12)
                + Text("\nRename the optimised file using this template").round(11, weight: .regular).foregroundColor(.secondary)

            VStack(alignment: .leading) {
                TextField("", text: $template, prompt: Text(DEFAULT_SAME_FOLDER_NAME_TEMPLATE))
                    .frame(width: TEXT_FIELD_WIDTH, height: 18, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                HStack {
                    Text("Example on \(type.defaultNameTemplatePath.name.string): ")
                        .round(12)
                        .lineLimit(1)
                        .allowsTightening(false)
                        .foregroundColor(.secondary.opacity(0.6))
                        .offset(x: 6)
                    Spacer()
                    Text(generateFileName(template: template ?! DEFAULT_SAME_FOLDER_NAME_TEMPLATE, for: type.defaultNameTemplatePath, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber]))
                        .round(12)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("""
                **Date**                | **Time**
                --------------------|-----------------
                Year             **%y** | Hour     **%H**
                Month (numeric)  **%m** | Minutes  **%M**
                Month (name)     **%n** | Seconds  **%S**
                Day              **%d** | AM/PM    **%p**
                Weekday          **%w** |
                """)

                Spacer()

                Text("""
                Source file name (without extension)   **%f**
                Source file extension                  **%e**

                Random characters                      **%r**
                Auto-incrementing number               **%i**
                """)
            }
            .font(.mono(11, weight: .light))
            .foregroundColor(.secondary)
            .padding(6)
        }
    }
}
struct SpecificFolderNameTemplate: View {
    let type: ClopFileType
    @Binding var template: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Path template").medium(12)
                + Text("\nCreate the optimised file into a path generated by this template").round(11, weight: .regular).foregroundColor(.secondary)

            VStack(alignment: .leading) {
                TextField("", text: $template, prompt: Text(DEFAULT_SPECIFIC_FOLDER_NAME_TEMPLATE))
                    .frame(width: TEXT_FIELD_WIDTH, height: 18, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                HStack {
                    Text("Example on \(type.defaultNameTemplatePath.shellString): ")
                        .mono(10)
                        .lineLimit(1)
                        .allowsTightening(false)
                        .foregroundColor(.secondary.opacity(0.6))
                        .offset(x: 6)
                    Spacer()
                    Text(
                        try! generateFilePath(
                            template: template ?! DEFAULT_SPECIFIC_FOLDER_NAME_TEMPLATE,
                            for: type.defaultNameTemplatePath,
                            autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber],
                            mkdir: false
                        )?.shellString ?? "Invalid path"
                    )
                    .round(12)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("""
                **Date**                | **Time**
                --------------------|-----------------
                Year             **%y** | Hour     **%H**
                Month (numeric)  **%m** | Minutes  **%M**
                Month (name)     **%n** | Seconds  **%S**
                Day              **%d** | AM/PM    **%p**
                Weekday          **%w** |
                """)

                Spacer()

                Text("""
                Source file path (without name)        **%P**
                Source file name (without extension)   **%f**
                Source file extension                  **%e**

                Random characters                      **%r**
                Auto-incrementing number               **%i**
                """)
            }
            .font(.mono(12, weight: .light))
            .foregroundColor(.secondary)
            .padding(6)
        }
    }
}

struct AudioSettingsView: View {
    @Default(.audioDirs) var audioDirs
    @Default(.audioFormat) var audioFormat
    @Default(.audioBitrate) var audioBitrate
    @Default(.audioFormatsToSkip) var audioFormatsToSkip
    @Default(.formatsToConvertToOutputAudio) var formatsToConvertToOutputAudio
    @Default(.maxAudioSizeMB) var maxAudioSizeMB
    @Default(.maxAudioFileCount) var maxAudioFileCount
    @Default(.optimisedAudioBehaviour) var optimisedAudioBehaviour
    @Default(.sameFolderNameTemplateAudio) var sameFolderNameTemplateAudio
    @Default(.specificFolderNameTemplateAudio) var specificFolderNameTemplateAudio
    @Default(.enableAutomaticAudioOptimisations) var enableAutomaticAudioOptimisations

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise audio files as they appear in these folders")) {
                DirListView(fileType: .audio, dirs: $audioDirs, enabled: $enableAutomaticAudioOptimisations)
            }
            Section(header: SectionHeader(title: "Optimisation rules")) {
                OptimisedFileBehaviourView(
                    type: .audio, optimisedBehaviour: $optimisedAudioBehaviour,
                    sameFolderNameTemplate: $sameFolderNameTemplateAudio,
                    specificFolderNameTemplate: $specificFolderNameTemplateAudio
                )
                HStack {
                    Text("Skip when audio files larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxAudioSizeMB, formatter: BoundFormatter(min: 1, max: 10000))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text("MB").mono(13)
                    Text("are copied or moved in watched folders").regular(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxAudioFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text(maxAudioFileCount == 1 ? "audio file is copied or moved in watched folders" : "audio files are copied or moved in watched folders").regular(13)
                }
                Picker(selection: $audioFormat) {
                    ForEach(AudioFormat.allCases, id: \.self) { format in
                        Text(format.name).tag(format)
                    }
                } label: {
                    Text("Output format").regular(13)
                }
                .onChange(of: audioFormat) { newFormat in
                    if newFormat.isLossless {
                        audioBitrate = newFormat.defaultBitrate
                    } else if audioBitrate >= 0, !newFormat.allowedBitrates.contains(audioBitrate) {
                        audioBitrate = newFormat.defaultBitrate
                    }
                    if let ut = newFormat.utType {
                        formatsToConvertToOutputAudio.remove(ut)
                    }
                }
                if !audioFormat.isLossless {
                    Picker(selection: $audioBitrate) {
                        Text("1 step lower than input").tag(-1)
                        Text("2 steps lower than input").tag(-2)
                        Divider()
                        ForEach(audioFormat.allowedBitrates, id: \.self) { bitrate in
                            Text("\(bitrate) kbps").tag(bitrate)
                        }
                    } label: {
                        Text("Bitrate").regular(13)
                    }
                }
            }
            if audioFormat != .sameAsInput, !audioFormat.isLossless {
                Section(header: SectionHeader(title: "Compatibility", subtitle: "Converts selected formats to \(audioFormat.fileExtension) before optimisation")) {
                    HStack {
                        (Text("Convert to ").regular(13) + Text(audioFormat.fileExtension).mono(13)).padding(.trailing, 10)
                        Spacer()

                        ForEach(ALL_AUDIO_CONVERTIBLE_FORMATS.filter { $0 != audioFormat.utType }, id: \.identifier) { format in
                            Button(format.preferredFilenameExtension ?? format.identifier) {
                                formatsToConvertToOutputAudio.toggle(format)
                            }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToOutputAudio.contains(format) }))
                                .font(.mono(11))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct ImagesSettingsView: View {
    @Default(.imageDirs) var imageDirs
    @Default(.formatsToConvertToJPEG) var formatsToConvertToJPEG
    @Default(.formatsToConvertToPNG) var formatsToConvertToPNG
    @Default(.maxImageSizeMB) var maxImageSizeMB
    @Default(.imageFormatsToSkip) var imageFormatsToSkip
    @Default(.adaptiveImageSize) var adaptiveImageSize
    // @Default(.downscaleRetinaImages) var downscaleRetinaImages
    @Default(.convertedImageBehaviour) var convertedImageBehaviour
    @Default(.optimisedImageBehaviour) var optimisedImageBehaviour
    @Default(.sameFolderNameTemplateImage) var sameFolderNameTemplateImage
    @Default(.specificFolderNameTemplateImage) var specificFolderNameTemplateImage
    @Default(.maxImageFileCount) var maxImageFileCount
    @Default(.copyImageFilePath) var copyImageFilePath
    @Default(.customNameTemplateForClipboardImages) var customNameTemplateForClipboardImages
    @Default(.useCustomNameTemplateForClipboardImages) var useCustomNameTemplateForClipboardImages
    @Default(.enablePhotosIntegration) var enablePhotosIntegration
    @Default(.maxCopiedPhotosCount) var maxCopiedPhotosCount
    @Default(.maxPhotosLength) var maxPhotosLength
    @Default(.photoCropOrientation) var photoCropOrientation

    @Default(.useAggressiveOptimisationJPEG) var useAggressiveOptimisationJPEG
    @Default(.useAggressiveOptimisationPNG) var useAggressiveOptimisationPNG
    @Default(.useAggressiveOptimisationGIF) var useAggressiveOptimisationGIF
    @Default(.enableAutomaticImageOptimisations) var enableAutomaticImageOptimisations

    var maxPhotosLengthBinding: Binding<String> {
        Binding(
            get: { maxPhotosLength?.description ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let val = Int(trimmed) {
                    maxPhotosLength = val.capped(between: 1, and: 20000)
                } else {
                    maxPhotosLength = nil
                }
            }
        )
    }

    var customNameTemplate: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom name template").regular(13)
                + Text("\nRename the file using this template before copying the path to the clipboard").round(11, weight: .regular).foregroundColor(.secondary)

            VStack(alignment: .leading) {
                TextField("", text: $customNameTemplateForClipboardImages, prompt: Text(DEFAULT_NAME_TEMPLATE))
                    .frame(width: TEXT_FIELD_WIDTH, height: 18, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray.opacity(useCustomNameTemplateForClipboardImages ? 1 : 0.35), lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE)
                            .offset(x: TEXT_FIELD_OFFSET)
                    )
                    .disabled(!useCustomNameTemplateForClipboardImages)
                if useCustomNameTemplateForClipboardImages {
                    Text("Result: " + generateFileName(template: customNameTemplateForClipboardImages ?! DEFAULT_NAME_TEMPLATE, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber]))
                        .round(12)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .offset(x: 6)
                }
            }
            if useCustomNameTemplateForClipboardImages {
                Text("""
                **Date**                | **Time**
                --------------------|-----------------
                Year             **%y** | Hour     **%H**
                Month (numeric)  **%m** | Minutes  **%M**
                Month (name)     **%n** | Seconds  **%S**
                Day              **%d** | AM/PM    **%p**
                Weekday          **%w** |

                Random characters **%r**
                Auto-incrementing number **%i**
                """)
                .mono(12, weight: .light)
                .foregroundColor(.secondary)
                .padding(.top, 6)
            }
        }

    }

    var cropOrientationPicker: some View {
        Picker("", selection: $photoCropOrientation) {
            Label("height", systemImage: "rectangle.portrait").tag(CropOrientation.portrait)
                .help("Resize images until the height is equal or lower than the specified size.")
            Label("longest edge", systemImage: "sparkles.rectangle.stack").tag(CropOrientation.adaptive)
                .help("Resize images until the longest edge is equal or lower than the specified size.")
            Label("width", systemImage: "rectangle").tag(CropOrientation.landscape)
                .help("Resize images until the width is equal or lower than the specified size.")
        }
        .fixedSize()
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .font(.heavy(10))
    }

    var body: some View {
        Form {
            Section(header: SectionHeader(title: "Watch paths", subtitle: "Optimise images as they appear in these folders")) {
                DirListView(fileType: .image, dirs: $imageDirs, enabled: $enableAutomaticImageOptimisations)
            }
            Section(header: SectionHeader(title: "File name handling")) {
                Toggle(isOn: $copyImageFilePath) {
                    Text("Copy image paths").regular(13)
                        + Text("\nWhen copying optimised image data, also copy the path of the image file").round(11, weight: .regular).foregroundColor(.secondary)
                }
                Toggle(isOn: $useCustomNameTemplateForClipboardImages.animation(.default)) {
                    customNameTemplate
                }.disabled(!copyImageFilePath)
            }

            Section(header: SectionHeader(title: "Photos integration", subtitle: "Handle images copied from the Photos app")) {
                Toggle(isOn: $enablePhotosIntegration.animation(.spring())) {
                    Text("Optimise images copied from Photos.app").regular(13)
                }

                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxCopiedPhotosCount, formatter: BoundFormatter(min: 1, max: 50))
                        .lineLimit(1)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text(maxCopiedPhotosCount == 1 ? "photo is copied" : "photos are copied").regular(13)
                }
                .disabled(!enablePhotosIntegration)

                HStack(spacing: 6) {
                    Text("Downscale to").regular(13).lineLimit(1).fixedSize()
                    TextField("", text: maxPhotosLengthBinding)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 70, alignment: .trailing)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text("px").mono(13).opacity(maxPhotosLength != nil ? 1 : 0.3).lineLimit(1).fixedSize()
                    Text("on").regular(13).lineLimit(1).fixedSize()
                    Spacer()
                    cropOrientationPicker
                }
                .disabled(!enablePhotosIntegration)
            }

            Section(header: SectionHeader(title: "Optimisation rules")) {
                OptimisedFileBehaviourView(
                    type: .image, optimisedBehaviour: $optimisedImageBehaviour,
                    sameFolderNameTemplate: $sameFolderNameTemplateImage,
                    specificFolderNameTemplate: $specificFolderNameTemplateImage
                )

                HStack {
                    Text("Skip when images larger than").regular(13).padding(.trailing, 10)
                    TextField("", value: $maxImageSizeMB, formatter: BoundFormatter(min: 1, max: 500))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text("MB").mono(13)
                    Text("are copied or moved in watched folders").regular(13)
                }
                HStack {
                    Text("Skip when more than").regular(13)
                    TextField("", value: $maxImageFileCount, formatter: BoundFormatter(min: 1, max: 100))
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Text(maxImageFileCount == 1 ? "image is copied or moved in watched folders" : "images are copied or moved in watched folders").regular(13)
                }

                HStack {
                    Text("Ignore images with extension").regular(13).padding(.trailing, 10)
                    Spacer()

                    ForEach(IMAGE_FORMATS, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            imageFormatsToSkip.toggle(format)
                        }.buttonStyle(ToggleButton(isOn: .oneway { imageFormatsToSkip.contains(format) }))
                            .font(.mono(11))
                    }
                }
                HStack {
                    Text("Use more aggressive optimisation for").regular(13).padding(.trailing, 10)
                    Spacer()

                    Button("jpeg") {
                        useAggressiveOptimisationJPEG.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggressiveOptimisationJPEG))
                        .font(.mono(11))
                    Button("png") {
                        useAggressiveOptimisationPNG.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggressiveOptimisationPNG))
                        .font(.mono(11))
                    Button("gif") {
                        useAggressiveOptimisationGIF.toggle()
                    }.buttonStyle(ToggleButton(isOn: $useAggressiveOptimisationGIF))
                        .font(.mono(11))
                }
                Toggle(isOn: $adaptiveImageSize) {
                    Text("Adaptive optimisation").regular(13)
                        + Text("\nConvert detail heavy images to JPEG and low-detail ones to PNG").round(11, weight: .regular).foregroundColor(.secondary)
                }
                // Toggle(isOn: $downscaleRetinaImages) {
                //     Text("Downscale HiDPI images to 72 DPI").regular(13)
                //         + Text("\nScales down images taken on HiDPI screens to the standard DPI for web (e.g. Retina to 1x)").round(11, weight: .regular).foregroundColor(.secondary)
                // }

            }
            Section(header: SectionHeader(title: "Compatibility", subtitle: "Converts less known formats to more compatible ones before optimisation")) {
                HStack {
                    (Text("Convert to ").regular(13) + Text("jpeg").mono(13)).padding(.trailing, 10)
                    Spacer()

                    ForEach(FORMATS_CONVERTIBLE_TO_JPEG, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToJPEG.toggle(format)
                            if formatsToConvertToJPEG.contains(format) {
                                formatsToConvertToPNG.remove(format)
                            }
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToJPEG.contains(format) }))
                            .font(.mono(11))
                    }
                }
                HStack {
                    (Text("Convert to ").regular(13) + Text("png").mono(13)).padding(.trailing, 10)
                    Spacer()

                    ForEach(FORMATS_CONVERTIBLE_TO_PNG, id: \.identifier) { format in
                        Button(format.preferredFilenameExtension!) {
                            formatsToConvertToPNG.toggle(format)
                            if formatsToConvertToPNG.contains(format) {
                                formatsToConvertToJPEG.remove(format)
                            }
                        }.buttonStyle(ToggleButton(isOn: .oneway { formatsToConvertToPNG.contains(format) }))
                            .font(.mono(11))
                    }
                }
                convertedImageLocation
            }

        }
        .scrollContentBackground(.hidden)
        .padding(4)
    }
    var convertedImageLocation: some View {
        HStack {
            (
                Text("Converted image location").regular(13) +
                    Text("\nThis only applies to JPGs and PNGs resulting\nfrom the conversion of the above formats").round(10)
                    .foregroundColor(.secondary)
            ).padding(.trailing, 10)

            Spacer()

            Button("Temporary\nfolder") {
                convertedImageBehaviour = .temporary
            }.buttonStyle(ToggleButton(isOn: .oneway { convertedImageBehaviour == .temporary }))
                .font(.round(10))
                .multilineTextAlignment(.center)
            Button("In-place\n(replace original)") {
                convertedImageBehaviour = .inPlace
            }.buttonStyle(ToggleButton(isOn: .oneway { convertedImageBehaviour == .inPlace }))
                .font(.round(10))
                .multilineTextAlignment(.center)
            Button("Same folder\n(as original)") {
                convertedImageBehaviour = .sameFolder
            }.buttonStyle(ToggleButton(isOn: .oneway { convertedImageBehaviour == .sameFolder }))
                .font(.round(10))
                .multilineTextAlignment(.center)
        }
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
                    DirectionalModifierView(triggerKeys: $keyComboModifiers, showFnCaps: false, allowShiftAlone: false)
                    Text(" + ")
                }
            }
            Section(header: SectionHeader(title: "Action keys")) {
                keyToggle(.minus, actionName: "Downscale", description: "Decrease resolution of the last image or video")
                keyToggle(.x, actionName: "Speed up video", description: "Make video playback faster by dropping frames")
                keyToggle(.delete, actionName: "Stop and Dismiss", description: "Stop the last running action and dismiss the floating result")
                keyToggle(.escape, actionName: "Stop and Clear All", description: "Stop running optimisations and clear all floating results")
                keyToggle(.equal, actionName: "Bring Back", description: "Bring back the last removed floating result")
                keyToggle(.space, actionName: "QuickLook", description: "Preview the latest image or video")
                keyToggle(.r, actionName: "Rename", description: "Rename the file of the latest image or video")
                keyToggle(.z, actionName: "Restore original", description: "Revert optimisations and downscaling actions done on the latest image or video")
                keyToggle(.p, actionName: "Pause optimisations", description: "Pause or stop automatic optimisations")
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
        .scrollContentBackground(.hidden)
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

    var proText: some View {
        Text(proactive ? "Pro" : "")
    }

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                SwiftUI.Image("clop")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                proText
                    .font(.mono(16, weight: .semibold))
                    .foregroundColor(.hotRed)
                    .offset(x: 5, y: 14)
            }
            Text("Clop")
                .round(64, weight: .black)
                .padding(.top, -30)
            Text((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "v2")
                .mono(16, weight: .regular)
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

import SymbolPicker

struct IconPickerView: View {
    @Binding var icon: String

    var body: some View {
        Button {
            iconPickerPresented = true
        } label: {
            SwiftUI.Image(systemName: icon)
        }
        .sheet(isPresented: $iconPickerPresented) {
            SymbolPicker(symbol: $icon)
        }
    }

    @State private var iconPickerPresented = false

}

struct DropZoneSettingsView: View {
    @Default(.enableDragAndDrop) var enableDragAndDrop
    @Default(.onlyShowDropZoneOnOption) var onlyShowDropZoneOnOption
    @Default(.onlyShowPresetZonesOnControlTapped) var onlyShowPresetZonesOnControlTapped
    @Default(.autoCopyToClipboard) var autoCopyToClipboard
    @Default(.presetZones) var presetZones
    @Default(.floatingResultsCorner) var floatingResultsCorner

    @State var editingZone: PresetZone? = nil
    @ObservedObject var shortcutsManager = SHM

    var zones: some View {
        Section(header: SectionHeader(title: "Preset zones", subtitle: "Drag files to these zones to run actions like crop, convert, copy and more")) {
            Toggle(isOn: $onlyShowPresetZonesOnControlTapped) {
                Text("Tap ^ Control to show preset zones").regular(13)
                    + Text("\nToggle preset zones by tapping ^ Control instead of by holding it").round(11, weight: .regular).foregroundColor(.secondary)
            }

            VStack(spacing: 6) {
                let types: [ClopFileType?] = [.image, .video, .audio, .pdf, nil]
                ForEach(types.indices, id: \.self) { i in
                    let t = types[i]
                    let matching = presetZones.filter { $0.type == t }
                    if !matching.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.map { $0 == .pdf ? "PDF" : $0.description.capitalized } ?? "Any type")
                                .semibold(10)
                                .foregroundColor(t?.color ?? .secondary)
                                .padding(.top, i > 0 ? 4 : 0)
                            ForEach(matching) { zone in
                                if let editingZone, editingZone.id == zone.id {
                                    PresetZoneEditor(zone: $editingZone)
                                } else {
                                    zoneItem(zone: zone)
                                }
                            }
                        }
                    }
                }
                if editingZone == nil {
                    Divider().padding(.vertical, 8)
                    Text("Create a new preset for a specific file type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .hfill(.leading)
                    PresetZoneEditor(zone: .constant(nil))
                }
            }
        }
    }

    func zoneItem(zone: PresetZone) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SwiftUI.Image(systemName: zone.icon)
                    .font(.regular(13))
                    .frame(width: 20, alignment: .center)
                    .foregroundColor(.secondary)
                Text(zone.name)
                    .medium(12)
                SwiftUI.Image(systemName: zone.pipeline.skipOptimisation ? "bolt.slash" : "bolt.fill")
                    .font(.regular(8))
                    .foregroundColor(zone.pipeline.skipOptimisation ? .secondary.opacity(0.3) : .orange.opacity(0.5))

                Spacer()

                Button(action: { editingZone = zone }) {
                    SwiftUI.Image(systemName: "pencil")
                        .font(.regular(10))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                Button(role: .destructive, action: {
                    presetZones = presetZones.filter { $0.id != zone.id }
                }) {
                    SwiftUI.Image(systemName: "trash")
                        .foregroundColor(Color.systemRed.opacity(0.6))
                        .font(.regular(10))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }

            let resolved = zone.resolvedPipeline
            Text(resolved.displayText.isEmpty ? "no steps configured" : resolved.displayText)
                .mono(10.5)
                .foregroundColor(.secondary.opacity(0.7))
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.leading, 26)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
    var settings: some View {
        Form {
            Toggle(isOn: $enableDragAndDrop) {
                Text("Enable drop zone").regular(13)
                    + Text("\nAllows dragging files, paths and URLs to a global drop zone for optimisation").round(11, weight: .regular).foregroundColor(.secondary)
            }
            Toggle(isOn: $onlyShowDropZoneOnOption) {
                Text("Require pressing ⌥ Option to show drop zone").regular(13)
                    + Text("\nHide drop zone by default to avoid distractions while dragging files, show it by manually pressing ⌥ Option once").round(11, weight: .regular).foregroundColor(.secondary)
            }
            .padding(.leading, 20)
            .disabled(!enableDragAndDrop)
            Toggle(isOn: $autoCopyToClipboard) {
                Text("Auto Copy optimised files to clipboard").regular(13)
                    + Text("\nCopy files resulting from drop zone or file watch optimisation\nso they can be pasted right after optimisation ends").round(11, weight: .regular).foregroundColor(.secondary)
            }
            zones
        }
    }

    func dropZoneSection(_ title: String) -> some View {
        HStack {
            Text(title).semibold(11)
                .frame(width: DROPZONE_SIZE.width + DROPZONE_PADDING.width * 2, alignment: floatingResultsCorner.isTrailing ? .bottomLeading : .bottomTrailing)
                .padding(1)
        }
        .frame(width: THUMB_SIZE.width - 20, alignment: floatingResultsCorner.isTrailing ? .bottomTrailing : .bottomLeading)
        .offset(x: floatingResultsCorner.isTrailing ? -HAT_ICON_SIZE : HAT_ICON_SIZE, y: 5)
    }

    var body: some View {
        HStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                settings
            }

            VStack(spacing: 4) {
                VStack(spacing: 0) {
                    dropZoneSection("PDF preset zones")
                    DropZoneView(presetFileType: .pdf)
                    dropZoneSection("Video preset zones")
                    DropZoneView(presetFileType: .video)
                    dropZoneSection("Image preset zones")
                    DropZoneView(presetFileType: .image)
                    DropZoneView()
                }
                .frame(width: THUMB_SIZE.width - 50, height: WINDOW_MIN_SIZE.height - 100, alignment: floatingResultsCorner.isTrailing ? .bottomTrailing : .bottomLeading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gray.opacity(0.2), lineWidth: 2))
                .disabled(!enableDragAndDrop)
                .saturation(enableDragAndDrop ? 1 : 0.5)
                .preview(true)

                Text("Hold **`^ Control`** while dragging\nto show preset zones")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
        }
        .hfill()
        .padding(.top)
    }
}

struct FloatingSettingsView: View {
    @Default(.enableFloatingResults) var enableFloatingResults
    @Default(.showFloatingHatIcon) var showFloatingHatIcon
    @Default(.showImages) var showImages
    @Default(.showCompactImages) var showCompactImages
    @Default(.autoHideFloatingResults) var autoHideFloatingResults
    @Default(.autoHideFloatingResultsAfter) var autoHideFloatingResultsAfter
    @Default(.autoHideClipboardResultAfter) var autoHideClipboardResultAfter
    @Default(.autoClearAllCompactResultsAfter) var autoClearAllCompactResultsAfter
    @Default(.floatingResultsCorner) var floatingResultsCorner
    @Default(.alwaysShowCompactResults) var alwaysShowCompactResults
    @Default(.floatingResultActions) var floatingResultActions
    @Default(.compactResultActions) var compactResultActions
    @Default(.showCopyClearButtons) var showCopyClearButtons

    @Default(.dismissFloatingResultOnDrop) var dismissFloatingResultOnDrop
    @Default(.dismissFloatingResultOnUpload) var dismissFloatingResultOnUpload
    @Default(.dismissCompactResultOnDrop) var dismissCompactResultOnDrop
    @Default(.dismissCompactResultOnUpload) var dismissCompactResultOnUpload

    @State var compact = SWIFTUI_PREVIEW

    var settings: some View {
        Form {
            Toggle(isOn: $enableFloatingResults) {
                Text("Show floating results").regular(13)
                    + Text("\n\nDisabling this will make Clop run in an UI-less mode, but keep optimising files in the background. Drop zone can be disabled separately in the Drop zone tab")
                    .round(10, weight: .regular)
                    .foregroundColor(.secondary)
            }
            Section(header: SectionHeader(title: "Layout")) {
                Picker("Position on screen", selection: $floatingResultsCorner) {
                    Text("Bottom right").tag(ScreenCorner.bottomRight)
                    Text("Bottom left").tag(ScreenCorner.bottomLeft)
                    Text("Top right").tag(ScreenCorner.topRight)
                    Text("Top left").tag(ScreenCorner.topLeft)
                }
                Toggle(isOn: $alwaysShowCompactResults) {
                    Text("Always use compact layout").regular(13)
                        + Text("\n\nBy default, the layout switches to compact automatically when there are more than 5 results on the screen")
                        .round(10, weight: .regular)
                        .foregroundColor(.secondary)
                }
            }.disabled(!enableFloatingResults)

            Section(header: SectionHeader(title: "Full layout")) {
                Toggle("Show hat icon", isOn: $showFloatingHatIcon)
                Toggle("Show images", isOn: $showImages)
                Toggle("Show Copy all / Clear all buttons", isOn: $showCopyClearButtons)
                Text("Dismiss result after")
                Toggle("drag and drop outside", isOn: $dismissFloatingResultOnDrop).padding(.leading, 20)
                Toggle("upload to Dropshare", isOn: $dismissFloatingResultOnUpload).padding(.leading, 20)

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
            }.disabled(!enableFloatingResults)

            Section(header: SectionHeader(title: "Compact layout")) {
                Toggle("Show images", isOn: $showCompactImages)
                Text("Dismiss result after")
                Toggle("drag and drop outside", isOn: $dismissCompactResultOnDrop).padding(.leading, 20)
                Toggle("upload to Dropshare", isOn: $dismissCompactResultOnUpload).padding(.leading, 20)

                Picker("Auto clear all after", selection: $autoClearAllCompactResultsAfter) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("30 minutes").tag(1800)
                    Text("never").tag(0)
                }
            }.disabled(!enableFloatingResults)

        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 380).fixedSize()
    }

    var body: some View {
        HStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                settings
            }

            VStack {
                if compact {
                    CompactPreview()
                        .frame(width: THUMB_SIZE.width + 60, height: 450, alignment: .center)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gray.opacity(0.2), lineWidth: 2))
                        .disabled(!enableFloatingResults)
                        .saturation(enableFloatingResults ? 1 : 0.5)
                } else {
                    FloatingPreview()
                        .frame(width: THUMB_SIZE.width + 60, height: 450, alignment: .center)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.gray.opacity(0.2), lineWidth: 2))
                        .disabled(!enableFloatingResults)
                        .saturation(enableFloatingResults ? 1 : 0.5)
                }
                Picker("", selection: $compact) {
                    Text("Compact").tag(true)
                    Text("Full").tag(false)
                }.pickerStyle(.segmented).frame(width: 200)
                Text("only for preview")
                    .round(10)
                    .foregroundColor(.secondary)

                Divider().frame(width: 100).padding(.vertical, 4)

                if compact {
                    ActionListPicker(label: "Side actions", vertical: false, actions: $compactResultActions)
                } else {
                    ActionListPicker(label: "Side actions", vertical: true, actions: $floatingResultActions)
                }
            }
        }
        .hfill()
        .padding(.top)
        .onAppear {
            compact = alwaysShowCompactResults
        }
        .onChange(of: alwaysShowCompactResults) { value in
            compact = value
        }
    }
}
struct GeneralSettingsView: View {
    @Default(.showMenubarIcon) var showMenubarIcon
    @Default(.optimiseTIFF) var optimiseTIFF
    @Default(.optimiseVideoClipboard) var optimiseVideoClipboard
    @Default(.optimiseAudioClipboard) var optimiseAudioClipboard
    @Default(.optimisePDFClipboard) var optimisePDFClipboard
    @Default(.optimiseImagePathClipboard) var optimiseImagePathClipboard
    @Default(.enableClipboardOptimiser) var enableClipboardOptimiser
    @Default(.clipboardIgnoredAppBundleIds) var clipboardIgnoredAppBundleIds
    @Default(.appendClipboardResults) var appendClipboardResults
    @Default(.copyConsecutiveClipboardImages) var copyConsecutiveClipboardImages
    @Default(.clipboardAccumulationTimeout) var clipboardAccumulationTimeout
    @Default(.stripMetadata) var stripMetadata
    @Default(.preserveColorMetadata) var preserveColorMetadata
    @Default(.preserveDates) var preserveDates
    @Default(.syncSettingsCloud) var syncSettingsCloud
    @Default(.optimisedFileProtectionMs) var optimisedFileProtectionMs

    @Default(.workdir) var workdir
    @Default(.workdirCleanupInterval) var workdirCleanupInterval

    var workdirBinding: Binding<String> {
        Binding(
            get: { workdir.shellString },
            set: { value in
                guard !value.isEmpty, let path = value.existingFilePath else {
                    return
                }
                workdir = path.string
            }
        )
    }

    var body: some View {
        Form {
            Toggle("Show menubar icon", isOn: $showMenubarIcon)
            LaunchAtLogin.Toggle()
            Toggle("Sync settings with other Macs via iCloud", isOn: $syncSettingsCloud)

            Section(header: SectionHeader(title: "Clipboard")) {
                Toggle(isOn: $enableClipboardOptimiser) {
                    Text("Enable clipboard optimiser").regular(13)
                        + Text("\nWatch for copied data and optimise it automatically").round(11, weight: .regular).foregroundColor(.secondary)
                }
                Group {
                    Toggle(isOn: .constant(true)) {
                        Text("Image data").regular(13)
                            + Text("\nCopied image data (e.g. screenshots)").round(11, weight: .regular).foregroundColor(.secondary)
                    }.disabled(true)
                    Toggle(isOn: $optimiseTIFF) {
                        Text("TIFF data").regular(13)
                            + Text("\nUsually from graphical design apps, sometimes better left alone").round(11, weight: .regular).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $optimiseImagePathClipboard) {
                        Text("Image files").regular(13)
                            + Text("\nCopying images from Finder results in file paths instead of image data").round(11, weight: .regular).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $optimiseVideoClipboard) {
                        Text("Video files").regular(13)
                            + Text("\nOptimise copied video file paths").round(11, weight: .regular).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $optimiseAudioClipboard) {
                        Text("Audio files").regular(13)
                            + Text("\nOptimise copied audio file paths").round(11, weight: .regular).foregroundColor(.secondary)
                    }
                    Toggle(isOn: $optimisePDFClipboard) {
                        Text("PDF files").regular(13)
                            + Text("\nOptimise copied PDF file paths").round(11, weight: .regular).foregroundColor(.secondary)
                    }
                }
                .disabled(!enableClipboardOptimiser)
                .padding(.leading, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored apps").regular(13)
                    Text("Skip clipboard optimisation when one of these apps is in the foreground")
                        .round(11, weight: .regular)
                        .foregroundColor(.secondary)
                    IgnoredAppsPicker(bundleIds: $clipboardIgnoredAppBundleIds, enabled: enableClipboardOptimiser)
                        .padding(.top, 2)
                }
                .padding(.leading, 20)
                .disabled(!enableClipboardOptimiser)
                .opacity(enableClipboardOptimiser ? 1 : 0.6)

                Toggle(isOn: $appendClipboardResults) {
                    Text("Keep all clipboard results").regular(13)
                        + Text("\nShow each clipboard optimisation as a separate result instead of replacing the previous one").round(11, weight: .regular).foregroundColor(.secondary)
                }.disabled(!enableClipboardOptimiser)
                if appendClipboardResults {
                    Toggle(isOn: $copyConsecutiveClipboardImages) {
                        Text("Accumulate optimised images in clipboard").regular(13)
                            + Text("\nEach new optimised image is added to a file list in the clipboard, so you can paste them all at once into image editor apps like Pixelmator or Affinity, or into notes").round(11, weight: .regular)
                            .foregroundColor(.secondary)
                    }
                    .disabled(!enableClipboardOptimiser)
                    .padding(.leading, 20)

                    HStack {
                        Text("Reset after").regular(13)
                        Picker("", selection: $clipboardAccumulationTimeout) {
                            Text("10 seconds").tag(10)
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                            Text("5 minutes").tag(300)
                            Text("Never").tag(0)
                        }
                        .frame(width: 140)
                        Text("of inactivity").regular(13)
                    }
                    .padding(.leading, 20)
                }
            }

            Section(header: SectionHeader(title: "Working directory", subtitle: "Where temporary files and backups are stored and where the optimised files are saved")) {
                HStack {
                    Text("Path").regular(13).padding(.trailing, 10)
                    TextField("", text: workdirBinding)
                        .multilineTextAlignment(.center)
                        .font(.mono(12))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.gray, lineWidth: 1).scaleEffect(y: TEXT_FIELD_SCALE).offset(x: TEXT_FIELD_OFFSET))
                    Button("Reset") {
                        workdir = Defaults.Keys.workdir.defaultValue
                    }
                    .buttonStyle(.bordered)
                    .font(.regular(11))
                }

                Picker("Periodically cleanup files older than", selection: $workdirCleanupInterval) {
                    Text("10 minutes").tag(CleanupInterval.every10Minutes)
                    Text("1 hour").tag(CleanupInterval.hourly)
                    Text("12 hours").tag(CleanupInterval.every12Hours)
                    Text("1 day").tag(CleanupInterval.daily)
                    Text("3 days").tag(CleanupInterval.every3Days)
                    Text("1 week").tag(CleanupInterval.weekly)
                    Text("1 month").tag(CleanupInterval.monthly)
                    Text("never clean up").tag(CleanupInterval.never)
                }
            }

            Section(header: SectionHeader(title: "Optimisation")) {
                Toggle(isOn: $stripMetadata) {
                    Text("Strip EXIF Metadata").regular(13)
                        + Text("\nDeleted identifiable metadata from files (e.g. camera that took the photo, location, date and time etc.)").round(11, weight: .regular).foregroundColor(.secondary)
                }
                Toggle(isOn: $preserveColorMetadata) {
                    Text("Preserve color profile metadata").regular(13)
                        + Text("\nKeep color profile metadata tags untouched when stripping EXIF metadata").round(11, weight: .regular).foregroundColor(.secondary)
                }
                .padding(.leading, 20)
                .disabled(!stripMetadata)

                Toggle(isOn: $preserveDates) {
                    Text("Preserve file creation and modification dates").regular(13)
                        + Text("\nThe optimised file will have the same creation and modification dates as the original file").round(11, weight: .regular).foregroundColor(.secondary)
                }

                Picker(selection: $optimisedFileProtectionMs) {
                    Text("3 seconds").tag(3000)
                    Text("10 seconds").tag(10000)
                    Text("30 seconds").tag(30000)
                    Text("60 seconds").tag(60000)
                } label: {
                    Text("Re-optimisation loop detection window").regular(13)
                        + Text("\nIncrease if files on iCloud Drive get optimised twice").round(11, weight: .regular).foregroundColor(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 50)
        .padding(.vertical, 20)
    }
}

struct HighlightedFolderRequest: Equatable {
    let fileType: ClopFileType
    let folder: String
}

class SettingsViewManager: ObservableObject {
    @Published var tab: SettingsView.Tabs = SWIFTUI_PREVIEW ? .floating : .general
    @Published var windowOpen = false
    @Published var scrollToFileType: ClopFileType?
    @Published var highlightFolder: HighlightedFolderRequest?
}

let settingsViewManager = SettingsViewManager()

struct SettingsView: View {
    enum Tabs: Int, Hashable {
        case general, video, audio, images, pdf, dropzone, floating, keys, automation, about

        var next: Tabs {
            Tabs(rawValue: rawValue + 1) ?? .general
        }

        var previous: Tabs {
            Tabs(rawValue: rawValue - 1) ?? .automation
        }

    }

    @ObservedObject var svm = settingsViewManager

    var body: some View {
        if svm.windowOpen {
            settings
        }
    }

    var tabView: some View {
        let t = TabView(selection: $svm.tab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tabs.general)
                .fill(.topLeading)
            VideoSettingsView()
                .tabItem {
                    Label("Video", systemImage: "video")
                }
                .tag(Tabs.video)
                .fill(.topLeading)
            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }
                .tag(Tabs.audio)
                .fill(.topLeading)
            ImagesSettingsView()
                .tabItem {
                    Label("Images", systemImage: "photo")
                }
                .tag(Tabs.images)
                .fill(.topLeading)
            PDFSettingsView()
                .tabItem {
                    Label("PDF", systemImage: "doc")
                }
                .tag(Tabs.pdf)
                .fill(.topLeading)
            DropZoneSettingsView()
                .tabItem {
                    Label("Drop zone", systemImage: "square.stack")
                }
                .tag(Tabs.dropzone)
                .fill(.topLeading)
            FloatingSettingsView()
                .tabItem {
                    Label("Floating results", systemImage: "square.stack")
                }
                .tag(Tabs.floating)
                .fill(.topLeading)
            KeysSettingsView()
                .tabItem {
                    Label("Keyboard shortcuts", systemImage: "command.square")
                }
                .tag(Tabs.keys)
                .fill(.topLeading)
            AutomationSettingsView()
                .tabItem {
                    Label("Automation", systemImage: "hammer")
                }
                .tag(Tabs.automation)
                .fill(.topLeading)
            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(Tabs.about)
                .fill(.topLeading)
        }

        if #available(macOS 15.0, *) {
            return t.tabViewStyle(.grouped)
        } else {
            return t
        }
    }

    var settings: some View {
        ZStack(alignment: .topTrailing) {
            tabView
                .hfill()
                .padding(.top, 20)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
                    guard !SWIFTUI_PREVIEW, let window = notif.object as? NSWindow else { return }
                    if window.title == "Settings" {
                        log.debug("Starting settings tab key monitor")
                        tabKeyMonitor.start()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notif in
                    guard !SWIFTUI_PREVIEW, let window = notif.object as? NSWindow else { return }
                    if window.title == "Settings" {
                        log.debug("Stopping settings tab key monitor")
                        tabKeyMonitor.stop()
                    }
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
    print("tabKeyMonitor", event)
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

    if combo.modifierFlags == [.command], let num = combo.key.character.i, let tab = SettingsView.Tabs(rawValue: num - 1) {
        settingsViewManager.tab = tab
        return nil
    }
    return event
}

struct FloatingSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        FloatingSettingsView()
            .formStyle(.grouped)
            .frame(width: WINDOW_MIN_SIZE.width, height: WINDOW_MIN_SIZE.height, alignment: .topLeading)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(minWidth: WINDOW_MIN_SIZE.width, maxWidth: .infinity, minHeight: WINDOW_MIN_SIZE.height, maxHeight: .infinity)
    }
}
