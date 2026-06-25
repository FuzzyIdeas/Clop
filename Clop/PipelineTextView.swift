import Cocoa
import Defaults
import Foundation
import Lowtech
import SwiftUI

// MARK: - Pipeline Syntax Highlighting

private let PIPELINE_FONT = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
private let PIPELINE_FONT_BOLD = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

func highlightPipelineText(_ text: String, fileType: ClopFileType?, darkMode: Bool) -> NSAttributedString {
    // The highlighted string is consumed both by an NSTextView and by a SwiftUI
    // `Text(AttributedString(...))` preview. Relying on dynamic NSColors there left some
    // previews stuck in the wrong appearance: the colours were resolved once, at body-eval
    // time, against whatever appearance happened to be current, and never recomputed when
    // the system flipped. We instead resolve every colour against an explicit appearance
    // (driven by `darkMode`) and bake it into a concrete value, and callers re-run
    // highlighting whenever the appearance changes.
    let appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua) ?? NSApplication.shared.effectiveAppearance
    var result = NSMutableAttributedString(string: text)
    appearance.performAsCurrentDrawingAppearance {
        /// Resolve a (possibly dynamic) colour to a concrete sRGB value for the current appearance.
        func baked(_ color: NSColor) -> NSColor {
            color.usingColorSpace(.sRGB) ?? color
        }

        let font = PIPELINE_FONT
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: baked(.labelColor),
        ]
        let mutable = NSMutableAttributedString(string: text, attributes: baseAttrs)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Color arrow separators
        let arrowRegex = try! NSRegularExpression(pattern: #"->"#)
        for match in arrowRegex.matches(in: text, range: fullRange) {
            mutable.addAttributes([
                .foregroundColor: baked(.secondaryLabelColor).withAlphaComponent(0.4),
            ], range: match.range)
        }

        // Split into step segments (between -> and newlines)
        let sepRegex = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
        let sepMatches = sepRegex.matches(in: text, range: fullRange)

        var segmentRanges: [NSRange] = []
        var start = 0
        for match in sepMatches {
            if match.range.location > start {
                segmentRanges.append(NSRange(location: start, length: match.range.location - start))
            }
            start = match.range.location + match.range.length
        }
        if start < nsText.length {
            segmentRanges.append(NSRange(location: start, length: nsText.length - start))
        }

        let templates = stepTemplates(for: fileType)
        let templateNames = Set(templates.map(\.name))

        for segRange in segmentRanges {
            let segText = nsText.substring(with: segRange).trimmingCharacters(in: .whitespaces)
            guard !segText.isEmpty else { continue }

            // Find the trimmed text position within the segment
            let trimmedRange = nsText.range(of: segText, range: segRange)
            guard trimmedRange.location != NSNotFound else { continue }

            // Extract step name
            let parenIndex = segText.firstIndex(of: "(")
            let stepName = parenIndex != nil ? String(segText[..<parenIndex!]) : segText

            if let template = templates.first(where: { $0.name == stepName }) {
                let step = template.create()
                let color = baked(step.categoryNSColor)

                // Color step name bold
                let nameRange = NSRange(location: trimmedRange.location, length: stepName.utf16.count)
                mutable.addAttributes([
                    .foregroundColor: color,
                    .font: PIPELINE_FONT_BOLD,
                ], range: nameRange)

                // Color params: dim param names, prominent param values
                if stepName.count < segText.count {
                    let paramsStr = String(segText[segText.index(segText.startIndex, offsetBy: stepName.count)...])
                    let paramsStart = trimmedRange.location + stepName.utf16.count

                    // Default: dim everything in parens (parens, commas, colons)
                    let paramsRange = NSRange(location: paramsStart, length: trimmedRange.length - stepName.utf16.count)
                    mutable.addAttributes([
                        .foregroundColor: baked(.labelColor).withAlphaComponent(0.8),
                        .font: font,
                    ], range: paramsRange)

                    // Now highlight individual param values more prominently
                    let paramPattern = try! NSRegularExpression(pattern: #"(\w+):\s*([^,\)]+)"#)
                    let paramsNS = paramsStr as NSString
                    let hsbColor = color.usingColorSpace(.displayP3) ?? color
                    for match in paramPattern.matches(in: paramsStr, range: NSRange(location: 0, length: paramsNS.length)) {
                        // Param name: visible but secondary
                        let nameMatchRange = match.range(at: 1)
                        if nameMatchRange.location != NSNotFound {
                            let absRange = NSRange(location: paramsStart + nameMatchRange.location, length: nameMatchRange.length)
                            mutable.addAttributes([
                                .foregroundColor: baked(.secondaryLabelColor),
                            ], range: absRange)
                        }
                        // Param value: prominent with hue shift and boosted saturation
                        let valueMatchRange = match.range(at: 2)
                        if valueMatchRange.location != NSNotFound {
                            let valueStr = paramsNS.substring(with: valueMatchRange).trimmingCharacters(in: .whitespaces)
                            let trimmedValueRange = NSRange(
                                location: paramsStart + valueMatchRange.location + (valueMatchRange.length - valueStr.utf16.count),
                                length: valueStr.utf16.count
                            )

                            // Check if this param value is invalid for the current file type
                            let paramNameStr = paramsNS.substring(with: nameMatchRange)
                            let allParams = template.mandatoryParams + template.optionalParams
                            let paramTemplate = allParams.first(where: { $0.name == paramNameStr })
                            let typeSpecific = fileType.flatMap { paramTemplate?.suggestionsForType[$0] }
                            let unquotedValue = valueStr.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            let isInvalidValue = typeSpecific != nil && !typeSpecific!.contains(unquotedValue)

                            if isInvalidValue {
                                let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                                mutable.addAttributes([
                                    .foregroundColor: baked(.systemRed).withAlphaComponent(0.7),
                                    .font: italicFont,
                                ], range: trimmedValueRange)
                            } else {
                                let valueSatColor = NSColor(
                                    hue: fmod(hsbColor.hueComponent + 0.01, 1.0),
                                    saturation: min(hsbColor.saturationComponent * 0.8, 1.0),
                                    brightness: min(hsbColor.brightnessComponent * (darkMode ? 1.1 : 0.6), 1.0),
                                    alpha: 0.95
                                )
                                mutable.addAttributes([
                                    .foregroundColor: valueSatColor,
                                    .font: PIPELINE_FONT_BOLD,
                                ], range: trimmedValueRange)
                            }
                        }
                    }
                }
            } else if !segText.isEmpty, !templateNames.contains(segText) {
                // Invalid step
                let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                mutable.addAttributes([
                    .foregroundColor: baked(.systemRed).withAlphaComponent(0.7),
                    .font: italicFont,
                ], range: trimmedRange)
            }
        }

        result = mutable
    }

    return result
}

// MARK: - Pipeline Text View (NSTextView wrapper)

struct PipelineTextView: NSViewRepresentable {
    class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        init(_ parent: PipelineTextView) {
            self.parent = parent
        }

        var parent: PipelineTextView
        weak var textView: NSTextView?
        var isEditing = false
        var isHighlighting = false
        var endEditingWorkItem: DispatchWorkItem?
        var lastAppearanceName: NSAppearance.Name?

        func textDidBeginEditing(_ notification: Notification) {
            endEditingWorkItem?.cancel()
            endEditingWorkItem = nil
            isEditing = true
            parent.onEditingChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false

            // Clean up trailing arrow/whitespace
            if let textView {
                var cleaned = textView.string
                cleaned = cleaned.replacingOccurrences(of: #"\s*->\s*$"#, with: "", options: .regularExpression)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                textView.string = cleaned
                parent.text = cleaned
            }
            applySyntaxHighlighting()
            parent.onPrefixChanged?("")

            // Delay dismiss so button clicks in the suggestion/grid area can fire first
            endEditingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.endEditingWorkItem = nil
                self?.parent.onEditingChanged?(false)
            }
            endEditingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }

        func textDidChange(_ notification: Notification) {
            guard !isHighlighting, let textView else { return }

            // Auto-insert " -> " when user types after a closing paren without an arrow
            autoInsertArrow(in: textView)

            parent.text = textView.string
            applySyntaxHighlighting()
            updateCompletionPrefix()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if isEditing { updateCompletionPrefix() }
        }

        // MARK: - Line breaking

        func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
            guard let text = layoutManager.textStorage?.string else { return true }
            let nsText = text as NSString
            // Allow break only right before " -> " (so the arrow starts the next line)
            if charIndex + 3 <= nsText.length {
                let ahead = nsText.substring(with: NSRange(location: charIndex, length: 3))
                if ahead == "-> " || ahead == " ->" { return true }
            }
            return false
        }

        // MARK: - Key handling

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleEnter(textView)
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return handleTab(textView)
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishEditing(in: textView)
                parent.onCancel?()
                return true
            }
            return false
        }

        // MARK: - Insertion

        /// Insert a completion suggestion at the current cursor position.
        func insertSuggestion(_ suggestion: CompletionSuggestion, in textView: NSTextView? = nil) {
            guard let textView = textView ?? self.textView else { return }
            let cursor = textView.selectedRange().location
            let text = textView.string
            let beforeCursor = String(text.prefix(cursor))

            let openCount = beforeCursor.filter { $0 == "(" }.count
            let closeCount = beforeCursor.filter { $0 == ")" }.count
            let insideParens = openCount > closeCount

            if insideParens {
                // Inside parens: figure out what to replace based on suggestion type
                let lastOpenParen: Int = beforeCursor.lastIndex(of: "(").map { beforeCursor.distance(from: beforeCursor.startIndex, to: $0) + 1 } ?? 0
                let lastComma: Int = beforeCursor.lastIndex(of: ",").map { beforeCursor.distance(from: beforeCursor.startIndex, to: $0) + 1 } ?? 0
                let lastSep = max(lastOpenParen, lastComma)
                let currentPart = String(beforeCursor.suffix(from: beforeCursor.index(beforeCursor.startIndex, offsetBy: lastSep)))

                if suggestion.isTemplateVar {
                    // Template variable: replace only the partial "%" at cursor, don't touch the rest
                    let percentPos = beforeCursor.lastIndex(of: "%")
                        .map { beforeCursor.distance(from: beforeCursor.startIndex, to: $0) } ?? cursor
                    let replaceRange = NSRange(location: percentPos, length: cursor - percentPos)
                    textView.replaceCharacters(in: replaceRange, with: suggestion.insertText)
                } else if currentPart.contains(":"), suggestion.needsQuotes {
                    // Value that needs quotes (e.g. "template"): replace value with "" and cursor inside
                    let colonPos = beforeCursor.lastIndex(of: ":")!
                    let replaceStart = beforeCursor.distance(from: beforeCursor.startIndex, to: colonPos) + 1
                    let replaceRange = NSRange(location: replaceStart, length: cursor - replaceStart)
                    textView.replaceCharacters(in: replaceRange, with: " \"\"")
                    let cursorPos = replaceStart + 2 // after the opening quote
                    textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                } else if currentPart.contains(":") {
                    // Completing a value after "paramName: partial" -> only replace after the colon
                    let colonPos = beforeCursor.lastIndex(of: ":")!
                    let replaceStart = beforeCursor.distance(from: beforeCursor.startIndex, to: colonPos) + 1
                    let replaceRange = NSRange(location: replaceStart, length: cursor - replaceStart)
                    let suffix = suggestion.closesParens ? ")" : ", "
                    textView.replaceCharacters(in: replaceRange, with: " " + suggestion.insertText + suffix)
                } else {
                    // Completing a param name -> replace from last separator
                    let replaceRange = NSRange(location: lastSep, length: cursor - lastSep)
                    let afterOpenParen = lastSep > 0 && beforeCursor[beforeCursor.index(beforeCursor.startIndex, offsetBy: lastSep - 1)] == "("
                    let prefix = afterOpenParen ? "" : " "
                    let suffix = suggestion.needsQuotes ? "\"\"" : ""
                    textView.replaceCharacters(in: replaceRange, with: prefix + suggestion.insertText + suffix)
                    if suggestion.needsQuotes {
                        // Place cursor between quotes: `paramName: "|"`
                        let cursorPos = lastSep + (prefix + suggestion.insertText).utf16.count + 1
                        textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                    }
                }
            } else {
                // Outside parens: replace current step segment
                let sepPattern = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
                let beforeMatches = sepPattern.matches(in: beforeCursor, range: NSRange(location: 0, length: beforeCursor.utf16.count))
                var segStart = beforeMatches.last.map { NSMaxRange($0.range) } ?? 0

                let nsText = text as NSString

                // Skip whitespace after separator so we don't eat the space in " -> "
                while segStart < nsText.length, nsText.substring(with: NSRange(location: segStart, length: 1)) == " " {
                    segStart += 1
                }

                let afterRange = NSRange(location: cursor, length: nsText.length - cursor)
                let afterMatches = sepPattern.matches(in: text, range: afterRange)
                let segEnd = afterMatches.first?.range.location ?? nsText.length

                let replaceRange = NSRange(location: segStart, length: segEnd - segStart)
                var insertText = suggestion.opensParens ? suggestion.insertText + "(" : suggestion.insertText
                if suggestion.needsQuotes, !suggestion.opensParens {
                    // Single mandatory param with quotes: `copy(to: "|")`
                    insertText += "\""
                }
                textView.replaceCharacters(in: replaceRange, with: insertText)
                if suggestion.needsQuotes, !suggestion.opensParens {
                    // Place cursor between quotes
                    let cursorPos = segStart + insertText.utf16.count - 1
                    textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                }
            }

            parent.text = textView.string
            applySyntaxHighlighting()
            updateCompletionPrefix()
        }

        /// Append a step at the end of the pipeline text.
        func appendStep(_ stepText: String) {
            guard let textView else { return }

            let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                textView.string = stepText
            } else {
                textView.string = trimmed + " -> " + stepText
            }
            parent.text = textView.string
            applySyntaxHighlighting()

            // Move cursor to end
            let endPos = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            updateCompletionPrefix()
        }

        /// Refocus the text view after an external button click.
        func refocus() {
            endEditingWorkItem?.cancel()
            endEditingWorkItem = nil
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            isEditing = true
            parent.onEditingChanged?(true)
        }

        // MARK: - Highlighting

        func applySyntaxHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let selectedRanges = textView.selectedRanges
            let darkMode = (textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua) == .darkAqua
            let highlighted = highlightPipelineText(textView.string, fileType: parent.fileType, darkMode: darkMode)

            storage.beginEditing()
            storage.setAttributedString(highlighted)
            storage.endEditing()

            textView.selectedRanges = selectedRanges
        }

        func updateCompletionPrefix() {
            guard let textView else { return }
            let prefix = extractCurrentStepPrefix(text: textView.string, cursor: textView.selectedRange().location)
            parent.onPrefixChanged?(prefix)
        }

        /// If the user typed a letter after `)` (with optional spaces) without ` -> `, insert the arrow.
        private func autoInsertArrow(in textView: NSTextView) {
            let text = textView.string
            let cursor = textView.selectedRange().location
            guard cursor >= 2 else { return }

            let nsText = text as NSString

            // The just-typed character must be a letter
            let typedChar = nsText.substring(with: NSRange(location: cursor - 1, length: 1))
            guard typedChar.rangeOfCharacter(from: .letters) != nil else { return }

            // Walk backwards from cursor-2 to find `)`, skipping spaces
            var pos = cursor - 2
            while pos >= 0, nsText.substring(with: NSRange(location: pos, length: 1)) == " " {
                pos -= 1
            }
            guard pos >= 0, nsText.substring(with: NSRange(location: pos, length: 1)) == ")" else { return }

            // Also make sure there isn't already a `->` between `)` and the typed char
            let between = nsText.substring(with: NSRange(location: pos + 1, length: cursor - 1 - (pos + 1)))
            guard !between.contains("->") else { return }

            // Replace spaces between ) and the typed char with " -> "
            let replaceRange = NSRange(location: pos + 1, length: cursor - 1 - (pos + 1))
            textView.replaceCharacters(in: replaceRange, with: " -> ")
            let newCursor = pos + 1 + 5 // after ") -> " then the typed char is already at +5
            textView.setSelectedRange(NSRange(location: newCursor, length: 0))
        }

        private func handleTab(_ textView: NSTextView) -> Bool {
            let prefix = extractCurrentStepPrefix(text: textView.string, cursor: textView.selectedRange().location)
            let suggestions = pipelineSuggestions(prefix: prefix, fileType: parent.fileType)

            if suggestions.isEmpty {
                // No suggestions left - if inside parens, all params used, commit step
                let cursor = textView.selectedRange().location
                let beforeCursor = String(textView.string.prefix(cursor))
                let insideParens = beforeCursor.filter { $0 == "(" }.count > beforeCursor.filter { $0 == ")" }.count
                if insideParens {
                    commitCurrentStep(in: textView)
                }
                return true
            }

            let suggestion = suggestions.first!
            insertSuggestion(suggestion, in: textView)

            // After inserting a param value, check if all params are now used
            let isParamValue = !suggestion.opensParens && !suggestion.needsQuotes && !suggestion.insertText.hasSuffix(": ") && !suggestion.isTemplateVar
            if isParamValue {
                checkAutoCloseParens(in: textView)
            }
            return true
        }

        private func handleEnter(_ textView: NSTextView) -> Bool {
            let cursor = textView.selectedRange().location
            let text = textView.string

            // Check if cursor is inside parentheses
            let beforeCursor = String(text.prefix(cursor))
            let openCount = beforeCursor.filter { $0 == "(" }.count
            let closeCount = beforeCursor.filter { $0 == ")" }.count

            if openCount > closeCount {
                // Inside parens: commit step, close parens, add ->
                commitCurrentStep(in: textView)
            } else {
                // Top level: the steps are submitted, so let the host editor save the whole pipeline.
                finishEditing(in: textView)
                parent.onSubmit?()
            }
            return true
        }

        /// Clean up trailing arrow/whitespace and exit editing.
        private func finishEditing(in textView: NSTextView) {
            var cleaned = textView.string
            cleaned = cleaned.replacingOccurrences(of: #"\s*->\s*$"#, with: "", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            textView.string = cleaned
            parent.text = cleaned
            applySyntaxHighlighting()
            textView.window?.makeFirstResponder(nil)
        }

        /// Close the current step's parens, clean up trailing commas, add ` -> `.
        private func commitCurrentStep(in textView: NSTextView) {
            var text = textView.string
            let cursor = textView.selectedRange().location

            // Find the unclosed open paren
            let beforeCursor = String(text.prefix(cursor))
            guard let openParenIdx = beforeCursor.lastIndex(of: "(") else { return }
            let openPos = beforeCursor.distance(from: beforeCursor.startIndex, to: openParenIdx)

            // Find end of current step segment (next -> or end of text)
            let nsText = text as NSString
            let sepPattern = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
            let afterOpen = NSRange(location: openPos, length: nsText.length - openPos)
            let segEnd = sepPattern.firstMatch(in: text, range: afterOpen)?.range.location ?? nsText.length

            // Get content inside parens (from open paren to segment end)
            let insideStart = text.index(text.startIndex, offsetBy: openPos + 1)
            let insideEnd = text.index(text.startIndex, offsetBy: segEnd)
            var inside = String(text[insideStart ..< insideEnd])

            // Clean trailing comma, whitespace, unclosed quotes, existing close parens
            inside = inside.replacingOccurrences(of: #"[,\s\)]*$"#, with: "", options: .regularExpression)
            // Ensure balanced quotes
            let quoteCount = inside.filter { $0 == "\"" }.count
            if quoteCount % 2 != 0 { inside += "\"" }

            // Rebuild: everything before open paren + (inside) + -> + rest after segment end
            let before = String(text.prefix(openPos + 1))
            let after = segEnd < nsText.length ? String(text.suffix(from: text.index(text.startIndex, offsetBy: segEnd))) : ""
            text = before + inside + ")" + after + " -> "

            textView.string = text
            parent.text = text
            applySyntaxHighlighting()

            // Move cursor to end (after the ->)
            let endPos = (text as NSString).length
            textView.setSelectedRange(NSRange(location: endPos, length: 0))
            updateCompletionPrefix()
        }

        /// After inserting a param value, check if all params for the current step are used.
        /// If so, auto-close parens and move to next step.
        private func checkAutoCloseParens(in textView: NSTextView) {
            let prefix = extractCurrentStepPrefix(text: textView.string, cursor: textView.selectedRange().location)
            let remaining = pipelineSuggestions(prefix: prefix, fileType: parent.fileType)
            if remaining.isEmpty {
                // All params used - commit
                commitCurrentStep(in: textView)
            }
        }

    }

    @Binding var text: String

    let fileType: ClopFileType?
    let placeholder: String
    var onEditingChanged: ((Bool) -> Void)?
    var onPrefixChanged: ((String) -> Void)?
    /// Called when the user presses Enter at the top level (steps submitted). Lets the host editor save.
    var onSubmit: (() -> Void)?
    /// Called when the user presses Esc. Lets the host editor cancel.
    var onCancel: (() -> Void)?
    var coordinatorRef: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = PIPELINE_FONT
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 3)
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        textView.layoutManager?.delegate = context.coordinator
        coordinatorRef?(context.coordinator)

        // Initial content
        textView.string = text
        context.coordinator.applySyntaxHighlighting()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        let currentAppearance = nsView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let appearanceChanged = currentAppearance != context.coordinator.lastAppearanceName
        if appearanceChanged {
            context.coordinator.lastAppearanceName = currentAppearance
        }

        // Don't stomp while user is editing or during delayed dismiss
        guard !context.coordinator.isEditing, context.coordinator.endEditingWorkItem == nil else { return }

        if textView.string != text {
            textView.string = text
            context.coordinator.applySyntaxHighlighting()
        } else if appearanceChanged {
            context.coordinator.applySyntaxHighlighting()
        }
    }

    @Environment(\.colorScheme) private var colorScheme

}

private func extractCurrentStepPrefix(text: String, cursor: Int) -> String {
    let nsText = text as NSString
    guard cursor <= nsText.length else { return "" }

    let beforeCursor = nsText.substring(to: cursor)

    // Find last separator (-> or newline)
    let sepPattern = try! NSRegularExpression(pattern: #"(?:->|\n|\r\n)"#)
    let matches = sepPattern.matches(in: beforeCursor, range: NSRange(location: 0, length: beforeCursor.utf16.count))

    let stepStart: Int = if let lastMatch = matches.last {
        NSMaxRange(lastMatch.range)
    } else {
        0
    }

    return nsText.substring(with: NSRange(location: stepStart, length: cursor - stepStart))
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - Completion Panel
