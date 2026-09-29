import AppKit

/// Isolated, offline UI preview. Never uses the installed app's settings or logins.
@main
struct DesignPreview {
    static func main() {
        precondition(Bundle.main.bundleIdentifier == "com.satoshi0817.NotchBrowser.DesignPreview")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var data = SettingsData()
        data.countdownEnabled = false
        data.hideFromScreenCapture = false
        data.motion.style = .none
        let profile = Profile(id: UUID(), name: "Preview")
        data.profiles = [Profile(id: Profile.defaultID, name: "デフォルト"), profile]
        data.newTabProfileID = profile.id
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        data.pinnedTabs = [
            PinnedTab(name: "メール", url: fixture.absoluteString, icon: .symbol("envelope"), profileID: profile.id),
            PinnedTab(name: "カレンダー", url: fixture.absoluteString, icon: .symbol("calendar"), profileID: profile.id),
            PinnedTab(name: "ドキュメント", url: fixture.absoluteString, icon: .symbol("doc.text"), profileID: profile.id),
            PinnedTab(name: "チーム", url: fixture.absoluteString, icon: .symbol("bubble.left.and.bubble.right"), profileID: profile.id)
        ]
        for screen in NSScreen.screens { data.displays[screen.displayUUID] = DisplaySettings(enabled: screen == NSScreen.screens.first, width: 960, height: 660) }
        SettingsStore.shared.data = data
        let manager = NotchManager()
        let settings = SettingsWindowController()
        manager.browser.onOpenSettings = { settings.present() }
        let menu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        menu.addItem(root)
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for (title, action, key, modifiers) in [
            ("クイックメモ", #selector(BrowserViewController.toggleNotes(_:)), "m", NSEvent.ModifierFlags([.command, .shift])),
            ("タブを検索", #selector(BrowserViewController.showTabSwitcher(_:)), "a", NSEvent.ModifierFlags([.command, .shift])),
            ("URLを表示", #selector(BrowserViewController.focusAddressBar(_:)), "l", NSEvent.ModifierFlags.command),
            ("ページ内を検索", #selector(BrowserViewController.showFind(_:)), "f", NSEvent.ModifierFlags.command)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: modifiers.contains(.shift) ? key.uppercased() : key)
            item.keyEquivalentModifierMask = modifiers
            item.target = manager.browser
            appMenu.addItem(item)
        }
        app.mainMenu = menu
        manager.start()
        manager.keepOpen = true
        manager.toggle()
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { settings.present() }
        } else {
            manager.browser.newTab(nil)
        }
        if CommandLine.arguments.contains("--tabs") {
            DispatchQueue.main.async { app.activate(); manager.browser.showTabSwitcher(nil) }
        }
        if CommandLine.arguments.contains("--address") {
            DispatchQueue.main.async { app.activate(); manager.browser.focusAddressBar(nil) }
        }
        var updatePreview: UpdateWindowController?
        if CommandLine.arguments.contains("--update-preview") {
            let release = GitHubRelease(tag_name: "v0.2.2", draft: false, prerelease: false, assets: [.init(name: "NotchBrowser-0.2.2.zip", state: "uploaded", size: 1)])
            updatePreview = UpdateWindowController(release: release, checker: UpdateChecker(currentVersion: "0.2.1"), manual: true)
        }
        withExtendedLifetime((manager, settings, updatePreview)) { app.run() }
    }
}
