import AppKit
import KayakomaKit
import SwiftUI
import XCTest

/// Renders the main views offscreen into PNG files, to check the rendering
/// by eye. Runs only when `SNAPSHOT_DIR` is set (pass
/// `TEST_RUNNER_SNAPSHOT_DIR` to `xcodebuild test`).
@MainActor
final class SnapshotTests: XCTestCase {
    static let sample = """
    # Mangrove

    > Carnet de terrain en Markdown, rangé par marée et par station.

    Mangrove range les relevés de terrain écrits en **Markdown** dans une arborescence datée, \
    et produit un index consultable *hors ligne*.
    Voir le [guide des stations](docs/stations.md).

    ## Installation

    ```sh
    $ brew install mangrove
    $ mangrove init ~/Releves
    ```

    ## Utilisation

    - `mangrove ajoute` crée la fiche du jour à partir du modèle ;
    - `mangrove range` déplace les fiches dans `AAAA/MM/` ;
    - `mangrove index` reconstruit le sommaire.

    ## Options

    | Option      | Par défaut | Rôle                   |
    |-------------|------------|------------------------|
    | `--station` | aucune     | Filtre sur une station |
    | `--depuis`  | 30 jours   | Période couverte       |
    | `--format`  | `md`       | `md` ou `pdf`          |

    ## Feuille de route

    - [x] Import des relevés CSV
    - [x] Export PDF
    - [ ] Photos géolocalisées

    """

    private var outputDirectory: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else {
            throw XCTSkip("SNAPSHOT_DIR is not set")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "app.kayakoma.editor.snapshots")
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: "app.kayakoma.editor.snapshots")
    }

    private func sampleFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mangrove", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "README.md")
        try Self.sample.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEditorWindow() throws {
        let url = try sampleFile()
        for dark in [false, true] {
            let document = MarkdownDocument(text: Self.sample)
            let view = DocumentWindow(document: document, fileURL: url).defaultAppStorage(defaults)
            try snapshotWindow(view, size: CGSize(width: 1180, height: 760), dark: dark,
                               name: "editor-\(dark ? "dark" : "light")") { window in
                self.placeCaret(in: window, line: 19, column: 34)
            }
        }
    }

    /// A file opened alone, with the folder pane shown.
    func testEditorFolderPane() throws {
        let url = try sampleFile()
        for dark in [false, true] {
            let document = MarkdownDocument(text: Self.sample)
            let view = DocumentWindow(document: document, fileURL: url, showsFolderPane: true).defaultAppStorage(defaults)
            try snapshotWindow(view, size: CGSize(width: 1180, height: 640), dark: dark,
                               name: "editor-folder-pane-\(dark ? "dark" : "light")") { _ in }
        }
        let view = DocumentWindow(document: MarkdownDocument(text: Self.sample), fileURL: nil, showsFolderPane: true)
            .defaultAppStorage(defaults)
        try snapshotWindow(view, size: CGSize(width: 1000, height: 480), dark: false, name: "editor-folder-pane-untitled") { _ in }
    }

    func testLayouts() throws {
        let url = try sampleFile()
        for layout in [EditorLayout.source, .preview] {
            let document = MarkdownDocument(text: Self.sample)
            let view = DocumentWindow(document: document, fileURL: url).defaultAppStorage(defaults)
            try snapshotWindow(view, size: CGSize(width: 1000, height: 520), dark: false, name: "editor-\(layout.rawValue)") { window in
                self.placeCaret(in: window, line: 19, column: 34)
                self.panes(in: window)?.layout = layout
            }
        }
    }

    func testHiddenLineNumbersAndLegacyEncoding() throws {
        defaults.set(false, forKey: Preferences.showsLineNumbers)
        let document = MarkdownDocument(text: "")
        document.replaceContent(DecodedText(text: "# Notes\n\nCaf\u{E9} et cr\u{E8}me.\n", encoding: .windows1252, lineEnding: .crlf))
        document.text = "# Notes\n\nCaf\u{E9} et cr\u{E8}me 🌊.\n"
        let view = DocumentWindow(document: document, fileURL: nil).defaultAppStorage(defaults)
        try snapshotWindow(view, size: CGSize(width: 900, height: 360), dark: false, name: "editor-no-numbers-cp1252") { _ in }
    }

    func testSettings() throws {
        for dark in [false, true] {
            try snapshotView(SettingsView().defaultAppStorage(defaults), dark: dark, name: "settings-\(dark ? "dark" : "light")")
        }
    }

    /// The soft controls of the sheet C5, in every appearance.
    func testSoftControlsSheet() throws {
        for (appearance, name) in Self.appearances {
            try snapshotView(SoftControlsSheet(), appearance: appearance, name: "soft-controls-\(name)")
        }
    }

    /// The toolbar's contents and the status bar as a strip: a window's
    /// toolbar is not drawn offscreen.
    func testToolbarStrip() throws {
        let url = try sampleFile()
        for (appearance, name) in Self.appearances {
            for syncs in [true, false] {
                let model = EditorModel(document: MarkdownDocument(text: Self.sample), syncsScrolling: syncs)
                try snapshotView(EditorToolbarStrip(model: model, fileURL: url), appearance: appearance,
                                 name: "editor-toolbar-\(name)\(syncs ? "" : "-nosync")")
            }
        }
    }

    /// Increase Contrast cannot be simulated offscreen: its appearances only
    /// serve for matching and cannot be created.
    static let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]

    // MARK: - Helpers

    private func panes(in window: NSWindow) -> EditorPanes? {
        guard let source = find(SourceTextView.self, in: window.contentView!) else { return nil }
        return source.delegate as? EditorPanes
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private func placeCaret(in window: NSWindow, line: Int, column: Int) {
        guard let panes = panes(in: window) else { return XCTFail("no source view") }
        let start = panes.highlighter.lines.starts[line - 1]
        window.makeFirstResponder(panes.sourceView)
        panes.sourceView.setSelectedRange(NSRange(location: start + column - 1, length: 0))
    }

    /// Renders a view in a titled window, frame included.
    private func snapshotWindow<V: View>(_ view: V, size: CGSize, dark: Bool, name: String,
                                         prepare: @escaping (NSWindow) -> Void) throws {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "README.md"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        settle(window)
        prepare(window)
        settle(window)
        let frameView = window.contentView?.superview ?? window.contentView!
        try write(frameView, appearance: window.appearance!, name: name)
        window.close()
    }

    /// Renders a view at its own size.
    private func snapshotView<V: View>(_ view: V, dark: Bool, name: String) throws {
        try snapshotView(view, appearance: dark ? .darkAqua : .aqua, name: name)
    }

    private func snapshotView<V: View>(_ view: V, appearance: NSAppearance.Name, name: String) throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = hosting.appearance
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        settle(window)
        try write(hosting, appearance: hosting.appearance!, name: name)
        window.close()
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
    }

    private func write(_ view: NSView, appearance: NSAppearance, name: String) throws {
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        let png = try XCTUnwrap(data)
        try png.write(to: outputDirectory.appending(path: name + ".png"))
    }
}

/// The Editor's toolbar contents laid out as in the document window (title, layout selector
/// in the middle, tools on the right), with the status bar under them.
private struct EditorToolbarStrip: View {
    let model: EditorModel
    let fileURL: URL
    @State private var layout = EditorLayout.split

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Text(verbatim: "README.md").font(.system(size: 12.5, weight: .semibold))
                        Text(verbatim: "Enregistré").font(.system(size: 11)).foregroundStyle(SoftColor.secondaryLabel)
                    }
                    .padding(.leading, 80)
                    Spacer()
                    SyncToggle(model: model)
                    FindButton(model: model)
                    ShareButton(fileURL: fileURL, exportPDF: {})
                }
                LayoutSwitcher(layout: $layout)
            }
            .padding(.horizontal, 10)
            .frame(width: 1000, height: 40)
            Color(nsColor: .textBackgroundColor).frame(height: 60)
            StatusBar(model: model)
        }
        .frame(width: 1000)
    }
}

// MARK: - Folder mode

extension SnapshotTests {
    static let stations = """
    # Guide des stations

    > Six stations, de l'embouchure à l'arrière-mangrove.

    Chaque station porte un code (`S1` à `S6`) repris dans le nom des fiches. Retour au [README](../README.md).

    ## Accès

    | Station         | Accès    | Marée conseillée |
    |-----------------|----------|------------------|
    | `S1` Embouchure | pirogue  | basse            |
    | `S2` Chenal     | à pied   | mi-marée         |
    | `S3` Vasière    | ponton   | haute            |

    ## Protocole

    Suivre le [protocole de relevé](protocole.md) et consulter le [calendrier des marées](marees.md) avant de partir.

    ## Matériel

    - sonde de salinité ;
    - carnet étanche ;
    - GPS de poche.

    """

    /// An invented notebook used by the folder window snapshots.
    private func mangroveFolder(name: String = "mangrove") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "kayakoma-snapshots-\(UUID().uuidString)")
        let root = base.appending(path: name, directoryHint: .isDirectory)
        let files: [String: String] = [
            "README.md": Self.sample,
            "CHANGELOG.md": "# Journal\n\n## 0.3\n\n- Export PDF.\n",
            "LICENSE": "MIT\n",
            "logo.png": "png",
            "releves.csv": "station;salinite\n",
            "docs/images/carte-stations.png": "png",
            "docs/images/vasiere.jpg": "jpg",
            "docs/glossaire.md": "# Glossaire\n",
            "docs/protocole.md": "# Protocole de relevé\n",
            "docs/sorties-terrain-avril.md": "# Sorties d'avril\n",
            "docs/stations.md": Self.stations,
            "modeles/fiche-du-jour.md": "# Fiche du jour\n",
            "modeles/station-type.md": "# Station type\n",
            "releves/2026/09/2026-09-28.md": "# 28 septembre\n",
            "releves/2026/09/2026-09-30.md": "# 30 septembre\n",
            "releves/2026/10/2026-10-01.md": "# 1er octobre\n",
            ".git/HEAD": "ref\n",
            // Long names: one line each, truncated in the middle.
            "campagne-de-mesures-saison-des-pluies-preparation/notes.md": "# Notes\n",
            "docs/sorties-terrain-avril-mai-juin-comparaison-des-stations.md": "# Sorties\n",
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return URL(filePath: String(cString: realpath(root.path, nil)), directoryHint: .isDirectory)
    }

    private func photosFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "kayakoma-snapshots-\(UUID().uuidString)")
            .appending(path: "photos-terrain", directoryHint: .isDirectory)
        for path in ["2026-09/IMG_0398.jpg", "2026-09/IMG_0399.jpg", "2026-09/IMG_0412.jpg", "carte-stations.pdf",
                     "releves-bruts.csv", "sonde-export.xlsx"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return URL(filePath: String(cString: realpath(root.path, nil)), directoryHint: .isDirectory)
    }

    private func startSession(_ root: URL, state: FolderWindowState?, recents: [String] = []) throws -> FolderSession {
        let memory = FolderMemory(defaults: defaults)
        for path in recents.reversed() { memory.noteRecentFile(path, for: root.canonicalFile.path) }
        let session = FolderSession(reference: FolderReference(url: root), memory: memory)
        session.start(state: state, showsHiddenFiles: false, hidesOtherFiles: false, marksBrokenLinks: true)
        let deadline = Date().addingTimeInterval(5)
        while !session.hasScanned, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(session.hasScanned)
        return session
    }

    private func folderState(current: String) -> FolderWindowState {
        FolderWindowState(tabs: ["README.md", "docs/stations.md", "CHANGELOG.md"], current: current,
                          expanded: ["docs", "releves", "releves/2026"])
    }

    /// Tree, tabs (README modified), panes, status bar.
    func testFolderWindow() throws {
        let root = try mangroveFolder()
        for dark in [false, true] {
            let session = try startSession(root, state: folderState(current: "README.md"))
            let view = FolderSnapshotWindow(session: session).defaultAppStorage(defaults)
            try snapshotWindow(view, size: CGSize(width: 1180, height: 720), dark: dark,
                               name: "folder-window-\(dark ? "dark" : "light")") { window in
                guard let tab = session.currentTab else { return XCTFail("no tab") }
                let source = tab.model.panes.sourceView
                window.makeFirstResponder(source)
                let start = tab.model.panes.highlighter.lines.starts[18]
                source.setSelectedRange(NSRange(location: start + 33, length: 0))
                source.insertText("s", replacementRange: NSRange(location: start + 33, length: 0))
            }
            session.stop()
        }
    }

    /// The link to a missing file, dashed in the preview and dotted in the source.
    func testFolderBrokenLink() throws {
        let root = try mangroveFolder()
        let session = try startSession(root, state: folderState(current: "docs/stations.md"))
        let view = FolderSnapshotWindow(session: session).defaultAppStorage(defaults)
        try snapshotWindow(view, size: CGSize(width: 1180, height: 640), dark: false, name: "folder-broken-link") { _ in
            session.currentTab?.model.panes.scrollSource(toLine: 10)
        }
        session.stop()
    }

    /// The palette, empty (recent files first) and with « sta ».
    func testFolderQuickOpen() throws {
        let root = try mangroveFolder()
        for (query, dark) in [("", false), ("sta", false), ("sta", true)] {
            let session = try startSession(root, state: folderState(current: "README.md"),
                                           recents: ["docs/stations.md", "releves/2026/10/2026-10-01.md", "CHANGELOG.md",
                                                     "docs/protocole.md"])
            session.isQuickOpenShown = query.isEmpty
            let view = FolderSnapshotWindow(session: session, paletteQuery: query).defaultAppStorage(defaults)
            let name = "folder-quick-open-\(query.isEmpty ? "recents" : query)-\(dark ? "dark" : "light")"
            try snapshotWindow(view, size: CGSize(width: 1180, height: 620), dark: dark, name: name) { _ in }
            session.stop()
        }
    }

    /// No open file, and no Markdown file at all.
    func testFolderEmptyStates() throws {
        let root = try mangroveFolder()
        for dark in [false, true] {
            let session = try startSession(root, state: FolderWindowState(tabs: [], expanded: ["docs"]))
            for tab in session.tabs.items { session.close(tab) }
            let view = FolderSnapshotWindow(session: session).defaultAppStorage(defaults)
            try snapshotWindow(view, size: CGSize(width: 900, height: 520), dark: dark,
                               name: "folder-empty-no-file-\(dark ? "dark" : "light")") { _ in }
            session.stop()
        }
        let photos = try photosFolder()
        let session = try startSession(photos, state: FolderWindowState(expanded: ["2026-09"]))
        let view = FolderSnapshotWindow(session: session).defaultAppStorage(defaults)
        try snapshotWindow(view, size: CGSize(width: 900, height: 520), dark: false, name: "folder-empty-no-markdown") { _ in }
        session.stop()
    }

    /// Drag and drop: the folder a drag would drop into, then the whole
    /// list for the top of the folder.
    func testFolderDropTargets() throws {
        let root = try mangroveFolder()
        for (target, dark) in [("modeles", false), ("modeles", true), ("", false)] {
            let session = try startSession(root, state: folderState(current: "README.md"))
            let view = FolderSnapshotWindow(session: session).defaultAppStorage(defaults)
            let name = "folder-drop-\(target.isEmpty ? "root" : target)-\(dark ? "dark" : "light")"
            try snapshotWindow(view, size: CGSize(width: 900, height: 520), dark: dark, name: name) { window in
                guard let content = window.contentView,
                      let outline = self.find(SidebarOutlineView.self, in: content) else { return XCTFail("no sidebar") }
                let folder = target.isEmpty ? session.rootURL : session.rootURL?.appending(path: target).canonicalFile
                outline.coordinator?.setDropTarget(folder)
            }
            session.stop()
        }
    }

    /// The folder pane of a document window while a folder hovers it.
    func testDocumentPaneDropHighlight() throws {
        let url = try sampleFile()
        for dark in [false, true] {
            let view = HStack(spacing: 0) {
                DocumentFolderPane(fileURL: url, onHandedOver: {})
                    .overlay { FolderDropHighlight(drop: .folder(url.deletingLastPathComponent())) }
                    .frame(width: DocumentFolderPane.width)
                SoftColor.hairline.frame(width: 1)
                Color(nsColor: .textBackgroundColor).frame(width: 200)
            }
            .frame(height: 380)
            .environment(\.softAccent, .coral)
            try snapshotView(view, dark: dark, name: "editor-folder-pane-drop-\(dark ? "dark" : "light")")
        }
    }

    /// The filter keeps the hierarchy and underlines what it found.
    func testFolderFilter() throws {
        let root = try mangroveFolder()
        let session = try startSession(root, state: folderState(current: "README.md"))
        session.filter = "2026-09"
        let view = FolderSnapshotWindow(session: session).defaultAppStorage(defaults)
        try snapshotWindow(view, size: CGSize(width: 900, height: 480), dark: false, name: "folder-filter") { _ in }
        session.stop()
    }
}

/// The folder window as drawn offscreen: the toolbar's contents as a strip
/// (a window's toolbar is not drawn offscreen), then the real layout.
private struct FolderSnapshotWindow: View {
    let session: FolderSession
    var paletteQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    SidebarToggle(session: session)
                        .padding(.leading, 72)
                    HStack(spacing: 7) {
                        Text(verbatim: session.currentTab?.name ?? session.folderName)
                            .font(.system(size: 12.5, weight: .semibold))
                        if let tab = session.currentTab {
                            Text(verbatim: "\(session.folderName)\(tab.isModified ? " · Modifié" : "")")
                                .font(.system(size: 11))
                                .foregroundStyle(SoftColor.secondaryLabel)
                        }
                    }
                    Spacer()
                    if let tab = session.currentTab {
                        SyncToggle(model: tab.model)
                        FindButton(model: tab.model)
                        ShareButton(fileURL: tab.url, exportPDF: {})
                    }
                }
                if let tab = session.currentTab {
                    LayoutSwitcher(layout: .constant(tab.model.layout))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(SoftColor.chrome)
            .overlay(alignment: .bottom) { SoftColor.hairline.frame(height: 1) }
            FolderLayout(session: session, theme: ThemeLibrary.shared.theme(id: ThemeLibrary.defaultID),
                         sourceFontSize: 13, showsLineNumbers: true, showsStatusBar: true)
                .overlay(alignment: .top) {
                    // The palette with a query typed in (the window's own starts empty).
                    if !paletteQuery.isEmpty {
                        QuickOpenPalette(session: session, query: paletteQuery)
                            .padding(.horizontal, 24)
                            .padding(.top, 12 + (session.tabs.isEmpty ? 0 : FolderTabStrip.height))
                            .padding(.leading, session.isSidebarHidden ? 0 : session.sidebarWidth)
                    }
                }
        }
        .environment(\.softAccent, .coral)
    }
}
