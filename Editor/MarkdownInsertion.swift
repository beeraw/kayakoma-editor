import Foundation

/// One replacement in the source text, as the cheat sheet's « Insérer » makes
/// it: a single edit, so that one ⌘Z undoes it.
struct MarkdownInsertion: Equatable {
    /// Range of the text replaced, in UTF-16 units of the original text.
    let range: NSRange
    let replacement: String
    /// The selection afterwards, in the new text.
    let selection: NSRange

    /// The edit that inserts `snippet` into `text` with `selection` (UTF-16 units).
    init(snippet: MarkdownSnippet, in text: String, selection: NSRange) {
        let text = text as NSString
        let selection = NSRange(location: min(selection.location, text.length),
                                length: max(0, min(selection.length, text.length - min(selection.location, text.length))))
        switch snippet {
        case let .inline(prefix, suffix, placeholder):
            self = Self.inline(prefix: prefix, suffix: suffix, placeholder: placeholder, in: text, selection: selection)
        case let .link(prefix, linkText, url):
            self = Self.link(prefix: prefix, text: linkText, url: url, in: text, selection: selection)
        case .text(let string):
            self.init(range: selection, replacement: string,
                      selection: NSRange(location: selection.location + string.utf16.count, length: 0))
        case let .block(block, selecting):
            self = Self.block(block, selecting: selecting, in: text, selection: selection)
        }
    }

    init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The text once the edit is applied.
    func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    // MARK: - Inline styles

    /// Wraps the selection, or removes the marks when it is already wrapped;
    /// without a selection, inserts the placeholder wrapped and selects it.
    private static func inline(prefix: String, suffix: String, placeholder: String,
                               in text: NSString, selection: NSRange) -> MarkdownInsertion {
        guard selection.length > 0 else {
            let inserted = prefix + placeholder + suffix
            return MarkdownInsertion(range: selection, replacement: inserted,
                                     selection: NSRange(location: selection.location + prefix.utf16.count,
                                                        length: placeholder.utf16.count))
        }
        let inner = trimmed(selection, in: text)
        if let mark = repeatedCharacter(prefix), prefix == suffix {
            return toggleRun(of: mark, count: prefix.count, inner: inner, in: text)
        }
        let p = prefix.utf16.count, s = suffix.utf16.count
        let selected = text.substring(with: inner)
        // The marks are inside the selection.
        if selected.utf16.count >= p + s, selected.hasPrefix(prefix), selected.hasSuffix(suffix), p + s > 0 {
            let content = (selected as NSString).substring(with: NSRange(location: p, length: selected.utf16.count - p - s))
            return MarkdownInsertion(range: inner, replacement: content,
                                     selection: NSRange(location: inner.location, length: content.utf16.count))
        }
        // The marks are just around it.
        if inner.location >= p, NSMaxRange(inner) + s <= text.length,
           text.substring(with: NSRange(location: inner.location - p, length: p)) == prefix,
           text.substring(with: NSRange(location: NSMaxRange(inner), length: s)) == suffix {
            return MarkdownInsertion(range: NSRange(location: inner.location - p, length: inner.length + p + s),
                                     replacement: selected,
                                     selection: NSRange(location: inner.location - p, length: inner.length))
        }
        return MarkdownInsertion(range: inner, replacement: prefix + selected + suffix,
                                 selection: NSRange(location: inner.location + p, length: inner.length))
    }

    /// Marks made of one repeated character (`*`, `**`, `~~`, `` ` ``): the
    /// runs on both sides of the selection are counted, so that bold and
    /// italic combine. For `*`, italic is one star and bold two: a run of
    /// three holds both, and each style is added or taken away on its own.
    private static func toggleRun(of mark: Character, count: Int, inner: NSRange, in text: NSString) -> MarkdownInsertion {
        let unit = String(mark).utf16.first!
        var content = inner
        // Marks selected along with the text count as around it.
        var inside = 0
        while inside < content.length / 2, text.character(at: content.location + inside) == unit,
              text.character(at: NSMaxRange(content) - 1 - inside) == unit {
            inside += 1
        }
        content = NSRange(location: content.location + inside, length: content.length - 2 * inside)
        var before = 0
        while content.location - before - 1 >= 0, text.character(at: content.location - before - 1) == unit { before += 1 }
        var after = 0
        while NSMaxRange(content) + after < text.length, text.character(at: NSMaxRange(content) + after) == unit { after += 1 }
        let current = before == after ? before : 0
        let newCount: Int
        if mark == "*", current <= 3, count <= 3 {
            newCount = current & count == count ? current & ~count : current | count
        } else {
            newCount = current == count ? 0 : current + count
        }
        let outer = NSRange(location: content.location - current, length: content.length + 2 * current)
        let marks = String(repeating: mark, count: newCount)
        let selected = text.substring(with: content)
        return MarkdownInsertion(range: outer, replacement: marks + selected + marks,
                                 selection: NSRange(location: outer.location + newCount, length: content.length))
    }

    private static func repeatedCharacter(_ string: String) -> Character? {
        guard let first = string.first, string.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The selection without the spaces at its ends: marks must touch the text.
    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        let spaces = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool {
            UnicodeScalar(text.character(at: index)).map(spaces.contains) ?? false
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return start < end ? NSRange(location: start, length: end - start) : range
    }

    // MARK: - Links

    /// `[selection](url)` with the address selected; `[text](url)` with the
    /// text selected when nothing is.
    private static func link(prefix: String, text linkText: String, url: String,
                             in text: NSString, selection: NSRange) -> MarkdownInsertion {
        if selection.length > 0 {
            let inner = trimmed(selection, in: text)
            let selected = text.substring(with: inner)
            let head = prefix + selected + "]("
            return MarkdownInsertion(range: inner, replacement: head + url + ")",
                                     selection: NSRange(location: inner.location + head.utf16.count, length: url.utf16.count))
        }
        return MarkdownInsertion(range: selection, replacement: prefix + linkText + "](" + url + ")",
                                 selection: NSRange(location: selection.location + prefix.utf16.count,
                                                    length: linkText.utf16.count))
    }

    // MARK: - Blocks

    /// A block never cuts a paragraph: on an empty line it takes that line,
    /// otherwise it goes after the block holding the selection, with the
    /// empty lines Markdown needs around it.
    private static func block(_ block: String, selecting placeholder: String?,
                              in text: NSString, selection: NSRange) -> MarkdownInsertion {
        let lines = Line.split(text)
        let current = Line.index(containing: selection.location, in: lines)
        let insertion: MarkdownInsertion
        let blockStart: Int
        if fenceEnd(containing: current, in: lines, text: text) == nil, lines[current].isBlank(in: text) {
            let line = lines[current]
            let before = current > 0 && !lines[current - 1].isBlank(in: text) ? "\n" : ""
            let after = current + 1 < lines.count && !lines[current + 1].isBlank(in: text) ? "\n" : ""
            blockStart = line.start + before.utf16.count
            insertion = MarkdownInsertion(range: NSRange(location: line.start, length: line.contentEnd - line.start),
                                          replacement: before + block + after, selection: NSRange())
        } else {
            let last = lastLine(ofBlockAt: current, in: lines, text: text)
            let end = lines[last].contentEnd
            let after = last + 1 < lines.count && !lines[last + 1].isBlank(in: text) ? "\n" : ""
            blockStart = end + 2
            insertion = MarkdownInsertion(range: NSRange(location: end, length: 0), replacement: "\n\n" + block + after,
                                          selection: NSRange())
        }
        var selected = NSRange(location: blockStart + block.utf16.count, length: 0)
        if let placeholder, !placeholder.isEmpty {
            let found = (block as NSString).range(of: placeholder)
            if found.location != NSNotFound {
                selected = NSRange(location: blockStart + found.location, length: found.length)
            }
        }
        return MarkdownInsertion(range: insertion.range, replacement: insertion.replacement, selection: selected)
    }

    /// The last line of the block holding a line: up to the next blank
    /// line, or to the closing fence of a fenced code block (which may hold
    /// blank lines).
    private static func lastLine(ofBlockAt index: Int, in lines: [Line], text: NSString) -> Int {
        if let end = fenceEnd(containing: index, in: lines, text: text) { return end }
        var last = index
        while last + 1 < lines.count, !lines[last + 1].isBlank(in: text) {
            last += 1
            // A fence opening inside the block runs to its closing fence.
            if fence(in: lines[last].content(in: text)) != nil,
               let end = fenceEnd(containing: last, in: lines, text: text) {
                last = end
            }
        }
        return last
    }

    /// When a line opens, closes or lies inside a fenced code block, the
    /// line that closes it (the last line when it is never closed).
    private static func fenceEnd(containing index: Int, in lines: [Line], text: NSString) -> Int? {
        var open: (marker: Character, length: Int)?
        for i in lines.indices {
            let fence = Self.fence(in: lines[i].content(in: text))
            if let opened = open {
                if let fence, fence.marker == opened.marker, fence.length >= opened.length, fence.isBare {
                    open = nil
                    if i >= index { return i }
                }
            } else if let fence {
                open = (fence.marker, fence.length)
            } else if i >= index {
                return nil
            }
        }
        return open == nil ? nil : lines.count - 1
    }

    /// A code fence: up to three spaces, then three or more backticks or tildes.
    private static func fence(in line: String) -> (marker: Character, length: Int, isBare: Bool)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length)
        if marker == "`", info.contains("`") { return nil }
        return (marker, length, info.allSatisfy(\.isWhitespace))
    }

    /// A line of the text: where it starts, where its content ends (before
    /// its line break).
    private struct Line {
        let start: Int
        let contentEnd: Int

        func content(in text: NSString) -> String {
            text.substring(with: NSRange(location: start, length: contentEnd - start))
        }

        func isBlank(in text: NSString) -> Bool {
            content(in: text).allSatisfy(\.isWhitespace)
        }

        /// The lines of a text; an empty text, or one ending with a line
        /// break, has an empty last line.
        static func split(_ text: NSString) -> [Line] {
            var lines: [Line] = []
            var start = 0
            while start < text.length {
                let range = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound else { break }
                lines.append(Line(start: start, contentEnd: range.location))
                start = range.location + 1
            }
            lines.append(Line(start: start, contentEnd: text.length))
            return lines
        }

        static func index(containing offset: Int, in lines: [Line]) -> Int {
            lines.lastIndex { $0.start <= offset } ?? 0
        }
    }
}
