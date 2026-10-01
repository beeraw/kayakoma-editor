import AppKit
import SwiftUI

/// Colours of the folder window's chrome that AppKit views draw.
enum FolderColor {
    /// Background of the sidebar.
    static let sidebar = NSColor.soft(light: 0xF6F6F3, dark: 0x1C1C1C)
    /// The current file in the sidebar: pale coral.
    static let selection = NSColor.soft(light: 0xFBE8E3, dark: 0xE9836F, darkAlpha: 0.20)
    /// A row selected while the current file is elsewhere (a dimmed file).
    static let quietSelection = NSColor.soft(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.08)
    /// Files the Editor does not open: still legible, clearly behind.
    static let dimmed = NSColor.soft(light: 0xA6AAAE, dark: 0x6E6E73, highContrastLight: 0x6E6E73, highContrastDark: 0x9A9A9F)
    static let label = NSColor.soft(light: 0x1C1C1E, dark: 0xEDEDED)
    static let folderIcon = NSColor.soft(light: 0x868B90, dark: 0x8E8E93)
    /// Icon of a Markdown file: the coral.
    static let documentIcon = NSColor.soft(light: 0xDD6B55, dark: 0xE9836F)
    static let modifiedDot = NSColor.soft(light: 0x6E6E73, dark: 0x9A9A9F)
    /// The folder a drag would drop into: pale coral with a coral outline.
    static let dropFill = NSColor.soft(light: 0xFBE8E3, dark: 0xE9836F, darkAlpha: 0.22)
    /// The whole list as a drop target: lighter, the rows stay legible.
    static let dropRootFill = NSColor.soft(light: 0xFBE8E3, lightAlpha: 0.55, dark: 0xE9836F, darkAlpha: 0.08)
    static let dropStroke = NSColor.soft(light: 0xDD6B55, dark: 0xE9836F, highContrastLight: 0xA84834)
}

extension FileKind {
    var symbolName: String {
        switch self {
        case .folder: "folder"
        case .markdown, .plainText: "doc.text"
        case .other: "doc"
        }
    }

    /// Symbol of a file the Editor does not open, from its extension.
    static func symbolName(forOtherFile url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "svg", "bmp": "photo"
        case "pdf": "doc.richtext"
        case "csv", "tsv", "xlsx", "numbers": "tablecells"
        default: "doc"
        }
    }
}

/// The sidebar of a folder window: the folder's name and a +
/// menu, the tree, and the filter at the bottom.
struct FolderSidebar: View {
    let session: FolderSession
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            FileOutlineView(session: session,
                            generation: session.treeGeneration,
                            expanded: session.expanded,
                            currentURL: session.currentTab?.url,
                            modified: Set(session.tabs.items.filter(\.isModified).map(\.url)),
                            revealRequest: session.revealRequest,
                            renameRequest: session.renameRequest,
                            filter: session.filter)
            filterField
        }
        .background(Color(nsColor: FolderColor.sidebar))
        .onChange(of: session.filterFocusRequest) { _, _ in filterFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SoftColor.iconIdle)
                .accessibilityHidden(true)
            Text(verbatim: session.folderName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(SoftColor.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Menu {
                Button("Nouveau fichier") { session.newFile(in: session.rootURL) }
                Button("Nouveau dossier") { session.newFolder(in: session.rootURL) }
            } label: {
                Label("Nouveau", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(SoftIconButtonStyle(size: CGSize(width: 22, height: 22), idleColor: SoftColor.iconIdle))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Nouveau fichier ou dossier")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dossier \(session.folderName)"))
    }

    /// The filter keeps the hierarchy and underlines what it found; ⎋ clears it.
    private var filterField: some View {
        @Bindable var session = session
        return HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SoftColor.iconIdle)
                .accessibilityHidden(true)
            TextField(text: $session.filter, prompt: Text("Filtrer")) {
                Text("Filtrer les fichiers")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($filterFocused)
            .onExitCommand { session.filter = "" }
            if !session.filter.isEmpty {
                let count = FileTree.fileCount(in: session.visibleTree)
                Text("\(count) fichiers")
                    .font(.system(size: 11))
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .lineLimit(1)
                    .fixedSize()
                Button {
                    session.filter = ""
                } label: {
                    Label("Effacer le filtre", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(SoftIconButtonStyle(size: CGSize(width: 16, height: 16), idleColor: SoftColor.iconIdle))
                .help("Effacer le filtre")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SoftColor.track))
        .padding(8)
    }
}

// MARK: - Outline

/// The tree of the folder in an `NSOutlineView`: 24 pt rows, the current
/// file on pale coral, other files dimmed, a dot on modified files, inline
/// renaming and the context menu. Keyboard: arrows, ⌘↓ opens, ↩ renames.
struct FileOutlineView: NSViewRepresentable {
    let session: FolderSession
    let generation: Int
    let expanded: Set<URL>
    let currentURL: URL?
    let modified: Set<URL>
    let revealRequest: URL?
    let renameRequest: URL?
    let filter: String

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.focusRingType = .none
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.rowClicked(_:))
        outline.doubleAction = #selector(Coordinator.rowDoubleClicked(_:))
        outline.coordinator = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.setAccessibilityLabel(String(localized: "Fichiers du dossier"))
        // Drag and drop: rows are dragged as file URLs; the coordinator draws
        // the target folder itself, always « on » a folder, never between rows.
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .none
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        context.coordinator.reload(generation: generation, expanded: expanded, filter: filter)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        if coordinator.generation != generation {
            coordinator.reload(generation: generation, expanded: expanded, filter: filter)
        } else {
            coordinator.applyExpansion(expanded, filter: filter)
        }
        coordinator.update(currentURL: currentURL, modified: modified)
        if let revealRequest {
            coordinator.reveal(revealRequest)
            DispatchQueue.main.async { if session.revealRequest == revealRequest { session.revealRequest = nil } }
        }
        if let renameRequest {
            DispatchQueue.main.async {
                coordinator.beginRenaming(renameRequest)
                if session.renameRequest == renameRequest { session.renameRequest = nil }
            }
        }
    }

    /// An entry of the outline: the outline view needs objects that stay the
    /// same across reloads, so they are reused by URL.
    final class Item: NSObject {
        let url: URL
        var node: FileNode
        var children: [Item] = []

        init(node: FileNode) {
            url = node.url
            self.node = node
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var session: FolderSession
        weak var outline: SidebarOutlineView?
        private(set) var generation = -1
        private var roots: [Item] = []
        private var items: [URL: Item] = [:]
        private var currentURL: URL?
        private var modified: Set<URL> = []
        private var filter = ""
        /// Set while the outline is expanded or collapsed from the session's state.
        private var isSyncingExpansion = false
        private var renamingURL: URL?
        /// The folder a drag hovers, highlighted; the folder's root is the whole list.
        private(set) var dropTarget: URL?
        private var springLoading: Timer?
        private var springLoadingURL: URL?

        init(session: FolderSession) {
            self.session = session
        }

        // MARK: Data

        func reload(generation: Int, expanded: Set<URL>, filter: String) {
            self.generation = generation
            self.filter = filter
            var reused: [URL: Item] = [:]
            func build(_ nodes: [FileNode]) -> [Item] {
                nodes.map { node in
                    let item = items[node.url] ?? Item(node: node)
                    item.node = node
                    item.children = node.children.map(build) ?? []
                    reused[node.url] = item
                    return item
                }
            }
            roots = build(session.visibleTree)
            items = reused
            guard let outline else { return }
            isSyncingExpansion = true
            outline.reloadData()
            isSyncingExpansion = false
            applyExpansion(expanded, filter: filter)
            selectCurrent()
        }

        /// Opens the folders the session has open; all of them while filtering.
        func applyExpansion(_ expanded: Set<URL>, filter: String) {
            guard let outline else { return }
            isSyncingExpansion = true
            defer { isSyncingExpansion = false }
            func visit(_ items: [Item]) {
                for item in items where item.node.isFolder {
                    let open = !filter.isEmpty || expanded.contains(item.url)
                    if open, !outline.isItemExpanded(item) { outline.expandItem(item) }
                    if !open, outline.isItemExpanded(item) { outline.collapseItem(item) }
                    if open { visit(item.children) }
                }
            }
            visit(roots)
        }

        func update(currentURL: URL?, modified: Set<URL>) {
            let changed = currentURL != self.currentURL || modified != self.modified
            self.currentURL = currentURL
            self.modified = modified
            guard changed, let outline else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let item = outline.item(atRow: row) as? Item,
                      let cell = rowView.view(atColumn: 0) as? SidebarCell else { return }
                configure(cell, for: item)
            }
            selectCurrent()
        }

        private func selectCurrent() {
            guard let outline, let currentURL, renamingURL == nil, let item = items[currentURL] else { return }
            let row = outline.row(forItem: item)
            if row >= 0, outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        func reveal(_ url: URL) {
            guard let outline else { return }
            applyExpansion(session.expanded, filter: filter)
            guard let item = items[url] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Item)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.node.isFolder ?? false
        }

        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = SidebarRowView()
            row.isCurrent = { [weak self] in (item as? Item)?.url == self?.currentURL }
            row.isDropTarget = { [weak self] in
                guard let url = (item as? Item)?.url else { return false }
                return url == self?.dropTarget && url != self?.session.rootURL
            }
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? {
                let cell = SidebarCell()
                cell.identifier = identifier
                cell.textField?.delegate = self
                return cell
            }()
            configure(cell, for: item)
            return cell
        }

        private func configure(_ cell: SidebarCell, for item: Item) {
            let node = item.node
            let isCurrent = item.url == currentURL
            cell.configure(name: node.name, kind: node.kind, url: node.url, isCurrent: isCurrent,
                           isModified: modified.contains(item.url), match: filter)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncingExpansion, filter.isEmpty, let item = notification.userInfo?["NSObject"] as? Item else { return }
            session.expanded.insert(item.url)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingExpansion, filter.isEmpty, let item = notification.userInfo?["NSObject"] as? Item else { return }
            session.expanded.remove(item.url)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            outline?.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        // MARK: Actions

        private var clickedItem: Item? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? Item
        }

        private var selectedItem: Item? {
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return outline.item(atRow: outline.selectedRow) as? Item
        }

        /// A click opens a document, or shows its tab.
        @objc func rowClicked(_ sender: Any?) {
            guard let item = clickedItem, item.node.kind.opensInEditor else { return }
            session.open(item.url)
        }

        /// A double click opens a dimmed file in its default app, or a folder.
        @objc func rowDoubleClicked(_ sender: Any?) {
            guard let item = clickedItem, let outline else { return }
            openItem(item, outline: outline)
        }

        func openSelected() {
            guard let item = selectedItem, let outline else { return }
            openItem(item, outline: outline)
        }

        private func openItem(_ item: Item, outline: NSOutlineView) {
            switch item.node.kind {
            case .folder:
                if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
            case .markdown, .plainText:
                session.open(item.url)
            case .other:
                session.openWithDefaultApp(item.url)
            }
        }

        func renameSelected() {
            if let item = selectedItem { beginRenaming(item.url) }
        }

        func trashSelected() {
            if let item = selectedItem { session.moveToTrash(item.url) }
        }

        /// Turns a row's name into a text field, the name selected without its extension.
        func beginRenaming(_ url: URL) {
            guard let outline, let item = items[url] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
                  let field = cell.textField else { return }
            outline.scrollRowToVisible(row)
            renamingURL = url
            field.stringValue = item.node.name
            field.isEditable = true
            field.isSelectable = true
            outline.window?.makeFirstResponder(field)
            let name = item.node.name as NSString
            let length = item.node.isFolder || name.pathExtension.isEmpty ? name.length : name.deletingPathExtension.utf16.count
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let url = renamingURL else { return }
            renamingURL = nil
            field.isEditable = false
            field.isSelectable = false
            let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
            let name = field.stringValue
            if let item = items[url] { field.stringValue = item.node.name }
            if movement != .cancel { session.rename(url, to: name) }
            outline?.window?.makeFirstResponder(outline)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // ⎋ gives the old name back.
                if let url = renamingURL, let item = items[url] { control.stringValue = item.node.name }
                control.window?.makeFirstResponder(outline)
                return true
            }
            return false
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard renamingURL == nil, let item = item as? Item else { return nil }
            return item.url as NSURL
        }

        /// Drops always land « on » a folder: a file or a gap between rows
        /// stands for the folder that holds it, the empty area for the root.
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let rootURL = session.rootURL, renamingURL == nil else { return clearDrop() }
            var target = item as? Item
            if let file = target, !file.node.isFolder {
                target = outlineView.parent(forItem: file) as? Item
            }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            let folder = target?.url ?? rootURL
            guard let operation = operation(for: info, into: folder) else { return clearDrop() }
            setDropTarget(folder, operation: operation)
            if let target {
                springLoad(target)
            } else {
                springLoading?.invalidate()
                springLoading = nil
            }
            return operation == .move ? .move : .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?,
                         childIndex index: Int) -> Bool {
            defer { clearDrop() }
            guard let rootURL = session.rootURL else { return false }
            let folder = (item as? Item)?.url ?? rootURL
            let sources = Self.fileURLs(in: info)
            guard let operation = operation(for: info, into: folder) else { return false }
            // ⌘Z undoes the drop from the sidebar.
            outlineView.window?.makeFirstResponder(outlineView)
            switch operation {
            case .move:
                return session.move(sources, into: folder)
            case .copy:
                Task { [session] in await session.copy(sources, into: folder) }
                return true
            }
        }

        private func operation(for info: NSDraggingInfo, into folder: URL) -> FileTransfer.Operation? {
            let mask = info.draggingSourceOperationMask
            guard mask.contains(.copy) || mask.contains(.move) || mask.contains(.generic) else { return nil }
            // ⌥ leaves only « copy » in the mask, as in the Finder.
            let prefersCopy = !mask.contains(.move) && !mask.contains(.generic)
            return session.dropOperation(for: Self.fileURLs(in: info), into: folder, prefersCopy: prefersCopy)
        }

        /// The file URLs of a drag; reading them takes the sandbox extension
        /// that comes with a drag from the Finder.
        static func fileURLs(in info: NSDraggingInfo) -> [URL] {
            let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true])
            return (objects as? [URL] ?? []).map(\.canonicalFile)
        }

        /// Highlights the target folder and announces it to VoiceOver.
        func setDropTarget(_ folder: URL?, operation: FileTransfer.Operation = .move) {
            guard folder != dropTarget else { return }
            dropTarget = folder
            guard let outline else { return }
            outline.isRootDropTarget = folder != nil && folder == session.rootURL
            outline.needsDisplay = true
            outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            guard let folder else { return }
            let name = folder == session.rootURL ? session.folderName : folder.lastPathComponent
            let announcement = operation == .copy ? String(localized: "Copier dans « \(name) »")
                : String(localized: "Déplacer dans « \(name) »")
            NSAccessibility.post(element: outline, notification: .announcementRequested,
                                 userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }

        @discardableResult
        func clearDrop() -> NSDragOperation {
            springLoading?.invalidate()
            springLoading = nil
            springLoadingURL = nil
            setDropTarget(nil)
            return []
        }

        /// Spring-loaded folders: a closed folder opens when a drag rests on
        /// it, after the system's spring-loading delay.
        private func springLoad(_ item: Item) {
            guard let outline, item.node.isFolder, !outline.isItemExpanded(item) else {
                springLoading?.invalidate()
                springLoading = nil
                springLoadingURL = nil
                return
            }
            if let timer = springLoading, timer.isValid, springLoadingURL == item.url { return }
            springLoading?.invalidate()
            springLoadingURL = item.url
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "com.apple.springing.enabled") as? Bool ?? true else { return }
            let delay = defaults.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
            let url = item.url
            springLoading = Timer.scheduledTimer(withTimeInterval: max(delay, 0.2), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let outline = self.outline, self.dropTarget == url, let item = self.items[url] else { return }
                    outline.expandItem(item)
                }
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let item = clickedItem
            let folder: URL? = item.map { $0.node.isFolder ? $0.url : $0.url.deletingLastPathComponent() } ?? session.rootURL
            func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                     action: @escaping () -> Void) {
                let menuItem = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
                menuItem.keyEquivalentModifierMask = modifiers
                menu.addItem(menuItem)
            }
            if let item {
                switch item.node.kind {
                case .markdown, .plainText:
                    add(String(localized: "Ouvrir dans un nouvel onglet")) { [weak self] in
                        self?.session.open(item.url, inBackground: true)
                    }
                    menu.addItem(.separator())
                case .other:
                    add(String(localized: "Ouvrir avec l'application par défaut")) { [weak self] in
                        self?.session.openWithDefaultApp(item.url)
                    }
                    menu.addItem(.separator())
                case .folder:
                    break
                }
            }
            add(String(localized: "Nouveau fichier"), key: "n") { [weak self] in self?.session.newFile(in: folder) }
            add(String(localized: "Nouveau dossier"), key: "n", modifiers: [.command, .shift]) { [weak self] in
                self?.session.newFolder(in: folder)
            }
            guard let item else { return }
            menu.addItem(.separator())
            add(String(localized: "Renommer"), key: "\r", modifiers: []) { [weak self] in self?.beginRenaming(item.url) }
            add(String(localized: "Afficher dans le Finder"), key: "r", modifiers: [.command, .option]) { [weak self] in
                self?.session.revealInFinder(item.url)
            }
            menu.addItem(.separator())
            add(String(localized: "Placer dans la corbeille"), key: "\u{8}") { [weak self] in
                self?.session.moveToTrash(item.url)
            }
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The outline view of the sidebar, with the Finder's keys: ⌘↓ opens, ↩
/// renames, ⌘⌫ moves to the Trash.
final class SidebarOutlineView: NSOutlineView {
    weak var coordinator: FileOutlineView.Coordinator?
    /// A drag would drop at the top of the folder: the whole list is outlined.
    var isRootDropTarget = false

    /// Moves and copies made by drag and drop are undone while the sidebar has the focus.
    override var undoManager: UndoManager? {
        coordinator?.session.fileUndoManager ?? super.undoManager
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        coordinator?.clearDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        coordinator?.clearDrop()
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard isRootDropTarget else { return }
        let rect = visibleRect.insetBy(dx: 2.75, dy: 2.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        FolderColor.dropRootFill.setFill()
        path.fill()
        FolderColor.dropStroke.setStroke()
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []):
            coordinator?.renameSelected()
        case (125, [.command]):
            coordinator?.openSelected()
        case (51, [.command]):
            coordinator?.trashSelected()
        default:
            super.keyDown(with: event)
        }
    }

    /// The pale coral row is the highlight; no extra focus ring around the list.
    override var focusRingMaskBounds: NSRect { .zero }
}

/// Draws the current file on pale coral, rounded, inside the sidebar's margins.
final class SidebarRowView: NSTableRowView {
    var isCurrent: () -> Bool = { false }
    var isDropTarget: () -> Bool = { false }

    /// The folder a drag would drop into.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isDropTarget() else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.75, dy: 1.75), xRadius: 6, yRadius: 6)
        FolderColor.dropFill.setFill()
        path.fill()
        FolderColor.dropStroke.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        (isCurrent() ? FolderColor.selection : FolderColor.quietSelection).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A row of the sidebar: icon, name (the part matching the filter
/// underlined), and a dot when the file has unsaved changes.
final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        addSubview(icon)
        addSubview(label)
        addSubview(dot)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -6),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isModified = false

    func configure(name: String, kind: FileKind, url: URL, isCurrent: Bool, isModified: Bool, match: String) {
        let dimmed = kind == .other
        let symbol = kind == .other ? FileKind.symbolName(forOtherFile: url) : kind.symbolName
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        icon.contentTintColor = dimmed ? FolderColor.dimmed : kind.opensInEditor ? FolderColor.documentIcon : FolderColor.folderIcon
        let color = dimmed ? FolderColor.dimmed : FolderColor.label
        let font = NSFont.systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .regular)
        // The attributed string's paragraph style overrides the field's own line break
        // mode: without it, a long name wraps over the next row.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: color,
                                                                        .paragraphStyle: paragraph])
        if let range = FileTree.matchRange(of: match, in: name) {
            text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)],
                               range: NSRange(range, in: name))
        }
        if !label.isEditable { label.attributedStringValue = text }
        toolTip = name
        self.isModified = isModified
        dot.isHidden = !isModified
        updateDotColor()
        var description = name
        switch kind {
        case .folder: description = String(localized: "\(name), dossier")
        case .other: description = String(localized: "\(name), autre fichier")
        case .markdown, .plainText: break
        }
        if isModified { description = String(localized: "\(description), modifié") }
        setAccessibilityLabel(description)
        label.setAccessibilityLabel(description)
    }

    private func updateDotColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = FolderColor.modifiedDot.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDotColor()
    }
}
