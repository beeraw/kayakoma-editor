import Foundation

/// The folder of a folder window, as the window keeps it across launches: its
/// path, and a security-scoped bookmark that gives the sandboxed app access to
/// it again (and follows it when it is moved or renamed).
///
/// Two references to the same path are the same window: opening a folder
/// that is already open brings its window forward.
struct FolderReference: Codable, Hashable, Sendable {
    let path: String
    let bookmark: Data?

    init(path: String, bookmark: Data?) {
        self.path = path
        self.bookmark = bookmark
    }

    /// A reference to a folder the user chose (open panel, drop): the
    /// bookmark must be made while the app has access to it.
    init(url: URL) {
        let url = url.standardizedFileURL
        path = url.path
        bookmark = Self.makeBookmark(for: url)
    }

    /// A folder dropped from the Finder, while the drop's sandbox extension
    /// gives access to it; `nil` when its bookmark does not give the app
    /// write access to the folder.
    init?(droppedURL url: URL) {
        let url = url.standardizedFileURL
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return nil }
        self.init(path: url.path, bookmark: bookmark)
        guard let resolution = resolve(), resolution.isSecurityScoped else { return nil }
        let started = resolution.url.startAccessingSecurityScopedResource()
        defer { if started { resolution.url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isWritableFile(atPath: resolution.url.path) else { return nil }
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    static func makeBookmark(for url: URL) -> Data? {
        // Outside the sandbox (tests), a security scope may be refused: a
        // plain bookmark still follows the folder.
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The folder's current location, from the bookmark when there is one.
    struct Resolution {
        let url: URL
        /// A new reference when the bookmark was stale or the folder moved.
        let refreshed: FolderReference?
        let isSecurityScoped: Bool
    }

    func resolve() -> Resolution? {
        guard let bookmark else {
            return FileManager.default.fileExists(atPath: path) ? Resolution(url: url, refreshed: nil, isSecurityScoped: false) : nil
        }
        var stale = false
        var scoped = true
        var resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        if resolved == nil {
            scoped = false
            resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        guard let url = resolved?.standardizedFileURL else {
            return FileManager.default.fileExists(atPath: path) ? Resolution(url: self.url, refreshed: nil, isSecurityScoped: false) : nil
        }
        var refreshed: FolderReference?
        if stale || url.path != path {
            let started = scoped && url.startAccessingSecurityScopedResource()
            refreshed = FolderReference(path: url.path, bookmark: Self.makeBookmark(for: url) ?? bookmark)
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return Resolution(url: url, refreshed: refreshed, isSecurityScoped: scoped)
    }
}

/// Access to a folder for as long as its window is open. Used from the main
/// actor only; `deinit` runs once nothing else holds it.
final class FolderAccess: @unchecked Sendable {
    let url: URL
    private var isAccessing = false

    init(url: URL, securityScoped: Bool) {
        self.url = url
        if securityScoped { isAccessing = url.startAccessingSecurityScopedResource() }
    }

    func stop() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit {
        stop()
    }
}

/// What a folder window remembers about its folder outside the window's own
/// restoration: the sidebar width (per folder), the recent files, and
/// the folder's bookmark, so that a document window can open it again
/// without asking.
struct FolderMemory {
    let defaults: UserDefaults

    static let sidebarWidthsKey = "folderSidebarWidths"
    static let recentFilesKey = "folderRecentFiles"
    static let bookmarksKey = "folderBookmarks"
    static let defaultSidebarWidth: Double = 216
    static let sidebarWidthRange: ClosedRange<Double> = 160...420
    static let recentLimit = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sidebarWidth(for folder: String) -> Double {
        let widths = defaults.dictionary(forKey: Self.sidebarWidthsKey) as? [String: Double] ?? [:]
        return widths[folder].map { min(max($0, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound) }
            ?? Self.defaultSidebarWidth
    }

    func setSidebarWidth(_ width: Double, for folder: String) {
        var widths = defaults.dictionary(forKey: Self.sidebarWidthsKey) as? [String: Double] ?? [:]
        widths[folder] = width
        defaults.set(widths, forKey: Self.sidebarWidthsKey)
    }

    /// Relative paths, most recent first.
    func recentFiles(for folder: String) -> [String] {
        (defaults.dictionary(forKey: Self.recentFilesKey) as? [String: [String]])?[folder] ?? []
    }

    func noteRecentFile(_ relativePath: String, for folder: String) {
        var all = defaults.dictionary(forKey: Self.recentFilesKey) as? [String: [String]] ?? [:]
        var list = all[folder] ?? []
        list.removeAll { $0 == relativePath }
        list.insert(relativePath, at: 0)
        all[folder] = Array(list.prefix(Self.recentLimit))
        defaults.set(all, forKey: Self.recentFilesKey)
    }

    func renameRecentFile(_ old: String, to new: String, for folder: String) {
        var all = defaults.dictionary(forKey: Self.recentFilesKey) as? [String: [String]] ?? [:]
        guard var list = all[folder] else { return }
        list = list.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 }
        all[folder] = list
        defaults.set(all, forKey: Self.recentFilesKey)
    }

    /// The reference last opened for `path`, with its bookmark.
    func reference(forPath path: String) -> FolderReference? {
        guard let bookmark = (defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data])?[path] else { return nil }
        return FolderReference(path: path, bookmark: bookmark)
    }

    func remember(_ reference: FolderReference) {
        guard let bookmark = reference.bookmark else { return }
        var all = defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        all[reference.path] = bookmark
        defaults.set(all, forKey: Self.bookmarksKey)
    }
}
