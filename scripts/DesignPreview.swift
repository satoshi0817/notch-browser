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
        let manager = NotchManager(shelfStore: ShelfStore(file: fixture.deletingLastPathComponent().appendingPathComponent("preview-shelf.json")))
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
        manager.keepOpen = !CommandLine.arguments.contains("--drag-preview")
        if !CommandLine.arguments.contains("--drag-preview") { manager.toggle() }
        if CommandLine.arguments.contains("--shelf") { manager.showShelf() }
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
        if CommandLine.arguments.contains("--switches") { DispatchQueue.main.async { QuickSwitchWindow.shared.present() } }
        var dragFixture: NSWindow?
        if CommandLine.arguments.contains("--drag-preview") {
            let window = NSWindow(contentRect: NSRect(x: 400, y: 200, width: 600, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Shelf Drag Fixture"
            window.contentView = FileDragFixture(url: fixture, grouped: CommandLine.arguments.contains("--stack-preview"))
            window.makeKeyAndOrderFront(nil)
            dragFixture = window
        }
        var updatePreview: UpdateWindowController?
        if CommandLine.arguments.contains("--update-preview") {
            let release = GitHubRelease(tag_name: "v0.2.2", draft: false, prerelease: false, assets: [.init(name: "NotchBrowser-0.2.2.zip", state: "uploaded", size: 1)])
            updatePreview = UpdateWindowController(release: release, checker: UpdateChecker(currentVersion: "0.2.1"), manual: true)
        }
        withExtendedLifetime((manager, settings, updatePreview, dragFixture)) { app.run() }
    }
}


/// Real AppKit drag source for repeatable offline verification without touching user files.
final class FileDragFixture: NSView, NSDraggingSource {
    let url: URL
    let urls: [URL]
    init(url: URL, grouped: Bool) {
        self.url = url
        let second = url.deletingLastPathComponent().appendingPathComponent("preview-second.txt")
        if grouped { try? Data("Second stack fixture".utf8).write(to: second) }
        urls = grouped ? [url, second] : [url]
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        let label = NSTextField(labelWithString: grouped ? "Drag two files as one stack" : "Drag preview-page.html from here")
        label.frame = NSRect(x: 40, y: 140, width: 420, height: 30)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 32, height: 32)), contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = ShelfViewController.urls(from: sender.draggingPasteboard)
        let output = url.deletingLastPathComponent().appendingPathComponent("preview-shelf-received.json")
        try? JSONEncoder().encode(urls.map(\.absoluteString)).write(to: output)
        return !urls.isEmpty
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
