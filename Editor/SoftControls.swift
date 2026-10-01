import AppKit
import SwiftUI

// Soft, compact controls (style A « Hybride », component sheet C5): a light
// grey track with the chosen item on a raised white pill, bare icon buttons
// that only take a grey background on hover, a pale tinted button, and the
// colour tokens they share. The same file is used by both Kayakoma apps.

// MARK: - Tokens

/// Neutral colours of the soft controls, each with its light, dark and
/// Increase Contrast values. Defined in code so they also resolve where the
/// asset catalog is not loaded (unit tests).
enum SoftColor {
    /// Track of a segmented control.
    static let track = Color(nsColor: .soft(light: 0xEDEDEB, dark: 0x2A2A2A))
    /// The chosen segment.
    static let pill = Color(nsColor: .soft(light: 0xFFFFFF, dark: 0x3A3A3A))
    /// Icon or label of the chosen or hovered segment.
    static let iconSelected = Color(nsColor: .soft(light: 0x1C1C1E, dark: 0xF2F2F2))
    /// Icons and labels of the other segments.
    static let iconIdle = Color(nsColor: .soft(light: 0x6E6E73, dark: 0x9A9A9F,
                                               highContrastLight: 0x4E4E53, highContrastDark: 0xC2C2C6))
    /// Icon buttons at rest.
    static let iconButton = Color(nsColor: .soft(light: 0x4E4E53, dark: 0xC2C2C6,
                                                 highContrastLight: 0x2C2C2E, highContrastDark: 0xE2E2E6))
    /// Background of a hovered control.
    static let hover = Color(nsColor: .soft(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.05))
    /// Background of a pressed control.
    static let pressed = Color(nsColor: .soft(light: 0x000000, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.10))
    /// Flat chrome: settings page, bars drawn by the app.
    static let chrome = Color(nsColor: .soft(light: 0xFAFAF8, dark: 0x1E1E1E))
    /// Groups of rows laid on the chrome.
    static let group = Color(nsColor: .soft(light: 0xFFFFFF, dark: 0x242424))
    /// Hairline between the chrome and the content, or between rows.
    static let hairline = Color(nsColor: .soft(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08,
                                               highContrastAlpha: 0.35))
    /// Primary label of the compact interface.
    static let label = Color(nsColor: .soft(light: 0x1C1C1E, dark: 0xEDEDED))
    /// Secondary label: status bar, section headers, help lines.
    static let secondaryLabel = Color(nsColor: .soft(light: 0x86868B, dark: 0x8E8E93,
                                                     highContrastLight: 0x5A5A5F, highContrastDark: 0xB0B0B5))
    /// 1 pt outline drawn around the track with Increase Contrast.
    static let contrastTrackOutline = Color(nsColor: .soft(light: 0x000000, lightAlpha: 0.35, dark: 0xFFFFFF, darkAlpha: 0.35))
    /// 1 pt outline drawn around the pill with Increase Contrast.
    static let contrastPillOutline = Color(nsColor: .soft(light: 0x000000, lightAlpha: 0.55, dark: 0xFFFFFF, darkAlpha: 0.55))
}

/// The two accent families: coral (Editor, « Modifier ») and lagoon (Viewer).
/// The accent only marks a selection or an active state.
enum SoftAccent: Sendable {
    case coral, lagoon

    /// Pale background of a tinted square, button or active toggle.
    var tint: Color {
        switch self {
        case .coral: Color(nsColor: .soft(light: 0xFBE8E3, dark: 0xE9836F, darkAlpha: 0.18))
        case .lagoon: Color(nsColor: .soft(light: 0xDFF0EE, dark: 0x4FB0A8, darkAlpha: 0.20))
        }
    }

    /// Tint of a hovered tinted button.
    var hoveredTint: Color {
        switch self {
        case .coral: Color(nsColor: .soft(light: 0xEDDAD5, dark: 0x5A3E39))
        case .lagoon: Color(nsColor: .soft(light: 0xD2E2E0, dark: 0x354C4B))
        }
    }

    /// Icon on the tint (at least 3:1).
    var icon: Color {
        switch self {
        case .coral: Color(nsColor: .soft(light: 0xC4573F, dark: 0xF0907C, highContrastLight: 0xA84834))
        case .lagoon: Color(nsColor: .soft(light: 0x2C8A84, dark: 0x6CC3BA, highContrastLight: 0x22706B))
        }
    }

    /// Label on the tint or on the window (at least 4.5:1).
    var text: Color {
        switch self {
        case .coral: Color(nsColor: .soft(light: 0xA84834, dark: 0xF4A896, highContrastLight: 0x8C3A29))
        case .lagoon: Color(nsColor: .soft(light: 0x22706B, dark: 0x86D3CA, highContrastLight: 0x1A5A56))
        }
    }

    /// Keyboard focus ring: the accent at 45 %.
    var focusRing: Color {
        switch self {
        case .coral: Color(nsColor: .soft(light: 0xDD6B55, lightAlpha: 0.45, dark: 0xE9836F, darkAlpha: 0.55))
        case .lagoon: Color(nsColor: .soft(light: 0x2C8A84, lightAlpha: 0.45, dark: 0x4FB0A8, darkAlpha: 0.55))
        }
    }
}

private struct SoftAccentKey: EnvironmentKey {
    static let defaultValue = SoftAccent.coral
}

extension EnvironmentValues {
    /// The app's accent family, for focus rings, active toggles and
    /// selections. Each app sets it at the root of its windows.
    var softAccent: SoftAccent {
        get { self[SoftAccentKey.self] }
        set { self[SoftAccentKey.self] = newValue }
    }
}

extension NSColor {
    /// A colour that follows the appearance, with optional values for
    /// Increase Contrast.
    static func soft(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1,
                     highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil,
                     highContrastAlpha: CGFloat? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let isHighContrast = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]).map { $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            var hex = isDark ? dark : light
            var alpha = isDark ? darkAlpha : lightAlpha
            if isHighContrast {
                hex = (isDark ? highContrastDark : highContrastLight) ?? hex
                alpha = highContrastAlpha ?? alpha
            }
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }
}

/// Sizes of the sheet C5, in points.
enum SoftMetrics {
    static let trackHeight: CGFloat = 26
    static let segmentHeight: CGFloat = 22
    static let iconSegmentWidth: CGFloat = 32
    static let trackRadius: CGFloat = 8
    static let segmentRadius: CGFloat = 6
    static let trackInset: CGFloat = 2
    static let segmentGap: CGFloat = 1
    static let iconButtonSize: CGFloat = 26
    static let iconPointSize: CGFloat = 13.5
    static let tintedHeight: CGFloat = 24
    static let focusRingWidth: CGFloat = 3
    static let statusBarHeight: CGFloat = 22
}

// MARK: - Shared pieces

/// The raised white pill of a chosen segment: a soft shadow in light mode, a
/// half-point light edge on top in dark mode, an outline with Increase Contrast.
struct SoftPill: View {
    var cornerRadius = SoftMetrics.segmentRadius
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(SoftColor.pill)
            .overlay {
                if colorScheme == .dark {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center),
                        lineWidth: 0.5)
                } else {
                    shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(SoftColor.contrastPillOutline, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.09), radius: 1, y: 1)
    }
}

/// The grey track under the segments.
struct SoftTrack: View {
    var cornerRadius = SoftMetrics.trackRadius
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(SoftColor.track)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(SoftColor.contrastTrackOutline, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// The 3 pt focus ring drawn by soft controls in place of the system ring.
    func softFocusRing(_ isFocused: Bool, cornerRadius: CGFloat, accent: SoftAccent) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius + SoftMetrics.focusRingWidth / 2, style: .continuous)
                    .stroke(accent.focusRing, lineWidth: SoftMetrics.focusRingWidth)
                    .padding(-SoftMetrics.focusRingWidth / 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Segmented control

/// One choice of a ``SoftSegmentedControl``.
struct SoftSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: Text
    let systemImage: String?
    let help: Text?

    var id: Value { value }

    init(_ value: Value, title: Text, systemImage: String? = nil, help: Text? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
        self.help = help
    }
}

/// A segmented control drawn as a track with the chosen segment on a white
/// pill. Icons only (32 × 22 segments) or icon and label. VoiceOver sees a
/// standard picker; with keyboard navigation on, the control takes focus as a
/// whole and the arrow keys move the choice.
struct SoftSegmentedControl<Value: Hashable>: View {
    enum Content { case icons, labels }

    let title: Text
    @Binding var selection: Value
    let segments: [SoftSegment<Value>]
    var content = Content.icons

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.softAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @Namespace private var pillSpace

    init(_ title: Text, selection: Binding<Value>, segments: [SoftSegment<Value>], content: Content = .icons) {
        self.title = title
        _selection = selection
        self.segments = segments
        self.content = content
    }

    var body: some View {
        HStack(spacing: SoftMetrics.segmentGap) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(.horizontal, SoftMetrics.trackInset)
        .frame(height: SoftMetrics.trackHeight)
        .background(SoftTrack())
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: selection)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .softFocusRing(isFocused, cornerRadius: SoftMetrics.trackRadius, accent: accent)
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .accessibilityRepresentation {
            Picker(selection: $selection) {
                ForEach(segments) { segment in
                    segment.title.tag(segment.value)
                }
            } label: {
                title
            }
            .pickerStyle(.segmented)
        }
    }

    private func segmentButton(_ segment: SoftSegment<Value>) -> some View {
        let isSelected = segment.value == selection
        return Button {
            selection = segment.value
        } label: {
            segmentLabel(segment)
        }
        .buttonStyle(SegmentStyle(isSelected: isSelected, pillSpace: pillSpace,
                                  width: content == .icons ? SoftMetrics.iconSegmentWidth : nil))
        .focusable(false)
        .help(segment.help ?? segment.title)
    }

    @ViewBuilder private func segmentLabel(_ segment: SoftSegment<Value>) -> some View {
        switch content {
        case .icons:
            if let symbol = segment.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: SoftMetrics.iconPointSize, weight: .regular))
                    .accessibilityLabel(segment.title)
            } else {
                segment.title.font(.system(size: 12, weight: .medium))
            }
        case .labels:
            HStack(spacing: 5) {
                if let symbol = segment.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .regular))
                }
                segment.title
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard isEnabled, let index = segments.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = index + offset
        guard segments.indices.contains(next) else { return .handled }
        selection = segments[next].value
        return .handled
    }

    /// A segment: the pill when chosen, a light grey when hovered or pressed.
    private struct SegmentStyle: ButtonStyle {
        let isSelected: Bool
        let pillSpace: Namespace.ID
        let width: CGFloat?

        func makeBody(configuration: Configuration) -> some View {
            SegmentBody(configuration: configuration, isSelected: isSelected, pillSpace: pillSpace, width: width)
        }
    }

    private struct SegmentBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let pillSpace: Namespace.ID
        let width: CGFloat?
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected || isHovered || configuration.isPressed
                                 ? SoftColor.iconSelected : SoftColor.iconIdle)
                .frame(width: width, height: SoftMetrics.segmentHeight)
                .background {
                    if isSelected {
                        SoftPill().matchedGeometryEffect(id: "pill", in: pillSpace)
                    } else if configuration.isPressed || isHovered {
                        RoundedRectangle(cornerRadius: SoftMetrics.segmentRadius, style: .continuous)
                            .fill(configuration.isPressed ? SoftColor.pressed : SoftColor.hover)
                    }
                }
                .scaleEffect(isSelected && configuration.isPressed ? 0.96 : 1)
                // The whole height of the track is clickable (26 pt).
                .frame(height: SoftMetrics.trackHeight)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Stepper

/// A value between − and + on a track, the value on the white pill (« 15 pt »).
/// VoiceOver sees a standard stepper; with keyboard navigation on, the arrow
/// keys change the value.
struct SoftStepper: View {
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let valueLabel: Text

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.softAccent) private var accent
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: SoftMetrics.segmentGap) {
            stepButton(systemImage: "minus", delta: -step)
            valueLabel
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(SoftColor.iconSelected)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: SoftMetrics.segmentHeight)
                .background(SoftPill())
            stepButton(systemImage: "plus", delta: step)
        }
        .padding(.horizontal, SoftMetrics.trackInset)
        .frame(height: SoftMetrics.trackHeight)
        .background(SoftTrack())
        .opacity(isEnabled ? 1 : 0.4)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .softFocusRing(isFocused, cornerRadius: SoftMetrics.trackRadius, accent: accent)
        .onKeyPress(.leftArrow) { change(by: -step) }
        .onKeyPress(.downArrow) { change(by: -step) }
        .onKeyPress(.rightArrow) { change(by: step) }
        .onKeyPress(.upArrow) { change(by: step) }
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { title }
                .accessibilityValue(valueLabel)
        }
    }

    private func stepButton(systemImage: String, delta: Double) -> some View {
        let target = value + delta
        return Button {
            value = min(max(target, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24)
        }
        .buttonStyle(SoftIconButtonStyle(size: CGSize(width: 24, height: SoftMetrics.segmentHeight),
                                         hitHeight: SoftMetrics.trackHeight, idleColor: SoftColor.iconIdle))
        .focusable(false)
        .disabled(!range.contains(target))
    }

    private func change(by delta: Double) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        value = min(max(value + delta, range.lowerBound), range.upperBound)
        return .handled
    }
}

// MARK: - Buttons

/// A bare icon button (26 × 26, icon 15): no capsule, a grey background on
/// hover and press. With `isOn`, a toggle tinted with the app's accent while
/// active.
struct SoftIconButtonStyle: ButtonStyle {
    var isOn = false
    var size = CGSize(width: SoftMetrics.iconButtonSize, height: SoftMetrics.iconButtonSize)
    var hitHeight: CGFloat?
    var idleColor = SoftColor.iconButton

    func makeBody(configuration: Configuration) -> some View {
        SoftIconButtonBody(configuration: configuration, isOn: isOn, size: size, hitHeight: hitHeight, idleColor: idleColor)
    }
}

private struct SoftIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let size: CGSize
    let hitHeight: CGFloat?
    let idleColor: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.softAccent) private var accent
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: SoftMetrics.iconPointSize, weight: .regular))
            .foregroundStyle(foreground)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: SoftMetrics.segmentRadius, style: .continuous)
                    .fill(background)
            }
            .opacity(isEnabled ? 1 : 0.35)
            .softFocusRing(isFocused, cornerRadius: SoftMetrics.segmentRadius, accent: accent)
            .frame(height: hitHeight)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 && isEnabled }
            .focusEffectDisabled()
    }

    private var foreground: Color {
        if isOn { return accent.icon }
        return isHovered || configuration.isPressed ? SoftColor.iconSelected : idleColor
    }

    private var background: Color {
        if isOn { return configuration.isPressed || isHovered ? accent.hoveredTint : accent.tint }
        if configuration.isPressed { return SoftColor.pressed }
        return isHovered ? SoftColor.hover : .clear
    }
}

/// A toggle drawn as a ``SoftIconButtonStyle`` button, tinted while on.
struct SoftIconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(SoftIconButtonStyle(isOn: configuration.isOn))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? Text("Activé") : Text("Désactivé"))
    }
}

/// A pale tinted button with an icon and a label (« Modifier »): 24 pt high,
/// icon in the accent, label in the darker accent.
struct SoftTintedButtonStyle: ButtonStyle {
    let accent: SoftAccent
    /// Narrows to the width offered, the label on up to two centred lines,
    /// instead of always taking its full width on one.
    var wraps = false

    func makeBody(configuration: Configuration) -> some View {
        SoftTintedButtonBody(configuration: configuration, accent: accent, wraps: wraps)
    }
}

private struct SoftTintedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let accent: SoftAccent
    let wraps: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(SoftTintedLabelStyle(accent: accent))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent.text)
            .lineLimit(wraps ? 2 : 1)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: !wraps, vertical: true)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, wraps ? 4 : 0)
            .frame(minHeight: SoftMetrics.tintedHeight)
            .frame(height: wraps ? nil : SoftMetrics.tintedHeight)
            .background {
                let shape = RoundedRectangle(cornerRadius: SoftMetrics.segmentRadius, style: .continuous)
                shape
                    .fill(isHovered || configuration.isPressed ? accent.hoveredTint : accent.tint)
                    .overlay {
                        if contrast == .increased { shape.strokeBorder(accent.text.opacity(0.6), lineWidth: 1) }
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .softFocusRing(isFocused, cornerRadius: SoftMetrics.segmentRadius, accent: accent)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 && isEnabled }
            .focusEffectDisabled()
    }
}

private struct SoftTintedLabelStyle: LabelStyle {
    let accent: SoftAccent

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(accent.icon)
            configuration.title
        }
    }
}

// MARK: - Tinted square

/// The app's mark on a pale tinted square (18 pt in a bar, 22 in a list, 28
/// in settings): the slanted # whose last stroke is only half drawn.
struct TintedIconSquare: View {
    let accent: SoftAccent
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(accent.tint)
            .frame(width: size, height: size)
            .overlay {
                SharpMark()
                    .stroke(accent.icon, style: StrokeStyle(lineWidth: max(1.2, size * 0.075), lineCap: .round))
                    .frame(width: size * 0.6, height: size * 0.6)
            }
            .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat {
        size >= 28 ? 8 : size >= 22 ? 6 : 5
    }
}

/// The Kayakoma # drawn as a shape, so it stays sharp at 18 pt.
struct SharpMark: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let slant = w * 0.12
        var path = Path()
        // Two slanted uprights, the second one only half drawn.
        path.move(to: CGPoint(x: rect.minX + w * 0.38 + slant, y: rect.minY + h * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.38 - slant, y: rect.minY + h * 0.95))
        path.move(to: CGPoint(x: rect.minX + w * 0.70 + slant, y: rect.minY + h * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.70, y: rect.minY + h * 0.45))
        // Two crossbars.
        path.move(to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY + h * 0.36))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.95, y: rect.minY + h * 0.36))
        path.move(to: CGPoint(x: rect.minX + w * 0.05, y: rect.minY + h * 0.66))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.92, y: rect.minY + h * 0.66))
        return path
    }
}

// MARK: - Tile track

/// Tiles (theme samples) laid on a track, the chosen one on a white pill and
/// the hovered one on a light grey.
struct SoftTileTrack<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    /// Tiles per row at most; the track hugs fewer tiles.
    var columns = 5
    var tileWidth: CGFloat = 92
    let isSelected: (Item) -> Bool
    let action: (Item) -> Void
    let accessibilityLabel: (Item) -> Text
    @ViewBuilder let tile: (Item, Bool) -> Tile

    var body: some View {
        let count = max(1, min(columns, items.count))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: 2), count: count), spacing: 2) {
            ForEach(items) { item in
                let selected = isSelected(item)
                Button {
                    action(item)
                } label: {
                    tile(item, selected)
                }
                .buttonStyle(TileStyle(isSelected: selected))
                .accessibilityLabel(accessibilityLabel(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .padding(3)
        .background(SoftTrack(cornerRadius: 10))
    }

    private struct TileStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            TileBody(configuration: configuration, isSelected: isSelected)
        }
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.softAccent) private var accent
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected || isHovered ? SoftColor.iconSelected : SoftColor.iconIdle)
                .padding(EdgeInsets(top: 6, leading: 6, bottom: 5, trailing: 6))
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        SoftPill(cornerRadius: 7)
                    } else if isHovered || configuration.isPressed {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(configuration.isPressed ? SoftColor.pressed : SoftColor.hover)
                    }
                }
                .softFocusRing(isFocused, cornerRadius: 7, accent: accent)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .focusEffectDisabled()
        }
    }
}

// MARK: - Settings rows

/// A section header of the compact settings page.
struct SoftSectionHeader: View {
    let title: Text

    init(_ title: Text) { self.title = title }

    var body: some View {
        title
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(SoftColor.secondaryLabel)
            .padding(EdgeInsets(top: 14, leading: 4, bottom: 6, trailing: 4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A white group of rows on the settings chrome; ``SoftRowDivider`` goes
/// between rows.
struct SoftGroup<Content: View>: View {
    var padding = EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(padding)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SoftColor.group)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(SoftColor.hairline, lineWidth: 0.5)
                }
        }
    }
}

/// The hairline between two rows of a ``SoftGroup``.
struct SoftRowDivider: View {
    var body: some View {
        SoftColor.hairline
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A settings row: label (12.5 pt) with an optional help line (11 pt), the
/// control on the right; at least 32 pt high.
struct SoftRow<Control: View>: View {
    let title: Text
    var help: Text?
    /// False when the control already carries the title for VoiceOver.
    var announcesTitle = true
    @ViewBuilder let control: Control

    init(_ title: Text, help: Text? = nil, announcesTitle: Bool = true, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.announcesTitle = announcesTitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: 12.5))
                    .foregroundStyle(SoftColor.label)
                if let help {
                    help
                        .font(.system(size: 11))
                        .foregroundStyle(SoftColor.secondaryLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(!announcesTitle)
            control
        }
        .padding(.vertical, 4)
        .frame(minHeight: 32)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Toolbar

extension ToolbarContent {
    /// On macOS 26 and later, takes the item out of the glass capsule the
    /// toolbar shares between neighbours: the soft control draws itself.
    @ToolbarContentBuilder func softToolbarItem() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
