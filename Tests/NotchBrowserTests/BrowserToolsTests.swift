import AppKit
import WebKit
import XCTest
@testable import NotchBrowser

final class BrowserToolsTests: XCTestCase {
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
        let address = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "検索またはURLを入力" })
        let rect = address.convert(address.bounds, to: browser.view)
        XCTAssertGreaterThan(rect.width, 20)
        XCTAssertGreaterThan(rect.minX, 420)
        let web = try XCTUnwrap(descendants(browser.view).compactMap { $0 as? WKWebView }.first)
        let webRect = web.convert(web.bounds, to: browser.view)
        XCTAssertEqual(webRect.maxY, 468, accuracy: 1)
        XCTAssertEqual(webRect.minX, 8, accuracy: 1)
        XCTAssertEqual(webRect.minY, 8, accuracy: 1)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
