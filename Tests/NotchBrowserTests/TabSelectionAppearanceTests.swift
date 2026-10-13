import AppKit
import XCTest
@testable import NotchBrowser

final class TabSelectionAppearanceTests: XCTestCase {

    @MainActor
    func testDisconnectRemovesBothNotionTabsAndRestoresPreviousBrowserTab() throws {
        _ = NSApplication.shared
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.pinnedTabs = [PinnedTab(name: "Previous", url: "about:blank")]
        settings.data.notionEnabled = true
        for showTasks in [false, true] {
            let connection = NotionConnectionStore.preview(connected: true)
            let browser = BrowserViewController()
            browser.notionConnection = connection
            _ = browser.view
            browser.newTab(nil)

            func buttons() -> [NSButton] {
                Array(sequence(first: [browser.view], next: { level in
                    let children = level.flatMap(\.subviews)
                    return children.isEmpty ? nil : children
                }).flatMap { $0 }.compactMap { $0 as? NSButton })
            }
            let initiallySelected = try XCTUnwrap(buttons().first { $0 is TabButton && $0.state == .on })
            let previousTag = initiallySelected.tag
            let previousLabel = initiallySelected.accessibilityLabel()
            // updateChrome rebuilds browser-tab buttons. Follow the same logical tab,
            // rather than retaining a button that has been removed from the hierarchy.
            func previousButton() throws -> NSButton {
                try XCTUnwrap(buttons().first {
                    $0 is TabButton && $0.tag == previousTag && $0.accessibilityLabel() == previousLabel
                })
            }
            let tasks = try XCTUnwrap(buttons().first { $0.accessibilityLabel() == "タスク" })
            let agents = try XCTUnwrap(buttons().first { $0.accessibilityLabel() == "Notionエージェント" })
            // Test each overlay, including switching from agents to tasks before disconnecting.
            browser.refreshTasksAvailability()
            browser.showNotion()
            if showTasks { browser.showTasks() }
            XCTAssertEqual(try previousButton().state, .off)
            connection.disconnect()
            browser.refreshTasksAvailability()
            XCTAssertEqual(try previousButton().state, .on)
            XCTAssertEqual(tasks.state, .off)
            XCTAssertEqual(agents.state, .off)
            XCTAssertNil(tasks.superview)
            XCTAssertNil(agents.superview)
            XCTAssertEqual(buttons().filter { $0 is TabButton && $0.state == .on }.count, 1,
                           "Only the previous browser tab must be selected after disconnect")
        }
    }

    @MainActor
    func testNotionSelectionReplacesPinnedTabHighlightAndRestoresItOnClose() throws {
        _ = NSApplication.shared
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.notionEnabled = true
        let browser = BrowserViewController()
        browser.notionConnection = .preview(connected: true)
        _ = browser.view
        func button(_ label: String) throws -> NSButton {
            let views = sequence(first: [browser.view], next: { level in
                let children = level.flatMap(\.subviews)
                return children.isEmpty ? nil : children
            }).flatMap { $0 }
            return try XCTUnwrap(views.compactMap { $0 as? NSButton }
                .first(where: { $0.accessibilityLabel() == label }))
        }
        let notion = try button("Notionエージェント")
        XCTAssertEqual(notion.state, .off)
        browser.showNotion()
        XCTAssertEqual(notion.state, .on)
        browser.hideNotion()
        XCTAssertEqual(notion.state, .off)
    }

    @MainActor
    func testNotionTabDisplayAndFeatureSwitchUpdateThePinnedStrip() throws {
        _ = NSApplication.shared
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.notionEnabled = true
        settings.data.notionTabDisplay = .iconAndTitle
        let browser = BrowserViewController()
        browser.notionConnection = .preview(connected: true)
        _ = browser.view
        func notionButton() throws -> NSButton {
            let views = sequence(first: [browser.view], next: { level in
                let children = level.flatMap(\.subviews)
                return children.isEmpty ? nil : children
            }).flatMap { $0 }
            return try XCTUnwrap(views.compactMap { $0 as? NSButton }
                .first(where: { $0.accessibilityLabel() == "Notionエージェント" }))
        }
        let notion = try notionButton()
        XCTAssertEqual(notion.title, "Notion")
        XCTAssertNotNil(notion.image)
        settings.data.notionTabDisplay = .iconOnly
        browser.settingsChanged()
        XCTAssertEqual(notion.title, "")
        XCTAssertNotNil(notion.image)
        settings.data.notionTabDisplay = .titleOnly
        browser.settingsChanged()
        XCTAssertEqual(notion.title, "Notion")
        XCTAssertNil(notion.image)
        settings.data.notionEnabled = false
        browser.settingsChanged()
        XCTAssertNil(notion.superview)
        browser.showNotion()
        XCTAssertEqual(notion.state, .off)
    }

    @MainActor
    func testSelectedTabStaysBlueBeforeFocusAndAfterReopening() throws {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.orderOut(nil) }
        panel.appearance = NSAppearance(named: .darkAqua)
        let button = TabButton(title: "", image: NSImage(size: .zero), target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 60, height: 28)
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.state = .on
        panel.contentView?.addSubview(button)

        func centerColor() throws -> NSColor {
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        func assertBlue(file: StaticString = #filePath, line: UInt = #line) throws {
            let color = try centerColor()
            XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.3, file: file, line: line)
            XCTAssertGreaterThan(color.blueComponent, color.greenComponent + 0.1, file: file, line: line)
        }

        panel.orderFrontRegardless()
        XCTAssertFalse(panel.isKeyWindow)
        try assertBlue()
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        try assertBlue()
        panel.resignKey()
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        XCTAssertFalse(panel.isKeyWindow)
        try assertBlue()

        button.state = .off
        let unselected = try centerColor()
        XCTAssertLessThan(abs(unselected.blueComponent - unselected.redComponent), 0.1)
    }
}
