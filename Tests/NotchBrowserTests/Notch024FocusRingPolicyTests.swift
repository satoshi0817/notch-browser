import XCTest
@testable import NotchBrowser

final class Notch024FocusRingPolicyTests: XCTestCase {
    func testPointerSelectionHidesInitialFocusRing() {
        var policy = NotionDetailFocusRingPolicy()
        policy.handle(.selected(.pointer))
        XCTAssertFalse(policy.showsRing)
    }

    func testKeyboardMoveAfterPointerSelectionShowsRing() {
        var policy = NotionDetailFocusRingPolicy()
        policy.handle(.selected(.pointer))
        policy.handle(.keyboardFocusMove) // Tab or Shift-Tab handoff.
        XCTAssertTrue(policy.showsRing)
    }

    func testNonPointerSelectionShowsInitialFocusRing() {
        var policy = NotionDetailFocusRingPolicy()
        policy.handle(.selected(.keyboard))
        XCTAssertTrue(policy.showsRing)
    }

    func testPointerClickAfterPointerSelectionKeepsRingHidden() {
        var policy = NotionDetailFocusRingPolicy()
        policy.handle(.selected(.pointer))
        policy.handle(.pointerFocus)
        XCTAssertFalse(policy.showsRing)
    }

    func testNewSelectionResetsPreviousOrigin() {
        var policy = NotionDetailFocusRingPolicy()
        policy.handle(.selected(.pointer))
        policy.handle(.selected(.keyboard))
        XCTAssertTrue(policy.showsRing)
        policy.handle(.selected(.pointer))
        XCTAssertFalse(policy.showsRing)
    }

    func testPointerClickHidesRingAfterKeyboardMove() {
        var policy = NotionDetailFocusRingPolicy()
        policy.handle(.keyboardFocusMove)
        policy.handle(.pointerFocus)
        XCTAssertFalse(policy.showsRing)
        policy.handle(.keyboardFocusMove)
        XCTAssertTrue(policy.showsRing)
    }
}
