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
                .help("Crop all images to the specified aspect ratio while keeping the original orientation of each image.")
            Label("Landscape", systemImage: "rectangle").tag(CropOrientation.landscape)
                .help("Crop all images to a landscape orientation.")
        }
        .pickerStyle(.segmented)
        .labelStyle(IconOnlyLabelStyle())
        .font(.heavy(10))
        .onChange(of: cropOrientation) { orientation in
            guard isAspectRatio, let cropSize = cropSize?.withOrientation(orientation) else {
                return
            }
            self.cropSize = cropSize
        }
    }

    var editor: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading) {
                Text("Size presets")
                    .heavy(10)
                    .foregroundColor(.secondary)
                ForEach(savedCropSizes.filter(!\.isAspectRatio).sorted(by: \.area)) { size in
                    cropSizeButton(size)
                }
                if !isAspectRatio {
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
                        .disabled(name.isEmpty || (tempWidth == 0 && tempHeight == 0))
                    }
                }
            }

            Divider()
            VStack(alignment: .leading) {
                Text("Aspect ratios")
                    .heavy(10)
                    .foregroundColor(.secondary)
                Grid(alignment: .leading) {
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
            if isAspectRatio {
                aspectRatioPicker
            }

            Divider()

            if !isAspectRatio {
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
                }
            }

            let sizeStr = isAspectRatio ? (cropSize?.name ?? "\(tempWidth):\(tempHeight)") : "\(tempWidth == 0 ? "Auto" : tempWidth.s)×\(tempHeight == 0 ? "Auto" : tempHeight.s)"
            Button("Crop and resize to \(sizeStr)") {
                guard !preview, tempWidth > 0 || tempHeight > 0 || isAspectRatio else { return }

                if isAspectRatio, let cropSize {
                    for id in sm.selection {
                        guard let optimiser = opt(id) else { continue }
                        optimiser.crop(to: cropSize.withOrientation(cropOrientation))
                    }
                } else if tempWidth != 0, tempHeight != 0 {
                    for id in sm.selection {
                        opt(id)?.crop(to: CropSize(width: tempWidth, height: tempHeight))
                    }
                } else {
                    for id in sm.selection {
                        guard let optimiser = opt(id), let size = optimiser.oldSize else { continue }
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
        Button(size.name) {
            isAspectRatio = true
            cropSize = size.withOrientation(cropOrientation)
        }.buttonStyle(.bordered)
    }

    @ViewBuilder var editorViewer: some View {
        viewer
            .popover(isPresented: $cropping, arrowEdge: .bottom) {
                PaddedPopoverView(background: Color.bg.warm.any) {
                    editor
                        .buttonStyle(FlatButton(color: .primary.opacity(colorScheme == .dark ? 0.05 : 0.13), textColor: .fg.warm, radius: 4, horizontalPadding: 3, verticalPadding: 1))
                        .font(.mono(11, weight: .medium))
                        .foregroundColor(.fg.warm)
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
        HStack(spacing: 10) {
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
                        .monospaced()
                        .allowsTightening(false)
                }
                .frame(width: 190)
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
            .frame(width: 30)
            .buttonStyle(.bordered)
        }
    }

}
