import AppKit
import XCTest
@testable import NotchBrowser

final class HoverBehaviorTests: XCTestCase {
    @MainActor
    func testAnimatedHotkeyCloseWaitsForExitFromOriginalExpandedRegion() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore.shared
        let original = store.data
        defer { store.data = original }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.notionEnabled = false
        settings.motion.style = .none
        settings.motion.openDelay = 0
        settings.motion.closeDuration = 0.28
        store.data = settings
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.show()
        controller.expand(focus: true)
        let expanded = controller.panel.frame
        // This point is inside the expanded panel but below the collapsed notch.
        var pointer = NSPoint(x: expanded.midX, y: expanded.midY)
        controller.hoverPointerLocation = { pointer }
        controller.root.onHoverChange?(true)
        store.data.motion.style = .linear
        controller.closeFromHotKey()
        // Shrinking/replacing tracking areas reports exit/entry without mouse motion.
        // Exercise both the 0.28s closing animation and events after it finishes.
        for _ in 0..<10 {
            controller.root.onHoverChange?(false)
            controller.root.onHoverChange?(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertFalse(controller.isExpanded, "A stationary pointer in the old panel must not rearm hover")
        }
        XCTAssertLessThan(controller.panel.frame.width, expanded.width)
        let collapsed = controller.panel.frame
        // Even movement into the collapsed notch is still inside the original region.
        pointer = NSPoint(x: collapsed.midX, y: collapsed.midY)
        controller.root.onHoverChange?(false)
        controller.root.onHoverChange?(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.isExpanded)
        XCTAssertEqual(controller.panel.frame.width, collapsed.width, accuracy: 0.5)
        // Leaving the old panel may produce no tracking event after collapse.
        pointer = NSPoint(x: expanded.minX - 100, y: expanded.minY - 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.isExpanded)
        pointer = NSPoint(x: collapsed.midX, y: collapsed.midY)
        controller.root.onHoverChange?(true)
        XCTAssertTrue(controller.isExpanded, "Physical exit followed by a fresh entry must restore hover opening")
    }

    @MainActor
    func testExplicitCloseSuppressesHoverAndReturnIgnoresPointerTransitions() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore.shared
        let original = store.data
        defer { store.data = original }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.notionEnabled = false
        settings.motion.style = .none
        settings.motion.openDelay = 0
        settings.motion.closeDelay = 0
        store.data = settings
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.hoverPointerLocation = { NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1) }
        controller.root.onHoverChange?(true)
        XCTAssertTrue(controller.isExpanded)
        controller.closeFromHotKey()
        controller.root.onHoverChange?(true)
        XCTAssertFalse(controller.isExpanded, "A pointer still inside must not reopen an explicit close")
        controller.root.onHoverChange?(false)
        controller.root.onHoverChange?(true)
        XCTAssertFalse(controller.isExpanded, "Tracking-area replacement must not rearm hover under a stationary pointer")
        controller.hoverPointerLocation = { NSPoint(x: screen.frame.minX - 100, y: screen.frame.minY - 100) }
        controller.root.onHoverChange?(false)
        controller.root.onHoverChange?(true)
        XCTAssertTrue(controller.isExpanded, "A fresh entry restores ordinary hover behavior")
        controller.collapse(animated: false)
        controller.deactivateAfterDetaching = {}
        controller.openFromHotKey(preservingContent: true, returningFromDetached: true)
        for inside in [false, true, false, true] { controller.root.onHoverChange?(inside) }
        XCTAssertTrue(controller.isExpanded, "Returning a tab explicitly holds the notch open")
        controller.closeFromHotKey()
        XCTAssertFalse(controller.isExpanded)
    }

    @MainActor
    func testHotkeyOpenAndReturnShareNonactivatingFocusAndPreserveContent() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = SettingsStore.shared
        let original = store.data
        defer { store.data = original }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.notionEnabled = true
        settings.motion.style = .none
        store.data = settings
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.show()
        manager.browser.showNotion()
        var deactivationStates: [(expanded: Bool, key: Bool)] = []
        controller.deactivateAfterDetaching = {
            deactivationStates.append((controller.isExpanded, controller.panel.isKeyWindow))
        }
        defer { controller.deactivateAfterDetaching = {} }
        func notionButton() throws -> NSButton {
            let views = sequence(first: [manager.browser.view], next: { level in
                let children = level.flatMap(\.subviews)
                return children.isEmpty ? nil : children
            }).flatMap { $0 }
            return try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Notionエージェント" })
        }
        // The return path uses this same entry point with content preservation.
        controller.openFromHotKey(preservingContent: true, returningFromDetached: true)
        XCTAssertEqual(deactivationStates.count, 1)
        XCTAssertFalse(try XCTUnwrap(deactivationStates.first).expanded)
        XCTAssertFalse(try XCTUnwrap(deactivationStates.first).key)
        XCTAssertTrue(controller.isExpanded)
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(controller.panel.isKeyWindow)
        XCTAssertEqual(try notionButton().state, .on)
        controller.collapse(animated: false)
        XCTAssertFalse(controller.isExpanded)
        controller.openFromHotKey()
        XCTAssertTrue(controller.isExpanded)
        XCTAssertTrue(controller.panel.isKeyWindow)
        XCTAssertEqual(deactivationStates.count, 1, "Ordinary hotkey open must leave settings-window activation unchanged")
        XCTAssertEqual(try notionButton().state, .off)
        controller.collapse(animated: false)
        XCTAssertFalse(controller.isExpanded)
    }

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
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
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
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
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
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
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
