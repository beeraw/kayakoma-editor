import AppKit
import SwiftUI

/// Native window tabs: document windows share one tabbing identifier, and
/// prefer joining the frontmost one over opening apart, whatever the system's
/// "Prefer tabs" setting says. With the preference off, the system decides.
enum WindowTabbing {
    static let identifier = "app.kayakoma.editor.document"

    static func mode(opensInTabs: Bool) -> NSWindow.TabbingMode {
        opensInTabs ? .preferred : .automatic
    }

    @MainActor
    static func configure(_ window: NSWindow, opensInTabs: Bool) {
        if window.tabbingIdentifier != identifier { window.tabbingIdentifier = identifier }
        let mode = mode(opensInTabs: opensInTabs)
        if window.tabbingMode != mode { window.tabbingMode = mode }
    }
}

/// Configures the tabbing of the window the view is in. It runs when the view
/// joins the window, before the window is shown, which is when AppKit decides
/// whether it becomes a tab.
struct WindowTabbingConfigurator: NSViewRepresentable {
    let opensInTabs: Bool

    final class ConfiguratorView: NSView {
        var opensInTabs = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowTabbing.configure(window, opensInTabs: opensInTabs) }
        }
    }

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.opensInTabs = opensInTabs
        return view
    }

    func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.opensInTabs = opensInTabs
        if let window = view.window { WindowTabbing.configure(window, opensInTabs: opensInTabs) }
    }
}
