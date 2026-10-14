import AppKit
import XCTest
@testable import NotchBrowser

final class NotionTabBarDesignerTests: XCTestCase {
    func testTitleWidthUsesMeasuredTextAndCapsAt120() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        XCTAssertEqual(NotchTabLayout.notionTabWidth(title: "タスク", display: .titleOnly, measure: measure), 42)
        XCTAssertEqual(NotchTabLayout.notionTabWidth(title: "議事録", display: .iconAndTitle, measure: measure), 64)
        XCTAssertEqual(NotchTabLayout.notionTabWidth(title: "Notion", display: .iconAndTitle, measure: measure), 94)
        XCTAssertEqual(NotchTabLayout.notionTabWidth(title: "長いタイトル", display: .iconOnly, measure: measure), 34)
        XCTAssertEqual(NotchTabLayout.fixedWidths(natural: [80, 64, 70], available: 170, spacing: 4,
                                                  preserving: [1, 2]), [28, 64, 70])
        for display in [NotionTabDisplay.titleOnly, .iconAndTitle] {
            let width = NotchTabLayout.notionTabWidth(title: String(repeating: "長", count: 20), display: display, measure: measure)
            XCTAssertEqual(width, 120)
            let rect = NotchTabLayout.notionTitleRect(in: NSRect(x: 0, y: 0, width: width, height: 28), display: display)
            let text = NotchTabLayout.displayedTitle(String(repeating: "長", count: 20), available: rect.width, measure: measure)
            XCTAssertTrue(text.hasSuffix("…"))
            XCTAssertGreaterThanOrEqual(text.dropLast().count, 2)
        }
    }

    @MainActor func testBothModeKeepsIconAndFullTitleDuringDrawing() throws {
        _ = NSApplication.shared
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "checklist", accessibilityDescription: nil))
        for title in ["タスク", "議事録", "Notion"] {
            let button = TabButton(title: "", image: icon, target: nil, action: nil)
            button.font = .systemFont(ofSize: 12)
            button.configureNotionFixedDisplay(title: title, image: icon, display: .iconAndTitle)
            let width = NotchTabLayout.notionTabWidth(title: title, display: .iconAndTitle) {
                ($0 as NSString).size(withAttributes: [.font: button.font!]).width
            }
            button.frame = NSRect(x: 0, y: 0, width: width, height: 28)
            let cell = try XCTUnwrap(button.cell as? TabButtonCell)
            XCTAssertNotNil(button.image)
            XCTAssertEqual(button.imagePosition, .imageLeft)
            XCTAssertEqual(cell.displayedTitle(forBounds: button.bounds), title)
            XCTAssertEqual(cell.titleRect(forBounds: button.bounds).minX, 28)
            XCTAssertEqual(button.toolTip, title)
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            XCTAssertEqual(button.title, title, "Drawing must not mutate the title used for width calculation")
        }
    }

    @MainActor func testTitleModeShowsShortNamesAndTruncatesOnlyLongTitles() throws {
        _ = NSApplication.shared
        for title in ["タスク", "議事録", "Notion", String(repeating: "議事録", count: 10)] {
            let button = TabButton(title: "", image: NSImage(), target: nil, action: nil)
            button.font = .systemFont(ofSize: 12)
            button.configureNotionFixedDisplay(title: title, image: NSImage(), display: .titleOnly)
            let width = NotchTabLayout.notionTabWidth(title: title, display: .titleOnly) {
                ($0 as NSString).size(withAttributes: [.font: button.font!]).width
            }
            button.frame = NSRect(x: 0, y: 0, width: width, height: 28)
            let cell = try XCTUnwrap(button.cell as? TabButtonCell)
            XCTAssertNil(button.image)
            XCTAssertEqual(button.imagePosition, .noImage)
            let text = cell.displayedTitle(forBounds: button.bounds)
            if title.count < 10 { XCTAssertEqual(text, title) }
            else {
                XCTAssertEqual(width, 120)
                XCTAssertTrue(text.hasSuffix("…"))
                XCTAssertGreaterThanOrEqual(text.dropLast().count, 2)
            }
            XCTAssertEqual(button.toolTip, title)
            button.frame.size.width = 12
            XCTAssertEqual(cell.displayedTitle(forBounds: button.bounds), "")
        }
    }

    func testMeetingRowMetadataUsesMiddleDotsAndOmitsUnknownDuration() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        for hasEnd in [true, false] {
            var calendar = ["start": "2026-10-14T02:04:00Z"]
            if hasEnd { calendar["end"] = "2026-10-14T02:49:00Z" }
            let meeting = try XCTUnwrap(NotionMeeting.parse([
                "id": "meeting", "type": "meeting_notes",
                "meeting_notes": ["title": "定例", "calendar": calendar, "attendees": ["a", "b", "c"]]
            ]))
            XCTAssertEqual(meeting.rowMetadata(timeZone: zone), hasEnd ? "11:04・45分・3人" : "11:04・3人")
        }
    }
}
