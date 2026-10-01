import AppKit
import KayakomaKit
import XCTest

/// A temporary folder laid out like a small notebook, removed after the test.
final class SampleFolder {
    private(set) var url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "kayakoma-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "mangrove", directoryHint: .isDirectory)
        for path in ["docs/images", "modeles", "releves/2026/09", "photos", "vide", ".git"] {
            try FileManager.default.createDirectory(at: url.appending(path: path), withIntermediateDirectories: true)
        }
        // The real path (/private/var…), as bookmarks and open panels give it.
        url = URL(filePath: String(cString: realpath(url.path, nil)), directoryHint: .isDirectory)
        try write("README.md", "# Mangrove\n\nVoir le [guide des stations](docs/stations.md#acces).\n")
        try write("CHANGELOG.md", "# Journal\n")
        try write("notes.txt", "Brouillon.\n")
        try write("logo.png", "png")
        try write("releves.csv", "station;marée\n")
        try write(".brouillon.md", "caché\n")
        try write(".git/config", "[core]\n")
        try write("docs/stations.md", "# Guide des stations\n\n## Accès\n\nRetour au [README](../README.md).\n")
        try write("docs/glossaire.md", "# Glossaire\n")
        try write("docs/images/carte.png", "png")
        try write("modeles/station-type.md", "# Station type\n")
        try write("releves/2026/09/2026-09-28.md", "# Relevé\n")
        try write("photos/IMG_0398.jpg", "jpg")
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: url.appending(path: path))
    }

    func file(_ path: String) -> URL { url.appending(path: path).standardizedFileURL }
}

final class FileTreeTests: XCTestCase {
    func testScanSortsFoldersFirstAndSkipsHiddenEntries() throws {
        let folder = try SampleFolder()
        let tree = FileTree.scan(folder.url, showsHiddenFiles: false)
        XCTAssertEqual(tree.map(\.name), ["docs", "modeles", "photos", "releves", "vide",
                                          "CHANGELOG.md", "logo.png", "notes.txt", "README.md", "releves.csv"])
        XCTAssertEqual(tree.first?.children?.map(\.name), ["images", "glossaire.md", "stations.md"])
        XCTAssertEqual(tree.first { $0.name == "notes.txt" }?.kind, .plainText)
        XCTAssertEqual(tree.first { $0.name == "logo.png" }?.kind, .other)
        XCTAssertTrue(tree.first { $0.name == "releves" }!.containsDocuments)
        XCTAssertFalse(tree.first { $0.name == "photos" }!.containsDocuments)

        let all = FileTree.scan(folder.url, showsHiddenFiles: true)
        XCTAssertTrue(all.contains { $0.name == ".git" })
        XCTAssertTrue(all.contains { $0.name == ".brouillon.md" })
    }

    func testOtherFilesAreHiddenWithTheirFolders() throws {
        let folder = try SampleFolder()
        let tree = FileTree.scan(folder.url, showsHiddenFiles: false)
        let hidden = FileTree.filtered(tree, hidesOtherFiles: true, query: "")
        XCTAssertEqual(hidden.map(\.name), ["docs", "modeles", "releves", "CHANGELOG.md", "notes.txt", "README.md"])
        XCTAssertEqual(hidden.first?.children?.map(\.name), ["glossaire.md", "stations.md"])
        // Dimmed: nothing removed.
        XCTAssertEqual(FileTree.filtered(tree, hidesOtherFiles: false, query: ""), tree)
    }

    func testFilterKeepsTheHierarchy() throws {
        let folder = try SampleFolder()
        let tree = FileTree.scan(folder.url, showsHiddenFiles: false)
        let found = FileTree.filtered(tree, hidesOtherFiles: false, query: "2026-09")
        XCTAssertEqual(found.map(\.name), ["releves"])
        XCTAssertEqual(found.first?.children?.first?.children?.first?.children?.map(\.name), ["2026-09-28.md"])
        XCTAssertEqual(FileTree.fileCount(in: found), 1)
        // Case and accents do not matter; a folder that matches keeps its contents.
        XCTAssertEqual(FileTree.filtered(tree, hidesOtherFiles: false, query: "STATION").map(\.name), ["docs", "modeles"])
        XCTAssertEqual(FileTree.filtered(tree, hidesOtherFiles: false, query: "modèles").first?.children?.count, 1)
        XCTAssertEqual(FileTree.matchRange(of: "gLo", in: "glossaire.md").map { "glossaire.md"[$0] }, "glo")
    }

    func testDocumentsAndLookups() throws {
        let folder = try SampleFolder()
        let tree = FileTree.scan(folder.url, showsHiddenFiles: false)
        let paths = FileTree.documents(in: tree).compactMap { FolderPath.relative($0, to: folder.url) }
        XCTAssertEqual(paths, ["docs/glossaire.md", "docs/stations.md", "modeles/station-type.md",
                               "releves/2026/09/2026-09-28.md", "CHANGELOG.md", "notes.txt", "README.md"])
        XCTAssertEqual(FileTree.node(at: folder.file("docs/images/carte.png"), in: tree)?.kind, .other)
        XCTAssertNil(FileTree.node(at: folder.file("docs/absent.md"), in: tree))
    }

    func testScanStopsAtTheEntryLimit() throws {
        let folder = try SampleFolder()
        func entries(_ nodes: [FileNode]) -> Int { nodes.reduce(0) { $0 + 1 + entries($1.children ?? []) } }
        XCTAssertEqual(entries(FileTree.scan(folder.url, showsHiddenFiles: false)), 19)
        XCTAssertEqual(entries(FileTree.scan(folder.url, showsHiddenFiles: false, limit: 3)), 3)
        XCTAssertEqual(entries(FileTree.scan(folder.url, showsHiddenFiles: false, limit: 8)), 8)
    }

    func testFolderPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/mangrove", isDirectory: true)
        XCTAssertEqual(FolderPath.relative(URL(fileURLWithPath: "/tmp/mangrove/docs/a.md"), to: root), "docs/a.md")
        XCTAssertEqual(FolderPath.relative(root, to: root), "")
        XCTAssertNil(FolderPath.relative(URL(fileURLWithPath: "/tmp/mangrove-2/a.md"), to: root))
        XCTAssertTrue(FolderPath.isInside(URL(fileURLWithPath: "/tmp/mangrove/docs/../a.md"), root))
        XCTAssertFalse(FolderPath.isInside(URL(fileURLWithPath: "/tmp/mangrove/../a.md"), root))
        XCTAssertEqual(FolderPath.ancestors(of: URL(fileURLWithPath: "/tmp/mangrove/releves/2026/a.md"), in: root).map(\.lastPathComponent),
                       ["releves", "2026"])

        let folder = try SampleFolder()
        XCTAssertEqual(FolderPath.uniqueURL(in: folder.url, base: "README", extension: "md").lastPathComponent, "README 2.md")
        XCTAssertEqual(FolderPath.uniqueURL(in: folder.url, base: "Sans titre", extension: "md").lastPathComponent, "Sans titre.md")
        XCTAssertEqual(FolderPath.uniqueURL(in: folder.url, base: "docs", extension: nil).lastPathComponent, "docs 2")
    }
}

final class FuzzyMatcherTests: XCTestCase {
    private let paths = ["docs/stations.md", "modeles/station-type.md", "docs/sorties-terrain-avril.md",
                         "docs/protocole.md", "CHANGELOG.md", "README.md", "modeles/fiche-du-jour.md",
                         "releves/2026/09/2026-09-30.md"]

    func testLettersMustAppearInOrder() {
        XCTAssertNotNil(FuzzyMatcher.match("sta", in: "docs/stations.md"))
        XCTAssertNil(FuzzyMatcher.match("tsa", in: "docs/stations.md"))
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "README.md"))
        XCTAssertEqual(FuzzyMatcher.match("sta", in: "docs/stations.md")?.positions, [5, 6, 7])
        // Accents and case are ignored, spaces too.
        XCTAssertNotNil(FuzzyMatcher.match("Marees", in: "docs/marées.md"))
        XCTAssertNotNil(FuzzyMatcher.match("fiche jour", in: "modeles/fiche-du-jour.md"))
    }

    func testRankingFavoursRunsAndStartsOfWords() {
        let ranked = FuzzyMatcher.rank(paths, query: "sta", recents: []).map(\.path)
        XCTAssertEqual(Array(ranked.prefix(3)), ["docs/stations.md", "modeles/station-type.md", "docs/sorties-terrain-avril.md"])
        // Starts of words win over letters inside them.
        let sorties = FuzzyMatcher.match("sta", in: "docs/sorties-terrain-avril.md")
        XCTAssertEqual(sorties?.positions, [5, 13, 21])
        XCTAssertEqual(FuzzyMatcher.rank(paths, query: "fiche", recents: []).first?.path, "modeles/fiche-du-jour.md")
        // The file name counts more than its folder.
        XCTAssertEqual(FuzzyMatcher.rank(["modeles/notes.md", "docs/modele.md"], query: "mod", recents: []).first?.path,
                       "docs/modele.md")
    }

    func testRecentFilesComeFirst() {
        let recents = ["docs/protocole.md", "CHANGELOG.md", "docs/absent.md"]
        let empty = FuzzyMatcher.rank(paths, query: "", recents: recents).map(\.path)
        XCTAssertEqual(Array(empty.prefix(2)), ["docs/protocole.md", "CHANGELOG.md"])
        XCTAssertEqual(empty.count, paths.count)
        XCTAssertFalse(empty.contains("docs/absent.md"))
        XCTAssertEqual(empty[2], "docs/sorties-terrain-avril.md")
        // At equal score, a recent file wins.
        let tie = FuzzyMatcher.rank(["a/note.md", "b/note.md"], query: "note", recents: ["b/note.md"]).map(\.path)
        XCTAssertEqual(tie, ["b/note.md", "a/note.md"])
    }
}

final class TabListTests: XCTestCase {
    struct Tab: Identifiable, Equatable {
        let id: String
    }

    func testNewTabsOpenRightAfterTheCurrentOne() {
        var list = TabList<Tab>()
        XCTAssertNil(list.current)
        list.insert(Tab(id: "README"))
        list.insert(Tab(id: "CHANGELOG"))
        XCTAssertEqual(list.items.map(\.id), ["README", "CHANGELOG"])
        list.select("README")
        list.insert(Tab(id: "stations"))
        XCTAssertEqual(list.items.map(\.id), ["README", "stations", "CHANGELOG"])
        XCTAssertEqual(list.currentID, "stations")
        // In the background: placed after the current tab, which stays.
        list.insert(Tab(id: "protocole"), inBackground: true)
        XCTAssertEqual(list.items.map(\.id), ["README", "stations", "protocole", "CHANGELOG"])
        XCTAssertEqual(list.currentID, "stations")
    }

    func testClosingShowsTheNextTabThenThePreviousOne() {
        var list = TabList<Tab>()
        for id in ["a", "b", "c"] { list.insert(Tab(id: id)) }
        list.select("b")
        XCTAssertEqual(list.remove("b")?.id, "b")
        XCTAssertEqual(list.currentID, "c")
        list.remove("c")
        XCTAssertEqual(list.currentID, "a")
        // Closing another tab keeps the current one.
        list.insert(Tab(id: "d"))
        list.select("a")
        list.remove("d")
        XCTAssertEqual(list.currentID, "a")
        // The last tab: no current tab, the window stays.
        list.remove("a")
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(list.currentID)
        XCTAssertNil(list.remove("a"))
    }

    func testReorderAndSwitch() {
        var list = TabList<Tab>()
        for id in ["a", "b", "c", "d"] { list.insert(Tab(id: id)) }
        list.move("a", to: 2)
        XCTAssertEqual(list.items.map(\.id), ["b", "c", "a", "d"])
        list.move("d", to: 0)
        XCTAssertEqual(list.items.map(\.id), ["d", "b", "c", "a"])
        list.move("b", to: 99)
        XCTAssertEqual(list.items.map(\.id), ["d", "c", "a", "b"])
        XCTAssertEqual(list.currentID, "d")
        list.selectNeighbour(offset: -1)
        XCTAssertEqual(list.currentID, "b")
        list.selectNeighbour(offset: 1)
        XCTAssertEqual(list.currentID, "d")
        list.select("missing")
        XCTAssertEqual(list.currentID, "d")
    }

    func testRestoredTabsKeepTheirOrder() {
        var list = TabList<Tab>()
        for id in ["a", "b", "c"] { list.append(Tab(id: id)) }
        XCTAssertEqual(list.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(list.currentID, "a")
    }
}

final class LinkTargetTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/notes/mangrove", isDirectory: true)
    private let current = URL(fileURLWithPath: "/notes/mangrove/README.md")
    private let existing: Set<String> = ["/notes/mangrove/README.md", "/notes/mangrove/docs/stations.md",
                                         "/notes/mangrove/logo.png", "/notes/mangrove/docs", "/notes/other.md"]

    private func resolve(_ link: String) -> LinkTarget {
        // As the engine resolves it, against the current file's folder.
        let url = link.hasPrefix("#") ? URL(string: link)! : URL(string: link, relativeTo: root)!.absoluteURL
        return LinkTarget.resolve(url, root: root, currentFile: current) { url in
            (existing.contains(url.path), url.pathExtension.isEmpty)
        }
    }

    func testLinksInsideTheFolder() {
        XCTAssertEqual(resolve("docs/stations.md"), .document(URL(fileURLWithPath: "/notes/mangrove/docs/stations.md"), anchor: nil))
        XCTAssertEqual(resolve("docs/stations.md#acces"),
                       .document(URL(fileURLWithPath: "/notes/mangrove/docs/stations.md"), anchor: "acces"))
        XCTAssertEqual(resolve("./docs/../docs/stations.md"),
                       .document(URL(fileURLWithPath: "/notes/mangrove/docs/stations.md"), anchor: nil))
        XCTAssertEqual(resolve("logo.png"), .otherFile(URL(fileURLWithPath: "/notes/mangrove/logo.png")))
        XCTAssertEqual(resolve("docs"), .folder(URL(fileURLWithPath: "/notes/mangrove/docs")))
    }

    func testAnchorsOfTheSameDocument() {
        XCTAssertEqual(resolve("#installation"), .anchor("installation"))
        XCTAssertEqual(resolve("README.md#usage"), .anchor("usage"))
    }

    func testMissingFilesAndOtherPlaces() {
        XCTAssertEqual(resolve("docs/marees.md"),
                       .missing(URL(fileURLWithPath: "/notes/mangrove/docs/marees.md"), canCreate: true))
        XCTAssertEqual(resolve("docs/carte.pdf"),
                       .missing(URL(fileURLWithPath: "/notes/mangrove/docs/carte.pdf"), canCreate: false))
        XCTAssertEqual(resolve("../other.md"), .outside(URL(fileURLWithPath: "/notes/other.md"), opensInEditor: true))
        XCTAssertEqual(resolve("https://example.org/guide"), .external(URL(string: "https://example.org/guide")!))
        XCTAssertEqual(resolve("mailto:someone@example.org"), .external(URL(string: "mailto:someone@example.org")!))
    }

    func testBrokenLinks() {
        let check: (URL) -> (exists: Bool, isDirectory: Bool) = { [existing] in (existing.contains($0.path), false) }
        XCTAssertTrue(LinkTarget.isBroken(URL(fileURLWithPath: "/notes/mangrove/docs/marees.md"), root: root, fileExists: check))
        XCTAssertFalse(LinkTarget.isBroken(URL(string: "file:///notes/mangrove/docs/stations.md#acces")!, root: root, fileExists: check))
        XCTAssertFalse(LinkTarget.isBroken(URL(fileURLWithPath: "/elsewhere/missing.md"), root: root, fileExists: check))
        XCTAssertFalse(LinkTarget.isBroken(URL(string: "https://example.org/missing.md")!, root: root, fileExists: check))
    }

    func testNewFilesAreTitledAfterTheLink() {
        let file = URL(fileURLWithPath: "/notes/mangrove/docs/calendrier-des-marees.md")
        XCTAssertEqual(LinkTarget.heading(forLinkText: "calendrier des marées", file: file), "# Calendrier des marées\n")
        XCTAssertEqual(LinkTarget.heading(forLinkText: " ", file: file), "# Calendrier des marees\n")
    }

    func testSourceLinksAreFound() {
        let text = "Voir le [guide](docs/stations.md) et [la carte](<cartes/plan général.md> \"Plan\").\n\n[ref]: docs/marees.md\n"
        let links = SourceLinks.find(in: text)
        XCTAssertEqual(links.map(\.destination), ["docs/stations.md", "cartes/plan général.md", "docs/marees.md"])
        XCTAssertEqual(links.map { (text as NSString).substring(with: $0.range) }, links.map(\.destination))
        let base = URL(fileURLWithPath: "/notes/mangrove/", isDirectory: true)
        XCTAssertEqual(SourceLinks.resolve("docs/stations.md#acces", baseURL: base)?.path, "/notes/mangrove/docs/stations.md")
        XCTAssertNil(SourceLinks.resolve("#acces", baseURL: base))
        XCTAssertNil(SourceLinks.resolve("https://example.org", baseURL: base))
    }
}

final class TextFileTests: XCTestCase {
    private var folder: SampleFolder!

    override func setUpWithError() throws {
        folder = try SampleFolder()
    }

    func testLegacyEncodingAndLineEndingsRoundTrip() throws {
        let url = folder.file("legacy.md")
        let original = Data("# Caf\u{E9}\r\n\r\nCr\u{E8}me br\u{FB}l\u{E9}e.\r\n".data(using: .windowsCP1252)!)
        try original.write(to: url)
        let read = try TextFile.read(url)
        XCTAssertEqual(read.content.encoding, .windows1252)
        XCTAssertEqual(read.content.lineEnding, .crlf)
        XCTAssertEqual(read.content.text, "# Caf\u{E9}\n\nCr\u{E8}me br\u{FB}l\u{E9}e.\n")
        let saved = try TextFile.write(read.content, to: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(saved.content, read.content)
        XCTAssertNotNil(saved.modificationDate)
    }

    func testByteOrderMarkAndPermissionsAreKept() throws {
        let url = folder.file("bom.md")
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# Titre\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let read = try TextFile.read(url)
        XCTAssertTrue(read.content.hasByteOrderMark)
        try TextFile.write(read.content, to: url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testTextOutsideTheEncodingIsSavedAsUTF8() throws {
        let url = folder.file("legacy.md")
        let content = DecodedText(text: "Caf\u{E9} 🌊\n", encoding: .windows1252, lineEnding: .lf)
        let saved = try TextFile.write(content, to: url)
        XCTAssertEqual(saved.content.encoding, .utf8)
        XCTAssertEqual(try TextFile.read(url).content.text, "Caf\u{E9} 🌊\n")
    }

    func testBinaryFilesAreRefused() throws {
        let url = folder.file("binary.md")
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: url)
        XCTAssertThrowsError(try TextFile.read(url))
    }
}

final class FolderPersistenceTests: XCTestCase {
    func testReferenceSurvivesEncodingAndFollowsTheFolder() throws {
        let folder = try SampleFolder()
        let reference = FolderReference(url: folder.url)
        XCTAssertEqual(reference.path, folder.url.standardizedFileURL.path)
        XCTAssertNotNil(reference.bookmark)
        let decoded = try JSONDecoder().decode(FolderReference.self, from: JSONEncoder().encode(reference))
        XCTAssertEqual(decoded, reference)
        XCTAssertEqual(decoded.bookmark, reference.bookmark)
        XCTAssertEqual(decoded.resolve()?.url.resolvingSymlinksInPath().path, folder.url.resolvingSymlinksInPath().path)

        // Same path, same window, whatever the bookmark.
        XCTAssertEqual(FolderReference(path: reference.path, bookmark: nil), reference)
        XCTAssertEqual(Set([reference, FolderReference(path: reference.path, bookmark: nil)]).count, 1)

        // The folder is renamed: the bookmark finds it, and a new reference is made.
        let moved = folder.url.deletingLastPathComponent().appending(path: "mangrove-renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder.url, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: folder.url) }
        let resolution = try XCTUnwrap(decoded.resolve())
        XCTAssertEqual(resolution.url.lastPathComponent, "mangrove-renamed")
        XCTAssertEqual(resolution.refreshed?.url.lastPathComponent, "mangrove-renamed")

        // Without a bookmark, a missing folder cannot be found.
        XCTAssertNil(FolderReference(path: folder.url.path, bookmark: nil).resolve())
    }

    func testSidebarWidthAndRecentFilesArePerFolder() throws {
        let suite = "app.kayakoma.editor.tests.folder-memory"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = FolderMemory(defaults: defaults)
        XCTAssertEqual(memory.sidebarWidth(for: "/a"), FolderMemory.defaultSidebarWidth)
        memory.setSidebarWidth(260, for: "/a")
        memory.setSidebarWidth(9999, for: "/b")
        XCTAssertEqual(memory.sidebarWidth(for: "/a"), 260)
        XCTAssertEqual(memory.sidebarWidth(for: "/b"), FolderMemory.sidebarWidthRange.upperBound)

        for path in ["README.md", "docs/stations.md", "README.md"] { memory.noteRecentFile(path, for: "/a") }
        XCTAssertEqual(memory.recentFiles(for: "/a"), ["README.md", "docs/stations.md"])
        XCTAssertEqual(memory.recentFiles(for: "/b"), [])
        memory.renameRecentFile("docs", to: "guides", for: "/a")
        XCTAssertEqual(memory.recentFiles(for: "/a"), ["README.md", "guides/stations.md"])
        for index in 0..<30 { memory.noteRecentFile("file-\(index).md", for: "/a") }
        XCTAssertEqual(memory.recentFiles(for: "/a").count, FolderMemory.recentLimit)
        XCTAssertEqual(memory.recentFiles(for: "/a").first, "file-29.md")
    }

    func testWindowStateRoundTrips() {
        let state = FolderWindowState(tabs: ["README.md", "docs/stations.md"], current: "docs/stations.md",
                                      expanded: ["docs"], sidebarHidden: true)
        XCTAssertEqual(FolderWindowState(encoded: state.encoded), state)
        XCTAssertNil(FolderWindowState(encoded: ""))
        XCTAssertNil(FolderWindowState(encoded: "{"))
    }
}

/// A folder window's session, without the window.
@MainActor
final class FolderSessionTests: XCTestCase {
    private var folder: SampleFolder!
    private var session: FolderSession!
    private var defaults: UserDefaults!
    private let suite = "app.kayakoma.editor.tests.folder-session"

    override func setUp() async throws {
        folder = try SampleFolder()
        defaults = UserDefaults(suiteName: suite)
        session = FolderSession(reference: FolderReference(url: folder.url), memory: FolderMemory(defaults: defaults))
    }

    override func tearDown() async throws {
        session.stop()
        defaults.removePersistentDomain(forName: suite)
    }

    private func start(_ state: FolderWindowState? = nil) async throws {
        session.start(state: state, showsHiddenFiles: false, hidesOtherFiles: false, marksBrokenLinks: true)
        for _ in 0..<100 where !session.hasScanned {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.hasScanned)
    }

    private var openNames: [String] { session.tabs.items.map(\.name) }

    func testTheREADMEOpensWithTheFolder() async throws {
        try await start()
        XCTAssertEqual(openNames, ["README.md"])
        XCTAssertEqual(session.currentTab?.name, "README.md")
        XCTAssertTrue(session.hasDocuments)
        XCTAssertTrue(session.expanded.isEmpty)
    }

    func testSavedTabsAreRestoredInsteadOfTheREADME() async throws {
        try await start(FolderWindowState(tabs: ["CHANGELOG.md", "docs/stations.md", "docs/absent.md"],
                                          current: "docs/stations.md", expanded: ["docs"]))
        XCTAssertEqual(openNames, ["CHANGELOG.md", "stations.md"])
        XCTAssertEqual(session.tabs.items.last?.model.panes.brokenLinkRanges, [])
        XCTAssertEqual(session.currentTab?.name, "stations.md")
        XCTAssertEqual(session.state.tabs, ["CHANGELOG.md", "docs/stations.md"])
        XCTAssertEqual(session.state.expanded, ["docs"])
    }

    func testOpeningFocusesAnOpenTabAndRevealsTheFile() async throws {
        try await start()
        session.open(folder.file("CHANGELOG.md"))
        session.select(session.tabs.items[0])
        session.open(folder.file("docs/stations.md"))
        XCTAssertEqual(openNames, ["README.md", "stations.md", "CHANGELOG.md"])
        XCTAssertTrue(session.expanded.contains(folder.file("docs")))
        XCTAssertEqual(session.revealRequest, folder.file("docs/stations.md"))
        session.open(folder.file("CHANGELOG.md"))
        XCTAssertEqual(openNames.count, 3)
        XCTAssertEqual(session.currentTab?.name, "CHANGELOG.md")
        XCTAssertEqual(session.recentPaths.prefix(2), ["CHANGELOG.md", "docs/stations.md"])
        // Closing the last tabs leaves the window empty.
        for tab in session.tabs.items { session.close(tab) }
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.currentTab)
    }

    func testLinksOpenTabsAndFlagMissingFiles() async throws {
        try await start()
        let readme = try XCTUnwrap(session.currentTab)
        let base = readme.url.deletingLastPathComponent()
        func click(_ link: String) -> Bool {
            let url = URL(string: link, relativeTo: base)!.absoluteURL
            return session.followLink(.init(url: url, modifiers: [], characterIndex: 0, text: "x"), from: readme)
        }
        XCTAssertTrue(click("docs/stations.md#acces"))
        XCTAssertEqual(session.currentTab?.name, "stations.md")
        session.select(readme)
        XCTAssertFalse(click("https://example.org"))
        XCTAssertEqual(session.tabs.items.count, 2)

        session.createLinkedFile(folder.file("docs/marees.md"), linkText: "calendrier des marées")
        XCTAssertEqual(try String(contentsOf: folder.file("docs/marees.md"), encoding: .utf8), "# Calendrier des marées\n")
        XCTAssertEqual(session.currentTab?.name, "marees.md")
        XCTAssertEqual(openNames, ["README.md", "marees.md", "stations.md"])
    }

    func testEditingAndSavingATabKeepsTheEncoding() async throws {
        let original = Data("# Caf\u{E9}\r\n".data(using: .windowsCP1252)!)
        try original.write(to: folder.file("legacy.md"))
        try await start()
        session.open(folder.file("legacy.md"))
        let tab = try XCTUnwrap(session.currentTab)
        XCTAssertFalse(tab.isModified)
        // In a window, as in the app: undo goes through the window's text system.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.model.panes.rootView
        defer { window.close() }
        let source = tab.model.panes.sourceView
        window.makeFirstResponder(source)
        source.insertText(" cr\u{E8}me", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(tab.document.text, "# Caf\u{E9} cr\u{E8}me\n")
        XCTAssertTrue(tab.isModified)
        XCTAssertTrue(session.hasModifiedTabs)
        XCTAssertTrue(tab.undoManager.canUndo)
        XCTAssertTrue(session.save(tab))
        // Let the typing's undo group close with the event loop turn.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(tab.isModified)
        XCTAssertEqual(try Data(contentsOf: folder.file("legacy.md")), "# Caf\u{E9} cr\u{E8}me\r\n".data(using: .windowsCP1252))
        // Undoing back to the saved text marks the tab modified again, then not.
        tab.undoManager.undo()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(tab.document.text, "# Caf\u{E9}\n")
        XCTAssertTrue(tab.isModified)
        tab.undoManager.redo()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(tab.isModified)
    }

    func testAnUnmodifiedTabReloadsWhenTheFileChanges() async throws {
        try await start()
        let tab = try XCTUnwrap(session.currentTab)
        try Data("# Mangrove v2\n".utf8).write(to: tab.url, options: .atomic)
        for _ in 0..<100 where tab.document.text != "# Mangrove v2\n" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tab.document.text, "# Mangrove v2\n")
        XCTAssertFalse(tab.isModified)
    }

    func testRenamingMovesTheTabsAlong() async throws {
        try await start()
        session.open(folder.file("docs/stations.md"))
        XCTAssertTrue(session.rename(folder.file("docs"), to: "guides"))
        XCTAssertEqual(session.currentTab?.url.standardizedFileURL, folder.file("guides/stations.md"))
        XCTAssertTrue(session.expanded.contains(folder.file("guides")))
        XCTAssertFalse(session.expanded.contains(folder.file("docs")))
        XCTAssertTrue(session.rename(folder.file("guides/stations.md"), to: "postes.md"))
        XCTAssertEqual(session.currentTab?.name, "postes.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.file("guides/postes.md").path))
    }

    func testNewFilesAndFoldersGetFreeNames() async throws {
        try await start()
        session.newFile(in: folder.url)
        session.newFile(in: folder.url)
        XCTAssertEqual(session.currentTab?.name, "Sans titre 2.md")
        XCTAssertEqual(session.renameRequest, folder.file("Sans titre 2.md"))
        session.newFolder(in: folder.file("docs"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.file("docs/Nouveau dossier").path))
        XCTAssertNotNil(FileTree.node(at: folder.file("docs/Nouveau dossier"), in: session.tree))
    }

    func testAFileHandedOverOpensInsteadOfTheREADME() async throws {
        var opened: Bool?
        session.openInitialFile(folder.file("docs/stations.md")) { opened = $0 }
        try await start()
        XCTAssertEqual(opened, true)
        XCTAssertEqual(openNames, ["stations.md"])
        XCTAssertEqual(session.revealRequest, folder.file("docs/stations.md"))
    }

    func testAFileHandedOverJoinsTheRestoredTabs() async throws {
        var opened: Bool?
        session.openInitialFile(folder.file("CHANGELOG.md")) { opened = $0 }
        try await start(FolderWindowState(tabs: ["README.md"], current: "README.md"))
        XCTAssertEqual(opened, true)
        XCTAssertEqual(openNames, ["README.md", "CHANGELOG.md"])
        XCTAssertEqual(session.currentTab?.name, "CHANGELOG.md")
    }

    func testAFileOutsideTheFolderGetsNoTab() async throws {
        try await start()
        let other = try SampleFolder()
        var opened: Bool?
        session.openInitialFile(other.file("README.md")) { opened = $0 }
        XCTAssertEqual(opened, false)
        XCTAssertEqual(openNames, ["README.md"])
        XCTAssertEqual(session.tabs.items.count, 1)
    }

    func testTheFolderRemembersItsBookmark() async throws {
        try await start()
        let memory = FolderMemory(defaults: defaults)
        XCTAssertEqual(memory.reference(forPath: folder.url.standardizedFileURL.path)?.bookmark, session.reference.bookmark)
    }
}

/// Handing a file of a document window over to a folder window.
final class FolderHandoffTests: XCTestCase {
    func testTheTabIsTheFilesPathInTheFolder() throws {
        let folder = try SampleFolder()
        XCTAssertEqual(FolderHandoff.relativePath(of: folder.file("README.md"), in: folder.url), "README.md")
        XCTAssertEqual(FolderHandoff.relativePath(of: folder.file("docs/stations.md"), in: folder.url), "docs/stations.md")
        XCTAssertEqual(FolderHandoff.relativePath(of: folder.file("docs/stations.md"), in: folder.file("docs")), "stations.md")
        // Not inside: a sibling folder, a folder whose name only starts the same, the folder itself.
        XCTAssertNil(FolderHandoff.relativePath(of: folder.file("README.md"), in: folder.file("docs")))
        XCTAssertNil(FolderHandoff.relativePath(of: URL(filePath: folder.url.path + "-bis/README.md"), in: folder.url))
        XCTAssertNil(FolderHandoff.relativePath(of: folder.url, in: folder.url))
    }

    func testSymbolicLinksLeadToTheSameFolder() throws {
        let folder = try SampleFolder()
        // The temporary folder is reached through /var as well as /private/var.
        let real = folder.url.path
        XCTAssertTrue(real.hasPrefix("/private/"))
        let linked = URL(filePath: String(real.dropFirst("/private".count)), directoryHint: .isDirectory)
        XCTAssertEqual(FolderHandoff.relativePath(of: linked.appending(path: "docs/stations.md"), in: folder.url),
                       "docs/stations.md")
        XCTAssertEqual(FolderHandoff.enclosingFolder(of: linked.appending(path: "docs/stations.md")).path,
                       folder.url.appending(path: "docs").path)
    }

    func testTheHomeFolderIsWrittenTilde() {
        XCTAssertEqual(FolderHandoff.abbreviatedPath("/Users/marin/Documents/mangrove", home: "/Users/marin"),
                       "~/Documents/mangrove")
        XCTAssertEqual(FolderHandoff.abbreviatedPath("/Users/marin", home: "/Users/marin/"), "~")
        XCTAssertEqual(FolderHandoff.abbreviatedPath("/Users/marina/notes", home: "/Users/marin"), "/Users/marina/notes")
        XCTAssertEqual(FolderHandoff.abbreviatedPath("/Volumes/terrain/releves", home: "/Users/marin"), "/Volumes/terrain/releves")
    }

    func testBookmarksAreRememberedPerFolder() throws {
        let suite = "app.kayakoma.editor.tests.folder-bookmarks"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = FolderMemory(defaults: defaults)
        XCTAssertNil(memory.reference(forPath: "/a"))
        memory.remember(FolderReference(path: "/a", bookmark: Data([1, 2])))
        memory.remember(FolderReference(path: "/b", bookmark: nil))
        XCTAssertEqual(memory.reference(forPath: "/a")?.bookmark, Data([1, 2]))
        XCTAssertNil(memory.reference(forPath: "/b"))
    }
}
