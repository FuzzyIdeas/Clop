import Combine
import Defaults
import Foundation
import Lowtech
import SwiftUI

struct ResolutionField: View {
    enum Field: Hashable {
        case width
        case height
        case name
    }

    @ObservedObject var optimiser: Optimiser
    @FocusState private var focused: Field?

    @State private var tempWidth = 0
    @State private var tempHeight = 0
    @State private var isAspectRatio = false
    @State private var cropOrientation = CropOrientation.adaptive
    @State private var cropSize: CropSize?

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
                    let hideOldSize = OM.compactResults && optimiser.newBytes > 0 && optimiser.newSize != nil && optimiser.newSize! != size // && (optimiser.newSize!.s + size.s).count > 14
                    if !hideOldSize {
                        Text(size == .zero ? "Crop" : "\(size.width.i.s)×\(size.height.i.s)")
                    }
                    if let newSize = optimiser.newSize, newSize != size {
                        if !hideOldSize {
                            SwiftUI.Image(systemName: "arrow.right")
                        }
                        Text("\(newSize.width.i.s)×\(newSize.height.i.s)")
                    }
                }
                .lineLimit(1)
            }
        )
        .focusable(false)
    }

    var aspectRatioPicker: some View {
        Picker("", selection: $cropOrientation) {
            Label("Portrait", systemImage: "rectangle.portrait").tag(CropOrientation.portrait)
                .help("Crop the \(optimiser.type.str) to a portrait orientation.")
            if optimiser.type.isPDF {
                Label("Adaptive", systemImage: "sparkles.rectangle.stack").tag(CropOrientation.adaptive)
                    .help("Crop all pages to the specified size while keeping the original orientation of each page.")
            }
            Label("Landscape", systemImage: "rectangle").tag(CropOrientation.landscape)
                .help("Crop the \(optimiser.type.str) to a landscape orientation.")
        }
        .pickerStyle(.segmented)
        .labelStyle(IconOnlyLabelStyle())
        .font(.heavy(10))
        .onChange(of: cropOrientation) { orientation in
            guard let cropSize = cropSize?.withOrientation(orientation) else {
                if orientation == .landscape {
                    let width = max(tempWidth, tempHeight)
                    let height = min(tempWidth, tempHeight)
                    tempWidth = width
                    tempHeight = height
                } else if orientation == .portrait {
                    let width = min(tempWidth, tempHeight)
                    let height = max(tempWidth, tempHeight)
                    tempWidth = width
                    tempHeight = height
                }
                cropSize = cropSize?.withOrientation(cropOrientation)
                return
            }
            self.cropSize = cropSize
            let size = cropSize.computedSize(from: size)
            tempWidth = size.width.evenInt
            tempHeight = size.height.evenInt
        }
    }

    @ViewBuilder var framingPicker: some View {
        if optimiser.type.isImage {
            Picker("", selection: $smartCrop) {
                Text("Smart").tag(true)
                    .help("Crop the image by keeping elements that catch attention.")
                Text("Center").tag(false)
                    .help("Crop the margins and keep the center of the image.")
            }
            .pickerStyle(.segmented)
            .scaleEffect(x: 0.75, y: 0.75, anchor: .trailing)
        }
    }

    var saveField: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .trailing) {
                TextField("", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .frame(width: 198, alignment: .leading)
                Text("\(tempWidth == 0 ? "Auto" : tempWidth.s)×\(tempHeight == 0 ? "Auto" : tempHeight.s)")
                    .monospaced()
                    .allowsTightening(false)
                    .opacity(0.5)
                    .padding(.trailing, 10)
            }

            Button(action: {
                guard !preview, !name.isEmpty, tempWidth > 0 || tempHeight > 0
                else { return }

                savedCropSizes.append(CropSize(width: tempWidth, height: tempHeight, name: name))
            }, label: {
                SwiftUI.Image(systemName: "plus")
                    .font(.heavy(10))
                    .foregroundColor(.mauvish)
            })
            .buttonStyle(.bordered)
            .fontDesign(.rounded)
            .disabled(name.isEmpty || (tempWidth == 0 && tempHeight == 0) || savedCropSizes.contains(where: { $0.width == tempWidth && $0.height == tempHeight }))
        }
    }

    var aspectRatios: some View {
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
    }

    var pdfSizes: some View {
        VStack(alignment: .leading) {
            Text("Paper size").heavy(10).foregroundColor(.secondary)
            Picker("", selection: $cropSize) {
                Text("No selection").tag(nil as CropSize?)
                Divider()
                ForEach(Array(PAPER_CROP_SIZES.keys.sorted()), id: \.self) { paperType in
                    Section(paperType) {
                        ForEach(Array(PAPER_CROP_SIZES[paperType]!.keys.sorted())) { paper in
                            Text(paper).tag(PAPER_CROP_SIZES[paperType]![paper]?.withOrientation(cropOrientation, for: size))
                        }
                    }
                }
            }.font(.medium(10))
            Text("Device size").heavy(10).foregroundColor(.secondary)
            Picker("", selection: $cropSize) {
                Text("No selection").tag(nil as CropSize?)
                Divider()
                ForEach(Array(DEVICE_CROP_SIZES.keys.sorted()), id: \.self) { deviceType in
                    Section(deviceType) {
                        ForEach(Array(DEVICE_CROP_SIZES[deviceType]!.keys.sorted())) { device in
                            Text(device).tag(DEVICE_CROP_SIZES[deviceType]![device]?.withOrientation(cropOrientation, for: size))
                        }
                    }
                }
            }.font(.medium(10))
            Text("Aspect ratio").heavy(10).foregroundColor(.secondary)
            Picker("", selection: $cropSize) {
                Text("No selection").tag(nil as CropSize?)
                Divider()
                ForEach(DEFAULT_CROP_ASPECT_RATIOS.filter { $0.name != "A4" && $0.name != "B5" }.map { $0.withOrientation(cropOrientation, for: size) }) { size in
                    Text(size.name).tag(size as CropSize?)
                }
            }.font(.medium(10))
        }
        .onChange(of: cropSize) { size in
            guard let newSize = size?.computedSize(from: self.size) else {
                return
            }
            tempWidth = newSize.width.evenInt
            tempHeight = newSize.height.evenInt
        }
    }

    @ViewBuilder var uncropButton: some View {
        if let pdf = optimiser.pdf, let originalSize = pdf.originalSize, originalSize != size {
            Button("Uncrop to \(originalSize.s)") {
                pdf.uncrop()
                optimiser.oldSize = originalSize
                optimiser.newSize = nil
            }
        }
    }

    @State private var smartCrop = true

    var editor: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading) {
                if optimiser.type.isPDF {
                    pdfSizes
                } else {
                    Text("Size presets").heavy(10).foregroundColor(.secondary)
                    ForEach(savedCropSizes.map { $0.withOrientation(cropOrientation) }.filter { !$0.isAspectRatio }.sorted(by: \.area)) { size in
                        cropSizeButton(size).disabled(size.width > self.size.width.i || size.height > self.size.height.i)
                    }
                    cropSizeButton(CropSize(width: size.width, height: size.height, name: "Default size"))
                    if !isAspectRatio, !savedCropSizes.contains(where: { $0.width == tempWidth && $0.height == tempHeight }) {
                        saveField
                    }
                    if !savedCropSizes.contains(DEFAULT_CROP_SIZES) {
                        Button("Bring back default sizes") {
                            Defaults[.savedCropSizes] = DEFAULT_CROP_SIZES + Defaults[.savedCropSizes].without(DEFAULT_CROP_SIZES)
                        }
                    }
                }

            }

            if !optimiser.type.isPDF {
                Divider()
                aspectRatios
            }
            Divider()

            HStack {
                TextField("", value: $tempWidth, formatter: NumberFormatter.int, prompt: Text("Width"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .width)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
                    .disabled(isAspectRatio && !optimiser.type.isPDF)
                Text(isAspectRatio ? ":" : "×")
                TextField("", value: $tempHeight, formatter: NumberFormatter.int, prompt: Text("Height"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .height)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
                    .disabled(isAspectRatio && !optimiser.type.isPDF)
                aspectRatioPicker.frame(width: 100).padding(.leading, 10)
            }

            HStack {
                Button("1.5x") {
                    tempWidth = (tempWidth.d * 1.5).evenInt
                    tempHeight = (tempHeight.d * 1.5).evenInt
                }.disabled(tempWidth.d * 1.5 > size.width || tempHeight.d * 1.5 > size.height)
                Button("2x") {
                    tempWidth = (tempWidth.d * 2).evenInt
                    tempHeight = (tempHeight.d * 2).evenInt
                }.disabled(tempWidth * 2 > size.width.i || tempHeight * 2 > size.height.i)
                Button("3x") {
                    tempWidth = (tempWidth.d * 3).evenInt
                    tempHeight = (tempHeight.d * 3).evenInt
                }.disabled(tempWidth * 3 > size.width.i || tempHeight * 3 > size.height.i)
                framingPicker
            }
            cropButton.fixedSize()

            uncropButton
        }
        .padding()
        .defaultFocus($focused, .width)
    }

    @ViewBuilder var cropButton: some View {
        let sizeStr = isAspectRatio ? (cropSize?.name ?? "\(tempWidth):\(tempHeight)") : "\(tempWidth == 0 ? "Auto" : tempWidth.s)×\(tempHeight == 0 ? "Auto" : tempHeight.s)"
        Button("Crop and resize to \(sizeStr)") {
            guard !preview, tempWidth > 0 || tempHeight > 0 else { return }

            if let pdf = optimiser.pdf {
                let lastOrientation = cropOrientation
                let size = CropSize(width: tempWidth, height: tempHeight).withOrientation(cropOrientation)
                pdf.cropTo(aspectRatio: size.fractionalAspectRatio, alwaysPortrait: cropOrientation == .portrait, alwaysLandscape: cropOrientation == .landscape)
                cropOrientation = lastOrientation
                optimiser.refetch()
                optimiser.oldSize = optimiser.pdf?.originalSize ?? size.computedSize(from: self.size)
                optimiser.newSize = optimiser.pdf?.size
                optimiser.editingResolution = false
                return
            }

            if isAspectRatio {
                optimiser.crop(to: CropSize(
                    width: cropOrientation == .adaptive ? tempWidth : (cropOrientation == .landscape ? max(tempWidth, tempHeight) : min(tempWidth, tempHeight)),
                    height: cropOrientation == .adaptive ? tempHeight : (cropOrientation == .portrait ? max(tempWidth, tempHeight) : min(tempWidth, tempHeight)),
                    longEdge: cropOrientation == .adaptive, smartCrop: smartCrop, isAspectRatio: true
                ))
            } else if tempWidth != 0, tempHeight != 0 {
                optimiser.crop(to: CropSize(width: tempWidth, height: tempHeight, smartCrop: smartCrop).withOrientation(cropOrientation))
            } else {
                optimiser.downscale(toFactor: tempWidth == 0 ? tempHeight.d / size.height.d : tempWidth.d / size.width.d)
            }
        }
        .buttonStyle(.bordered)
        .fontDesign(.rounded)
        .monospacedDigit()
        .disabled(optimiser.running || (tempWidth == 0 && tempHeight == 0))
    }

    @State private var hoveringHelpButton = false
    @State private var lastFocusState: Field?

    @ViewBuilder var editorViewer: some View {
        viewer
            .onAppear {
                guard let size = optimiser.oldSize else { return }
                tempWidth = size.width.i
                tempHeight = size.height.i
                cropOrientation = optimiser.type.isPDF ? .adaptive : size.orientation
                isAspectRatio = optimiser.type.isPDF
                self.size = size
            }
            .onChange(of: optimiser.oldSize) { size in
                guard let size else { return }
                tempWidth = size.width.i
                tempHeight = size.height.i
                cropOrientation = optimiser.type.isPDF ? .adaptive : size.orientation
                isAspectRatio = optimiser.type.isPDF
                self.size = size
            }
            .popover(isPresented: $optimiser.editingResolution, arrowEdge: .bottom) {
                PaddedPopoverView(background: Color.bg.warm.any) {
                    ZStack(alignment: .bottomTrailing) {
                        editor
                        SwiftUI.Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(5)
                            .onHover { hovering in
                                hoveringHelpButton = hovering
                            }
                            .helpTag(
                                isPresented: $hoveringHelpButton,
                                alignment: .bottomTrailing,
                                offset: CGSize(width: -5, height: -25),
                                """
                                Width and height need to be smaller
                                than the original size.

                                Set the width or height to 0 to have it
                                calculated automatically while keeping
                                the original aspect ratio.
                                """
                            )
                    }
                    .onChange(of: tempWidth) { width in
                        if let size = optimiser.oldSize, width > size.width.evenInt {
                            tempWidth = size.width.evenInt
                        }
                    }
                    .onChange(of: tempHeight) { height in
                        if let size = optimiser.oldSize, height > size.height.evenInt {
                            tempHeight = size.height.evenInt
                        }
                    }
                    .foregroundColor(.fg.warm)
                }
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

    @ViewBuilder func aspectRatioButton(_ size: CropSize) -> some View {
        Button(size.name) {
            isAspectRatio = true
            cropSize = size.withOrientation(cropOrientation)

            let newSize = (cropSize ?? size).computedSize(from: self.size)
            tempWidth = newSize.width.evenInt
            tempHeight = newSize.height.evenInt
        }.buttonStyle(.bordered)
    }

    @ViewBuilder func cropSizeButton(_ size: CropSize, noDelete: Bool = false) -> some View {
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
                .frame(width: 180)
                .lineLimit(1)
            })
            .buttonStyle(.bordered)

            Button(action: {
                guard !preview else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    savedCropSizes.removeAll(where: { $0.id == size.id })
                }
            }, label: {
                SwiftUI.Image(systemName: "trash")
                    .foregroundColor(.red)
            })
            .buttonStyle(.bordered)
            .disabled(noDelete)
            .opacity(noDelete ? 0.0 : 1.0)
        }
    }

}

extension CropSize: Defaults.Serializable {}
