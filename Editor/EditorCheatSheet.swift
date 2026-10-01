import AppKit
import KayakomaKit
import SwiftUI

private struct MarkdownCheatSheetKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    /// Shows the Markdown cheat sheet on the key window.
    var showMarkdownCheatSheet: (@MainActor () -> Void)? {
        get { self[MarkdownCheatSheetKey.self] }
        set { self[MarkdownCheatSheetKey.self] = newValue }
    }
}

/// The Help menu: the cheat sheet takes the place and the shortcut of
/// the app's help book, which Kayakoma does not have.
struct MarkdownHelpCommands: Commands {
    @FocusedValue(\.showMarkdownCheatSheet) private var showCheatSheet

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Aide-mémoire Markdown") { showCheatSheet?() }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(showCheatSheet == nil)
        }
    }
}

/// The cheat sheet of a document or folder window: rows insert into the
/// source of `model`, the file on display; without one (a folder window
/// with no tab open), they can only be copied.
struct EditorCheatSheet: View {
    let model: EditorModel?
    let theme: Theme
    @Binding var isPresented: Bool
    var initialSection: CheatSheetSection? = .text

    var body: some View {
        MarkdownCheatSheet(theme: theme, action: action, onDone: { isPresented = false }, initialSection: initialSection)
            .environment(\.softAccent, .coral)
    }

    private var action: CheatSheetAction {
        let model = model
        return CheatSheetAction(
            title: Text("Insérer"),
            systemImage: "text.insert",
            hint: model == nil
                ? Text("Aucun fichier ouvert : double-clic pour copier la syntaxe")
                : Text("Double-clic : insérer et fermer · ⌥ clic : copier"),
            isEnabled: { item in model != nil && item.snippet != nil },
            perform: { item in
                guard let model, let snippet = item.snippet else { return .copied }
                model.insert(snippet, actionName: item.undoName)
                return .close
            })
    }
}

private extension CheatSheetItem {
    /// « Annuler Gras »
    var undoName: String {
        switch self {
        case .entry(let entry): entry.name
        case .language(let language): language.name
        }
    }
}

extension EditorModel {
    /// Inserts a snippet of the cheat sheet into the source as one edit:
    /// it is undone in one step and rendered like typing. The source is
    /// shown first if only the preview was.
    func insert(_ snippet: MarkdownSnippet, actionName: String) {
        if layout == .preview { layout = .split }
        let view = panes.sourceView
        let edit = MarkdownInsertion(snippet: snippet, in: view.string, selection: view.selectedRange())
        view.apply(edit, actionName: actionName)
    }
}

extension SourceTextView {
    /// Applies an insertion as a single undoable change and selects what it
    /// leaves to fill in.
    func apply(_ edit: MarkdownInsertion, actionName: String) {
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement),
              let storage = textStorage else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        window?.makeFirstResponder(self)
    }
}
