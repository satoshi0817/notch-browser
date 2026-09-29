import AppKit
import XCTest
@testable import NotchBrowser

final class FileShelfTests: XCTestCase {
    func testDragStartDoesNotReuseStalePasteboardAndCancellationEndsSession() {
        var state = ShelfDragState(generation: 10)
        XCTAssertFalse(state.update(generation: 10, pressed: true, hasFiles: true))
        XCTAssertTrue(state.update(generation: 11, pressed: true, hasFiles: true))
        XCTAssertTrue(state.update(generation: 11, pressed: true, hasFiles: true))
        XCTAssertFalse(state.update(generation: 11, pressed: true, hasFiles: true, cancelled: true))
        XCTAssertFalse(state.update(generation: 11, pressed: true, hasFiles: true))
        XCTAssertFalse(state.update(generation: 12, pressed: true, hasFiles: false))
        XCTAssertTrue(state.update(generation: 12, pressed: true, hasFiles: true), "Delayed file types can arrive after the generation changes")
        XCTAssertFalse(state.update(generation: 12, pressed: false, hasFiles: true))
        XCTAssertFalse(state.update(generation: 12, pressed: true, hasFiles: true))
    }

    func testPersistenceDeduplicationPinningAndRemovalPreserveOriginalFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("日本語 a.txt")
        let b = directory.appendingPathComponent("b.txt")
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)
        let file = directory.appendingPathComponent("shelf.json")
        let store = ShelfStore(file: file)
        XCTAssertTrue(store.add([a, b, a]))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(store.add([URL(string: "https://example.com")!]))
        let id = try XCTUnwrap(store.entries.first?.id)
        store.togglePin([id])
        let restored = ShelfStore(file: file)
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertTrue(restored.entries[0].pinned)
        restored.clearUnpinned()
        XCTAssertEqual(restored.entries.map(\.id), [id])
        restored.remove([id])
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: a), "first")
        XCTAssertEqual(try String(contentsOf: b), "second")
    }

    func testFailedSaveDoesNotPretendDropSucceeded() throws {
        let store = ShelfStore(file: URL(fileURLWithPath: "/dev/null/items.json"))
        XCTAssertFalse(store.add([URL(fileURLWithPath: "/tmp/example")]))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.error)
    }

    func testOldSettingsKeepShelfDefaults() throws {
        let data = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(data.shelfTrigger, .automatic)
        XCTAssertFalse(data.shelfDownloads)
    }

    @MainActor func testShelfUsesCompactNotchAndPreservesExpandedBrowser() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let original = SettingsStore.shared.data
        defer { SettingsStore.shared.data = original }
        var data = SettingsData()
        data.pinnedTabs = []; data.countdownEnabled = false; data.motion.style = .none
        SettingsStore.shared.data = data
        let manager = NotchManager()
        let controller = NotchController(screen: screen, manager: manager)
        defer { controller.close() }
        controller.show()
        controller.showShelf()
        XCTAssertTrue(controller.shelfOnly)
        XCTAssertLessThan(controller.expandedSize.width, 500)
        XCTAssertFalse(controller.panel.isKeyWindow, "Automatic shelf must not take focus")
        controller.hideShelf()
        XCTAssertFalse(controller.isExpanded)
        controller.expand(focus: false)
        let browserSize = manager.browser.view.frame.size
        controller.showShelf()
        XCTAssertFalse(controller.shelfOnly)
        XCTAssertEqual(manager.browser.view.frame.height, browserSize.height - 220)
        XCTAssertFalse(manager.browser.view.frame.intersects(manager.shelf.view.frame))
        controller.hideShelf()
        XCTAssertTrue(controller.isExpanded)
        XCTAssertEqual(manager.browser.view.frame.size, browserSize)
    }
}
