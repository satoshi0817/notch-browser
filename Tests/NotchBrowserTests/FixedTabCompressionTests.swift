import AppKit
import XCTest
@testable import NotchBrowser

final class FixedTabCompressionTests: XCTestCase {
    func testTitlesCompressBeforeSpacing() {
        let plan = NotchTabLayout.compressionPlan(natural: [80, 80, 80], minimum: [28, 28, 28], available: 160)
        XCTAssertEqual(plan.spacing, 4)
        XCTAssertEqual(plan.contentWidth, 160)
        XCTAssertFalse(plan.scrolls)
        XCTAssertTrue(plan.widths.allSatisfy { $0 >= 28 && $0 < 80 })
    }

    func testSpacingCompressesOnlyAfterTitlesReachMinimum() {
        let plan = NotchTabLayout.compressionPlan(natural: [80, 80, 80], minimum: [28, 28, 28], available: 88)
        XCTAssertEqual(plan.widths, [28, 28, 28])
        XCTAssertEqual(plan.spacing, 2)
        XCTAssertEqual(plan.contentWidth, 88)
        XCTAssertFalse(plan.scrolls)
    }

    func testScrollStartsAfterSpacingReachesZeroWithoutShrinkingSlots() {
        let plan = NotchTabLayout.compressionPlan(natural: [80, 80, 80], minimum: [28, 28, 28], available: 60)
        XCTAssertEqual(plan.widths, [28, 28, 28])
        XCTAssertEqual(plan.spacing, 0)
        XCTAssertEqual(plan.contentWidth, 84)
        XCTAssertEqual(plan.viewportWidth, 60)
        XCTAssertTrue(plan.scrolls)
    }

    @MainActor func testAllModesKeepOtherFixedPageIconsAtSixteenPoints() throws {
        _ = NSApplication.shared
        let image = try XCTUnwrap(NSImage(systemSymbolName: "envelope", accessibilityDescription: nil))
        for mode in NotionTabDisplay.allCases {
            let notion = TabButton(title: "", image: image, target: nil, action: nil)
            notion.configureNotionFixedDisplay(title: "Notion", image: image, display: mode)
            for title in ["メール", "カレンダー", "ドキュメント", "チーム"] {
                let button = TabButton(title: title, image: image, target: nil, action: nil)
                button.notchFixedPage = true
                button.font = .systemFont(ofSize: 12)
                for width in [100.0, 40, 28] {
                    button.frame = NSRect(x: 0, y: 0, width: width, height: 28)
                    let icon = button.notchIconRect(in: button.bounds)
                    XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
                    XCTAssertGreaterThanOrEqual(icon.minX, 0)
                    XCTAssertLessThanOrEqual(icon.maxX, button.bounds.maxX)
                    let cell = try XCTUnwrap(button.cell as? TabButtonCell)
                    let text = cell.displayedTitle(forBounds: button.bounds)
                    if text.hasSuffix("…") { XCTAssertGreaterThanOrEqual(text.dropLast().count, 2) }
                    let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
                    button.cacheDisplay(in: button.bounds, to: bitmap)
                }
            }
            XCTAssertEqual(notion.notchIconRect(in: NSRect(x: 0, y: 0, width: 34, height: 28)).size,
                           NSSize(width: 18, height: 18))
        }
    }

    @MainActor func testOverflowUsesHorizontalScrollViewAndRestoresDirectFixedGroup() throws {
        _ = NSApplication.shared
        let group = NSStackView()
        group.orientation = .horizontal
        group.spacing = 0
        for title in ["メール", "カレンダー", "ドキュメント", "チーム"] {
            let button = TabButton(title: title, image: NSImage(), target: nil, action: nil)
            button.notchFixedPage = true
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            group.addArrangedSubview(button)
        }
        let strip = BrowserTabStripView()
        strip.frame = NSRect(x: 0, y: 0, width: 80, height: 32)
        strip.fixed = group
        strip.addSubview(group)
        strip.fixedWidth = 80
        strip.fixedContentWidth = 112
        strip.setFixedScrolling(true)
        strip.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(group.enclosingScrollView)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertGreaterThan(group.frame.width, scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: 28, y: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        strip.setFixedScrolling(false)
        strip.fixedWidth = 112
        strip.frame.size.width = 140
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.superview === strip)
        XCTAssertNil(group.enclosingScrollView)
    }
}
