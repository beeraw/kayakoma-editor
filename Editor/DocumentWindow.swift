import AppKit
import KayakomaKit
import SwiftUI

private struct EditorModelKey: FocusedValueKey {
    typealias Value = EditorModel
}

extension FocusedValues {
    /// The model of the key window, for the menu bar.
    var editorModel: EditorModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }
}

extension EditorLayout {
    var title: LocalizedStringKey {
        switch self {
        case .source: "Source seule"
        case .split: "Côte à côte"
        case .preview: "Rendu seul"
        }
    }

    var symbol: String {
        switch self {
        case .source: "doc.plaintext"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .source: "1"
        case .split: "2"
        case .preview: "3"
        }
    }
}

/// A document window: source and preview side by side, the
/// layout selector in the middle of the toolbar, and the status bar.
struct DocumentWindow: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @State private var model: EditorModel
    @State private var watcher: FileWatcher?
    @SceneStorage("layout") private var layout = EditorLayout.split
    /// The folder pane, hidden until asked for; kept per window.
    @SceneStorage("folderPaneShown") private var showsFolderPane = false
    @State private var window = WeakWindow()
    @State private var showsCheatSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(Preferences.themeID) private var themeID = ThemeLibrary.defaultID
    @AppStorage(Preferences.fontSize) private var fontSize = Preferences.defaultFontSize
    @AppStorage(Preferences.maxLineCharacters) private var maxLineCharacters = Preferences.defaultMaxLineCharacters
    @AppStorage(Preferences.sourceFontSize) private var sourceFontSize = Preferences.defaultSourceFontSize
    @AppStorage(Preferences.showsLineNumbers) private var showsLineNumbers = true
    @AppStorage(Preferences.showsStatusBar) private var showsStatusBar = true
    @AppStorage(Preferences.opensInTabs) private var opensInTabs = true
    @Environment(\.undoManager) private var undoManager

    private let library = ThemeLibrary.shared

    init(document: MarkdownDocument, fileURL: URL?, showsFolderPane: Bool = false) {
        self.document = document
        self.fileURL = fileURL
        _showsFolderPane = SceneStorage(wrappedValue: showsFolderPane, "folderPaneShown")
        _model = State(initialValue: EditorModel(document: document, syncsScrolling: UserDefaults.standard.syncsScrollingByDefault))
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsFolderPane {
                DocumentFolderPane(fileURL: fileURL, onHandedOver: closeIfSaved)
                    .frame(width: DocumentFolderPane.width)
                    .transition(.move(edge: .leading))
                SoftColor.hairline
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                EditorPanesView(model: model, theme: theme, baseURL: baseURL, sourceFontSize: sourceFontSize,
                                showsLineNumbers: showsLineNumbers, undoManager: undoManager)
                if showsStatusBar {
                    StatusBar(model: model)
                }
            }
            .frame(minWidth: 560)
        }
        .frame(minHeight: 320)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showsFolderPane)
        .background(WindowTabbingConfigurator(opensInTabs: opensInTabs))
        .background(WindowSizer())
        .background(WindowAccessor { [window] in window.window = $0 })
        .toolbar { toolbar }
        .onAppear { model.restoreLayout(layout) }
        .onChange(of: layout) { _, layout in model.layout = layout }
        .onChange(of: model.layout) { _, newLayout in if layout != newLayout { layout = newLayout } }
        .onChange(of: ObjectIdentifier(document)) { _, _ in model.adopt(document) }
        .task(id: fileURL) { startWatching() }
        .onDisappear { watcher?.stop() }
        .focusedSceneValue(\.editorModel, model)
        .focusedSceneValue(\.exportPDF, exportPDF)
        .focusedSceneValue(\.documentFolderPane, $showsFolderPane)
        .focusedSceneValue(\.showMarkdownCheatSheet, { showsCheatSheet = true })
        .sheet(isPresented: $showsCheatSheet) {
            EditorCheatSheet(model: model, theme: theme, isPresented: $showsCheatSheet)
        }
    }

    /// The native toolbar, with soft controls that draw themselves.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DocumentSidebarToggle(isShown: $showsFolderPane)
        }
        .softToolbarItem()

        ToolbarItem(placement: .principal) {
            LayoutSwitcher(layout: $layout)
        }
        .softToolbarItem()

        ToolbarItem(placement: .primaryAction) {
            SyncToggle(model: model)
        }
        .softToolbarItem()

        ToolbarItem(placement: .primaryAction) {
            FindButton(model: model)
        }
        .softToolbarItem()

        ToolbarItem(placement: .primaryAction) {
            ShareButton(fileURL: fileURL, exportPDF: exportPDF)
        }
        .softToolbarItem()
    }

    // MARK: - State

    private var theme: Theme {
        library.theme(id: themeID)
            .applyingReadingSettings(fontSize: fontSize, maxLineCharacters: maxLineCharacters)
    }

    private var baseURL: URL? { fileURL?.deletingLastPathComponent() }

    private var fileName: String {
        fileURL?.lastPathComponent ?? String(localized: "Sans titre")
    }

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard let fileURL else { return }
        let model = model
        watcher = FileWatcher(url: fileURL) { model.fileDidChange(at: fileURL) }
    }

    private func exportPDF() {
        model.exportPDF(theme: theme, baseURL: baseURL, fileName: fileName)
    }

    /// The file now has its tab in a folder window: this window goes away,
    /// unless it holds unsaved changes.
    private func closeIfSaved() {
        guard let window = window.window else { return }
        let edited = NSDocumentController.shared.document(for: window)?.isDocumentEdited ?? window.isDocumentEdited
        if !edited { window.performClose(nil) }
    }
}

/// The window a view lives in, kept without retaining it.
@MainActor
final class WeakWindow {
    weak var window: NSWindow?
}

private struct ExportPDFKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var exportPDF: (@MainActor () -> Void)? {
        get { self[ExportPDFKey.self] }
        set { self[ExportPDFKey.self] = newValue }
    }
}

/// Hosts the window's AppKit panes and passes the settings down to them.
struct EditorPanesView: NSViewRepresentable {
    let model: EditorModel
    let theme: Theme
    let baseURL: URL?
    let sourceFontSize: Double
    let showsLineNumbers: Bool
    let undoManager: UndoManager?

    func makeNSView(context: Context) -> NSView {
        let panes = model.panes
        apply(to: panes)
        return panes.rootView
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: model.panes)
    }

    private func apply(to panes: EditorPanes) {
        panes.undoManager = undoManager
        model.undoManager = undoManager
        panes.sourceFontSize = CGFloat(sourceFontSize)
        panes.showsLineNumbers = showsLineNumbers
        panes.baseURL = baseURL
        panes.theme = theme
    }
}

/// The layout selector (Source · Côte à côte · Rendu), icons only; ⌘1–⌘3
/// come from the View menu.
struct LayoutSwitcher: View {
    @Binding var layout: EditorLayout

    var body: some View {
        SoftSegmentedControl(Text("Disposition"), selection: $layout,
                             segments: EditorLayout.allCases.map { SoftSegment($0, title: Text($0.title), systemImage: $0.symbol) })
            .help("Source seule, côte à côte ou rendu seul")
    }
}

/// Scroll sync as a toggle, tinted coral while on: the only coloured element
/// of the toolbar.
struct SyncToggle: View {
    @Bindable var model: EditorModel

    var body: some View {
        Toggle(isOn: $model.syncsScrolling) {
            Label("Synchroniser le défilement", systemImage: "arrow.up.arrow.down")
        }
        .toggleStyle(SoftIconToggleStyle())
        .help("Synchroniser le défilement de la source et du rendu")
    }
}

struct FindButton: View {
    let model: EditorModel

    var body: some View {
        Button {
            model.showFindBar()
        } label: {
            Label("Rechercher", systemImage: "magnifyingglass")
        }
        .buttonStyle(SoftIconButtonStyle())
        .help("Rechercher dans le document")
    }
}

struct ShareButton: View {
    let fileURL: URL?
    let exportPDF: @MainActor () -> Void

    var body: some View {
        Menu {
            if let fileURL {
                ShareLink(item: fileURL) {
                    Label("Partager…", systemImage: "square.and.arrow.up")
                }
                Divider()
            }
            Button("Exporter en PDF…", action: exportPDF)
        } label: {
            Label("Partager", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(SoftIconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Partager ou exporter en PDF")
    }
}

/// Words, characters, caret position, scroll sync and file format,
/// in the compact 22 pt bar: the accent only marks an active sync.
struct StatusBar: View {
    let model: EditorModel
    @Environment(\.softAccent) private var accent

    var body: some View {
        HStack(spacing: 14) {
            Text("\(model.statistics.words) mots")
            Text("\(model.statistics.characters) caractères")
            Text("Ligne \(model.caretLine), col. \(model.caretColumn)")
            Spacer(minLength: 8)
            Button {
                model.syncsScrolling.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9.5, weight: .medium))
                    Text(model.syncsScrolling ? "Synchro" : "Synchro coupée")
                }
                .foregroundStyle(model.syncsScrolling ? accent.text : SoftColor.secondaryLabel)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.syncsScrolling ? Text("Défilement synchronisé") : Text("Défilement indépendant"))
            .help("Synchroniser le défilement de la source et du rendu")
            formatLabel
        }
        .font(.system(size: 11))
        .foregroundStyle(SoftColor.secondaryLabel)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: SoftMetrics.statusBarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { SoftColor.hairline.frame(height: 1) }
    }

    /// « Markdown · UTF-8 · LF »; when the text no longer fits the file's
    /// encoding, the arrow says it will be saved as UTF-8.
    private var formatLabel: some View {
        HStack(spacing: 4) {
            Text(model.isPlainText ? "Texte brut" : "Markdown")
            Text(verbatim: "·")
            if model.savesAsUTF8 {
                Text(verbatim: "\(model.encoding.displayName) → UTF-8")
                    .foregroundStyle(.orange)
            } else {
                Text(verbatim: model.encoding.displayName)
            }
            Text(verbatim: "·")
            Text(verbatim: model.lineEnding.displayName)
        }
        .help(model.savesAsUTF8
              ? Text("Le texte contient des caractères que \(model.encoding.displayName) ne peut pas coder : il sera enregistré en UTF-8.")
              : Text("Encodage et fins de ligne conservés à l'enregistrement"))
    }
}
