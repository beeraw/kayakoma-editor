import Foundation

/// Where a link of the preview leads, from a file of a folder window.
enum LinkTarget: Equatable {
    /// A heading of the same document.
    case anchor(String)
    /// A web page, a mail address: the system opens it.
    case external(URL)
    /// A file of the folder that the Editor opens, at an optional heading.
    case document(URL, anchor: String?)
    /// A folder of the folder: the sidebar shows it.
    case folder(URL)
    /// Another file of the folder (an image, a PDF): its default app opens it.
    case otherFile(URL)
    /// A file of the folder that does not exist; `canCreate` when it would be
    /// a document the Editor opens.
    case missing(URL, canCreate: Bool)
    /// A file outside the folder: a document opens in its own window.
    case outside(URL, opensInEditor: Bool)

    /// Classifies a link resolved by the engine (against the current file's
    /// folder; `#anchor` links stay relative).
    static func resolve(_ url: URL, root: URL, currentFile: URL?,
                        fileExists: (URL) -> (exists: Bool, isDirectory: Bool) = LinkTarget.fileExists) -> LinkTarget {
        if url.scheme == nil, url.host == nil, url.path.isEmpty, let fragment = url.fragment(percentEncoded: false) {
            return .anchor(fragment)
        }
        guard url.isFileURL else { return .external(url) }
        let fragment = url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        let file = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
        if let currentFile, file == currentFile.standardizedFileURL {
            return fragment.map { .anchor($0) } ?? .document(file, anchor: nil)
        }
        let kind = FileKind(url: file, isDirectory: false)
        guard FolderPath.isInside(file, root) else {
            return .outside(file, opensInEditor: kind.opensInEditor)
        }
        let state = fileExists(file)
        guard state.exists else {
            return .missing(file, canCreate: kind.opensInEditor)
        }
        if state.isDirectory { return .folder(file) }
        return kind.opensInEditor ? .document(file, anchor: fragment) : .otherFile(file)
    }

    static func fileExists(_ url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    /// Whether a link of the preview points to a missing file of the folder.
    static func isBroken(_ url: URL, root: URL, fileExists: (URL) -> (exists: Bool, isDirectory: Bool) = LinkTarget.fileExists) -> Bool {
        guard url.isFileURL else { return false }
        let file = URL(fileURLWithPath: url.path(percentEncoded: false)).standardizedFileURL
        return FolderPath.isInside(file, root) && !fileExists(file).exists
    }

    /// The first line of a new file created from a broken link: the link's
    /// text as a heading (« # Calendrier des marées »), or the file's name.
    static func heading(forLinkText text: String, file: URL) -> String {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        if let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        return "# \(title)\n"
    }
}

/// Finds the link destinations of a Markdown source, for marking broken
/// links in the source pane.
enum SourceLinks {
    struct Link: Equatable {
        /// Range of the destination in the source, in UTF-16 units.
        let range: NSRange
        let destination: String
    }

    /// `](destination)` or `](<destination with spaces>)`, with an optional title.
    private static let inline = try! NSRegularExpression(
        pattern: #"\]\(\s*(?:<([^>\n]+)>|([^)\s]+))(?:\s+"[^"]*")?\s*\)"#)
    private static let definition = try! NSRegularExpression(
        pattern: #"(?m)^ {0,3}\[[^\]]+\]:\s*(?:<([^>\n]+)>|(\S+))"#)

    /// Inline links `[text](destination)` and definitions `[label]: destination`.
    static func find(in text: String) -> [Link] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var links: [Link] = []
        for regex in [inline, definition] {
            for match in regex.matches(in: text, range: full) {
                let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard range.location != NSNotFound else { continue }
                links.append(Link(range: range, destination: ns.substring(with: range)))
            }
        }
        return links.sorted { $0.range.location < $1.range.location }
    }

    /// The destination resolved as the engine resolves it, against the
    /// folder of the current file; `nil` for anchors and web links.
    static func resolve(_ destination: String, baseURL: URL) -> URL? {
        if destination.hasPrefix("#") { return nil }
        if let url = URL(string: destination), url.scheme != nil { return url.isFileURL ? url : nil }
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(["#", "?"])) ?? destination
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }
}
