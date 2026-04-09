import Foundation

enum VideoEncoder: String, CaseIterable, Codable {
    case fast
    case slowHighQuality
    case visuallyLossless

    var name: String {
        switch self {
        case .fast: "Fast, battery efficient, larger file"
        case .slowHighQuality: "Slow, high quality, smaller file"
        case .visuallyLossless: "Visually lossless"
        }
    }

    var description: String {
        switch self {
        case .fast:
            #if arch(arm64)
                "Uses the hardware encoder for quick, low-power optimisation"
            #else
                "Uses the default encoder preset for a good balance of speed and quality"
            #endif
        case .slowHighQuality:
            "Uses a slow software encoder preset for smaller files with better quality"
        case .visuallyLossless:
            "Produces files with no perceptible quality loss (CRF 17)"
        }
    }
}
