import Foundation

/// The pure rules of moving and copying entries by drag and drop in a
/// folder window's sidebar.
enum FileTransfer {
    enum Operation: Equatable {
        case move
        case copy
    }

    /// Why an entry cannot be moved into a folder.
    enum Refusal: Equatable {
        /// The folder is the entry itself, or inside it.
        case intoItself
        /// The entry is in that folder already: nothing to do.
        case alreadyThere
        /// The folder holds an entry with the same name.
        case nameTaken(String)
    }

    /// Whether `source` can move into `folder`; `exists` tells whether a
    /// path is taken (the file system is usually case-insensitive).
    static func checkMove(_ source: URL, into folder: URL, exists: (URL) -> Bool) -> Refusal? {
        let source = source.canonicalFile
        let folder = folder.canonicalFile
        if FolderPath.isInside(folder, source) { return .intoItself }
        if source.deletingLastPathComponent().canonicalFile == folder { return .alreadyThere }
        let destination = folder.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
        if exists(destination) { return .nameTaken(source.lastPathComponent) }
        return nil
    }

    /// What a drop of `sources` on `folder` does, or `nil` when it is
    /// refused. Entries of the window's folder move (copy with ⌥, like the
    /// Finder); entries from elsewhere are copied. A name already taken does
    /// not refuse the drop: the drop explains it.
    static func operation(for sources: [URL], into folder: URL, root: URL, prefersCopy: Bool,
                          exists: (URL) -> Bool) -> Operation? {
        guard !sources.isEmpty else { return nil }
        let folder = folder.canonicalFile
        if sources.contains(where: { FolderPath.isInside(folder, $0.canonicalFile) }) { return nil }
        let isLocal = sources.allSatisfy { FolderPath.isInside($0, root) }
        guard isLocal, !prefersCopy else { return .copy }
        let refusals = sources.map { checkMove($0, into: folder, exists: exists) }
        if refusals.allSatisfy({ $0 == .alreadyThere }) { return nil }
        return .move
    }

    /// Where `url` is once `old` moved to `new`: `new` itself, the same path
    /// under `new` when `url` was inside `old`, or `nil` when it is elsewhere.
    static func relocated(_ url: URL, from old: URL, to new: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let oldPath = old.standardizedFileURL.path
        if path == oldPath { return new.canonicalFile }
        guard path.hasPrefix(oldPath + "/") else { return nil }
        return new.appending(path: String(path.dropFirst(oldPath.count + 1))).canonicalFile
    }

    /// The name a copy gets, like the Finder: the same name when it is free,
    /// otherwise a number before the extension (« notes 2.md »), counting on
    /// from a number the name already ends with (« notes 2.md » → « notes 3.md »).
    static func copyName(for name: String, isFolder: Bool, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ns = name as NSString
        var ext = isFolder ? "" : ns.pathExtension
        var stem = ext.isEmpty ? name : ns.deletingPathExtension
        // « .env »: the dot starts the name, not an extension.
        if stem.isEmpty {
            stem = name
            ext = ""
        }
        var index = 2
        if let space = stem.lastIndex(of: " "), let number = Int(stem[stem.index(after: space)...]), number >= 2,
           space > stem.startIndex {
            index = number + 1
            stem = String(stem[..<space])
        }
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !isTaken(candidate) { return candidate }
            index += 1
        }
    }
}
