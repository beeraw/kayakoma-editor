import Foundation

/// Reading and writing the text files of a folder window, which are not
/// `NSDocument`s: the same rules as ``MarkdownDocument`` (encoding, byte order
/// mark and line endings kept).
enum TextFile {
    struct Snapshot: Equatable {
        let content: DecodedText
        let modificationDate: Date?
    }

    /// Reads and decodes a file; throws for a binary file.
    static func read(_ url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let content = try DecodedText(data: data)
        return Snapshot(content: content, modificationDate: modificationDate(of: url))
    }

    /// Writes the text in its encoding, or UTF-8 when the encoding cannot hold
    /// it, replacing the file atomically and keeping its permissions.
    ///
    /// - Returns: the content as saved (its encoding may have become UTF-8).
    @discardableResult
    static func write(_ content: DecodedText, to url: URL) throws -> Snapshot {
        let (data, encoding) = content.encoded()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        let saved = encoding == content.encoding
            ? content
            : DecodedText(text: content.text, encoding: encoding, hasByteOrderMark: false, lineEnding: content.lineEnding)
        return Snapshot(content: saved, modificationDate: modificationDate(of: url))
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
