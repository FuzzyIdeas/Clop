import Foundation

enum CropOrientation: String, CaseIterable, Codable {
    case landscape
    case portrait
    case adaptive
}

/// Normalized (0...1) crop region with the origin in the top-left corner of the source.
/// Being relative, it can be applied to any source size (pipeline runs operate on the
/// original file, whose pixel size can differ from the displayed file).
struct CropRect: Codable, Hashable {
    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isFullFrame: Bool {
        x <= 0.005 && y <= 0.005 && width >= 0.995 && height >= 0.995
    }

    func clamped() -> CropRect {
        let w = min(max(width, 0.001), 1)
        let h = min(max(height, 0.001), 1)
        return CropRect(
            x: min(max(x, 0), 1 - w),
            y: min(max(y, 0), 1 - h),
            width: w, height: h
        )
    }

    func pixelRect(in size: NSSize) -> CGRect {
        let r = clamped()
        let x = min(max((r.x * size.width).rounded(), 0), max(size.width - 1, 0))
        let y = min(max((r.y * size.height).rounded(), 0), max(size.height - 1, 0))
        let w = min(max((r.width * size.width).rounded(), 1), size.width - x)
        let h = min(max((r.height * size.height).rounded(), 1), size.height - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func computedSize(from size: NSSize) -> NSSize {
        pixelRect(in: size).size
    }

    /// Maps a rect from *displayed* (rotated) page space into *media box* (unrotated) space
    /// for PDF pages with a /Rotate entry of 90, 180 or 270 degrees (clockwise).
    /// The inverse mapping (media to displayed) is `rotated(by: 360 - degrees)`.
    func rotated(by degrees: Int) -> CropRect {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            CropRect(x: y, y: 1 - x - width, width: height, height: width)
        case 180:
            CropRect(x: 1 - x - width, y: 1 - y - height, width: width, height: height)
        case 270:
            CropRect(x: 1 - y - height, y: x, width: height, height: width)
        default:
            self
        }
    }
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
        let cropRect = try container.decodeIfPresent(CropRect.self, forKey: .cropRect)
        self.init(width: width, height: height, name: name, longEdge: longEdge, smartCrop: smartCrop, isAspectRatio: isAspectRatio, cropRect: cropRect)
    }

    init(width: Int, height: Int, name: String = "", longEdge: Bool = false, smartCrop: Bool = false, isAspectRatio: Bool = false, cropRect: CropRect? = nil) {
        self.width = width
        self.height = height
        self.name = name
        self.longEdge = longEdge
        self.smartCrop = smartCrop
        self.isAspectRatio = isAspectRatio
        self.cropRect = cropRect
    }

    init(width: Double, height: Double, name: String = "", longEdge: Bool = false, smartCrop: Bool = false, isAspectRatio: Bool = false, cropRect: CropRect? = nil) {
        self.width = width.evenInt
        self.height = height.evenInt
        self.name = name
        self.longEdge = longEdge
        self.smartCrop = smartCrop
        self.isAspectRatio = isAspectRatio
        self.cropRect = cropRect
    }

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case name
        case longEdge
        case smartCrop
        case isAspectRatio
        case cropRect
    }

    static let zero = CropSize(width: 0, height: 0)

    let width: Int
    let height: Int
    var name = ""
    var longEdge = false
    var smartCrop = false
    var isAspectRatio = false
    var cropRect: CropRect? = nil

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

/// A set of devices or paper sizes sharing the same aspect ratio.
/// Only the ratio matters when cropping, so any member yields the same result.
struct CropSizeGroup: Identifiable, Hashable {
    let name: String
    let width: Int
    let height: Int
    let members: [String]
    var summary: String? = nil

    var id: String { name }
    var size: NSSize { NSSize(width: width, height: height) }
    var cropSize: CropSize { CropSize(width: width, height: height, name: name, isAspectRatio: true) }
    var subtitle: String { summary ?? members.joined(separator: ", ") }

    func matches(_ name: String) -> Bool {
        let needle = name.lowercased()
        return self.name.lowercased() == needle || members.contains { $0.lowercased() == needle }
    }
}

func < (_ cropSize: CropSize, _ size: NSSize) -> Bool {
    // a sub-region rect is always a real crop; a full-frame rect is a plain resize,
    // judged by the target size below
    if let rect = cropSize.cropRect, !rect.isFullFrame {
        return true
    }
    return cropSize.longEdge
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
