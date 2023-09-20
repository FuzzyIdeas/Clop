import Defaults
import Foundation
import Lowtech
import SwiftUI

extension Defaults.Keys {
    static let shortcutToRunOnImage = Key<[String: String]>("shortcutToRunOnImage", default: [:])
    static let shortcutToRunOnVideo = Key<[String: String]>("shortcutToRunOnVideo", default: [:])
    static let shortcutToRunOnPdf = Key<[String: String]>("shortcutToRunOnPdf", default: [:])
}

func getShortcuts() -> [String: String]? {
    guard let output = shell("/usr/bin/shortcuts", args: ["list", "--show-identifiers"], timeout: 2).o else {
        return nil
    }

    let lines = output.split(separator: "\n")
    var shortcuts: [String: String] = [:]
    for line in lines {
        let parts = line.split(separator: " ")
        guard let identifier = parts.last?.trimmingCharacters(in: ["(", ")"]) else {
            continue
        }
        let name = parts.dropLast().joined(separator: " ")
        shortcuts[identifier] = name
    }
    return shortcuts.isEmpty ? nil : shortcuts
}

func runShortcut(_ shortcut: String, _ file: String) -> Process? {
    let proc = shellProc("/usr/bin/shortcuts", args: ["run", shortcut, "--input-path", file])
    return proc
}

struct ShortcutsIcon: View {
    var size: CGFloat = 20

    var body: some View {
        VStack(spacing: -size / 1.8) {
            RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(hue: 0.02, saturation: 0.61, brightness: 0.89, opacity: 1.00), location: 0),
                    .init(color: Color(hue: 0.87, saturation: 0.51, brightness: 0.89, opacity: 0.9), location: 0.5),
                    .init(color: Color(hue: 0.87, saturation: 0.51, brightness: 0.89, opacity: 0.3), location: 0.9),
                ], startPoint: .leading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.7), radius: size / 4, y: 2)
                .rotationEffect(.degrees(-45))
                .scaleEffect(y: 0.85)
            RoundedRectangle(cornerRadius: size / 3, style: .continuous)
                .fill(LinearGradient(stops: [
                    .init(color: Color(hue: 0.59, saturation: 0.49, brightness: 0.48, opacity: 1.00), location: 0),
                    .init(color: Color(hue: 0.46, saturation: 0.46, brightness: 0.74, opacity: 0.9), location: 0.5),
                    .init(color: Color(hue: 0.61, saturation: 0.76, brightness: 0.94, opacity: 1.00), location: 0.9),
                ], startPoint: .top, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-45))
                .scaleEffect(y: 0.85)
                .zIndex(-1)
        }
    }
}

struct AutomationRowView: View {
    @Binding var shortcuts: [String: String]

    var shortcutsList: [[String: String].Element]
    var icon: String
    var type: String
    var color: Color
    var sources: [String] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("On optimised")
                HStack {
                    SwiftUI.Image(systemName: icon).frame(width: 14)
                    Text(type)
                }.roundbg(radius: 6, color: color.opacity(0.1), noFG: true)
                Spacer()
                Link(destination: "shortcuts://create-shortcut".url!, label: {
                    HStack {
                        ShortcutsIcon(size: 12)
                        Text("New Shortcut")
                    }
                })
                .buttonStyle(FlatButton(color: .mauve.opacity(0.8), textColor: .white))
                .help("Opens the Shortcuts app to create a new shortcut")
                .font(.medium(12))
                .saturation(1.5)
            }
            ForEach(sources, id: \.self) { s in
                picker(source: s)
                    .padding(.leading)
            }
        }
    }

    @ViewBuilder
    func picker(source: String) -> some View {
        let binding = Binding<String?>(
            get: { shortcuts[source] },
            set: {
                if let shortcut = $0 {
                    shortcuts = shortcuts.copyWith(key: source, value: shortcut)
                } else {
                    shortcuts = shortcuts.copyWithout(key: source)
                }
            }
        )

        HStack {
            Picker(
                selection: binding,
                content: {
                    Text("do nothing").tag(nil as String?)
                    Divider()
                    ForEach(shortcutsList, id: \.key) { el in
                        if el.value.count > 30 {
                            Text("\(el.value)").tag(el.key as String?)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("run the \"\(el.value)\" Shortcut").tag(el.key as String?)
                        }
                    }
                },
                label: {
                    (Text("from  ").round(12, weight: .regular).foregroundColor(.secondary) + Text(source.replacingOccurrences(of: HOME.string, with: "~")).mono(12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            )
            Button("\(SwiftUI.Image(systemName: binding.wrappedValue == nil ? "hammer" : "hammer.fill"))") {
                if let shortcut = binding.wrappedValue {
                    NSWorkspace.shared.open("shortcuts://open-shortcut?id=\(shortcut)".url!)
                }
            }
            .help("Opens the shortcut in the Shortcuts app for editing")
            .buttonStyle(FlatButton())
            .disabled(binding.wrappedValue == nil)
        }
    }
}

struct AutomationSettingsView: View {
    @Default(.shortcutToRunOnImage) var shortcutToRunOnImage
    @Default(.shortcutToRunOnVideo) var shortcutToRunOnVideo
    @Default(.shortcutToRunOnPdf) var shortcutToRunOnPdf

    @Default(.enableDragAndDrop) var enableDragAndDrop
    @Default(.optimiseVideoClipboard) var optimiseVideoClipboard
    @Default(.optimiseImagePathClipboard) var optimiseImagePathClipboard
    @Default(.enableClipboardOptimiser) var enableClipboardOptimiser

    @State var shortcuts: [String: String] = [:]

    var body: some View {
        let shortcutsList = shortcuts.map { $0 }.sorted(by: \.1)
        let imageSources = ((enableClipboardOptimiser || optimiseImagePathClipboard) ? ["clipboard"] : []) + (enableDragAndDrop ? ["drop zone"] : []) + Defaults[.imageDirs]
        let videoSources = (optimiseVideoClipboard ? ["clipboard"] : []) + (enableDragAndDrop ? ["drop zone"] : []) + Defaults[.videoDirs]
        let pdfSources = (enableDragAndDrop ? ["drop zone"] : []) + Defaults[.pdfDirs]

        Form {
            Section(header: SectionHeader(title: "Shortcuts")) {
                if imageSources.isNotEmpty {
                    AutomationRowView(
                        shortcuts: $shortcutToRunOnImage,
                        shortcutsList: shortcutsList,
                        icon: "photo", type: "image",
                        color: .calmBlue,
                        sources: imageSources
                    )
                }
                if videoSources.isNotEmpty {
                    AutomationRowView(
                        shortcuts: $shortcutToRunOnVideo,
                        shortcutsList: shortcutsList,
                        icon: "video", type: "video",
                        color: .red,
                        sources: videoSources
                    )
                }
                if pdfSources.isNotEmpty {
                    AutomationRowView(
                        shortcuts: $shortcutToRunOnPdf,
                        shortcutsList: shortcutsList,
                        icon: "doc.text.magnifyingglass", type: "PDF",
                        color: .burntSienna,
                        sources: pdfSources
                    )
                }
            }
        }.padding(4)
            .onAppear {
                DispatchQueue.global().async {
                    guard let shortcuts = getShortcuts() else {
                        return
                    }
                    mainActor {
                        self.shortcuts = shortcuts
                    }
                }
            }
    }
}

struct AutomationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AutomationSettingsView()
            .frame(minWidth: 850, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
            .formStyle(.grouped)
    }
}
