import KayakomaKit
import SwiftUI

/// The themes as tiles on a soft track, each sample drawn in its own colours
/// and face; the chosen theme sits on the white pill.
struct ThemeSwatches: View {
    let entries: [ThemeEntry]
    @Binding var selection: String
    var columns = 5
    var tileWidth: CGFloat = 92

    var body: some View {
        SoftTileTrack(items: entries, columns: columns, tileWidth: tileWidth,
                      isSelected: { $0.id == selection },
                      action: select,
                      accessibilityLabel: { Text($0.name) }) { entry, isSelected in
            ThemeTile(entry: entry, isSelected: isSelected)
        }
    }

    private func select(_ entry: ThemeEntry) {
        switch entry.result {
        case .success: selection = entry.id
        case .failure(let error): ThemeLibrary.presentError(error, themeName: entry.name)
        }
    }
}

private struct ThemeTile: View {
    let entry: ThemeEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            sample
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                }
            Text(entry.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(helpText)
    }

    @ViewBuilder private var sample: some View {
        if let theme = entry.theme {
            let ink = Color(nsColor: theme.textColor.nsColor)
            ZStack(alignment: .topLeading) {
                Color(nsColor: theme.backgroundColor.nsColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Titre")
                        .font(theme.fontFamily.map { .custom($0, size: 10.5).bold() } ?? .system(size: 10.5, weight: .bold))
                        .foregroundStyle(ink)
                        .padding(.bottom, 1)
                    Capsule().fill(ink.opacity(0.45)).frame(height: 2.5)
                    Capsule().fill(ink.opacity(0.45)).frame(height: 2.5)
                        .padding(.trailing, 18)
                }
                .padding(EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7))
            }
        } else {
            ZStack {
                Color(nsColor: .quaternarySystemFill)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var helpText: Text {
        if case .failure(let error) = entry.result { Text(verbatim: error.message) } else { Text(entry.name) }
    }
}

extension AppearanceMode {
    var symbol: String {
        switch self {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// Auto / Clair / Sombre on a soft track.
struct AppearanceSwitcher: View {
    @Binding var appearance: AppearanceMode

    var body: some View {
        SoftSegmentedControl(Text("Mode"), selection: $appearance,
                             segments: AppearanceMode.allCases.map { SoftSegment($0, title: Text($0.title), systemImage: $0.symbol) },
                             content: .labels)
    }
}

/// A row with a switch on the right; the row's title is the switch's label.
struct SoftToggleRow: View {
    let title: Text
    @Binding var isOn: Bool

    init(_ title: Text, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        SoftRow(title, announcesTitle: false) {
            Toggle(isOn: $isOn) { title }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// The settings window: one grouped form in the compact soft style,
/// with the Editor's own source settings.
struct SettingsView: View {
    @AppStorage(Preferences.appearance) private var appearance = AppearanceMode.auto
    @AppStorage(Preferences.opensWindowsLarge) private var opensWindowsLarge = true
    @AppStorage(Preferences.themeID) private var themeID = ThemeLibrary.defaultID
    @AppStorage(Preferences.fontSize) private var fontSize = Preferences.defaultFontSize
    @AppStorage(Preferences.maxLineCharacters) private var maxLineCharacters = Preferences.defaultMaxLineCharacters
    @AppStorage(Preferences.sourceFontSize) private var sourceFontSize = Preferences.defaultSourceFontSize
    @AppStorage(Preferences.showsLineNumbers) private var showsLineNumbers = true
    @AppStorage(Preferences.syncsScrolling) private var syncsScrolling = true
    @AppStorage(Preferences.showsStatusBar) private var showsStatusBar = true
    @AppStorage(Preferences.opensInTabs) private var opensInTabs = true
    @AppStorage(Preferences.hidesOtherFiles) private var hidesOtherFiles = false
    @AppStorage(Preferences.marksBrokenLinks) private var marksBrokenLinks = true
    var library = ThemeLibrary.shared

    var body: some View {
        VStack(spacing: 0) {
            SoftSectionHeader(Text("Apparence"))
            SoftGroup {
                SoftRow(Text("Mode")) {
                    AppearanceSwitcher(appearance: $appearance)
                }
                SoftRowDivider()
                SoftToggleRow(Text("Ouvrir les fenêtres en grand"), isOn: $opensWindowsLarge)
            }

            SoftSectionHeader(Text("Thème du rendu"))
            SoftGroup(padding: EdgeInsets(top: 10, leading: 10, bottom: 2, trailing: 10)) {
                ThemeSwatches(entries: library.entries, selection: $themeID)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                SoftRow(Text("Thème personnalisé"), help: Text("Fichier JSON partiel, complété par le thème par défaut")) {
                    Button("Ouvrir…") { library.chooseAndImportTheme() }
                        .controlSize(.small)
                        .accessibilityLabel(Text("Ouvrir un fichier de thème…"))
                        .help("Ouvrir un fichier de thème…")
                }
                .padding(.horizontal, 2)
                SoftRowDivider()
                SoftRow(Text("Dossier des thèmes")) {
                    Button("Ouvrir…") { library.revealFolder() }
                        .controlSize(.small)
                        .accessibilityLabel(Text("Ouvrir le dossier des thèmes"))
                        .help("Ouvrir le dossier des thèmes")
                }
                .padding(.horizontal, 2)
            }

            SoftSectionHeader(Text("Rendu"))
            SoftGroup {
                SoftRow(Text("Taille du texte")) {
                    SoftStepper(title: Text("Taille du texte"), value: $fontSize, range: Preferences.fontSizeRange,
                                valueLabel: Text("\(Int(fontSize)) pt"))
                }
                SoftRowDivider()
                SoftRow(Text("Largeur maximale de ligne")) {
                    HStack(spacing: 10) {
                        Slider(value: $maxLineCharacters.rounded(toMultipleOf: 5), in: Preferences.maxLineCharactersRange) {
                            Text("Largeur maximale de ligne")
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 140)
                        Text("\(Int(maxLineCharacters)) car.")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(SoftColor.secondaryLabel)
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
            }

            SoftSectionHeader(Text("Source"))
            SoftGroup {
                SoftRow(Text("Taille de la police")) {
                    SoftStepper(title: Text("Taille de la police"), value: $sourceFontSize,
                                range: Preferences.sourceFontSizeRange, valueLabel: Text("\(Int(sourceFontSize)) pt"))
                }
                SoftRowDivider()
                SoftToggleRow(Text("Afficher les numéros de ligne"), isOn: $showsLineNumbers)
            }

            SoftSectionHeader(Text("Général"))
            SoftGroup {
                SoftToggleRow(Text("Ouvrir les documents dans des onglets"), isOn: $opensInTabs)
                SoftRowDivider()
                SoftToggleRow(Text("Synchroniser le défilement dans les nouvelles fenêtres"), isOn: $syncsScrolling)
                SoftRowDivider()
                SoftToggleRow(Text("Afficher la barre d'état"), isOn: $showsStatusBar)
            }

            SoftSectionHeader(Text("Mode dossier"))
            SoftGroup {
                SoftToggleRow(Text("Masquer les autres fichiers"), isOn: $hidesOtherFiles)
                SoftRowDivider()
                SoftToggleRow(Text("Signaler les liens cassés"), isOn: $marksBrokenLinks)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 20, bottom: 20, trailing: 20))
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(SoftColor.chrome)
        .onAppear { library.reload() }
    }
}
