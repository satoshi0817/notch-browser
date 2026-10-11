import AppKit
import XCTest
@testable import NotchBrowser

final class DetachedTabLayoutTests: XCTestCase {
    func testSeparateOverflowAndPermanentNewTabBudgetsAcrossWidthSweep() {
        for total in [2, 3, 5, 7, 8] {
            var previousVisible = 0
            for requested in stride(from: 381, through: 1000, by: 1) {
                let traffic: CGFloat = 70
                let fixed = traffic + 12 + 28 + 4 + 8
                let divider: CGFloat = total > 2 ? 6 : 0
                let width = CGFloat(requested)
                let plan = DetachedTabLayout.planWithOverflowButton(available: width - fixed - divider, count: total, fullWidth: 140, minimumVisible: min(total, 3))
                let normals = total - 2
                let a = DetachedTabLayout.distribute(plan: plan, pinnedCount: 2, normalCount: normals, selectedNormal: normals > 0 ? 0 : nil)
                let z = DetachedTabLayout.distribute(plan: plan, pinnedCount: 2, normalCount: normals, selectedNormal: normals > 0 ? normals - 1 : nil)
                XCTAssertEqual(a.hiddenNormalCount, z.hiddenNormalCount)
                if !plan.toolbar.visible.contains(.reload) {
                    XCTAssertGreaterThan(a.hiddenNormalCount, 0)
                    XCTAssertLessThan(width - fixed - divider - 32 - DetachedToolbarLayout.width(for: 3), 3 * 28 + 4)
                    XCTAssertTrue(plan.toolbar.overflow.contains(.reload))
                }
                if normals > 0 {
                    XCTAssertTrue(a.visibleNormalIndices.contains(0))
                    XCTAssertTrue(z.visibleNormalIndices.contains(normals - 1))
                }
                let shown = 2 + a.visibleNormalIndices.count
                XCTAssertGreaterThanOrEqual(shown, previousVisible)
                previousVisible = shown
                let overflowWidth = a.hiddenNormalCount > 0 ? DetachedTabLayout.overflowButtonWidth + DetachedTabLayout.overflowButtonGap : 0
                let tabs = CGFloat(shown) * a.width + CGFloat(shown - 1) * 2 + divider
                XCTAssertLessThanOrEqual(tabs + overflowWidth + fixed + plan.toolbar.width, width + 0.001)
                XCTAssertGreaterThanOrEqual(a.width, 28)
                if a.hiddenNormalCount > 0 { XCTAssertLessThanOrEqual(a.width, 36) }
                if total <= 3 || (total == 5 && requested == 440) { XCTAssertEqual(a.hiddenNormalCount, 0) }
            }
        }
    }

    func testReloadFoldsOnlyAtOverflowMinimumBoundary() {
        for total in [5, 7, 8] {
            for width in [381, 390, 400, 403, 404, 440] {
                // 70pt traffic inset + 52pt permanent +/gaps/right margin,
                // 6pt divider allowance; 32pt +N slot; 88pt for three tabs.
                let plan = DetachedTabLayout.planWithOverflowButton(available: CGFloat(width) - 128, count: total, fullWidth: 140, minimumVisible: 3)
                XCTAssertEqual(plan.toolbar.visible.contains(.reload), width >= 404)
                XCTAssertGreaterThanOrEqual(plan.capacity, 3)
                if width < 404 {
                    XCTAssertGreaterThan(plan.overflow, 0)
                    XCTAssertEqual(plan.toolbar.overflow, [.quit, .settings, .address, .home, .reload])
                }
            }
        }
    }

    func test156PointBandFitsFiveTabsUsingActualSpacing() {
        let result = DetachedTabLayout.distribute(available: 156 - 6 + DetachedToolbarLayout.width(for: 3), pinnedCount: 2, normalCount: 3, selectedNormal: 2, fullWidth: 120, spacing: 2)
        XCTAssertEqual(result.hiddenNormalCount, 0)
        XCTAssertGreaterThanOrEqual(result.width, 28)
        XCTAssertLessThanOrEqual(5 * result.width + 5 * 2 + 4, 156)
    }

    func testToolbarAndOverflowRemainInsideWindowBudgetAcrossShrinkingWidths() {
        for count in [5, 7, 8] {
            var previous = count
            for width in [1000, 480, 440, 400, 390, 381] {
                let traffic: CGFloat = 70
                let fixed = traffic + 12 + 28 + 4 + 8
                let result = DetachedTabLayout.distribute(available: CGFloat(width) - fixed - 6, pinnedCount: 2, normalCount: count - 2, selectedNormal: count - 3, fullWidth: 140, spacing: 2)
                let shown = 2 + result.visibleNormalIndices.count
                XCTAssertLessThanOrEqual(shown, previous)
                previous = shown
                let document = CGFloat(shown) * result.width + CGFloat(shown) * 2 + 4
                XCTAssertLessThanOrEqual(document + fixed + result.plan.toolbar.width, CGFloat(width))
                XCTAssertTrue(result.visibleNormalIndices.contains(count - 3))
            }
        }
    }
    func test159PointBandFitsFiveTabsAt28AndOverflowDistributesSpareWidth() {
        // 5 tabs + one divider use five 3pt gaps and a 4pt separator: 159pt.
        let fit = DetachedTabLayout.distribute(available: 159 - 7 + DetachedToolbarLayout.width(for: 3), pinnedCount: 2, normalCount: 3, selectedNormal: 2, fullWidth: 120, spacing: 3)
        XCTAssertEqual(fit.hiddenNormalCount, 0)
        XCTAssertEqual(fit.width, 28)
        for band in [100.0, 109, 119, 159] {
            for total in [5, 7] {
                let result = DetachedTabLayout.distribute(available: band - 7 + DetachedToolbarLayout.width(for: 3), pinnedCount: 2, normalCount: total - 2, selectedNormal: total - 3, fullWidth: 120, spacing: 3)
                let count = 2 + result.visibleNormalIndices.count
                XCTAssertGreaterThanOrEqual(result.width, 28)
                if result.hiddenNormalCount > 0 { XCTAssertLessThanOrEqual(result.width, 36) }
                XCTAssertLessThanOrEqual(CGFloat(count) * result.width + CGFloat(count) * 3 + 4, band)
                XCTAssertTrue(result.visibleNormalIndices.contains(total - 3))
            }
        }
    }

    @MainActor
    func testTextHoverAt66KeepsOneCharacterAndEllipsis() {
        let tab = TabButton(title: "新規タブ", image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!, target: nil, action: nil)
        tab.frame = NSRect(x: 0, y: 0, width: 66, height: 28)
        tab.font = .systemFont(ofSize: 12)
        tab.isDetachedLayout = true
        tab.detachedMode = .truncated
        tab.onClose = {}
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        tab.mouseEntered(with: event)
        let cell = tab.cell as! TabButtonCell
        let text = cell.displayedTitle(forBounds: tab.bounds)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertGreaterThanOrEqual(text.count, 2)
        XCTAssertEqual(tab.detachedMode, .truncated)
    }
    func test100PointBandKeepsPinnedPairAndSelectedNormalSlot() {
        for normalCount in [1, 3, 5] {
            for selected in [0, normalCount - 1] {
                // 100pt band minus 4pt divider and its additional 4pt gap.
                let result = DetachedTabLayout.distribute(available: 92 + DetachedToolbarLayout.width(for: 3), pinnedCount: 2, normalCount: normalCount, selectedNormal: selected, fullWidth: 120)
                XCTAssertEqual(result.plan.width, 28)
                XCTAssertEqual(result.visibleNormalIndices, [selected])
                XCTAssertEqual(result.hiddenNormalCount, normalCount - 1)
                XCTAssertEqual(3 * result.plan.width + 12 + 4, 100)
            }
        }
    }
    func testPinnedTabsAndOverflowCountAreIndependentOfSelectionAcrossNarrowWidths() {
        for width in stride(from: 381, through: 480, by: 1) {
            for total in [2, 3, 5, 7] {
                for pinned in [0, 2] {
                    let normals = total - pinned
                    let first = DetachedTabLayout.distribute(available: CGFloat(width) - 132, pinnedCount: pinned, normalCount: normals, selectedNormal: normals > 0 ? 0 : nil, fullWidth: 120)
                    let last = DetachedTabLayout.distribute(available: CGFloat(width) - 132, pinnedCount: pinned, normalCount: normals, selectedNormal: normals > 0 ? normals - 1 : nil, fullWidth: 120)
                    XCTAssertEqual(first.hiddenNormalCount, last.hiddenNormalCount)
                    XCTAssertEqual(pinned + first.visibleNormalIndices.count + first.hiddenNormalCount, total)
                    XCTAssertGreaterThanOrEqual(first.plan.width, 28)
                    XCTAssertGreaterThanOrEqual(first.plan.capacity, pinned)
                    if normals > 0 {
                        XCTAssertTrue(first.visibleNormalIndices.contains(0))
                        XCTAssertTrue(last.visibleNormalIndices.contains(normals - 1))
                    }
                    if total == 2 { XCTAssertEqual(first.hiddenNormalCount, 0) }
                    if first.hiddenNormalCount > 0 {
                        XCTAssertLessThan(CGFloat(width) - 132 - first.plan.toolbar.width, CGFloat(total * 28 + (total - 1) * 4))
                        XCTAssertEqual(first.plan.width, 28)
                        XCTAssertEqual(first.plan.capacity, Int(floor((CGFloat(width) - 132 - first.plan.toolbar.width + 4) / 32)))
                    }
                }
            }
        }
    }
    @MainActor
    func testTextMinimumOmitsCloseReservationAndHoverReservesItOnlyWhileVisible() {
        let tab = TabButton(title: "カレンダー", image: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!, target: nil, action: nil)
        tab.frame = NSRect(x: 0, y: 0, width: 100, height: 28)
        tab.isDetachedLayout = true
        let minimum = tab.detachedMinimumTextWidth
        let full = tab.detachedMeasuredWidth
        let rect = tab.detachedTitleRect(in: tab.bounds)
        tab.onClose = {}
        XCTAssertEqual(tab.detachedMinimumTextWidth, minimum)
        XCTAssertEqual(tab.detachedMeasuredWidth, full)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        tab.mouseEntered(with: event)
        XCTAssertEqual(tab.detachedTitleRect(in: tab.bounds).width, rect.width - 10)
        tab.mouseExited(with: event)
        XCTAssertEqual(tab.detachedTitleRect(in: tab.bounds), rect)
    }

    func testCompactUncappedSharesFillTheTabBandContinuously() {
        for count in [3, 5] {
            var previous: CGFloat = 0
            // Sweep measured tab-band widths, with all optional actions folded.
            for band in (count * 28 + (count - 1) * 4)...(count * 68 + (count - 1) * 4) {
                let plan = DetachedTabLayout.plan(available: CGFloat(band) + DetachedToolbarLayout.width(for: 3), count: count, fullWidth: 120, textMinimum: 68)
                XCTAssertEqual(plan.overflow, 0)
                XCTAssertGreaterThanOrEqual(plan.width, previous)
                if previous > 0 { XCTAssertLessThanOrEqual(plan.width - previous, 1) }
                let unused = CGFloat(band) - CGFloat(count) * plan.width - CGFloat(count - 1) * 4
                XCTAssertLessThan(unused, plan.width)
                if plan.mode == .iconOnly { XCTAssertLessThan(plan.width, 68) }
                previous = plan.width
            }
        }
        let fiveAt640 = DetachedTabLayout.plan(available: 359 + DetachedToolbarLayout.width(for: 3), count: 5, fullWidth: 120, textMinimum: 68)
        XCTAssertNotEqual(fiveAt640.mode, .iconOnly)
    }
    func testFiveIconTabsIn60PointViewportHaveThreeHiddenTabs() {
        let frames = (0..<5).map { NSRect(x: $0 * 32, y: 0, width: 28, height: 28) }
        for origin in [0, 96] {
            let visible = DetachedTabLayout.fullyVisibleCount(frames: frames, viewport: NSRect(x: origin, y: 0, width: 60, height: 28))
            XCTAssertEqual(visible, 2)
            XCTAssertEqual(frames.count - visible, 3)
        }
    }
    func testUnifiedTabModesAndToolbarPriorityAreMonotonicAcrossWidthSweep() {
        for count in [1, 2, 3, 5] {
            let titles = Array(["View of Mount Fuji from a very long English title", "新規タブ", "メール", "カレンダー", "予定一覧"].prefix(count))
            let measure: (String) -> CGFloat = { CGFloat($0.count) * 12 }
            let fullWidth = titles.map { 32 + measure($0) }.max()!
            let textMinimum = titles.map { 32 + measure(String($0.prefix(2)) + "…") }.max()!
            var previousMode = DetachedTabLayout.Mode.iconOnly
            var previousWidth: CGFloat = 0
            var previousVisible = 0
            var previousCharacters = Array(repeating: 0, count: count)
            for windowWidth in stride(from: 388, through: 1200, by: 4) {
                let available = CGFloat(windowWidth) - 80 - 28 - 4 - 8 - 12
                let initial = DetachedTabLayout.plan(available: available, count: count, fullWidth: fullWidth, textMinimum: textMinimum)
                let plan = initial.overflow == 0 ? initial : DetachedTabLayout.plan(available: available - 48, count: count, fullWidth: fullWidth, textMinimum: textMinimum)
                XCTAssertGreaterThanOrEqual(plan.mode.rawValue, previousMode.rawValue)
                XCTAssertGreaterThanOrEqual(plan.width, previousWidth)
                XCTAssertGreaterThanOrEqual(plan.width, 28)
                XCTAssertEqual(plan.width, floor(plan.width))
                XCTAssertLessThanOrEqual(plan.width, 150)
                XCTAssertGreaterThanOrEqual(plan.toolbar.visible.count, previousVisible)
                previousVisible = plan.toolbar.visible.count
                if windowWidth == 1000 && (count == 2 || count == 3) { XCTAssertEqual(plan.toolbar.visible.count, 7) }
                if !plan.toolbar.overflow.isEmpty && plan.mode != .iconOnly { XCTAssertEqual(plan.width, textMinimum) }
                if plan.mode != .iconOnly {
                    XCTAssertGreaterThanOrEqual(plan.width, textMinimum)
                    XCTAssertEqual(plan.overflow, 0)
                    XCTAssertEqual(plan.capacity, count)
                }
                for (index, title) in titles.enumerated() {
                    let display = DetachedTabLayout.displayedTitle(title, mode: plan.mode, available: plan.width - 32, measure: measure)
                    let characters = display.filter { $0 != "…" }.count
                    XCTAssertGreaterThanOrEqual(characters, previousCharacters[index])
                    if plan.mode == .truncated {
                        XCTAssertTrue(display == title || display.hasSuffix("…"))
                        XCTAssertGreaterThanOrEqual(characters, 2)
                    }
                    if plan.mode == .full { XCTAssertEqual(display, title) }
                    if plan.mode == .iconOnly { XCTAssertEqual(display, "") }
                    previousCharacters[index] = characters
                }
                if plan.overflow > 0 {
                    XCTAssertEqual(plan.mode, .iconOnly)
                    XCTAssertEqual(plan.width, 28)
                }
                XCTAssertEqual(plan.capacity + plan.overflow, count)
                for selected in 0..<count { XCTAssertTrue(plan.visibleRange(selected: selected, count: count).contains(selected)) }
                XCTAssertEqual(plan.toolbar.overflow, Array(DetachedToolbarLayout.overflowOrder.prefix(plan.toolbar.overflow.count)))
                previousMode = plan.mode
                previousWidth = plan.width
            }
        }
    }

    func testFractionalEqualSharesNeverCreateTextOverflow() {
        let toolbarWidth = DetachedToolbarLayout.resolve(availableWidth: .greatestFiniteMagnitude).width
        for count in [3, 5] {
            for budget in stride(from: 501, through: 599, by: 1) {
                let plan = DetachedTabLayout.plan(available: toolbarWidth + CGFloat(budget), count: count, fullWidth: 150, textMinimum: 88)
                XCTAssertNotEqual(plan.mode, .iconOnly)
                XCTAssertEqual(plan.capacity, count)
                XCTAssertEqual(plan.overflow, 0)
                XCTAssertEqual(plan.toolbar.visible.count, 7)
            }
        }
    }

    func testFiveIdenticalTitlesUseIdenticalIntegerDrawingWidths() {
        for windowWidth in [800, 1000] {
            let plan = DetachedTabLayout.plan(available: CGFloat(windowWidth) - 132, count: 5, fullWidth: 112, textMinimum: 88)
            XCTAssertEqual(plan.width, floor(plan.width))
            let displayed = (0..<5).map { _ in
                DetachedTabLayout.displayedTitle("新規タブ", mode: plan.mode, available: plan.width - 32) { CGFloat($0.count) * 12 }
            }
            XCTAssertEqual(Set(displayed).count, 1)
            XCTAssertEqual(plan.capacity + plan.overflow, 5)
        }
    }

    func testNewTabFullTitleFitsAt1000WithoutPermanentCloseReservation() {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let full = 12 + 20 + ("新規タブ" as NSString).size(withAttributes: [.font: font]).width
        let minimum = 12 + 20 + ("新規…" as NSString).size(withAttributes: [.font: font]).width
        let plan = DetachedTabLayout.plan(available: 1000 - 80 - 28 - 4 - 8 - 12, count: 3, fullWidth: full, textMinimum: minimum)
        XCTAssertEqual(plan.mode, .full)
        XCTAssertEqual(plan.width, ceil(full))
        XCTAssertEqual(plan.overflow, 0)
    }

    @MainActor
    func testTitlebarDragHitTestExcludesTabCloseAndToolbarControls() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
        let tab = TabButton(title: "新規タブ", target: nil, action: nil)
        tab.frame = NSRect(x: 80, y: 0, width: 120, height: 28)
        tab.isDetachedLayout = true
        tab.onClose = {}
        parent.addSubview(tab)
        tab.layoutSubtreeIfNeeded()
        let menu = NSButton(title: "…", target: nil, action: nil)
        menu.frame = NSRect(x: 450, y: 0, width: 28, height: 28)
        parent.addSubview(menu)
        let drag = BrowserTitlebarDragView(frame: parent.bounds)
        parent.addSubview(drag)
        for point in [NSPoint(x: 90, y: 14), NSPoint(x: 190, y: 14), NSPoint(x: 460, y: 14)] {
            XCTAssertNil(drag.hitTest(point))
            XCTAssertTrue(parent.hitTest(point) is NSControl)
        }
        XCTAssertTrue(drag.hitTest(NSPoint(x: 300, y: 14)) === drag)
        XCTAssertFalse(tab.mouseDownCanMoveWindow)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        tab.mouseEntered(with: event)
        let close = tab.subviews.compactMap { $0 as? NSButton }.first!
        XCTAssertTrue(close.superview === tab)
        XCTAssertTrue(tab.bounds.contains(close.frame))
        XCTAssertTrue(close.isEnabled)
        XCTAssertEqual(close.alphaValue, 1)
        tab.detachedMode = .iconOnly
        tab.configureDetachedTitle(width: 40)
        tab.state = .off
        tab.mouseEntered(with: event)
        XCTAssertFalse(close.isEnabled)
        XCTAssertTrue(tab.detachedDrawsIcon)
        tab.state = .on
        tab.mouseEntered(with: event)
        XCTAssertTrue(close.isEnabled)
        XCTAssertEqual(close.alphaValue, 1)
        XCTAssertEqual(tab.detachedIconSide, 16)
        XCTAssertFalse(tab.detachedDrawsIcon)
        XCTAssertEqual(close.frame.midX, tab.bounds.midX)
        XCTAssertEqual(close.frame.midY, tab.bounds.midY)
        tab.mouseExited(with: event)
        XCTAssertTrue(tab.detachedDrawsIcon)
    }
    func testNaturalWidthsAreNotExpandedAndShortTabsDonateUnusedSpace() {
        XCTAssertEqual(DetachedTabLayout.widths(available: 1000, items: [nil, nil], naturalWidths: [72.5, 92]), [72.5, 92])
        XCTAssertEqual(DetachedTabLayout.widths(available: 200, items: [nil, nil], naturalWidths: [80, 140]), [80, 116])
        XCTAssertEqual(DetachedTabLayout.widths(available: 200, items: [28, nil, nil], naturalWidths: [28, 80, 140]), [28, 80, 84])
    }
    func testResizeOrderDoesNotAffectAllocationAndExpansionIsMonotonic() {
        var previous: [CGFloat] = [0, 0]
        for available in [100.0, 120, 140, 180, 220] {
            let current = DetachedTabLayout.widths(available: available, items: [nil, nil], naturalWidths: [72.5, 92])
            XCTAssertGreaterThanOrEqual(current[0], previous[0])
            XCTAssertGreaterThanOrEqual(current[1], previous[1])
            XCTAssertLessThanOrEqual(current.reduce(0, +) + 4, available)
            previous = current
        }
        for available in [220.0, 100, 180, 120, 220] {
            let current = DetachedTabLayout.widths(available: available, items: [nil, nil], naturalWidths: [72.5, 92])
            XCTAssertLessThanOrEqual(current[0], 72.5)
            XCTAssertLessThanOrEqual(current[1], 92)
        }
    }
    func testTwoTitlesShareVisibleWidthIncludingSpacing() {
        for available in [100.0, 120, 180, 220, 300] {
            let widths = DetachedTabLayout.widths(available: available, items: [nil, nil])
            XCTAssertLessThanOrEqual(widths.reduce(0, +) + 4, available)
            XCTAssertEqual(widths[0], widths[1])
            XCTAssertGreaterThanOrEqual(widths[0], 40)
            XCTAssertLessThanOrEqual(widths[0], 150)
        }
    }
    func testFixedIconsAreReservedAndOnlyMinimumOverflowScrolls() {
        XCTAssertEqual(DetachedTabLayout.widths(available: 132, items: [28, nil, nil]), [28, 48, 48])
        XCTAssertEqual(DetachedTabLayout.widths(available: 70, items: [nil, nil]), [40, 40])
        XCTAssertEqual(DetachedTabLayout.widths(available: 1000, items: [nil, nil]), [150, 150])
    }
}
