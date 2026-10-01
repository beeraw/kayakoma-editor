import AppKit
import SwiftUI

/// The quick open palette, at the top of the editing area: recent files
/// first, then approximate matching on the path. ↑↓ choose, ↩ opens (or shows
/// the open tab), ⌘↩ opens in the background, ⎋ closes.
struct QuickOpenPalette: View {
    let session: FolderSession

    @State private var query: String
    @State private var selection = 0

    init(session: FolderSession, query: String = "") {
        self.session = session
        _query = State(initialValue: query)
    }
    @Environment(\.colorScheme) private var colorScheme

    private static let rowLimit = 60

    private var results: [FuzzyMatcher.Result] {
        Array(FuzzyMatcher.rank(session.documentPaths, query: query, recents: session.recentPaths).prefix(Self.rowLimit))
    }

    var body: some View {
        let results = results
        let recentCount = query.isEmpty ? session.recentPaths.filter(Set(session.documentPaths).contains).count : 0
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(SoftColor.iconIdle)
                    .accessibilityHidden(true)
                PaletteField(text: $query,
                             placeholder: String(localized: "Ouvrir un fichier de « \(session.folderName) »"),
                             onMove: { move(by: $0, count: results.count) },
                             onSubmit: { background in open(results, background: background) },
                             onCancel: close)
                ShortcutBadge(text: "⇧⌘O")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            SoftColor.hairline.frame(height: 1)
            if results.isEmpty {
                Text("Aucun fichier ne correspond")
                    .font(.system(size: 12))
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.path) { index, result in
                                if query.isEmpty, index == 0, recentCount > 0 { sectionHeader(Text("Récents")) }
                                if query.isEmpty, index == recentCount { sectionHeader(Text("Dossier")) }
                                row(result, index: index)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { _, index in proxy.scrollTo(index) }
                }
            }
            SoftColor.hairline.frame(height: 1)
            footer(count: results.count)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .soft(light: 0xFFFFFF, dark: 0x2A2A2A)))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 18, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SoftColor.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 520)
        .onChange(of: query) { _, _ in selection = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Ouverture rapide"))
    }

    private func sectionHeader(_ title: Text) -> some View {
        title
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SoftColor.secondaryLabel)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ result: FuzzyMatcher.Result, index: Int) -> some View {
        let isSelected = index == selection
        let path = result.path
        let nameStart = path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 } ?? 0
        let name = String(path.dropFirst(nameStart))
        let folder = nameStart > 0 ? String(path.prefix(nameStart - 1)).replacingOccurrences(of: "/", with: " › ") : ""
        let isOpen = session.rootURL.flatMap { session.tab(for: $0.appending(path: path)) } != nil
        return HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(SoftAccent.coral.icon)
                .accessibilityHidden(true)
            highlighted(name, positions: Set(result.positions.filter { $0 >= nameStart }.map { $0 - nameStart }))
                .font(.system(size: 12.5))
                .foregroundStyle(SoftColor.label)
                .lineLimit(1)
            if !folder.isEmpty {
                Text(verbatim: folder)
                    .font(.system(size: 11))
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            if isOpen {
                Text("Ouvert")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SoftColor.track))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SoftAccent.coral.tint)
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { openPath(path, background: false) }
        .onHover { if $0 { selection = index } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { openPath(path, background: false) }
    }

    /// The name with the matched letters bold and underlined.
    private func highlighted(_ name: String, positions: Set<Int>) -> Text {
        var attributed = AttributedString(name)
        for (offset, index) in zip(0..., attributed.characters.indices) where positions.contains(offset) {
            let range = index..<attributed.characters.index(after: index)
            attributed[range].font = .system(size: 12.5, weight: .bold)
            attributed[range].underlineStyle = .single
        }
        return Text(attributed)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 14) {
            if query.isEmpty { hint("↑↓", Text("choisir")) }
            hint("↩", Text("ouvrir"))
            hint("⌘↩", Text("en arrière-plan"))
            hint("⎋", Text("fermer"))
            Spacer()
            if !query.isEmpty {
                Text("\(count) fichiers")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(SoftColor.secondaryLabel)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func hint(_ keys: String, _ label: Text) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: keys)
            label
        }
    }

    private func move(by offset: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + offset, 0), count - 1)
    }

    private func open(_ results: [FuzzyMatcher.Result], background: Bool) {
        guard results.indices.contains(selection) else { return }
        openPath(results[selection].path, background: background)
    }

    private func openPath(_ path: String, background: Bool) {
        guard let root = session.rootURL else { return }
        if !background { close() }
        session.open(root.appending(path: path), inBackground: background, focusEditor: !background)
    }

    private func close() {
        session.isQuickOpenShown = false
    }
}

/// A key shortcut drawn as a small grey badge (« ⇧⌘O »).
struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(SoftColor.secondaryLabel)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SoftColor.track))
            .accessibilityHidden(true)
    }
}

/// The palette's search field: an AppKit field, so that ↑↓, ↩, ⌘↩ and ⎋
/// reach the palette instead of moving the caret.
struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: (_ background: Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(placeholder)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField

        init(_ parent: PaletteField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                parent.onSubmit(command)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case Selector(("noop:")):
                // ⌘↩ arrives as a no-op.
                guard let event = NSApp.currentEvent, event.keyCode == 36 || event.keyCode == 76 else { return false }
                parent.onSubmit(true)
            default:
                return false
            }
            return true
        }
    }
}
