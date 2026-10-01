import AppKit
import KayakomaKit

/// What the window shows: the source, both side by side, or the preview.
enum EditorLayout: String, CaseIterable, Identifiable {
    case source, split, preview

    var id: Self { self }
}

/// The two panes of a document window, in AppKit: the source text view with
/// its line numbers, and the engine's preview. They keep each other scrolled
/// to the same source line and mark the block under the caret.
@MainActor
final class EditorPanes: NSObject {
    /// Owns the split view: its items collapse (and animate) the hidden pane.
    private let splitController = PanesSplitViewController()
    var splitView: NSSplitView { splitController.splitView }
    /// What the window hosts: the split view, sized by its host.
    let rootView = PanesRootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    private let sourceItem: NSSplitViewItem
    private let previewItem: NSSplitViewItem
    let sourceScrollView = NSScrollView()
    let sourceView = SourceTextView(usingTextLayoutManager: true)
    let ruler: LineNumberRuler
    let preview = MarkdownView()
    let highlighter: SourceHighlighter
    private let marker = PreviewBlockMarker()

    /// Called after each edit of the source text.
    var onTextChange: (() -> Void)?
    /// Called when the caret moves, with its line and column (1-based).
    var onCaretChange: ((Int, Int) -> Void)?
    /// The document's undo manager, so that typing marks the document as modified.
    var undoManager: UndoManager?
    /// Offered the clicks on the preview's links (except ⌥-clicks, which place
    /// the caret); returns whether it handled the click.
    var onLinkClick: ((MarkdownView.LinkClick) -> Bool)?

    var syncsScrolling = true {
        didSet { if syncsScrolling, !oldValue { syncPreviewToSource() } }
    }

    var layout: EditorLayout = .split {
        didSet { if layout != oldValue { applyLayout(from: oldValue, animated: canAnimateLayout) } }
    }

    /// Whether layout changes slide the panes; tests turn it off. Reduce Motion
    /// always wins over it.
    var animatesLayoutChanges = true

    /// Changes the layout without sliding (restoring a window's saved layout).
    func setLayoutImmediately(_ newLayout: EditorLayout) {
        suppressesAnimation = true
        layout = newLayout
        suppressesAnimation = false
    }

    private var suppressesAnimation = false
    /// True from the start of a slide until its last completion: the panes are
    /// resizing, so scroll synchronisation and the block marker wait.
    private var isAnimatingLayout = false
    /// Identifies the latest layout change; older slides finishing late are ignored.
    private var layoutGeneration = 0

    private var canAnimateLayout: Bool {
        guard animatesLayoutChanges, !suppressesAnimation,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = splitView.window, window.isVisible, splitView.bounds.width > 0 else { return false }
        return true
    }

    var showsLineNumbers = true {
        didSet { sourceScrollView.rulersVisible = showsLineNumbers }
    }

    var sourceFontSize: CGFloat {
        get { highlighter.style.fontSize }
        set {
            guard newValue != highlighter.style.fontSize else { return }
            restyle(fontSize: newValue)
        }
    }

    /// The document on display in the preview.
    private(set) var document: RenderedDocument?
    /// Set while the panes scroll the source themselves, so as not to scroll the preview back.
    private var isScrollingSource = false
    /// The split position, as a fraction of the width, kept while a pane is hidden.
    private var splitFraction: CGFloat = 0.5

    init(text: String, fontSize: CGFloat = Preferences.defaultSourceFontSize) {
        sourceItem = NSSplitViewItem(viewController: PaneViewController(view: sourceScrollView))
        previewItem = NSSplitViewItem(viewController: PaneViewController(view: preview))
        highlighter = SourceHighlighter(style: SourceStyle(fontSize: fontSize))
        ruler = LineNumberRuler(sourceView: sourceView, scrollView: sourceScrollView)
        super.init()
        setUpSource()
        setUpPreview()
        setUpSplit()
        setText(text)
    }

    // MARK: Set-up

    private func setUpSource() {
        let textView = sourceView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesRuler = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = SourceStyle.accent
        textView.textContainerInset = NSSize(width: 6, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.lineIndex = { [unowned self] in highlighter.lines }
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.setAccessibilityLabel(String(localized: "Source Markdown"))

        // The text view tracks the clip view's width from a real starting size.
        sourceScrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.frame = NSRect(origin: .zero, size: sourceScrollView.contentSize)
        sourceScrollView.documentView = textView
        sourceScrollView.automaticallyAdjustsContentInsets = false
        sourceScrollView.contentInsets = NSEdgeInsetsZero
        sourceScrollView.hasVerticalScroller = true
        sourceScrollView.autohidesScrollers = true
        sourceScrollView.drawsBackground = true
        sourceScrollView.backgroundColor = .textBackgroundColor
        sourceScrollView.verticalRulerView = ruler
        sourceScrollView.hasVerticalRuler = true
        sourceScrollView.rulersVisible = showsLineNumbers
        sourceScrollView.findBarPosition = .aboveContent
        sourceScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sourceDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: sourceScrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(sourceFrameDidChange),
                                               name: NSView.frameDidChangeNotification, object: textView)
    }

    private func setUpPreview() {
        preview.onTopVisibleSourceLineChange = { [weak self] line in
            self?.previewDidScroll(toLine: line)
        }
        preview.onLinkClick = { [weak self] click in
            guard let self else { return false }
            if click.modifiers.contains(.option) {
                placeCaret(atPreviewCharacter: click.characterIndex)
                return true
            }
            return onLinkClick?(click) ?? false
        }
        // The window places the panes below the toolbar: no inset of their own.
        if let scrollView = preview.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            // A pane resized from outside (tab bar shown or hidden, full screen,
            // a window shown again) leaves the preview where it was; the source
            // keeps its place by itself, so the preview is brought back to it.
            scrollView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(previewViewportDidResize),
                                                   name: NSView.frameDidChangeNotification, object: scrollView)
        }
        if let textView = preview.contentTextView {
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(previewFrameDidChange),
                                                   name: NSView.frameDidChangeNotification, object: textView)
            NotificationCenter.default.addObserver(self, selector: #selector(previewSelectionDidChange),
                                                   name: NSTextView.didChangeSelectionNotification, object: textView)
        }
    }

    private func setUpSplit() {
        splitController.splitView = PanesSplitView()
        splitController.loadView()
        for item in [sourceItem, previewItem] {
            item.canCollapse = true
            item.minimumThickness = 240
            item.holdingPriority = .defaultLow - 1
            splitController.addSplitViewItem(item)
        }
        splitController.isDividerHidden = { [unowned self] in layout != .split }
        // The first real size splits the window in half, both panes shown
        // in the side-by-side layout (a narrow size before it may have
        // collapsed one).
        (splitView as? PanesSplitView)?.onFirstLayout = { [unowned self] in
            if !isAnimatingLayout {
                if sourceItem.isCollapsed != (layout == .preview) { sourceItem.isCollapsed = layout == .preview }
                if previewItem.isCollapsed != (layout == .source) { previewItem.isCollapsed = layout == .source }
            }
            placeDivider(layingOut: false)
        }
        (splitView as? PanesSplitView)?.onLayout = { [weak self] in
            // Not inside layout: moving the divider lays the split view out again.
            guard let self, !self.isRepairScheduled, self.isPaneSqueezed else { return }
            self.isRepairScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.isRepairScheduled = false
                    self?.repairSqueezedPane()
                }
            }
        }
        // The container shields the host from the split view's own constraints,
        // which would otherwise drive the size of the window.
        splitView.translatesAutoresizingMaskIntoConstraints = true
        splitView.autoresizingMask = [.width, .height]
        rootView.splitView = splitView
        rootView.addSubview(splitView)
        splitView.frame = rootView.contentRect
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = nil
    }

    /// Side by side, a pane squeezed under its minimum width (by a narrow size
    /// the host gave before its real one) gets its share back.
    private var isPaneSqueezed: Bool {
        layout == .split && !isAnimatingLayout
            && splitView.bounds.width >= 2 * minimumPaneWidth + splitView.dividerThickness
            && min(sourceScrollView.frame.width, preview.frame.width) < minimumPaneWidth - 1
    }

    private func repairSqueezedPane() {
        guard isPaneSqueezed else { return }
        if sourceItem.isCollapsed { sourceItem.isCollapsed = false }
        if previewItem.isCollapsed { previewItem.isCollapsed = false }
        splitView.setPosition((splitView.bounds.width * splitFraction).rounded(), ofDividerAt: 0)
    }

    private var isRepairScheduled = false
    private let minimumPaneWidth: CGFloat = 240

    /// Puts the divider at the kept split position.
    private func placeDivider(layingOut: Bool = true) {
        guard layout == .split, !sourceItem.isCollapsed, !previewItem.isCollapsed, splitView.bounds.width > 0 else { return }
        if layingOut { splitView.layoutSubtreeIfNeeded() }
        let target = (splitView.bounds.width * splitFraction).rounded()
        if abs(sourceScrollView.frame.width - target) > 1 { splitView.setPosition(target, ofDividerAt: 0) }
    }

    // MARK: Text

    /// Replaces the whole source text, outside undo: a new document, or the
    /// file reloaded from disk.
    func setText(_ text: String) {
        guard let storage = sourceView.textStorage else { return }
        let selection = sourceView.selectedRange()
        isReplacingText = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        isReplacingText = false
        highlighter.reset(storage.mutableString)
        highlighter.flush(storage)
        sourceView.typingAttributes = highlighter.style.baseAttributes
        let caret = min(selection.location, storage.length)
        suppressesCaretSync = true
        sourceView.setSelectedRange(NSRange(location: caret, length: 0))
        caretDidMove()
        suppressesCaretSync = false
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    private var isReplacingText = false
    /// Set by an edit of the text until it is reported through `onTextChange`.
    private var hasUnreportedEdit = false

    var text: String { sourceView.string }

    private func restyle(fontSize: CGFloat) {
        highlighter.style = SourceStyle(fontSize: fontSize)
        highlighter.invalidateAll()
        if let storage = sourceView.textStorage { highlighter.flush(storage) }
        sourceView.typingAttributes = highlighter.style.baseAttributes
        ruler.fontSize = fontSize
        ruler.needsDisplay = true
        sourceView.needsDisplay = true
    }

    // MARK: Preview

    var theme: Theme {
        get { preview.theme }
        set {
            guard newValue != preview.theme else { return }
            preview.theme = newValue
            refreshAfterPreviewLayout()
        }
    }

    var baseURL: URL? {
        get { preview.baseURL }
        set {
            guard newValue != preview.baseURL else { return }
            preview.baseURL = newValue
            refreshAfterPreviewLayout()
        }
    }

    /// Shows a newly rendered version of the source; the engine rebuilds only the blocks that changed.
    func show(_ rendered: RenderedDocument) {
        document = rendered
        preview.document = rendered
        refreshAfterPreviewLayout()
    }

    private func refreshAfterPreviewLayout() {
        if syncsScrolling, layout == .split, !isAnimatingLayout { syncPreviewToSource() }
        updateActiveBlock()
    }

    // MARK: Caret and active block

    /// Line (0-based) and UTF-16 offset of the caret.
    private var caret: (line: Int, offset: Int) {
        let offset = sourceView.selectedRange().location
        return (highlighter.lines.line(at: offset), offset)
    }

    private func caretDidMove() {
        let (line, offset) = caret
        let lineStart = highlighter.lines.starts[line]
        let prefix = (sourceView.textStorage?.mutableString.substring(with: NSRange(location: lineStart, length: offset - lineStart))) ?? ""
        ruler.currentLine = line
        updateActiveBlock()
        onCaretChange?(line + 1, prefix.count + 1)
        guard !suppressesCaretSync else { return }
        // The preview follows the caret, not the top of the source. The source
        // may scroll to show the caret right after this; that scroll is the
        // caret's too (see `sourceDidScroll`).
        anchor = .caret
        caretMovedThisTurn = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.caretMovedThisTurn = false }
        }
        syncPreviewToCaret()
    }

    /// Marks the block holding the caret in both panes; nothing when the caret
    /// is between blocks.
    func updateActiveBlock() {
        let line = caret.line + 1
        guard let document, let index = document.blockIndex(forSourceLine: line),
              let lines = document.blocks[index].sourceLines, lines.contains(line) else {
            sourceView.activeLines = nil
            marker.show(block: nil, in: preview)
            ruler.needsDisplay = true
            return
        }
        let last = highlighter.lines.lineCount - 1
        sourceView.activeLines = min(lines.lowerBound - 1, last)...min(lines.upperBound - 1, last)
        marker.show(block: index, in: preview)
        ruler.needsDisplay = true
    }

    // MARK: Scroll synchronisation

    /// What the panes keep aligned: the caret's line (after the caret moved or
    /// the text changed), or the middle of the pane the reader scrolled.
    private enum ScrollAnchor { case caret, scroll }

    private var anchor = ScrollAnchor.scroll
    /// Set while the preview is scrolled by the panes, so as not to scroll the source back.
    private var isScrollingPreview = false
    /// True until the end of the run loop turn in which the caret moved: a
    /// scroll of the source in that turn is the source revealing the caret.
    private var caretMovedThisTurn = false
    private var suppressesCaretSync = false

    /// Points the caret's block may be off its place in the preview before
    /// the preview moves: typing on one line must not make it jitter.
    static let caretTolerance: CGFloat = 24

    private var canSync: Bool { syncsScrolling && layout == .split && !isAnimatingLayout && document != nil }

    /// Source line (1-based) at the top of the source pane.
    var topVisibleSourceLine: Int {
        // One point of tolerance: the clip view snaps to whole points.
        (sourceView.line(atY: sourceScrollView.contentView.bounds.minY + 1) ?? 0) + 1
    }

    @objc private func sourceDidScroll(_ notification: Notification) {
        guard !isScrollingSource, canSync else { return }
        if caretMovedThisTurn {
            if !syncPreviewToCaret() { syncPreviewToScroll() }
        } else {
            anchor = .scroll
            syncPreviewToScroll()
        }
    }

    private func previewDidScroll(toLine line: Int) {
        guard canSync, !isScrollingPreview else { return }
        anchor = .scroll
        syncSourceToPreview()
    }

    /// Brings the preview back in line with the source, on the anchor that was used last.
    private func syncPreviewToSource() {
        guard canSync else { return }
        switch anchor {
        case .caret:
            if !syncPreviewToCaret() { syncPreviewToScroll() }
        case .scroll:
            syncPreviewToScroll()
        }
    }

    // MARK: Geometry, source side

    /// Vertical position, as a line number with a fraction (0-based: 2.5 is the
    /// middle of the third line), of a point of the source view.
    func linePosition(atSourceY y: CGFloat) -> CGFloat {
        let lines = highlighter.lines
        let line = min(max(sourceView.line(atY: y) ?? 0, 0), lines.lineCount - 1)
        guard let frame = sourceView.lineFragmentFrame(atOffset: lines.starts[line]), frame.height > 0 else { return CGFloat(line) }
        let local = y - sourceView.textContainerOrigin.y - frame.minY
        return CGFloat(line) + min(max(local / frame.height, 0), 1)
    }

    /// The point of the source view where a line position is.
    func sourceY(forLinePosition position: CGFloat) -> CGFloat? {
        let lines = highlighter.lines
        let clamped = min(max(position, 0), CGFloat(lines.lineCount))
        let line = min(Int(clamped), lines.lineCount - 1)
        guard let frame = sourceView.lineFragmentFrame(atOffset: lines.starts[line]) else { return nil }
        return frame.minY + (clamped - CGFloat(line)) * frame.height + sourceView.textContainerOrigin.y
    }

    // MARK: Geometry, preview side

    /// Frame of a block in the preview's text view coordinates, which are
    /// scroll offsets, and the height of its text without the space after it.
    private func previewFrame(ofBlock index: Int) -> (frame: CGRect, contentHeight: CGFloat)? {
        guard let textView = preview.contentTextView,
              let frame = preview.frame(ofBlockAt: index).map({ preview.convert($0, to: textView) }) else { return nil }
        let spacing = min(preview.theme.blockSpacing, frame.height / 3)
        return (frame, max(frame.height - spacing, 1))
    }

    /// Where, in the preview's text view, a source line position is: the
    /// block holding the line, interpolated by the line inside its source lines.
    func previewY(forLinePosition position: CGFloat) -> CGFloat? {
        guard let document, !document.blocks.isEmpty,
              let index = document.blockIndex(forSourceLine: Int(max(position, 0)) + 1),
              let (frame, height) = previewFrame(ofBlock: index) else { return nil }
        guard let lines = document.blocks[index].sourceLines else { return frame.minY }
        let fraction = min(max((position - CGFloat(lines.lowerBound - 1)) / CGFloat(lines.count), 0), 1)
        return frame.minY + fraction * height
    }

    /// The line position shown at a point of the preview's text view.
    func linePosition(forPreviewY y: CGFloat) -> CGFloat? {
        guard let document, !document.blocks.isEmpty, let textView = preview.contentTextView else { return nil }
        let point = preview.convert(NSPoint(x: textView.bounds.midX, y: y), from: textView)
        var index = preview.blockIndex(at: point)
        if index == nil {
            // Margins above the first block, or below the last one.
            let first = previewFrame(ofBlock: 0)?.frame.minY ?? 0
            index = y < first ? 0 : document.blocks.count - 1
        }
        guard var block = index else { return nil }
        // A block without source lines belongs to the one before it.
        while document.blocks[block].sourceLines == nil, block > 0 { block -= 1 }
        guard let lines = document.blocks[block].sourceLines, let (frame, height) = previewFrame(ofBlock: block) else { return nil }
        let fraction = min(max((y - frame.minY) / height, 0), 1)
        return CGFloat(lines.lowerBound - 1) + fraction * CGFloat(lines.count)
    }

    // MARK: Scrolling the panes

    /// Scrolls the preview to the offset `target` gives, once the layout around
    /// it has settled: positions far from the viewport are estimates until laid
    /// out, so the target is asked again after each scroll. The first request
    /// is ignored when it is within `tolerance` points of where the preview is.
    private func scrollPreview(tolerance: CGFloat, target: () -> CGFloat?) {
        guard let textView = preview.contentTextView, let scrollView = textView.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        isScrollingPreview = true
        defer { isScrollingPreview = false }
        for pass in 0..<4 {
            guard let raw = target() else { return }
            let height = clipView.bounds.height
            let wanted = min(max(raw, 0), previewMaxOffset)
            if abs(clipView.bounds.minY - wanted) < (pass == 0 ? tolerance : 0.5) { return }
            // The text view's own height lags behind layout, and laying the
            // viewport out resets it: make sure it reaches, before and after.
            func scroll() {
                if textView.frame.height < wanted + height {
                    textView.setFrameSize(NSSize(width: textView.frame.width, height: wanted + height))
                }
                textView.scroll(NSPoint(x: 0, y: wanted))
                scrollView.reflectScrolledClipView(clipView)
            }
            scroll()
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            if abs(clipView.bounds.minY - wanted) >= 0.5 { scroll() }
        }
    }

    /// Scrolls the source to the offset `target` gives, settling the layout as `scrollPreview` does.
    private func scrollSource(target: () -> CGFloat?) {
        let clipView = sourceScrollView.contentView
        isScrollingSource = true
        defer { isScrollingSource = false }
        for _ in 0..<4 {
            guard let raw = target() else { return }
            let wanted = min(max(raw, 0), sourceMaxOffset)
            if abs(clipView.bounds.minY - wanted) < 0.5 { return }
            func scroll() {
                if sourceView.frame.height < wanted + clipView.bounds.height {
                    sourceView.setFrameSize(NSSize(width: sourceView.frame.width, height: wanted + clipView.bounds.height))
                }
                sourceView.scroll(NSPoint(x: 0, y: wanted))
                sourceScrollView.reflectScrolledClipView(clipView)
            }
            scroll()
            sourceView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            if abs(clipView.bounds.minY - wanted) >= 0.5 { scroll() }
        }
    }

    /// Largest scroll offset of the preview, from where its last block ends:
    /// the text view's frame lags behind layout, so it is not used.
    var previewMaxOffset: CGFloat {
        guard let textView = preview.contentTextView, let last = document.map({ $0.blocks.count - 1 }), last >= 0,
              let bottom = previewFrame(ofBlock: last)?.frame.maxY else { return 0 }
        return max(0, bottom + textView.textContainerOrigin.y - previewVisibleHeight)
    }

    /// Largest scroll offset of the source, from where its last line ends.
    var sourceMaxOffset: CGFloat {
        let height = sourceScrollView.contentView.bounds.height
        guard let bottom = sourceY(forLinePosition: CGFloat(highlighter.lines.lineCount)) else { return 0 }
        return max(0, bottom + sourceView.textContainerOrigin.y - height)
    }

    /// Puts the caret's block in the preview where the caret's line is in the
    /// source, as a fraction of the visible height; inside a tall block, the
    /// caret's line position inside it decides.
    ///
    /// - Returns: false when the caret is not in the visible part of the source.
    @discardableResult
    func syncPreviewToCaret() -> Bool {
        guard canSync else { return true }
        let visible = sourceScrollView.contentView.bounds
        let (line, offset) = caret
        guard visible.height > 0, let extents = sourceView.verticalExtents(atOffset: offset) else { return false }
        let centre = (extents.visualLine.lowerBound + extents.visualLine.upperBound) / 2
        let relative = (centre - visible.minY) / visible.height
        guard relative >= 0, relative <= 1 else { return false }
        let paragraphHeight = max(extents.paragraph.upperBound - extents.paragraph.lowerBound, 1)
        let position = CGFloat(line) + min(max((centre - extents.paragraph.lowerBound) / paragraphHeight, 0), 1)
        let sourceIsAtTop = visible.minY <= 0
        scrollPreview(tolerance: Self.caretTolerance) { [self] in
            guard let y = previewY(forLinePosition: position) else { return nil }
            let target = y - relative * previewVisibleHeight
            // Both at the top, margins included: the source shows its top margin,
            // so the preview must not hide the space above its first block.
            if sourceIsAtTop, target < (previewFrame(ofBlock: 0)?.frame.minY ?? 0) { return 0 }
            return target
        }
        return true
    }

    private var previewVisibleHeight: CGFloat {
        preview.contentTextView?.enclosingScrollView?.contentView.bounds.height ?? 0
    }

    /// The source was scrolled by the reader: its middle line goes to the
    /// middle of the preview, and the ends go to the ends.
    private func syncPreviewToScroll() {
        let visible = sourceScrollView.contentView.bounds
        guard visible.height > 0 else { return }
        let maxOffset = sourceMaxOffset
        if visible.minY <= 0 {
            // Both at the top, margins included.
            scrollPreview(tolerance: 0.5) { 0 }
        } else if maxOffset > 0, visible.minY >= maxOffset - 1 {
            scrollPreview(tolerance: 0.5) { .greatestFiniteMagnitude }
        } else {
            let position = linePosition(atSourceY: visible.midY)
            scrollPreview(tolerance: 1) { [self] in
                guard let y = previewY(forLinePosition: position) else { return nil }
                return y - previewVisibleHeight / 2
            }
        }
    }

    /// The preview was scrolled by the reader: the source follows, middle to middle.
    private func syncSourceToPreview() {
        guard let clipView = preview.contentTextView?.enclosingScrollView?.contentView else { return }
        let visible = clipView.bounds
        guard visible.height > 0 else { return }
        let maxOffset = previewMaxOffset
        if visible.minY <= 0 {
            scrollSource { 0 }
        } else if maxOffset > 0, visible.minY >= maxOffset - 1 {
            scrollSource { .greatestFiniteMagnitude }
        } else if let position = linePosition(forPreviewY: visible.midY) {
            scrollSource { [self] in
                guard let y = sourceY(forLinePosition: position) else { return nil }
                return y - sourceScrollView.contentView.bounds.height / 2
            }
        }
    }

    /// Puts a source line (1-based) at the top of the source pane. Layout
    /// positions far from the viewport are estimates until laid out, so the
    /// scroll is corrected once the viewport around it is laid out.
    func scrollSource(toLine line: Int) {
        let lines = highlighter.lines
        let index = min(max(line - 1, 0), lines.lineCount - 1)
        let clipView = sourceScrollView.contentView
        isScrollingSource = true
        defer { isScrollingSource = false }
        for _ in 0..<4 {
            guard let frame = sourceView.lineFragmentFrame(atOffset: lines.starts[index]) else { return }
            // The first line shows the top margin too.
            let y = index == 0 ? 0 : max(0, (frame.minY + sourceView.textContainerOrigin.y).rounded())
            if abs(clipView.bounds.minY - y) < 0.5 { return }
            sourceView.scroll(NSPoint(x: 0, y: y))
            sourceScrollView.reflectScrolledClipView(clipView)
            sourceView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    // MARK: Layout

    private func applyLayout(from old: EditorLayout, animated: Bool) {
        let isSettledSplit = old == .split && !isAnimatingLayout && !sourceItem.isCollapsed && !previewItem.isCollapsed
        if isSettledSplit, splitView.bounds.width > 0 {
            splitFraction = min(max(sourceScrollView.frame.width / splitView.bounds.width, 0.2), 0.8)
        }
        layoutGeneration += 1
        let generation = layoutGeneration
        let collapsesSource = layout == .preview
        let collapsesPreview = layout == .source

        // Focus leaves the pane that is going away right away.
        let window = splitView.window
        if layout == .preview, let previewText = preview.contentTextView {
            window?.makeFirstResponder(previewText)
        } else if old == .preview || (layout == .source && isInside(preview, window?.firstResponder)) {
            window?.makeFirstResponder(sourceView)
        }

        if animated {
            // One group moves both panes, so a direct Source <-> Preview switch
            // is a single motion; the divider stays hidden throughout.
            isAnimatingLayout = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                sourceItem.animator().isCollapsed = collapsesSource
                previewItem.animator().isCollapsed = collapsesPreview
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishLayout(generation) }
            })
        } else {
            sourceItem.isCollapsed = collapsesSource
            previewItem.isCollapsed = collapsesPreview
            finishLayout(generation)
        }
    }

    /// Settles the panes once the latest slide is over, whatever the slides
    /// before it did when they were interrupted.
    private func finishLayout(_ generation: Int) {
        guard generation == layoutGeneration else { return }
        let collapsesSource = layout == .preview
        let collapsesPreview = layout == .source
        if sourceItem.isCollapsed != collapsesSource { sourceItem.isCollapsed = collapsesSource }
        if previewItem.isCollapsed != collapsesPreview { previewItem.isCollapsed = collapsesPreview }
        isAnimatingLayout = false
        splitView.needsDisplay = true
        splitView.window?.invalidateCursorRects(for: splitView)
        if layout == .split {
            placeDivider()
            if syncsScrolling { syncPreviewToSource() }
        }
        updateActiveBlock()
    }

    private func isInside(_ view: NSView, _ responder: NSResponder?) -> Bool {
        guard let candidate = responder as? NSView else { return false }
        return candidate.isDescendant(of: view)
    }

    /// Opens the find bar of the pane being read: the source, or the preview when it is alone.
    func showFindBar() {
        let target: NSTextView = layout == .preview ? (preview.contentTextView ?? sourceView) : sourceView
        target.window?.makeFirstResponder(target)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        target.performTextFinderAction(item)
    }

    /// Selects a character of the preview, which moves the source caret to its block.
    private func placeCaret(atPreviewCharacter index: Int) {
        guard let textView = preview.contentTextView else { return }
        if textView.window?.firstResponder !== textView { textView.window?.makeFirstResponder(textView) }
        textView.setSelectedRange(NSRange(location: index, length: 0))
    }

    // MARK: Broken links

    /// Underlines with dots the given ranges of the source (the destinations
    /// of broken links), replacing the previous marks. Drawn by the text
    /// view: they touch neither the text nor undo.
    func markBrokenLinks(_ ranges: [NSRange]) {
        guard ranges != brokenLinkRanges else { return }
        brokenLinkRanges = ranges
        sourceView.dottedRanges = ranges
    }

    private(set) var brokenLinkRanges: [NSRange] = []

    // MARK: Notifications

    @objc private func sourceFrameDidChange(_ notification: Notification) {
        ruler.needsDisplay = true
    }

    @objc private func previewViewportDidResize(_ notification: Notification) {
        guard !isAnimatingLayout else { return }
        if syncsScrolling, layout == .split { syncPreviewToSource() }
        updateActiveBlock()
    }

    @objc private func previewFrameDidChange(_ notification: Notification) {
        guard !isAnimatingLayout else { return }
        updateActiveBlock()
    }

    /// A click in the preview puts the source caret at the start of the block clicked.
    @objc private func previewSelectionDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView.window?.firstResponder === textView,
              let document, textView.selectedRange().length == 0,
              let index = preview.selectedBlockIndex,
              index < document.blocks.count, let line = document.blocks[index].sourceLines?.lowerBound else { return }
        let lines = highlighter.lines
        let target = min(line - 1, lines.lineCount - 1)
        guard caret.line != target else { return }
        // The reader is in the preview: the source must not scroll it back.
        suppressesCaretSync = true
        sourceView.setSelectedRange(NSRange(location: lines.starts[target], length: 0))
        suppressesCaretSync = false
        if layout != .split || !syncsScrolling {
            sourceView.scrollRangeToVisible(NSRange(location: lines.starts[target], length: 0))
        }
    }
}

// MARK: - Delegates

extension EditorPanes: NSTextViewDelegate, NSTextStorageDelegate {
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            // The source view's storage is the only one this delegate serves.
            guard !isReplacingText, let storage = sourceView.textStorage else { return }
            highlighter.noteEdit(in: storage.mutableString, editedRange: editedRange, changeInLength: delta)
            // Undo and redo do not always end with `textDidChange`: catch up
            // at the end of the turn if it did not come.
            hasUnreportedEdit = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hasUnreportedEdit else { return }
                    self.reportTextChange()
                }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        reportTextChange()
    }

    private func reportTextChange() {
        hasUnreportedEdit = false
        guard let storage = sourceView.textStorage else { return }
        highlighter.flush(storage)
        ruler.updateThickness()
        ruler.needsDisplay = true
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        caretDidMove()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager ?? view.window?.undoManager
    }

    /// Line breaks other than `\n` (pasted from elsewhere) become `\n`.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, replacementString.contains("\r") else { return true }
        textView.insertText(DecodedText.normalizingLineEndings(replacementString).text, replacementRange: affectedCharRange)
        return false
    }
}

// MARK: - Split view

/// What the window hosts: keeps the split view inside the part of the window
/// the toolbar and the tab bar leave free. The host usually sizes it to that
/// part already, and then the safe area is empty; when it does not, or when
/// the safe area changes after the window was built (tab bar shown or hidden,
/// toolbar style, full screen), both panes move down together.
@MainActor
final class PanesRootView: NSView {
    weak var splitView: NSView?

    /// The bounds without the top safe area (the toolbar and the tab bar).
    var contentRect: NSRect {
        var rect = bounds
        let top = safeAreaInsets.top
        if top > 0 {
            rect.size.height -= top
            if !isFlipped { rect.origin.y = bounds.minY } else { rect.origin.y += top }
        }
        return rect
    }

    override func layout() {
        super.layout()
        let target = contentRect
        if let splitView, splitView.frame != target { splitView.frame = target }
    }

    private var layoutRectObservation: NSKeyValueObservation?

    /// AppKit gives no safe-area callback on macOS 14, so the window's content
    /// layout rect, which moves with the toolbar and the tab bar, is watched.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutRectObservation = window?.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        needsLayout = true
    }
}

/// Holds a ready-made view as a split view item's content.
private final class PaneViewController: NSViewController {
    init(view: NSView) {
        super.init(nibName: nil, bundle: nil)
        self.view = view
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The split view controller of the panes: a collapsed pane leaves no divider.
private final class PanesSplitViewController: NSSplitViewController {
    var isDividerHidden: () -> Bool = { false }

    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        isDividerHidden()
    }

    /// Side by side, a pane never collapses by itself when the window is
    /// narrow; only a layout change collapses one.
    override func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        isDividerHidden() && super.splitView(splitView, canCollapseSubview: subview)
    }
}

/// Reports its first layout with a real size.
private final class PanesSplitView: NSSplitView {
    var onFirstLayout: (() -> Void)?
    /// Called after every layout, once the first one is done.
    var onLayout: (() -> Void)?
    private var hasLaidOut = false

    override func layout() {
        super.layout()
        if hasLaidOut { onLayout?() }
        guard !hasLaidOut, bounds.width > 0 else { return }
        hasLaidOut = true
        onFirstLayout?()
    }
}
