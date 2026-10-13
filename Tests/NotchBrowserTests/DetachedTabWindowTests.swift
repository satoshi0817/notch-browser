import AppKit
import WebKit
import XCTest
@testable import NotchBrowser

final class DetachedTabWindowTests: XCTestCase {
    @MainActor
    private func withManager(_ body: (NotchManager) throws -> Void) rethrows {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let original = store.data
        let savedSize = UserDefaults.standard.string(forKey: "detachedTabWindowSize")
        var settings = SettingsData()
        settings.pinnedTabs = []
        settings.notionEnabled = false
        settings.countdownEnabled = false
        settings.motion.style = .none
        store.data = settings
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let manager = NotchManager(shelfStore: ShelfStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("items.json")))
        defer {
            for controller in manager.detachedTabs { controller.window?.close() }
            for window in NSApp.windows where !existingWindows.contains(ObjectIdentifier(window)) {
                if let notch = window.delegate as? NotchController { notch.close() }
            }
            store.data = original
            if let savedSize { UserDefaults.standard.set(savedSize, forKey: "detachedTabWindowSize") }
            else { UserDefaults.standard.removeObject(forKey: "detachedTabWindowSize") }
        }
        _ = manager.browser.view
        try body(manager)
    }

    @MainActor
    func testDetachAndReturnPreserveWebViewAndAppendAtRight() throws {
        try withManager { manager in
            manager.browser.newTab(nil)
            let first = try XCTUnwrap(manager.browser.currentTab)
            first.webView.pageZoom = 1.5
            manager.browser.newTab(nil)
            let second = try XCTUnwrap(manager.browser.currentTab)
            manager.detachTab(first)
            let window = try XCTUnwrap(manager.detachedTabs.first)
            XCTAssertEqual(manager.browser.tabCount, 1)
            XCTAssertTrue(manager.browser.currentTab === second)
            XCTAssertTrue(window.browser.currentTab === first)
            XCTAssertTrue(window.browser.currentTab?.webView === first.webView)
            XCTAssertEqual(first.webView.pageZoom, 1.5)
            let buttons = descendants(window.browser.view).compactMap { $0 as? TabButton }
            XCTAssertNotNil(buttons.first?.menu?.items.first { $0.title == "ノッチに戻す" })
            let returnButton = descendants(window.browser.view).compactMap { $0 as? NSButton }
                .first { $0.toolTip == "ノッチに戻す" }
            XCTAssertNotNil(returnButton)
            XCTAssertNil(buttons.first?.onDragOut)
            returnButton?.performClick(nil)
            XCTAssertTrue(manager.detachedTabs.isEmpty)
            XCTAssertEqual(manager.browser.tabCount, 2)
            XCTAssertTrue(manager.browser.currentTab === first)
            let number = NSMenuItem()
            number.tag = 2
            manager.browser.selectTabByNumber(number)
            XCTAssertTrue(manager.browser.currentTab === first)
        }
    }

    @MainActor
    func testPinnedTabCannotDetachAndMenuIsDisabled() throws {
        try withManager { manager in
            let pinned = PinnedTab(name: "固定", url: "about:blank", profileID: Profile.defaultID)
            SettingsStore.shared.data.pinnedTabs = [pinned]
            manager.browser.settingsChanged()
            let pinnedTab = try XCTUnwrap(manager.browser.currentTab)
            manager.detachTab(pinnedTab)
            manager.browser.detachCurrentTab(nil)
            XCTAssertTrue(manager.detachedTabs.isEmpty)
            XCTAssertEqual(manager.browser.tabCount, 1)
            let buttons = descendants(manager.browser.view).compactMap { $0 as? TabButton }
            let button = try XCTUnwrap(buttons.first { $0.title == "固定" })
            let item = try XCTUnwrap(button.menu?.items.first { $0.title == "このタブを別ウインドウで開く" })
            XCTAssertFalse(item.isEnabled)
            XCTAssertNil(button.onDragOut)
        }
    }

    @MainActor
    func testClosingWindowClosesOnlyItsTabAndReleasesTimers() throws {
        try withManager { manager in
            manager.browser.newTab(nil)
            let tab = try XCTUnwrap(manager.browser.currentTab)
            let timer = Timer(timeInterval: 60, repeats: true) { _ in }
            tab.refreshTimer = timer
            manager.detachTab(tab)
            manager.browser.newTab(nil)
            let remaining = manager.browser.currentTab
            let controller = try XCTUnwrap(manager.detachedTabs.first)
            controller.window?.close()
            XCTAssertTrue(manager.detachedTabs.isEmpty)
            XCTAssertEqual(controller.browser.tabCount, 0)
            XCTAssertFalse(timer.isValid)
            XCTAssertNil(tab.webView.superview)
            XCTAssertTrue(manager.browser.currentTab === remaining)
        }
    }

    @MainActor
    func testMultipleWindowsAndNewTabKeepOneTabPerWindow() throws {
        try withManager { manager in
            for _ in 0..<3 {
                manager.browser.newTab(nil)
                manager.browser.detachCurrentTab(nil)
            }
            XCTAssertEqual(manager.detachedTabs.count, 3)
            XCTAssertEqual(manager.browser.tabCount, 0)
            let first = try XCTUnwrap(manager.detachedTabs.first)
            first.browser.newTab(nil)
            XCTAssertEqual(manager.detachedTabs.count, 3)
            XCTAssertEqual(manager.browser.tabCount, 1)
            XCTAssertTrue(manager.detachedTabs.allSatisfy { $0.browser.tabCount == 1 })
            first.browser.closeCurrentTab(nil)
            XCTAssertEqual(manager.detachedTabs.count, 2)
        }
    }

    @MainActor
    func testCommandTFromDetachedWindowCreatesAndShowsNotchTab() throws {
        try withManager { manager in
            manager.rebuild()
            manager.browser.newTab(nil)
            let detachedTab = try XCTUnwrap(manager.browser.currentTab)
            manager.browser.detachCurrentTab(nil)
            let controller = try XCTUnwrap(manager.detachedTabs.first)
            let window = try XCTUnwrap(controller.window)
            let plus = descendants(controller.browser.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "新規タブ (⌘T)" }
            XCTAssertTrue(plus == nil || plus?.isHidden == true)
            window.makeKeyAndOrderFront(nil)
            controller.browser.focusContent()
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(window.canBecomeKey)
            // Exercise the actual menu key-equivalent path and its explicit dispatcher.
            // XCTest's command-line host does not synchronously gain application
            // focus. Supply the intended focused window; do not assume keyWindow.
            let command = BrowserNewTabCommand(browser: manager.browser, focusedWindow: { window })
            let menu = NSMenu()
            let item = command.makeMenuItem()
            let action = try XCTUnwrap(item.action)
            XCTAssertEqual(NSStringFromSelector(action), "openBrowserNewTab:")
            XCTAssertTrue(command.responds(to: action))
            menu.addItem(item)
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "t",
                charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
            XCTAssertTrue(menu.performKeyEquivalent(with: key))
            XCTAssertEqual(manager.browser.tabCount, 1)
            XCTAssertFalse(manager.browser.currentTab === detachedTab)
            XCTAssertEqual(controller.browser.tabCount, 1)
            XCTAssertTrue(controller.browser.currentTab === detachedTab)
            XCTAssertEqual(manager.detachedTabs.count, 1)
            XCTAssertTrue(manager.browser.view.window is NotchPanel)
            XCTAssertEqual((manager.browser.view.window?.delegate as? NotchController)?.isExpanded, true)
        }
    }

    @MainActor
    func testNewTabMenuOwnsTargetAndUsesFallbackWithoutKeyWindow() throws {
        try withManager { manager in
            weak var receiver: BrowserNewTabCommand?
            weak var menuItem: NSMenuItem?
            // AppKit's key-equivalent dispatch and Objective-C bridging may
            // autorelease temporary references. Check lifetime after draining
            // that pool and leaving the scope of all Swift temporaries.
            try autoreleasepool {
                let menu = NSMenu()
                let item: NSMenuItem = {
                    let command = BrowserNewTabCommand(browser: manager.browser, focusedWindow: { nil })
                    receiver = command
                    return command.makeMenuItem()
                }()
                menuItem = item
                menu.addItem(item)
                // Only the item owns the command after its construction scope.
                XCTAssertNotNil(receiver)
                let action = try XCTUnwrap(item.action)
                XCTAssertTrue(try XCTUnwrap(receiver).responds(to: action))
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "t",
                    charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
                XCTAssertTrue(menu.performKeyEquivalent(with: key))
                XCTAssertEqual(manager.browser.tabCount, 1)
                XCTAssertTrue(manager.detachedTabs.isEmpty)
                menu.removeAllItems()
            }
            XCTAssertNil(menuItem, "The menu item must release after its scope and autorelease pool end")
            XCTAssertNil(receiver, "The command must release with its owning menu item")
        }
    }

    @MainActor
    func testDragCallbackCreatesOnlyFinalSingleTabWindow() throws {
        try withManager { manager in
            manager.rebuild()
            manager.browser.newTab(nil)
            manager.browser.newTab(nil)
            manager.toggle()
            let notch = try XCTUnwrap(manager.browser.view.window?.delegate as? NotchController)
            XCTAssertTrue(notch.isExpanded)
            let expandedFrame = notch.panel.frame
            notch.hoverPointerLocation = { NSPoint(x: expandedFrame.midX, y: expandedFrame.midY) }
            let draggedTab = try XCTUnwrap(manager.browser.currentTab)
            let button = try XCTUnwrap(descendants(manager.browser.view).compactMap { $0 as? TabButton }
                .first { $0.state == .on && $0.onDragOut != nil })
            let dragOut = try XCTUnwrap(button.onDragOut)
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let pointer = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
            dragOut(pointer)
            XCTAssertFalse(notch.isExpanded)
            notch.root.onHoverChange?(false)
            notch.root.onHoverChange?(true)
            XCTAssertFalse(notch.isExpanded, "Dragging must not reopen the panel in front of the new tab window")
            // Repeated callbacks for the same source cannot leave an extra window.
            dragOut(pointer)
            let controller = try XCTUnwrap(manager.detachedTabs.first)
            XCTAssertEqual(manager.detachedTabs.count, 1)
            XCTAssertFalse(manager.isDetached)
            XCTAssertEqual(manager.browser.tabCount, 1)
            XCTAssertTrue(controller.browser.isSingleTabWindow)
            XCTAssertEqual(controller.browser.tabCount, 1)
            XCTAssertTrue(controller.browser.currentTab === draggedTab)
            XCTAssertTrue(controller.window?.isVisible == true)
            XCTAssertTrue(controller.window?.canBecomeKey == true)
            XCTAssertLessThan(notch.panel.frame.height, expandedFrame.height)
            let tabs = descendants(controller.browser.view).compactMap { $0 as? TabButton }
            XCTAssertEqual(tabs.count, 1)
            let plus = descendants(controller.browser.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "新規タブ (⌘T)" }
            XCTAssertTrue(plus == nil || plus?.isHidden == true)
            let newVisibleWindows = NSApp.windows.filter { $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) }
            XCTAssertEqual(newVisibleWindows.count, 1)
            XCTAssertTrue(newVisibleWindows.first === controller.window)
        }
    }

    @MainActor
    func testWholeBrowserDetachAndReturnLeaveTabWindowsAlive() throws {
        try withManager { manager in
            manager.rebuild()
            manager.browser.newTab(nil)
            manager.browser.detachCurrentTab(nil)
            let controller = try XCTUnwrap(manager.detachedTabs.first)
            let web = try XCTUnwrap(controller.browser.currentTab?.webView)
            manager.toggleDetached()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(manager.isDetached)
            XCTAssertEqual(manager.detachedTabs.count, 1)
            XCTAssertTrue(controller.browser.currentTab?.webView === web)
            manager.toggleDetached()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertFalse(manager.isDetached)
            XCTAssertEqual(manager.detachedTabs.count, 1)
            XCTAssertTrue(controller.browser.currentTab?.webView === web)
            controller.onReturn?()
            XCTAssertTrue(manager.detachedTabs.isEmpty)
            XCTAssertTrue(manager.browser.currentTab?.webView === web)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    func testReturnWhileWholeBrowserIsDetachedAndRememberWindowSize() throws {
        try withManager { manager in
            manager.rebuild()
            manager.toggleDetached()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(manager.isDetached)
            manager.browser.newTab(nil)
            let tab = try XCTUnwrap(manager.browser.currentTab)
            manager.browser.detachCurrentTab(nil)
            let controller = try XCTUnwrap(manager.detachedTabs.first)
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 800, height: 500))
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            let expectedSize = window.contentRect(forFrameRect: window.frame).size
            controller.onReturn?()
            XCTAssertTrue(manager.isDetached)
            XCTAssertTrue(manager.browser.currentTab === tab)
            manager.browser.detachCurrentTab(nil)
            let next = try XCTUnwrap(manager.detachedTabs.first?.window)
            XCTAssertEqual(next.contentRect(forFrameRect: next.frame).width, expectedSize.width, accuracy: 1)
            XCTAssertEqual(next.contentRect(forFrameRect: next.frame).height, expectedSize.height, accuracy: 1)
            manager.toggleDetached()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertFalse(manager.isDetached)
            XCTAssertEqual(manager.detachedTabs.count, 1)
        }
    }

    @MainActor
    func testToggleClosesHoverOpenedNotchWithoutKeyboardFocus() throws {
        try withManager { manager in
            manager.rebuild()
            SettingsStore.shared.data.motion.openDelay = 0
            let controller = try XCTUnwrap(NSApp.windows.compactMap { $0.delegate as? NotchController }.first)
            controller.root.onHoverChange?(true)
            XCTAssertTrue(controller.isExpanded)
            controller.panel.resignKey()
            manager.toggle()
            XCTAssertFalse(controller.isExpanded)
            controller.root.onHoverChange?(true)
            XCTAssertFalse(controller.isExpanded)
        }
    }

    @MainActor
    func testLoadedPageTitleAndFormValueSurviveRoundTrip() throws {
        try withManager { manager in
            manager.rebuild()
            manager.browser.newTab(nil)
            let tab = try XCTUnwrap(manager.browser.currentTab)
            let web = tab.webView
            let loaded = expectation(description: "Local page loaded")
            var didLoad = false
            let observation = web.observe(\.title) { web, _ in
                if web.title == "テストページ", !didLoad { didLoad = true; loaded.fulfill() }
            }
            web.loadHTMLString("<title>テストページ</title><input id='value' value='保持する値'>", baseURL: nil)
            wait(for: [loaded], timeout: 10)
            withExtendedLifetime(observation) {}
            manager.detachTab(tab)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let controller = try XCTUnwrap(manager.detachedTabs.first)
            XCTAssertEqual(controller.window?.title, "テストページ")
            XCTAssertTrue(controller.browser.currentTab?.webView === web)
            controller.onReturn?()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(manager.detachedTabs.isEmpty)
            XCTAssertTrue(manager.browser.currentTab?.webView === web)
            let valueChecked = expectation(description: "Form state retained")
            web.evaluateJavaScript("document.getElementById('value').value") { value, error in
                XCTAssertNil(error)
                XCTAssertEqual(value as? String, "保持する値")
                valueChecked.fulfill()
            }
            wait(for: [valueChecked], timeout: 10)
        }
    }

    func testDragThresholdIsFortyPointsBelowStrip() {
        let strip = NSRect(x: 0, y: 0, width: 600, height: 32)
        XCTAssertFalse(TabDetachmentGesture.shouldDetach(pointer: NSPoint(x: 80, y: -39), strip: strip, flipped: false))
        XCTAssertTrue(TabDetachmentGesture.shouldDetach(pointer: NSPoint(x: 80, y: -40), strip: strip, flipped: false))
        XCTAssertFalse(TabDetachmentGesture.shouldDetach(pointer: NSPoint(x: 80, y: 71), strip: strip, flipped: true))
        XCTAssertTrue(TabDetachmentGesture.shouldDetach(pointer: NSPoint(x: 80, y: 72), strip: strip, flipped: true))
    }

    func testTabShortcutDefaultsAndLegacyDecode() throws {
        XCTAssertEqual(GlobalShortcutAction.detachTab.defaultBinding, .unassigned)
        let legacy = try JSONDecoder().decode(ShortcutPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.detachTab, .unassigned)
        var preferences = legacy
        preferences[.detachTab] = .keys([ShortcutStroke(keyCode: 2, modifiers: [.control, .option])])
        XCTAssertNil(preferences.error(for: preferences.detachTab, action: .detachTab))
        XCTAssertEqual(try JSONDecoder().decode(ShortcutPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertNotNil(preferences.error(for: preferences.toggle, action: .detachTab))
    }
}
