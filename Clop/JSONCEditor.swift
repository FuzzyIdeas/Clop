import Foundation

/// Adds and removes one member of one top-level object inside a JSON file,
/// **as text**, so everything else in the file survives byte for byte.
///
/// Agent config files are JSON with comments (Zed ships `settings.json` with a
/// `//` header, VS Code's `mcp.json` allows trailing commas). Reading such a file
/// into a dictionary and writing it back is lossy in a way the user notices: the
/// comments are gone, the key order is gone, and the formatting is whatever the
/// serializer felt like. So this never reserializes. It finds the span the new
/// member belongs in and splices the text there.
///
/// The scanner is deliberately small. It only has to find balanced spans while
/// respecting strings, escapes and both comment forms, which is enough to place
/// a member and to cut one out.
///
/// The same file lives in Crank (`Crank/Core/JSONCEditor.swift`), rcmd
/// (`rcmd/JSONCEditor.swift`) and here, byte for byte. All three install into the
/// same agents' config files, so they must treat them the same way; keep the
/// copies in step.
enum JSONCEditor {
    enum EditError: LocalizedError {
        case notAnObject(String)

        var errorDescription: String? {
            switch self {
            case let .notAnObject(path): "\(path) is not a JSON object."
            }
        }
    }

    /// The file's content as parseable JSON: comments and trailing commas
    /// blanked out, every remaining byte left where it was. Positions in the
    /// result index the original string, which is what lets the writers scan the
    /// clean copy and splice the dirty one.
    static func sanitized(_ text: String) -> String {
        var out = Array(text)
        var i = 0
        var inString = false
        // Offsets of commas that a `]` or `}` turns into trailing commas. Blanked
        // at the end so the parser accepts the file.
        var lastComma: Int?

        while i < out.count {
            let c = out[i]
            if inString {
                if c == "\\" {
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                lastComma = nil
            case "/" where i + 1 < out.count && out[i + 1] == "/":
                // `isNewline`, not `== "\n"`: Swift reads CRLF as ONE Character,
                // so a file with Windows line endings never matched and the
                // first `//` comment blanked the whole rest of the file.
                while i < out.count, !out[i].isNewline {
                    out[i] = " "
                    i += 1
                }
                continue
            case "/" where i + 1 < out.count && out[i + 1] == "*":
                while i < out.count {
                    let end = out[i] == "*" && i + 1 < out.count && out[i + 1] == "/"
                    // Newlines stay, so line numbers in any error still line up.
                    if !out[i].isNewline { out[i] = " " }
                    if end {
                        out[i + 1] = " "
                        i += 2
                        break
                    }
                    i += 1
                }
                continue
            case ",":
                lastComma = i
            case "}", "]":
                if let comma = lastComma { out[comma] = " " }
                lastComma = nil
            case " ", "\t", "\n", "\r":
                break
            default:
                lastComma = nil
            }
            i += 1
        }
        return String(out)
    }

    /// The object at `path`, read through the sanitized copy. `nil` when the file
    /// does not exist; throws when it exists and is not an object even after the
    /// comments come out.
    static func read(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = sanitized(text).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw EditError.notAnObject(url.path)
        }
        return obj
    }

    /// Put `member` under `root[container]`, replacing any member of that name.
    /// Creates the container when it is missing, and the whole file when that is
    /// missing. `member` is written verbatim, so the caller controls its shape.
    static func setMember(in text: String, container: String, name: String, member: String) throws -> String {
        let clean = Array(sanitized(text))
        guard let rootBrace = firstBrace(in: clean, from: 0) else {
            // A file with something in it that is not an object gets refused,
            // never replaced: an array root, a bare string, or anything this
            // scanner could not make sense of is still the user's file, and
            // writing over it loses whatever it held.
            guard clean.allSatisfy(\.isWhitespace) else {
                throw EditError.notAnObject("this file")
            }
            // Empty, whitespace, or comments with no object under them: the
            // file gets one, rather than being refused over content there is
            // nothing to preserve in. Whatever it did hold stays on top.
            let object = "{\n  \"\(container)\": {\n    \"\(name)\": \(indented(member, by: 4))\n  }\n}\n"
            let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return kept.isEmpty ? object : "\(kept)\n\(object)"
        }

        guard let containerSpan = memberValueSpan(in: clean, objectBrace: rootBrace, name: container) else {
            return insert(key: container, member: "{\n\(indent(1))\"\(name)\": \(indented(member, by: 2))\n}", intoObjectAt: rootBrace, text: text, clean: clean)
        }
        guard clean[containerSpan.lowerBound] == "{" else {
            throw EditError.notAnObject("\(container)")
        }
        // Replacing rather than appending keeps a re-install idempotent instead
        // of writing a duplicate key the parser would silently collapse.
        if let existing = memberSpan(in: clean, objectBrace: containerSpan.lowerBound, name: name) {
            let pad = lineIndent(text, at: existing.lowerBound)
            return replace(existing, with: "\"\(name)\": \(indented(member, by: pad.count))", in: text)
        }
        return insert(key: name, member: member, intoObjectAt: containerSpan.lowerBound, text: text, clean: clean)
    }

    /// Drop `root[container][name]`. Returns nil when it was not there, so the
    /// caller can skip the write rather than rewrite the file to say nothing.
    static func removeMember(in text: String, container: String, name: String) -> String? {
        let clean = Array(sanitized(text))
        guard let rootBrace = firstBrace(in: clean, from: 0),
              let containerSpan = memberValueSpan(in: clean, objectBrace: rootBrace, name: container),
              clean[containerSpan.lowerBound] == "{",
              let span = memberSpan(in: clean, objectBrace: containerSpan.lowerBound, name: name)
        else { return nil }
        // Sole member: take the container with it, so uninstalling leaves the
        // file as it found it instead of an empty servers map that was only ever
        // there to hold us. A container with other servers in it stays.
        if memberCount(in: clean, objectBrace: containerSpan.lowerBound) == 1,
           let containerMember = memberSpan(in: clean, objectBrace: rootBrace, name: container)
        {
            return cut(containerMember, in: text, clean: clean)
        }
        return cut(span, in: text, clean: clean)
    }

    // MARK: - Scanning

    private static func firstBrace(in clean: [Character], from start: Int) -> Int? {
        var i = start
        while i < clean.count {
            if clean[i] == "{" { return i }
            if !clean[i].isWhitespace { return nil }
            i += 1
        }
        return nil
    }

    /// Walk the members of the object opening at `objectBrace`, calling `body`
    /// with each key and the range of its whole `"key": value` member.
    private static func forEachMember(
        in clean: [Character],
        objectBrace: Int,
        _ body: (String, Range<Int>, Range<Int>) -> Bool
    ) {
        var i = objectBrace + 1
        while i < clean.count {
            skipSpace(clean, &i)
            guard i < clean.count, clean[i] != "}" else { return }
            guard clean[i] == "\"", let keyEnd = endOfString(clean, from: i) else { return }
            let key = String(clean[(i + 1) ..< keyEnd])
            let memberStart = i
            var j = keyEnd + 1
            skipSpace(clean, &j)
            guard j < clean.count, clean[j] == ":" else { return }
            j += 1
            skipSpace(clean, &j)
            guard j < clean.count, let valueEnd = endOfValue(clean, from: j) else { return }
            if body(key, memberStart ..< valueEnd, j ..< valueEnd) { return }
            i = valueEnd
            skipSpace(clean, &i)
            if i < clean.count, clean[i] == "," { i += 1 }
        }
    }

    private static func memberCount(in clean: [Character], objectBrace: Int) -> Int {
        var count = 0
        forEachMember(in: clean, objectBrace: objectBrace) { _, _, _ in
            count += 1
            return false
        }
        return count
    }

    private static func memberSpan(in clean: [Character], objectBrace: Int, name: String) -> Range<Int>? {
        var found: Range<Int>?
        forEachMember(in: clean, objectBrace: objectBrace) { key, member, _ in
            guard key == name else { return false }
            found = member
            return true
        }
        return found
    }

    private static func memberValueSpan(in clean: [Character], objectBrace: Int, name: String) -> Range<Int>? {
        var found: Range<Int>?
        forEachMember(in: clean, objectBrace: objectBrace) { key, _, value in
            guard key == name else { return false }
            found = value
            return true
        }
        return found
    }

    private static func skipSpace(_ clean: [Character], _ i: inout Int) {
        while i < clean.count, clean[i].isWhitespace {
            i += 1
        }
    }

    private static func endOfString(_ clean: [Character], from start: Int) -> Int? {
        var i = start + 1
        while i < clean.count {
            if clean[i] == "\\" {
                i += 2
                continue
            }
            if clean[i] == "\"" { return i }
            i += 1
        }
        return nil
    }

    /// One past the last character of the value starting at `start`.
    private static func endOfValue(_ clean: [Character], from start: Int) -> Int? {
        switch clean[start] {
        case "\"":
            return endOfString(clean, from: start).map { $0 + 1 }
        case "{", "[":
            var depth = 0
            var i = start
            while i < clean.count {
                switch clean[i] {
                case "\"":
                    guard let end = endOfString(clean, from: i) else { return nil }
                    i = end
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < clean.count, clean[i] != ",", clean[i] != "}", clean[i] != "]" {
                i += 1
            }
            // Trailing space belongs to the gap between members, not the value.
            while i > start, clean[i - 1].isWhitespace {
                i -= 1
            }
            return i
        }
    }

    // MARK: - Splicing

    private static func indent(_ levels: Int) -> String {
        String(repeating: "  ", count: levels)
    }

    /// Re-indent a multi-line member so it sits under its new parent instead of
    /// at column zero.
    private static func indented(_ member: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return member.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset == 0 ? String($0.element) : pad + String($0.element) }
            .joined(separator: "\n")
    }

    private static func range(_ r: Range<Int>, in text: String) -> Range<String.Index> {
        let lower = text.index(text.startIndex, offsetBy: r.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: r.upperBound)
        return lower ..< upper
    }

    private static func replace(_ span: Range<Int>, with entry: String, in text: String) -> String {
        text.replacingCharacters(in: range(span, in: text), with: entry)
    }

    /// The whitespace at the start of the line `offset` sits on. What the file
    /// already uses beats any house style: an editor that reformats the lines
    /// around its own edit is an editor people stop trusting with their config.
    private static func lineIndent(_ text: String, at offset: Int) -> String {
        let chars = Array(text)
        var start = min(offset, chars.count)
        // `isNewline` for the same reason `sanitized` uses it: CRLF is one
        // Character, so a `!= "\n"` walk never finds the line start.
        while start > 0, !chars[start - 1].isNewline {
            start -= 1
        }
        var i = start
        var pad = ""
        while i < chars.count, chars[i] == " " || chars[i] == "\t" {
            pad.append(chars[i])
            i += 1
        }
        return pad
    }

    /// Insert as the FIRST member of the object, which needs no knowledge of
    /// where the last one ends and never lands after a trailing comment.
    ///
    /// Indentation is taken from the member already there, so the entry lands
    /// looking like the rest of the file. An empty object has nothing to copy,
    /// so its own line plus two spaces is the fallback.
    private static func insert(key: String, member: String, intoObjectAt brace: Int, text: String, clean: [Character]) -> String {
        var after = brace + 1
        skipSpace(clean, &after)
        let isEmpty = after >= clean.count || clean[after] == "}"
        let closing = lineIndent(text, at: brace)
        let pad = isEmpty ? closing + "  " : lineIndent(text, at: after)
        let entry = "\"\(key)\": \(indented(member, by: pad.count))"
        let insertion = "\n\(pad)\(entry)\(isEmpty ? "\n\(closing)" : ",")"
        let at = text.index(text.startIndex, offsetBy: brace + 1)
        return text.replacingCharacters(in: at ..< at, with: insertion)
    }

    /// Cut a member and exactly one of the commas around it, so the object is
    /// still valid whether it was first, last or only.
    private static func cut(_ span: Range<Int>, in text: String, clean: [Character]) -> String {
        var lower = span.lowerBound
        var upper = span.upperBound

        var after = upper
        skipSpace(clean, &after)
        if after < clean.count, clean[after] == "," {
            upper = after + 1
        } else {
            // Last member: take the comma in front of it instead, and any blank
            // line that comma left behind.
            var before = lower
            while before > 0, clean[before - 1].isWhitespace {
                before -= 1
            }
            if before > 0, clean[before - 1] == "," { lower = before - 1 }
        }
        // Swallow the member's own leading indentation and newline so removing it
        // does not leave an empty line where it was.
        while lower > 0, clean[lower - 1] == " " || clean[lower - 1] == "\t" {
            lower -= 1
        }
        if lower > 0, clean[lower - 1] == "\n" { lower -= 1 }
        return text.replacingCharacters(in: range(lower ..< upper, in: text), with: "")
    }
}

// MARK: - Symlink resolution

/// Where the bytes of a config file actually live.
///
/// The agent config files this app edits are exactly the ones people keep in a dotfiles repo and
/// symlink into place, and an atomic write against a symlink replaces the link with a regular file.
/// Each component is followed on its own first, so a link whose target does not exist yet still
/// resolves: `resolvingSymlinksInPath()` gives up on a dangling component and would hand back the
/// link's own path, and then the write clobbers the link.
///
/// Returns the input unchanged (just standardized) when nothing is symlinked.
///
/// rcmd keeps this in `ConfigFile.swift`; it lives here in Clop because the MCP installer is its
/// only caller. Keep the two in step.
func resolvedConfigURL(_ url: URL) -> URL {
    let fm = FileManager.default
    /// `destinationOfSymbolicLink` reads the link itself, so it still answers for a link pointing at
    /// something that isn't there.
    func follow(_ url: URL) -> URL {
        var resolved = url.resolvingSymlinksInPath()
        var hops = 0
        while hops < 16, let dest = try? fm.destinationOfSymbolicLink(atPath: resolved.path) {
            let base = resolved.deletingLastPathComponent()
            resolved = URL(fileURLWithPath: dest, relativeTo: base).standardizedFileURL
            hops += 1
        }
        return resolved
    }
    let parent = follow(url.standardizedFileURL.deletingLastPathComponent())
    return follow(parent.appendingPathComponent(url.lastPathComponent))
}
