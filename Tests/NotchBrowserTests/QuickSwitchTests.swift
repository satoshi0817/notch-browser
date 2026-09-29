import AppKit
import XCTest
@testable import NotchBrowser

final class QuickSwitchTests: XCTestCase {
    @MainActor func testPanelReplacesEntireBrowserAreaAndRestoresShelf() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let saved = SettingsStore.shared.data
        defer { SettingsStore.shared.data = saved }
        var settings = SettingsData(); settings.pinnedTabs = []; settings.countdownEnabled = false; settings.motion.style = .none
        SettingsStore.shared.data = settings
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(file: directory.appendingPathComponent("shelf.json"))
        store.add([directory.appendingPathComponent("example.txt")])
        let manager = NotchManager(shelfStore: store)
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.show(); controller.expand(focus: false)
        XCTAssertTrue(controller.shelfVisible)
        let windowCount = NSApp.windows.count
        manager.browser.setQuickSwitchVisible(true)
        XCTAssertEqual(NSApp.windows.count, windowCount, "Switches must reuse the notch, not open a separate window")
        controller.layoutContent()
        XCTAssertTrue(manager.browser.quickSwitchVisible)
        XCTAssertEqual(manager.browser.view.frame.height, controller.root.content.bounds.height)
        XCTAssertTrue(manager.shelf.view.isHidden)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(manager.browser.dismissOverlay())
        controller.layoutContent()
        XCTAssertFalse(manager.browser.quickSwitchVisible)
        XCTAssertFalse(manager.shelf.view.isHidden)
        XCTAssertEqual(manager.browser.view.frame.height, controller.root.content.bounds.height - 220)
        manager.browser.setQuickSwitchVisible(true)
        controller.collapse(animated: false)
        XCTAssertFalse(manager.browser.quickSwitchVisible)
        XCTAssertTrue(controller.shelfOnly)
        XCTAssertFalse(manager.shelf.view.isHidden)
    }

    @MainActor func testKeepAwakeCanSwitchModeAndReleaseItsAssertion() {
        let store = QuickSwitchStore()
        defer { store.keepAwake(minutes: 0) }
        store.keepAwake(minutes: 15)
        XCTAssertTrue(store.isAwake)
        XCTAssertFalse(store.keepsDisplayAwake)
        XCTAssertEqual(store.awakeUntil!.timeIntervalSinceNow, 900, accuracy: 2)
        store.keepAwake(minutes: -1, display: true)
        XCTAssertTrue(store.isAwake)
        XCTAssertTrue(store.keepsDisplayAwake)
        XCTAssertEqual(store.awakeUntil, .distantFuture)
        store.keepAwake(minutes: 0)
        XCTAssertFalse(store.isAwake)
        XCTAssertFalse(store.keepsDisplayAwake)
        XCTAssertNil(store.awakeUntil)
        store.keepAwake(minutes: Int.max)
        XCTAssertFalse(store.isAwake)
        XCTAssertNotNil(store.message)
    }
}
