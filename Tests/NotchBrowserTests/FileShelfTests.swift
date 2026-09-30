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
        XCTAssertEqual(data.shelfTileSize, .medium)
        XCTAssertTrue(data.shelfHoverDetails)
        XCTAssertFalse(data.shelfDownloads)
    }

    func testOutgoingDragAllowsFinderStyleMoveAndCopy() {
        let external = ShelfTilesView.allowedOperations(for: .outsideApplication)
        XCTAssertTrue(external.contains(.copy))
        XCTAssertTrue(external.contains(.move))
        XCTAssertEqual(ShelfTilesView.allowedOperations(for: .withinApplication), .copy)
    }

    @MainActor func testCollectionDropAddsFileToEmptyShelf() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dropped.txt")
        try Data("dropped".utf8).write(to: url)
        let store = ShelfStore(file: directory.appendingPathComponent("shelf.json"))
        let controller = ShelfViewController(store: store)
        _ = controller.view
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        let info = ShelfTestDraggingInfo(pasteboard: pasteboard)
        XCTAssertTrue(controller.collectionView(controller.tiles, acceptDrop: info,
                                                indexPath: IndexPath(item: 0, section: 0), dropOperation: .before))
        XCTAssertEqual(store.entries.map(\.url), [url])
    }

    @MainActor func testShelfUsesCompactNotchAndPreservesExpandedBrowser() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let original = SettingsStore.shared.data
        defer { SettingsStore.shared.data = original }
        var data = SettingsData()
        data.pinnedTabs = []; data.countdownEnabled = false; data.motion.style = .none
        SettingsStore.shared.data = data
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
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
        XCTAssertEqual(manager.browser.view.frame.height, browserSize.height - manager.shelf.preferredShelfHeight)
        XCTAssertFalse(manager.browser.view.frame.intersects(manager.shelf.view.frame))
        let scroll = try XCTUnwrap(manager.shelf.tiles.enclosingScrollView)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertEqual((manager.shelf.tiles.collectionViewLayout as? NSCollectionViewFlowLayout)?.scrollDirection, .horizontal)
        XCTAssertTrue(manager.shelf.tiles.delegate === manager.shelf)
        XCTAssertTrue(manager.shelf.responds(to: NSSelectorFromString("collectionView:validateDrop:proposedIndexPath:dropOperation:")))
        XCTAssertTrue(manager.shelf.responds(to: NSSelectorFromString("collectionView:acceptDrop:indexPath:dropOperation:")))
        controller.hideShelf()
        XCTAssertTrue(controller.isExpanded)
        XCTAssertEqual(manager.browser.view.frame.size, browserSize)
    }
    func testDropBatchesFormSeparateStacksAndPartialClearCanBeRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("items.json")
        let store = ShelfStore(file: file)
        let urls = (0..<4).map { directory.appendingPathComponent("file\($0).txt") }
        XCTAssertTrue(store.add(Array(urls.prefix(2))))
        XCTAssertTrue(store.add(Array(urls.suffix(2))))
        let rows = ShelfRow.make(from: store.entries)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.isStack))
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertEqual(ShelfRow.make(from: ShelfStore(file: file).entries).map(\.id), rows.map(\.id))
        let expanded = ShelfRow.make(from: store.entries, expanded: [rows[0].id])
        XCTAssertEqual(expanded.count, 4)
        XCTAssertEqual(ShelfRow.files(in: expanded, at: IndexSet([0, 1, 2])).count, 2, "A selected parent and its children must not duplicate outgoing files")
        let removed = rows[0].items[0].id
        store.remove([removed])
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(ShelfRow.make(from: store.entries)[0].items.count, 1)
        store.restoreRemoved()
        XCTAssertEqual(ShelfRow.make(from: store.entries)[0].items.map(\.url), Array(urls.prefix(2)))
        store.splitGroups([rows[0].id])
        XCTAssertEqual(ShelfRow.make(from: store.entries).count, 3)
        store.combine(Set(store.entries.map(\.id)))
        XCTAssertEqual(ShelfRow.make(from: store.entries).count, 1)
        store.togglePin([removed])
        store.clearAll()
        XCTAssertTrue(store.entries.isEmpty, "Explicit clear all also clears pinned references")
        store.restoreRemoved()
        XCTAssertEqual(store.entries.count, 4)
        XCTAssertTrue(store.entries.first { $0.id == removed }!.pinned)
        store.finishDrag(Set(store.entries.map(\.id)))
        XCTAssertEqual(store.entries.map(\.id), [removed], "Successful drag retains pinned files")
    }

    func testRedroppingExistingFileWithAnotherFileGroupsBothWithoutDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(file: directory.appendingPathComponent("items.json"))
        let first = directory.appendingPathComponent("a.txt"), second = directory.appendingPathComponent("b.txt")
        store.add([first]); store.add([first, second])
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(ShelfRow.make(from: store.entries).count, 1)
        XCTAssertEqual(ShelfRow.make(from: store.entries)[0].items.count, 2)
    }

    func testOldShelfEntriesDecodeWithoutGroups() throws {
        let entry = ShelfEntry(url: URL(fileURLWithPath: "/tmp/old.txt"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "groupID")
        let decoded = try JSONDecoder().decode(ShelfEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.groupID)
        XCTAssertEqual(decoded.id, entry.id)
    }

    @MainActor func testStackDragWritesEveryFileAsAnIndependentURL() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (0..<2).map { directory.appendingPathComponent("file\($0).txt") }
        for url in urls { try Data("fixture".utf8).write(to: url) }
        let store = ShelfStore(file: directory.appendingPathComponent("items.json"))
        store.add(urls)
        let controller = ShelfViewController(store: store)
        _ = controller.view
        XCTAssertEqual(controller.collectionView(controller.tiles, numberOfItemsInSection: 0), 1)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(controller.pasteboardItems(forRows: [0])))
        XCTAssertEqual(ShelfViewController.urls(from: pasteboard), urls)
        try FileManager.default.removeItem(at: urls[0])
        XCTAssertTrue(controller.pasteboardItems(forRows: [0]).isEmpty, "Do not silently drag a partial stack")
    }

    @MainActor func testNonemptyShelfSurvivesMouseExitAndBrowserCollapse() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelfStore = ShelfStore(file: directory.appendingPathComponent("items.json"))
        shelfStore.add([directory.appendingPathComponent("file.txt")])
        let original = SettingsStore.shared.data
        defer { SettingsStore.shared.data = original }
        var data = SettingsData()
        data.pinnedTabs = []; data.countdownEnabled = false
        data.motion.style = .none; data.motion.closeDelay = 0
        SettingsStore.shared.data = data
        let manager = NotchManager(shelfStore: shelfStore)
        let controller = NotchController(screen: try XCTUnwrap(NSScreen.screens.first), manager: manager)
        defer { controller.close() }
        controller.show()
        controller.showShelf()
        controller.root.onHoverChange?(false)
        XCTAssertTrue(controller.shelfOnly)
        XCTAssertTrue(controller.isExpanded)
        controller.expand(focus: false)
        XCTAssertTrue(controller.shelfVisible)
        XCTAssertFalse(controller.shelfOnly)
        controller.root.onHoverChange?(false)
        XCTAssertTrue(controller.shelfOnly, "Only the browser collapses; the populated shelf stays open")
        shelfStore.clearAll()
        controller.root.onHoverChange?(false)
        XCTAssertFalse(controller.isExpanded)
    }

}

@MainActor private final class ShelfTestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
