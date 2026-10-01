import AppKit

/// The source pane's text view: plain text in TextKit 2, with the block under
/// the caret tinted and list items continued on Return.
final class SourceTextView: NSTextView {
    /// Lines (0-based) of the block holding the caret, tinted with the accent.
    var activeLines: ClosedRange<Int>? {
        didSet {
            guard activeLines != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Where lines start; set by the panes, owned by the highlighter.
    var lineIndex: () -> LineIndex = { LineIndex() }

    /// Ranges underlined with dots in the accent (broken links).
    var dottedRanges: [NSRange] = [] {
        didSet { if dottedRanges != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawDottedRanges(in: rect)
        guard let activeLines, let extent = verticalExtent(ofLines: activeLines) else { return }
        let band = NSRect(x: bounds.minX, y: extent.lowerBound, width: bounds.width, height: extent.upperBound - extent.lowerBound)
        guard band.intersects(rect) else { return }
        SourceStyle.activeBlockBackground.setFill()
        band.intersection(rect).fill(using: .sourceOver)
    }

    private func drawDottedRanges(in rect: NSRect) {
        guard !dottedRanges.isEmpty, let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let length = textStorage?.length ?? 0
        let start = contentManager.documentRange.location
        let origin = textContainerOrigin
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.setLineDash([1.2, 2.2], count: 2, phase: 0)
        path.lineCapStyle = .round
        for range in dottedRanges where NSMaxRange(range) <= length {
            guard let from = contentManager.location(start, offsetBy: range.location),
                  let to = contentManager.location(from, offsetBy: range.length),
                  let textRange = NSTextRange(location: from, end: to) else { continue }
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, baseline, _ in
                let y = frame.minY + origin.y + baseline + 2.5
                guard y >= rect.minY - 4, y <= rect.maxY + 4 else { return true }
                path.move(to: NSPoint(x: frame.minX + origin.x, y: y))
                path.line(to: NSPoint(x: frame.maxX + origin.x, y: y))
                return true
            }
        }
        SourceStyle.accent.setStroke()
        path.stroke()
    }

    // MARK: Geometry

    /// Top and bottom, in view coordinates, of a range of lines (0-based).
    func verticalExtent(ofLines lines: ClosedRange<Int>) -> ClosedRange<CGFloat>? {
        let index = lineIndex()
        guard lines.lowerBound >= 0, lines.upperBound < index.lineCount,
              let top = lineFragmentFrame(atOffset: index.starts[lines.lowerBound]),
              let bottom = lineFragmentFrame(atOffset: index.starts[lines.upperBound]) else { return nil }
        let origin = textContainerOrigin.y
        return (top.minY + origin)...(max(bottom.maxY, top.maxY) + origin)
    }

    /// Vertical extents, in view coordinates, of the paragraph (source line)
    /// and of the wrapped line holding a character offset.
    func verticalExtents(atOffset offset: Int) -> (paragraph: ClosedRange<CGFloat>, visualLine: ClosedRange<CGFloat>)? {
        guard let layoutManager = textLayoutManager, let storage = textStorage,
              let frame = lineFragmentFrame(atOffset: offset) else { return nil }
        let origin = textContainerOrigin.y
        var paragraph = (frame.minY + origin)...(frame.maxY + origin)
        // The empty last line after a final line break is a frame of its own.
        if offset == storage.length, offset > 0, storage.mutableString.character(at: offset - 1) == 10 {
            return (paragraph, paragraph)
        }
        let documentStart = layoutManager.documentRange.location
        guard let location = layoutManager.location(documentStart, offsetBy: offset) else { return (paragraph, paragraph) }
        var visual = paragraph
        layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            let local = offset - layoutManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let lines = fragment.textLineFragments
            if let line = lines.last(where: { $0.characterRange.location <= local }) ?? lines.first {
                let top = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + origin
                visual = top...(top + line.typographicBounds.height)
            }
            paragraph = (fragment.layoutFragmentFrame.minY + origin)...(fragment.layoutFragmentFrame.maxY + origin)
            return false
        }
        return (paragraph, visual)
    }

    /// Frame, in text container coordinates, of the layout fragment holding a
    /// character offset; the last fragment for the end of the text.
    func lineFragmentFrame(atOffset offset: Int) -> CGRect? {
        guard let layoutManager = textLayoutManager else { return nil }
        let documentStart = layoutManager.documentRange.location
        let length = textStorage?.length ?? 0
        var frame: CGRect?
        func visit(_ fragment: NSTextLayoutFragment) -> Bool {
            frame = fragment.layoutFragmentFrame
            // At the very end of a text that ends with a line break, the
            // empty last line is the extra line fragment of the last paragraph.
            if offset == length, offset > 0,
               let extra = fragment.textLineFragments.last, fragment.textLineFragments.count > 1 || fragment.rangeInElement.isEmpty {
                let bounds = extra.typographicBounds
                frame = CGRect(x: fragment.layoutFragmentFrame.minX, y: fragment.layoutFragmentFrame.minY + bounds.minY,
                               width: fragment.layoutFragmentFrame.width, height: bounds.height)
            }
            return false
        }
        if let location = layoutManager.location(documentStart, offsetBy: offset) {
            layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout, .ensuresExtraLineFragment], using: visit)
        }
        if frame == nil, offset == length {
            // Nothing starts at the end of the text: the last fragment is the one.
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.endLocation,
                                                       options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment], using: visit)
        }
        return frame
    }

    /// Line (0-based) at a vertical position of the view.
    func line(atY y: CGFloat) -> Int? {
        guard let layoutManager = textLayoutManager else { return nil }
        let point = CGPoint(x: 0, y: max(0, y - textContainerOrigin.y))
        guard let fragment = layoutManager.textLayoutFragment(for: point)
                ?? layoutManager.textLayoutFragment(for: layoutManager.documentRange.endLocation) else { return nil }
        let offset = layoutManager.offset(from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)
        return lineIndex().line(at: offset)
    }

    // MARK: Editing

    /// Return inside a list item starts the next item; Return on an empty
    /// item ends the list. Quotes continue the same way.
    override func insertNewline(_ sender: Any?) {
        guard selectedRanges.count == 1, let storage = textStorage else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let text = storage.mutableString
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: selection.location - lineRange.location)
        let prefix = text.substring(with: prefixRange)
        let lineEnd = lineRange.location + lineRange.length - (text.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
        let wholeLine = text.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        guard let continuation = ListContinuation(line: wholeLine), prefix.utf16.count >= continuation.markerLength else {
            super.insertNewline(sender)
            return
        }
        if continuation.isEmptyItem, selection.location == lineEnd {
            // An empty item ends the list: remove its marker.
            let markerRange = NSRange(location: lineRange.location, length: lineEnd - lineRange.location)
            insertText("", replacementRange: markerRange)
            return
        }
        insertText("\n" + continuation.nextMarker, replacementRange: selection)
    }
}

/// How Return continues a list item or a quote line.
struct ListContinuation: Equatable {
    /// What starts the next line: indentation, quote marks, bullet or number, task box.
    let nextMarker: String
    /// Length of the current line's marker, in UTF-16 units.
    let markerLength: Int
    /// Whether the current line holds nothing but its marker.
    let isEmptyItem: Bool

    init?(line: String) {
        let pattern = #"^((?:[ \t]{0,3}>[ \t]?)*)([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#
        let quotePattern = #"^((?:[ \t]{0,3}>[ \t]?)+)"#
        let nsLine = line as NSString
        let full = NSRange(location: 0, length: nsLine.length)
        if let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: full) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsLine.substring(with: range)
            }
            var marker = (group(1) ?? "") + (group(2) ?? "")
            if let bullet = group(3) {
                marker += bullet
            } else if let number = group(4).flatMap({ Int($0) }), let delimiter = group(5) {
                marker += String(number + 1) + delimiter
            }
            marker += group(6) ?? " "
            if group(7) != nil { marker += "[ ] " }
            nextMarker = marker
            markerLength = match.range.length
            isEmptyItem = nsLine.substring(from: match.range.length).trimmingCharacters(in: .whitespaces).isEmpty
        } else if let match = try? NSRegularExpression(pattern: quotePattern).firstMatch(in: line, range: full) {
            var marker = nsLine.substring(with: match.range(at: 1))
            if !marker.hasSuffix(" ") { marker += " " }
            nextMarker = marker
            markerLength = match.range.length
            isEmptyItem = nsLine.substring(from: match.range.length).trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            return nil
        }
    }
}
