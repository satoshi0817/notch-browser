import AppKit
import XCTest
@testable import NotchBrowser

final class NotchTabLayoutTests: XCTestCase {
    @MainActor
    func testPinnedStripStaysOutsideNormalScrollAndSurvivesModeChanges() throws {
        _ = NSApplication.shared
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.pinnedTabs = [
            PinnedTab(name: "Fixed Mail", url: "about:blank"),
            PinnedTab(name: "Fixed Calendar", url: "about:blank", iconOnly: true)
        ]
        settings.data.notionEnabled = true
        let browser = BrowserViewController()
        browser.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        for _ in 0..<12 { browser.newTab(nil) }
        browser.revealSelectedTabAfterNotchLayout()

        func descendants() -> [NSView] {
            Array(sequence(first: [browser.view], next: { level in
                let children = level.flatMap(\.subviews)
                return children.isEmpty ? nil : children
            }).flatMap { $0 })
        }
        func notion() throws -> TabButton {
            try XCTUnwrap(descendants().compactMap { $0 as? TabButton }.first { $0.accessibilityLabel() == "Notionエージェント" })
        }
        let fixed = try notion()
        XCTAssertFalse(fixed.superview?.superview is NSClipView)
        let pinned = descendants().compactMap { $0 as? TabButton }.filter { $0.accessibilityLabel()?.hasPrefix("Fixed ") == true }
        XCTAssertEqual(pinned.count, 2)
        for button in pinned {
            XCTAssertTrue(button.superview === fixed.superview)
            XCTAssertNil(button.onClose)
        }
        let selected = try XCTUnwrap(descendants().compactMap { $0 as? TabButton }.first { $0 !== fixed && $0.state == .on })
        let clip = try XCTUnwrap(selected.superview?.superview as? NSClipView)
        let normalRect = selected.convert(selected.bounds, to: browser.view)
        for button in pinned {
            XCTAssertEqual(button.convert(button.bounds, to: browser.view).midY, normalRect.midY, accuracy: 0.5)
        }
        let scroll = try XCTUnwrap(clip.superview as? NSScrollView)
        let fade = try XCTUnwrap(scroll.layer?.mask as? CAGradientLayer)
        XCTAssertEqual(try XCTUnwrap(fade.locations?[1]).doubleValue * Double(scroll.bounds.width), 12, accuracy: 0.5)
        XCTAssertNotNil(selected.onClose)
        let group = try XCTUnwrap(fixed.superview)
        XCTAssertEqual(group.frame.height, clip.frame.height, accuracy: 0.5)
        let widthConstraint = try XCTUnwrap(group.constraints.first {
            $0.firstAttribute == .width && $0.secondItem == nil && $0.relation == .equal
        })
        XCTAssertEqual(group.frame.width, widthConstraint.constant, accuracy: 0.5)
        XCTAssertLessThanOrEqual(group.convert(group.bounds, to: browser.view).maxX,
                                clip.convert(clip.bounds, to: browser.view).minX + 0.5)
        XCTAssertGreaterThan(clip.bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(selected.frame.minX, clip.bounds.minX - 0.5)
        XCTAssertLessThanOrEqual(selected.frame.maxX, clip.bounds.maxX + 0.5)
        let before = fixed.convert(fixed.bounds, to: browser.view)
        clip.scroll(to: .zero)
        XCTAssertEqual(fixed.convert(fixed.bounds, to: browser.view), before)
        // Resizing must update the fixed budget before placing/revealing the clip.
        browser.view.setFrameSize(NSSize(width: 1000, height: 700))
        browser.revealSelectedTabAfterNotchLayout()
        XCTAssertEqual(group.frame.width, widthConstraint.constant, accuracy: 0.5)
        XCTAssertLessThanOrEqual(group.convert(group.bounds, to: browser.view).maxX,
                                clip.convert(clip.bounds, to: browser.view).minX + 0.5)
        XCTAssertGreaterThanOrEqual(selected.frame.minX, clip.bounds.minX - 0.5)
        XCTAssertLessThanOrEqual(selected.frame.maxX, clip.bounds.maxX + 0.5)

        let resizedNormalY = selected.convert(selected.bounds, to: browser.view).midY
        for button in pinned {
            XCTAssertEqual(button.convert(button.bounds, to: browser.view).midY, resizedNormalY, accuracy: 0.5)
        }
        browser.isDetached = true
        browser.updateDetachedMetrics(trafficInset: 80, rowHeight: 28)
        XCTAssertTrue(try notion().superview?.superview is NSClipView)
        browser.isDetached = false
        browser.revealSelectedTabAfterNotchLayout()
        XCTAssertFalse(try notion().superview?.superview is NSClipView)
        let restoredButtons = descendants().compactMap { $0 as? TabButton }
        let restoredNormal = try XCTUnwrap(restoredButtons.first { $0.state == .on && $0.onClose != nil })
        let restoredNormalY = restoredNormal.convert(restoredNormal.bounds, to: browser.view).midY
        for button in restoredButtons where button.accessibilityLabel()?.hasPrefix("Fixed ") == true {
            XCTAssertEqual(button.convert(button.bounds, to: browser.view).midY, restoredNormalY, accuracy: 0.5)
        }
        XCTAssertEqual(descendants().compactMap { $0 as? TabButton }.filter { $0.accessibilityLabel() == "Notionエージェント" }.count, 1)
    }

    func testPinnedWidthReservesNormalSlot() {
        XCTAssertEqual(NotchTabLayout.pinnedWidth(natural: 200, available: 180, hasNormal: true), 30)
        XCTAssertEqual(NotchTabLayout.pinnedWidth(natural: 100, available: 280, hasNormal: true), 100)
        XCTAssertEqual(NotchTabLayout.pinnedWidth(natural: 200, available: 180, hasNormal: false), 180)
        XCTAssertEqual(NotchTabLayout.pinnedWidth(natural: 100, available: 10, hasNormal: true), 0)
    }

    func testFixedWidthsKeepIconsAndTruncateLongTitles() {
        XCTAssertEqual(NotchTabLayout.fixedWidths(natural: [28, 150, 100], available: 156), [28, 60, 60])
        XCTAssertEqual(NotchTabLayout.fixedWidths(natural: [28, 60], available: 200), [28, 60])
        XCTAssertEqual(NotchTabLayout.fixedWidths(natural: [], available: 0), [])
    }

    func testSelectedNormalTabRevealsBothEdges() {
        let frame = NSRect(x: 240, y: 0, width: 80, height: 32)
        XCTAssertEqual(NotchTabLayout.revealOrigin(current: 0, viewport: 100, document: 500, selected: frame), 220)
        XCTAssertEqual(NotchTabLayout.revealOrigin(current: 300, viewport: 100, document: 500, selected: frame), 240)
        XCTAssertEqual(NotchTabLayout.revealOrigin(current: 230, viewport: 100, document: 500, selected: frame), 230)
    }

    func testRevealClampsAfterRemovalAndHandlesOversizedTab() {
        XCTAssertEqual(NotchTabLayout.revealOrigin(current: 400, viewport: 200, document: 100, selected: NSRect(x: 0, y: 0, width: 80, height: 32)), 0)
        XCTAssertEqual(NotchTabLayout.revealOrigin(current: 0, viewport: 40, document: 500, selected: NSRect(x: 100, y: 0, width: 150, height: 32)), 100)
    }
}
