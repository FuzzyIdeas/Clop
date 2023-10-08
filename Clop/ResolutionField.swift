import Defaults
import Foundation
import Lowtech
import SwiftUI

struct ResolutionField: View {
    @ObservedObject var optimiser: Optimiser
    @FocusState var focused: Bool

    @State var tempWidth = 0
    @State var tempHeight = 0
    @State var size: NSSize = .zero
    @State var name = ""

    @Default(.savedCropSizes) var savedCropSizes

    @Environment(\.preview) var preview

    @ViewBuilder var viewer: some View {
        Button(
            action: {
                withAnimation(.easeOut(duration: 0.1)) { optimiser.editingResolution = true }
            },
            label: {
                HStack(spacing: 3) {
                    Text("\(size.width.i)×\(size.height.i)")
                    if let newSize = optimiser.newSize, newSize != size {
                        SwiftUI.Image(systemName: "arrow.right")
                        Text("\(newSize.width.i)×\(newSize.height.i)")
                    }
                }
                .lineLimit(1)
            }
        )
    }

    var editor: some View {
        VStack {
            HStack {
                TextField("", value: $tempWidth, formatter: NumberFormatter(), prompt: Text("Width"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .defaultFocus($focused, true)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
                Text("×")
                TextField("", value: $tempHeight, formatter: NumberFormatter(), prompt: Text("Height"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            Text("Width and height need to be\nsmaller than the original size")
                .round(10)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 5)

            VStack(alignment: .leading) {
                ForEach(savedCropSizes.filter { $0.width <= size.width.i && $0.height <= size.height.i }.sorted(by: \.area)) { size in
                    cropSizeButton(size)
                }
            }

            Divider()

            Button("Crop and resize to \(tempWidth)×\(tempHeight)") {
                guard !preview else { return }
                optimiser.crop(to: NSSize(width: tempWidth, height: tempHeight))
            }
            .buttonStyle(.bordered)
            .fontDesign(.rounded)
            .monospacedDigit()

            HStack {
                TextField("", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100, alignment: .leading)
                Button("Save") {
                    guard !preview, !name.isEmpty, tempWidth > 0, tempHeight > 0
                    else { return }

                    savedCropSizes.append(CropSize(width: tempWidth, height: tempHeight, name: name))
                }
                .buttonStyle(.bordered)
                .fontDesign(.rounded)
            }
        }
        .padding()
    }

    @ViewBuilder var editorViewer: some View {
        viewer
            .onAppear {
                guard let size = optimiser.oldSize else { return }
                tempWidth = size.width.i
                tempHeight = size.height.i
                self.size = size
            }
            .onChange(of: optimiser.oldSize) { size in
                guard let size else { return }
                tempWidth = size.width.i
                tempHeight = size.height.i
                self.size = size
            }
            .popover(isPresented: $optimiser.editingResolution, arrowEdge: .bottom) {
                editor
                    .onChange(of: tempWidth) { width in
                        if let size = optimiser.oldSize, width > size.width.i {
                            tempWidth = size.width.i
                        }
                    }
                    .onChange(of: tempHeight) { height in
                        if let size = optimiser.oldSize, height > size.height.i {
                            tempHeight = size.height.i
                        }
                    }
                    .foregroundColor(.primary)
            }
    }

    var body: some View {
        editorViewer
            .onChange(of: optimiser.running) { running in
                if running {
                    optimiser.editingResolution = false
                }
            }
    }

    @ViewBuilder func cropSizeButton(_ size: CropSize) -> some View {
        HStack {
            Button(action: {
                tempWidth = size.width
                tempHeight = size.height
            }, label: {
                HStack {
                    Text(size.name)
                        .allowsTightening(false)
                        .fontDesign(.rounded)
                    Spacer()
                    Text(size.id)
                        .monospaced()
                        .allowsTightening(false)
                }
                .frame(width: 150)
                .lineLimit(1)
            })
            .buttonStyle(.bordered)

            Button(action: {
                withAnimation(.easeOut(duration: 0.1)) {
                    savedCropSizes.removeAll(where: { $0.id == size.id })
                }
            }, label: {
                SwiftUI.Image(systemName: "trash")
                    .foregroundColor(.red)
            })
            .buttonStyle(.bordered)

        }
    }

}

struct CropSize: Codable, Hashable, Defaults.Serializable, Identifiable {
    let width: Int
    let height: Int
    let name: String

    var id: String { "\(width)×\(height)" }
    var area: Int { width * height }
}
