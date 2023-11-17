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
                    let hideOldSize = OM.compactResults && optimiser.newBytes > 0 && optimiser.newSize != nil && optimiser.newSize! != size && (optimiser.newSize!.s + size.s).count > 14
                    if !hideOldSize {
                        Text(size == .zero ? "Crop" : "\(size.width.i)×\(size.height.i)")
                    }
                    if let newSize = optimiser.newSize, newSize != size {
                        if !hideOldSize {
                            SwiftUI.Image(systemName: "arrow.right")
                        }
                        Text("\(newSize.width.i)×\(newSize.height.i)")
                    }
                }
                .lineLimit(1)
            }
        )
        .focusable(false)
    }

    var editor: some View {
        VStack {
            HStack {
                TextField("", value: $tempWidth, formatter: NumberFormatter(), prompt: Text("Width"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .width)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
                    .disabled(isAspectRatio)
                Text("×")
                TextField("", value: $tempHeight, formatter: NumberFormatter(), prompt: Text("Height"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .height)
                    .frame(width: 60, alignment: .center)
                    .multilineTextAlignment(.center)
                    .disabled(isAspectRatio)

                if isAspectRatio {
                    Picker("", selection: $cropOrientation) {
                        Label("Portrait", systemImage: "rectangle.portrait").tag(CropOrientation.portrait)
                        Label("Landscape", systemImage: "rectangle").tag(CropOrientation.landscape)
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
            }

            VStack(alignment: .leading) {
                ForEach(savedCropSizes.filter { !$0.isAspectRatio && $0.width <= size.width.i && $0.height <= size.height.i }.sorted(by: \.area)) { size in
                    cropSizeButton(size)
                }
            }

            Divider()
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

            Divider()

            let sizeStr = isAspectRatio ? (cropSize?.name ?? "\(tempWidth):\(tempHeight)") : "\(tempWidth == 0 ? "Auto" : tempWidth.s)×\(tempHeight == 0 ? "Auto" : tempHeight.s)"
            Button("Crop and resize to \(sizeStr)") {
                guard !preview, tempWidth > 0 || tempHeight > 0 else { return }

                if isAspectRatio {
                    optimiser.crop(to: CropSize(
                        width: cropOrientation == .adaptive ? tempWidth : (cropOrientation == .landscape ? max(tempWidth, tempHeight) : min(tempWidth, tempHeight)),
                        height: cropOrientation == .adaptive ? tempHeight : (cropOrientation == .portrait ? max(tempWidth, tempHeight) : min(tempWidth, tempHeight)),
                        longEdge: cropOrientation == .adaptive, isAspectRatio: true
                    ))
                } else if tempWidth != 0, tempHeight != 0 {
                    optimiser.crop(to: CropSize(width: tempWidth, height: tempHeight))
                } else {
                    optimiser.downscale(toFactor: tempWidth == 0 ? tempHeight.d / size.height.d : tempWidth.d / size.width.d)
                }
            }
            .buttonStyle(.bordered)
            .fontDesign(.rounded)
            .monospacedDigit()
            .disabled(optimiser.running || (tempWidth == 0 && tempHeight == 0))

            HStack {
                TextField("", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .frame(width: 100, alignment: .leading)
                Button("Save") {
                    guard !preview, !name.isEmpty, tempWidth > 0 || tempHeight > 0
                    else { return }

                    savedCropSizes.append(CropSize(width: tempWidth, height: tempHeight, name: name))
                }
                .buttonStyle(.bordered)
                .fontDesign(.rounded)
            }
        }
        .padding()
        .defaultFocus($focused, .width)
    }

    @State private var hoveringHelpButton = false
    @State private var lastFocusState: Field?

    @ViewBuilder var editorViewer: some View {
        viewer
            .onAppear {
                guard let size = optimiser.oldSize else { return }
                tempWidth = size.width.i
                tempHeight = size.height.i
                cropOrientation = size.orientation
                self.size = size
            }
            .onChange(of: optimiser.oldSize) { size in
                guard let size else { return }
                tempWidth = size.width.i
                tempHeight = size.height.i
                cropOrientation = size.orientation
                self.size = size
            }
            .popover(isPresented: $optimiser.editingResolution, arrowEdge: .bottom) {
                ZStack(alignment: .topTrailing) {
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
                            alignment: .topTrailing,
                            offset: CGSize(width: -5, height: 45),
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

    @ViewBuilder func aspectRatioButton(_ size: CropSize) -> some View {
        Button(size.name) {
            isAspectRatio = true
            cropSize = size.withOrientation(cropOrientation)

            let newSize = (cropSize ?? size).computedSize(from: self.size)
            tempWidth = newSize.width.evenInt
            tempHeight = newSize.height.evenInt
        }.buttonStyle(.bordered)
    }

    @ViewBuilder func cropSizeButton(_ size: CropSize) -> some View {
        HStack {
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

    var editor: some View {
        VStack {
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

            VStack(alignment: .leading) {
                ForEach(savedCropSizes.sorted(by: \.area)) { size in
                    cropSizeButton(size)
                }
            }

            Divider()

            Button("Crop and resize to \(tempWidth == 0 ? "Auto" : tempWidth.s)×\(tempHeight == 0 ? "Auto" : tempHeight.s)") {
                guard !preview, tempWidth > 0 || tempHeight > 0 else { return }

                if tempWidth != 0, tempHeight != 0 {
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
            .disabled(tempWidth == 0 && tempHeight == 0)

            HStack {
                TextField("", text: $name, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .frame(width: 100, alignment: .leading)
                Button("Save") {
                    guard !preview, !name.isEmpty, tempWidth > 0 || tempHeight > 0
                    else { return }

                    savedCropSizes.append(CropSize(width: tempWidth, height: tempHeight, name: name))
                }
                .buttonStyle(.bordered)
                .fontDesign(.rounded)
            }
        }
        .padding()
        .defaultFocus($focused, .width)
    }

    @State private var hoveringHelpButton = false
    @State private var lastFocusState: Field?

    @ViewBuilder var editorViewer: some View {
        viewer
            .popover(isPresented: $cropping, arrowEdge: .bottom) {
                ZStack(alignment: .topTrailing) {
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
                            alignment: .topTrailing,
                            offset: CGSize(width: -5, height: 45),
                            """
                            Width and height need to be smaller
                            than the original size.

                            Set the width or height to 0 to have it
                            calculated automatically while keeping
                            the original aspect ratio.
                            """
                        )
                }
                .buttonStyle(FlatButton(color: .primary.opacity(colorScheme == .dark ? 0.05 : 0.13), textColor: .primary, radius: 3, horizontalPadding: 3, verticalPadding: 1))
                .font(.mono(11, weight: .medium))
                .foregroundColor(.primary)
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

extension CropSize: Defaults.Serializable {}
