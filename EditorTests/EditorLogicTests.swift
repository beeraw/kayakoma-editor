import AppKit
import KayakomaKit
import SwiftUI
import XCTest

final class SyntaxTests: XCTestCase {
    private func tokens(_ line: String, state: MarkdownSyntax.State = .normal, previous: String? = nil,
                        next: String? = nil) -> [(MarkdownSyntax.Kind, String)] {
        let units = Array(line.utf16)
        let result = MarkdownSyntax.tokenize(units, state: state, previous: previous.map { Array($0.utf16) },
                                             next: next.map { Array($0.utf16) })
        return result.tokens.map { ($0.kind, (line as NSString).substring(with: $0.range)) }
    }

    private func has(_ list: [(MarkdownSyntax.Kind, String)], _ kind: MarkdownSyntax.Kind, _ text: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(list.contains { $0.0 == kind && $0.1 == text }, "no \(kind) “\(text)” in \(list)", file: file, line: line)
    }

    func testHeading() {
        let list = tokens("## Getting `started` ##")
        has(list, .heading, "## Getting `started` ##")
        has(list, .marker, "## ")
        has(list, .marker, " ##")
        has(list, .codeSpan, "`started`")
        XCTAssertFalse(tokens("#hashtag").contains { $0.0 == .heading })
    }

    func testEmphasis() {
        let list = tokens("Some **strong** and *light* and __also__ and _this_ and ~~gone~~.")
        has(list, .strong, "**strong**")
        has(list, .emphasis, "*light*")
        has(list, .strong, "__also__")
        has(list, .emphasis, "_this_")
        has(list, .strikethrough, "~~gone~~")
        has(list, .marker, "**")
        // Intraword underscores and lone stars are text.
        XCTAssertFalse(tokens("snake_case_name").contains { $0.0 == .emphasis })
        XCTAssertFalse(tokens("2 * 3 * 4").contains { $0.0 == .emphasis })
        // Nothing inside a code span is emphasis.
        XCTAssertFalse(tokens("`*not*`").contains { $0.0 == .emphasis })
    }

    func testLinks() {
        let list = tokens("See the [station guide](docs/stations.md) or ![a map](map.png) or <https://example.org>.")
        has(list, .marker, "[")
        has(list, .link, "station guide")
        has(list, .marker, "](docs/stations.md)")
        has(list, .marker, "![")
        has(list, .link, "a map")
        has(list, .url, "https://example.org")
        has(tokens("Read https://example.org/a_b_c, then stop."), .url, "https://example.org/a_b_c")
        has(tokens("[ref]: https://example.org \"Title\""), .url, "https://example.org")
        let reference = tokens("A [reference][guide] link.")
        has(reference, .link, "reference")
        has(reference, .marker, "][guide]")
    }

    func testListsAndQuotes() {
        has(tokens("- item"), .listMarker, "- ")
        has(tokens("  12. item"), .listMarker, "12. ")
        has(tokens("- [x] done"), .listMarker, "- [x] ")
        let quote = tokens("> Field notes, *tide* by tide.")
        has(quote, .marker, "> ")
        has(quote, .quote, "Field notes, *tide* by tide.")
        has(quote, .emphasis, "*tide*")
        has(tokens("> - quoted item"), .listMarker, "- ")
        // A rule is not a list item.
        XCTAssertEqual(tokens("- - -").map(\.0), [.marker])
    }

    func testFencedCode() {
        let open = MarkdownSyntax.tokenize(Array("```sh".utf16), state: .normal)
        XCTAssertEqual(open.state, .fencedCode(marker: .backtick, length: 3))
        XCTAssertEqual(open.tokens.map(\.kind), [.fence])
        let inside = MarkdownSyntax.tokenize(Array("$ echo **not bold**".utf16), state: open.state)
        XCTAssertEqual(inside.tokens.map(\.kind), [.code])
        XCTAssertEqual(inside.state, open.state)
        // A shorter fence does not close, a longer one does.
        XCTAssertEqual(MarkdownSyntax.tokenize(Array("``".utf16), state: open.state).state, open.state)
        XCTAssertEqual(MarkdownSyntax.tokenize(Array("````".utf16), state: open.state).state, .normal)
        XCTAssertEqual(MarkdownSyntax.tokenize(Array("~~~".utf16), state: .normal).state, .fencedCode(marker: .tilde, length: 3))
    }

    func testTablesAndSetext() {
        let delimiter = "|---|:--:|"
        XCTAssertEqual(tokens(delimiter).map(\.0), [.marker])
        let row = tokens("| `--station` | none |", next: delimiter)
        XCTAssertEqual(row.filter { $0.0 == .marker && $0.1 == "|" }.count, 3)
        has(row, .codeSpan, "`--station`")
        // Pipes outside tables stay text.
        XCTAssertFalse(tokens("a | b").contains { $0.0 == .marker })
        has(tokens("Title", next: "====="), .heading, "Title")
        XCTAssertEqual(tokens("-----", previous: "Title").map(\.0), [.marker])
    }
}

final class TextModelTests: XCTestCase {
    func testLineIndexFollowsEdits() {
        var generator = SystemRandomNumberGenerator()
        let text = NSMutableString(string: "one\ntwo\n\nfour\n")
        var index = LineIndex(text)
        let pieces = ["", "x", "\n", "ab\ncd", "\n\n", "é\n"]
        for _ in 0..<500 {
            let location = Int.random(in: 0...text.length, using: &generator)
            let length = Int.random(in: 0...min(5, text.length - location), using: &generator)
            let piece = pieces.randomElement(using: &generator)!
            text.replaceCharacters(in: NSRange(location: location, length: length), with: piece)
            let edited = NSRange(location: location, length: (piece as NSString).length)
            index.update(in: text, editedRange: edited, changeInLength: edited.length - length)
            XCTAssertEqual(index, LineIndex(text))
        }
        XCTAssertEqual(index.line(at: 0), 0)
    }

    func testLineIndexLookups() {
        let index = LineIndex("ab\ncd\n" as NSString)
        XCTAssertEqual(index.lineCount, 3)
        XCTAssertEqual(index.line(at: 2), 0)
        XCTAssertEqual(index.line(at: 3), 1)
        XCTAssertEqual(index.line(at: 6), 2)
        XCTAssertEqual(index.range(ofLine: 1), NSRange(location: 3, length: 2))
        XCTAssertEqual(index.rangeWithBreak(ofLine: 1), NSRange(location: 3, length: 3))
    }

    func testWordCount() {
        XCTAssertEqual(TextStatistics.countWords(in: "# Mangrove\n\n- **two** words — and `code` *"), 5)
        XCTAssertEqual(TextStatistics("Été 2026").characters, 8)
    }

    func testListContinuation() {
        XCTAssertEqual(ListContinuation(line: "- item")?.nextMarker, "- ")
        XCTAssertEqual(ListContinuation(line: "  9. item")?.nextMarker, "  10. ")
        XCTAssertEqual(ListContinuation(line: "- [x] done")?.nextMarker, "- [ ] ")
        XCTAssertEqual(ListContinuation(line: "> quoted")?.nextMarker, "> ")
        XCTAssertEqual(ListContinuation(line: "- ")?.isEmptyItem, true)
        XCTAssertNil(ListContinuation(line: "plain text"))
    }
}

final class EncodingTests: XCTestCase {
    func testUTF8WithByteOrderMarkAndCRLFRoundTrips() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# Été\r\n\r\nText\r\n".utf8)
        let decoded = try DecodedText(data: data)
        XCTAssertEqual(decoded.text, "# Été\n\nText\n")
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertTrue(decoded.hasByteOrderMark)
        XCTAssertEqual(decoded.encoded().data, data)
    }

    func testWindows1252RoundTrips() throws {
        let data = Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x80, 0x0A])
        let decoded = try DecodedText(data: data)
        XCTAssertEqual(decoded.encoding, .windows1252)
        XCTAssertEqual(decoded.encoded().data, data)
        XCTAssertEqual(decoded.encoded().encoding, .windows1252)
    }

    func testTextOutsideTheEncodingIsSavedAsUTF8() throws {
        let decoded = try DecodedText(data: Data([0x43, 0x61, 0x66, 0xE9]))
        let edited = DecodedText(text: decoded.text + " 🌊", encoding: decoded.encoding)
        XCTAssertFalse(edited.isEncodable)
        let (data, encoding) = edited.encoded()
        XCTAssertEqual(encoding, .utf8)
        XCTAssertEqual(String(data: data, encoding: .utf8), "Café 🌊")
    }

    func testUTF16RoundTrips() throws {
        let original = "# Titre\n\nTexte é\n"
        let data = try XCTUnwrap(original.data(using: .utf16))
        let decoded = try DecodedText(data: data)
        XCTAssertEqual(decoded.encoding, .utf16)
        XCTAssertEqual(try DecodedText(data: decoded.encoded().data).text, original)
    }

    func testDocumentKeepsItsEncodingOnSave() throws {
        let document = MarkdownDocument(text: "")
        document.replaceContent(DecodedText(text: "Caf\u{E9}\n", encoding: .latin1, lineEnding: .crlf))
        document.text = "Caf\u{E9} au lait\n"
        let content = document.content
        XCTAssertEqual(content.encoding, .latin1)
        XCTAssertEqual(content.encoded().data, Data("Caf\u{E9} au lait\r\n".data(using: .isoLatin1)!))
    }
}

/// Counts notifications posted on the main thread.
final class ScrollCounter: @unchecked Sendable { var count = 0 }

@MainActor
final class PanesTests: XCTestCase {
    static func longDocument(lines: Int) -> String {
        var text = ""
        var section = 0
        while text.utf8.count(where: { $0 == 10 }) < lines {
            section += 1
            text += "## Section \(section)\n\nA paragraph with **strong**, *emphasis*, `code` and a [link](https://example.org/\(section)).\n"
            text += "It wraps onto a second source line that keeps going for a while to fill the width.\n\n"
            text += "- first item\n- second item with `inline code`\n- [ ] a task\n\n"
            text += "```swift\nlet value = \(section)\nprint(value)\n```\n\n"
            text += "> A quote about the tide.\n\n| Key | Value |\n|-----|-------|\n| a   | \(section) |\n\n"
        }
        return text
    }

    private func window(for panes: EditorPanes, size: CGSize = CGSize(width: 1100, height: 700)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panes.rootView
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        panes.show(RenderedDocument(source: panes.text))
        window.displayIfNeeded()
        return window
    }

    /// A collapsed pane is hidden by its split view item's wrapper view.
    private func isCollapsed(_ pane: NSView) -> Bool { pane.isHidden || pane.superview?.isHidden == true }

    // MARK: Top safe area (toolbar and tab bar)

    private func chromeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "panes-tests")
        window.toolbarStyle = .unified
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    /// Both panes, and the first block of the preview, start below the top of the content layout rect.
    private func assertPanesBelowChrome(_ panes: EditorPanes, in window: NSWindow, _ context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        window.layoutIfNeeded()
        settle()
        let top = window.contentLayoutRect.maxY
        let source = panes.sourceScrollView.convert(panes.sourceScrollView.bounds, to: nil)
        let preview = panes.preview.convert(panes.preview.bounds, to: nil)
        XCTAssertLessThanOrEqual(source.maxY, top + 0.5, "source pane under the chrome, \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(preview.maxY, top + 0.5, "preview pane under the chrome, \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(panes.ruler.convert(panes.ruler.bounds, to: nil).maxY, top + 0.5,
                                 "line numbers under the chrome, \(context)", file: file, line: line)
        guard let block = panes.preview.frame(ofBlockAt: 0).map({ panes.preview.convert($0, to: nil) }) else {
            return XCTFail("no first block, \(context)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(block.maxY, min(top, preview.maxY) + 0.5, "first block hidden, \(context)", file: file, line: line)
        XCTAssertEqual(previewClip(panes).bounds.minY, 0, accuracy: 0.5, "preview scrolled away from its top, \(context)",
                       file: file, line: line)
        // The active block's marker follows the block.
        if let bar = panes.preview.contentTextView?.subviews.first(where: { !($0 is NSScrollView) && $0.frame.width == 3 }), !bar.isHidden {
            let barTop = bar.convert(bar.bounds, to: nil).maxY
            XCTAssertLessThanOrEqual(barTop, min(top, preview.maxY) + 0.5, "marker under the chrome, \(context)", file: file, line: line)
        }
    }

    private func addTab(to window: NSWindow) -> NSWindow {
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.tabbingIdentifier = WindowTabbing.identifier
        other.tabbingIdentifier = WindowTabbing.identifier
        window.addTabbedWindow(other, ordered: .above)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return other
    }

    /// The window's own safe area changes after the panes were built: the panes sit directly in the window.
    func testPanesFollowTheTopSafeAreaWhenTheTabBarAppears() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = chromeWindow(content: panes.rootView)
        defer { window.close() }
        panes.show(RenderedDocument(source: panes.text))
        assertPanesBelowChrome(panes, in: window, "before the tab bar")
        let rectBefore = window.contentLayoutRect
        let other = addTab(to: window)
        defer { other.close() }
        XCTAssertLessThan(window.contentLayoutRect.height, rectBefore.height, "the tab bar should take room")
        assertPanesBelowChrome(panes, in: window, "after the tab bar")
        // And back.
        other.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        assertPanesBelowChrome(panes, in: window, "after the tab bar left")
    }

    /// The hosting view sizes the panes to the safe area itself, as in the app.
    func testHostedPanesStayBelowTheTabBar() throws {
        let model = EditorModel(document: MarkdownDocument(text: Self.unevenDocument))
        let panes = model.panes
        let window = chromeWindow(content: NSHostingView(rootView: VStack(spacing: 0) {
            EditorPanesView(model: model, theme: Theme.default, baseURL: nil, sourceFontSize: 13, showsLineNumbers: true, undoManager: nil)
            Text(verbatim: "status").frame(height: 28)
        }))
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        assertPanesBelowChrome(panes, in: window, "before the tab bar")
        let other = addTab(to: window)
        defer { other.close() }
        assertPanesBelowChrome(panes, in: window, "after the tab bar")
    }

    /// A preview synchronised while the window had no size must come back to the top when the pane is resized.
    func testPreviewReturnsToTopWhenThePaneIsResized() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        XCTAssertEqual(panes.sourceScrollView.contentView.bounds.minY, 0, accuracy: 0.5)
        let clip = previewClip(panes)
        // Stale offset, as left by a sync made at another size.
        panes.preview.onTopVisibleSourceLineChange = nil
        panes.preview.contentTextView?.scroll(NSPoint(x: 0, y: 40))
        XCTAssertGreaterThan(clip.bounds.minY, 30)
        window.setContentSize(NSSize(width: 1100, height: 664))
        window.layoutIfNeeded()
        settle()
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.5)
    }

    func testIncrementalColouringMatchesAFullPass() {
        let panes = EditorPanes(text: Self.longDocument(lines: 200))
        let window = window(for: panes)
        defer { window.close() }
        let view = panes.sourceView
        var generator = SystemRandomNumberGenerator()
        let pieces = ["```\n", "x", "\n", "**", "`", "# ", "> ", "| a |\n|---|\n", "~~~"]
        for _ in 0..<150 {
            let length = view.textStorage!.length
            let location = Int.random(in: 0...length, using: &generator)
            let removed = Int.random(in: 0...min(4, length - location), using: &generator)
            view.insertText(pieces.randomElement(using: &generator)!, replacementRange: NSRange(location: location, length: removed))
        }
        let incremental = NSAttributedString(attributedString: view.textStorage!)
        let fresh = EditorPanes(text: view.string)
        XCTAssertEqual(fresh.highlighter.lines, panes.highlighter.lines)
        XCTAssertTrue(incremental.isEqual(to: fresh.sourceView.textStorage!), "incremental colouring drifted from a full pass")
        XCTAssertNotNil(view.textLayoutManager, "the source view fell back to TextKit 1")
    }

    func testScrollSyncMapsLines() {
        let panes = EditorPanes(text: Self.longDocument(lines: 600))
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let document = RenderedDocument(source: panes.text)
        // Scrolled by the preview: the source follows.
        panes.scrollSource(toLine: 233)
        XCTAssertEqual(panes.topVisibleSourceLine, 233)
        // Scrolled by the reader: the preview follows, middle to middle.
        let target = panes.sourceView.lineFragmentFrame(atOffset: panes.highlighter.lines.starts[401])!
        let clipView = panes.sourceScrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: target.minY + panes.sourceView.textContainerOrigin.y))
        panes.sourceScrollView.reflectScrolledClipView(clipView)
        XCTAssertEqual(panes.topVisibleSourceLine, 402)
        let middleLine = Int(panes.linePosition(atSourceY: clipView.bounds.midY)) + 1
        let previewMiddle = panes.preview.contentTextView!.enclosingScrollView!.contentView.bounds.midY
        let previewLine = Int(panes.linePosition(forPreviewY: previewMiddle)!) + 1
        XCTAssertEqual(document.blockIndex(forSourceLine: previewLine), document.blockIndex(forSourceLine: middleLine))
        // Back to the top: both panes show their first line.
        clipView.scroll(to: .zero)
        panes.sourceScrollView.reflectScrolledClipView(clipView)
        XCTAssertEqual(panes.preview.topVisibleSourceLine, 1)
    }

    // MARK: Scroll sync anchors

    /// Blocks whose rendered height differs strongly from their source height.
    static let unevenDocument: String = {
        var text = "# A very large heading\n\n"
        for section in 1...12 {
            text += "## Part \(section)\n\n"
            text += (0..<6).map { "Sentence \($0) of a long paragraph that wraps over many rendered lines, \(section)." }.joined(separator: " ") + "\n\n"
            text += "| Key | Value |\n|-----|-------|\n" + (0..<5).map { "| row \($0) | \(section) |\n" }.joined() + "\n"
            text += "```swift\n" + (0..<10).map { "let value\($0) = \(section)\n" }.joined() + "```\n\n"
            text += "- one\n- two\n- three\n\n"
        }
        return text
    }()

    private func previewClip(_ panes: EditorPanes) -> NSClipView { panes.preview.contentTextView!.enclosingScrollView!.contentView }

    /// Scrolls the preview to its top as a program would, without the reader's scroll reaching the source.
    private func resetPreviewToTop(_ panes: EditorPanes) {
        let handler = panes.preview.onTopVisibleSourceLineChange
        panes.preview.onTopVisibleSourceLineChange = nil
        panes.preview.contentTextView?.scroll(.zero)
        panes.preview.onTopVisibleSourceLineChange = handler
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Lays both panes out completely, so that positions are exact rather than estimated.
    private func layOutEverything(_ panes: EditorPanes) {
        for textView in [panes.sourceView, panes.preview.contentTextView!] {
            textView.textLayoutManager.map { $0.ensureLayout(for: $0.documentRange) }
            textView.sizeToFit()
        }
        settle()
    }

    func testPreviewFollowsTheCaretAtTheSamePlaceInThePane() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let document = try XCTUnwrap(panes.document)
        let lines = panes.highlighter.lines
        let source = panes.sourceScrollView.contentView
        let preview = previewClip(panes)
        let textView = try XCTUnwrap(panes.preview.contentTextView)
        // Source lines in the lower part of the viewport, inside blocks of every kind.
        for sourceTop in [60, 100, 140] {
            panes.scrollSource(toLine: sourceTop)
            settle()
            var checked = 0
            for line in (sourceTop + 12)...(sourceTop + 40) {
                resetPreviewToTop(panes)  // far from where the caret's block is
                panes.sourceView.setSelectedRange(NSRange(location: lines.starts[line], length: 0))
                settle()
                let extents = try XCTUnwrap(panes.sourceView.verticalExtents(atOffset: lines.starts[line]))
                let centre = (extents.visualLine.lowerBound + extents.visualLine.upperBound) / 2
                guard centre - source.bounds.minY > source.bounds.height * 0.4,
                      centre < source.bounds.maxY else { continue }
                let relative = (centre - source.bounds.minY) / source.bounds.height
                let blockIndex = try XCTUnwrap(document.blockIndex(forSourceLine: line + 1))
                let frame = try XCTUnwrap(panes.preview.frame(ofBlockAt: blockIndex).map { panes.preview.convert($0, to: textView) })
                let wanted = preview.bounds.minY + relative * preview.bounds.height
                XCTAssertTrue(frame.minY - 2 <= wanted && wanted <= frame.maxY + 2,
                              "line \(line + 1): block \(frame.minY)...\(frame.maxY) misses the caret's place \(wanted)")
                // Inside the block, the position follows the line.
                let paragraphHeight = extents.paragraph.upperBound - extents.paragraph.lowerBound
                let position = CGFloat(line) + (centre - extents.paragraph.lowerBound) / paragraphHeight
                let expected = try XCTUnwrap(panes.previewY(forLinePosition: position))
                XCTAssertEqual(expected - preview.bounds.minY, relative * preview.bounds.height, accuracy: Self.syncAccuracy,
                               "line \(line + 1)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 3)
        }
    }

    /// Accuracy of the caret placement when the preview is not clamped by its ends.
    static let syncAccuracy: CGFloat = 3

    func testCaretWithinToleranceDoesNotScrollThePreview() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let lines = panes.highlighter.lines
        panes.scrollSource(toLine: 100)
        panes.sourceView.setSelectedRange(NSRange(location: lines.starts[118], length: 0))
        settle()
        let before = previewClip(panes).bounds.minY
        // Typing on the same line moves nothing.
        for _ in 0..<5 { panes.sourceView.insertText("x", replacementRange: panes.sourceView.selectedRange()) }
        settle()
        XCTAssertEqual(previewClip(panes).bounds.minY, before, accuracy: 0.01)
    }

    func testScrollingTheSourceAnchorsOnItsMiddle() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let source = panes.sourceScrollView.contentView
        let preview = previewClip(panes)
        for line in [90, 150, 210] {
            let y = try XCTUnwrap(panes.sourceY(forLinePosition: CGFloat(line)))
            source.scroll(to: NSPoint(x: 0, y: y))
            panes.sourceScrollView.reflectScrolledClipView(source)
            settle()
            let middle = panes.linePosition(atSourceY: source.bounds.midY)
            let previewY = try XCTUnwrap(panes.previewY(forLinePosition: middle))
            XCTAssertEqual(previewY - preview.bounds.minY, preview.bounds.height / 2, accuracy: Self.syncAccuracy, "source top \(line)")
        }
    }

    func testScrollingThePreviewAnchorsOnItsMiddle() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let source = panes.sourceScrollView.contentView
        let preview = previewClip(panes)
        let textView = try XCTUnwrap(panes.preview.contentTextView)
        for fraction in [0.3, 0.5, 0.7] {
            let y = (textView.frame.height - preview.bounds.height) * fraction
            textView.scroll(NSPoint(x: 0, y: y))
            textView.enclosingScrollView?.reflectScrolledClipView(preview)
            settle()
            let position = try XCTUnwrap(panes.linePosition(forPreviewY: preview.bounds.midY))
            let sourceY = try XCTUnwrap(panes.sourceY(forLinePosition: position))
            XCTAssertEqual(sourceY - source.bounds.minY, source.bounds.height / 2, accuracy: Self.syncAccuracy, "preview at \(fraction)")
        }
    }

    func testEdgesGoToEdgesTogether() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let source = panes.sourceScrollView.contentView
        let preview = previewClip(panes)
        let textView = try XCTUnwrap(panes.preview.contentTextView)
        // Source to the bottom: the preview reaches its bottom.
        // (The text view's height catches up with layout as the reader reaches the end: scroll twice.)
        for _ in 0..<2 {
            source.scroll(to: NSPoint(x: 0, y: panes.sourceView.frame.height))
            panes.sourceScrollView.reflectScrolledClipView(source)
            settle()
        }
        XCTAssertEqual(preview.bounds.maxY, textView.frame.height, accuracy: 2)
        // Source back to the top: the preview too.
        source.scroll(to: .zero)
        panes.sourceScrollView.reflectScrolledClipView(source)
        settle()
        XCTAssertEqual(preview.bounds.minY, 0, accuracy: 0.5)
        // Preview to the bottom: the source reaches its bottom.
        textView.scroll(NSPoint(x: 0, y: textView.frame.height))
        settle()
        XCTAssertEqual(source.bounds.maxY, panes.sourceView.frame.height, accuracy: 2)
        textView.scroll(.zero)
        settle()
        XCTAssertEqual(source.bounds.minY, 0, accuracy: 0.5)
    }

    func testProgrammaticScrollsDoNotSyncBack() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        let source = panes.sourceScrollView.contentView
        let preview = previewClip(panes)
        let scrolls = ScrollCounter()
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: preview, queue: nil) { _ in
            scrolls.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // A caret move scrolls the preview; the source must stay where it was.
        panes.scrollSource(toLine: 100)
        settle()
        let sourceOffset = source.bounds.minY
        let lines = panes.highlighter.lines
        panes.sourceView.setSelectedRange(NSRange(location: lines.starts[125], length: 0))
        settle()
        XCTAssertGreaterThan(scrolls.count, 0)
        XCTAssertEqual(source.bounds.minY, sourceOffset, accuracy: 0.01, "the preview scroll echoed back into the source")
        // The preview scrolled by the panes does not move the source either.
        let before = source.bounds.minY
        panes.syncPreviewToCaret()
        XCTAssertEqual(source.bounds.minY, before, accuracy: 0.01)
    }

    func testSyncToggleAndSinglePaneLeaveThePreviewAlone() throws {
        let panes = EditorPanes(text: Self.unevenDocument)
        let window = window(for: panes)
        defer { window.close() }
        layOutEverything(panes)
        panes.syncsScrolling = false
        let preview = previewClip(panes)
        let before = preview.bounds.minY
        panes.scrollSource(toLine: 150)
        panes.sourceView.setSelectedRange(NSRange(location: panes.highlighter.lines.starts[160], length: 0))
        settle()
        XCTAssertEqual(preview.bounds.minY, before, accuracy: 0.01)
    }

    func testPreviewGeometryComesFromTheEngine() throws {
        let panes = EditorPanes(text: "# Title\n\nParagraph.\n\n- one\n- two\n")
        let window = window(for: panes)
        defer { window.close() }
        XCTAssertEqual(panes.sourceScrollView.frame.width, panes.splitView.bounds.width / 2, accuracy: 2, "the first layout splits in half")
        let list = try XCTUnwrap(panes.preview.frame(ofBlockAt: 2))
        let title = try XCTUnwrap(panes.preview.frame(ofBlockAt: 0))
        XCTAssertLessThan(list.maxY, title.minY, "the list is drawn below the title")
        XCTAssertEqual(panes.preview.blockIndex(at: CGPoint(x: list.midX, y: list.midY)), 2)
        XCTAssertNil(panes.preview.frame(ofBlockAt: 3))
        // Caret in the list: both panes mark lines 5 and 6.
        panes.sourceView.setSelectedRange(NSRange(location: ("# Title\n\nParagraph.\n\n- o" as NSString).length, length: 0))
        XCTAssertEqual(panes.sourceView.activeLines, 4...5)
    }

    func testSinglePaneLayoutsHideTheDivider() throws {
        let panes = EditorPanes(text: Self.longDocument(lines: 60))
        panes.animatesLayoutChanges = false
        let window = window(for: panes)
        defer { window.close() }
        let split = panes.splitView
        let delegate = try XCTUnwrap(split.delegate)
        let width = split.bounds.width
        func hidesDivider() -> Bool { delegate.splitView?(split, shouldHideDividerAt: 0) ?? false }

        XCTAssertFalse(hidesDivider())
        XCTAssertFalse(isCollapsed(panes.sourceScrollView))
        XCTAssertFalse(isCollapsed(panes.preview))
        split.setPosition((width * 0.35).rounded(), ofDividerAt: 0)
        let keptWidth = panes.sourceScrollView.frame.width

        panes.layout = .source
        window.layoutIfNeeded()
        XCTAssertTrue(hidesDivider())
        XCTAssertTrue(isCollapsed(panes.preview))
        XCTAssertEqual(panes.sourceScrollView.frame.width, width, accuracy: 1)

        panes.layout = .preview
        window.layoutIfNeeded()
        XCTAssertTrue(hidesDivider())
        XCTAssertTrue(isCollapsed(panes.sourceScrollView))
        XCTAssertEqual(panes.preview.frame.width, width, accuracy: 1)

        // Scrolling while a pane is hidden must not trip the synchronisation.
        panes.scrollSource(toLine: 20)
        panes.show(RenderedDocument(source: panes.text + "\nmore\n"))

        panes.layout = .split
        window.layoutIfNeeded()
        XCTAssertFalse(hidesDivider())
        XCTAssertFalse(isCollapsed(panes.sourceScrollView))
        XCTAssertFalse(isCollapsed(panes.preview))
        XCTAssertGreaterThan(split.dividerThickness, 0)
        XCTAssertEqual(panes.sourceScrollView.frame.width, keptWidth, accuracy: 2, "the split position is restored")
        XCTAssertLessThan(panes.sourceScrollView.frame.width, width)
        XCTAssertGreaterThan(panes.preview.frame.width, 0)
    }

    /// Finds the panes of a hosted document window.
    private func panes(in view: NSView) -> EditorPanes? {
        if let source = view as? SourceTextView { return source.delegate as? EditorPanes }
        for subview in view.subviews {
            if let panes = panes(in: subview) { return panes }
        }
        return nil
    }

    func testAnimatedLayoutSwitchesSettleEvenWhenRapid() throws {
        // Hosted like the app's window, which keeps its size while the panes slide.
        // The window must keep the size it is given, not grow to the screen.
        UserDefaults.standard.set(false, forKey: Preferences.opensWindowsLarge)
        defer { UserDefaults.standard.removeObject(forKey: Preferences.opensWindowsLarge) }
        let size = CGSize(width: 1000, height: 520)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DocumentWindow(document: MarkdownDocument(text: Self.longDocument(lines: 60)), fileURL: nil))
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.close() }
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func settle(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !done(), Date() < deadline { spin(0.05) }
            spin(0.05)
        }
        spin(0.5)
        let panes = try XCTUnwrap(panes(in: window.contentView!))
        let width = panes.splitView.bounds.width
        let before = panes.sourceScrollView.frame.width
        XCTAssertEqual(before, width / 2, accuracy: 2)
        XCTAssertTrue(panes.animatesLayoutChanges)

        for layout in [EditorLayout.source, .preview, .source, .split, .preview] {
            panes.layout = layout
            spin(0.05)
        }
        panes.scrollSource(toLine: 10)
        settle { isCollapsed(panes.sourceScrollView) && !isCollapsed(panes.preview) }
        XCTAssertTrue(isCollapsed(panes.sourceScrollView))
        XCTAssertEqual(panes.preview.frame.width, width, accuracy: 1)
        XCTAssertEqual(panes.splitView.delegate?.splitView?(panes.splitView, shouldHideDividerAt: 0), true)

        panes.layout = .source
        settle { isCollapsed(panes.preview) && !isCollapsed(panes.sourceScrollView) }
        XCTAssertEqual(panes.sourceScrollView.frame.width, width, accuracy: 1)

        panes.layout = .split
        settle { !isCollapsed(panes.preview) }
        spin(0.4)
        XCTAssertFalse(isCollapsed(panes.sourceScrollView))
        XCTAssertEqual(panes.sourceScrollView.frame.width, before, accuracy: 2)
        XCTAssertEqual(window.frame.width, size.width, accuracy: 1, "the window keeps its size")
    }
}

@MainActor
final class WindowTabbingTests: XCTestCase {
    func testModeFollowsPreference() {
        XCTAssertEqual(WindowTabbing.mode(opensInTabs: true), .preferred)
        XCTAssertEqual(WindowTabbing.mode(opensInTabs: false), .automatic)
    }

    func testConfigureSetsIdentifierAndMode() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        WindowTabbing.configure(window, opensInTabs: true)
        XCTAssertEqual(window.tabbingMode, .preferred)
        XCTAssertEqual(window.tabbingIdentifier, WindowTabbing.identifier)
        WindowTabbing.configure(window, opensInTabs: false)
        XCTAssertEqual(window.tabbingMode, .automatic)
        XCTAssertEqual(window.tabbingIdentifier, WindowTabbing.identifier)
    }

    func testOpensInTabsDefaultsToOn() {
        let defaults = UserDefaults(suiteName: "tabbing-tests")!
        defaults.removePersistentDomain(forName: "tabbing-tests")
        XCTAssertTrue(defaults.opensInTabs)
        defaults.set(false, forKey: Preferences.opensInTabs)
        XCTAssertFalse(defaults.opensInTabs)
        defaults.removePersistentDomain(forName: "tabbing-tests")
    }
}

