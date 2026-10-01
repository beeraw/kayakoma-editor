import AppKit

/// Line numbers in the source pane's gutter. Numbers count source lines, so a
/// wrapped line has one number; the current line's number is darker, and the
/// block under the caret carries the accent bar along the gutter's edge.
final class LineNumberRuler: NSRulerView {
    private weak var sourceView: SourceTextView?
    private var digits = 0
    var fontSize: CGFloat = 13 {
        didSet { updateThickness(force: true) }
    }
    /// Line (0-based) of the caret.
    var currentLine = 0 {
        didSet { if currentLine != oldValue { needsDisplay = true } }
    }

    init(sourceView: SourceTextView, scrollView: NSScrollView) {
        self.sourceView = sourceView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        // The text view is not the ruler's client: NSTextView would otherwise
        // manage the ruler through its TextKit 1 layout manager.
        clientView = nil
        // Views no longer clip by default: the gutter must not paint over the text.
        clipsToBounds = true
        updateThickness(force: true)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }

    private var numberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: (fontSize * 0.88).rounded(), weight: .regular)
    }

    /// Wide enough for the largest line number, three digits at least.
    func updateThickness(force: Bool = false) {
        let lineCount = sourceView?.lineIndex().lineCount ?? 1
        let needed = max(3, String(lineCount).count)
        guard force || needed != digits else { return }
        digits = needed
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        ruleThickness = ceil(digitWidth * CGFloat(digits) + fontSize * 1.4)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let sourceView, let layoutManager = sourceView.textLayoutManager else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(rect).fill()

        let index = sourceView.lineIndex()
        if let lines = sourceView.activeLines, let extent = sourceView.verticalExtent(ofLines: lines) {
            let top = convert(NSPoint(x: 0, y: extent.lowerBound), from: sourceView).y
            let bottom = convert(NSPoint(x: 0, y: extent.upperBound), from: sourceView).y
            let band = NSRect(x: 0, y: min(top, bottom), width: bounds.width, height: abs(bottom - top))
            SourceStyle.activeBlockBackground.setFill()
            band.fill(using: .sourceOver)
            SourceStyle.accent.withAlphaComponent(0.8).setFill()
            NSRect(x: 0, y: band.minY, width: 3, height: band.height).fill()
        }

        let visible = sourceView.visibleRect
        let origin = sourceView.textContainerOrigin
        let documentStart = layoutManager.documentRange.location
        guard let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - origin.y)))
                ?? layoutManager.textLayoutFragment(for: documentStart) else { return }

        let font = numberFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let right = bounds.width - fontSize * 0.9
        let textLength = sourceView.textStorage?.length ?? 0
        func draw(_ number: Int, lineTop: CGFloat, lineHeight: CGFloat, current: Bool) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: current ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: lineTop + origin.y), from: sourceView).y
            // Same baseline as the source text, which sits in the middle of its line.
            let baselineShift = (sourceView.font?.ascender ?? font.ascender) - font.ascender
            let labelTop = y + (lineHeight - (sourceView.font.map { ceil($0.ascender - $0.descender) } ?? size.height)) / 2 + baselineShift
            label.draw(in: NSRect(x: 0, y: labelTop, width: right, height: size.height), withAttributes: attributes)
        }

        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location,
                                                   options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            let offset = layoutManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let line = index.line(at: offset)
            let lines = fragment.textLineFragments
            let firstHeight = lines.first?.typographicBounds.height ?? frame.height
            if !(fragment.rangeInElement.isEmpty && offset == textLength && offset > 0) {
                draw(line + 1, lineTop: frame.minY, lineHeight: firstHeight, current: line == currentLine)
            }
            // The empty line after a final line break.
            if offset + (lines.last.map { $0.characterRange.upperBound } ?? 0) >= textLength, textLength > 0,
               index.lineCount > line + 1, let extra = lines.last, lines.count > 1 || fragment.rangeInElement.isEmpty {
                let last = index.lineCount - 1
                draw(last + 1, lineTop: frame.minY + extra.typographicBounds.minY,
                     lineHeight: extra.typographicBounds.height, current: last == currentLine)
            }
            return true
        }
    }
}
