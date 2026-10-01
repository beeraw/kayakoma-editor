import SwiftUI

/// The tab bar of a folder window: tabs on a grey rail, the current
/// one on the white pill; a modified tab shows a dot in place of its ×.
/// Tabs reorder by dragging; + opens the quick open palette.
struct FolderTabStrip: View {
    let session: FolderSession

    @State private var frames: [UUID: CGRect] = [:]
    @State private var dragging: UUID?
    @State private var dragStart: CGRect = .zero
    @State private var dragTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SoftMetrics.segmentGap) {
                        ForEach(session.tabs.items) { tab in
                            tabView(tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, SoftMetrics.trackInset)
                    .frame(height: SoftMetrics.trackHeight)
                    .background(SoftTrack())
                    .coordinateSpace(name: "tabs")
                    .onPreferenceChange(TabFramesKey.self) { frames = $0 }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: session.tabs.currentID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            .layoutPriority(1)
            Button {
                session.isQuickOpenShown = true
            } label: {
                Label("Ouvrir rapidement", systemImage: "plus")
            }
            .buttonStyle(SoftIconButtonStyle(size: CGSize(width: 24, height: 24), idleColor: SoftColor.iconIdle))
            .help("Ouvrir rapidement un fichier du dossier (⇧⌘O)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(SoftColor.chrome)
        .overlay(alignment: .bottom) { SoftColor.hairline.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Onglets"))
    }

    private func tabView(_ tab: FolderTab) -> some View {
        let isCurrent = tab.id == session.tabs.currentID
        let isDragging = tab.id == dragging
        return FolderTabButton(tab: tab, isCurrent: isCurrent,
                               select: { session.select(tab) },
                               close: { session.close(tab) })
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named("tabs"))])
                }
            }
            .offset(x: isDragging ? dragOffset(for: tab) : 0)
            .zIndex(isDragging ? 1 : 0)
            .gesture(drag(tab))
            .contextMenu {
                Button("Fermer l'onglet") { session.close(tab) }
                Button("Fermer les autres onglets") {
                    for other in session.tabs.items where other.id != tab.id { session.close(other) }
                }
                .disabled(session.tabs.items.count < 2)
                Divider()
                Button("Afficher dans la barre latérale") {
                    session.isSidebarHidden = false
                    session.reveal(tab.url, select: true)
                }
                Button("Afficher dans le Finder") { session.revealInFinder(tab.url) }
            }
    }

    /// Where the dragged tab is drawn: under the pointer, whatever its slot.
    private func dragOffset(for tab: FolderTab) -> CGFloat {
        guard let frame = frames[tab.id] else { return 0 }
        return dragStart.minX + dragTranslation - frame.minX
    }

    private func drag(_ tab: FolderTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("tabs"))
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    dragStart = frames[tab.id] ?? .zero
                    session.select(tab)
                }
                dragTranslation = value.translation.width
                let centre = dragStart.midX + dragTranslation
                let others = session.tabs.items.filter { $0.id != tab.id }
                let target = others.filter { (frames[$0.id]?.midX ?? .infinity) < centre }.count
                if session.tabs.items.firstIndex(where: { $0.id == tab.id }) != target {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { session.move(tab, to: target) }
                }
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    dragging = nil
                    dragTranslation = 0
                }
            }
    }
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One tab: icon, name, and × (or the modified dot, which turns into × on hover).
struct FolderTabButton: View {
    let tab: FolderTab
    let isCurrent: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.softAccent) private var accent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(accent.icon.opacity(isCurrent ? 1 : 0.75))
                .accessibilityHidden(true)
            Text(verbatim: tab.name)
                .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                .foregroundStyle(isCurrent || isHovered ? SoftColor.iconSelected : SoftColor.iconIdle)
                .lineLimit(1)
                .truncationMode(.middle)
            closeButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(minWidth: 96, maxWidth: 200, minHeight: SoftMetrics.segmentHeight, maxHeight: SoftMetrics.segmentHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if isCurrent {
                SoftPill()
            } else if isHovered {
                RoundedRectangle(cornerRadius: SoftMetrics.segmentRadius, style: .continuous).fill(SoftColor.hover)
            }
        }
        .frame(height: SoftMetrics.trackHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .softFocusRing(isFocused, cornerRadius: SoftMetrics.segmentRadius, accent: accent)
        .onKeyPress(.space) { select(); return .handled }
        .onKeyPress(.return) { select(); return .handled }
        .help(Text(verbatim: tab.url.path(percentEncoded: false)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.isModified ? Text("\(tab.name), modifié") : Text(verbatim: tab.name))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: Text("Fermer l'onglet"), close)
    }

    @ViewBuilder private var closeButton: some View {
        let showsDot = tab.isModified && !isHovered
        Button(action: close) {
            ZStack {
                if showsDot {
                    Circle().fill(SoftColor.iconIdle).frame(width: 6, height: 6)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(isHovered || isCurrent ? 1 : 0)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(SoftIconButtonStyle(size: CGSize(width: 16, height: 16), idleColor: SoftColor.iconIdle))
        .focusable(false)
        .help("Fermer l'onglet (⌘W)")
        .accessibilityLabel(Text("Fermer l'onglet"))
    }
}
