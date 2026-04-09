import Foundation

enum CropOrientation: String, CaseIterable, Codable {
    case landscape
    case portrait
    case adaptive
}

struct CropSize: Codable, Hashable, Identifiable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let name = try container.decode(String.self, forKey: .name)
        let longEdge = try container.decode(Bool.self, forKey: .longEdge)
        let smartCrop = try container.decode(Bool.self, forKey: .smartCrop)
        let isAspectRatio = try container.decodeIfPresent(Bool.self, forKey: .isAspectRatio) ?? false
        self.init(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }

    init(width: Int, height: Int, name: String = "", longEdge: Bool = false, smartCrop: Bool = false, isAspectRatio: Bool = false) {
        self.width = width
        self.height = height
        self.name = name
        self.longEdge = longEdge
        self.smartCrop = smartCrop
        self.isAspectRatio = isAspectRatio
    }

    init(width: Double, height: Double, name: String = "", longEdge: Bool = false, smartCrop: Bool = false, isAspectRatio: Bool = false) {
        self.width = width.evenInt
        self.height = height.evenInt
        self.name = name
        self.longEdge = longEdge
        self.smartCrop = smartCrop
        self.isAspectRatio = isAspectRatio
    }

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case name
        case longEdge
        case smartCrop
        case isAspectRatio
    }

    static let zero = CropSize(width: 0, height: 0)

    let width: Int
    let height: Int
    var name = ""
    var longEdge = false
    var smartCrop = false
    var isAspectRatio = false

    var flipped: CropSize {
        var flippedName = name
        if name.contains(":") {
            let elements = name.split(separator: ":")
            flippedName = "\(elements.last ?? ""):\(elements.first ?? "")"
        }
        return CropSize(width: height, height: width, name: flippedName, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }
    var orientation: CropOrientation {
        width >= height ? .landscape : .portrait
    }
    var fractionalAspectRatio: Double {
        min(width, height).d / max(width, height).d
    }
    var id: String { "\(width == 0 ? "Auto" : width.s)×\(height == 0 ? "Auto" : height.s)" }
    var area: Int { (width == 0 ? height : width) * (height == 0 ? width : height) }
    var ns: NSSize { NSSize(width: width, height: height) }
    var cg: CGSize { CGSize(width: width, height: height) }
    var aspectRatio: Double { width.d / height.d }

    func withLongEdge(_ longEdge: Bool) -> CropSize {
        CropSize(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }

    func withSmartCrop(_ smartCrop: Bool) -> CropSize {
        CropSize(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio)
    }

    func withOrientation(_ orientation: CropOrientation, for size: NSSize? = nil) -> CropSize {
        switch orientation {
        case .landscape:
            (width >= height ? self : flipped).withLongEdge(false)
        case .portrait:
            (width >= height ? flipped : self).withLongEdge(false)
        case .adaptive:
            if let size {
                (size.orientation == self.orientation ? self : flipped).withLongEdge(true)
            } else {
                withLongEdge(true)
            }
        }
    }

    func factor(from size: NSSize) -> Double {
        if isAspectRatio {
            let cropSize = computedSize(from: size)
            return (cropSize.width * cropSize.height) / (size.width * size.height)
        }
        if longEdge {
            return width == 0 ? height.d / max(size.width, size.height) : width.d / max(size.width, size.height)
        }
        if width == 0 {
            return height.d / size.height
        }
        if height == 0 {
            return width.d / size.width
        }
        return (width.d * height.d) / (size.width * size.height)
    }

    func computedSize(from size: NSSize) -> NSSize {
        guard width == 0 || height == 0 || longEdge || isAspectRatio else {
            return ns
        }
        if isAspectRatio {
            return size.cropTo(aspectRatio: fractionalAspectRatio, alwaysPortrait: !longEdge && width < height, alwaysLandscape: !longEdge && height < width).size
        }
        return size.scaled(by: factor(from: size))
    }

}

func < (_ cropSize: CropSize, _ size: NSSize) -> Bool {
    cropSize.longEdge
        ? (cropSize.width == 0 ? cropSize.height : cropSize.width).d < max(size.width, size.height)
        : (cropSize.width.d < size.width && cropSize.height.d <= size.height) || (cropSize.width.d <= size.width && cropSize.height.d < size.height)
}

extension NSSize {
    var orientation: CropOrientation {
        width >= height ? .landscape : .portrait
    }
    func cropSize(name: String = "", longEdge: Bool = false) -> CropSize {
        CropSize(width: width.evenInt, height: height.evenInt, name: name, longEdge: longEdge)
    }
    var flipped: NSSize {
        NSSize(width: height, height: width)
    }
}
