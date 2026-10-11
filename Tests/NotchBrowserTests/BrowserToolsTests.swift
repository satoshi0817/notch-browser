import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import NotchBrowser

final class BrowserToolsTests: XCTestCase {
    @MainActor
    func testSeparateOverflowButtonKeepsNewTabVisibleAndInsideWindow() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        for total in [2, 3, 5, 7, 8] {
            var settings = SettingsData()
            settings.notionEnabled = false
            settings.pinnedTabs = [PinnedTab(name: "メール", url: "about:blank", icon: .symbol("envelope")), PinnedTab(name: "カレンダー", url: "about:blank", icon: .symbol("calendar"))]
            store.data = settings
            let browser = BrowserViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            window.setContentSize(NSSize(width: 1000, height: 400))
            browser.isDetached = true
            browser.updateDetachedMetrics(trafficInset: 70, rowHeight: 28)
            for _ in 0..<max(0, total - 2) { browser.newTab(nil) }
            for width in [1000, 560, 480, 440, 400, 390, 381] {
                var overflowLabels: [String] = []
                for index in [3, total] where index <= total {
                    let sender = NSMenuItem(); sender.tag = index
                    browser.selectTabByNumber(sender)
                    window.setContentSize(NSSize(width: width, height: 400))
                    browser.view.layoutSubtreeIfNeeded()
                    browser.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(window.contentView?.bounds.width, CGFloat(width))
                    let buttons = descendants(browser.view).compactMap { $0 as? NSButton }
                    let add = try XCTUnwrap(buttons.first { $0.action == #selector(BrowserViewController.newTab(_:)) })
                    XCTAssertFalse(add.isHidden)
                    XCTAssertEqual(add.title, "")
                    let addFrame = add.convert(add.bounds, to: browser.view)
                    XCTAssertLessThanOrEqual(addFrame.maxX, browser.view.bounds.maxX - 11)
                    let overflow = buttons.first { !$0.isHidden && $0.title.hasPrefix("+") && $0.title.count > 1 }
                    overflowLabels.append(overflow?.title ?? "")
                    if let overflow {
                        XCTAssertEqual(overflow.contentTintColor, NSColor.secondaryLabelColor)
                        let frame = overflow.convert(overflow.bounds, to: browser.view)
                        XCTAssertGreaterThanOrEqual(addFrame.minX, frame.maxX + 3)
                    }
                    let reloadAction = NSSelectorFromString("reloadOrStop")
                    let reload = try XCTUnwrap(buttons.first { $0.action == reloadAction })
                    XCTAssertEqual(reload.isHidden, overflow != nil && width < 404)
                    if reload.isHidden {
                        let menus = buttons.compactMap { $0.menu }
                        let item = try XCTUnwrap(menus.flatMap { $0.items }.first { $0.action == reloadAction })
                        XCTAssertTrue((item.target as? BrowserViewController) === browser)
                    }
                    let selected = try XCTUnwrap(buttons.compactMap { $0 as? TabButton }.first { $0.state == .on })
                    XCTAssertFalse(selected.isHidden)
                }
                if overflowLabels.count == 2 { XCTAssertEqual(overflowLabels[0], overflowLabels[1]) }
            }
        }
    }

    @MainActor
    func testNotchLayoutRevealsSelectedNormalTabAfterAddingTabs() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.notionEnabled = false
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 640, height: 400))
        browser.updateNotchMetrics(notchWidth: 200, stripHeight: 32)
        for _ in 0..<5 { browser.newTab(nil) }
        browser.view.layoutSubtreeIfNeeded()
        let selected = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.state == .on })
        var parent = selected.superview
        while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
        let scroll = try XCTUnwrap(parent as? NSScrollView)
        let frame = selected.convert(selected.bounds, to: scroll.contentView)
        // Engineer's main c1588977 probe of this same procedure:
        // frame=(341,6,80,19), clip=(257,0,162,32), doc=(0,0,421,32).
        // Main already clips the trailing 2pt (421 vs 419). Preserve that behavior
        // while guarding against the selected tab being substantially offscreen.
        XCTAssertGreaterThanOrEqual(frame.minX, scroll.contentView.bounds.minX - 2)
        XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.maxX + 2)
        let visibleWidth = max(0, min(frame.maxX, scroll.contentView.bounds.maxX)
            - max(frame.minX, scroll.contentView.bounds.minX))
        XCTAssertGreaterThanOrEqual(visibleWidth, frame.width - 2)
    }

    @MainActor
    func testReturningFromDetachedOverflowRevealsAllNotchTabsAndSelectedTab() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.notionEnabled = false
        settings.pinnedTabs = [PinnedTab(name: "メール", url: "about:blank", icon: .symbol("envelope")), PinnedTab(name: "カレンダー", url: "about:blank", icon: .symbol("calendar"))]
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 640, height: 400))
        browser.updateNotchMetrics(notchWidth: 200, stripHeight: 32)
        for _ in 0..<5 { browser.newTab(nil) }
        browser.isDetached = true
        window.setContentSize(NSSize(width: 381, height: 400))
        browser.updateDetachedMetrics(trafficInset: 70, rowHeight: 28)
        browser.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(browser.view).compactMap { $0 as? TabButton }.count < 7 || descendants(browser.view).compactMap { $0 as? TabButton }.contains { $0.isHidden })
        let longTab = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.state == .on })
        longTab.title = "r7t7 - Google 検索"
        browser.isDetached = false
        window.setContentSize(NSSize(width: 640, height: 400))
        browser.updateNotchMetrics(notchWidth: 200, stripHeight: 32)
        browser.view.layoutSubtreeIfNeeded()
        for _ in 0..<2 { browser.revealSelectedTabAfterNotchLayout(); browser.view.layoutSubtreeIfNeeded() }
        let restored = descendants(browser.view).compactMap { $0 as? TabButton }
        XCTAssertEqual(restored.count, 7)
        XCTAssertTrue(restored.allSatisfy { !$0.isHidden })
        let selected = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.state == .on })
        var parent = selected.superview
        while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
        let scroll = try XCTUnwrap(parent as? NSScrollView)
        let frame = selected.convert(selected.bounds, to: scroll.contentView)
        // Engineer's main c1588977 probe of this same procedure:
        // frame=(341,6,80,19), clip=(257,0,162,32), doc=(0,0,421,32).
        // Main already clips the trailing 2pt (421 vs 419). Preserve that behavior
        // while guarding against the selected tab being substantially offscreen.
        XCTAssertGreaterThanOrEqual(frame.minX, scroll.contentView.bounds.minX - 2)
        XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.maxX + 2)
        let visibleWidth = max(0, min(frame.maxX, scroll.contentView.bounds.maxX)
            - max(frame.minX, scroll.contentView.bounds.minX))
        XCTAssertGreaterThanOrEqual(visibleWidth, frame.width - 2)
    }

    @MainActor
    func testDetachedToolbarRightEdgeStaysInsideWindowWithEightTabs() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.notionEnabled = false
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1000, height: 400))
        browser.isDetached = true
        browser.updateDetachedMetrics(trafficInset: 80, rowHeight: 28)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        browser.newTab(nil)
        browser.view.layoutSubtreeIfNeeded()
        for _ in 0..<7 { browser.newTab(nil) }
        for width in [1000.0, 480, 440, 400, 390, 381] {
            window.setContentSize(NSSize(width: width, height: 400))
            browser.view.layoutSubtreeIfNeeded()
            let tools = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "ページの操作" })
            let controls = try XCTUnwrap(tools.superview as? NSStackView)
            let rect = controls.convert(controls.bounds, to: browser.view)
            XCTAssertLessThanOrEqual(rect.maxX, browser.view.bounds.maxX - 11)
        }
    }

    @MainActor
    func testDetachedNewTabTitleIsFullAt1000() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.notionEnabled = false
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1000, height: 400))
        browser.isDetached = true
        browser.updateDetachedMetrics(trafficInset: 80, rowHeight: 28)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        browser.newTab(nil)
        browser.view.layoutSubtreeIfNeeded()
        let tab = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.last)
        XCTAssertEqual(tab.detachedMode, .full)
        XCTAssertEqual(tab.title, "新規タブ")
        let cell = try XCTUnwrap(tab.cell as? TabButtonCell)
        XCTAssertEqual(cell.displayedTitle(forBounds: tab.bounds), "新規タブ")
        let context = try XCTUnwrap(tab.menu)
        XCTAssertTrue(context.items.contains { $0.title == "タブを閉じる" })
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        XCTAssertTrue(tab.menu(for: rightClick) === context)
        var parent = tab.superview
        while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
        let scroll = try XCTUnwrap(parent as? NSScrollView)
        XCTAssertFalse(scroll.automaticallyAdjustsContentInsets)
        XCTAssertGreaterThanOrEqual(scroll.contentView.frame.height, tab.frame.height)
        let point = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: window.contentView?.superview)
        XCTAssertTrue(window.contentView?.hitTest(point) is TabButton)
    }

    @MainActor
    func testDetachedTabRebuildsAndTitleChangesApplyWidthsImmediately() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.notionEnabled = false
        settings.pinnedTabs = [PinnedTab(name: "メール", url: "about:blank", icon: .symbol("envelope")), PinnedTab(name: "カレンダー", url: "about:blank", icon: .symbol("calendar"))]
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 560, height: 400))
        XCTAssertEqual(window.contentView?.bounds.width, 560)
        browser.isDetached = true
        browser.updateDetachedMetrics(trafficInset: 80, rowHeight: 28)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        browser.view.layoutSubtreeIfNeeded()

        func verify(_ operation: String) throws {
            for tab in descendants(browser.view).compactMap({ $0 as? TabButton }) {
                XCTAssertTrue(tab.isDetachedLayout)
                XCTAssertNotNil(tab.detachedOriginalTitle)
                XCTAssertEqual(tab.detachedWidthConstraint?.isActive, true)
                var parent = tab.superview
                while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
                let scroll = try XCTUnwrap(parent as? NSScrollView)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1, operation)
                XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1, operation)
                let frame = tab.convert(tab.bounds, to: scroll.contentView)
                XCTAssertGreaterThanOrEqual(frame.minX, scroll.contentView.bounds.minX - 1, operation)
                XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.maxX + 1, operation)
                let cell = try XCTUnwrap(tab.cell as? TabButtonCell)
                let displayed = cell.displayedTitle(forBounds: tab.bounds)
                XCTAssertTrue(tab.title.isEmpty || displayed == tab.title || displayed.hasSuffix("…"))
            }
        }
        browser.newTab(nil) // rebuild at 560; do not call layout after the operation
        try verify("newTab at 560")
        window.setContentSize(NSSize(width: 390, height: 400))
        browser.view.layoutSubtreeIfNeeded()
        browser.closeCurrentTab(nil) // two tabs again, rebuild at 390
        try verify("closeCurrentTab at 390")
        let before = descendants(browser.view).compactMap { $0 as? TabButton }
        let previouslySelected = try XCTUnwrap(before.first { $0.state == .on })
        let select = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let otherTab = try XCTUnwrap(before.first { $0.tag != previouslySelected.tag })
        select.tag = otherTab.tag + 1 // menu numbers are one-based; button tags are zero-based
        browser.selectTabByNumber(select)
        try verify("selectTabByNumber")
        let after = descendants(browser.view).compactMap { $0 as? TabButton }
        let newlySelected = try XCTUnwrap(after.first { $0.state == .on })
        XCTAssertNotEqual(newlySelected.tag, previouslySelected.tag)
        XCTAssertEqual(newlySelected.tag, otherTab.tag)
        XCTAssertFalse(after.contains { tab in before.contains { $0 === tab } })
        browser.selectTabByNumber(select)
        let sameSelection = descendants(browser.view).compactMap { $0 as? TabButton }
        XCTAssertEqual(after.map(ObjectIdentifier.init), sameSelection.map(ObjectIdentifier.init))
        XCTAssertEqual(sameSelection.first { $0.state == .on }?.tag, newlySelected.tag)
        try verify("unchanged selectTabByNumber")
        let axOther = try XCTUnwrap(sameSelection.first { $0.tag != newlySelected.tag })
        XCTAssertTrue(axOther.accessibilityPerformPress())
        XCTAssertEqual(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.state == .on }?.tag, axOther.tag)
        for _ in 0..<2 {
            let current = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.state == .on })
            current.performClick(nil)
            let afterClick = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.tag == current.tag })
            XCTAssertEqual(afterClick.state, .on)
            XCTAssertEqual(afterClick.accessibilityValue() as? String, "選択中")
            XCTAssertTrue(afterClick.accessibilityPerformPress())
            let afterPress = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.tag == current.tag })
            XCTAssertEqual(afterPress.state, .on)
            XCTAssertEqual(afterPress.accessibilityValue() as? String, "選択中")
        }
        let changed = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first)
        changed.title = "変更された長いタブタイトル"
        XCTAssertEqual(changed.detachedOriginalTitle, "変更された長いタブタイトル")
        try verify("title change")
        store.data.pinnedTabs[1].name = "予定カレンダー"
        browser.settingsChanged()
        try verify("settingsChanged")
        XCTAssertTrue(descendants(browser.view).compactMap { $0 as? TabButton }.contains { $0.detachedOriginalTitle == "予定カレンダー" })
        let unchanged = descendants(browser.view).compactMap { $0 as? TabButton }
        browser.settingsChanged()
        let repeated = descendants(browser.view).compactMap { $0 as? TabButton }
        XCTAssertEqual(unchanged.map(ObjectIdentifier.init), repeated.map(ObjectIdentifier.init))
        try verify("unchanged settingsChanged")

        // Genuine minimum-width overflow hides whole normal tabs. The newest tab
        // remains visible while pinned tabs stay at the left edge.
        for _ in 0..<4 { browser.newTab(nil) }
        let overflowTabs = descendants(browser.view).compactMap { $0 as? TabButton }
        let selected = try XCTUnwrap(overflowTabs.last)
        XCTAssertTrue(selected.detachedContentFullyVisible)
        var parent = selected.superview
        while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
        let scroll = try XCTUnwrap(parent as? NSScrollView)
        XCTAssertLessThanOrEqual(try XCTUnwrap(scroll.documentView).frame.width, scroll.contentSize.width + 1)
        XCTAssertTrue(overflowTabs.contains { $0.isHidden })
        for tab in overflowTabs where !tab.detachedContentFullyVisible {
            let cell = try XCTUnwrap(tab.cell as? TabButtonCell)
            XCTAssertEqual(cell.displayedTitle(forBounds: tab.bounds), "")
        }
        for _ in 0..<4 { browser.closeCurrentTab(nil) }
        try verify("close overflow tabs back to two")
    }

    @MainActor
    func testTwoDetachedTabTitlesFitAndTruncateInsteadOfBeingClipped() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.notionEnabled = false
        settings.pinnedTabs = [PinnedTab(name: "メール", url: "about:blank", icon: .symbol("envelope")), PinnedTab(name: "カレンダー", url: "about:blank", icon: .symbol("calendar"))]
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 560, height: 400))
        XCTAssertEqual(window.contentView?.bounds.width, 560)
        browser.isDetached = true
        browser.updateDetachedMetrics(trafficInset: 80, rowHeight: 28)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var widthsByWindowWidth: [Double: [CGFloat]] = [:]
        for width in [390.0, 400, 440, 480, 520, 560, 640, 1000, 560, 390, 1000, 440, 520, 400] {
            window.setContentSize(NSSize(width: width, height: 400))
            browser.view.layoutSubtreeIfNeeded()
            let tabs = descendants(browser.view).compactMap { $0 as? TabButton }
            XCTAssertEqual(tabs.count, 2)
            for tab in tabs {
                XCTAssertNil(tab.onClose)
                XCTAssertTrue(tab.subviews.compactMap { $0 as? NSButton }.isEmpty)
                XCTAssertFalse(try XCTUnwrap(tab.menu).items.contains { $0.title == "タブを閉じる" })
            }
            XCTAssertEqual(tabs[0].frame.width, tabs[1].frame.width, accuracy: 1)
            XCTAssertEqual(tabs[0].detachedMode, tabs[1].detachedMode)
            let currentWidths = tabs.map { $0.frame.width }
            if let earlier = widthsByWindowWidth[width] { XCTAssertEqual(currentWidths, earlier) }
            widthsByWindowWidth[width] = currentWidths
            for tab in tabs {
                XCTAssertLessThanOrEqual(tab.frame.width, tab.detachedNaturalWidth + 1)
                if tab.image?.isTemplate == true { XCTAssertEqual(tab.detachedIconTint, tab.contentTintColor ?? .labelColor) }
                var parent = tab.superview
                while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
                let scroll = try XCTUnwrap(parent as? NSScrollView)
                let stack = try XCTUnwrap(scroll.documentView)
                XCTAssertLessThanOrEqual(stack.frame.width, scroll.contentSize.width + 1)
                let frame = tab.convert(tab.bounds, to: scroll.contentView)
                XCTAssertGreaterThanOrEqual(frame.minX, scroll.contentView.bounds.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.maxX + 1)
                let cell = try XCTUnwrap(tab.cell as? TabButtonCell)
                XCTAssertEqual(cell.lineBreakMode, .byTruncatingTail)
                XCTAssertTrue(cell.truncatesLastVisibleLine)
                XCTAssertFalse(cell.wraps)
                let titleRect = cell.titleRect(forBounds: tab.bounds)
                XCTAssertGreaterThanOrEqual(titleRect.minX, tab.bounds.minX)
                XCTAssertLessThanOrEqual(titleRect.maxX, tab.bounds.maxX)
                let displayed = cell.displayedTitle(forBounds: tab.bounds)
                XCTAssertTrue(tab.title.isEmpty || displayed == tab.title || displayed.hasSuffix("…"))
                if tab.title.isEmpty { XCTAssertEqual(tab.imagePosition, .imageOnly) }
            }
        }
    }

    func testClosedTabsAreBoundedLIFOAndRejectTransientURLs() {
        var history = ClosedTabHistory()
        for n in 0..<25 {
            history.push(ClosedTab(url: URL(string: "https://example.com/\(n)")!, profileID: Profile.defaultID, zoom: 1.2))
        }
        history.push(ClosedTab(url: URL(string: "blob:https://example.com/temporary")!, profileID: Profile.defaultID, zoom: 1))
        XCTAssertEqual(history.entries.count, 20)
        XCTAssertEqual(history.entries.first?.url.lastPathComponent, "5")
        XCTAssertEqual(history.pop()?.url.lastPathComponent, "24")
        XCTAssertEqual(history.pop()?.zoom, 1.2)
    }

    func testSearchMatchesAllWordsAcrossTitleURLAndProfile() {
        XCTAssertTrue(BrowserTools.matches(query: "DOCS work", title: "Documents", url: "https://docs.example.com", profile: "Work"))
        XCTAssertFalse(BrowserTools.matches(query: "docs personal", title: "Documents", url: "https://docs.example.com", profile: "Work"))
        XCTAssertTrue(BrowserTools.matches(query: "  ", title: "", url: "", profile: ""))
    }

    func testGlassPreferenceSurvivesOldSettingsAndClampsInvalidValues() throws {
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8)).glassTint, 0.5)
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: Data("{\"glassTint\":2}".utf8)).glassTint, 1)
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: Data("{\"glassTint\":-1}".utf8)).glassTint, 0)
    }

    func testExternalBrowserPreferenceKeepsLegacySettingsAndRoundTrips() throws {
        let old = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertNil(old.externalBrowserBundleID)
        var selected = old
        selected.externalBrowserBundleID = "com.apple.Safari"
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.externalBrowserBundleID, "com.apple.Safari")
    }

    @MainActor func testLinkAndTabExternalBrowserMenusAreInstalled() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 960, height: 660), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        browser.newTab(nil)
        let webView = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? WKWebView }.first)
        XCTAssertTrue(webView.configuration.userContentController.userScripts.contains { $0.source.contains("notchBrowserLinkMenu") })
        let button = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? TabButton }.first { $0.menu != nil })
        let menu = try XCTUnwrap(button.menu)
        XCTAssertTrue(menu.items.contains { $0.title == "ブラウザで開く" })
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "ブラウザで開く" }).isEnabled)
    }

    @MainActor func testSettingsRefreshKeepsNotionPanelVisible() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 960, height: 660),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        browser.showNotion()
        let glass = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? GlassSurface }.first)
        XCTAssertTrue(glass.opaqueBackdrop)
        let tint = try XCTUnwrap(glass.content.subviews.first?.layer?.backgroundColor)
        XCTAssertEqual(tint.alpha, 1, accuracy: 0.001)
        let notion = try XCTUnwrap(descendants(browser.view).first { $0 is NSHostingView<NotionAgentsPanel> })
        XCTAssertFalse(notion.isHidden)
        store.data.notionSavedAgents = [SavedNotionAgent(id: "agent", name: "Updated")]
        browser.settingsChanged()
        XCTAssertFalse(notion.isHidden, "Metadata-driven settings updates must not switch back to a pinned page")
        store.data.notionAppearance = .light
        browser.settingsChanged()
        XCTAssertEqual(notion.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        store.data.notionAppearance = .dark
        browser.settingsChanged()
        XCTAssertEqual(notion.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        browser.hideNotion()
        XCTAssertFalse(glass.opaqueBackdrop)
    }

    @MainActor
    func testLegacyIconsUseOnlyValidSFSymbols() {
        for icon in [TabIcon.emoji("legacy"), .image("custom.png"), .favicon, .symbol("missing-symbol")] {
            XCTAssertEqual(TabIconRenderer.symbolName(for: icon, hosts: ["mail.google.com"]), "envelope")
            XCTAssertTrue(TabIconRenderer.image(for: icon, hosts: ["mail.google.com"]).isTemplate)
        }
        for name in TabIconRenderer.presetSymbols {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    @MainActor
    func testZoomCloseRestoreAndFindOnRealWebView() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.countdownEnabled = false
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 960, height: 660), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        browser.newTab(nil)
        let webView = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? WKWebView }.first)
        webView.loadHTMLString("<html><body><h1>Local browser test</h1><p>Needle appears here.</p></body></html>", baseURL: URL(string: "https://example.com/test")!)
        let deadline = Date().addingTimeInterval(5)
        while (webView.isLoading || webView.url == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(webView.url)
        browser.zoomIn(nil)
        XCTAssertEqual(webView.pageZoom, 1.1, accuracy: 0.001)
        for _ in 0..<30 { browser.zoomOut(nil) }
        XCTAssertEqual(webView.pageZoom, 0.5, accuracy: 0.001)
        browser.resetZoom(nil)
        XCTAssertEqual(webView.pageZoom, 1)
        browser.showFind(nil)
        let field = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? NSSearchField }.first { $0.placeholderString == "ページ内を検索" })
        field.stringValue = "Needle"
        browser.findNext(nil)
        let found = expectation(description: "WebKit find result")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { found.fulfill() }
        wait(for: [found], timeout: 2)
        XCTAssertTrue(descendants(browser.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "一致あり" })
        XCTAssertTrue(browser.dismissOverlay())
        XCTAssertFalse(browser.dismissOverlay())
        let tools = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? NSPopUpButton }.first)
        let refresh = try XCTUnwrap(tools.menu?.items.first { $0.title == "自動更新" }?.submenu?.items.first { $0.tag == 30 })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(refresh.action), to: refresh.target, from: refresh))
        XCTAssertTrue(descendants(browser.view).compactMap { $0 as? NSButton }.contains { $0.toolTip?.contains("自動更新中") == true })
        let off = try XCTUnwrap(tools.menu?.items.first { $0.title == "自動更新" }?.submenu?.items.first { $0.tag == 0 })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(off.action), to: off.target, from: off))
        XCTAssertFalse(descendants(browser.view).compactMap { $0 as? NSButton }.contains { $0.toolTip?.contains("自動更新中") == true })
        let noteItem = try XCTUnwrap(tools.menu?.items.first { $0.title.hasPrefix("クイックメモ") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(noteItem.action), to: noteItem.target, from: noteItem))
        XCTAssertTrue(browser.dismissOverlay(), "The visible tools menu must open the note editor")
        let originalMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = originalMenu }
        let menu = NSMenu()
        let command = NSMenuItem(title: "メモ", action: #selector(BrowserViewController.toggleNotes(_:)), keyEquivalent: "M")
        command.keyEquivalentModifierMask = [.command, .shift]
        command.target = browser
        menu.addItem(command)
        NSApp.mainMenu = menu
        browser.toggleNotes(nil)
        XCTAssertTrue(panel.firstResponder is NSTextView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "M", charactersIgnoringModifiers: "M", isARepeat: false, keyCode: 46))
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertFalse(browser.dismissOverlay(), "The shortcut must close notes even while the editor owns focus")
        let searchCommand = NSMenuItem(title: "タブ検索", action: #selector(BrowserViewController.showTabSwitcher(_:)), keyEquivalent: "A")
        searchCommand.keyEquivalentModifierMask = [.command, .shift]
        searchCommand.target = browser
        menu.addItem(searchCommand)
        let searchEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "A", charactersIgnoringModifiers: "A", isARepeat: false, keyCode: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: searchEvent))
        XCTAssertTrue(browser.dismissOverlay(), "The tab search shortcut must open the switcher")
        browser.closeCurrentTab(nil)
        XCTAssertTrue(descendants(browser.view).compactMap { $0 as? WKWebView }.isEmpty)
        browser.reopenClosedTab(nil)
        let restored = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? WKWebView }.first)
        XCTAssertFalse(restored === webView)
        restored.stopLoading()
        browser.showTabSwitcher(nil)
        XCTAssertTrue(browser.dismissOverlay())
    }

    @MainActor
    func testToolbarPlacementMovesActionsIntoMenuAndBack() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.toolbarActions = [.settings, .quit]
        store.data = settings
        let browser = BrowserViewController()
        browser.view.frame = NSRect(x: 0, y: 0, width: 960, height: 500)
        browser.updateNotchMetrics(notchWidth: 200, stripHeight: 32)
        browser.view.layoutSubtreeIfNeeded()
        let controls = descendants(browser.view).compactMap { $0 as? NSButton }
        let settingsButton = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "設定" })
        let menu = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertFalse(settingsButton.isHidden)
        XCTAssertFalse(menu.itemTitles.contains("設定"))
        XCTAssertTrue(menu.itemTitles.contains("戻る"))
        store.data.toolbarActions = []
        browser.settingsChanged()
        XCTAssertTrue(settingsButton.isHidden)
        XCTAssertTrue(menu.itemTitles.contains("設定"))
        XCTAssertTrue(menu.itemTitles.contains("終了"))
        store.data.toolbarActions = [.settings, .quit]
        browser.settingsChanged()
        XCTAssertFalse(settingsButton.isHidden)
        XCTAssertFalse(menu.itemTitles.contains("設定"))
    }

    @MainActor
    func testToolbarFollowsSavedOrderAndSpacerSeparatesButtons() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.toolbarActions = [.quit, .spacer, .address, .settings]
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 960, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        browser.updateNotchMetrics(notchWidth: 200, stripHeight: 32)
        browser.view.layoutSubtreeIfNeeded()
        let buttons = descendants(browser.view).compactMap { $0 as? NSButton }
        let quit = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "終了" })
        let address = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "URLを表示・検索 (⌘L)" })
        let preferences = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "設定" })
        let quitFrame = quit.convert(quit.bounds, to: browser.view)
        let addressFrame = address.convert(address.bounds, to: browser.view)
        let settingsFrame = preferences.convert(preferences.bounds, to: browser.view)
        XCTAssertLessThan(quitFrame.maxX + 40, addressFrame.minX)
        XCTAssertLessThan(addressFrame.maxX, settingsFrame.minX)
        XCTAssertFalse(quit.isHidden)
        XCTAssertFalse(address.isHidden)
    }

    @MainActor
    func testNewTabKeepsSearchInsideTheStartPage() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 960, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        browser.newTab(nil)
        XCTAssertFalse(browser.dismissOverlay(), "Creating a tab should not open the toolbar search popover")
    }

    @MainActor
    func testCompactLayoutKeepsTheOriginalSingleStripAndCameraGap() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 640, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        browser.updateNotchMetrics(notchWidth: 200, stripHeight: 32)
        browser.newTab(nil)
        browser.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(browser.view).contains { ($0 as? NSTextField)?.placeholderString == "検索またはURLを入力" }, "URL field should not occupy the toolbar")
        _ = browser.dismissOverlay()
        for width in [600.0, 640.0, 960.0] {
            panel.setContentSize(NSSize(width: width, height: 500))
            browser.view.layoutSubtreeIfNeeded()
            browser.view.layoutSubtreeIfNeeded()
            let buttons = descendants(browser.view).compactMap { $0 as? NSButton }.filter {
                !$0.isHidden && ["戻る", "進む", "設定したページに戻る", "再読み込み", "URLを表示・検索 (⌘L)", "開いたままにする", "設定", "終了", "ページの操作"].contains($0.accessibilityLabel() ?? "")
            }
            let frames = buttons.map { $0.convert($0.bounds, to: browser.view) }.sorted { $0.minX < $1.minX }
            XCTAssertGreaterThanOrEqual(frames.count, 5)
            for frame in frames { XCTAssertGreaterThanOrEqual(frame.minX, width / 2 + 112 - 1); XCTAssertLessThanOrEqual(frame.maxX, width - 11) }
            for pair in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.maxX + 3, pair.1.minX) }
            let detach = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "ウインドウで開く" })
            XCTAssertFalse(detach.isHidden)
            let detachFrame = detach.convert(detach.bounds, to: browser.view)
            XCTAssertGreaterThanOrEqual(detachFrame.minX, width / 2 + 112 - 1)
            XCTAssertLessThanOrEqual(detachFrame.maxX, width - 11)
            let allFrames = (frames + [detachFrame]).sorted { $0.minX < $1.minX }
            for pair in zip(allFrames, allFrames.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.maxX + 3, pair.1.minX)
            }
            if let pin = buttons.first(where: { $0.accessibilityLabel() == "開いたままにする" }) {
                let pinFrame = pin.convert(pin.bounds, to: browser.view)
                XCTAssertGreaterThanOrEqual(detachFrame.minX - pinFrame.maxX, 3)
                XCTAssertLessThanOrEqual(detachFrame.minX - pinFrame.maxX, 4.5)
            }
        }
        let web = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? WKWebView }.first)
        let webRect = web.convert(web.bounds, to: browser.view)
        XCTAssertEqual(webRect.maxY, 468, accuracy: 1)
        XCTAssertEqual(webRect.minX, 8, accuracy: 1)
        XCTAssertEqual(webRect.minY, 8, accuracy: 1)
    }

    @MainActor
    func testDetachedMinimumWidthOverflowsWithoutHidingPermanentControls() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = []
        store.data = settings
        let browser = BrowserViewController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 500),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1000, height: 500))
        XCTAssertEqual(window.contentView?.bounds.width, 1000)
        browser.isDetached = true
        browser.updateDetachedMetrics(trafficInset: 80, rowHeight: 28)
        browser.newTab(nil)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for width in [388.0, 390.0, 420.0, 520.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 500))
            browser.view.layoutSubtreeIfNeeded()
            browser.view.layoutSubtreeIfNeeded()
            let controls = descendants(browser.view).compactMap { $0 as? NSButton }
            let pin = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "開いたままにする" })
            XCTAssertTrue(pin.isHidden)
            for tab in controls.compactMap({ $0 as? TabButton }) where tab.maximumTitleWidth != nil {
                XCTAssertEqual(tab.cell?.lineBreakMode, .byTruncatingTail)
                XCTAssertEqual(tab.cell?.truncatesLastVisibleLine, true)
                var parent = tab.superview
                while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
                let scroll = try XCTUnwrap(parent as? NSScrollView)
                XCTAssertLessThanOrEqual(tab.frame.width, scroll.contentSize.width + 1)
            }
            let names = ["戻る", "進む", "ノッチに戻す", "ページの操作"]
            for name in names {
                let button = try XCTUnwrap(controls.first { $0.accessibilityLabel() == name })
                XCTAssertFalse(button.isHidden)
                let frame = button.convert(button.bounds, to: browser.view)
                XCTAssertGreaterThanOrEqual(frame.minX, 80)
                XCTAssertLessThanOrEqual(frame.maxX, width - 11)
            }
            if width == 388 {
                let menu = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first?.menu)
                for title in ["終了", "設定", "URLを表示・検索", "設定したページに戻る"] {
                    let item = try XCTUnwrap(menu.items.first { $0.title == title })
                    XCTAssertNotNil(item.action)
                    XCTAssertTrue((item.target as? BrowserViewController) === browser)
                }
            }
        }
    }

    @MainActor
    func testAddressPopoverAndHomeReturnToConfiguredPage() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home.html")
        let other = folder.appendingPathComponent("other.html")
        try "<h1>Home</h1>".write(to: home, atomically: true, encoding: .utf8)
        try "<h1>Other</h1>".write(to: other, atomically: true, encoding: .utf8)
        let store = SettingsStore.shared
        let saved = store.data
        defer { store.data = saved }
        var settings = SettingsData()
        settings.pinnedTabs = [PinnedTab(name: "Home", url: home.absoluteString)]
        store.data = settings
        let browser = BrowserViewController()
        let panel = NotchPanel(contentRect: NSRect(x: 100, y: 100, width: 960, height: 660), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = browser.view
        panel.orderFrontRegardless()
        defer { _ = browser.dismissOverlay(); panel.orderOut(nil) }
        browser.view.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? WKWebView }.first)
        func waitForURL(_ url: URL) {
            let deadline = Date().addingTimeInterval(5)
            while (web.url != url || web.isLoading) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertEqual(web.url, url)
        }
        waitForURL(home)
        browser.focusAddressBar()
        let address = try XCTUnwrap(NSApp.windows.flatMap { $0.contentView.map { descendants($0) } ?? [] }.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "検索またはURLを入力" })
        XCTAssertEqual(address.stringValue, home.absoluteString)
        address.stringValue = other.absoluteString
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(address.action), to: address.target, from: address))
        waitForURL(other)
        XCTAssertFalse(browser.dismissOverlay(), "Submitting the URL must close the popover")
        browser.goHome(nil)
        waitForURL(home)
        browser.focusAddressBar()
        XCTAssertTrue(browser.dismissOverlay(), "Escape can dismiss the address popover")
        XCTAssertFalse(browser.dismissOverlay())
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
