import Foundation
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "FileNameTemplate")

final class NanoID {
    init(alphabet: NanoIDAlphabet..., size: Int) {
        self.size = size
        self.alphabet = NanoIDHelper.parse(alphabet)
    }

    static func new() -> String {
        NanoIDHelper.generate(from: defaultAphabet, of: defaultSize)
    }

    static func new(alphabet: NanoIDAlphabet..., size: Int) -> String {
        let charactersString = NanoIDHelper.parse(alphabet)
        return NanoIDHelper.generate(from: charactersString, of: size)
    }

    static func new(_ size: Int) -> String {
        NanoIDHelper.generate(from: NanoID.defaultAphabet, of: size)
    }

    static func random(maxSize: Int = 40) -> String {
        maxSize < 10
            ? NanoID.new(alphabet: .all, size: maxSize)
            : NanoIDHelper.generate(from: NanoIDAlphabet.all.toString(), of: arc4random_uniform((maxSize - 10).u32).i + 10)
    }

    func new() -> String {
        NanoIDHelper.generate(from: alphabet, of: size)
    }

    private static let defaultSize = 21
    private static let defaultAphabet = NanoIDAlphabet.urlSafe.toString()

    private var size: Int
    private var alphabet: String
}

extension Int {
    var u32: UInt32 {
        UInt32(self)
    }
}

extension UInt32 {
    var i: Int {
        Int(self)
    }
}

// MARK: - NanoIDHelper

private enum NanoIDHelper {
    static func parse(_ alphabets: [NanoIDAlphabet]) -> String {
        var stringCharacters = ""

        for alphabet in alphabets {
            stringCharacters.append(alphabet.toString())
        }

        return stringCharacters
    }

    static func generate(from alphabet: String, of length: Int) -> String {
        var nanoID = ""

        for _ in 0 ..< length {
            let randomCharacter = NanoIDHelper.randomCharacter(from: alphabet)
            nanoID.append(randomCharacter)
        }

        return nanoID
    }

    static func randomCharacter(from string: String) -> Character {
        let randomNum = arc4random_uniform(string.count.u32).i
        let randomIndex = string.index(string.startIndex, offsetBy: randomNum)
        return string[randomIndex]
    }
}

// MARK: - NanoIDAlphabet

enum NanoIDAlphabet {
    case urlSafe
    case uppercasedLatinLetters
    case lowercasedLatinLetters
    case numbers
    case symbols
    case all

    func toString() -> String {
        switch self {
        case .uppercasedLatinLetters, .lowercasedLatinLetters, .numbers, .symbols:
            chars()
        case .urlSafe:
            "\(NanoIDAlphabet.uppercasedLatinLetters.chars())\(NanoIDAlphabet.lowercasedLatinLetters.chars())\(NanoIDAlphabet.numbers.chars())~_"
        case .all:
            "\(NanoIDAlphabet.uppercasedLatinLetters.chars())\(NanoIDAlphabet.lowercasedLatinLetters.chars())\(NanoIDAlphabet.numbers.chars())\(NanoIDAlphabet.symbols.chars())"
        }
    }

    private func chars() -> String {
        switch self {
        case .uppercasedLatinLetters:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        case .lowercasedLatinLetters:
            "abcdefghijklmnopqrstuvwxyz"
        case .numbers:
            "1234567890"
        case .symbols:
            "§±!@#$%^&*()_+-=[]{};':,.<>?`~ /|"
        default:
            ""
        }
    }
}

enum FileNameToken: String {
    case year = "%y"
    case monthNumeric = "%m"
    case monthName = "%n"
    case day = "%d"
    case weekday = "%w"
    case hour = "%H"
    case minutes = "%M"
    case seconds = "%S"
    case amPm = "%p"
    case randomCharacters = "%r"
    case autoIncrementingNumber = "%i"
    case filename = "%f"
    case ext = "%e"
    case path = "%P"
    case fullPath = "%F"
}

func generateFilePath(template: FilePath, for path: FilePath? = nil, autoIncrementingNumber: inout Int, mkdir: Bool) throws -> FilePath {
    let num_ = autoIncrementingNumber
    log.trace("Generating file path from '\(template.string)' for '\(path?.string ?? "NOPATH")' [num: \(num_), mkdir: \(mkdir)]")
    let num = autoIncrementingNumber + 1
    var placeholderNum = 0

    var newpath = template
    newpath.components = FilePath.ComponentView(
        newpath.components.map { component in
            FilePath(
                generateFileName(
                    template: component.string, for: path,
                    autoIncrementingNumber: &placeholderNum,
                    safe: !component.string.contains(FileNameToken.path.rawValue) && !component.string.contains(FileNameToken.fullPath.rawValue)
                )
            ).components.map { $0 }
        }.joined()
    )
    if newpath.isRelative, let path {
        let startsWithAbsolute = template.components.first?.string == FileNameToken.path.rawValue || template.components.first?.string == FileNameToken.fullPath.rawValue
        newpath = (startsWithAbsolute ? FilePath("/") : path.dir).appending(newpath.components)
    }

    newpath = newpath.lexicallyNormalized()
    if mkdir {
        let name = newpath.name.string
        let dir = (name.last == "/" || !name.contains(".")) ? newpath : newpath.dir
        guard dir.mkdir(withIntermediateDirectories: true) else {
            log.error("Could not create output directory '\(dir.string)'")
            throw ClopError.couldNotCreateOutputDirectory(dir.string)
        }
    }

    if !SWIFTUI_PREVIEW, template.string.contains(FileNameToken.autoIncrementingNumber.rawValue) {
        autoIncrementingNumber = num
    }
    do {
        let num2_ = autoIncrementingNumber
        log.trace("Generated file path \(newpath.string) [template: '\(template)', path: '\(path?.string ?? "NOPATH")', num: \(num2_), mkdir: \(mkdir)]")
    }
    return newpath
}

func generateFilePath(template: String, for path: FilePath? = nil, autoIncrementingNumber: inout Int, mkdir: Bool) throws -> FilePath? {
    let num_ = autoIncrementingNumber
    log.trace("Generating file path from '\(template)' for '\(path?.string ?? "NOPATH")' [num: \(num_), mkdir: \(mkdir)]")
    let pathString = generateFileName(template: template, for: path, autoIncrementingNumber: &autoIncrementingNumber, safe: false)
    guard var newpath = pathString.filePath?.lexicallyNormalized() else {
        return nil
    }
    newpath.components = FilePath.ComponentView(
        newpath.components.map {
            FilePath.Component($0.string.safeFilename) ?? $0
        }
    )
    if newpath.isRelative, let path {
        newpath = path.dir.appending(newpath.components)
    }
    if mkdir {
        let name = newpath.name.string
        let dir = (name.last == "/" || !name.contains(".")) ? newpath : newpath.dir
        guard dir.mkdir(withIntermediateDirectories: true) else {
            log.error("Could not create output directory '\(dir.string)'")
            throw ClopError.couldNotCreateOutputDirectory(dir.string)
        }
    }
    do {
        let num2_ = autoIncrementingNumber
        log.trace("Generated file path \(newpath.string) [template: '\(template)', path: '\(path?.string ?? "NOPATH")', num: \(num2_), mkdir: \(mkdir)]")
    }
    return newpath
}

func generateFileName(template: String, for path: FilePath? = nil, autoIncrementingNumber: inout Int, safe: Bool = true) -> String {
    var name = template
    let date = Date()
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
    let num = autoIncrementingNumber + 1

    name = name.replacingOccurrences(of: FileNameToken.year.rawValue, with: String(format: "%04d", components.year!))
        .replacingOccurrences(of: FileNameToken.monthNumeric.rawValue, with: String(format: "%02d", components.month!))
        .replacingOccurrences(of: FileNameToken.monthName.rawValue, with: calendar.monthSymbols[components.month! - 1])
        .replacingOccurrences(of: FileNameToken.day.rawValue, with: String(format: "%02d", components.day!))
        .replacingOccurrences(of: FileNameToken.weekday.rawValue, with: String(components.weekday!))
        .replacingOccurrences(of: FileNameToken.hour.rawValue, with: String(format: "%02d", components.hour!))
        .replacingOccurrences(of: FileNameToken.minutes.rawValue, with: String(format: "%02d", components.minute!))
        .replacingOccurrences(of: FileNameToken.seconds.rawValue, with: String(format: "%02d", components.second!))
        .replacingOccurrences(of: FileNameToken.amPm.rawValue, with: components.hour! > 12 ? "PM" : "AM")
        .replacingOccurrences(of: FileNameToken.randomCharacters.rawValue, with: NanoID.new(alphabet: .lowercasedLatinLetters, size: 5))
        .replacingOccurrences(of: FileNameToken.autoIncrementingNumber.rawValue, with: num.s)
        .replacingOccurrences(of: FileNameToken.fullPath.rawValue, with: path?.string ?? "")
        .replacingOccurrences(of: FileNameToken.path.rawValue, with: path?.dir.string ?? "")
        .replacingOccurrences(of: FileNameToken.filename.rawValue, with: path?.stem ?? "")
        .replacingOccurrences(of: FileNameToken.ext.rawValue, with: path?.extension ?? "")

    if safe {
        name = name.safeFilename
    }
    if let ext = path?.extension {
        name = "\(name).\(ext)"
    }

    if !SWIFTUI_PREVIEW, template.contains(FileNameToken.autoIncrementingNumber.rawValue) {
        autoIncrementingNumber = num
    }

    return name
}

extension FileNameToken {
    /// Regex pattern matching the values this token can generate, used by
    /// `nameMatchesTemplate` to recognise names already produced by a template.
    var matchPattern: String {
        switch self {
        case .year: #"\d{4}"#
        case .monthNumeric, .day, .hour, .minutes, .seconds: #"\d{2}"#
        case .monthName: "[A-Za-z]+"
        case .weekday: #"\d"#
        case .amPm: "AM|PM"
        case .randomCharacters: "[a-z]{5}"
        case .autoIncrementingNumber: #"\d+"#
        case .ext: "[^./]+"
        case .filename, .path, .fullPath: ".+"
        }
    }
}

/// Whether `name` could have been generated by `template`. Used to keep a naming
/// template from being applied twice to the same file (e.g. `%f-opt` turning
/// `kitty-opt` into `kitty-opt-opt` on re-optimisation).
func nameMatchesTemplate(_ name: String, template: String, allowPathPrefix: Bool = false) -> Bool {
    guard !template.isEmpty else { return false }

    var pattern = allowPathPrefix ? "^(?:.*/)?" : "^"
    var rest = Substring(template)
    while let pct = rest.firstIndex(of: "%") {
        pattern += NSRegularExpression.escapedPattern(for: String(rest[..<pct]))
        let tokenEnd = rest.index(pct, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
        if let token = FileNameToken(rawValue: String(rest[pct ..< tokenEnd])) {
            pattern += "(?:\(token.matchPattern))"
        } else {
            pattern += NSRegularExpression.escapedPattern(for: String(rest[pct ..< tokenEnd]))
        }
        rest = rest[tokenEnd...]
    }
    pattern += NSRegularExpression.escapedPattern(for: String(rest))
    pattern += "$"

    return name.range(of: pattern, options: .regularExpression) != nil
}
