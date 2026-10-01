import AppKit
import KayakomaKit
import SwiftUI

// The Markdown cheat sheet (« Aide-mémoire Markdown »): what the
// engine really renders, section by section, each row with its syntax and
// the result drawn by KayakomaKit with the app's theme. The same file is used
// by both Kayakoma apps; what a row's button does (insert in the Editor, copy
// in the Viewer) is passed in by each app.

// MARK: - Content

/// What inserting a row puts in the text. Pure data: the Editor interprets it,
/// the Viewer only copies the row's syntax.
enum MarkdownSnippet: Equatable, Sendable {
    /// An inline style: wraps the selection, or the placeholder when nothing
    /// is selected; clicking again on a wrapped selection removes the marks.
    case inline(prefix: String, suffix: String, placeholder: String)
    /// A link or an image: the selection becomes its text, then the address
    /// is selected; without a selection, the text placeholder is selected.
    case link(prefix: String, text: String, url: String)
    /// Text typed at the caret, in place of the selection.
    case text(String)
    /// A block on its own lines, after the current block; `selecting` is the
    /// first place to fill in (its first occurrence in `text`).
    case block(String, selecting: String?)
}

/// A row's syntax, with its marks told apart from its content so that they
/// can be dimmed as in the Editor's source.
struct MarkedSyntax: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let text: String
        let isMark: Bool
    }

    let segments: [Segment]

    /// Marks are written between ⟦ and ⟧: `"⟦**⟧texte⟦**⟧"`.
    init(_ marked: String) {
        var segments: [Segment] = []
        var rest = Substring(marked)
        while let open = rest.firstIndex(of: "⟦") {
            if open > rest.startIndex { segments.append(Segment(text: String(rest[..<open]), isMark: false)) }
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "⟧") else {
                rest = rest[afterOpen...]
                break
            }
            segments.append(Segment(text: String(rest[afterOpen..<close]), isMark: true))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { segments.append(Segment(text: String(rest), isMark: false)) }
        self.segments = segments
    }

    /// The Markdown as typed.
    var plain: String { segments.map(\.text).joined() }
}

/// A row of the cheat sheet.
struct CheatSheetEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let syntax: MarkedSyntax
    /// A short note under the rendered example.
    var hint: String?
    /// Nothing to insert (automatic typography): the row can only be copied.
    var snippet: MarkdownSnippet?
    /// Followed by the chips of the highlighted languages.
    var listsLanguages = false
}

/// A language whose code blocks the engine highlights, with the other names
/// it accepts after the backticks (the engine's `CodeLanguage`).
struct CheatSheetLanguage: Identifiable, Equatable, Sendable {
    let name: String
    let aliases: [String]

    var id: String { name }

    static let all: [CheatSheetLanguage] = [
        .init(name: "bash", aliases: ["sh", "zsh", "shell"]),
        .init(name: "c", aliases: []),
        .init(name: "c++", aliases: ["cpp", "cc", "cxx", "h", "hpp"]),
        .init(name: "css", aliases: []),
        .init(name: "go", aliases: ["golang"]),
        .init(name: "html", aliases: ["htm"]),
        .init(name: "javascript", aliases: ["js", "mjs", "cjs", "jsx"]),
        .init(name: "json", aliases: ["jsonc"]),
        .init(name: "php", aliases: []),
        .init(name: "python", aliases: ["py"]),
        .init(name: "rust", aliases: ["rs"]),
        .init(name: "sql", aliases: []),
        .init(name: "swift", aliases: []),
        .init(name: "typescript", aliases: ["ts", "tsx"]),
        .init(name: "xml", aliases: []),
        .init(name: "yaml", aliases: ["yml"]),
    ]
}

/// What a click, a double-click or a row's button acts on: a row, or one of
/// the language chips.
enum CheatSheetItem: Equatable, Sendable {
    case entry(CheatSheetEntry)
    case language(CheatSheetLanguage)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .language(let language): "language." + language.name
        }
    }

    var snippet: MarkdownSnippet? {
        switch self {
        case .entry(let entry): entry.snippet
        case .language(let language): .block(Self.fencedCode(language.name), selecting: CheatSheetWords.code)
        }
    }

    /// The Markdown that « Copier » puts on the pasteboard.
    var copiedText: String {
        switch self {
        case .entry(let entry): entry.syntax.plain
        case .language(let language): Self.fencedCode(language.name)
        }
    }

    private static func fencedCode(_ language: String) -> String {
        "```\(language)\n\(CheatSheetWords.code)\n```"
    }
}

/// One thing the engine does not render, for the short closing note.
struct CheatSheetUnsupported: Identifiable, Sendable {
    let name: String
    let syntax: String?
    let detail: String

    var id: String { name }
}

/// The words of the examples and of the inserted placeholders.
enum CheatSheetWords {
    static var text: String { String(localized: "texte", comment: "Markdown cheat sheet: placeholder word in examples and insertions.") }
    static var code: String { String(localized: "code", comment: "Markdown cheat sheet: placeholder for code.") }
    static var heading: String { String(localized: "Titre", comment: "Markdown cheat sheet: placeholder heading.") }
    static var item: String { String(localized: "élément", comment: "Markdown cheat sheet: placeholder list item.") }
    static var column: String { String(localized: "Colonne", comment: "Markdown cheat sheet: placeholder table header.") }
    static var value: String { String(localized: "Valeur", comment: "Markdown cheat sheet: placeholder table cell.") }
}

/// The seven sections of the cheat sheet, in the order of the sidebar.
enum CheatSheetSection: String, CaseIterable, Identifiable, Sendable {
    case text, headings, lists, links, code, tables, quotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: String(localized: "Texte", comment: "Markdown cheat sheet section.")
        case .headings: String(localized: "Titres", comment: "Markdown cheat sheet section.")
        case .lists: String(localized: "Listes", comment: "Markdown cheat sheet section.")
        case .links: String(localized: "Liens et images", comment: "Markdown cheat sheet section.")
        case .code: String(localized: "Code", comment: "Markdown cheat sheet section.")
        case .tables: String(localized: "Tableaux", comment: "Markdown cheat sheet section.")
        case .quotes: String(localized: "Citations et séparateurs", comment: "Markdown cheat sheet section.")
        }
    }

    var entries: [CheatSheetEntry] {
        let w = CheatSheetWords.self
        switch self {
        case .text:
            return [
                inline("italic", String(localized: "Italique"), "*", w.text),
                inline("bold", String(localized: "Gras"), "**", w.text),
                inline("bold-italic", String(localized: "Gras italique"), "***", w.text),
                inline("strikethrough", String(localized: "Barré"), "~~", w.text),
                inline("inline-code", String(localized: "Code en ligne"), "`", w.code),
                CheatSheetEntry(id: "line-break", name: String(localized: "Saut de ligne"),
                                syntax: MarkedSyntax(String(localized: "fin de ligne") + "⟦\\⟧\n" + String(localized: "suite")),
                                hint: String(localized: "ou deux espaces en fin de ligne"),
                                snippet: .text("\\\n")),
                CheatSheetEntry(id: "escape", name: String(localized: "Échappement"),
                                syntax: MarkedSyntax("⟦\\⟧*" + String(localized: "pas d'italique") + "⟦\\⟧*"),
                                snippet: .inline(prefix: "\\", suffix: "", placeholder: "*")),
                CheatSheetEntry(id: "typography", name: String(localized: "Typographie"),
                                syntax: MarkedSyntax("\"" + String(localized: "oui") + "\" -- 3..."),
                                hint: String(localized: "automatique ; les « » se tapent directement")),
            ]
        case .headings:
            return [
                heading(1, String(localized: "Titre 1")),
                heading(2, String(localized: "Titre 2")),
                heading(3, String(localized: "Titre 3")),
                heading(4, String(localized: "Titres 4 à 6"), hint: String(localized: "jusqu'à ######")),
                CheatSheetEntry(id: "setext-heading", name: String(localized: "Titre souligné"),
                                syntax: MarkedSyntax(w.heading + "\n⟦=====⟧"),
                                hint: String(localized: "--- pour un titre 2"),
                                snippet: .block(w.heading + "\n=====", selecting: w.heading)),
            ]
        case .lists:
            return [
                CheatSheetEntry(id: "bullet-list", name: String(localized: "À puces"),
                                syntax: MarkedSyntax("⟦- ⟧" + String(localized: "baobab") + "\n⟦- ⟧" + String(localized: "tamarinier")),
                                snippet: .block("- \(w.item)\n- \(w.item)", selecting: w.item)),
                CheatSheetEntry(id: "ordered-list", name: String(localized: "Numérotée"),
                                syntax: MarkedSyntax("⟦1. ⟧" + String(localized: "départ") + "\n⟦2. ⟧" + String(localized: "arrivée")),
                                snippet: .block("1. \(w.item)\n2. \(w.item)", selecting: w.item)),
                CheatSheetEntry(id: "ordered-list-start", name: String(localized: "Départ choisi"),
                                syntax: MarkedSyntax("⟦3. ⟧" + String(localized: "troisième") + "\n⟦4. ⟧" + String(localized: "quatrième")),
                                snippet: .block("3. \(w.item)\n4. \(w.item)", selecting: w.item)),
                CheatSheetEntry(id: "nested-list", name: String(localized: "Imbriquée"),
                                syntax: MarkedSyntax("⟦- ⟧" + String(localized: "arbres") + "\n⟦  - ⟧" + String(localized: "baobab")),
                                snippet: .block("- \(w.item)\n  - \(w.item)", selecting: w.item)),
                CheatSheetEntry(id: "task-list", name: String(localized: "Tâches"),
                                syntax: MarkedSyntax("⟦- [ ] ⟧" + String(localized: "à faire") + "\n⟦- [x] ⟧" + String(localized: "fait")),
                                snippet: .block("- [ ] \(w.item)\n- [x] \(w.item)", selecting: w.item)),
            ]
        case .links:
            let address = "https://exemple.org"
            return [
                CheatSheetEntry(id: "link", name: String(localized: "Lien"),
                                syntax: MarkedSyntax("⟦[⟧\(w.text)⟦](⟧\(address)⟦)⟧"),
                                snippet: .link(prefix: "[", text: w.text, url: "https://")),
                CheatSheetEntry(id: "autolink", name: String(localized: "Adresse"),
                                syntax: MarkedSyntax("⟦<⟧\(address)⟦>⟧"),
                                hint: String(localized: "entre chevrons, sinon pas de lien"),
                                snippet: .inline(prefix: "<", suffix: ">", placeholder: "https://")),
                CheatSheetEntry(id: "heading-link", name: String(localized: "Vers un titre"),
                                syntax: MarkedSyntax("⟦[⟧" + String(localized: "Accès") + "⟦](⟧#" + String(localized: "accès") + "⟦)⟧"),
                                hint: String(localized: "fait défiler jusqu'au titre"),
                                snippet: .link(prefix: "[", text: w.text, url: "#" + String(localized: "titre"))),
                CheatSheetEntry(id: "file-link", name: String(localized: "Vers un fichier"),
                                syntax: MarkedSyntax("⟦[⟧" + String(localized: "Guide") + "⟦](⟧" + String(localized: "docs/guide.md") + "⟦)⟧"),
                                snippet: .link(prefix: "[", text: w.text, url: String(localized: "fichier.md"))),
                CheatSheetEntry(id: "reference-link", name: String(localized: "Lien de référence"),
                                syntax: MarkedSyntax("⟦[⟧\(w.text)⟦][⟧1⟦]⟧\n\n⟦[1]: ⟧\(address)"),
                                snippet: .block("[\(w.text)][1]\n\n[1]: https://", selecting: w.text)),
                CheatSheetEntry(id: "image", name: String(localized: "Image"),
                                syntax: MarkedSyntax("⟦![⟧" + String(localized: "Plan") + "⟦](⟧" + String(localized: "images/plan.png") + "⟦)⟧"),
                                hint: String(localized: "fichier local, chemin relatif ou absolu"),
                                snippet: .link(prefix: "![", text: String(localized: "description"),
                                               url: String(localized: "image.png"))),
            ]
        case .code:
            let language = String(localized: "langage", comment: "Markdown cheat sheet: placeholder for a code block's language.")
            return [
                CheatSheetEntry(id: "fenced-code", name: String(localized: "Bloc de code"),
                                syntax: MarkedSyntax("⟦```⟧swift\nlet n = 3\n⟦```⟧"),
                                snippet: .block("```\(language)\n\(w.code)\n```", selecting: language),
                                listsLanguages: true),
                CheatSheetEntry(id: "plain-code", name: String(localized: "Sans langage"),
                                syntax: MarkedSyntax("⟦```⟧\n" + String(localized: "texte brut") + "\n⟦```⟧"),
                                hint: String(localized: "ou ~~~ à la place de ```"),
                                snippet: .block("```\n\(w.code)\n```", selecting: w.code)),
                CheatSheetEntry(id: "indented-code", name: String(localized: "Indenté"),
                                syntax: MarkedSyntax("⟦    ⟧" + String(localized: "texte brut")),
                                hint: String(localized: "4 espaces, sans coloration"),
                                snippet: .block("    \(w.code)", selecting: w.code)),
            ]
        case .tables:
            let (left, center, right) = (String(localized: "gauche"), String(localized: "centre"), String(localized: "droite"))
            return [
                CheatSheetEntry(id: "table", name: String(localized: "Tableau"),
                                syntax: MarkedSyntax("⟦| ⟧" + String(localized: "Lieu") + "⟦ | ⟧" + String(localized: "Km")
                                                     + "⟦ |⟧\n⟦| --- | --- |⟧\n⟦| ⟧" + String(localized: "Ponton") + "⟦ | ⟧2⟦ |⟧"),
                                hint: String(localized: "mise en forme possible dans les cellules"),
                                snippet: .block("| \(w.column) | \(w.column) |\n| ------- | ------- |\n| \(w.value) | \(w.value) |",
                                                selecting: w.column)),
                CheatSheetEntry(id: "table-alignment", name: String(localized: "Alignement"),
                                syntax: MarkedSyntax("⟦| ⟧\(left)⟦ | ⟧\(center)⟦ | ⟧\(right)⟦ |⟧\n⟦|:--- |:---:| ---:|⟧"),
                                snippet: .block("| \(w.column) | \(w.column) | \(w.column) |\n| :--- | :---: | ---: |\n"
                                                + "| \(w.value) | \(w.value) | \(w.value) |", selecting: w.column)),
            ]
        case .quotes:
            let quoted = String(localized: "texte cité")
            let (first, second) = (String(localized: "premier niveau"), String(localized: "second"))
            return [
                CheatSheetEntry(id: "quote", name: String(localized: "Citation"),
                                syntax: MarkedSyntax("⟦> ⟧\(quoted)"),
                                snippet: .block("> \(quoted)", selecting: quoted)),
                CheatSheetEntry(id: "nested-quote", name: String(localized: "Imbriquée"),
                                syntax: MarkedSyntax("⟦> ⟧\(first)\n⟦>> ⟧\(second)"),
                                snippet: .block("> \(first)\n>> \(second)", selecting: first)),
                CheatSheetEntry(id: "rule", name: String(localized: "Séparateur"),
                                syntax: MarkedSyntax("⟦---⟧"),
                                hint: String(localized: "ou *** et ___"),
                                snippet: .block("---", selecting: nil)),
            ]
        }
    }

    private func inline(_ id: String, _ name: String, _ mark: String, _ placeholder: String) -> CheatSheetEntry {
        CheatSheetEntry(id: id, name: name, syntax: MarkedSyntax("⟦\(mark)⟧\(placeholder)⟦\(mark)⟧"),
                        snippet: .inline(prefix: mark, suffix: mark, placeholder: placeholder))
    }

    private func heading(_ level: Int, _ name: String, hint: String? = nil) -> CheatSheetEntry {
        let marks = String(repeating: "#", count: level) + " "
        let title = CheatSheetWords.heading
        return CheatSheetEntry(id: "heading-\(level)", name: name, syntax: MarkedSyntax("⟦\(marks)⟧\(title)"), hint: hint,
                               snippet: .block(marks + title, selecting: title))
    }

    /// What the engine leaves aside, one line each.
    static var unsupported: [CheatSheetUnsupported] {
        [
            .init(name: String(localized: "Notes de bas de page"), syntax: "[^1]", detail: String(localized: "restent du texte")),
            .init(name: String(localized: "Adresses nues"), syntax: "https://…",
                  detail: String(localized: "pas de lien sans les chevrons < >")),
            .init(name: String(localized: "HTML"), syntax: "<br> <kbd>",
                  detail: String(localized: "affiché tel quel, jamais interprété")),
            .init(name: String(localized: "Images distantes"), syntax: "![…](https://…)",
                  detail: String(localized: "pas téléchargées : une icône et le texte alternatif")),
            .init(name: String(localized: "Formules et diagrammes"), syntax: "$…$ mermaid",
                  detail: String(localized: "affichés comme du texte ou du code")),
            .init(name: String(localized: "Surlignage, indice, exposant, emoji"), syntax: "==…== :nom:",
                  detail: String(localized: "restent du texte")),
            .init(name: String(localized: "Encadrés"), syntax: "> [!NOTE]",
                  detail: String(localized: "affichés comme une citation ordinaire")),
            .init(name: String(localized: "Listes de définitions, identifiants de titre, fusion de cellules"), syntax: "{#id}",
                  detail: String(localized: "non reconnus")),
        ]
    }
}

/// The rows matching a search, by section; every row without a query.
enum CheatSheetSearch {
    struct Result: Identifiable {
        let section: CheatSheetSection
        let entries: [CheatSheetEntry]

        var id: CheatSheetSection { section }
    }

    static func results(for query: String) -> [Result] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return CheatSheetSection.allCases.compactMap { section in
            let entries = section.entries.filter { matches($0, query: query) }
            return entries.isEmpty ? nil : Result(section: section, entries: entries)
        }
    }

    static func matches(_ entry: CheatSheetEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entry.name.range(of: query, options: options) != nil
            || entry.syntax.plain.range(of: query, options: options) != nil
            || (entry.listsLanguages && CheatSheetLanguage.all.contains { language in
                ([language.name] + language.aliases).contains { $0.range(of: query, options: options) != nil }
            })
    }
}

// MARK: - Actions

/// What a row's button and a double-click do, set by each app.
struct CheatSheetAction {
    /// What the action did, for the sheet to react.
    enum Outcome {
        /// The sheet closes (inserted in the Editor).
        case close
        /// The syntax was copied: the sheet stays and says so.
        case copied
    }

    let title: Text
    let systemImage: String
    /// The line at the left of the bottom bar.
    let hint: Text
    let isEnabled: @MainActor (CheatSheetItem) -> Bool
    let perform: @MainActor (CheatSheetItem) -> Outcome
}

/// Copies a row's syntax.
@MainActor
enum CheatSheetPasteboard {
    static func copy(_ item: CheatSheetItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.copiedText, forType: .string)
    }

    /// The copy action, as the Viewer offers it on every row.
    static var copyAction: CheatSheetAction {
        CheatSheetAction(title: Text("Copier"), systemImage: "doc.on.doc",
                         hint: Text("Double-clic : copier la syntaxe"),
                         isEnabled: { _ in true },
                         perform: { item in
                             copy(item)
                             return .copied
                         })
    }
}

// MARK: - Sheet

/// The cheat sheet, as a sheet on a window: sections at the left with the
/// search field, the rows of the chosen section (or of the search) at the
/// right, « Copier » and « Terminé » at the bottom.
struct MarkdownCheatSheet: View {
    /// The app's theme; the examples are drawn with it, at a smaller size.
    let theme: Theme
    let action: CheatSheetAction
    let onDone: () -> Void

    @State private var section: CheatSheetSection? = .text
    @State private var query = ""
    @State private var selection: CheatSheetItem?
    @State private var showsCopied = false
    @State private var copiedGeneration = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.softAccent) private var accent

    static let size = CGSize(width: 780, height: 540)

    init(theme: Theme, action: CheatSheetAction, onDone: @escaping () -> Void, initialSection: CheatSheetSection? = .text) {
        self.theme = theme
        self.action = action
        self.onDone = onDone
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Aide-mémoire Markdown")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SoftColor.label)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .accessibilityAddTraits(.isHeader)
            SoftColor.hairline.frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                SoftColor.hairline.frame(width: 1)
                content
            }
            SoftColor.hairline.frame(height: 1)
            bottomBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(SoftColor.group)
        .onAppear { searchFocused = true }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            searchField
                .padding(.bottom, 8)
            ForEach(CheatSheetSection.allCases) { item in
                sidebarButton(Text(item.title), count: count(of: item), isOn: query.isEmpty && section == item) {
                    query = ""
                    section = item
                }
            }
            Spacer(minLength: 8)
            sidebarButton(Text("Non pris en charge"), count: nil, isOn: query.isEmpty && section == nil, secondary: true) {
                query = ""
                section = nil
            }
        }
        .padding(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
        .frame(width: 204)
        .background(SoftColor.chrome)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SoftColor.iconIdle)
            TextField(text: $query, prompt: Text("Rechercher")) {
                Text("Rechercher dans l'aide-mémoire")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SoftColor.iconIdle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Effacer la recherche"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(SoftTrack(cornerRadius: 7))
    }

    private func count(of section: CheatSheetSection) -> Int {
        section.entries.count { CheatSheetSearch.matches($0, query: query) }
    }

    private func sidebarButton(_ title: Text, count: Int?, isOn: Bool, secondary: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                title
                    .font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(secondary && !isOn ? SoftColor.secondaryLabel : SoftColor.label)
                Spacer(minLength: 4)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(SoftColor.secondaryLabel)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(isOn: isOn, accent: accent))
        .opacity(count == 0 ? 0.45 : 1)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private struct SidebarRowStyle: ButtonStyle {
        let isOn: Bool
        let accent: SoftAccent

        func makeBody(configuration: Configuration) -> some View {
            SidebarRowBody(configuration: configuration, isOn: isOn, accent: accent)
        }

        private struct SidebarRowBody: View {
            let configuration: ButtonStyleConfiguration
            let isOn: Bool
            let accent: SoftAccent
            @State private var isHovered = false

            var body: some View {
                configuration.label
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isOn ? accent.tint : configuration.isPressed ? SoftColor.pressed
                                  : isHovered ? SoftColor.hover : .clear)
                    }
                    .onHover { isHovered = $0 }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !query.isEmpty {
                    let results = CheatSheetSearch.results(for: query)
                    if results.isEmpty {
                        Text("Aucun résultat")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SoftColor.secondaryLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(results) { result in
                        sectionHeader(Text(result.section.title), count: result.entries.count)
                        rows(result.entries)
                    }
                } else if let section {
                    sectionHeader(Text(section.title), count: nil)
                    rows(section.entries)
                } else {
                    sectionHeader(Text("Non pris en charge"), count: nil)
                    unsupportedList
                }
            }
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoftColor.group)
    }

    private func sectionHeader(_ title: Text, count: Int?) -> some View {
        HStack(spacing: 6) {
            title
            if let count {
                Text(verbatim: "\(count)").fontWeight(.regular).foregroundStyle(SoftColor.secondaryLabel)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(SoftColor.secondaryLabel)
        .padding(EdgeInsets(top: 10, leading: 6, bottom: 4, trailing: 6))
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ entries: [CheatSheetEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 {
                SoftColor.hairline.frame(height: 1).padding(.horizontal, 6)
            }
            CheatSheetRow(entry: entry, theme: rowTheme, action: action,
                          isSelected: selection == .entry(entry),
                          onSelect: { selection = .entry(entry) },
                          onPerform: { perform(.entry(entry)) },
                          onCopy: { copy(.entry(entry)) })
            if entry.listsLanguages {
                CheatSheetLanguageChips(action: action, selection: selection,
                                        onSelect: { selection = $0 },
                                        onPerform: { perform($0) },
                                        onCopy: { copy($0) })
            }
        }
    }

    private var unsupportedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CheatSheetSection.unsupported) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SoftColor.label)
                        if let syntax = item.syntax {
                            Text(verbatim: syntax)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(SoftColor.secondaryLabel)
                        }
                    }
                    .frame(width: 250, alignment: .leading)
                    Text(item.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(SoftColor.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
                SoftColor.hairline.frame(height: 1).padding(.horizontal, 6)
            }
            Text("Un langage inconnu après ``` donne un bloc de code avec son étiquette, sans coloration.")
                .font(.system(size: 11.5))
                .foregroundStyle(SoftColor.secondaryLabel)
                .padding(EdgeInsets(top: 10, leading: 6, bottom: 0, trailing: 6))
        }
    }

    /// The example theme: the app's, scaled to the sheet's size, with small
    /// margins and no column limit.
    private var rowTheme: Theme {
        theme.cheatSheetScaled(toBodySize: 13)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Group {
                if showsCopied {
                    Label("Copié dans le presse-papiers", systemImage: "checkmark")
                        .foregroundStyle(accent.text)
                } else {
                    action.hint
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(SoftColor.secondaryLabel)
            .lineLimit(1)
            Spacer()
            Button("Copier") {
                if let selection { copy(selection) }
            }
            .disabled(selection == nil)
            Button("Terminé", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(SoftColor.chrome)
        .background {
            // Escape closes the sheet as « Terminé » does.
            Button("Fermer", action: onDone)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private func perform(_ item: CheatSheetItem) {
        selection = item
        // Nothing to insert, or nowhere to insert it: the syntax is copied.
        guard action.isEnabled(item) else { return copy(item) }
        switch action.perform(item) {
        case .close: onDone()
        case .copied: flashCopied()
        }
    }

    private func copy(_ item: CheatSheetItem) {
        selection = item
        CheatSheetPasteboard.copy(item)
        flashCopied()
    }

    private func flashCopied() {
        copiedGeneration += 1
        let generation = copiedGeneration
        showsCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if copiedGeneration == generation { showsCopied = false }
        }
    }
}

/// A row: name, syntax with its marks dimmed, the rendered example; on hover,
/// the row's action as a pale tinted button. Click selects, double-click acts,
/// ⌥-click copies.
private struct CheatSheetRow: View {
    let entry: CheatSheetEntry
    let theme: Theme
    let action: CheatSheetAction
    let isSelected: Bool
    let onSelect: () -> Void
    let onPerform: () -> Void
    let onCopy: () -> Void

    @State private var isHovered = false
    @Environment(\.softAccent) private var accent

    var body: some View {
        let enabled = action.isEnabled(.entry(entry))
        HStack(alignment: .top, spacing: 12) {
            Text(entry.name)
                .font(.system(size: 11.5))
                .foregroundStyle(SoftColor.secondaryLabel)
                .frame(width: 86, alignment: .leading)
                .padding(.top, 2)
            CheatSheetSyntaxText(syntax: entry.syntax)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                CheatSheetExample(markdown: entry.syntax.plain, theme: theme)
                if let hint = entry.hint {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SoftColor.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 7, leading: 6, bottom: 7, trailing: 6))
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? accent.tint.opacity(0.6) : isHovered ? SoftColor.hover : .clear)
        }
        .overlay(alignment: .topTrailing) {
            if isHovered, enabled {
                Button(action: onPerform) {
                    Label { action.title } icon: { Image(systemName: action.systemImage) }
                }
                .buttonStyle(SoftTintedButtonStyle(accent: accent))
                .padding(.top, 5)
                .padding(.trailing, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            if NSEvent.modifierFlags.contains(.option) { onCopy() } else { onPerform() }
        }.exclusively(before: TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.option) { onCopy() } else { onSelect() }
        }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.name))
        .accessibilityValue(Text(verbatim: entry.syntax.plain))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { enabled ? onPerform() : onCopy() }
        .accessibilityAction(named: Text("Copier"), onCopy)
    }
}

/// The syntax in the source's monospaced face, marks dimmed.
private struct CheatSheetSyntaxText: View {
    let syntax: MarkedSyntax

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in syntax.segments {
            var part = AttributedString(segment.text)
            part.foregroundColor = segment.isMark ? SoftColor.secondaryLabel : SoftColor.label
            result += part
        }
        return result
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.disabled)
    }
}

/// The languages under « Bloc de code »: one chip each, its aliases
/// on hover; acting on a chip inserts or copies a block of that language.
private struct CheatSheetLanguageChips: View {
    let action: CheatSheetAction
    let selection: CheatSheetItem?
    let onSelect: (CheatSheetItem) -> Void
    let onPerform: (CheatSheetItem) -> Void
    let onCopy: (CheatSheetItem) -> Void

    @State private var hovered: String?
    @Environment(\.softAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(CheatSheetLanguage.all.count) langages colorés")
                .font(.system(size: 11.5))
                .foregroundStyle(SoftColor.secondaryLabel)
                .frame(width: 86, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                ChipFlow(spacing: 4) {
                    ForEach(CheatSheetLanguage.all) { language in
                        chip(language)
                    }
                }
                Text("Langage inconnu : bloc avec son étiquette, sans coloration.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SoftColor.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 8, trailing: 6))
    }

    private func chip(_ language: CheatSheetLanguage) -> some View {
        let item = CheatSheetItem.language(language)
        let isHovered = hovered == language.name
        let isSelected = selection == item
        return Button {
            if NSEvent.modifierFlags.contains(.option) { onCopy(item) } else { onPerform(item) }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: language.name)
                    .foregroundStyle(SoftColor.label)
                if isHovered, !language.aliases.isEmpty {
                    Text(verbatim: language.aliases.joined(separator: ", "))
                        .foregroundStyle(SoftColor.secondaryLabel)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? SoftColor.pressed : SoftColor.track)
            }
            .overlay {
                if isSelected || isHovered {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(accent.icon, lineWidth: 1.2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? language.name : (hovered == language.name ? nil : hovered) }
        .help(language.aliases.isEmpty ? Text(verbatim: language.name)
              : Text("Aussi : \(language.aliases.joined(separator: ", "))"))
        .accessibilityLabel(Text(verbatim: language.name))
        .accessibilityHint(language.aliases.isEmpty ? Text(verbatim: "")
                           : Text("Aussi : \(language.aliases.joined(separator: ", "))"))
        .accessibilityAction(named: Text("Copier")) { onCopy(item) }
    }
}

/// Lays chips out in lines, wrapping at the width offered.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Rendered example

extension Theme {
    /// The theme at a smaller body size (code and headings in proportion),
    /// with the spacing tightened for a row of the cheat sheet.
    func cheatSheetScaled(toBodySize size: CGFloat) -> Theme {
        var theme = self
        let factor = size / max(fontSize, 1)
        theme.fontSize = size
        theme.codeFontSize = (codeFontSize * factor * 2).rounded() / 2
        for level in Theme.HeadingStyles.levels {
            theme.headings[level: level].size = (headings[level: level].size * factor * 2).rounded() / 2
            theme.headings[level: level].spacingBefore = 0
        }
        theme.paragraphSpacing *= factor
        theme.blockSpacing = (blockSpacing * factor * 0.6).rounded()
        theme.listItemSpacing *= factor
        theme.listIndent *= factor
        theme.quoteIndent *= factor
        theme.codePadding = (codePadding * factor).rounded()
        theme.contentMargins = Theme.Margins(horizontal: 10, vertical: 10)
        theme.maxLineWidth = nil
        return theme
    }
}

/// A Markdown example drawn by KayakomaKit's `MarkdownView`, on a tile of the
/// theme's background, as tall as its content. It takes no clicks nor
/// scrolling: the row handles them.
private struct CheatSheetExample: View {
    let markdown: String
    let theme: Theme

    var body: some View {
        ExampleView(markdown: markdown, theme: theme)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SoftColor.hairline, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private struct ExampleView: NSViewRepresentable {
        let markdown: String
        let theme: Theme

        func makeNSView(context: Context) -> ExampleHost {
            ExampleHost()
        }

        func updateNSView(_ host: ExampleHost, context: Context) {
            host.show(markdown, theme: theme)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView host: ExampleHost, context: Context) -> CGSize? {
            let width = max(proposal.width ?? 260, 60)
            host.show(markdown, theme: theme)
            return CGSize(width: width, height: host.contentHeight(forWidth: width))
        }
    }

    /// Holds the `MarkdownView` and measures it; lets every event through to
    /// the row under it.
    final class ExampleHost: NSView {
        private let markdownView = MarkdownView()
        private var heights: [CGFloat: CGFloat] = [:]

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            markdownView.frame = bounds
            markdownView.autoresizingMask = [.width, .height]
            markdownView.showsVerticalScroller = false
            addSubview(markdownView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(_ markdown: String, theme: Theme) {
            if markdownView.theme != theme {
                markdownView.theme = theme
                heights.removeAll()
            }
            if markdownView.document?.source != markdown {
                markdownView.document = RenderedDocument(source: markdown)
                heights.removeAll()
            }
        }

        /// Height of the rendered example at a width, margins included.
        func contentHeight(forWidth width: CGFloat) -> CGFloat {
            if let height = heights[width] { return height }
            let height = Self.measure(markdownView.document?.source ?? "", theme: markdownView.theme, width: width)
            heights[width] = height
            return height
        }

        /// The last block of a document is followed by an empty line whose
        /// height depends on that block: the example is measured with a short
        /// paragraph after it, down to the top of that paragraph, less the
        /// space the engine leaves after the last block.
        private static func measure(_ markdown: String, theme: Theme, width: CGFloat) -> CGFloat {
            let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: width, height: 4000))
            view.showsVerticalScroller = false
            view.theme = theme
            view.document = RenderedDocument(source: markdown + "\n\nx\n")
            view.layoutSubtreeIfNeeded()
            guard let blocks = view.document?.blocks, blocks.count >= 2,
                  let first = view.frame(ofBlockAt: 0), let sentinel = view.frame(ofBlockAt: blocks.count - 1) else {
                return 40
            }
            let top = view.isFlipped ? first.minY : first.maxY
            let sentinelTop = view.isFlipped ? sentinel.minY : sentinel.maxY
            let last = blocks[blocks.count - 2].kind
            let spacingAfter = last == .paragraph ? theme.paragraphSpacing : theme.blockSpacing
            let content = abs(top - sentinelTop) - spacingAfter
            return ceil(max(content, 0) + theme.contentMargins.vertical * 2)
        }
    }
}
