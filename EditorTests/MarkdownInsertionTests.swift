import AppKit
import XCTest

/// The cheat sheet's « Insérer »: wrapping and unwrapping inline styles,
/// placeholders, links, and blocks that never cut a paragraph.
final class MarkdownInsertionTests: XCTestCase {
    /// Applies a snippet to a text whose selection is marked with `[` and `]`
    /// (or a caret `|`), and returns the result with the new selection marked
    /// the same way.
    private func insert(_ snippet: MarkdownSnippet, into marked: String) -> String {
        let (text, selection) = parse(marked)
        let edit = MarkdownInsertion(snippet: snippet, in: text, selection: selection)
        return mark(edit.applied(to: text), selection: edit.selection)
    }

    private func parse(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound {
            return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let open = ns.range(of: "[[")
        let close = ns.range(of: "]]")
        precondition(open.location != NSNotFound && close.location != NSNotFound, "no selection in \(marked)")
        let text = ns.replacingCharacters(in: close, with: "") as NSString
        return (text.replacingCharacters(in: open, with: ""), NSRange(location: open.location, length: close.location - open.location - 2))
    }

    private func mark(_ text: String, selection: NSRange) -> String {
        let ns = text as NSString
        if selection.length == 0 { return ns.replacingCharacters(in: selection, with: "|") }
        let closed = ns.replacingCharacters(in: NSRange(location: NSMaxRange(selection), length: 0), with: "]]") as NSString
        return closed.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "[[")
    }

    private let bold = MarkdownSnippet.inline(prefix: "**", suffix: "**", placeholder: "texte")
    private let italic = MarkdownSnippet.inline(prefix: "*", suffix: "*", placeholder: "texte")
    private let boldItalic = MarkdownSnippet.inline(prefix: "***", suffix: "***", placeholder: "texte")
    private let code = MarkdownSnippet.inline(prefix: "`", suffix: "`", placeholder: "code")

    // MARK: Inline styles

    func testWrapsSelectionAndKeepsItSelected() {
        XCTAssertEqual(insert(bold, into: "Le sentier [[longe la mangrove]] jusqu'au ponton."),
                       "Le sentier **[[longe la mangrove]]** jusqu'au ponton.")
    }

    func testSecondClickRemovesTheMarks() {
        XCTAssertEqual(insert(bold, into: "Le sentier **[[longe la mangrove]]** jusqu'au ponton."),
                       "Le sentier [[longe la mangrove]] jusqu'au ponton.")
        // Marks selected with the text count the same.
        XCTAssertEqual(insert(bold, into: "Le sentier [[**longe**]] la mangrove."),
                       "Le sentier [[longe]] la mangrove.")
        XCTAssertEqual(insert(code, into: "lancer `[[make]]` ici"), "lancer [[make]] ici")
    }

    func testBoldAndItalicCombine() {
        XCTAssertEqual(insert(italic, into: "un **[[mot]]** ici"), "un ***[[mot]]*** ici")
        XCTAssertEqual(insert(bold, into: "un ***[[mot]]*** ici"), "un *[[mot]]* ici")
        XCTAssertEqual(insert(italic, into: "un ***[[mot]]*** ici"), "un **[[mot]]** ici")
        XCTAssertEqual(insert(boldItalic, into: "un ***[[mot]]*** ici"), "un [[mot]] ici")
        XCTAssertEqual(insert(boldItalic, into: "un *[[mot]]* ici"), "un ***[[mot]]*** ici")
        // Italic is not taken for half of a bold.
        XCTAssertEqual(insert(bold, into: "un *[[mot]]* ici"), "un ***[[mot]]*** ici")
    }

    func testSpacesAtTheEndsOfTheSelectionStayOutside() {
        XCTAssertEqual(insert(bold, into: "un[[ mot ]]ici"), "un **[[mot]]** ici")
    }

    func testWithoutSelectionThePlaceholderIsSelected() {
        XCTAssertEqual(insert(bold, into: "Voir |"), "Voir **[[texte]]**")
        XCTAssertEqual(insert(.inline(prefix: "<", suffix: ">", placeholder: "https://"), into: "Site : |."),
                       "Site : <[[https://]]>.")
    }

    func testOtherMarksToggleToo() {
        let autolink = MarkdownSnippet.inline(prefix: "<", suffix: ">", placeholder: "https://")
        XCTAssertEqual(insert(autolink, into: "<[[https://exemple.org]]>"), "[[https://exemple.org]]")
        XCTAssertEqual(insert(autolink, into: "[[https://exemple.org]]"), "<[[https://exemple.org]]>")
        let escape = MarkdownSnippet.inline(prefix: "\\", suffix: "", placeholder: "*")
        XCTAssertEqual(insert(escape, into: "a [[*]] b"), "a \\[[*]] b")
        XCTAssertEqual(insert(escape, into: "a \\[[*]] b"), "a [[*]] b")
    }

    func testTextIsTypedInPlaceOfTheSelection() {
        XCTAssertEqual(insert(.text("\\\n"), into: "fin de ligne|suite"), "fin de ligne\\\n|suite")
    }

    // MARK: Links

    func testLinkWithoutSelectionSelectsItsText() {
        XCTAssertEqual(insert(.link(prefix: "[", text: "texte", url: "https://"), into: "Voir aussi |"),
                       "Voir aussi [[[texte]]](https://)")
    }

    func testLinkWithSelectionSelectsTheAddress() {
        XCTAssertEqual(insert(.link(prefix: "[", text: "texte", url: "https://"), into: "Voir [[la carte]]"),
                       "Voir [la carte]([[https://]])")
        XCTAssertEqual(insert(.link(prefix: "![", text: "description", url: "image.png"), into: "[[Plan]] "),
                       "![Plan]([[image.png]]) ")
    }

    // MARK: Blocks

    private let table = MarkdownSnippet.block("| Colonne | Colonne |\n| ------- | ------- |\n| Valeur | Valeur |",
                                              selecting: "Colonne")

    func testBlockGoesAfterTheParagraphNeverInside() {
        XCTAssertEqual(insert(table, into: "Les horaires| changent en été.\n"),
                       "Les horaires changent en été.\n\n| [[Colonne]] | Colonne |\n| ------- | ------- |\n| Valeur | Valeur |\n")
        XCTAssertEqual(insert(.block("---", selecting: nil), into: "Première ligne|\nseconde ligne\n\nSuite"),
                       "Première ligne\nseconde ligne\n\n---|\n\nSuite")
    }

    func testBlockAddsTheEmptyLinesItNeeds() {
        let heading = MarkdownSnippet.block("## Titre", selecting: "Titre")
        // At the end of a paragraph without a final line break.
        XCTAssertEqual(insert(heading, into: "Texte|"), "Texte\n\n## [[Titre]]")
        // On an empty line between two paragraphs, which are kept apart.
        XCTAssertEqual(insert(heading, into: "Avant\n|\nAprès"), "Avant\n\n## [[Titre]]\n\nAprès")
        // On an empty line that already has space around it.
        XCTAssertEqual(insert(heading, into: "Avant\n\n|\n\nAprès"), "Avant\n\n## [[Titre]]\n\nAprès")
        // In an empty document.
        XCTAssertEqual(insert(heading, into: "|"), "## [[Titre]]")
        // A paragraph directly followed by another block.
        XCTAssertEqual(insert(heading, into: "Un|\nDeux\n# Trois"), "Un\nDeux\n# Trois\n\n## [[Titre]]")
    }

    func testBlockSkipsAFencedCodeBlockWithEmptyLines() {
        let quote = MarkdownSnippet.block("> texte cité", selecting: "texte cité")
        let source = "```swift\nlet a = 1\n|\nlet b = 2\n```\n\nFin"
        XCTAssertEqual(insert(quote, into: source), "```swift\nlet a = 1\n\nlet b = 2\n```\n\n> [[texte cité]]\n\nFin")
        let inCode = "Intro\n```\nlet| a = 1\n\nlet b = 2\n```"
        XCTAssertEqual(insert(quote, into: inCode), "Intro\n```\nlet a = 1\n\nlet b = 2\n```\n\n> [[texte cité]]")
    }

    func testBlockIgnoresTheSelectionText() {
        let list = MarkdownSnippet.block("- élément\n- élément", selecting: "élément")
        XCTAssertEqual(insert(list, into: "Un [[mot]] ici.\n"), "Un mot ici.\n\n- [[élément]]\n- élément\n")
    }

    @MainActor func testOneEditUndoneInOneStep() throws {
        let view = SourceTextView(usingTextLayoutManager: true)
        let undoManager = UndoManager()
        let delegate = UndoDelegate(undoManager: undoManager)
        view.delegate = delegate
        view.allowsUndo = true
        view.string = "Le sentier longe la mangrove."
        view.setSelectedRange(NSRange(location: 11, length: 5))
        let edit = MarkdownInsertion(snippet: bold, in: view.string, selection: view.selectedRange())
        view.apply(edit, actionName: "Gras")
        XCTAssertEqual(view.string, "Le sentier **longe** la mangrove.")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 13, length: 5))
        XCTAssertEqual(undoManager.undoActionName, "Gras")
        undoManager.undo()
        XCTAssertEqual(view.string, "Le sentier longe la mangrove.")
        XCTAssertFalse(undoManager.canUndo)
    }

    func testCheatSheetSnippetsAreConsistent() {
        for section in CheatSheetSection.allCases {
            for entry in section.entries {
                guard case let .block(text, selecting)? = entry.snippet, let selecting else { continue }
                XCTAssertTrue(text.contains(selecting), "\(entry.id): placeholder not in its block")
            }
        }
        XCTAssertEqual(CheatSheetLanguage.all.count, 16)
        XCTAssertEqual(MarkedSyntax("⟦**⟧texte⟦**⟧").plain, "**texte**")
        XCTAssertEqual(CheatSheetSearch.results(for: "yml").map(\.section), [.code])
        XCTAssertEqual(CheatSheetSearch.results(for: "").count, CheatSheetSection.allCases.count)
    }
}

/// Gives a text view an undo manager outside a window.
private final class UndoDelegate: NSObject, NSTextViewDelegate {
    let undoManager: UndoManager

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
}
