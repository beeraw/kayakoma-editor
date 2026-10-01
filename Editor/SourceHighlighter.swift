import AppKit

/// Fonts and colours of the source pane: a monospaced face, Markdown marks
/// dimmed, headings in bold, code and links tinted.
struct SourceStyle {
    let fontSize: CGFloat
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let paragraphStyle: NSParagraphStyle
    /// Raises glyphs to the middle of the line height.
    let baselineOffset: CGFloat
    let lineHeight: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        regular = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        bold = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        // 13-point text on 21-point lines.
        let lineHeight = (fontSize * 1.6).rounded()
        let natural = ceil(regular.ascender - regular.descender + regular.leading)
        self.lineHeight = lineHeight
        baselineOffset = max(0, ((lineHeight - natural) / 2).rounded())
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraphStyle = paragraph
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: regular, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle, .baselineOffset: baselineOffset]
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }

    // MARK: Colours

    /// Coral, the Editor's accent, lightened in the dark appearance.
    static let accent = NSColor(light: 0xDD6B55, dark: 0xE9836F)
    static let activeBlockBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xE9836F, alpha: 0.16) : NSColor(hex: 0xDD6B55, alpha: 0.12)
    }
    static let codeColor = NSColor(light: 0x9A5B13, dark: 0xE0A96D)
    static let codeSpanColor = NSColor(light: 0x8A3EA8, dark: 0xD49BEA)
    static let linkColor = NSColor(light: 0x2D6AA8, dark: 0x79B0EA)

    static func color(for kind: MarkdownSyntax.Kind) -> NSColor? {
        switch kind {
        case .heading, .strong, .emphasis, .strikethrough: nil
        case .quote, .fence: .secondaryLabelColor
        case .link, .url: linkColor
        case .listMarker: accent
        case .codeSpan: codeSpanColor
        case .code: codeColor
        case .marker: .tertiaryLabelColor
        }
    }
}

/// Colours the source text as it is edited.
///
/// Edits are noted as they reach the text storage, which keeps the line index
/// and the per-line state in step; `flush` then recolours the edited lines,
/// their neighbours, and the following lines only as long as their state
/// changed (opening a code fence recolours the lines below it, typing a word
/// recolours one line).
@MainActor
final class SourceHighlighter {
    var style: SourceStyle

    private(set) var lines = LineIndex()
    /// What is open at the start of each line.
    private var states: [MarkdownSyntax.State] = [.normal]
    /// Lines to recolour at the next flush.
    private var dirty: Range<Int>?

    init(style: SourceStyle) {
        self.style = style
    }

    /// Starts over with a new text; everything is recoloured at the next flush.
    func reset(_ text: NSString) {
        lines = LineIndex(text)
        states = Array(repeating: .normal, count: lines.lineCount)
        dirty = 0..<lines.lineCount
    }

    /// Marks every line for recolouring, after a change of style.
    func invalidateAll() {
        dirty = 0..<lines.lineCount
    }

    /// Records an edit of the text's characters; see `LineIndex.update`.
    func noteEdit(in text: NSString, editedRange: NSRange, changeInLength: Int) {
        let (removed, inserted) = lines.update(in: text, editedRange: editedRange, changeInLength: changeInLength)
        states.replaceSubrange(removed, with: repeatElement(.normal, count: inserted))
        let edited = removed.lowerBound - 1
        // Neighbours too: a setext underline or a table delimiter row changes the line next to it.
        let low = max(0, edited - 1)
        let high = min(lines.lineCount, edited + inserted + 2)
        if let previous = dirty {
            let shift = inserted - removed.count
            let previousHigh = previous.upperBound > edited ? previous.upperBound + shift : previous.upperBound
            dirty = min(previous.lowerBound, low)..<min(lines.lineCount, max(previousHigh, high))
        } else {
            dirty = low..<high
        }
    }

    /// Recolours the lines marked since the last flush.
    func flush(_ storage: NSTextStorage) {
        guard let range = dirty, !range.isEmpty else {
            dirty = nil
            return
        }
        dirty = nil
        let text = storage.mutableString
        guard text.length == lines.length else {
            // Out of step (an edit that was not noted): start over.
            reset(text)
            dirty = nil
            flush(lines: 0..<lines.lineCount, in: storage)
            return
        }
        flush(lines: range, in: storage)
    }

    private func flush(lines range: Range<Int>, in storage: NSTextStorage) {
        let text = storage.mutableString
        storage.beginEditing()
        defer { storage.endEditing() }
        var line = range.lowerBound
        var previous: [unichar]? = line > 0 ? characters(ofLine: line - 1, in: text) : nil
        var current = characters(ofLine: line, in: text)
        while line < lines.lineCount {
            let next = line + 1 < lines.lineCount ? characters(ofLine: line + 1, in: text) : nil
            let (tokens, nextState) = MarkdownSyntax.tokenize(current, state: states[line], previous: previous, next: next)
            apply(tokens, toLine: line, in: storage)
            guard line + 1 < lines.lineCount else { break }
            if line + 1 >= range.upperBound, states[line + 1] == nextState { break }
            states[line + 1] = nextState
            previous = current
            current = next ?? []
            line += 1
        }
    }

    private func characters(ofLine line: Int, in text: NSMutableString) -> [unichar] {
        let range = lines.range(ofLine: line)
        guard range.length > 0 else { return [] }
        return [unichar](unsafeUninitializedCapacity: range.length) { buffer, count in
            text.getCharacters(buffer.baseAddress!, range: range)
            count = range.length
        }
    }

    private func apply(_ tokens: [MarkdownSyntax.Token], toLine line: Int, in storage: NSTextStorage) {
        let full = lines.rangeWithBreak(ofLine: line)
        guard full.length > 0 else { return }
        storage.setAttributes(style.baseAttributes, range: full)
        guard !tokens.isEmpty else { return }
        let start = full.location
        let length = lines.range(ofLine: line).length
        // Bit 0: bold, bit 1: italic, per character of the line.
        var traits: [UInt8]?
        for token in tokens.sorted(by: { $0.kind < $1.kind }) {
            let range = NSRange(location: start + token.range.location, length: token.range.length)
            guard token.range.length > 0, token.range.upperBound <= length else { continue }
            if let color = SourceStyle.color(for: token.kind) {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            let bit: UInt8
            switch token.kind {
            case .heading, .strong: bit = 1
            case .emphasis, .quote: bit = 2
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                continue
            default: continue
            }
            if traits == nil { traits = [UInt8](repeating: 0, count: length) }
            for index in token.range.location..<token.range.upperBound { traits![index] |= bit }
        }
        guard let traits else { return }
        var runStart = 0
        while runStart < length {
            var runEnd = runStart + 1
            while runEnd < length, traits[runEnd] == traits[runStart] { runEnd += 1 }
            if traits[runStart] != 0 {
                let font = style.font(bold: traits[runStart] & 1 != 0, italic: traits[runStart] & 2 != 0)
                storage.addAttribute(.font, value: font, range: NSRange(location: start + runStart, length: runEnd - runStart))
            }
            runStart = runEnd
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A colour that follows the light or dark appearance it is drawn in.
    convenience init(light: UInt32, dark: UInt32) {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        self.init(name: nil) { $0.isDark ? darkColor : lightColor }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
