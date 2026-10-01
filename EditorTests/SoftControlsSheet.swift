import SwiftUI

/// The component sheet C5 drawn with the real controls, for the snapshots.
/// Hover, press and keyboard focus need a pointer or a key press and are
/// checked live.
struct SoftControlsSheet: View {
    enum Layout: Hashable { case source, split, preview }
    enum Mode: Hashable { case auto, light, dark }

    @State private var layout = Layout.split
    @State private var pair = Layout.source
    @State private var mode = Mode.light
    @State private var size = 15.0

    private var three: [SoftSegment<Layout>] {
        [SoftSegment(.source, title: Text(verbatim: "Source"), systemImage: "doc.plaintext"),
         SoftSegment(.split, title: Text(verbatim: "Split"), systemImage: "rectangle.split.2x1"),
         SoftSegment(.preview, title: Text(verbatim: "Preview"), systemImage: "eye")]
    }

    private var modes: [SoftSegment<Mode>] {
        [SoftSegment(.auto, title: Text(verbatim: "Auto"), systemImage: "circle.lefthalf.filled"),
         SoftSegment(.light, title: Text(verbatim: "Clair"), systemImage: "sun.max"),
         SoftSegment(.dark, title: Text(verbatim: "Sombre"), systemImage: "moon")]
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 16) {
            row("Selector · 3") {
                SoftSegmentedControl(Text(verbatim: "Layout"), selection: $layout, segments: three)
                SoftSegmentedControl(Text(verbatim: "Layout"), selection: .constant(Layout.preview), segments: three)
                SoftSegmentedControl(Text(verbatim: "Layout"), selection: $layout, segments: three).disabled(true)
            }
            row("Selector · 2") {
                SoftSegmentedControl(Text(verbatim: "Layout"), selection: $pair, segments: Array(three.prefix(1)) + [three[2]])
                SoftSegmentedControl(Text(verbatim: "Layout"), selection: $pair, segments: Array(three.prefix(1)) + [three[2]])
                    .disabled(true)
            }
            row("Selector · text") {
                SoftSegmentedControl(Text(verbatim: "Mode"), selection: $mode, segments: modes, content: .labels)
                SoftStepper(title: Text(verbatim: "Size"), value: $size, range: 10...28,
                            valueLabel: Text(verbatim: "\(Int(size)) pt"))
            }
            row("Icon button") {
                Button {} label: { Label(String("Find"), systemImage: "magnifyingglass") }
                    .buttonStyle(SoftIconButtonStyle())
                Button {} label: { Label(String("Sync"), systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(SoftIconButtonStyle(isOn: true))
                Button {} label: { Label(String("Sidebar"), systemImage: "sidebar.left") }
                    .buttonStyle(SoftIconButtonStyle(isOn: true))
                    .environment(\.softAccent, .lagoon)
                Button {} label: { Label(String("Find"), systemImage: "magnifyingglass") }
                    .buttonStyle(SoftIconButtonStyle())
                    .disabled(true)
            }
            row("Tinted square") {
                TintedIconSquare(accent: .lagoon, size: 18)
                TintedIconSquare(accent: .lagoon, size: 22)
                TintedIconSquare(accent: .lagoon, size: 28)
                TintedIconSquare(accent: .coral, size: 18)
                TintedIconSquare(accent: .coral, size: 22)
                TintedIconSquare(accent: .coral, size: 28)
            }
            row("Tinted button") {
                Button {} label: { Label(String("Modifier"), systemImage: "pencil") }
                    .buttonStyle(SoftTintedButtonStyle(accent: .coral))
                Button {} label: { Label(String("Ouvrir"), systemImage: "pencil") }
                    .buttonStyle(SoftTintedButtonStyle(accent: .lagoon))
                Button {} label: { Label(String("Modifier"), systemImage: "pencil") }
                    .buttonStyle(SoftTintedButtonStyle(accent: .coral))
                    .disabled(true)
            }
        }
        .padding(24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SoftColor.label)
            HStack(spacing: 22) { content() }
        }
    }
}
