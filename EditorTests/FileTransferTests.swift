import AppKit
import XCTest

final class FileTransferTests: XCTestCase {
    private let root = URL(filePath: "/notebook", directoryHint: .isDirectory)

    private func url(_ path: String) -> URL { root.appending(path: path).canonicalFile }

    func testMovesThatAreRefused() {
        let taken: Set<String> = ["/notebook/docs/stations.md", "/notebook/modeles/stations.md"]
        let exists: (URL) -> Bool = { taken.contains($0.standardizedFileURL.path) }
        // Into itself, or into one of its own folders.
        XCTAssertEqual(FileTransfer.checkMove(url("docs"), into: url("docs"), exists: exists), .intoItself)
        XCTAssertEqual(FileTransfer.checkMove(url("docs"), into: url("docs/images"), exists: exists), .intoItself)
        // Where it is already.
        XCTAssertEqual(FileTransfer.checkMove(url("docs/stations.md"), into: url("docs"), exists: exists), .alreadyThere)
        XCTAssertEqual(FileTransfer.checkMove(url("README.md"), into: root, exists: exists), .alreadyThere)
        // A name already taken at the destination.
        XCTAssertEqual(FileTransfer.checkMove(url("docs/stations.md"), into: url("modeles"), exists: exists),
                       .nameTaken("stations.md"))
        // A sibling whose name only starts like the folder is not inside it.
        XCTAssertNil(FileTransfer.checkMove(url("docs"), into: url("docs-old"), exists: exists))
        XCTAssertNil(FileTransfer.checkMove(url("docs/stations.md"), into: root, exists: exists))
    }

    func testWhatADropDoes() {
        let none: (URL) -> Bool = { _ in false }
        func operation(_ sources: [URL], _ folder: URL, copy: Bool = false) -> FileTransfer.Operation? {
            FileTransfer.operation(for: sources, into: folder, root: root, prefersCopy: copy, exists: none)
        }
        XCTAssertEqual(operation([url("README.md")], url("docs")), .move)
        XCTAssertEqual(operation([url("README.md")], url("docs"), copy: true), .copy)
        // ⌥ copies next to the original; a plain drag there does nothing.
        XCTAssertNil(operation([url("docs/stations.md")], url("docs")))
        XCTAssertEqual(operation([url("docs/stations.md")], url("docs"), copy: true), .copy)
        XCTAssertNil(operation([url("docs")], url("docs/images")))
        XCTAssertNil(operation([url("docs")], url("docs/images"), copy: true))
        // From elsewhere (the Finder): always a copy.
        let outside = URL(filePath: "/elsewhere/notes.md")
        XCTAssertEqual(operation([outside], url("docs")), .copy)
        XCTAssertEqual(operation([outside], root), .copy)
        // A folder from elsewhere cannot go inside itself either.
        XCTAssertNil(FileTransfer.operation(for: [URL(filePath: "/")], into: url("docs"), root: root, prefersCopy: false,
                                            exists: none))
        XCTAssertNil(operation([], root))
    }

    func testTabsFollowAMovedFolder() {
        XCTAssertEqual(FileTransfer.relocated(url("docs/stations.md"), from: url("docs"), to: url("modeles/docs")),
                       url("modeles/docs/stations.md"))
        XCTAssertEqual(FileTransfer.relocated(url("docs/images/carte.png"), from: url("docs"), to: url("archive/docs")),
                       url("archive/docs/images/carte.png"))
        XCTAssertEqual(FileTransfer.relocated(url("docs"), from: url("docs"), to: url("modeles/docs")), url("modeles/docs"))
        XCTAssertNil(FileTransfer.relocated(url("docs-old/a.md"), from: url("docs"), to: url("modeles/docs")))
        XCTAssertNil(FileTransfer.relocated(url("README.md"), from: url("docs"), to: url("modeles/docs")))
    }

    func testCopiesGetFinderNames() {
        let taken: Set<String> = ["notes.md", "notes 2.md", "images", "Makefile", ".env", "archive.tar.gz"]
        func name(_ name: String, folder: Bool = false) -> String {
            FileTransfer.copyName(for: name, isFolder: folder) { taken.contains($0) }
        }
        XCTAssertEqual(name("journal.md"), "journal.md")
        XCTAssertEqual(name("notes.md"), "notes 3.md")
        XCTAssertEqual(name("notes 2.md"), "notes 3.md")
        XCTAssertEqual(name("images", folder: true), "images 2")
        XCTAssertEqual(name("Makefile"), "Makefile 2")
        XCTAssertEqual(name(".env"), ".env 2")
        XCTAssertEqual(name("archive.tar.gz"), "archive.tar 2.gz")
    }

    func testThePaneTakesOneFolderOrOneDocument() throws {
        let folder = try SampleFolder()
        XCTAssertEqual(FolderHandoff.paneDrop(for: [folder.file("docs")]), .folder(folder.file("docs")))
        XCTAssertEqual(FolderHandoff.paneDrop(for: [folder.file("README.md")]), .document(folder.file("README.md")))
        XCTAssertEqual(FolderHandoff.paneDrop(for: [folder.file("notes.txt")]), .document(folder.file("notes.txt")))
        XCTAssertNil(FolderHandoff.paneDrop(for: [folder.file("logo.png")]))
        XCTAssertNil(FolderHandoff.paneDrop(for: [folder.file("docs"), folder.file("modeles")]))
        XCTAssertNil(FolderHandoff.paneDrop(for: []))
    }

    func testADroppedFolderGetsItsBookmark() throws {
        let folder = try SampleFolder()
        let reference = try XCTUnwrap(FolderReference(droppedURL: folder.url))
        XCTAssertEqual(reference.path, folder.url.standardizedFileURL.path)
        XCTAssertNotNil(reference.bookmark)
        XCTAssertEqual(reference.resolve()?.url.path, folder.url.standardizedFileURL.path)
    }
}

@MainActor
final class FolderDropTests: XCTestCase {
    private var folder: SampleFolder!
    private var session: FolderSession!
    private var defaults: UserDefaults!
    private var errors: [String] = []
    private let suite = "app.kayakoma.editor.tests.folder-drop"

    override func setUp() async throws {
        folder = try SampleFolder()
        defaults = UserDefaults(suiteName: suite)
        session = FolderSession(reference: FolderReference(url: folder.url), memory: FolderMemory(defaults: defaults))
        session.errorPresenter = { [weak self] message, _ in self?.errors.append(message) }
        session.start(state: nil, showsHiddenFiles: false, hidesOtherFiles: false, marksBrokenLinks: true)
        for _ in 0..<100 where !session.hasScanned {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.hasScanned)
    }

    override func tearDown() async throws {
        session.stop()
        defaults.removePersistentDomain(forName: suite)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: folder.file(path).path) }

    func testMovingAFolderKeepsItsTabsAndTheirChanges() async throws {
        session.open(folder.file("docs/stations.md"))
        let tab = try XCTUnwrap(session.currentTab)
        tab.model.panes.sourceView.insertText("Brouillon. ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(tab.isModified)
        let edited = tab.document.text
        session.expanded.insert(folder.file("docs"))

        XCTAssertTrue(session.move([folder.file("docs")], into: folder.file("modeles")))
        XCTAssertTrue(exists("modeles/docs/stations.md"))
        XCTAssertFalse(exists("docs"))
        XCTAssertTrue(session.currentTab === tab)
        XCTAssertEqual(tab.url, folder.file("modeles/docs/stations.md").canonicalFile)
        XCTAssertTrue(tab.isModified)
        XCTAssertEqual(tab.document.text, edited)
        XCTAssertTrue(session.expanded.contains(folder.file("modeles/docs").canonicalFile))
        XCTAssertFalse(session.expanded.contains(folder.file("docs").canonicalFile))
        XCTAssertNotNil(FileTree.node(at: folder.file("modeles/docs/stations.md").canonicalFile, in: session.tree))
        XCTAssertEqual(session.fileUndoManager.undoActionName, "le déplacement")

        // ⌘Z puts it back, the tab with it; redo moves it again.
        try await Task.sleep(for: .milliseconds(20))
        session.fileUndoManager.undo()
        XCTAssertTrue(exists("docs/stations.md"))
        XCTAssertFalse(exists("modeles/docs"))
        XCTAssertEqual(tab.url, folder.file("docs/stations.md").canonicalFile)
        XCTAssertEqual(tab.document.text, edited)
        session.fileUndoManager.redo()
        XCTAssertTrue(exists("modeles/docs/stations.md"))
        XCTAssertEqual(tab.url, folder.file("modeles/docs/stations.md").canonicalFile)
        XCTAssertTrue(errors.isEmpty)
    }

    func testAMoveNeverReplacesAnEntry() throws {
        try folder.write("modeles/notes.txt", "Autre.\n")
        XCTAssertFalse(session.move([folder.file("notes.txt")], into: folder.file("modeles")))
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(try String(contentsOf: folder.file("notes.txt"), encoding: .utf8), "Brouillon.\n")
        XCTAssertEqual(try String(contentsOf: folder.file("modeles/notes.txt"), encoding: .utf8), "Autre.\n")
        // Into itself, or where it is: nothing happens, nothing to explain.
        XCTAssertFalse(session.move([folder.file("docs")], into: folder.file("docs/images")))
        XCTAssertFalse(session.move([folder.file("README.md")], into: folder.url))
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(session.fileUndoManager.canUndo)
    }

    func testFilesFromElsewhereAreCopiedUnderAFreeName() async throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "kayakoma-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside.appending(path: "images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("Ailleurs.\n".utf8).write(to: outside.appending(path: "notes.txt"))
        try Data("png".utf8).write(to: outside.appending(path: "images/plan.png"))

        XCTAssertEqual(session.dropOperation(for: [outside.appending(path: "notes.txt")], into: folder.url, prefersCopy: false),
                       .copy)
        let copied = await session.copy([outside.appending(path: "notes.txt"), outside.appending(path: "images")],
                                        into: folder.file("docs"))
        XCTAssertEqual(copied.map(\.lastPathComponent), ["notes.txt", "images 2"])
        XCTAssertTrue(exists("docs/images 2/plan.png"))
        let again = await session.copy([outside.appending(path: "notes.txt")], into: folder.url)
        XCTAssertEqual(again.map(\.lastPathComponent), ["notes 2.txt"])
        XCTAssertEqual(try String(contentsOf: folder.file("notes 2.txt"), encoding: .utf8), "Ailleurs.\n")
        XCTAssertEqual(try String(contentsOf: folder.file("notes.txt"), encoding: .utf8), "Brouillon.\n")
        // The copies appear in the tree; none of them opens.
        XCTAssertNotNil(FileTree.node(at: folder.file("notes 2.txt").canonicalFile, in: session.tree))
        XCTAssertEqual(session.tabs.items.map(\.name), ["README.md"])
        XCTAssertEqual(session.fileUndoManager.undoActionName, "la copie")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "notes.txt").path))
    }
}
