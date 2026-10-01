import AppKit
import SwiftUI

/// Opens new windows filling the visible frame of their screen (menu bar and
/// Dock stay visible; this is not full screen).
///
/// This file is shared: the Viewer and the Editor each carry an identical copy.
enum WindowSizing {
    /// The frame a new window should take, or `nil` when it keeps its own:
    /// the setting is off, the window joined a tab group (it shares the
    /// group's frame), or it already fills the visible frame.
    static func targetFrame(windowFrame: NSRect, visibleFrame: NSRect, tabCount: Int, isEnabled: Bool) -> NSRect? {
        guard isEnabled, tabCount <= 1, visibleFrame.width > 0, visibleFrame.height > 0,
              windowFrame != visibleFrame else { return nil }
        return visibleFrame
    }

    @MainActor
    static func applyIfNeeded(to window: NSWindow, isEnabled: Bool) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let tabCount = window.tabbedWindows?.count ?? 0
        guard let frame = targetFrame(windowFrame: window.frame, visibleFrame: screen.visibleFrame,
                                      tabCount: tabCount, isEnabled: isEnabled) else { return }
        window.setFrame(frame, display: true)
    }
}

/// Sizes the window the view is in, once, when it first gets its window. The
/// work waits one run-loop turn so that the window has its screen and AppKit
/// has already decided whether it becomes a tab.
struct WindowSizer: NSViewRepresentable {
    final class SizerView: NSView {
        private var didApply = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didApply, window != nil else { return }
            didApply = true
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                let isEnabled = UserDefaults.standard.object(forKey: Preferences.opensWindowsLarge) as? Bool ?? true
                WindowSizing.applyIfNeeded(to: window, isEnabled: isEnabled)
            }
        }
    }

    func makeNSView(context: Context) -> SizerView { SizerView() }
    func updateNSView(_ view: SizerView, context: Context) {}
}
