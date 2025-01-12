import Defaults
import Foundation
import Lowtech
import SwiftUI

struct PresetZone: Codable, Hashable, Identifiable, Defaults.Serializable {
    init(name: String, icon: String, type: ClopFileType? = nil, shortcut: Shortcut) {
        self.name = name
        self.icon = icon
        self.type = type
        self.shortcut = shortcut
        id = "\(name)-\(type?.rawValue ?? "all")"
    }

    let id: String
    let icon: String
    let name: String
    let type: ClopFileType?
    let shortcut: Shortcut

}

struct DropZoneSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            DropZoneSettingsView()
                .formStyle(.grouped)
                .padding()
        }
        .frame(minWidth: WINDOW_MIN_SIZE.width, maxWidth: .infinity, minHeight: WINDOW_MIN_SIZE.height, maxHeight: .infinity)
    }
}

struct PresetZoneEditor: View {
    @Binding var zone: PresetZone?

    @State var icon = "wand.and.sparkles"
    @State var name = ""
    @State var shortcut: Shortcut? = nil
    @State var type: ClopFileType? = nil

    var onSubmit: (() -> Void)? = nil

    @Default(.presetZones) var presetZones

    var body: some View {
        HStack(spacing: 6) {
            IconPickerView(icon: $icon)
                .frame(width: 30, alignment: .center)
            Divider().foregroundColor(.secondary)

            TextField("", text: $name, prompt: Text("Name"))
                .frame(width: 100, alignment: .leading)
            Divider().foregroundColor(.secondary)

            Picker("", selection: $type) {
                Text("any file").tag(nil as ClopFileType?)
                ForEach(ClopFileType.allCases, id: \.self) { type in
                    Text("\(type.description)s").tag(type)
                }
            }
            .fixedSize()
            .frame(width: 100, alignment: .trailing)
            Divider().foregroundColor(.secondary)

            shortcutPicker().frame(width: 150, alignment: .trailing)
            Divider().foregroundColor(.secondary)
            Spacer()

            Button(
                action: {
                    guard !name.isEmpty, let shortcut else { return }
                    if let zone {
                        presetZones = presetZones.replacing(zone, with: PresetZone(name: name, icon: icon, type: type, shortcut: shortcut))
                        self.zone = nil
                    } else {
                        presetZones.append(PresetZone(name: name, icon: icon, type: type, shortcut: shortcut))
                    }
                    setFields(zone: nil)
                    onSubmit?()
                },
                label: { SwiftUI.Image(systemName: zone == nil ? "plus" : "checkmark").fontWeight(.bold) }
            )
            .frame(width: 30)
            .disabled(name.isEmpty || shortcut == nil)
            .help(zone == nil ? "Add this preset zone" : "Save preset zone")

            Button(
                action: {
                    zone = nil
                    setFields(zone: nil)
                    onSubmit?()
                },
                label: { SwiftUI.Image(systemName: "xmark").fontWeight(.bold).foregroundColor(.yellow) }
            )
            .frame(width: 30)
            .help("Cancel editing")
        }
        .roundbg(radius: 10, verticalPadding: 4, horizontalPadding: 4, color: .fg.warm.opacity(0.05))
        .onAppear {
            if let zone {
                setFields(zone: zone)
            }
        }
        .onChange(of: zone) { [zone] newZone in
            if let zone = newZone {
                setFields(zone: zone)
            } else if zone != nil {
                setFields(zone: nil)
            }
        }

    }

    @ViewBuilder func shortcutPicker() -> some View {
        let binding = Binding<Shortcut?>(
            get: { shortcut },
            set: {
                if let shortcut = $0, let url = shortcut.identifier.url {
                    NSWorkspace.shared.open(url)
                    return
                }

                shortcut = $0
            }
        )

        Picker(
            "",
            selection: binding,
            content: {
                Text("do nothing").tag(nil as Shortcut?)
                Divider()
                ShortcutChoiceMenu()
                DefaultShortcutList()
            }
        )
        .fixedSize()
    }

    func setFields(zone: PresetZone?) {
        icon = zone?.icon ?? "wand.and.sparkles"
        name = zone?.name ?? ""
        shortcut = zone?.shortcut
        type = zone?.type
    }

}
