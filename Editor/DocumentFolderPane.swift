import AppKit
import SwiftUI

/// The pure part of handing a file over to a folder window.
enum FolderHandoff {
    /// The folder that holds `file`, by its real path (/private/var…), as
    /// open panels and bookmarks give it.
    static func enclosingFolder(of file: URL) -> URL {
        URL(filePath: realPath(file.deletingLastPathComponent()), directoryHint: .isDirectory)
    }

    /// Path of `file` from `folder` (« docs/stations.md »), the tab to open
    /// in the folder window; `nil` when the file is not inside the folder,
    /// or is the folder itself.
    static func relativePath(of file: URL, in folder: URL) -> String? {
        let relative = FolderPath.relative(file, to: folder)
            ?? FolderPath.relative(URL(filePath: realPath(file)), to: URL(filePath: realPath(folder)))
        guard let relative, !relative.isEmpty else { return nil }
        return relative
    }

    /// `path` with the home folder written « ~ »; `home` is the user's real
    /// home, not the sandbox container.
    static func abbreviatedPath(_ path: String, home: String = realHome) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The user's home folder; `NSHomeDirectory()` is the sandbox container.
    static var realHome: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }

    /// What a drop on the folder pane does.
    enum PaneDrop: Equatable {
        /// One folder: it opens in a folder window, like « Choisir un autre dossier… ».
        case folder(URL)
        /// One Markdown or text file: it opens in a document window, as a
        /// drop on the Dock icon would.
        case document(URL)
    }

    /// The pane takes a single folder, or a single file the Editor opens;
    /// anything else is refused.
    static func paneDrop(for urls: [URL]) -> PaneDrop? {
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true {
            return values?.isPackage == true ? nil : .folder(url)
        }
        return FileKind(url: url, isDirectory: false).opensInEditor ? .document(url) : nil
    }

    /// The path with its symbolic links resolved, or as it is when it does
    /// not exist.
    static func realPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Opening the folder of a document

extension FolderOpening {
    /// Files waiting for their folder window to start, by folder path.
    private static var pendingFiles: [String: (url: URL, completion: (Bool) -> Void)] = [:]

    /// The file a folder window opening for `path` must show first.
    static func takePendingFile(for path: String) -> (url: URL, completion: (Bool) -> Void)? {
        pendingFiles.removeValue(forKey: path)
    }

    /// « Ouvrir le dossier « … » »: the window of the folder holding `file`,
    /// with the file in a tab. Opens it directly when its window is open or
    /// its bookmark still gives access; otherwise the open panel shows the
    /// folder, which the user only has to confirm (the sandbox only granted
    /// the file). `completion` tells whether the file got its tab.
    static func openEnclosingFolder(of file: URL, openWindow: OpenWindowAction, completion: @escaping (Bool) -> Void) {
        let folder = FolderHandoff.enclosingFolder(of: file)
        // References keep the standardized path (see `FolderReference(url:)`).
        let path = folder.standardizedFileURL.path
        if FolderSessions.all.contains(where: { $0.reference.path == path }) {
            return open(FolderReference(path: path, bookmark: nil), file: file, openWindow: openWindow, completion: completion)
        }
        if let stored = FolderMemory().reference(forPath: path), grantsAccess(stored) {
            return open(stored, file: file, openWindow: openWindow, completion: completion)
        }
        chooseFolder(startingAt: folder, file: file, openWindow: openWindow, completion: completion)
    }

    /// « Choisir un autre dossier… »: Fichier › Ouvrir un dossier…; the file
    /// gets a tab when it is inside the chosen folder.
    static func chooseFolder(startingAt folder: URL?, file: URL?, openWindow: OpenWindowAction,
                             completion: @escaping (Bool) -> Void) {
        let panel = folderPanel()
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return completion(false) }
        open(FolderReference(url: url), file: file, openWindow: openWindow, completion: completion)
    }

    /// Brings the folder's window forward, or opens one, then hands it the file.
    static func open(_ reference: FolderReference, file: URL?, openWindow: OpenWindowAction,
                     completion: @escaping (Bool) -> Void) {
        guard let file, FolderHandoff.relativePath(of: file, in: reference.url) != nil else {
            open(reference, openWindow: openWindow)
            return completion(false)
        }
        if let session = FolderSessions.all.first(where: { $0.reference == reference }), let window = session.window {
            window.makeKeyAndOrderFront(nil)
            session.openInitialFile(file, completion: completion)
            return
        }
        pendingFiles[reference.path] = (file, completion)
        openWindow(id: windowID, value: reference)
    }

    /// A folder dropped from the Finder: the drop's sandbox extension lets
    /// the app make its bookmark at once. When that does not give write
    /// access, the open panel shows the folder, which the user only has to
    /// confirm.
    static func openDroppedFolder(_ folder: URL, file: URL?, openWindow: OpenWindowAction,
                                  completion: @escaping (Bool) -> Void) {
        let path = folder.standardizedFileURL.path
        if FolderSessions.all.contains(where: { $0.reference.path == path }) {
            return open(FolderReference(path: path, bookmark: nil), file: file, openWindow: openWindow, completion: completion)
        }
        guard let reference = FolderReference(droppedURL: folder) else {
            return chooseFolder(startingAt: folder, file: file, openWindow: openWindow, completion: completion)
        }
        open(reference, file: file, openWindow: openWindow, completion: completion)
    }

    /// Whether a stored bookmark still opens its folder, where it was.
    private static func grantsAccess(_ reference: FolderReference) -> Bool {
        guard let resolution = reference.resolve(), resolution.isSecurityScoped,
              resolution.url.path(percentEncoded: false) == reference.path else { return false }
        guard resolution.url.startAccessingSecurityScopedResource() else { return false }
        resolution.url.stopAccessingSecurityScopedResource()
        return true
    }
}

// MARK: - The pane

/// The left pane of a document window: an invitation to open the file's
/// folder in a folder window, the file in one of its tabs.
struct DocumentFolderPane: View {
    let fileURL: URL?
    /// Called when the file got its tab in a folder window.
    let onHandedOver: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What a drag hovering the pane would do.
    @State private var hoveringDrop: FolderHandoff.PaneDrop?

    static var width: Double { FolderMemory.defaultSidebarWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fileURL {
                folderContent(FolderHandoff.enclosingFolder(of: fileURL), file: fileURL)
            } else {
                untitledContent
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: FolderColor.sidebar))
        .overlay {
            if let hoveringDrop {
                FolderDropHighlight(drop: hoveringDrop)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveringDrop)
        .onDrop(of: [.fileURL], delegate: PaneDropDelegate(hovering: $hoveringDrop, perform: performDrop))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dossier du document"))
        .accessibilityHint(Text("Déposez un dossier ici pour l'ouvrir."))
    }

    private func performDrop(_ drop: FolderHandoff.PaneDrop) {
        switch drop {
        case .folder(let folder):
            FolderOpening.openDroppedFolder(folder, file: fileURL, openWindow: openWindow, completion: handOver)
        case .document(let url):
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// Laid out like the folder sidebar: its header row, then the actions, all
    /// aligned on the leading edge.
    private func folderContent(_ folder: URL, file: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(folder.lastPathComponent)
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: FolderHandoff.abbreviatedPath(folder.path))
                    .font(.system(size: 11))
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: folder.path))
                Button {
                    FolderOpening.openEnclosingFolder(of: file, openWindow: openWindow, completion: handOver)
                } label: {
                    Label("Ouvrir ce dossier", systemImage: "folder")
                }
                .buttonStyle(SoftTintedButtonStyle(accent: .coral))
                .help("Ouvrir ce dossier dans une fenêtre de dossier, avec ce fichier en onglet")
                .padding(.top, 2)
                otherFolderButton(Text("Choisir un autre dossier…"), file: file)
                Text("Le fichier s'ouvrira dans un onglet du dossier.")
                    .font(.system(size: 11))
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
        }
    }

    private var untitledContent: some View {
        otherFolderButton(Text("Ouvrir un dossier…"), file: nil)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 12)
    }

    /// The folder sidebar's header row: icon and name, 32 pt high.
    private func header(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SoftColor.iconIdle)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(SoftColor.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
    }

    /// The quiet, link-like button under the main one.
    private func otherFolderButton(_ title: Text, file: URL?) -> some View {
        Button {
            FolderOpening.chooseFolder(startingAt: nil, file: file, openWindow: openWindow, completion: handOver)
        } label: {
            title
                .font(.system(size: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietLinkButtonStyle())
    }

    private func handOver(_ opened: Bool) {
        if opened { onHandedOver() }
    }
}

/// Secondary text that darkens and underlines on hover, like a link.
private struct QuietLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLinkBody(configuration: configuration)
    }
}

private struct QuietLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovered ? SoftColor.label : SoftColor.secondaryLabel)
            .underline(isHovered)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovered = $0 }
    }
}

/// The sidebar button of a document window (⌃⌘S): shows the folder pane.
struct DocumentSidebarToggle: View {
    @Binding var isShown: Bool

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Label(isShown ? "Masquer la barre latérale" : "Afficher la barre latérale", systemImage: "sidebar.left")
        }
        .buttonStyle(SoftIconButtonStyle())
        .help("Afficher ou masquer la barre latérale (⌃⌘S)")
    }
}

private struct DocumentFolderPaneKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// Whether the key document window shows its folder pane, for ⌃⌘S.
    var documentFolderPane: Binding<Bool>? {
        get { self[DocumentFolderPaneKey.self] }
        set { self[DocumentFolderPaneKey.self] = newValue }
    }
}

// MARK: - Drop

/// Reads the drag's file URLs straight from the drag pasteboard, so that the
/// pane can tell a folder from a file while it hovers; reading them also
/// takes the drop's sandbox extension.
private struct PaneDropDelegate: DropDelegate {
    @Binding var hovering: FolderHandoff.PaneDrop?
    let perform: (FolderHandoff.PaneDrop) -> Void

    private var drop: FolderHandoff.PaneDrop? {
        let objects = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true])
        return FolderHandoff.paneDrop(for: objects as? [URL] ?? [])
    }

    func validateDrop(info: DropInfo) -> Bool { drop != nil }

    func dropEntered(info: DropInfo) {
        hovering = drop
        guard let hovering else { return }
        AccessibilityNotification.Announcement(FolderDropHighlight.title(for: hovering)).post()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drop == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) { hovering = nil }

    func performDrop(info: DropInfo) -> Bool {
        hovering = nil
        guard let drop else { return false }
        // After the drag returns: opening may show the open panel.
        DispatchQueue.main.async { perform(drop) }
        return true
    }
}

/// The pane while a folder (or a document) hovers it: a soft coral dashed
/// outline and what the drop will do.
struct FolderDropHighlight: View {
    let drop: FolderHandoff.PaneDrop

    static func title(for drop: FolderHandoff.PaneDrop) -> String {
        switch drop {
        case .folder: String(localized: "Déposer pour ouvrir le dossier")
        case .document: String(localized: "Déposer pour ouvrir le document")
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 8) {
            Image(systemName: isFolder ? "folder" : "doc.text")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(SoftAccent.coral.icon)
            Text(verbatim: Self.title(for: drop))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SoftAccent.coral.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            shape.fill(Color(nsColor: FolderColor.sidebar).opacity(0.9))
            shape.fill(SoftAccent.coral.tint.opacity(0.7))
        }
        .overlay {
            shape.strokeBorder(Color(nsColor: FolderColor.dropStroke), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isFolder: Bool {
        if case .folder = drop { return true }
        return false
    }
}
