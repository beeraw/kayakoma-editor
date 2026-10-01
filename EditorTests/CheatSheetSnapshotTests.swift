import AppKit
import KayakomaKit
import SwiftUI
import XCTest

/// Renders the Markdown cheat sheet offscreen into PNG files, light and dark.
/// Runs only when `SNAPSHOT_DIR` is set (pass `TEST_RUNNER_SNAPSHOT_DIR` to
/// `xcodebuild test`). Hover (the « Insérer » button) is checked live.
@MainActor
final class CheatSheetSnapshotTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else {
            throw XCTSkip("SNAPSHOT_DIR is not set")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func testCheatSheet() throws {
        let model = EditorModel(document: MarkdownDocument(text: "# Notes\n"))
        let sections: [(String, CheatSheetSection?)] = [
            ("text", .text), ("headings", .headings), ("lists", .lists), ("links", .links), ("code", .code),
            ("tables", .tables), ("quotes", .quotes), ("unsupported", nil),
        ]
        for (name, section) in sections {
            for dark in [false, true] {
                let sheet = EditorCheatSheet(model: model, theme: .editorDefault, isPresented: .constant(true),
                                             initialSection: section)
                try snapshot(sheet, dark: dark, name: "editor-help-\(name)-\(dark ? "dark" : "light")")
            }
        }
        // A folder window with no tab open: rows can only be copied.
        let sheet = EditorCheatSheet(model: nil, theme: .paper, isPresented: .constant(true), initialSection: .lists)
        try snapshot(sheet, dark: false, name: "editor-help-no-file-paper")
    }

    private func snapshot<V: View>(_ view: V, dark: Bool, name: String) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: MarkdownCheatSheet.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = hosting.appearance
        window.contentView = hosting
        window.setContentSize(MarkdownCheatSheet.size)
        for _ in 0..<6 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        var data: Data?
        hosting.appearance!.performAsCurrentDrawingAppearance {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        try XCTUnwrap(data).write(to: outputDirectory.appending(path: name + ".png"))
        window.close()
    }
}
