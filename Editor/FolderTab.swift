import AppKit
import KayakomaKit
import Observation

/// A file open in a tab of a folder window: its text, its own panes, undo
/// history and scroll sync, and what it takes to save it without `NSDocument`.
@MainActor
@Observable
final class FolderTab: Identifiable {
    let id = UUID()
    private(set) var url: URL
    let document: MarkdownDocument
    let model: EditorModel
    @ObservationIgnored let undoManager = UndoManager()
    /// Whether the text differs from the file as last read or saved.
    private(set) var isModified = false
    /// Set when the file changed on disk while the tab had unsaved changes.
    private(set) var hasConflict = false

    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var diskDate: Date?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Called when the file changed on disk while the tab is modified.
    @ObservationIgnored var onConflict: ((FolderTab) -> Void)?
    /// Called after each rendering, to mark the broken links again.
    @ObservationIgnored var onRendered: ((FolderTab) -> Void)?

    var name: String { url.lastPathComponent }

    init(url: URL, snapshot: TextFile.Snapshot, syncsScrolling: Bool) {
        self.url = url.canonicalFile
        document = MarkdownDocument(content: snapshot.content,
                                    isPlainText: !FileKind.markdownExtensions.contains(url.pathExtension.lowercased()))
        model = EditorModel(document: document, syncsScrolling: syncsScrolling)
        savedText = snapshot.content.text
        diskDate = snapshot.modificationDate
        model.undoManager = undoManager
        model.panes.undoManager = undoManager
        model.onTextChange = { [weak self] in self?.textDidChange() }
        model.onRendered = { [weak self] in
            guard let self else { return }
            self.onRendered?(self)
        }
        startWatching()
    }

    /// Opens a file of the folder; throws when it cannot be read as text.
    convenience init(url: URL, syncsScrolling: Bool) throws {
        try self.init(url: url, snapshot: TextFile.read(url), syncsScrolling: syncsScrolling)
    }

    func close() {
        watcher?.stop()
        watcher = nil
    }

    private func textDidChange() {
        let modified = document.text != savedText
        if modified != isModified { isModified = modified }
    }

    // MARK: Saving

    /// Whether the file changed on disk since it was read or saved.
    var changedOnDisk: Bool {
        guard let current = TextFile.modificationDate(of: url) else { return false }
        return diskDate.map { abs(current.timeIntervalSince($0)) > 0.001 } ?? true
    }

    /// Writes the text to the file, in its encoding.
    func save() throws {
        watcher?.stop()
        defer { startWatching() }
        let snapshot = try TextFile.write(document.content, to: url)
        model.didSave(as: snapshot.content)
        savedText = snapshot.content.text
        diskDate = snapshot.modificationDate
        hasConflict = false
        textDidChange()
    }

    /// Drops the changes and shows the file as it is on disk.
    func revertToDisk() throws {
        let snapshot = try TextFile.read(url)
        savedText = snapshot.content.text
        diskDate = snapshot.modificationDate
        hasConflict = false
        model.reload(with: snapshot.content)
        textDidChange()
    }

    /// Keeps the text as it is after a conflict: the next save overwrites the file.
    func keepChanges() {
        hasConflict = false
        diskDate = TextFile.modificationDate(of: url)
    }

    // MARK: The file on disk

    /// The file was renamed or moved from the sidebar.
    func move(to newURL: URL) {
        url = newURL.canonicalFile
        startWatching()
    }

    private func startWatching() {
        watcher?.stop()
        watcher = FileWatcher(url: url) { [weak self] in self?.fileDidChange() }
    }

    /// Reloads the file when the tab has no unsaved changes; otherwise asks.
    private func fileDidChange() {
        guard let snapshot = try? TextFile.read(url) else { return }
        guard snapshot.content.text != document.text else {
            savedText = snapshot.content.text
            diskDate = snapshot.modificationDate
            textDidChange()
            return
        }
        if isModified {
            guard !hasConflict, changedOnDisk else { return }
            hasConflict = true
            onConflict?(self)
        } else {
            savedText = snapshot.content.text
            diskDate = snapshot.modificationDate
            model.reload(with: snapshot.content)
        }
    }
}
