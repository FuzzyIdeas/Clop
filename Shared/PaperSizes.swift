import Foundation
import PDFKit

enum PageLayout: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case auto
}

extension PDFDocument {
    func cropTo(aspectRatio: Double, alwaysPortrait: Bool = false, alwaysLandscape: Bool = false) {
        guard pageCount > 0 else { return }

        for i in 0 ..< pageCount {
            let page = page(at: i)!
            let size = page.bounds(for: .mediaBox).size
            let cropRect = size.cropTo(aspectRatio: aspectRatio, alwaysPortrait: alwaysPortrait, alwaysLandscape: alwaysLandscape)
            page.setBounds(cropRect, for: .cropBox)
        }
    }
    func uncrop() {
        guard pageCount > 0 else { return }

        for i in 0 ..< pageCount {
            let page = page(at: i)!
            page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
        }
    }

    /// `rect` is normalized to the *displayed* page (top-left origin, rotation applied),
    /// so it has to be mapped back into media box space before flipping the y axis
    /// into PDF bottom-left coordinates.
    func cropTo(rect: CropRect) {
        guard pageCount > 0 else { return }

        for i in 0 ..< pageCount {
            let page = page(at: i)!
            let media = page.bounds(for: .mediaBox)
            let r = rect.rotated(by: page.rotation).clamped()
            let cropRect = CGRect(
                x: media.minX + media.width * r.x,
                y: media.minY + media.height * (1 - r.y - r.height),
                width: media.width * r.width,
                height: media.height * r.height
            )
            page.setBounds(cropRect, for: .cropBox)
        }
    }
}

let PAPER_SIZES_BY_CATEGORY = [
    "A": [
        "A0": NSSize(width: 841, height: 1189),
        "A1": NSSize(width: 594, height: 841),
        "A2": NSSize(width: 420, height: 594),
        "A3": NSSize(width: 297, height: 420),
        "A4": NSSize(width: 210, height: 297),
        "A5": NSSize(width: 148, height: 210),
        "A6": NSSize(width: 105, height: 148),
        "A7": NSSize(width: 74, height: 105),
        "A8": NSSize(width: 52, height: 74),
        "A9": NSSize(width: 37, height: 52),
        "A10": NSSize(width: 26, height: 37),
        "A11": NSSize(width: 18, height: 26),
        "A12": NSSize(width: 13, height: 18),
        "A13": NSSize(width: 9, height: 13),
        "2A0": NSSize(width: 1189, height: 1682),
        "4A0": NSSize(width: 1682, height: 2378),
        "A0+": NSSize(width: 914, height: 1292),
        "A1+": NSSize(width: 609, height: 914),
        "A3+": NSSize(width: 329, height: 483),
    ],
    "B": [
        "B0": NSSize(width: 1000, height: 1414),
        "B1": NSSize(width: 707, height: 1000),
        "B2": NSSize(width: 500, height: 707),
        "B3": NSSize(width: 353, height: 500),
        "B4": NSSize(width: 250, height: 353),
        "B5": NSSize(width: 176, height: 250),
        "B6": NSSize(width: 125, height: 176),
        "B7": NSSize(width: 88, height: 125),
        "B8": NSSize(width: 62, height: 88),
        "B9": NSSize(width: 44, height: 62),
        "B10": NSSize(width: 31, height: 44),
        "B11": NSSize(width: 22, height: 31),
        "B12": NSSize(width: 15, height: 22),
        "B13": NSSize(width: 11, height: 15),
        "B0+": NSSize(width: 1118, height: 1580),
        "B1+": NSSize(width: 720, height: 1020),
        "B2+": NSSize(width: 520, height: 720),
    ],
    "US": [
        "Letter": NSSize(width: 216, height: 279),
        "Legal": NSSize(width: 216, height: 356),
        "Tabloid": NSSize(width: 279, height: 432),
        "Ledger": NSSize(width: 432, height: 279),
        "Junior Legal": NSSize(width: 127, height: 203),
        "Half Letter": NSSize(width: 140, height: 216),
        "Government Letter": NSSize(width: 203, height: 267),
        "Government Legal": NSSize(width: 216, height: 330),
        "ANSI A": NSSize(width: 216, height: 279),
        "ANSI B": NSSize(width: 279, height: 432),
        "ANSI C": NSSize(width: 432, height: 559),
        "ANSI D": NSSize(width: 559, height: 864),
        "ANSI E": NSSize(width: 864, height: 1118),
        "Arch A": NSSize(width: 229, height: 305),
        "Arch B": NSSize(width: 305, height: 457),
        "Arch C": NSSize(width: 457, height: 610),
        "Arch D": NSSize(width: 610, height: 914),
        "Arch E": NSSize(width: 914, height: 1219),
        "Arch E1": NSSize(width: 762, height: 1067),
        "Arch E2": NSSize(width: 660, height: 965),
        "Arch E3": NSSize(width: 686, height: 991),
    ],
    "Photography": [
        "Passport": NSSize(width: 35, height: 45),
        "2R": NSSize(width: 64, height: 89),
        "LD, DSC": NSSize(width: 89, height: 119),
        "3R, L": NSSize(width: 89, height: 127),
        "LW": NSSize(width: 89, height: 133),
        "KGD": NSSize(width: 102, height: 136),
        "4R, KG": NSSize(width: 102, height: 152),
        "2LD, DSCW": NSSize(width: 127, height: 169),
        "5R, 2L": NSSize(width: 127, height: 178),
        "2LW": NSSize(width: 127, height: 190),
        "6R": NSSize(width: 152, height: 203),
        "8R, 6P": NSSize(width: 203, height: 254),
        "S8R, 6PW": NSSize(width: 203, height: 305),
        "11R": NSSize(width: 279, height: 356),
        "A3+ Super B": NSSize(width: 330, height: 483),
    ],
    "Newspaper": [
        "Berliner": NSSize(width: 315, height: 470),
        "Broadsheet": NSSize(width: 597, height: 749),
        "US Broadsheet": NSSize(width: 381, height: 578),
        "British Broadsheet": NSSize(width: 375, height: 597),
        "South African Broadsheet": NSSize(width: 410, height: 578),
        "Ciner": NSSize(width: 350, height: 500),
        "Compact": NSSize(width: 280, height: 430),
        "Nordisch": NSSize(width: 400, height: 570),
        "Rhenish": NSSize(width: 350, height: 520),
        "Swiss": NSSize(width: 320, height: 475),
        "Newspaper Tabloid": NSSize(width: 280, height: 430),
        "Canadian Tabloid": NSSize(width: 260, height: 368),
        "Norwegian Tabloid": NSSize(width: 280, height: 400),
        "New York Times": NSSize(width: 305, height: 559),
        "Wall Street Journal": NSSize(width: 305, height: 578),
    ],
    "Books": [
        "Folio": NSSize(width: 304.8, height: 482.6),
        "Quarto": NSSize(width: 241.3, height: 304.8),
        "Imperial Octavo": NSSize(width: 209.55, height: 292.1),
        "Super Octavo": NSSize(width: 177.8, height: 279.4),
        "Royal Octavo": NSSize(width: 165, height: 254),
        "Medium Octavo": NSSize(width: 165.1, height: 234.95),
        "Octavo": NSSize(width: 152.4, height: 228.6),
        "Crown Octavo": NSSize(width: 136.525, height: 203.2),
        "12mo": NSSize(width: 127.0, height: 187.325),
        "16mo": NSSize(width: 101.6, height: 171.45),
        "18mo": NSSize(width: 101.6, height: 165.1),
        "32mo": NSSize(width: 88.9, height: 139.7),
        "48mo": NSSize(width: 63.5, height: 101.6),
        "64mo": NSSize(width: 50.8, height: 76.2),
        "A Format": NSSize(width: 110, height: 178),
        "B Format": NSSize(width: 129, height: 198),
        "C Format": NSSize(width: 135, height: 216),
    ],
]
let PAPER_SIZES: [String: NSSize] = PAPER_SIZES_BY_CATEGORY.reduce(into: [:]) { result, category in
    category.value.forEach { result[$0.key] = $0.value }
}
let PAPER_CROP_SIZES: [String: [String: CropSize]] = PAPER_SIZES_BY_CATEGORY.reduce(into: [:]) { result, category in
    let paperCropSizes = category.value.map { k, v in (k, CropSize(width: v.width.intround, height: v.height.intround, name: k, isAspectRatio: true)) }
    result[category.key] = [String: CropSize](uniqueKeysWithValues: paperCropSizes)
}

enum PaperSize: String, Codable, Sendable, CaseIterable {
    case a0 = "A0"
    case a1 = "A1"
    case a2 = "A2"
    case a3 = "A3"
    case a4 = "A4"
    case a5 = "A5"
    case a6 = "A6"
    case a7 = "A7"
    case a8 = "A8"
    case a9 = "A9"
    case a10 = "A10"
    case a11 = "A11"
    case a12 = "A12"
    case a13 = "A13"
    case _2A0 = "2A0"
    case _4A0 = "4A0"
    case a0plus = "A0+"
    case a1plus = "A1+"
    case a3plus = "A3+"
    case b0 = "B0"
    case b1 = "B1"
    case b2 = "B2"
    case b3 = "B3"
    case b4 = "B4"
    case b5 = "B5"
    case b6 = "B6"
    case b7 = "B7"
    case b8 = "B8"
    case b9 = "B9"
    case b10 = "B10"
    case b11 = "B11"
    case b12 = "B12"
    case b13 = "B13"
    case b0plus = "B0+"
    case b1plus = "B1+"
    case b2plus = "B2+"
    case letter = "Letter"
    case legal = "Legal"
    case tabloid = "Tabloid"
    case ledger = "Ledger"
    case juniorLegal = "Junior Legal"
    case halfLetter = "Half Letter"
    case governmentLetter = "Government Letter"
    case governmentLegal = "Government Legal"
    case ansiA = "ANSI A"
    case ansiB = "ANSI B"
    case ansiC = "ANSI C"
    case ansiD = "ANSI D"
    case ansiE = "ANSI E"
    case archA = "Arch A"
    case archB = "Arch B"
    case archC = "Arch C"
    case archD = "Arch D"
    case archE = "Arch E"
    case archE1 = "Arch E1"
    case archE2 = "Arch E2"
    case archE3 = "Arch E3"
    case passport = "Passport"
    case _2R = "2R"
    case ldDsc = "LD, DSC"
    case _3RL = "3R, L"
    case lw = "LW"
    case kgd = "KGD"
    case _4RKg = "4R, KG"
    case _2LdDscw = "2LD, DSCW"
    case _5R2L = "5R, 2L"
    case _2Lw = "2LW"
    case _6R = "6R"
    case _8R6P = "8R, 6P"
    case s8R6Pw = "S8R, 6PW"
    case _11R = "11R"
    case a3SuperB = "A3+ Super B"
    case berliner = "Berliner"
    case broadsheet = "Broadsheet"
    case usBroadsheet = "US Broadsheet"
    case britishBroadsheet = "British Broadsheet"
    case southAfricanBroadsheet = "South African Broadsheet"
    case ciner = "Ciner"
    case compact = "Compact"
    case nordisch = "Nordisch"
    case rhenish = "Rhenish"
    case swiss = "Swiss"
    case newspaperTabloid = "Newspaper Tabloid"
    case canadianTabloid = "Canadian Tabloid"
    case norwegianTabloid = "Norwegian Tabloid"
    case newYorkTimes = "New York Times"
    case wallStreetJournal = "Wall Street Journal"
    case folio = "Folio"
    case quarto = "Quarto"
    case imperialOctavo = "Imperial Octavo"
    case superOctavo = "Super Octavo"
    case royalOctavo = "Royal Octavo"
    case mediumOctavo = "Medium Octavo"
    case octavo = "Octavo"
    case crownOctavo = "Crown Octavo"
    case _12Mo = "12mo"
    case _16Mo = "16mo"
    case _18Mo = "18mo"
    case _32Mo = "32mo"
    case _48Mo = "48mo"
    case _64Mo = "64mo"
    case aFormat = "A Format"
    case bFormat = "B Format"
    case cFormat = "C Format"

    var aspectRatio: Double {
        PAPER_SIZES[rawValue]!.aspectRatio
    }

}
