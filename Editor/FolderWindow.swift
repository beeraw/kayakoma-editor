import AppKit
import KayakomaKit
import SwiftUI

private struct FolderSessionKey: FocusedValueKey {
    typealias Value = FolderSession
}

extension FocusedValues {
    /// The session of the key folder window, for the menu bar.
    var folderSession: FolderSession? {
        get { self[FolderSessionKey.self] }
        set { self[FolderSessionKey.self] = newValue }
    }
}

/// A folder window: the sidebar with the folder's tree, the tab bar,
/// and the panes of the current file, which each tab keeps for itself.
struct FolderWindow: View {
    @Binding var reference: FolderReference?

    var body: some View {
        if let reference {
            FolderWindowContent(reference: reference, onMoved: { self.reference = $0 })
                .id(reference.path)
        } else {
            FolderMissingView(name: nil)
        }
    }
}

private struct FolderWindowContent: View {
    let onMoved: (FolderReference) -> Void
    @State private var session: FolderSession
    @SceneStorage("folderState") private var savedState = ""
    @State private var showsCheatSheet = false

    @AppStorage(Preferences.themeID) private var themeID = ThemeLibrary.defaultID
    @AppStorage(Preferences.fontSize) private var fontSize = Preferences.defaultFontSize
    @AppStorage(Preferences.maxLineCharacters) private var maxLineCharacters = Preferences.defaultMaxLineCharacters
    @AppStorage(Preferences.sourceFontSize) private var sourceFontSize = Preferences.defaultSourceFontSize
    @AppStorage(Preferences.showsLineNumbers) private var showsLineNumbers = true
    @AppStorage(Preferences.showsStatusBar) private var showsStatusBar = true
    @AppStorage(Preferences.showsHiddenFiles) private var showsHiddenFiles = false
    @AppStorage(Preferences.hidesOtherFiles) private var hidesOtherFiles = false
    @AppStorage(Preferences.marksBrokenLinks) private var marksBrokenLinks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let library = ThemeLibrary.shared

    init(reference: FolderReference, onMoved: @escaping (FolderReference) -> Void) {
        self.onMoved = onMoved
        _session = State(initialValue: FolderSession(reference: reference))
    }

    var body: some View {
        observingChanges(windowContent)
            .focusedSceneValue(\.folderSession, session)
            .focusedSceneValue(\.editorModel, session.currentTab?.model)
            .focusedSceneValue(\.exportPDF, currentExport)
            .focusedSceneValue(\.showMarkdownCheatSheet, { showsCheatSheet = true })
            .sheet(isPresented: $showsCheatSheet) {
                EditorCheatSheet(model: session.currentTab?.model, theme: theme, isPresented: $showsCheatSheet)
            }
            .environment(\.softAccent, .coral)
    }

    private var windowContent: some View {
        Group {
            if session.isMissing {
                FolderMissingView(name: session.reference.name)
            } else {
                FolderLayout(session: session, theme: theme, sourceFontSize: sourceFontSize,
                             showsLineNumbers: showsLineNumbers, showsStatusBar: showsStatusBar)
            }
        }
        .frame(minWidth: 720, minHeight: 360)
        .background(WindowAccessor { window in configure(window) })
        .background(WindowSizer())
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private func observingChanges<V: View>(_ view: V) -> some View {
        view
            .onAppear(perform: start)
            .onDisappear { session.stop() }
            .onChange(of: session.state) { _, state in savedState = state.encoded }
            .onChange(of: showsHiddenFiles) { _, _ in applyOptions() }
            .onChange(of: hidesOtherFiles) { _, _ in applyOptions() }
            .onChange(of: marksBrokenLinks) { _, _ in applyOptions() }
            .onChange(of: session.hasModifiedTabs) { _, modified in session.window?.isDocumentEdited = modified }
    }

    private var currentExport: (@MainActor () -> Void)? {
        guard let tab = session.currentTab else { return nil }
        return { exportPDF(tab) }
    }

    private func start() {
        session.start(state: FolderWindowState(encoded: savedState), showsHiddenFiles: showsHiddenFiles,
                      hidesOtherFiles: hidesOtherFiles, marksBrokenLinks: marksBrokenLinks)
        if let pending = FolderOpening.takePendingFile(for: session.reference.path) {
            session.openInitialFile(pending.url, completion: pending.completion)
        }
        if let refreshed = session.refreshedReference { onMoved(refreshed) }
    }

    private var title: String {
        session.currentTab?.name ?? session.folderName
    }

    /// « mangrove › docs · Modifié »
    private var subtitle: String {
        guard let tab = session.currentTab, let root = session.rootURL else { return "" }
        var parts = [session.folderName]
        if let relative = FolderPath.relative(tab.url.deletingLastPathComponent(), to: root), !relative.isEmpty {
            parts += relative.split(separator: "/").map(String.init)
        }
        let place = parts.joined(separator: " › ")
        return tab.isModified ? String(localized: "\(place) · Modifié") : place
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SidebarToggle(session: session)
        }
        .softToolbarItem()

        ToolbarItem(placement: .principal) {
            if let tab = session.currentTab {
                LayoutSwitcher(layout: Binding(get: { tab.model.layout }, set: { tab.model.layout = $0 }))
            }
        }
        .softToolbarItem()

        ToolbarItem(placement: .primaryAction) {
            if let tab = session.currentTab {
                SyncToggle(model: tab.model)
            }
        }
        .softToolbarItem()

        ToolbarItem(placement: .primaryAction) {
            if let tab = session.currentTab {
                FindButton(model: tab.model)
            }
        }
        .softToolbarItem()

        ToolbarItem(placement: .primaryAction) {
            if let tab = session.currentTab {
                ShareButton(fileURL: tab.url, exportPDF: { exportPDF(tab) })
            }
        }
        .softToolbarItem()
    }

    private var theme: Theme {
        library.theme(id: themeID).applyingReadingSettings(fontSize: fontSize, maxLineCharacters: maxLineCharacters)
    }

    private func applyOptions() {
        session.setOptions(showsHiddenFiles: showsHiddenFiles, hidesOtherFiles: hidesOtherFiles,
                           marksBrokenLinks: marksBrokenLinks)
    }

    private func exportPDF(_ tab: FolderTab) {
        tab.model.exportPDF(theme: theme, baseURL: tab.url.deletingLastPathComponent(), fileName: tab.name)
    }

    /// One folder per window, never a native tab of the document windows;
    /// closing asks about unsaved tabs.
    private func configure(_ window: NSWindow) {
        session.window = window
        window.tabbingMode = .disallowed
        window.isDocumentEdited = session.hasModifiedTabs
        FolderWindowDelegate.install(on: window, session: session)
    }
}

/// The window's content under the toolbar: sidebar, tabs, panes, status bar.
struct FolderLayout: View {
    let session: FolderSession
    let theme: Theme
    let sourceFontSize: Double
    let showsLineNumbers: Bool
    let showsStatusBar: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !session.isSidebarHidden {
                    FolderSidebar(session: session)
                        .frame(width: session.sidebarWidth)
                        .transition(.move(edge: .leading))
                    SidebarResizeHandle(session: session)
                }
                VStack(spacing: 0) {
                    if !session.tabs.isEmpty {
                        FolderTabStrip(session: session)
                    }
                    ZStack(alignment: .top) {
                        content
                        if session.isQuickOpenShown {
                            Color.black.opacity(0.001)
                                .onTapGesture { session.isQuickOpenShown = false }
                            QuickOpenPalette(session: session)
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if showsStatusBar, let tab = session.currentTab {
                StatusBar(model: tab.model)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: session.isSidebarHidden)
    }

    @ViewBuilder private var content: some View {
        if let tab = session.currentTab {
            EditorPanesView(model: tab.model, theme: theme, baseURL: tab.url.deletingLastPathComponent(),
                            sourceFontSize: sourceFontSize, showsLineNumbers: showsLineNumbers,
                            undoManager: tab.undoManager)
                .id(tab.id)
        } else if session.hasScanned, !session.hasDocuments {
            NoDocumentsView(session: session)
        } else if session.hasScanned {
            NoOpenFileView(session: session)
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }
}

/// The edge between the sidebar and the content: a hairline that can be
/// dragged; the width is kept per folder.
struct SidebarResizeHandle: View {
    let session: FolderSession
    @State private var startWidth: Double?

    var body: some View {
        SoftColor.hairline
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth ?? session.sidebarWidth
                                startWidth = start
                                let range = FolderMemory.sidebarWidthRange
                                session.sidebarWidth = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// The sidebar button at the left of the toolbar (⌃⌘S).
struct SidebarToggle: View {
    let session: FolderSession

    var body: some View {
        Button {
            session.isSidebarHidden.toggle()
        } label: {
            Label(session.isSidebarHidden ? "Afficher la barre latérale" : "Masquer la barre latérale",
                  systemImage: "sidebar.left")
        }
        .buttonStyle(SoftIconButtonStyle())
        .help("Afficher ou masquer la barre latérale (⌃⌘S)")
    }
}

// MARK: - Empty states

/// The folder is open, no file is (no README, or the last tab closed).
struct NoOpenFileView: View {
    let session: FolderSession

    var body: some View {
        VStack(spacing: 10) {
            SharpMark()
                .stroke(SoftColor.iconIdle.opacity(0.55), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 46, height: 46)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text("Aucun fichier ouvert")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SoftColor.label)
            Text("Choisissez un fichier dans la barre latérale, ou :")
                .font(.system(size: 12))
                .foregroundStyle(SoftColor.secondaryLabel)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                shortcut(Text("Ouvrir rapidement"), "⇧⌘O") { session.isQuickOpenShown = true }
                shortcut(Text("Nouveau fichier"), "⌘N") { session.newFile(in: session.rootURL) }
                shortcut(Text("Barre latérale"), "⌃⌘S") { session.isSidebarHidden.toggle() }
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func shortcut(_ title: Text, _ keys: String, action: @escaping () -> Void) -> some View {
        GridRow {
            Button(action: action) {
                title
                    .font(.system(size: 12))
                    .foregroundStyle(SoftColor.secondaryLabel)
            }
            .buttonStyle(.plain)
            ShortcutBadge(text: keys)
                .gridColumnAlignment(.leading)
        }
    }
}

/// The folder holds no file the Editor opens.
struct NoDocumentsView: View {
    let session: FolderSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = FileTree.fileCount(in: session.tree)
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(SoftColor.iconIdle)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text("Aucun fichier Markdown ici")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SoftColor.label)
            Text("« \(session.folderName) » contient \(count) fichiers, aucun en .md, .markdown ou .txt.")
                .font(.system(size: 12))
                .foregroundStyle(SoftColor.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                Button("Ouvrir un autre dossier…") { FolderOpening.chooseFolder(openWindow: openWindow) }
                Button("Nouveau fichier") { session.newFile(in: session.rootURL) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The folder of a restored window cannot be found any more.
struct FolderMissingView: View {
    let name: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(SoftColor.iconIdle)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            if let name {
                Text("Le dossier « \(name) » est introuvable")
                    .font(.system(size: 14, weight: .semibold))
            } else {
                Text("Aucun dossier")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Il a peut-être été déplacé, renommé ou supprimé.")
                .font(.system(size: 12))
                .foregroundStyle(SoftColor.secondaryLabel)
            Button("Ouvrir un dossier…") { FolderOpening.chooseFolder(openWindow: openWindow) }
                .padding(.top, 12)
        }
        .padding(24)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Opening folders

@MainActor
enum FolderOpening {
    static let windowID = "folder"

    /// Fichier › Ouvrir un dossier… (⌥⌘O): the standard panel, then a window
    /// for the folder, or its window if it is open already.
    static func chooseFolder(openWindow: OpenWindowAction) {
        let panel = folderPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, openWindow: openWindow)
    }

    static func folderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Ouvrir")
        panel.message = String(localized: "Choisissez le dossier à ouvrir dans l'Éditeur.")
        return panel
    }

    static func open(_ url: URL, openWindow: OpenWindowAction) {
        open(FolderReference(url: url), openWindow: openWindow)
    }

    static func open(_ reference: FolderReference, openWindow: OpenWindowAction) {
        if let session = FolderSessions.all.first(where: { $0.reference == reference }), let window = session.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: windowID, value: reference)
    }
}

// MARK: - Window

/// Hands the window a view lives in to `configure`, once it has one.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    final class AccessorView: NSView {
        var configure: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure?(window) }
        }
    }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.configure = configure
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {
        view.configure = configure
        if let window = view.window { configure(window) }
    }
}

/// Stands in front of SwiftUI's window delegate, forwarding everything to it,
/// to ask about unsaved tabs before the window closes, and to save the
/// current tab from Fichier › Enregistrer.
@MainActor
final class FolderWindowDelegate: NSObject, NSWindowDelegate, NSMenuItemValidation {
    /// Read by the forwarding methods, which AppKit calls on the main thread.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private weak var session: FolderSession?
    private var closesWithoutAsking = false

    private static var delegates: [ObjectIdentifier: FolderWindowDelegate] = [:]

    static func install(on window: NSWindow, session: FolderSession) {
        let key = ObjectIdentifier(window)
        let delegate = delegates[key] ?? FolderWindowDelegate()
        delegate.session = session
        if window.delegate !== delegate {
            delegate.original = window.delegate
            window.delegate = delegate
        }
        delegates[key] = delegate
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closesWithoutAsking {
            closesWithoutAsking = false
        } else if let session, session.hasModifiedTabs {
            Task {
                if await session.reviewUnsavedTabs() {
                    closesWithoutAsking = true
                    sender.performClose(nil)
                }
            }
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow {
            Self.delegates[ObjectIdentifier(window)] = nil
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        session?.saveCurrentTab()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveDocument(_:)) { return session?.currentTab != nil }
        return (original as? NSMenuItemValidation)?.validateMenuItem(menuItem) ?? true
    }
}
