import AppKit
import KayakomaKit
import Observation

/// Counts shown in the status bar.
struct TextStatistics: Equatable, Sendable {
    var words = 0
    var characters = 0

    init(words: Int = 0, characters: Int = 0) {
        self.words = words
        self.characters = characters
    }

    init(_ text: String) {
        words = Self.countWords(in: text)
        characters = text.count
    }

    /// Words of prose: runs of characters holding at least one letter or digit,
    /// so that Markdown marks do not count.
    static func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { $0.contains { $0.isLetter || $0.isNumber } }
    }
}

/// State of one document window: the panes, the rendered document, and what
/// the status bar shows.
@MainActor
@Observable
final class EditorModel {
    private(set) var document: MarkdownDocument
    private(set) var statistics = TextStatistics()
    private(set) var caretLine = 1
    private(set) var caretColumn = 1
    /// The file's encoding, and whether the text still fits in it.
    private(set) var encoding = DecodedText.Encoding.utf8
    private(set) var lineEnding = DecodedText.LineEnding.lf
    private(set) var savesAsUTF8 = false

    var syncsScrolling: Bool {
        didSet { panesIfLoaded?.syncsScrolling = syncsScrolling }
    }

    var layout = EditorLayout.split {
        didSet {
            if restoresLayout { panesIfLoaded?.setLayoutImmediately(layout) } else { panesIfLoaded?.layout = layout }
        }
    }

    @ObservationIgnored private var restoresLayout = false

    /// Applies the layout saved with the window, without sliding the panes.
    func restoreLayout(_ saved: EditorLayout) {
        restoresLayout = true
        layout = saved
        restoresLayout = false
    }

    /// Called after each edit of the text, undo and redo included.
    @ObservationIgnored var onTextChange: (() -> Void)?
    /// Called after each rendering of the preview.
    @ObservationIgnored var onRendered: (() -> Void)?

    @ObservationIgnored private var panesIfLoaded: EditorPanes?
    @ObservationIgnored private var rendering: Task<Void, Never>?
    @ObservationIgnored private var needsRendering = false

    /// Light: the window's views are built when first shown.
    init(document: MarkdownDocument, syncsScrolling: Bool = true) {
        self.document = document
        self.syncsScrolling = syncsScrolling
        let content = document.content
        encoding = content.encoding
        lineEnding = content.lineEnding
    }

    /// The window's AppKit views, built on first use with the document's text
    /// and its first rendering.
    var panes: EditorPanes {
        if let panesIfLoaded { return panesIfLoaded }
        let text = document.text
        let panes = EditorPanes(text: text, fontSize: CGFloat(UserDefaults.standard.sourceFontSize))
        panes.syncsScrolling = syncsScrolling
        panes.layout = layout
        panes.onTextChange = { [weak self] in self?.sourceDidChange() }
        panes.onCaretChange = { [weak self] line, column in
            self?.caretLine = line
            self?.caretColumn = column
        }
        panesIfLoaded = panes
        panes.show(RenderedDocument(source: text))
        statistics = TextStatistics(text)
        savesAsUTF8 = !document.content.isEncodable
        return panes
    }

    var isPlainText: Bool { document.isPlainText }

    // MARK: Editing

    private func sourceDidChange() {
        guard let panes = panesIfLoaded else { return }
        document.text = panes.text
        scheduleRendering()
        onTextChange?()
    }

    /// Parses the text off the main thread, one parse at a time: edits made
    /// during a parse are rendered together by the next one.
    private func scheduleRendering() {
        guard rendering == nil else {
            needsRendering = true
            return
        }
        let content = document.content
        rendering = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                (RenderedDocument(source: content.text), TextStatistics(content.text), content.isEncodable)
            }.value
            guard let self else { return }
            self.rendering = nil
            self.panesIfLoaded?.show(result.0)
            self.onRendered?()
            if self.statistics != result.1 { self.statistics = result.1 }
            if self.savesAsUTF8 == result.2 { self.savesAsUTF8 = !result.2 }
            let current = self.document.content
            if self.encoding != current.encoding { self.encoding = current.encoding }
            if self.needsRendering {
                self.needsRendering = false
                self.scheduleRendering()
            }
        }
    }

    // MARK: Documents

    /// Takes over a new document object for the same window, after the
    /// document was reverted to its saved version.
    func adopt(_ newDocument: MarkdownDocument) {
        guard newDocument !== document else { return }
        document = newDocument
        replaceText(with: newDocument.content)
    }

    /// The file changed on disk: reload it if the window has no unsaved
    /// changes. With unsaved changes, saving later shows the system's conflict
    /// alert, as for any document.
    func fileDidChange(at url: URL) {
        guard let window = panesIfLoaded?.splitView.window,
              let systemDocument = NSDocumentController.shared.document(for: window),
              !systemDocument.isDocumentEdited,
              let data = try? Data(contentsOf: url),
              let decoded = try? DecodedText(data: data),
              decoded.text != document.text else { return }
        reload(with: decoded)
        systemDocument.fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Replaces the text with the file's, outside undo: the file was reloaded
    /// from disk. Undo history is cleared, as it no longer applies.
    func reload(with decoded: DecodedText) {
        document.replaceContent(decoded)
        replaceText(with: decoded)
        undoManager?.removeAllActions()
    }

    /// Takes the encoding the file was just saved in (UTF-8 when the original
    /// one could not hold the text).
    func didSave(as content: DecodedText) {
        if document.content.encoding != content.encoding {
            document.replaceContent(DecodedText(text: document.text, encoding: content.encoding,
                                                hasByteOrderMark: content.hasByteOrderMark, lineEnding: content.lineEnding))
        }
        encoding = content.encoding
        lineEnding = content.lineEnding
        savesAsUTF8 = !document.content.isEncodable
    }

    @ObservationIgnored weak var undoManager: UndoManager?

    private func replaceText(with content: DecodedText) {
        encoding = content.encoding
        lineEnding = content.lineEnding
        guard let panes = panesIfLoaded, panes.text != content.text else { return }
        panes.setText(content.text)
        scheduleRendering()
    }

    // MARK: Actions

    func showFindBar() {
        panesIfLoaded?.showFindBar()
    }

    func exportPDF(theme: Theme, baseURL: URL?, fileName: String) {
        let rendered = RenderedDocument(source: document.text)
        PDFExport.run(document: rendered, theme: theme, baseURL: baseURL, fileName: fileName,
                      window: panesIfLoaded?.splitView.window ?? NSApp.keyWindow)
    }
}
