import AppKit
import XCTest

final class WindowSizingTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 25, width: 1440, height: 850)
    private let small = NSRect(x: 100, y: 100, width: 600, height: 400)

    func testPicksVisibleFrame() {
        XCTAssertEqual(WindowSizing.targetFrame(windowFrame: small, visibleFrame: visible, tabCount: 0, isEnabled: true), visible)
        XCTAssertEqual(WindowSizing.targetFrame(windowFrame: small, visibleFrame: visible, tabCount: 1, isEnabled: true), visible)
    }

    func testIgnoresTabbedWindow() {
        XCTAssertNil(WindowSizing.targetFrame(windowFrame: small, visibleFrame: visible, tabCount: 2, isEnabled: true))
    }

    func testIgnoresWhenSettingIsOff() {
        XCTAssertNil(WindowSizing.targetFrame(windowFrame: small, visibleFrame: visible, tabCount: 0, isEnabled: false))
    }

    func testIgnoresWindowAlreadyFilling() {
        XCTAssertNil(WindowSizing.targetFrame(windowFrame: visible, visibleFrame: visible, tabCount: 0, isEnabled: true))
    }
}
