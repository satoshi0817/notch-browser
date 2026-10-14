import AppKit
import XCTest
@testable import NotchBrowser

final class FixedTabBackground019Tests: XCTestCase {
    @MainActor
    func testAllThreeTabsHaveTransparentOffAndBlueOnBezelInEveryDisplayMode() throws {
        _ = NSApplication.shared
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.notionEnabled = true
        for mode in [NotionTabDisplay.iconOnly, .titleOnly, .iconAndTitle] {
            settings.data.tasksTabDisplay = mode
            settings.data.meetingsTabDisplay = mode
            settings.data.notionTabDisplay = mode
            let browser = BrowserViewController()
            browser.notionConnection = .preview(connected: true)
            _ = browser.view
            let buttons = sequence(first: [browser.view], next: { level in
                let children = level.flatMap(\.subviews)
                return children.isEmpty ? nil : children
            }).flatMap { $0 }.compactMap { $0 as? TabButton }
            let labels = ["タスク", "議事録", "Notionエージェント"]
            let fixed = try labels.map { label in
                try XCTUnwrap(buttons.first { $0.accessibilityLabel() == label })
            }
            for (index, button) in fixed.enumerated() {
                XCTAssertEqual(button.notchDisplay, mode)
                XCTAssertEqual(button.state, .off)
                try assertBezel(button, selected: false)
                switch index {
                case 0: browser.showTasks()
                case 1: browser.showMeetings()
                default: browser.showNotion()
                }
                for other in fixed {
                    XCTAssertEqual(other.state, other === button ? .on : .off)
                    try assertBezel(other, selected: other === button)
                }
                XCTAssertTrue(browser.dismissOverlay())
                XCTAssertEqual(button.state, .off)
                try assertBezel(button, selected: false)
            }
        }
    }

    @MainActor
    private func assertBezel(_ button: TabButton, selected: Bool,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 28,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 28).fill(using: .copy)
        // Isolate the actual cell's bezel from icon/title ink.
        try XCTUnwrap(button.cell as? TabButtonCell).drawBezel(withFrame: NSRect(x: 0, y: 0, width: 60, height: 28), in: button)
        let color = try XCTUnwrap(bitmap.colorAt(x: 30, y: 14)?.usingColorSpace(.deviceRGB))
        if selected {
            XCTAssertGreaterThan(color.alphaComponent, 0.9, file: file, line: line)
            XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.3, file: file, line: line)
            XCTAssertGreaterThan(color.blueComponent, color.greenComponent + 0.1, file: file, line: line)
        } else {
            XCTAssertEqual(color.alphaComponent, 0, accuracy: 0.001, file: file, line: line)
        }
    }
}
