import Foundation

/// What the Editor does with an entry of a folder.
enum FileKind: Sendable, Equatable {
    case folder
    case markdown
    case plainText
    case other

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let plainTextExtensions: Set<String> = ["txt"]

    init(url: URL, isDirectory: Bool) {
        if isDirectory {
            self = .folder
            return
        }
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.plainTextExtensions.contains(ext) {
            self = .plainText
        } else {
            self = .other
        }
    }

    /// Whether the Editor opens the file in a tab; other files are dimmed.
    var opensInEditor: Bool { self == .markdown || self == .plainText }
}

/// One entry of a folder's tree.
struct FileNode: Sendable, Hashable, Identifiable {
    let url: URL
    let name: String
    let kind: FileKind
    /// The entries of a folder, sorted; `nil` for a file.
    var children: [FileNode]?
    /// Whether the entry, or one of the entries inside it, opens in the Editor.
    let containsDocuments: Bool

    var id: URL { url }
    var isFolder: Bool { kind == .folder }

    init(url: URL, name: String? = nil, kind: FileKind, children: [FileNode]? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.kind = kind
        self.children = children
        containsDocuments = kind.opensInEditor || (children?.contains { $0.containsDocuments } ?? false)
    }
}

/// Reads a folder into a tree of ``FileNode``, and filters it for the sidebar.
enum FileTree {
    /// Entries read at most, so that a huge folder cannot stall the window.
    static let entryLimit = 20_000

    /// Reads the folder and everything inside it, folders first, then files,
    /// in Finder order. Hidden entries (a leading dot, or the hidden flag) are
    /// left out unless `showsHiddenFiles`. Blocking: call it off the main thread.
    static func scan(_ root: URL, showsHiddenFiles: Bool, limit: Int = entryLimit) -> [FileNode] {
        var budget = limit
        return scanFolder(root, showsHiddenFiles: showsHiddenFiles, budget: &budget)
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]

    private static func scanFolder(_ folder: URL, showsHiddenFiles: Bool, budget: inout Int) -> [FileNode] {
        guard budget > 0 else { return [] }
        let options: FileManager.DirectoryEnumerationOptions = showsHiddenFiles ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: options) else { return [] }
        var folders: [(URL, String)] = []
        var files: [(URL, String)] = []
        for found in urls {
            let url = found.canonicalFile
            let name = url.lastPathComponent
            if !showsHiddenFiles, name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Packages (an app, a bundle) are files; links are not followed.
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                && !(values?.isSymbolicLink ?? false)
            if isDirectory { folders.append((url, name)) } else { files.append((url, name)) }
        }
        let byName: ((URL, String), (URL, String)) -> Bool = { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        folders.sort(by: byName)
        files.sort(by: byName)
        var nodes: [FileNode] = []
        for (url, name) in folders {
            guard budget > 0 else { break }
            budget -= 1
            let children = scanFolder(url, showsHiddenFiles: showsHiddenFiles, budget: &budget)
            nodes.append(FileNode(url: url, name: name, kind: .folder, children: children))
        }
        for (url, name) in files {
            guard budget > 0 else { break }
            budget -= 1
            nodes.append(FileNode(url: url, name: name, kind: FileKind(url: url, isDirectory: false)))
        }
        return nodes
    }

    /// The tree as the sidebar shows it: without the files the Editor does not
    /// open (and the folders left empty) when `hidesOtherFiles`, and only the
    /// entries whose name holds `query`, with their folders, when there is one.
    static func filtered(_ nodes: [FileNode], hidesOtherFiles: Bool, query: String) -> [FileNode] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return nodes.compactMap { filter($0, hidesOtherFiles: hidesOtherFiles, query: query) }
    }

    private static func filter(_ node: FileNode, hidesOtherFiles: Bool, query: String) -> FileNode? {
        if hidesOtherFiles, !node.containsDocuments { return nil }
        let matches = query.isEmpty || matchRange(of: query, in: node.name) != nil
        guard let children = node.children else { return matches ? node : nil }
        // A folder whose name matches keeps its contents; otherwise it stays
        // only to hold the entries that match.
        let kept = children.compactMap { filter($0, hidesOtherFiles: hidesOtherFiles, query: matches ? "" : query) }
        if !matches, kept.isEmpty { return nil }
        return FileNode(url: node.url, name: node.name, kind: .folder, children: kept)
    }

    /// Where `query` is in `name`, ignoring case and accents.
    static func matchRange(of query: String, in name: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// The files the Editor opens, depth first, in sidebar order.
    static func documents(in nodes: [FileNode]) -> [URL] {
        var result: [URL] = []
        func visit(_ nodes: [FileNode]) {
            for node in nodes {
                if let children = node.children { visit(children) } else if node.kind.opensInEditor { result.append(node.url) }
            }
        }
        visit(nodes)
        return result
    }

    /// Number of files (not folders) in the tree.
    static func fileCount(in nodes: [FileNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.children.map { fileCount(in: $0) } ?? 1) }
    }

    /// The node at `url`, if the tree holds it.
    static func node(at url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children, FolderPath.isInside(url, node.url), let found = self.node(at: url, in: children) {
                return found
            }
        }
        return nil
    }
}

extension URL {
    /// The same file URL, standardized and without a trailing slash, so that
    /// a folder compares equal however its URL was made.
    var canonicalFile: URL {
        URL(filePath: standardizedFileURL.path(percentEncoded: false), directoryHint: .notDirectory)
    }
}

/// Paths inside the folder of a window.
enum FolderPath {
    /// Whether `url` is `folder` itself or inside it.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = folder.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Path of `url` from `root` (« docs/stations.md »); `nil` outside it.
    static func relative(_ url: URL, to root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard isInside(url, root) else { return nil }
        if path == base { return "" }
        return String(path.dropFirst(base.hasSuffix("/") ? base.count : base.count + 1))
    }

    /// The folders between `root` (excluded) and `url` (excluded), outermost first.
    static func ancestors(of url: URL, in root: URL) -> [URL] {
        guard let relative = relative(url, to: root), !relative.isEmpty else { return [] }
        var result: [URL] = []
        var current = root.canonicalFile
        for component in relative.split(separator: "/").dropLast() {
            current = current.appending(path: String(component), directoryHint: .notDirectory)
            result.append(current)
        }
        return result
    }

    /// A name not yet taken in `folder`: « Sans titre.md », « Sans titre 2.md »…
    static func uniqueURL(in folder: URL, base: String, extension ext: String?) -> URL {
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? base : "\(base) \(index)"
            let file = ext.map { "\(name).\($0)" } ?? name
            return folder.canonicalFile.appending(path: file, directoryHint: .notDirectory)
        }
        var index = 1
        while FileManager.default.fileExists(atPath: candidate(index).path) { index += 1 }
        return candidate(index)
    }
}
