import AppKit
import KayakomaKit
import SwiftUI

/// The update window: one window whose content follows the update. It opens
/// when the model has something to show and closes when it is done.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let model: UpdateModel
    private let accent: SoftAccent
    private let notesTheme: Theme
    private var window: NSWindow?

    init(model: UpdateModel, accent: SoftAccent, notesTheme: Theme) {
        self.model = model
        self.accent = accent
        self.notesTheme = notesTheme
        super.init()
        observe()
    }

    /// Brings the window forward, for a check asked while one is shown.
    func showInFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func observe() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if model.phase == nil {
            window?.delegate = nil
            window?.close()
            window = nil
        } else if window == nil {
            let window = makeWindow()
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let content = UpdateView(model: model, notesTheme: notesTheme)
            .environment(\.softAccent, accent)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Mise à jour")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.backgroundColor = NSColor(SoftColor.chrome)
        window.delegate = self
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Once installing has started, it can no longer be called off.
        model.phase != .preparing
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.windowClosed()
    }
}

/// The content of the update window for each state.
struct UpdateView: View {
    let model: UpdateModel
    let notesTheme: Theme

    @Environment(\.softAccent) private var accent

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ProcessInfo.processInfo.processName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
        }
        .padding(EdgeInsets(top: 30, leading: 22, bottom: 18, trailing: 22))
        .frame(width: isWide ? 560 : 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(SoftColor.chrome)
    }

    private var isWide: Bool {
        if case .found(let release) = model.phase, !release.notes.isEmpty { return true }
        return false
    }

    // MARK: Text

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            title(Text("Recherche de mises à jour…"))
            ProgressView().progressViewStyle(.linear).controlSize(.small).padding(.top, 8)
        case .found(let release):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                title(Text("\(appName) \(release.version) est disponible"))
                Text("vous avez \(model.currentVersion)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.tint))
                    .fixedSize()
            }
            subtitle(Text("Installation en quelques secondes ; l'appli se relance toute seule."))
            if !release.notes.isEmpty {
                ReleaseNotesView(markdown: release.notes, theme: notesTheme)
                    .frame(height: 178)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(SoftColor.hairline, lineWidth: 1)
                    }
                    .padding(.top, 12)
            }
        case .downloading(let received, let expected):
            title(Text("Téléchargement…"))
            if let expected {
                AccentProgressBar(fraction: Double(min(received, expected)) / Double(max(expected, 1)))
                    .padding(.vertical, 6)
                subtitle(Text("\(byteCount(received)) sur \(byteCount(expected))"))
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small).padding(.vertical, 6)
            }
        case .preparing:
            title(Text("Préparation de la mise à jour…"))
            ProgressView().progressViewStyle(.linear).controlSize(.small).padding(.top, 8)
        case .ready:
            title(Text("La mise à jour est prête"))
            subtitle(Text("L'appli se fermera, puis se relancera aussitôt."))
        case .upToDate:
            title(Text("\(appName) est à jour"))
            subtitle(Text("La version \(model.currentVersion) est la plus récente."))
        case .failed(let message):
            title(Text("La mise à jour n'a pas pu être installée"))
            subtitle(Text(message) + Text(verbatim: " ") + Text("Réessayez plus tard, ou téléchargez la version depuis la page des versions."))
        case nil:
            EmptyView()
        }
    }

    private func title(_ text: Text) -> some View {
        text.font(.system(size: 14, weight: .bold))
            .foregroundStyle(SoftColor.label)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    private func subtitle(_ text: Text) -> some View {
        text.font(.system(size: 12.5))
            .foregroundStyle(SoftColor.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file))
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .checking, .downloading:
                Spacer()
                Button("Annuler") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .found:
                Button("Ignorer cette version") { model.choose(.skip) }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .foregroundStyle(SoftColor.secondaryLabel)
                Spacer()
                Button("Plus tard") { model.choose(.later) }
                    .keyboardShortcut(.cancelAction)
                primary(Text("Installer et relancer"), systemImage: "arrow.down.circle") { model.choose(.install) }
            case .ready:
                Button("À la fermeture") { model.choose(.later) }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .foregroundStyle(SoftColor.secondaryLabel)
                    .help("Installer quand l'appli sera quittée")
                Spacer()
                primary(Text("Installer et relancer"), systemImage: "arrow.clockwise") { model.choose(.install) }
            case .upToDate:
                Spacer()
                primary(Text("OK"), systemImage: "checkmark") { model.acknowledge() }
            case .failed:
                if let url = model.releasesURL {
                    Button("Page des versions") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .foregroundStyle(SoftColor.secondaryLabel)
                }
                Spacer()
                Button("Fermer") { model.acknowledge() }
                    .keyboardShortcut(.cancelAction)
                primary(Text("Réessayer"), systemImage: "arrow.clockwise") { model.retry() }
            case .preparing, nil:
                EmptyView()
            }
        }
        .controlSize(.regular)
        .padding(.leading, 80)
    }

    private func primary(_ title: Text, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: systemImage) }
        }
        .buttonStyle(SoftTintedButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
    }
}

/// The release notes, Markdown rendered by the engine in a scrolling box.
struct ReleaseNotesView: NSViewRepresentable {
    let markdown: String
    let theme: Theme

    func makeNSView(context: Context) -> MarkdownView {
        let view = MarkdownView()
        view.onLinkClick = { click in
            NSWorkspace.shared.open(click.url)
            return true
        }
        return view
    }

    func updateNSView(_ view: MarkdownView, context: Context) {
        // Smaller than a document: the text of a dialog, headings in proportion.
        var theme = theme.applyingReadingSettings(fontSize: 12.5, maxLineCharacters: Preferences.unlimitedLineCharacters)
        theme.contentMargins = Theme.Margins(horizontal: 14, vertical: 10)
        view.theme = theme
        if view.document?.source != markdown {
            view.document = RenderedDocument(source: markdown)
        }
    }
}

/// « Rechercher les mises à jour… » under « À propos » in the app menu.
struct UpdateCommands: Commands {
    let model: UpdateModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(model: model)
        }
    }
}

/// The menu item; a version put off with « Plus tard » shows as its badge.
struct CheckForUpdatesButton: View {
    let model: UpdateModel

    var body: some View {
        Button("Rechercher les mises à jour…") { model.checkForUpdates() }
            .badge(model.deferredVersion.map { Text(verbatim: $0) })
            .disabled(model.backend == nil)
    }
}

/// The « Mises à jour » section of the settings.
struct UpdateSettingsSection: View {
    let model: UpdateModel

    private var lastCheck: Text {
        guard let date = model.lastCheckDate else { return Text("Jamais recherchées") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return Text("Dernière recherche : \(formatter.string(from: date))")
    }

    var body: some View {
        SoftSectionHeader(Text("Mises à jour"))
        SoftGroup {
            SoftToggleRow(Text("Rechercher automatiquement"), help: Text("À l'ouverture, puis une fois par jour"),
                          isOn: Binding(get: { model.automaticallyChecks }, set: { model.setAutomaticallyChecks($0) }))
            SoftRowDivider()
            SoftToggleRow(Text("Télécharger et installer sans demander"), help: Text("Installée à la fermeture de l'appli"),
                          isOn: Binding(get: { model.automaticallyDownloads }, set: { model.setAutomaticallyDownloads($0) }))
                .disabled(!model.automaticallyChecks)
            SoftRowDivider()
            SoftRow(Text("Version \(model.currentVersion)"), help: lastCheck) {
                Button("Rechercher maintenant") { model.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!model.canCheck)
            }
        }
        .disabled(model.backend == nil)
        .onAppear { model.refreshSettings() }
    }
}

/// A thin determinate bar in the app's accent (the system bar ignores the tint).
struct AccentProgressBar: View {
    let fraction: Double

    @Environment(\.softAccent) private var accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SoftColor.track)
                Capsule().fill(accent.icon)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}
