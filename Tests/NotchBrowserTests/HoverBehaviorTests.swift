import AppKit
import XCTest
@testable import NotchBrowser

final class HoverBehaviorTests: XCTestCase {
    @MainActor
    func testFocusedNotchClosesAfterLeavingAndModalDefersClosing() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore.shared
        let original = store.data
        defer { store.data = original }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.countdownEnabled = false
        settings.motion.closeDelay = 0.15
        settings.motion.style = .none
        store.data = settings
        let manager = NotchManager()
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.show()
        controller.expand(focus: true)
        XCTAssertTrue(controller.panel.isKeyWindow, "Reproduce keyboard focus after browser interaction")
        controller.root.onHoverChange?(false)
        XCTAssertTrue(controller.isExpanded)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isExpanded, "Keyboard focus must not prevent automatic closing")

        controller.expand(focus: true)
        controller.root.onHoverChange?(false)
        manager.isShowingModal = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isExpanded)
        manager.isShowingModal = false
        controller.resumeHoverCloseIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isExpanded)
    }

    @MainActor
    func testDelaysCancelOnExitAndReentryAndPinPreventsPendingClose() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore.shared
        let original = store.data
        defer { store.data = original }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.countdownEnabled = false
        settings.motion.openDelay = 0.15
        settings.motion.closeDelay = 0.15
        settings.motion.style = .none
        store.data = settings
        let manager = NotchManager()
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }

        controller.root.onHoverChange?(true)
        XCTAssertFalse(controller.isExpanded)
        controller.root.onHoverChange?(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isExpanded, "Leaving before the opening delay cancels the open")

        controller.root.onHoverChange?(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isExpanded)
        controller.root.onHoverChange?(false)
        XCTAssertTrue(controller.isExpanded, "Closing must wait for the configured delay")
        controller.root.onHoverChange?(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isExpanded, "Reentry cancels the pending close")

        controller.root.onHoverChange?(false)
        manager.keepOpen = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isExpanded, "Pinning during the delay prevents closing")
        manager.keepOpen = false
        controller.root.onHoverChange?(true)
        controller.root.onHoverChange?(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isExpanded)
    }

    @MainActor
    func testZeroDelayAndExplicitOpenBypassHoverWait() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore.shared
        let original = store.data
        defer { store.data = original }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.countdownEnabled = false
        settings.motion.openDelay = 0
        settings.motion.closeDelay = 0
        settings.motion.style = .none
        store.data = settings
        let manager = NotchManager()
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.root.onHoverChange?(true)
        XCTAssertTrue(controller.isExpanded)
        controller.root.onHoverChange?(false)
        XCTAssertFalse(controller.isExpanded)
        store.data.motion.openDelay = 3
        controller.expand(focus: false)
        XCTAssertTrue(controller.isExpanded, "Explicit open ignores hover delay")
        controller.collapse(animated: false)
    }
}
