import AppKit
import KayakomaKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension Theme {
    /// Coral, the Editor's accent: a shade darker than the icon's for
    /// legible link text, and lightened in the dark appearance for contrast.
    static let coralLink = Theme.Color.custom(light: "#C95A45", dark: "#F29A86")

    /// The engine's default theme with links in the Editor's colour.
    static let editorDefault: Theme = {
        var theme = Theme.default
        theme.linkColor = coralLink
        return theme
    }()

    /// Cream paper and a serif face; warm dark grey in the dark appearance.
    static let paper: Theme = {
        var theme = Theme.editorDefault
        theme.fontFamily = "Georgia"
        theme.backgroundColor = .custom(light: "#FBF8F2", dark: "#24211D")
        theme.textColor = .custom(light: "#3B2F22", dark: "#E9E2D6")
        theme.secondaryTextColor = .custom(light: "#76695A", dark: "#ADA393")
        theme.codeBackgroundColor = .custom(light: "#F1EBDF", dark: "#312C26")
        theme.quoteBarColor = .custom(light: "#D9CFBE", dark: "#544C40")
        theme.ruleColor = .custom(light: "#E6DED0", dark: "#3D372F")
        theme.tableBorderColor = .custom(light: "#E6DED0", dark: "#3D372F")
        theme.tableHeaderBackgroundColor = .custom(light: "#F1EBDF", dark: "#312C26")
        return theme
    }()

    /// The theme with the reading settings applied over it: body size (code
    /// and headings scaled in proportion) and a column width in characters.
    func applyingReadingSettings(fontSize: Double, maxLineCharacters: Double) -> Theme {
        var theme = self
        let size = CGFloat(fontSize)
        let factor = size / max(self.fontSize, 1)
        theme.fontSize = size
        theme.codeFontSize = (codeFontSize * factor * 2).rounded() / 2
        for level in Theme.HeadingStyles.levels {
            theme.headings[level: level].size = (headings[level: level].size * factor * 2).rounded() / 2
        }
        // An average character of body text is about half an em wide.
        theme.maxLineWidth = (CGFloat(maxLineCharacters) * size * 0.5).rounded()
        return theme
    }
}

/// A theme the user can pick: built in, or read from a JSON file.
struct ThemeEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case builtIn
        case file(URL)
    }

    let id: String
    let name: String
    let source: Source
    /// The theme, or the reason its file could not be decoded.
    let result: Result<Theme, ThemeFileError>

    var theme: Theme? { try? result.get() }
}

/// A theme file that could not be read or decoded.
struct ThemeFileError: Error, Equatable {
    /// The decoder's message; it names the faulty key.
    let message: String
}

/// Built-in themes and the user's theme files, kept in the app's
/// Application Support folder.
@MainActor
@Observable
final class ThemeLibrary {
    static let shared = ThemeLibrary()

    static let defaultID = "builtin.default"
    static let paperID = "builtin.paper"

    private(set) var entries: [ThemeEntry] = []

    let folderURL: URL

    init(folderURL: URL? = nil) {
        self.folderURL = folderURL ?? URL.applicationSupportDirectory.appending(path: "Themes", directoryHint: .isDirectory)
        reload()
    }

    var builtInEntries: [ThemeEntry] {
        [
            ThemeEntry(id: Self.defaultID, name: String(localized: "Par défaut"), source: .builtIn, result: .success(.editorDefault)),
            ThemeEntry(id: Self.paperID, name: String(localized: "Papier"), source: .builtIn, result: .success(.paper)),
        ]
    }

    /// Reads the theme folder again; called whenever the app becomes active.
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let userEntries = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                ThemeEntry(
                    id: "file:" + url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    source: .file(url),
                    result: Self.decodeTheme(at: url)
                )
            }
        let newEntries = builtInEntries + userEntries
        if newEntries != entries { entries = newEntries }
    }

    /// The theme with that identifier; the default theme when it is unknown or invalid.
    func theme(id: String) -> Theme {
        entries.first { $0.id == id }?.theme ?? .editorDefault
    }

    /// Validates a theme file, then copies it into the theme folder.
    /// - Returns: the identifier of the imported theme.
    @discardableResult
    func importTheme(from url: URL) throws(ThemeFileError) -> String {
        _ = try Self.decodeTheme(at: url).get()
        let destination = folderURL.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ThemeFileError(message: error.localizedDescription)
        }
        reload()
        return "file:" + destination.lastPathComponent
    }

    /// Shows the theme folder in the Finder, creating it first if needed.
    func revealFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    /// Asks for a theme file, imports it and selects it.
    func chooseAndImportTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choisissez un fichier de thème JSON.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try importTheme(from: url)
            UserDefaults.standard.set(id, forKey: Preferences.themeID)
        } catch {
            Self.presentError(error, themeName: url.deletingPathExtension().lastPathComponent)
        }
    }

    static func presentError(_ error: ThemeFileError, themeName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Le thème « \(themeName) » n'a pas pu être chargé.")
        alert.informativeText = error.message
        alert.runModal()
    }

    // MARK: - Decoding

    /// Decodes a partial theme file over the engine's default theme; links
    /// stay in the Editor's colour unless the file sets them.
    nonisolated static func decodeTheme(at url: URL) -> Result<Theme, ThemeFileError> {
        do {
            let data = try Data(contentsOf: url)
            return decodeTheme(data)
        } catch {
            return .failure(ThemeFileError(message: error.localizedDescription))
        }
    }

    nonisolated static func decodeTheme(_ data: Data) -> Result<Theme, ThemeFileError> {
        do {
            var theme = try JSONDecoder().decode(Theme.self, from: data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["linkColor"] == nil { theme.linkColor = Theme.coralLink }
            return .success(theme)
        } catch {
            return .failure(ThemeFileError(message: message(for: error)))
        }
    }

    /// A readable message for a decoding error, naming the key at fault.
    nonisolated static func message(for error: any Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        switch decodingError {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            context = c
        @unknown default:
            return error.localizedDescription
        }
        var message = context.debugDescription
        if let underlying = context.underlyingError as NSError?,
           let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
            message += " " + detail
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        if !path.isEmpty, !message.contains(path) {
            message += " " + String(localized: "(clé « \(path) »)")
        }
        return message
    }
}
