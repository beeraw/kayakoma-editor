import Foundation

/// Text read from a file, with the encoding that made sense of it.
///
/// Same rules as Kayakoma Viewer's, plus what the editor needs to write the
/// file back as it found it: the byte order mark and the line endings.
struct DecodedText: Equatable, Sendable {
    enum Encoding: Equatable, Sendable {
        case utf8
        case utf16
        /// UTF-8 was invalid; the bytes were read as Windows-1252.
        case windows1252
        /// UTF-8 and Windows-1252 both failed; the bytes were read as ISO Latin-1, which never fails.
        case latin1

        /// Whether the encoding was a guess after UTF-8 failed.
        var isFallback: Bool { self == .windows1252 || self == .latin1 }

        /// Name shown to the user; encoding names are not translated.
        var displayName: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf16: "UTF-16"
            case .windows1252: "Windows-1252"
            case .latin1: "ISO Latin-1"
            }
        }

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .utf16: .utf16
            case .windows1252: .windowsCP1252
            case .latin1: .isoLatin1
            }
        }
    }

    enum LineEnding: Equatable, Sendable {
        case lf
        case crlf

        var displayName: String { self == .lf ? "LF" : "CRLF" }
    }

    /// The text, with `\n` line breaks whatever the file used.
    let text: String
    let encoding: Encoding
    var hasByteOrderMark = false
    var lineEnding = LineEnding.lf

    /// Thrown when the data is not text at all.
    struct BinaryDataError: Error {}

    /// Decodes UTF-8 (with or without a byte order mark) or UTF-16 with a byte
    /// order mark. Invalid UTF-8 falls back to Windows-1252, then Latin-1,
    /// rather than failing. Data holding NUL bytes outside UTF-16 is binary.
    init(data: Data) throws {
        let raw: String
        let encoding: Encoding
        var hasByteOrderMark = false
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            raw = text.droppingByteOrderMark
            encoding = .utf16
            hasByteOrderMark = true
        } else {
            if Self.looksBinary(data) { throw BinaryDataError() }
            if let text = String(data: data, encoding: .utf8) {
                raw = text.droppingByteOrderMark
                encoding = .utf8
                hasByteOrderMark = data.starts(with: [0xEF, 0xBB, 0xBF])
            } else if let text = String(data: data, encoding: .windowsCP1252) {
                raw = text
                encoding = .windows1252
            } else {
                // Every byte is a Latin-1 character, so this cannot fail.
                raw = String(data: data, encoding: .isoLatin1) ?? String(String.UnicodeScalarView(data.map(Unicode.Scalar.init)))
                encoding = .latin1
            }
        }
        let normalized = Self.normalizingLineEndings(raw)
        self.init(text: normalized.text, encoding: encoding)
        self.hasByteOrderMark = hasByteOrderMark
        self.lineEnding = normalized.ending
    }

    init(text: String, encoding: Encoding, hasByteOrderMark: Bool = false, lineEnding: LineEnding = .lf) {
        self.text = text
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
        self.lineEnding = lineEnding
    }

    /// Text never holds NUL bytes; looking at the start of the file is enough.
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    /// The text with `\n` line breaks, and the line ending the file used most.
    /// Lone `\r` (classic Mac OS) become `\n` too.
    static func normalizingLineEndings(_ text: String) -> (text: String, ending: LineEnding) {
        guard text.utf8.contains(13) else { return (text, .lf) }
        let crlf = text.components(separatedBy: "\r\n").count - 1
        let lf = text.utf8.count { $0 == 10 } - crlf
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (normalized, crlf > lf ? .crlf : .lf)
    }
}

extension DecodedText {
    /// Whether the text can be written back in its original encoding.
    var isEncodable: Bool {
        encoding == .utf8 || encoding == .utf16 || text.canBeConverted(to: encoding.stringEncoding)
    }

    /// The file's bytes: the original encoding, byte order mark and line
    /// endings. Text that the original encoding cannot hold is written as UTF-8.
    ///
    /// - Returns: the data, and the encoding actually used.
    func encoded() -> (data: Data, encoding: Encoding) {
        let text = lineEnding == .crlf ? self.text.replacingOccurrences(of: "\n", with: "\r\n") : self.text
        switch encoding {
        case .utf8:
            return ((hasByteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8), .utf8)
        case .utf16:
            // Foundation writes a byte order mark and the platform's byte order.
            return (text.data(using: .utf16) ?? Data(text.utf8), .utf16)
        case .windows1252, .latin1:
            if let data = text.data(using: encoding.stringEncoding, allowLossyConversion: false) {
                return (data, encoding)
            }
            return (Data(text.utf8), .utf8)
        }
    }
}

private extension String {
    var droppingByteOrderMark: String {
        hasPrefix("\u{FEFF}") ? String(dropFirst()) : self
    }
}
