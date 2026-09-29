import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchManager!
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var keepOpenItem: NSMenuItem!
    private var updateWindow: UpdateWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchManager()
        notch.browser.onOpenSettings = { [weak self] in self?.openSettings() }
        NSApp.mainMenu = buildMainMenu()
        setupStatusItem()
        notch.start()
        UpdateChecker.shared.onUpdate = { [weak self] release, manual in
            self?.updateWindow?.close()
            self?.updateWindow = UpdateWindowController(release: release, checker: .shared, manual: manual)
        }
        UpdateChecker.shared.onMessage = { message in
            let alert = NSAlert()
            alert.messageText = "アップデートの確認"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.window.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
            NSApp.activate()
            alert.runModal()
        }
        UpdateChecker.shared.start()

        // ⌃⌥N toggles the browser from anywhere.
        hotKey = HotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) { [weak self] in
            self?.notch.toggle()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchBrowser")

        let menu = NSMenu()
        menu.addItem(item("開く / 閉じる", #selector(toggleNotch), "n", [.control, .option], target: self))
        keepOpenItem = item("開いたままにする", #selector(toggleKeepOpen), target: self)
        menu.addItem(keepOpenItem)
        menu.addItem(item("クイックスイッチ", #selector(openQuickSwitches), target: self))
        menu.addItem(item("ファイル棚", #selector(openShelf), target: self))
        menu.addItem(item("設定…", #selector(openSettings), ",", target: self))
        menu.addItem(item("アップデートを確認…", #selector(checkForUpdates), target: self))
        menu.addItem(.separator())
        menu.addItem(item("NotchBrowser を終了", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openQuickSwitches() { notch.showQuickSwitches() }

    @objc private func openShelf() { notch.showShelf() }

    @objc private func checkForUpdates() { Task { await UpdateChecker.shared.check() } }

    @objc private func toggleNotch() { notch.toggle() }
    @objc private func toggleKeepOpen() { notch.keepOpen.toggle() }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.present()
    }

    // MARK: Main menu (key equivalents work while the panel is focused)

    private func buildMainMenu() -> NSMenu {
        let browser = notch.browser
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("設定…", #selector(openSettings), ",", target: self))
        appMenu.addItem(item("アップデートを確認…", #selector(checkForUpdates), target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("NotchBrowser を終了", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        addSubmenu(appMenu, to: main)

        let edit = NSMenu(title: "編集")
        edit.addItem(item("取り消す", Selector(("undo:")), "z"))
        edit.addItem(item("やり直す", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("カット", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("コピー", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("ペースト", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("すべてを選択", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("ページ内を検索", #selector(BrowserViewController.showFind(_:)), "f", target: browser))
        addSubmenu(edit, to: main)

        let nav = NSMenu(title: "移動")
        nav.addItem(item("新規タブ", #selector(BrowserViewController.newTab(_:)), "t", target: browser))
        nav.addItem(item("タブを閉じる", #selector(BrowserViewController.closeCurrentTab(_:)), "w", target: browser))
        nav.addItem(item("アドレスバー", #selector(BrowserViewController.focusAddressBar(_:)), "l", target: browser))
        nav.addItem(item("再読み込み", #selector(BrowserViewController.reloadPage(_:)), "r", target: browser))
        nav.addItem(item("戻る", #selector(BrowserViewController.goBack(_:)), "[", target: browser))
        nav.addItem(item("進む", #selector(BrowserViewController.goForward(_:)), "]", target: browser))
        nav.addItem(item("閉じたタブを戻す", #selector(BrowserViewController.reopenClosedTab(_:)), "t", [.command, .shift], target: browser))
        nav.addItem(item("クイックメモ", #selector(BrowserViewController.toggleNotes(_:)), "m", [.command, .shift], target: browser))
        nav.addItem(item("タブを検索", #selector(BrowserViewController.showTabSwitcher(_:)), "a", [.command, .shift], target: browser))
        nav.addItem(item("拡大", #selector(BrowserViewController.zoomIn(_:)), "+", target: browser))
        nav.addItem(item("拡大", #selector(BrowserViewController.zoomIn(_:)), "=", target: browser))
        nav.addItem(item("縮小", #selector(BrowserViewController.zoomOut(_:)), "-", target: browser))
        nav.addItem(item("実際のサイズ", #selector(BrowserViewController.resetZoom(_:)), "0", target: browser))
        nav.addItem(.separator())
        for n in 1...9 {
            nav.addItem(item("タブ \(n)", #selector(BrowserViewController.selectTabByNumber(_:)), "\(n)", target: browser, tag: n))
        }
        addSubmenu(nav, to: main)

        return main
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let holder = NSMenuItem()
        holder.submenu = submenu
        menu.addItem(holder)
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: modifiers.contains(.shift) ? key.uppercased() : key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target // nil = first responder chain
        item.tag = tag
        return item
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        keepOpenItem.state = notch.keepOpen ? .on : .off
    }
}
