import AppKit
import KayakomaKit

extension MarkdownView {
    /// The text view inside the preview's scroll view, for what the engine does
    /// not wrap: focus, find bar, and observing frame and selection changes.
    var contentTextView: NSTextView? {
        (subviews.first { $0 is NSScrollView } as? NSScrollView)?.documentView as? NSTextView
    }
}

/// The accent bar beside the preview's block that holds the source caret.
@MainActor
final class PreviewBlockMarker {
    private let bar = MarkerBar()

    /// Places the bar beside a block, or hides it.
    func show(block index: Int?, in preview: MarkdownView) {
        guard let index, let textView = preview.contentTextView,
              var frame = preview.frame(ofBlockAt: index).map({ preview.convert($0, to: textView) }) else {
            bar.isHidden = true
            return
        }
        if bar.superview !== textView {
            textView.addSubview(bar)
        }
        // The fragment includes the space after the block; keep the bar to the text.
        let spacing = min(preview.theme.blockSpacing, frame.height / 3)
        frame.size.height -= spacing
        let column = textView.textContainerOrigin.x
        bar.frame = NSRect(x: column - 16, y: frame.minY + 3, width: 3, height: max(0, frame.height - 6))
        bar.isHidden = false
    }
}

/// Draws itself, so that its colour follows the appearance.
private final class MarkerBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SourceStyle.accent.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).fill()
    }
}
