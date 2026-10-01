import Foundation

/// A line-by-line Markdown tokenizer for colouring the source.
///
/// It is not a parser: it recognises what a writer needs to see (headings,
/// emphasis, code, links, list markers, quotes, table pipes) with the
/// CommonMark rules simplified to what one line and its two neighbours show.
/// The only state carried from line to line is whether a fenced code block is
/// open, so that an edit recolours its own lines and, at most, the lines whose
/// state it changes.
enum MarkdownSyntax {
    /// What is open at the start of a line.
    enum State: Hashable, Sendable {
        case normal
        /// Inside a fenced code block opened by `length` times `marker` (a backtick or a tilde).
        case fencedCode(marker: unichar, length: Int)
    }

    /// Kinds of tokens, in the order they are applied: a later kind wins over
    /// an earlier one for the colour of the characters they share.
    enum Kind: Int, Comparable, Sendable, CaseIterable {
        /// A whole heading line (bold).
        case heading
        /// Text inside a block quote (italic, secondary colour).
        case quote
        case strong
        case emphasis
        case strikethrough
        /// The text of a link or image.
        case link
        /// A URL: autolinks, bare URLs, link definition destinations.
        case url
        /// A list bullet or number, with its task box.
        case listMarker
        /// An inline code span, backticks included.
        case codeSpan
        /// A line inside a fenced code block.
        case code
        /// The opening or closing line of a fenced code block.
        case fence
        /// Markdown punctuation: `#`, `>`, `**`, `[`, `](…)`, table pipes, rules…
        case marker

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Token: Equatable, Sendable {
        var kind: Kind
        /// Range in the line, in UTF-16 units.
        var range: NSRange

        init(_ kind: Kind, _ location: Int, _ length: Int) {
            self.kind = kind
            self.range = NSRange(location: location, length: length)
        }
    }

    /// Tokens of one line, and the state at the start of the next.
    ///
    /// - Parameters:
    ///   - previous: the line before, to tell a setext underline from a rule.
    ///   - next: the line after, for setext headings and tables.
    static func tokenize(_ line: [unichar], state: State, previous: [unichar]? = nil, next: [unichar]? = nil) -> (tokens: [Token], state: State) {
        var tokens: [Token] = []
        let count = line.count

        if case .fencedCode(let marker, let length) = state {
            if isClosingFence(line, marker: marker, length: length) {
                tokens.append(Token(.fence, 0, count))
                return (tokens, .normal)
            }
            if count > 0 { tokens.append(Token(.code, 0, count)) }
            return (tokens, state)
        }

        if let fence = openingFence(line) {
            tokens.append(Token(.fence, 0, count))
            return (tokens, .fencedCode(marker: fence.marker, length: fence.length))
        }

        let indent = leadingSpaces(line, from: 0)

        // ATX heading.
        if indent <= 3, let headingEnd = atxMarkerEnd(line, from: indent) {
            tokens.append(Token(.heading, 0, count))
            let markerEnd = min(count, headingEnd + 1)
            tokens.append(Token(.marker, 0, markerEnd))
            var contentEnd = count
            if let closing = atxClosingSequence(line, from: markerEnd) {
                tokens.append(Token(.marker, closing, count - closing))
                contentEnd = closing
            }
            inlineTokens(line, from: markerEnd, to: contentEnd, into: &tokens)
            return (tokens, .normal)
        }

        // Setext underline, or a thematic break.
        if isSetextUnderline(line), let previous, isParagraphText(previous) {
            tokens.append(Token(.marker, 0, count))
            return (tokens, .normal)
        }
        if isThematicBreak(line) {
            tokens.append(Token(.marker, 0, count))
            return (tokens, .normal)
        }

        // Link reference definition: `[label]: destination`.
        if indent <= 3, let definition = linkDefinition(line, from: indent) {
            tokens.append(Token(.marker, indent, definition.labelEnd - indent))
            if definition.urlRange.length > 0 {
                tokens.append(Token(.url, definition.urlRange.location, definition.urlRange.length))
            }
            return (tokens, .normal)
        }

        // Block quote markers, possibly nested.
        var position = 0
        var isQuote = false
        while true {
            let spaces = leadingSpaces(line, from: position)
            guard spaces <= 3, position + spaces < count, line[position + spaces] == .greaterThan else { break }
            var end = position + spaces + 1
            if end < count, line[end] == .space { end += 1 }
            tokens.append(Token(.marker, position + spaces, end - position - spaces))
            position = end
            isQuote = true
        }
        if isQuote, position < count {
            tokens.append(Token(.quote, position, count - position))
        }

        // List item marker, with its task box.
        if let marker = listMarker(line, from: position) {
            tokens.append(Token(.listMarker, marker.location, marker.length))
            position = marker.location + marker.length
        }

        // Setext heading text: the line above a `===` or `---` underline.
        if !isQuote, position == 0, let next, isSetextUnderline(next), isParagraphText(line) {
            tokens.append(Token(.heading, 0, count))
        }

        // Tables: the delimiter row, and the pipes of the other rows.
        if isDelimiterRow(line) {
            tokens.append(Token(.marker, 0, count))
            return (tokens, .normal)
        }
        let isTableRow = line.contains(.pipe)
            && (firstNonSpace(line, from: position).map { line[$0] == .pipe } == true
                || previous.map(isDelimiterRow) == true || next.map(isDelimiterRow) == true)
        inlineTokens(line, from: position, to: count, tablePipes: isTableRow, into: &tokens)
        return (tokens, .normal)
    }

    // MARK: - Blocks

    private static func leadingSpaces(_ line: [unichar], from start: Int) -> Int {
        var index = start
        while index < line.count, line[index] == .space || line[index] == .tab { index += 1 }
        return index - start
    }

    private static func firstNonSpace(_ line: [unichar], from start: Int) -> Int? {
        let index = start + leadingSpaces(line, from: start)
        return index < line.count ? index : nil
    }

    static func isBlank(_ line: [unichar]) -> Bool {
        line.allSatisfy { $0 == .space || $0 == .tab }
    }

    private static func run(of character: unichar, in line: [unichar], from start: Int) -> Int {
        var index = start
        while index < line.count, line[index] == character { index += 1 }
        return index - start
    }

    private static func openingFence(_ line: [unichar]) -> (marker: unichar, length: Int)? {
        let indent = leadingSpaces(line, from: 0)
        guard indent <= 3, indent < line.count else { return nil }
        let marker = line[indent]
        guard marker == .backtick || marker == .tilde else { return nil }
        let length = run(of: marker, in: line, from: indent)
        guard length >= 3 else { return nil }
        // A backtick fence's info string cannot hold a backtick.
        if marker == .backtick, line[(indent + length)...].contains(.backtick) { return nil }
        return (marker, length)
    }

    private static func isClosingFence(_ line: [unichar], marker: unichar, length: Int) -> Bool {
        let indent = leadingSpaces(line, from: 0)
        guard indent <= 3 else { return false }
        let fence = run(of: marker, in: line, from: indent)
        return fence >= length && leadingSpaces(line, from: indent + fence) == line.count - indent - fence
    }

    /// End of the `#` run of an ATX heading starting at `start`.
    private static func atxMarkerEnd(_ line: [unichar], from start: Int) -> Int? {
        let hashes = run(of: .hash, in: line, from: start)
        guard (1...6).contains(hashes) else { return nil }
        let end = start + hashes
        guard end == line.count || line[end] == .space || line[end] == .tab else { return nil }
        return end
    }

    /// Start of an optional closing `#` sequence, with the spaces before it.
    private static func atxClosingSequence(_ line: [unichar], from start: Int) -> Int? {
        var end = line.count
        while end > start, line[end - 1] == .space || line[end - 1] == .tab { end -= 1 }
        var hashStart = end
        while hashStart > start, line[hashStart - 1] == .hash { hashStart -= 1 }
        guard hashStart < end else { return nil }
        guard hashStart == start || line[hashStart - 1] == .space || line[hashStart - 1] == .tab else { return nil }
        var spaceStart = hashStart
        while spaceStart > start, line[spaceStart - 1] == .space || line[spaceStart - 1] == .tab { spaceStart -= 1 }
        return spaceStart
    }

    static func isSetextUnderline(_ line: [unichar]) -> Bool {
        let indent = leadingSpaces(line, from: 0)
        guard indent <= 3, indent < line.count else { return false }
        let marker = line[indent]
        guard marker == .equals || marker == .hyphen else { return false }
        let length = run(of: marker, in: line, from: indent)
        return leadingSpaces(line, from: indent + length) == line.count - indent - length
    }

    static func isThematicBreak(_ line: [unichar]) -> Bool {
        let indent = leadingSpaces(line, from: 0)
        guard indent <= 3, indent < line.count else { return false }
        let marker = line[indent]
        guard marker == .hyphen || marker == .asterisk || marker == .underscore else { return false }
        var markers = 0
        for character in line[indent...] {
            if character == marker { markers += 1 } else if character != .space && character != .tab { return false }
        }
        return markers >= 3
    }

    /// Text that a setext underline would turn into a heading: not blank, and
    /// not another kind of block.
    private static func isParagraphText(_ line: [unichar]) -> Bool {
        guard !isBlank(line), leadingSpaces(line, from: 0) <= 3 else { return false }
        let start = leadingSpaces(line, from: 0)
        if line[start] == .greaterThan || atxMarkerEnd(line, from: start) != nil { return false }
        if listMarker(line, from: 0) != nil || openingFence(line) != nil { return false }
        if isThematicBreak(line) || isSetextUnderline(line) || isDelimiterRow(line) { return false }
        return true
    }

    /// Range of a list item's marker (`- `, `12. `, `- [x] `) from `start`.
    static func listMarker(_ line: [unichar], from start: Int) -> NSRange? {
        let markerStart = start + leadingSpaces(line, from: start)
        guard markerStart < line.count else { return nil }
        var end: Int
        let first = line[markerStart]
        if first == .hyphen || first == .asterisk || first == .plus {
            end = markerStart + 1
        } else if first.isDigit {
            end = markerStart
            while end < line.count, line[end].isDigit, end - markerStart < 9 { end += 1 }
            guard end < line.count, line[end] == .period || line[end] == .closingParenthesis else { return nil }
            end += 1
        } else {
            return nil
        }
        guard end == line.count || line[end] == .space || line[end] == .tab else { return nil }
        if end < line.count, first == .hyphen || first == .asterisk, isThematicBreak(line) { return nil }
        end += min(leadingSpaces(line, from: end), 4)
        // Task box.
        if end + 2 < line.count, line[end] == .openingBracket, line[end + 2] == .closingBracket,
           [unichar.space, .lowercaseX, .uppercaseX].contains(line[end + 1]),
           end + 3 == line.count || line[end + 3] == .space {
            end = min(line.count, end + 4)
        }
        return NSRange(location: markerStart, length: end - markerStart)
    }

    static func isDelimiterRow(_ line: [unichar]) -> Bool {
        var hasPipe = false
        var hasHyphen = false
        for character in line {
            switch character {
            case .pipe: hasPipe = true
            case .hyphen: hasHyphen = true
            case .colon, .space, .tab: break
            default: return false
            }
        }
        return hasPipe && hasHyphen
    }

    private static func linkDefinition(_ line: [unichar], from start: Int) -> (labelEnd: Int, urlRange: NSRange)? {
        guard start + 1 < line.count, line[start] == .openingBracket else { return nil }
        var index = start + 1
        while index < line.count, line[index] != .closingBracket {
            if line[index] == .openingBracket { return nil }
            index += 1
        }
        guard index > start + 1, index + 1 < line.count, line[index + 1] == .colon else { return nil }
        let labelEnd = index + 2
        let urlStart = labelEnd + leadingSpaces(line, from: labelEnd)
        var urlEnd = urlStart
        while urlEnd < line.count, line[urlEnd] != .space, line[urlEnd] != .tab { urlEnd += 1 }
        return (labelEnd, NSRange(location: urlStart, length: urlEnd - urlStart))
    }

    // MARK: - Inlines

    private static func inlineTokens(_ line: [unichar], from start: Int, to end: Int, tablePipes: Bool = false, into tokens: inout [Token]) {
        guard start < end else { return }
        // Characters already claimed by a code span, URL or link destination.
        var claimed = [Bool](repeating: false, count: line.count)
        func claim(_ from: Int, _ to: Int) {
            for index in from..<to { claimed[index] = true }
        }

        // Code spans first: nothing inside them is Markdown.
        var index = start
        while index < end {
            let character = line[index]
            // An escaped backtick does not open a code span.
            if character == .backslash {
                index += 2
                continue
            }
            guard character == .backtick else { index += 1; continue }
            let length = run(of: .backtick, in: line, from: index)
            var search = index + length
            var closing: Int?
            while search < end {
                if line[search] == .backtick {
                    let other = run(of: .backtick, in: line, from: search)
                    if other == length { closing = search; break }
                    search += other
                } else {
                    search += 1
                }
            }
            if let closing {
                tokens.append(Token(.codeSpan, index, closing + length - index))
                claim(index, closing + length)
                index = closing + length
            } else {
                index += length
            }
        }

        // Escapes, autolinks, bare URLs, links and images, inline HTML.
        index = start
        while index < end {
            if claimed[index] { index += 1; continue }
            let character = line[index]
            switch character {
            case .backslash where index + 1 < end && line[index + 1].isASCIIPunctuation:
                tokens.append(Token(.marker, index, 1))
                claim(index, index + 2)
                index += 2
                continue
            case .lessThan:
                if let close = autolinkEnd(line, from: index, to: end) {
                    tokens.append(Token(.marker, index, 1))
                    tokens.append(Token(.url, index + 1, close - index - 1))
                    tokens.append(Token(.marker, close, 1))
                    claim(index, close + 1)
                    index = close + 1
                    continue
                }
                if let close = htmlTagEnd(line, from: index, to: end) {
                    tokens.append(Token(.marker, index, close + 1 - index))
                    claim(index, close + 1)
                    index = close + 1
                    continue
                }
            case .openingBracket, .exclamation:
                if let link = inlineLink(line, from: index, to: end, claimed: claimed) {
                    tokens.append(Token(.marker, index, link.textStart - index))
                    if link.textEnd > link.textStart {
                        tokens.append(Token(.link, link.textStart, link.textEnd - link.textStart))
                    }
                    tokens.append(Token(.marker, link.textEnd, link.end - link.textEnd))
                    claim(link.textEnd, link.end)
                    claim(index, link.textStart)
                    index = link.textStart
                    continue
                }
            case .lowercaseH, .lowercaseW:
                if index == start || !line[index - 1].isWordCharacter, let urlEnd = bareURLEnd(line, from: index, to: end) {
                    tokens.append(Token(.url, index, urlEnd - index))
                    claim(index, urlEnd)
                    index = urlEnd
                    continue
                }
            case .pipe where tablePipes:
                tokens.append(Token(.marker, index, 1))
                claim(index, index + 1)
            default:
                break
            }
            index += 1
        }

        emphasisTokens(line, from: start, to: end, claimed: claimed, into: &tokens)
    }

    /// End (the `>`) of an autolink `<scheme:…>` or `<name@host>` starting at `start`.
    private static func autolinkEnd(_ line: [unichar], from start: Int, to end: Int) -> Int? {
        var index = start + 1
        var hasColon = false
        var hasAt = false
        while index < end {
            let character = line[index]
            if character == .greaterThan { break }
            if character == .space || character == .lessThan { return nil }
            if character == .colon { hasColon = true }
            if character == .at { hasAt = true }
            index += 1
        }
        guard index < end, index > start + 1, hasColon || hasAt else { return nil }
        // `<a:b>` must start with a scheme of letters.
        if hasColon, !line[start + 1].isLetter { return nil }
        return index
    }

    /// End (the `>`) of an HTML tag or a one-line comment starting at `start`.
    private static func htmlTagEnd(_ line: [unichar], from start: Int, to end: Int) -> Int? {
        guard start + 1 < end else { return nil }
        let next = line[start + 1]
        guard next.isLetter || next == .slash || next == .exclamation else { return nil }
        var index = start + 1
        while index < end, line[index] != .greaterThan {
            if line[index] == .lessThan { return nil }
            index += 1
        }
        return index < end ? index : nil
    }

    private static let schemes: [[unichar]] = ["https://", "http://", "www."].map { Array($0.utf16) }

    /// End of a bare URL (`https://…`, `www.…`) starting at `start`.
    private static func bareURLEnd(_ line: [unichar], from start: Int, to end: Int) -> Int? {
        guard let scheme = schemes.first(where: { scheme in
            start + scheme.count < end && Array(line[start..<(start + scheme.count)]) == scheme
        }) else { return nil }
        var index = start + scheme.count
        var parentheses = 0
        while index < end {
            let character = line[index]
            if character == .space || character == .tab || character == .lessThan { break }
            if character == .openingParenthesis { parentheses += 1 }
            if character == .closingParenthesis {
                if parentheses == 0 { break }
                parentheses -= 1
            }
            index += 1
        }
        // Trailing punctuation belongs to the sentence.
        while index > start + scheme.count, [unichar.period, .comma, .colon, .semicolon, .exclamation, .question,
                                               .quote, .apostrophe].contains(line[index - 1]) {
            index -= 1
        }
        return index > start + scheme.count ? index : nil
    }

    /// A link `[text](destination)`, `[text][label]` or `[text][]`, or the
    /// same as an image with `!`, starting at `start`.
    private static func inlineLink(_ line: [unichar], from start: Int, to end: Int, claimed: [Bool]) -> (textStart: Int, textEnd: Int, end: Int)? {
        var index = start
        if line[index] == .exclamation {
            index += 1
            guard index < end, line[index] == .openingBracket else { return nil }
        }
        let textStart = index + 1
        var depth = 1
        index = textStart
        while index < end {
            if claimed[index] { index += 1; continue }
            let character = line[index]
            if character == .backslash { index += 2; continue }
            if character == .openingBracket { depth += 1 }
            if character == .closingBracket {
                depth -= 1
                if depth == 0 { break }
            }
            index += 1
        }
        guard index < end, depth == 0 else { return nil }
        let textEnd = index
        let after = index + 1
        guard after < end else { return nil }
        if line[after] == .openingParenthesis {
            var parentheses = 1
            var close = after + 1
            while close < end {
                let character = line[close]
                if character == .backslash { close += 2; continue }
                if character == .openingParenthesis { parentheses += 1 }
                if character == .closingParenthesis {
                    parentheses -= 1
                    if parentheses == 0 { break }
                }
                close += 1
            }
            guard close < end, parentheses == 0 else { return nil }
            return (textStart, textEnd, close + 1)
        }
        if line[after] == .openingBracket {
            var close = after + 1
            while close < end, line[close] != .closingBracket {
                if line[close] == .openingBracket { return nil }
                close += 1
            }
            guard close < end else { return nil }
            return (textStart, textEnd, close + 1)
        }
        return nil
    }

    /// `**strong**`, `*emphasis*`, `_emphasis_`, `__strong__` and
    /// `~~strikethrough~~`, matched the way CommonMark matches delimiter runs,
    /// without its finer rules.
    private static func emphasisTokens(_ line: [unichar], from start: Int, to end: Int, claimed: [Bool], into tokens: inout [Token]) {
        struct Run {
            let character: unichar
            var location: Int
            var length: Int
            let canOpen: Bool
            let canClose: Bool
        }
        var runs: [Run] = []
        var index = start
        while index < end {
            let character = line[index]
            guard !claimed[index], character == .asterisk || character == .underscore || character == .tilde else {
                index += 1
                continue
            }
            var length = 0
            while index + length < end, line[index + length] == character, !claimed[index + length] { length += 1 }
            let before: unichar? = index > 0 ? line[index - 1] : nil
            let after: unichar? = index + length < line.count ? line[index + length] : nil
            let leftFlanking = after.map { !$0.isWhitespace } ?? false
            let rightFlanking = before.map { !$0.isWhitespace } ?? false
            var canOpen = leftFlanking
            var canClose = rightFlanking
            if character == .underscore {
                canOpen = leftFlanking && !(before?.isWordCharacter ?? false)
                canClose = rightFlanking && !(after?.isWordCharacter ?? false)
            }
            if character != .tilde || length == 2 {
                runs.append(Run(character: character, location: index, length: length, canOpen: canOpen, canClose: canClose))
            }
            index += length
        }

        var openers: [Run] = []
        for var closer in runs {
            if closer.canClose {
                var openerIndex = openers.lastIndex { $0.character == closer.character && $0.length > 0 }
                while let found = openerIndex, closer.length > 0 {
                    var opener = openers[found]
                    let used = closer.character == .tilde ? 2 : (opener.length >= 2 && closer.length >= 2 ? 2 : 1)
                    let kind: Kind = closer.character == .tilde ? .strikethrough : (used == 2 ? .strong : .emphasis)
                    // Delimiters are used from the inside out.
                    let openerMarker = opener.location + opener.length - used
                    tokens.append(Token(kind, openerMarker, closer.location + used - openerMarker))
                    tokens.append(Token(.marker, openerMarker, used))
                    tokens.append(Token(.marker, closer.location, used))
                    opener.length -= used
                    closer.location += used
                    closer.length -= used
                    openers[found] = opener
                    // Openers between the two are closed off.
                    openers.removeSubrange((found + 1)...)
                    if opener.length == 0 { openers.remove(at: found) }
                    openerIndex = openers.lastIndex { $0.character == closer.character && $0.length > 0 }
                }
            }
            if closer.length > 0, closer.canOpen {
                openers.append(closer)
            }
        }
    }
}

// MARK: - Characters

extension unichar {
    static let tab: unichar = 9
    static let lineFeed: unichar = 10
    static let space: unichar = 32
    static let exclamation: unichar = 33
    static let quote: unichar = 34
    static let hash: unichar = 35
    static let apostrophe: unichar = 39
    static let openingParenthesis: unichar = 40
    static let closingParenthesis: unichar = 41
    static let asterisk: unichar = 42
    static let plus: unichar = 43
    static let comma: unichar = 44
    static let hyphen: unichar = 45
    static let period: unichar = 46
    static let slash: unichar = 47
    static let colon: unichar = 58
    static let semicolon: unichar = 59
    static let lessThan: unichar = 60
    static let equals: unichar = 61
    static let greaterThan: unichar = 62
    static let question: unichar = 63
    static let at: unichar = 64
    static let uppercaseX: unichar = 88
    static let openingBracket: unichar = 91
    static let backslash: unichar = 92
    static let closingBracket: unichar = 93
    static let underscore: unichar = 95
    static let backtick: unichar = 96
    static let lowercaseH: unichar = 104
    static let lowercaseW: unichar = 119
    static let lowercaseX: unichar = 120
    static let pipe: unichar = 124
    static let tilde: unichar = 126

    var isDigit: Bool { self >= 48 && self <= 57 }

    var isLetter: Bool {
        (self >= 65 && self <= 90) || (self >= 97 && self <= 122) || (self > 127 && !isWhitespace)
    }

    var isWordCharacter: Bool { isLetter || isDigit }

    var isWhitespace: Bool {
        self == .space || self == .tab || self == .lineFeed || self == 0x00A0 || self == 0x202F || self == 0x3000
    }

    var isASCIIPunctuation: Bool {
        (self >= 33 && self <= 47) || (self >= 58 && self <= 64) || (self >= 91 && self <= 96) || (self >= 123 && self <= 126)
    }
}
