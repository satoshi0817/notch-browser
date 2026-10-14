import AppKit
import XCTest
@testable import NotchBrowser

final class FixedTabActualBudgetTests: XCTestCase {
    @MainActor func test960PointNotchBudgetKeepsBothModeTitles() throws {
        _ = NSApplication.shared
        let names = ["メール", "カレンダー", "ドキュメント", "チーム", "Notion", "タスク", "議事録"]
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "envelope", accessibilityDescription: nil))
        let buttons = names.enumerated().map { index, name -> TabButton in
            let button = TabButton(title: name, image: icon, target: nil, action: nil)
            button.font = .systemFont(ofSize: 12)
            button.notchFixedPage = true
            if index >= 4 {
                button.configureNotionFixedDisplay(title: name, image: icon, display: .iconAndTitle,
                                                  iconSide: NotchTabLayout.fixedIconSide)
            }
            return button
        }
        let natural = buttons.enumerated().map { index, button in
            NotchTabLayout.fixedTabWidth(title: button.title, display: .iconAndTitle,
                maximum: index >= 4 ? 120 : 150) {
                ($0 as NSString).size(withAttributes: [.font: button.font!]).width
            }
        }
        let minimum = natural.enumerated().map { $0.offset >= 4 ? $0.element : 28 }
        // Same 960pt, center -110pt, leading 14pt, add 28pt and 4pt gap
        // calculation that BrowserViewController uses, including normal tabs.
        let budget = NotchTabLayout.fixedTabBudget(windowWidth: 960, trailingOffset: -110,
            leadingInset: 14, addWidth: 28, hasNormal: true, normalWidth: 150, showingFixedPanel: true)
        XCTAssertEqual(budget, 296)
        let plan = NotchTabLayout.compressionPlan(natural: natural, minimum: minimum, available: budget)
        XCTAssertLessThanOrEqual(plan.viewportWidth, budget)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 0, y: 0, width: plan.widths[index], height: 32)
            XCTAssertEqual(button.notchIconRect(in: button.bounds).size, NSSize(width: 16, height: 16))
            if index >= 4 {
                let cell = try XCTUnwrap(button.cell as? TabButtonCell)
                XCTAssertEqual(cell.displayedTitle(forBounds: button.bounds), names[index])
                XCTAssertNotNil(button.image)
            }
        }
    }

    @MainActor func testProductionIconConfigurationIsIdenticalAcrossModes() throws {
        _ = NSApplication.shared
        for mode in NotionTabDisplay.allCases {
            let button = TabButton(title: "", image: NSImage(), target: nil, action: nil)
            button.configureNotionFixedDisplay(title: "タスク", image: NSImage(), display: mode,
                                              iconSide: NotchTabLayout.fixedIconSide)
            XCTAssertEqual(button.notchIconSide, 16)
            XCTAssertEqual(button.notchIconRect(in: NSRect(x: 0, y: 0, width: 80, height: 32)).size,
                           NSSize(width: 16, height: 16))
        }
    }
}
