import AppKit
import XCTest
@testable import NotchBrowser

final class DetachedToolbarLayoutTests: XCTestCase {
    func testMinimumWidthRemainsFixedWithSeparateTabButtons() {
        XCTAssertEqual(DetachedToolbarLayout.minimumWidth(trafficInset: 70), 378)
        XCTAssertEqual(DetachedToolbarLayout.minimumWidth(trafficInset: 80), 388)
    }

    func testAllIconsFitAtFullWidth() {
        let layout = DetachedToolbarLayout.resolve(availableWidth: 284)
        XCTAssertEqual(layout.visible, [.back, .forward, .home, .reload, .address, .settings, .quit])
        XCTAssertTrue(layout.overflow.isEmpty)
        XCTAssertEqual(layout.width, 284)
    }

    func testEachOverflowBoundaryAndRemovalOrder() {
        for (index, width) in ([284, 252, 220, 188] as [CGFloat]).enumerated() {
            let atBoundary = DetachedToolbarLayout.resolve(availableWidth: width)
            let below = DetachedToolbarLayout.resolve(availableWidth: width - 1)
            XCTAssertEqual(atBoundary.overflow, Array(DetachedToolbarLayout.overflowOrder.prefix(index)))
            XCTAssertEqual(below.overflow, Array(DetachedToolbarLayout.overflowOrder.prefix(index + 1)))
            XCTAssertLessThanOrEqual(below.width, width - 1)
        }
    }

    func testMinimumWidthRetainsNavigationReturnAndMenu() {
        let minimum = DetachedToolbarLayout.minimumWidth(trafficInset: 80)
        XCTAssertEqual(minimum, 388)
        let available = minimum - 80 - 100 - 28 - 4 - 8 - 12
        let layout = DetachedToolbarLayout.resolve(availableWidth: available)
        XCTAssertEqual(layout.visible, [.back, .forward, .reload])
        XCTAssertEqual(layout.overflow, [.quit, .settings, .address, .home])
        XCTAssertEqual(layout.width, 156) // five 28pt icons, including return/menu; four 4pt gaps
        XCTAssertEqual(DetachedToolbarLayout.resolve(availableWidth: 0).visible, layout.visible)
        XCTAssertFalse(layout.visible.contains(.keepOpen))
    }
}
