import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")
}

/// A Markdown or plain text file being edited.
///
/// A reference document: the source text view edits the text and registers
/// its own undo actions with the document's undo manager, which is what marks
/// the document as modified. The window's model copies the text here after
/// each edit; saving reads it back from any thread, hence the lock.
final class MarkdownDocument: ReferenceFileDocument, @unchecked Sendable {
    static let readableContentTypes: [UTType] = [.markdown, .plainText]
    static let writableContentTypes: [UTType] = [.markdown, .plainText]

    private let lock = NSLock()
    private var storedContent: DecodedText
    /// Whether the file is plain text (`.txt`) rather than Markdown.
    let isPlainText: Bool

    /// A new, untitled document: empty UTF-8 text.
    init(text: String = "") {
        storedContent = DecodedText(text: text, encoding: .utf8)
        isPlainText = false
    }

    /// A file of a folder window, read by ``TextFile``.
    init(content: DecodedText, isPlainText: Bool) {
        storedContent = content
        self.isPlainText = isPlainText
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            storedContent = try DecodedText(data: data)
        } catch {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        isPlainText = !configuration.contentType.conforms(to: .markdown)
    }

    /// The text, its encoding and its line endings.
    var content: DecodedText {
        lock.withLock { storedContent }
    }

    var text: String {
        get { content.text }
        set {
            lock.withLock {
                let old = storedContent
                storedContent = DecodedText(text: newValue, encoding: old.encoding,
                                            hasByteOrderMark: old.hasByteOrderMark, lineEnding: old.lineEnding)
            }
        }
    }

    /// Replaces the text and its file format, after the file changed on disk.
    func replaceContent(_ content: DecodedText) {
        lock.withLock { storedContent = content }
    }

    func snapshot(contentType: UTType) throws -> DecodedText {
        content
    }

    /// Writes the original encoding back when it can hold the text; otherwise
    /// UTF-8, which the document then keeps (the status bar said so beforehand).
    func fileWrapper(snapshot: DecodedText, configuration: WriteConfiguration) throws -> FileWrapper {
        let (data, encoding) = snapshot.encoded()
        if encoding != snapshot.encoding {
            lock.withLock {
                let current = storedContent
                storedContent = DecodedText(text: current.text, encoding: encoding,
                                            hasByteOrderMark: false, lineEnding: current.lineEnding)
            }
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
