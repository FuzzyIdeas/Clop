import Foundation

let DEVICE_SIZES = [
    "iPhone 17 Pro Max": NSSize(width: 1320, height: 2868),
    "iPhone 17 Pro": NSSize(width: 1206, height: 2622),
    "iPhone 17": NSSize(width: 1206, height: 2622),
    "iPhone 17e": NSSize(width: 1170, height: 2532),
    "iPhone Air": NSSize(width: 1260, height: 2736),
    "iPad Pro M5 13inch": NSSize(width: 2064, height: 2752),
    "iPad Pro M5 11inch": NSSize(width: 1668, height: 2420),
    "iPad Pro M4 13inch": NSSize(width: 2064, height: 2752),
    "iPad Pro M4 11inch": NSSize(width: 1668, height: 2420),
    "iPad Air M4 13inch": NSSize(width: 2048, height: 2732),
    "iPad Air M4 11inch": NSSize(width: 1640, height: 2360),
    "iPad Air M3 13inch": NSSize(width: 2048, height: 2732),
    "iPad Air M3 11inch": NSSize(width: 1640, height: 2360),
    "iPad Air M2 13inch": NSSize(width: 2048, height: 2732),
    "iPad Air M2 11inch": NSSize(width: 1640, height: 2360),
    "iPad 11": NSSize(width: 1640, height: 2360),
    "iPad mini 7": NSSize(width: 1488, height: 2266),
    "iPhone 16e": NSSize(width: 1170, height: 2532),
    "iPhone 16 Pro Max": NSSize(width: 1320, height: 2868),
    "iPhone 16 Pro": NSSize(width: 1206, height: 2622),
    "iPhone 16 Plus": NSSize(width: 1290, height: 2796),
    "iPhone 16": NSSize(width: 1179, height: 2556),
    "iPhone 15 Pro Max": NSSize(width: 1290, height: 2796),
    "iPhone 15 Pro": NSSize(width: 1179, height: 2556),
    "iPhone 15 Plus": NSSize(width: 1290, height: 2796),
    "iPhone 15": NSSize(width: 1179, height: 2556),
    "iPad Pro": NSSize(width: 2064, height: 2752),
    "iPad Pro 6 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 6 11inch": NSSize(width: 1668, height: 2388),
    "iPad": NSSize(width: 1640, height: 2360),
    "iPad 10": NSSize(width: 1640, height: 2360),
    "iPhone 14 Plus": NSSize(width: 1284, height: 2778),
    "iPhone 14 Pro Max": NSSize(width: 1290, height: 2796),
    "iPhone 14 Pro": NSSize(width: 1179, height: 2556),
    "iPhone 14": NSSize(width: 1170, height: 2532),
    "iPhone SE 3": NSSize(width: 750, height: 1334),
    "iPad Air": NSSize(width: 1640, height: 2360),
    "iPad Air 5": NSSize(width: 1640, height: 2360),
    "iPhone 13": NSSize(width: 1170, height: 2532),
    "iPhone 13 mini": NSSize(width: 1080, height: 2340),
    "iPhone 13 Pro Max": NSSize(width: 1284, height: 2778),
    "iPhone 13 Pro": NSSize(width: 1170, height: 2532),
    "iPad 9": NSSize(width: 1620, height: 2160),
    "iPad Pro 5 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 5 11inch": NSSize(width: 1668, height: 2388),
    "iPad Air 4": NSSize(width: 1640, height: 2360),
    "iPhone 12": NSSize(width: 1170, height: 2532),
    "iPhone 12 mini": NSSize(width: 1080, height: 2340),
    "iPhone 12 Pro Max": NSSize(width: 1284, height: 2778),
    "iPhone 12 Pro": NSSize(width: 1170, height: 2532),
    "iPad 8": NSSize(width: 1620, height: 2160),
    "iPhone SE 2": NSSize(width: 750, height: 1334),
    "iPad Pro 4 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 4 11inch": NSSize(width: 1668, height: 2388),
    "iPad 7": NSSize(width: 1620, height: 2160),
    "iPhone 11 Pro Max": NSSize(width: 1242, height: 2688),
    "iPhone 11 Pro": NSSize(width: 1125, height: 2436),
    "iPhone 11": NSSize(width: 828, height: 1792),
    "iPod touch 7": NSSize(width: 640, height: 1136),
    "iPad mini": NSSize(width: 1488, height: 2266),
    "iPad mini 6": NSSize(width: 1488, height: 2266),
    "iPad mini 5": NSSize(width: 1536, height: 2048),
    "iPad Air 3": NSSize(width: 1668, height: 2224),
    "iPad Pro 3 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 3 11inch": NSSize(width: 1668, height: 2388),
    "iPhone XR": NSSize(width: 828, height: 1792),
    "iPhone XS Max": NSSize(width: 1242, height: 2688),
    "iPhone XS": NSSize(width: 1125, height: 2436),
    "iPad 6": NSSize(width: 1536, height: 2048),
    "iPhone X": NSSize(width: 1125, height: 2436),
    "iPhone 8 Plus": NSSize(width: 1080, height: 1920),
    "iPhone 8": NSSize(width: 750, height: 1334),
    "iPad Pro 2 12.9inch": NSSize(width: 2048, height: 2732),
    "iPad Pro 2 10.5inch": NSSize(width: 1668, height: 2224),
    "iPad 5": NSSize(width: 1536, height: 2048),
    "iPhone 7 Plus": NSSize(width: 1080, height: 1920),
    "iPhone 7": NSSize(width: 750, height: 1334),
    "iPhone SE 1": NSSize(width: 640, height: 1136),
    "iPad Pro 1 9.7inch": NSSize(width: 1536, height: 2048),
    "iPad Pro 1 12.9inch": NSSize(width: 2048, height: 2732),
    "iPhone 6s Plus": NSSize(width: 1080, height: 1920),
    "iPhone 6s": NSSize(width: 750, height: 1334),
    "iPad mini 4": NSSize(width: 1536, height: 2048),
    "iPod touch 6": NSSize(width: 640, height: 1136),
    "iPad Air 2": NSSize(width: 1536, height: 2048),
    "iPad mini 3": NSSize(width: 1536, height: 2048),
    "iPhone 6 Plus": NSSize(width: 1080, height: 1920),
    "iPhone 6": NSSize(width: 750, height: 1334),
    "iPad mini 2": NSSize(width: 1536, height: 2048),
    "iPad mini 1": NSSize(width: 768, height: 1024),
    "iPad Air 1": NSSize(width: 1536, height: 2048),
    "iPhone 5C": NSSize(width: 640, height: 1136),
    "iPhone 5S": NSSize(width: 640, height: 1136),
    "iPad 4": NSSize(width: 1536, height: 2048),
    "iPod touch 5": NSSize(width: 640, height: 1136),
    "iPhone 5": NSSize(width: 640, height: 1136),
    "iPad 3": NSSize(width: 1536, height: 2048),
    "iPhone 4S": NSSize(width: 640, height: 960),
    "iPad 2": NSSize(width: 768, height: 1024),
    "iPod touch 4": NSSize(width: 640, height: 960),
    "iPhone 4": NSSize(width: 640, height: 960),
]

/// Devices that share the same exact screen aspect ratio, newest first.
/// A PDF cropped to the group ratio fills the screen of every member without black borders.
let IPHONE_SIZE_GROUPS: [CropSizeGroup] = [
    CropSizeGroup(
        name: "iPhone 17 Pro Max & 16 Pro Max", width: 1320, height: 2868,
        members: ["iPhone 17 Pro Max", "iPhone 16 Pro Max"]
    ),
    CropSizeGroup(
        name: "iPhone 17 & 16 Pro", width: 1206, height: 2622,
        members: ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro"]
    ),
    CropSizeGroup(
        name: "iPhone Air", width: 1260, height: 2736,
        members: ["iPhone Air"]
    ),
    CropSizeGroup(
        name: "iPhone 16 & 15 & 14 Pro", width: 1179, height: 2556,
        members: ["iPhone 16", "iPhone 15 Pro", "iPhone 15", "iPhone 14 Pro"]
    ),
    CropSizeGroup(
        name: "iPhone 16 Plus & 15 Pro Max", width: 1290, height: 2796,
        members: ["iPhone 16 Plus", "iPhone 15 Pro Max", "iPhone 15 Plus", "iPhone 14 Pro Max"]
    ),
    CropSizeGroup(
        name: "iPhone 17e & 16e & 12\u{2013}14", width: 1170, height: 2532,
        members: ["iPhone 17e", "iPhone 16e", "iPhone 14", "iPhone 13 Pro", "iPhone 13", "iPhone 12 Pro", "iPhone 12"]
    ),
    CropSizeGroup(
        name: "iPhone 14 Plus & 13 Pro Max", width: 1284, height: 2778,
        members: ["iPhone 14 Plus", "iPhone 13 Pro Max", "iPhone 12 Pro Max"]
    ),
    CropSizeGroup(
        name: "iPhone 13 & 12 mini", width: 1080, height: 2340,
        members: ["iPhone 13 mini", "iPhone 12 mini"]
    ),
    CropSizeGroup(
        name: "iPhone 11 Pro & X & XS", width: 1125, height: 2436,
        members: ["iPhone 11 Pro", "iPhone XS", "iPhone X"]
    ),
    CropSizeGroup(
        name: "iPhone 11 & XR & Max", width: 1242, height: 2688,
        members: ["iPhone 11 Pro Max", "iPhone 11", "iPhone XS Max", "iPhone XR"]
    ),
    CropSizeGroup(
        name: "iPhone Plus (16:9)", width: 1080, height: 1920,
        members: ["iPhone 8 Plus", "iPhone 7 Plus", "iPhone 6s Plus", "iPhone 6 Plus"]
    ),
    CropSizeGroup(
        name: "iPhone 6\u{2013}8 & SE", width: 750, height: 1334,
        members: ["iPhone SE 3", "iPhone SE 2", "iPhone 8", "iPhone 7", "iPhone 6s", "iPhone 6"]
    ),
    CropSizeGroup(
        name: "iPhone 5 & SE 1", width: 640, height: 1136,
        members: ["iPhone SE 1", "iPhone 5S", "iPhone 5C", "iPhone 5", "iPod touch 7", "iPod touch 6", "iPod touch 5"]
    ),
    CropSizeGroup(
        name: "iPhone 4 (2:3)", width: 640, height: 960,
        members: ["iPhone 4S", "iPhone 4", "iPod touch 4"]
    ),
]

let IPAD_SIZE_GROUPS: [CropSizeGroup] = [
    CropSizeGroup(
        name: "iPad & iPad Pro 13\u{2033} (3:4)", width: 2064, height: 2752,
        members: [
            "iPad Pro M5 13inch", "iPad Pro M4 13inch",
            "iPad 9", "iPad 8", "iPad 7", "iPad 6", "iPad 5", "iPad 4", "iPad 3", "iPad 2",
            "iPad mini 5", "iPad mini 4", "iPad mini 3", "iPad mini 2", "iPad mini 1",
            "iPad Air 3", "iPad Air 2", "iPad Air 1",
            "iPad Pro 2 10.5inch", "iPad Pro 1 9.7inch",
        ],
        summary: "iPad 2\u{2013}9, iPad mini 1\u{2013}5, iPad Air 1\u{2013}3, iPad Pro 9.7\u{2033}/10.5\u{2033}, iPad Pro 13\u{2033} M4/M5"
    ),
    CropSizeGroup(
        name: "iPad Pro 12.9\u{2033} & Air 13\u{2033}", width: 2048, height: 2732,
        members: [
            "iPad Air M4 13inch", "iPad Air M3 13inch", "iPad Air M2 13inch",
            "iPad Pro 6 12.9inch", "iPad Pro 5 12.9inch", "iPad Pro 4 12.9inch",
            "iPad Pro 3 12.9inch", "iPad Pro 2 12.9inch", "iPad Pro 1 12.9inch",
        ],
        summary: "iPad Pro 12.9\u{2033} 1\u{2013}6, iPad Air 13\u{2033} M2/M3/M4"
    ),
    CropSizeGroup(
        name: "iPad 10.9\u{2033} & Air 11\u{2033}", width: 1640, height: 2360,
        members: [
            "iPad 11", "iPad 10",
            "iPad Air M4 11inch", "iPad Air M3 11inch", "iPad Air M2 11inch",
            "iPad Air 5", "iPad Air 4",
        ],
        summary: "iPad 10/11, iPad Air 4/5, iPad Air 11\u{2033} M2/M3/M4"
    ),
    CropSizeGroup(
        name: "iPad Pro 11\u{2033} M4/M5", width: 1668, height: 2420,
        members: ["iPad Pro M5 11inch", "iPad Pro M4 11inch"]
    ),
    CropSizeGroup(
        name: "iPad Pro 11\u{2033} 2018\u{2013}2022", width: 1668, height: 2388,
        members: ["iPad Pro 6 11inch", "iPad Pro 5 11inch", "iPad Pro 4 11inch", "iPad Pro 3 11inch"]
    ),
    CropSizeGroup(
        name: "iPad mini 6 & 7", width: 1488, height: 2266,
        members: ["iPad mini 7", "iPad mini 6"]
    ),
]

let DEVICE_SIZE_GROUPS: [(category: String, groups: [CropSizeGroup])] = [
    ("iPhone", IPHONE_SIZE_GROUPS),
    ("iPad", IPAD_SIZE_GROUPS),
]

func deviceSizeGroup(named name: String) -> CropSizeGroup? {
    DEVICE_SIZE_GROUPS.flatMap(\.groups).first { $0.matches(name) }
}

/// Resolves a device name or device group name to its screen size, case-insensitively.
func findDeviceSize(named name: String) -> NSSize? {
    if let size = DEVICE_SIZES[name] {
        return size
    }
    let needle = name.lowercased()
    if let size = DEVICE_SIZES.first(where: { $0.key.lowercased() == needle })?.value {
        return size
    }
    return deviceSizeGroup(named: name)?.size
}

enum Device: String, Codable, Sendable, CaseIterable {
    case iPhone17ProMax = "iPhone 17 Pro Max"
    case iPhone17Pro = "iPhone 17 Pro"
    case iPhone17 = "iPhone 17"
    case iPhone17e = "iPhone 17e"
    case iPhoneAir = "iPhone Air"
    case iPadProM513Inch = "iPad Pro M5 13inch"
    case iPadProM511Inch = "iPad Pro M5 11inch"
    case iPadProM413Inch = "iPad Pro M4 13inch"
    case iPadProM411Inch = "iPad Pro M4 11inch"
    case iPadAirM413Inch = "iPad Air M4 13inch"
    case iPadAirM411Inch = "iPad Air M4 11inch"
    case iPadAirM313Inch = "iPad Air M3 13inch"
    case iPadAirM311Inch = "iPad Air M3 11inch"
    case iPadAirM213Inch = "iPad Air M2 13inch"
    case iPadAirM211Inch = "iPad Air M2 11inch"
    case iPad11 = "iPad 11"
    case iPadMini7 = "iPad mini 7"
    case iPhone16e = "iPhone 16e"
    case iPhone16ProMax = "iPhone 16 Pro Max"
    case iPhone16Pro = "iPhone 16 Pro"
    case iPhone16Plus = "iPhone 16 Plus"
    case iPhone16 = "iPhone 16"
    case iPhone15ProMax = "iPhone 15 Pro Max"
    case iPhone15Pro = "iPhone 15 Pro"
    case iPhone15Plus = "iPhone 15 Plus"
    case iPhone15 = "iPhone 15"
    case iPadPro = "iPad Pro"
    case iPadPro6129Inch = "iPad Pro 6 12.9inch"
    case iPadPro611Inch = "iPad Pro 6 11inch"
    case iPad
    case iPad10 = "iPad 10"
    case iPhone14Plus = "iPhone 14 Plus"
    case iPhone14ProMax = "iPhone 14 Pro Max"
    case iPhone14Pro = "iPhone 14 Pro"
    case iPhone14 = "iPhone 14"
    case iPhoneSe3 = "iPhone SE 3"
    case iPadAir = "iPad Air"
    case iPadAir5 = "iPad Air 5"
    case iPhone13 = "iPhone 13"
    case iPhone13Mini = "iPhone 13 mini"
    case iPhone13ProMax = "iPhone 13 Pro Max"
    case iPhone13Pro = "iPhone 13 Pro"
    case iPad9 = "iPad 9"
    case iPadPro5129Inch = "iPad Pro 5 12.9inch"
    case iPadPro511Inch = "iPad Pro 5 11inch"
    case iPadAir4 = "iPad Air 4"
    case iPhone12 = "iPhone 12"
    case iPhone12Mini = "iPhone 12 mini"
    case iPhone12ProMax = "iPhone 12 Pro Max"
    case iPhone12Pro = "iPhone 12 Pro"
    case iPad8 = "iPad 8"
    case iPhoneSe2 = "iPhone SE 2"
    case iPadPro4129Inch = "iPad Pro 4 12.9inch"
    case iPadPro411Inch = "iPad Pro 4 11inch"
    case iPad7 = "iPad 7"
    case iPhone11ProMax = "iPhone 11 Pro Max"
    case iPhone11Pro = "iPhone 11 Pro"
    case iPhone11 = "iPhone 11"
    case iPodTouch7 = "iPod touch 7"
    case iPadMini = "iPad mini"
    case iPadMini6 = "iPad mini 6"
    case iPadMini5 = "iPad mini 5"
    case iPadAir3 = "iPad Air 3"
    case iPadPro3129Inch = "iPad Pro 3 12.9inch"
    case iPadPro311Inch = "iPad Pro 3 11inch"
    case iPhoneXr = "iPhone XR"
    case iPhoneXsMax = "iPhone XS Max"
    case iPhoneXs = "iPhone XS"
    case iPad6 = "iPad 6"
    case iPhoneX = "iPhone X"
    case iPhone8Plus = "iPhone 8 Plus"
    case iPhone8 = "iPhone 8"
    case iPadPro2129Inch = "iPad Pro 2 12.9inch"
    case iPadPro2105Inch = "iPad Pro 2 10.5inch"
    case iPad5 = "iPad 5"
    case iPhone7Plus = "iPhone 7 Plus"
    case iPhone7 = "iPhone 7"
    case iPhoneSe1 = "iPhone SE 1"
    case iPadPro197Inch = "iPad Pro 1 9.7inch"
    case iPadPro1129Inch = "iPad Pro 1 12.9inch"
    case iPhone6SPlus = "iPhone 6s Plus"
    case iPhone6S = "iPhone 6s"
    case iPadMini4 = "iPad mini 4"
    case iPodTouch6 = "iPod touch 6"
    case iPadAir2 = "iPad Air 2"
    case iPadMini3 = "iPad mini 3"
    case iPhone6Plus = "iPhone 6 Plus"
    case iPhone6 = "iPhone 6"
    case iPadMini2 = "iPad mini 2"
    case iPadMini1 = "iPad mini 1"
    case iPadAir1 = "iPad Air 1"
    case iPhone5C = "iPhone 5C"
    case iPhone5S = "iPhone 5S"
    case iPad4 = "iPad 4"
    case iPodTouch5 = "iPod touch 5"
    case iPhone5 = "iPhone 5"
    case iPad3 = "iPad 3"
    case iPhone4S = "iPhone 4S"
    case iPad2 = "iPad 2"
    case iPodTouch4 = "iPod touch 4"
    case iPhone4 = "iPhone 4"

    var aspectRatio: Double {
        DEVICE_SIZES[rawValue]!.aspectRatio
    }

}
