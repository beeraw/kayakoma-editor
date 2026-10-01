import AppKit
import SwiftUI

@main
struct EditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            DocumentWindow(document: file.document, fileURL: file.fileURL)
        }
        .commands {
            EditorCommands()
            FolderCommands()
            MarkdownHelpCommands()
        }
        // The native bar at its compact height (about 40 pt).
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        // Folder windows: one per folder, restored with the system's
        // window restoration; the value keeps the folder's bookmark.
        WindowGroup(id: FolderOpening.windowID, for: FolderReference.self) { $reference in
            FolderWindow(reference: $reference)
        }
        .commandsRemoved()
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppearanceMode.applyStored()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppearanceMode.applyStored() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { FolderKeys.handle(event) }
            return handled ? nil : event
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ThemeLibrary.shared.reload()
    }

    /// Folder windows are not documents: their unsaved tabs are reviewed here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard FolderSessions.all.contains(where: \.hasModifiedTabs) else { return .terminateNow }
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: await FolderSessions.reviewAllUnsaved())
        }
        return .terminateLater
    }
}

/// Keys that mean something else in a folder window than in a document
/// window: ⌘S saves the current tab, ⌘W closes it (the window stays),
/// ⌘N creates a file in the folder. Handled before the menus, which belong to
/// the document windows.
@MainActor
enum FolderKeys {
    static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.attachedSheet == nil,
              let session = FolderSessions.all.first(where: { $0.window === window }) else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "s":
            session.saveCurrentTab()
        case "w":
            if session.isQuickOpenShown {
                session.isQuickOpenShown = false
            } else if session.currentTab != nil {
                session.closeCurrentTab()
            } else {
                return false
            }
        case "n":
            session.newFile()
        default:
            return false
        }
        return true
    }
}

/// Menu bar additions: Export as PDF in the File menu; layout, scroll sync
/// and status bar in the View menu.
struct EditorCommands: Commands {
    @FocusedValue(\.editorModel) private var model
    @FocusedValue(\.exportPDF) private var exportPDF
    @AppStorage(Preferences.showsStatusBar) private var showsStatusBar = true

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Exporter en PDF…") { exportPDF?() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(exportPDF == nil)
        }

        CommandGroup(before: .toolbar) {
            ForEach(EditorLayout.allCases) { layout in
                Toggle(isOn: Binding(get: { model?.layout == layout }, set: { if $0 { model?.layout = layout } })) {
                    Text(layout.title)
                }
                .keyboardShortcut(layout.shortcut)
                .disabled(model == nil)
            }
            Divider()
            Toggle("Synchroniser le défilement", isOn: Binding(get: { model?.syncsScrolling ?? false },
                                                               set: { model?.syncsScrolling = $0 }))
                .disabled(model == nil)
            Button(showsStatusBar ? "Masquer la barre d'état" : "Afficher la barre d'état") {
                showsStatusBar.toggle()
            }
            .keyboardShortcut("/", modifiers: [.command])
            Divider()
        }
    }
}

/// The folder mode in the menus: Ouvrir un dossier…, Ouvrir
/// rapidement…, Fermer le dossier in the File menu; the sidebar and its
/// files in the View menu; tab switching in the Window menu.
struct FolderCommands: Commands {
    @FocusedValue(\.folderSession) private var session
    @FocusedValue(\.documentFolderPane) private var documentFolderPane
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.showsHiddenFiles) private var showsHiddenFiles = false
    @AppStorage(Preferences.hidesOtherFiles) private var hidesOtherFiles = false

    /// The sidebar of a folder window, or the folder pane of a document window.
    private var sidebarShown: Bool {
        if let session { return !session.isSidebarHidden }
        return documentFolderPane?.wrappedValue ?? false
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Ouvrir un dossier…") { FolderOpening.chooseFolder(openWindow: openWindow) }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Ouvrir rapidement…") { session?.isQuickOpenShown = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(session?.rootURL == nil)
            Button("Nouveau fichier dans le dossier") { session?.newFile() }
                .disabled(session?.rootURL == nil)
            Button("Nouveau dossier") { session?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session?.rootURL == nil)
        }

        CommandGroup(before: .saveItem) {
            Button("Fermer le dossier") { session?.window?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(session == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Afficher dans le Finder") {
                if let url = session?.currentTab?.url ?? session?.rootURL { session?.revealInFinder(url) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(session?.rootURL == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(sidebarShown ? "Masquer la barre latérale" : "Afficher la barre latérale") {
                if let session {
                    session.isSidebarHidden.toggle()
                } else {
                    documentFolderPane?.wrappedValue.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(session == nil && documentFolderPane == nil)
            Button("Filtrer les fichiers") {
                session?.isSidebarHidden = false
                session?.filterFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(session == nil)
            Toggle("Afficher les fichiers cachés", isOn: $showsHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Masquer les autres fichiers", isOn: $hidesOtherFiles)
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Button("Afficher l'onglet suivant") { session?.selectNeighbour(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((session?.tabs.items.count ?? 0) < 2)
            Button("Afficher l'onglet précédent") { session?.selectNeighbour(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((session?.tabs.items.count ?? 0) < 2)
        }
    }
}
