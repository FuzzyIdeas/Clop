import Combine
import Defaults
import Foundation
import Lowtech
import SwiftUI

struct BatchCropButton: View {
    enum Field: Hashable {
        case width
        case height
        case name
    }

    @FocusState private var focused: Field?
    @ObservedObject var sm = SM

    @State private var tempWidth = 0
    @State private var tempHeight = 0
    @State private var isAspectRatio = false
    @State private var cropOrientation = CropOrientation.adaptive
    @State private var cropSize: CropSize?

    @State var name = ""
    @State var cropping = false

    @Default(.savedCropSizes) var savedCropSizes

    @Environment(\.preview) var preview

    @ViewBuilder var viewer: some View {
        Button("Crop") {
            withAnimation(.easeOut(duration: 0.1)) { cropping = true }
        }
        .focusable(false)
    }

    var aspectRatioPicker: some View {
        Picker("", selection: $cropOrientation) {
            Label("Portrait", systemImage: "rectangle.portrait").tag(CropOrientation.portrait)
                .help("Crop all images to a portrait orientation.")
            Label("Adaptive", systemImage: "sparkles.rectangle.stack").tag(CropOrientation.adaptive)
                .help("Crop all images to the specified size while keeping the original orientation of each image.")
            Label("Landscape", systemImage: "rectangle").tag(CropOrientation.landscape)
                .help("Crop all images to a landscape orientation.")
        }
        .pickerStyle(.segmented)
        .labelStyle(IconOnlyLabelStyle())
        .font(.heavy(10))
        .onChange(of: cropOrientation) { orientation in
            let width = orientation == .portrait ? min(tempWidth, tempHeight) : max(tempWidth, tempHeight)
            let height = orientation == .portrait ? max(tempWidth, tempHeight) : min(tempWidth, tempHeight)
            tempWidth = width
            tempHeight = height

            guard isAspectRatio, let cropSize = cropSize?.withOrientation(orientation) else {
                return
            }
            self.cropSize = cropSize
        }.disabled(!isAspectRatio)
    }

    var editor: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIZE PRESETS")
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(0.7)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 1)
                ForEach(savedCropSizes.map { $0.withOrientation(cropOrientation) }.filter(!\.isAspectRatio).sorted(by: \.area)) { size in
                    cropSizeButton(size)
                }
                HStack(spacing: 8) {
                    TextField("", text: $name, prompt: Text("Name"))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .name)
                        .frame(width: 208, alignment: .leading)

                    Button(action: {
                        guard !preview, !name.isEmpty, tempWidth > 0 || tempHeight > 0
                        else { return }

                        savedCropSizes.append(CropSize(width: tempWidth, height: tempHeight, name: name))
                    }, label: {
                        SwiftUI.Image(systemName: "plus")
                            .font(.heavy(11))
                            .foregroundColor(.mauvish)
                    })
                    .buttonStyle(.bordered)
                    .frame(width: 30)
                    .fontDesign(.rounded)
                    .disabled(name.isEmpty || (tempWidth == 0 && tempHeight == 0) || savedCropSizes.contains(where: { $0.width == tempWidth && $0.height == tempHeight }))
                }
                .disabled(isAspectRatio)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("ASPECT RATIOS")
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(0.7)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 1)
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        ForEach(DEFAULT_CROP_ASPECT_RATIOS[0 ..< 5].map { $0.withOrientation(cropOrientation) }) { size in
                            aspectRatioButton(size)
                        }
                    }
                    GridRow {
                        ForEach(DEFAULT_CROP_ASPECT_RATIOS[5 ..< 10].map { $0.withOrientation(cropOrientation) }) { size in
                            aspectRatioButton(size)
                        }
                    }
                    GridRow {
                        ForEach(DEFAULT_CROP_ASPECT_RATIOS[10 ..< 15].map { $0.withOrientation(cropOrientation) }) { size in
                            aspectRatioButton(size)
                        }
                    }
                }
            }
            aspectRatioPicker

            Divider()

            HStack {
                TextField("", value: $tempWidth, formatter: NumberFormatter(), prompt: Text("Width"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .width)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
                Text("×")
                TextField("", value: $tempHeight, formatter: NumberFormatter(), prompt: Text("Height"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .height)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
            }.disabled(isAspectRatio)

            let sizeStr = isAspectRatio ? (cropSize?.name ?? "\(tempWidth):\(tempHeight)") : "\(tempWidth == 0 ? "Auto" : tempWidth.s)×\(tempHeight == 0 ? "Auto" : tempHeight.s)"
            Button("Crop and resize to \(sizeStr)") {
                guard !preview, tempWidth > 0 || tempHeight > 0 || isAspectRatio else { return }

                if isAspectRatio, let cropSize {
                    for id in sm.selection {
                        guard let optimiser = opt(id), optimiser.canCrop() else { continue }
                        optimiser.crop(to: cropSize.withOrientation(cropOrientation))
                    }
                } else if tempWidth != 0, tempHeight != 0 {
                    for id in sm.selection {
                        guard let optimiser = opt(id), optimiser.canCrop() else { continue }
                        optimiser.crop(to: CropSize(width: tempWidth, height: tempHeight))
                    }
                } else {
                    for id in sm.selection {
                        guard let optimiser = opt(id), let size = optimiser.oldSize, optimiser.canDownscale() else { continue }
                        optimiser.downscale(toFactor: tempWidth == 0 ? tempHeight.d / size.height.d : tempWidth.d / size.width.d)
                    }
                }
                sm.selection = []
            }
            .buttonStyle(.bordered)
            .fontDesign(.rounded)
            .monospacedDigit()
            .disabled(tempWidth == 0 && tempHeight == 0 && !isAspectRatio)
        }
        .padding()
        .defaultFocus($focused, .width)
    }

    @State private var lastFocusState: Field?

    @ViewBuilder func aspectRatioButton(_ size: CropSize) -> some View {
        let selected = isAspectRatio && cropSize?.name == size.name
        Button(action: {
            isAspectRatio = true
            cropSize = size.withOrientation(cropOrientation)
        }, label: {
            Text(size.name)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .chipBackground(selected: selected)
        })
        .buttonStyle(.plain)
    }

    @ViewBuilder var editorViewer: some View {
        viewer
            .popover(isPresented: $cropping, arrowEdge: .bottom) {
                PaddedPopoverView(background: Color(light: Color.white, dark: Color.black).any) {
                    editor
                        .buttonStyle(FlatButton(color: .primary.opacity(colorScheme == .dark ? 0.08 : 0.10), textColor: .primary, radius: 5, horizontalPadding: 3, verticalPadding: 1))
                        .font(.mono(11, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
    }

    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        editorViewer
            .onChange(of: sm.selecting) { selecting in
                if !selecting {
                    cropping = false
                }
            }
    }

    @ViewBuilder func cropSizeButton(_ size: CropSize) -> some View {
        let selected = !isAspectRatio && tempWidth == size.width && tempHeight == size.height
        HStack(spacing: 6) {
            Button(action: {
                isAspectRatio = false
                tempWidth = size.width
                tempHeight = size.height
                cropSize = size
            }, label: {
                HStack {
                    Text(size.name)
                        .allowsTightening(false)
                        .fontDesign(.rounded)
                    Spacer()
                    Text(size.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .allowsTightening(false)
                }
                .frame(width: 190)
                .lineLimit(1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .chipBackground(selected: selected)
            })
            .buttonStyle(.plain)

            Button(action: {
                withAnimation(.easeOut(duration: 0.1)) {
                    savedCropSizes.removeAll(where: { $0.id == size.id })
                }
            }, label: {
                SwiftUI.Image(systemName: "trash")
                    .foregroundColor(.red)
            })
            .frame(width: 30)
            .buttonStyle(.bordered)
        }
    }

}

private extension View {
    @ViewBuilder func chipBackground(selected: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
