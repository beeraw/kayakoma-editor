import AppKit
import SwiftUI

/// Keys and default values of the app's settings, stored in `UserDefaults`.
enum Preferences {
    static let themeID = "themeID"
    static let fontSize = "fontSize"
    static let maxLineCharacters = "maxLineCharacters"
    static let appearance = "appearance"
    /// New windows open filling the visible frame of their screen.
    static let opensWindowsLarge = "opensWindowsLarge"
    static let sourceFontSize = "sourceFontSize"
    static let showsLineNumbers = "showsLineNumbers"
    static let syncsScrolling = "syncsScrolling"
    static let showsStatusBar = "showsStatusBar"
    static let opensInTabs = "opensInTabs"
    /// Folder windows: hidden files in the sidebar (Présentation, ⇧⌘.).
    static let showsHiddenFiles = "showsHiddenFiles"
    /// Folder windows: files the Editor does not open are hidden, not dimmed.
    static let hidesOtherFiles = "hidesOtherFiles"
    /// Folder windows: links to missing files are underlined.
    static let marksBrokenLinks = "marksBrokenLinks"

    /// Text size of the preview, which has half the window.
    static let defaultFontSize: Double = 14
    static let fontSizeRange: ClosedRange<Double> = 10...28
    static let defaultMaxLineCharacters: Double = 90
    static let maxLineCharactersRange: ClosedRange<Double> = 50...140
    static let defaultSourceFontSize: Double = 13
    static let sourceFontSizeRange: ClosedRange<Double> = 9...24
}

extension UserDefaults {
    var sourceFontSize: Double {
        object(forKey: Preferences.sourceFontSize) as? Double ?? Preferences.defaultSourceFontSize
    }

    /// Whether documents open as tabs of the frontmost window (on by default).
    var opensInTabs: Bool {
        object(forKey: Preferences.opensInTabs) as? Bool ?? true
    }

    /// Whether new windows keep the two panes scrolled together.
    var syncsScrollingByDefault: Bool {
        object(forKey: Preferences.syncsScrolling) as? Bool ?? true
    }
}

/// The app's appearance, independent of the system's when forced.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .auto: "Auto"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the mode stored in the user defaults to the whole app.
    @MainActor
    static func applyStored() {
        let mode = UserDefaults.standard.string(forKey: Preferences.appearance).flatMap(AppearanceMode.init) ?? .auto
        if NSApp.appearance != mode.nsAppearance {
            NSApp.appearance = mode.nsAppearance
        }
    }
}

extension Binding where Value == Double {
    /// Rounds what a slider sets, without the tick marks a stepped slider draws.
    func rounded(toMultipleOf step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue }, set: { wrappedValue = ($0 / step).rounded() * step })
    }
}
