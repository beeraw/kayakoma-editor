import AppKit
import KayakomaKit
import Observation
import SwiftUI

/// What a folder window restores with the window: its tabs, the
/// current one, the open folders of the sidebar and whether it is shown.
/// Paths are relative to the folder.
struct FolderWindowState: Codable, Equatable {
    var tabs: [String] = []
    var current: String?
    var expanded: [String] = []
    var sidebarHidden = false

    init(tabs: [String] = [], current: String? = nil, expanded: [String] = [], sidebarHidden: Bool = false) {
        self.tabs = tabs
        self.current = current
        self.expanded = expanded
        self.sidebarHidden = sidebarHidden
    }

    init?(encoded: String) {
        guard !encoded.isEmpty, let data = encoded.data(using: .utf8),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = state
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// The state of one folder window: the folder's tree, the open tabs, and
/// the actions of the sidebar, the tab bar, the palette and the menus.
@MainActor
@Observable
final class FolderSession {
    let reference: FolderReference
    /// The folder, once the bookmark resolved; `nil` when it cannot be found.
    private(set) var rootURL: URL?
    var folderName: String { rootURL?.lastPathComponent ?? reference.name }

    /// The folder as read from disk, hidden files included or not.
    private(set) var tree: [FileNode] = []
    private(set) var hasScanned = false
    /// Bumped at each change of what the sidebar shows.
    private(set) var treeGeneration = 0
    private(set) var tabs = TabList<FolderTab>()
    /// Open folders of the sidebar.
    var expanded: Set<URL> = []
    var filter = "" {
        didSet { if filter != oldValue { treeGeneration += 1 } }
    }
    var isSidebarHidden = false
    var sidebarWidth: Double {
        didSet { memory.setSidebarWidth(sidebarWidth, for: reference.path) }
    }
    /// Bumped to put the keyboard focus in the sidebar's filter field.
    var filterFocusRequest = 0
    var isQuickOpenShown = false
    /// A file or folder the sidebar must show and select (then clears it).
    var revealRequest: URL?
    /// A file or folder the sidebar must start renaming (then clears it).
    var renameRequest: URL?

    private(set) var showsHiddenFiles = false
    private(set) var hidesOtherFiles = false
    private(set) var marksBrokenLinks = true

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var access: FolderAccess?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private var pendingState: FolderWindowState?
    @ObservationIgnored private let memory: FolderMemory
    @ObservationIgnored private var linkPopover: NSPopover?
    /// A file to open in a tab once the folder is read, and whom to tell.
    @ObservationIgnored private var pendingFile: (url: URL, completion: (Bool) -> Void)?

    /// The tree as the sidebar shows it.
    var visibleTree: [FileNode] {
        FileTree.filtered(tree, hidesOtherFiles: hidesOtherFiles, query: filter)
    }

    var currentTab: FolderTab? { tabs.current }
    var hasDocuments: Bool { tree.contains { $0.containsDocuments } }
    var hasModifiedTabs: Bool { tabs.items.contains { $0.isModified } }

    /// Set when the folder cannot be found any more.
    private(set) var isMissing = false
    /// A newer reference when the folder moved or its bookmark was stale.
    private(set) var refreshedReference: FolderReference?
    @ObservationIgnored private var isStarted = false

    /// Light: nothing is read before `start`.
    init(reference: FolderReference, memory: FolderMemory = FolderMemory()) {
        self.reference = reference
        self.memory = memory
        sidebarWidth = memory.sidebarWidth(for: reference.path)
    }

    /// Gets access to the folder, starts reading and watching it, then
    /// reopens the saved tabs, or the folder's README when there are none.
    func start(state: FolderWindowState?, showsHiddenFiles: Bool, hidesOtherFiles: Bool, marksBrokenLinks: Bool) {
        guard !isStarted else { return }
        isStarted = true
        guard let resolution = reference.resolve() else {
            isMissing = true
            return
        }
        let rootURL = resolution.url.canonicalFile
        self.rootURL = rootURL
        access = FolderAccess(url: rootURL, securityScoped: resolution.isSecurityScoped)
        refreshedReference = resolution.refreshed
        memory.remember(resolution.refreshed ?? reference)
        FolderSessions.register(self)
        self.showsHiddenFiles = showsHiddenFiles
        self.hidesOtherFiles = hidesOtherFiles
        self.marksBrokenLinks = marksBrokenLinks
        pendingState = state ?? FolderWindowState()
        if let state {
            expanded = Set(state.expanded.map { rootURL.appending(path: $0).canonicalFile })
            isSidebarHidden = state.sidebarHidden
        }
        watcher = FolderWatcher(url: rootURL) { [weak self] in self?.rescan() }
        rescan()
    }

    /// Stops watching and closes the tabs; the window is going away.
    func stop() {
        watcher?.stop()
        watcher = nil
        scanning?.cancel()
        for tab in tabs.items { tab.close() }
        access?.stop()
        FolderSessions.unregister(self)
    }

    var state: FolderWindowState {
        guard let rootURL else { return FolderWindowState() }
        func relative(_ url: URL) -> String? { FolderPath.relative(url, to: rootURL) }
        return FolderWindowState(tabs: tabs.items.compactMap { relative($0.url) },
                                 current: currentTab.flatMap { relative($0.url) },
                                 expanded: expanded.compactMap(relative).sorted(),
                                 sidebarHidden: isSidebarHidden)
    }

    // MARK: Tree

    func setOptions(showsHiddenFiles: Bool, hidesOtherFiles: Bool, marksBrokenLinks: Bool) {
        let rescans = showsHiddenFiles != self.showsHiddenFiles
        if hidesOtherFiles != self.hidesOtherFiles { treeGeneration += 1 }
        self.showsHiddenFiles = showsHiddenFiles
        self.hidesOtherFiles = hidesOtherFiles
        if marksBrokenLinks != self.marksBrokenLinks {
            self.marksBrokenLinks = marksBrokenLinks
            for tab in tabs.items { configureLinks(of: tab) }
        }
        if rescans { rescan() }
    }

    /// Reads the folder again off the main thread.
    func rescan() {
        guard let rootURL else { return }
        scanning?.cancel()
        let hidden = showsHiddenFiles
        scanning = Task { [weak self] in
            let nodes = await Task.detached(priority: .userInitiated) {
                FileTree.scan(rootURL, showsHiddenFiles: hidden)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(nodes)
        }
    }

    /// Reads the folder at once; after a change made by the window itself.
    func rescanNow() {
        guard let rootURL else { return }
        scanning?.cancel()
        apply(FileTree.scan(rootURL, showsHiddenFiles: showsHiddenFiles))
    }

    private func apply(_ nodes: [FileNode]) {
        if nodes != tree {
            tree = nodes
            treeGeneration += 1
            for tab in tabs.items { revalidateLinks(of: tab) }
        }
        if !hasScanned {
            hasScanned = true
            restoreTabs()
            if let pending = pendingFile {
                pendingFile = nil
                openInitialFile(pending.url, completion: pending.completion)
            }
        }
    }

    /// Opens a file handed over by a document window in a tab, as soon as
    /// the folder is read; `completion` tells whether the tab is open. A
    /// file outside the folder gets no tab.
    func openInitialFile(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard hasScanned else {
            pendingFile = (url, completion)
            return
        }
        guard let rootURL, FolderHandoff.relativePath(of: url, in: rootURL) != nil else { return completion(false) }
        open(url)
        completion(tab(for: url) != nil)
    }

    private func restoreTabs() {
        guard let rootURL, let state = pendingState else { return }
        pendingState = nil
        for path in state.tabs {
            let url = rootURL.appending(path: path)
            if let tab = try? FolderTab(url: url, syncsScrolling: UserDefaults.standard.syncsScrollingByDefault) {
                add(tab, restoring: true)
            }
        }
        if let current = state.current, let tab = tab(for: rootURL.appending(path: current)) {
            tabs.select(tab.id)
        }
        if tabs.isEmpty, state.tabs.isEmpty, pendingFile == nil, let home = homeDocument() {
            open(home)
        }
    }

    /// README.md, or index.md, at the top of the folder.
    func homeDocument() -> URL? {
        let files = tree.filter { !$0.isFolder && $0.kind == .markdown }
        for wanted in ["readme.md", "index.md", "readme.markdown", "index.markdown"] {
            if let file = files.first(where: { $0.name.lowercased() == wanted }) { return file.url }
        }
        return nil
    }

    /// Relative paths of the files the palette offers.
    var documentPaths: [String] {
        guard let rootURL else { return [] }
        return FileTree.documents(in: tree).compactMap { FolderPath.relative($0, to: rootURL) }
    }

    var recentPaths: [String] { memory.recentFiles(for: reference.path) }

    // MARK: Tabs

    func tab(for url: URL) -> FolderTab? {
        let target = url.canonicalFile
        return tabs.items.first { $0.url == target }
    }

    /// Opens a file of the folder in a tab right after the current one, or
    /// shows its tab when it is open already; scrolls to `anchor` if given.
    func open(_ url: URL, inBackground: Bool = false, anchor: String? = nil, focusEditor: Bool = false) {
        let url = url.canonicalFile
        if let existing = tab(for: url) {
            if !inBackground { select(existing) }
            if let anchor { scroll(existing, toAnchor: anchor) }
            return
        }
        do {
            let tab = try FolderTab(url: url, syncsScrolling: UserDefaults.standard.syncsScrollingByDefault)
            add(tab, inBackground: inBackground)
            if !inBackground { didShow(tab) }
            if let anchor { scroll(tab, toAnchor: anchor) }
            if focusEditor, !inBackground { focusSource(of: tab) }
        } catch {
            presentError(String(localized: "Impossible d'ouvrir « \(url.lastPathComponent) »."),
                         detail: String(localized: "Le fichier n'est pas du texte, ou il ne peut pas être lu."))
        }
    }

    private func add(_ tab: FolderTab, inBackground: Bool = false, restoring: Bool = false) {
        tab.onConflict = { [weak self] tab in self?.resolveConflict(tab) }
        tab.onRendered = { [weak self] tab in self?.markSourceLinks(of: tab) }
        tab.model.panes.onLinkClick = { [weak self, weak tab] click in
            guard let self, let tab else { return false }
            return self.followLink(click, from: tab)
        }
        configureLinks(of: tab)
        if restoring { tabs.append(tab) } else { tabs.insert(tab, inBackground: inBackground) }
    }

    func select(_ tab: FolderTab) {
        tabs.select(tab.id)
        didShow(tab)
    }

    func selectNeighbour(offset: Int) {
        tabs.selectNeighbour(offset: offset)
        if let tab = currentTab { didShow(tab) }
    }

    func move(_ tab: FolderTab, to index: Int) {
        tabs.move(tab.id, to: index)
    }

    private func didShow(_ tab: FolderTab) {
        guard let rootURL, let path = FolderPath.relative(tab.url, to: rootURL) else { return }
        memory.noteRecentFile(path, for: reference.path)
        reveal(tab.url, select: true)
    }

    /// Closes a tab, after asking to save it when it is modified. The window
    /// stays open with no tab.
    func close(_ tab: FolderTab) {
        guard tab.isModified else {
            discard(tab)
            return
        }
        select(tab)
        Task {
            if await askToSave(tab) { discard(tab) }
        }
    }

    func closeCurrentTab() {
        if let tab = currentTab { close(tab) }
    }

    private func discard(_ tab: FolderTab) {
        tab.close()
        tabs.remove(tab.id)
        if let current = currentTab { reveal(current.url, select: true) }
    }

    /// Asks, tab after tab, what to do with the unsaved changes; `false` when
    /// the user cancels.
    func reviewUnsavedTabs() async -> Bool {
        for tab in tabs.items where tab.isModified {
            select(tab)
            guard await askToSave(tab) else { return false }
        }
        return true
    }

    /// The standard sheet: Enregistrer · Annuler · Ne pas enregistrer.
    private func askToSave(_ tab: FolderTab) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Voulez-vous enregistrer les modifications apportées au document « \(tab.name) » ?")
        alert.informativeText = String(localized: "Vos modifications seront perdues si vous ne les enregistrez pas.")
        alert.addButton(withTitle: String(localized: "Enregistrer"))
        alert.addButton(withTitle: String(localized: "Annuler"))
        let dontSave = alert.addButton(withTitle: String(localized: "Ne pas enregistrer"))
        dontSave.hasDestructiveAction = true
        switch await run(alert) {
        case .alertFirstButtonReturn:
            return save(tab)
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Saving

    /// Saves a tab; asks first when another app changed the file since.
    @discardableResult
    func save(_ tab: FolderTab) -> Bool {
        do {
            try tab.save()
            return true
        } catch {
            presentError(String(localized: "Impossible d'enregistrer « \(tab.name) »."), detail: error.localizedDescription)
            return false
        }
    }

    func saveCurrentTab() {
        guard let tab = currentTab else { return }
        guard tab.changedOnDisk, FileManager.default.fileExists(atPath: tab.url.path) else {
            save(tab)
            return
        }
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "« \(tab.name) » a été modifié par une autre application depuis son ouverture.")
            alert.informativeText = String(localized: "Enregistrer remplacera la version du disque par la vôtre.")
            alert.addButton(withTitle: String(localized: "Enregistrer quand même"))
            alert.addButton(withTitle: String(localized: "Annuler"))
            if await run(alert) == .alertFirstButtonReturn { save(tab) }
        }
    }

    /// The file changed on disk while its tab has unsaved changes.
    private func resolveConflict(_ tab: FolderTab) {
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "« \(tab.name) » a été modifié par une autre application.")
            alert.informativeText = String(localized: "Recharger affiche la version du disque et abandonne vos modifications.")
            alert.addButton(withTitle: String(localized: "Garder mes modifications"))
            alert.addButton(withTitle: String(localized: "Recharger"))
            if await run(alert) == .alertSecondButtonReturn {
                do { try tab.revertToDisk() } catch { tab.keepChanges() }
            } else {
                tab.keepChanges()
            }
        }
    }

    // MARK: Files and folders

    /// The folder new files go to: the one given, the current file's, or the top.
    private func targetFolder(_ folder: URL?) -> URL? {
        if let folder { return folder }
        return currentTab?.url.deletingLastPathComponent() ?? rootURL
    }

    /// Creates « Sans titre.md », opens it and starts renaming it in the sidebar.
    func newFile(in folder: URL? = nil) {
        guard let folder = targetFolder(folder) else { return }
        let url = FolderPath.uniqueURL(in: folder, base: String(localized: "Sans titre"), extension: "md")
        do {
            try Data().write(to: url, options: .withoutOverwriting)
        } catch {
            return presentError(String(localized: "Impossible de créer le fichier."), detail: error.localizedDescription)
        }
        rescanNow()
        open(url)
        renameRequest = url.canonicalFile
    }

    func newFolder(in folder: URL? = nil) {
        guard let folder = targetFolder(folder) else { return }
        let url = FolderPath.uniqueURL(in: folder, base: String(localized: "Nouveau dossier"), extension: nil)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            return presentError(String(localized: "Impossible de créer le dossier."), detail: error.localizedDescription)
        }
        rescanNow()
        reveal(url, select: true)
        renameRequest = url.canonicalFile
    }

    /// Renames a file or folder in place; open tabs follow it. Links that
    /// point to it are left as they are (v1).
    @discardableResult
    func rename(_ url: URL, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rootURL, !trimmed.isEmpty, trimmed != url.lastPathComponent else { return false }
        guard !trimmed.contains("/"), !trimmed.hasPrefix(".") || showsHiddenFiles else {
            presentError(String(localized: "Le nom « \(trimmed) » ne peut pas être utilisé."),
                         detail: String(localized: "Un nom ne peut pas contenir « / », ni commencer par un point."))
            return false
        }
        let url = url.canonicalFile
        let destination = url.deletingLastPathComponent().appending(path: trimmed).canonicalFile
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            presentError(String(localized: "Impossible de renommer « \(url.lastPathComponent) »."), detail: error.localizedDescription)
            return false
        }
        relocate(from: url, to: destination, root: rootURL)
        rescanNow()
        reveal(destination, select: true)
        return true
    }

    /// Open tabs, open folders and recent files follow an entry that moved:
    /// tabs keep their unsaved changes and watch the new path.
    private func relocate(from old: URL, to new: URL, root: URL) {
        for tab in tabs.items {
            if let newURL = FileTransfer.relocated(tab.url, from: old, to: new) { tab.move(to: newURL) }
        }
        expanded = Set(expanded.map { FileTransfer.relocated($0, from: old, to: new) ?? $0 })
        if let oldPath = FolderPath.relative(old, to: root), let newPath = FolderPath.relative(new, to: root) {
            memory.renameRecentFile(oldPath, to: newPath, for: reference.path)
        }
    }

    // MARK: Drag and drop

    /// Moves and copies made by drag and drop are undone from the sidebar
    /// (⌘Z): the window's undo manager, or the session's own without a window.
    @ObservationIgnored private let ownUndoManager = UndoManager()
    var fileUndoManager: UndoManager { window?.undoManager ?? ownUndoManager }

    /// What a drop of `sources` on `folder` would do; `nil` refuses it.
    func dropOperation(for sources: [URL], into folder: URL, prefersCopy: Bool) -> FileTransfer.Operation? {
        guard let rootURL else { return nil }
        return FileTransfer.operation(for: sources, into: folder, root: rootURL, prefersCopy: prefersCopy) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Moves entries of the folder into one of its folders. Refuses, with an
    /// explanation, to replace an entry of the same name; links pointing to
    /// the moved entries are left as they are (v1). `false` when nothing moved.
    @discardableResult
    func move(_ sources: [URL], into folder: URL) -> Bool {
        let folder = folder.canonicalFile
        var moves: [(from: URL, to: URL)] = []
        for source in sources.map(\.canonicalFile) {
            switch FileTransfer.checkMove(source, into: folder, exists: { FileManager.default.fileExists(atPath: $0.path) }) {
            case .alreadyThere, .intoItself:
                continue
            case .nameTaken(let name):
                presentError(String(localized: "Un élément nommé « \(name) » existe déjà dans « \(folder.lastPathComponent) »."),
                             detail: String(localized: "Renommez l'un des deux avant de le déplacer. Rien n'a été modifié."))
            case nil:
                moves.append((source, folder.appending(path: source.lastPathComponent, directoryHint: .notDirectory)))
            }
        }
        return perform(moves)
    }

    /// Moves each entry to its exact destination, never over an existing
    /// one, and registers the inverse moves for undo (and then redo).
    @discardableResult
    private func perform(_ moves: [(from: URL, to: URL)]) -> Bool {
        guard let rootURL else { return false }
        var done: [(from: URL, to: URL)] = []
        for move in moves {
            do {
                try FileManager.default.moveItem(at: move.from, to: move.to)
            } catch {
                presentError(String(localized: "Impossible de déplacer « \(move.from.lastPathComponent) »."),
                             detail: error.localizedDescription)
                continue
            }
            relocate(from: move.from, to: move.to, root: rootURL)
            done.append(move)
        }
        guard !done.isEmpty else { return false }
        let inverse = done.reversed().map { (from: $0.to, to: $0.from) }
        let undoManager = fileUndoManager
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { _ = session.perform(inverse) }
        }
        // « Annuler le déplacement »: AppKit puts « Annuler » in front.
        undoManager.setActionName(String(localized: "le déplacement"))
        rescanNow()
        if done.count == 1, let moved = done.first { reveal(moved.to, select: true) }
        return true
    }

    /// Copies entries into a folder of the window, off the main thread; a
    /// name already taken gets a number, like the Finder (« notes 2.md »).
    /// Copied files are not opened. Undo moves the copies to the Trash.
    @discardableResult
    func copy(_ sources: [URL], into folder: URL) async -> [URL] {
        let folder = folder.canonicalFile
        var planned: Set<String> = []
        var copies: [(from: URL, to: URL)] = []
        for source in sources.map(\.canonicalFile) where !FolderPath.isInside(folder, source) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            let name = FileTransfer.copyName(for: source.lastPathComponent, isFolder: isDirectory.boolValue) { name in
                planned.contains(name.lowercased())
                    || FileManager.default.fileExists(atPath: folder.appending(path: name).path)
            }
            planned.insert(name.lowercased())
            copies.append((source, folder.appending(path: name, directoryHint: .notDirectory)))
        }
        let results = await Task.detached(priority: .userInitiated) {
            copies.map { copy -> (URL, String?) in
                do {
                    try FileManager.default.copyItem(at: copy.from, to: copy.to)
                    return (copy.to, nil)
                } catch {
                    return (copy.from, error.localizedDescription)
                }
            }
        }.value
        var copied: [URL] = []
        for (url, failure) in results {
            if let failure {
                presentError(String(localized: "Impossible de copier « \(url.lastPathComponent) »."), detail: failure)
            } else {
                copied.append(url)
            }
        }
        guard !copied.isEmpty else { return [] }
        let undoManager = fileUndoManager
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                for url in copied { session.moveToTrash(url) }
            }
        }
        undoManager.setActionName(String(localized: "la copie"))
        rescanNow()
        if copied.count == 1, let url = copied.first { reveal(url, select: true) }
        return copied
    }

    /// Moves a file or folder to the Trash (never a permanent deletion);
    /// the tabs of unmodified files inside it close.
    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            return presentError(String(localized: "Impossible de placer « \(url.lastPathComponent) » dans la corbeille."),
                                detail: error.localizedDescription)
        }
        for tab in tabs.items where FolderPath.isInside(tab.url, url) && !tab.isModified {
            discard(tab)
        }
        rescanNow()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// A dimmed file: its default app opens it.
    func openWithDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens the sidebar's folders down to `url` and selects it.
    func reveal(_ url: URL, select: Bool) {
        guard let rootURL else { return }
        let url = url.canonicalFile
        for folder in FolderPath.ancestors(of: url, in: rootURL) where !expanded.contains(folder) {
            expanded.insert(folder)
        }
        if select { revealRequest = url }
    }

    // MARK: Links

    /// A click on a link of a tab's preview; `false` leaves it to the engine
    /// (anchors of the same document, web links).
    func followLink(_ click: MarkdownView.LinkClick, from tab: FolderTab) -> Bool {
        guard let rootURL else { return false }
        switch LinkTarget.resolve(click.url, root: rootURL, currentFile: tab.url) {
        case .anchor, .external:
            return false
        case .document(let url, let anchor):
            open(url, anchor: anchor)
        case .folder(let url):
            isSidebarHidden = false
            reveal(url, select: true)
        case .otherFile(let url):
            NSWorkspace.shared.open(url)
        case .missing(let url, let canCreate):
            showMissingFile(url, linkText: click.text, canCreate: canCreate, in: tab)
        case .outside(let url, let opensInEditor):
            if opensInEditor {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if error != nil { NSWorkspace.shared.open(url) }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }

    private func scroll(_ tab: FolderTab, toAnchor anchor: String) {
        // The preview must be on screen and laid out first.
        Task { [weak tab] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(60))
                guard let tab else { return }
                let preview = tab.model.panes.preview
                if preview.window != nil, preview.bounds.height > 0 {
                    preview.scrollToAnchor(anchor)
                    return
                }
            }
        }
    }

    private func configureLinks(of tab: FolderTab) {
        let preview = tab.model.panes.preview
        if marksBrokenLinks, let rootURL {
            preview.isLinkBroken = { LinkTarget.isBroken($0, root: rootURL) }
        } else {
            preview.isLinkBroken = nil
        }
        markSourceLinks(of: tab)
    }

    private func revalidateLinks(of tab: FolderTab) {
        guard marksBrokenLinks else { return }
        tab.model.panes.preview.revalidateLinks()
        markSourceLinks(of: tab)
    }

    /// Dotted underline under the destinations of broken links in the source.
    private func markSourceLinks(of tab: FolderTab) {
        let panes = tab.model.panes
        guard marksBrokenLinks, let rootURL else {
            panes.markBrokenLinks([])
            return
        }
        let base = tab.url.deletingLastPathComponent()
        let ranges = SourceLinks.find(in: panes.text).compactMap { link -> NSRange? in
            guard let url = SourceLinks.resolve(link.destination, baseURL: base),
                  LinkTarget.isBroken(url, root: rootURL) else { return nil }
            return link.range
        }
        panes.markBrokenLinks(ranges)
    }

    /// The bubble shown when the link's file does not exist.
    private func showMissingFile(_ url: URL, linkText: String, canCreate: Bool, in tab: FolderTab) {
        guard let rootURL else { return }
        let preview = tab.model.panes.preview
        linkPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let relative = FolderPath.relative(url, to: rootURL) ?? url.lastPathComponent
        let content = MissingFilePopover(fileName: url.lastPathComponent, relativePath: relative, folderName: folderName,
                                         canCreate: canCreate,
                                         cancel: { [weak popover] in popover?.close() },
                                         create: { [weak self, weak popover] in
                                             popover?.close()
                                             self?.createLinkedFile(url, linkText: linkText)
                                         })
        let hosting = NSHostingController(rootView: content.environment(\.softAccent, .coral))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        var point = NSPoint(x: preview.bounds.midX, y: preview.bounds.midY)
        if let event = NSApp.currentEvent, event.window === preview.window {
            point = preview.convert(event.locationInWindow, from: nil)
        }
        popover.show(relativeTo: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4), of: preview, preferredEdge: .maxY)
        linkPopover = popover
    }

    /// « Créer le fichier »: a new document titled after the link, in a new tab.
    func createLinkedFile(_ url: URL, linkText: String) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let heading = LinkTarget.heading(forLinkText: linkText, file: url)
            try Data(heading.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            return presentError(String(localized: "Impossible de créer « \(url.lastPathComponent) »."), detail: error.localizedDescription)
        }
        rescanNow()
        open(url, focusEditor: true)
    }

    // MARK: Focus and alerts

    func focusSource(of tab: FolderTab) {
        Task { [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let tab, let window = self?.window else { return }
            window.makeFirstResponder(tab.model.panes.sourceView)
        }
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    /// Replaces the alert, in tests.
    @ObservationIgnored var errorPresenter: ((_ message: String, _ detail: String) -> Void)?

    func presentError(_ message: String, detail: String) {
        if let errorPresenter { return errorPresenter(message, detail) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        Task { _ = await run(alert) }
    }
}

/// The open folder windows, for quitting with unsaved changes.
@MainActor
enum FolderSessions {
    private final class Weak {
        weak var session: FolderSession?
        init(_ session: FolderSession) { self.session = session }
    }

    private static var entries: [Weak] = []

    static var all: [FolderSession] { entries.compactMap(\.session) }

    static func register(_ session: FolderSession) {
        entries.removeAll { $0.session == nil }
        entries.append(Weak(session))
    }

    static func unregister(_ session: FolderSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
    }

    /// Asks about every modified tab of every folder window; `false` when
    /// the user cancels.
    static func reviewAllUnsaved() async -> Bool {
        for session in all where session.hasModifiedTabs {
            session.window?.makeKeyAndOrderFront(nil)
            guard await session.reviewUnsavedTabs() else { return false }
        }
        return true
    }
}

/// The non-blocking bubble shown for a link to a missing file.
struct MissingFilePopover: View {
    let fileName: String
    let relativePath: String
    let folderName: String
    let canCreate: Bool
    let cancel: () -> Void
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.badge.exclamationmark")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(SoftColor.iconIdle, .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("« \(fileName) » est introuvable")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SoftColor.label)
                    Text("Le lien pointe vers \(Text(verbatim: relativePath).font(.system(size: 11, design: .monospaced))), qui n'existe pas dans « \(folderName) ».")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SoftColor.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(canCreate ? "Annuler" : "OK", action: cancel)
                    .keyboardShortcut(.cancelAction)
                if canCreate {
                    Button("Créer le fichier", action: create)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 300)
    }
}
