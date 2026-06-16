import Combine
import Defaults
import Foundation
import Lowtech
import SwiftUI

struct ResolutionField: View {
    @ObservedObject var optimiser: Optimiser
    /// Prefix the value with a small crop glyph so it reads as a "crop & resize" control, not just a
    /// passive size readout. Opt-in (off on the floating card, on in the compact list).
    var showCropIcon = false

    @State var size: NSSize = .zero

    @Environment(\.preview) var preview

    var body: some View {
        Button(
            action: {
                guard !preview else { return }
                optimiser.showCropWindow()
            },
            label: {
                HStack(spacing: 3) {
                    if showCropIcon {
                        SwiftUI.Image(systemName: "crop")
                    }
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
        .help("Open the crop and resize window")
        .onAppear {
            guard let size = optimiser.oldSize else { return }
            self.size = size
        }
        .onChange(of: optimiser.oldSize) { size in
            guard let size else { return }
            self.size = size
        }
    }
}

extension CropSize: Defaults.Serializable {}
