import AppKit
import XCTest
@testable import NotchBrowser

final class TabSelectionAppearanceTests: XCTestCase {
    @MainActor
    func testNotionSelectionReplacesPinnedTabHighlightAndRestoresItOnClose() throws {
        _ = NSApplication.shared
        let browser = BrowserViewController()
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
