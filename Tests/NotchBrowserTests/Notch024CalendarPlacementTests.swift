import AppKit
import XCTest
@testable import NotchBrowser

final class Notch024CalendarPlacementTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 500, height: 600)
    private let size = NSSize(width: 160, height: 200)

    func testBelowIsPreferredWithEitherAnchorCoordinateSystem() {
        let anchor = NSRect(x: 240, y: 300, width: 40, height: 20)
        for flipped in [false, true] {
            let result = NotionDueCalendarPlacement.placement(anchorInWindow: anchor,
                windowBounds: bounds, popoverSize: size, flipped: flipped)
            XCTAssertEqual(result.edge, flipped ? .maxY : .minY)
            XCTAssertEqual(result.positioningRect.minY, anchor.minY)
        }
    }

    func testAboveWhenOnlyAboveFits() {
        for flipped in [false, true] {
            let result = NotionDueCalendarPlacement.placement(
                anchorInWindow: NSRect(x: 200, y: 80, width: 40, height: 20),
                windowBounds: bounds, popoverSize: size, flipped: flipped)
            XCTAssertEqual(result.edge, flipped ? .minY : .maxY)
            XCTAssertEqual(result.positioningRect.minY, 100)
        }
    }

    func testNeitherSideFitsUsesLargerSideAndMovesAttachmentInside() {
        let shortWindow = NSRect(x: 0, y: 0, width: 500, height: 350)
        let cases: [(CGFloat, NSRectEdge)] = [(180, .minY), (130, .maxY)]
        for (y, expected) in cases {
            let result = NotionDueCalendarPlacement.placement(
                anchorInWindow: NSRect(x: 200, y: y, width: 40, height: 20),
                windowBounds: shortWindow, popoverSize: size, flipped: false)
            XCTAssertEqual(result.edge, expected)
            let tip = result.positioningRect.minY
            if expected == .minY { XCTAssertGreaterThanOrEqual(tip - size.height - 13, 4) }
            else { XCTAssertLessThanOrEqual(tip + size.height + 13, 346) }
        }
    }

    func testHorizontalAttachmentClampsAtBothWindowEdges() {
        let positions: [CGFloat] = [0, 480]
        for x in positions {
            let result = NotionDueCalendarPlacement.placement(
                anchorInWindow: NSRect(x: x, y: 300, width: 20, height: 20),
                windowBounds: bounds, popoverSize: size, flipped: false)
            let halfWidth = (size.width + 26) / 2
            XCTAssertGreaterThanOrEqual(result.positioningRect.midX - halfWidth, 4)
            XCTAssertLessThanOrEqual(result.positioningRect.midX + halfWidth, 496)
        }
    }

    func testActualChromeFrameIsClampedWithoutChangingSize() {
        let safe = bounds.insetBy(dx: 4, dy: 4)
        for origin in [NSPoint(x: -30, y: -50), NSPoint(x: 450, y: 550)] {
            let result = NotionDueCalendarPlacement.containedFrame(
                NSRect(origin: origin, size: size), in: safe)
            XCTAssertEqual(result.size, size)
            XCTAssertTrue(safe.contains(result))
        }
    }
}
