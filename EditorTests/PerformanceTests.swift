import AppKit
import KayakomaKit
import XCTest

/// Times one keystroke in a 5,000-line document. The numbers are printed for
/// reading; the assertions only catch a regression by an order of magnitude.
@MainActor
final class PerformanceTests: XCTestCase {
    func testKeystrokeOnALongDocument() throws {
        let text = PanesTests.longDocument(lines: 5_000)
        let panes = EditorPanes(text: text)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panes.splitView
        defer { window.close() }
        panes.show(RenderedDocument(source: text))
        window.displayIfNeeded()
        XCTAssertGreaterThanOrEqual(panes.highlighter.lines.lineCount, 5_000)

        let view = panes.sourceView
        let storage = try XCTUnwrap(view.textStorage)
        // Type in the middle of the document, in a paragraph.
        let middle = panes.highlighter.lines.starts[2_502]
        panes.scrollSource(toLine: 2_500)
        view.setSelectedRange(NSRange(location: middle, length: 0))

        var keystrokes: [Double] = []
        var colouring: [Double] = []
        for index in 0..<60 {
            let character = index % 10 == 9 ? " " : "a"
            let start = DispatchTime.now().uptimeNanoseconds
            view.insertText(character, replacementRange: view.selectedRange())
            keystrokes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            // The highlighter alone, on the same edit.
            let location = view.selectedRange().location
            let colourStart = DispatchTime.now().uptimeNanoseconds
            panes.highlighter.noteEdit(in: storage.mutableString, editedRange: NSRange(location: location - 1, length: 1),
                                       changeInLength: 0)
            panes.highlighter.flush(storage)
            colouring.append(Double(DispatchTime.now().uptimeNanoseconds - colourStart) / 1e6)
        }

        // One caret move with the preview following it, wherever in the document.
        var caretMoves: [Double] = []
        for step in 0..<40 {
            let target = 1_000 + step * 90
            panes.scrollSource(toLine: target - 15)
            let offset = panes.highlighter.lines.starts[target]
            let start = DispatchTime.now().uptimeNanoseconds
            view.setSelectedRange(NSRange(location: offset, length: 0))
            caretMoves.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        // Opening a code fence recolours everything below it.
        let fenceStart = DispatchTime.now().uptimeNanoseconds
        view.insertText("\n```\n", replacementRange: view.selectedRange())
        let fence = Double(DispatchTime.now().uptimeNanoseconds - fenceStart) / 1e6

        let parseStart = DispatchTime.now().uptimeNanoseconds
        let rendered = RenderedDocument(source: view.string)
        let parse = Double(DispatchTime.now().uptimeNanoseconds - parseStart) / 1e6
        let renderStart = DispatchTime.now().uptimeNanoseconds
        panes.show(rendered)
        let render = Double(DispatchTime.now().uptimeNanoseconds - renderStart) / 1e6

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let report = String(format: """
            5,000-line keystroke (%d lines, %d characters):
              keystroke in the text view, colouring included: median %.2f ms, max %.2f ms
              colouring alone: median %.3f ms, max %.3f ms
              caret move, preview sync included: median %.2f ms, max %.2f ms
              opening a code fence (recolours the rest): %.1f ms
              parsing the whole document (off the main thread): %.1f ms
              preview update with one block changed: %.1f ms
            """, panes.highlighter.lines.lineCount, storage.length, median(keystrokes), keystrokes.max()!,
            median(colouring), colouring.max()!, median(caretMoves), caretMoves.max()!, fence, parse, render)
        print(report)
        if let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try? report.write(toFile: path + "/keystroke-timing.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertLessThan(median(colouring), 5)
        XCTAssertLessThan(median(keystrokes), 50)
        XCTAssertLessThan(median(caretMoves), 50)
    }
}
