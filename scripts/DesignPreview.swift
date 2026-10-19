import AppKit

/// Isolated, offline UI preview. Never uses the installed app's settings or logins.
@main
struct DesignPreview {
    static func main() {
        precondition(Bundle.main.bundleIdentifier == "com.satoshi0817.NotchBrowser.DesignPreview")
        #if DEBUG
        // TASK-NOTCH-020: offline cache states and a pinned failure tooltip.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--cache-state=") }) {
            precondition(["cached", "refreshing", "failed", "settings"].contains(String(argument.dropFirst(14))))
        }
        let selectedNotionTab = NotionPreviewTab.parse(arguments: CommandLine.arguments)
        // Read the connection fixture before constructing the browser or any live stores.
        let connectionPreview = NotionConnectionStore.launchPreviewState
        #endif
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let quitDelegate = PreviewQuitDelegate()
        app.delegate = quitDelegate
        var data = SettingsData()
        data.countdownEnabled = false
        data.hideFromScreenCapture = false
        data.motion.style = CommandLine.arguments.contains("--motion") ? .responsive : .none
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
        if CommandLine.arguments.contains("--no-pinned") { data.pinnedTabs = [] }
        for screen in NSScreen.screens { data.displays[screen.displayUUID] = DisplaySettings(enabled: screen == NSScreen.screens.first, width: CommandLine.arguments.contains("--compact") ? 600 : 960, height: 660) }
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--agents=") }) { data.notionEnabled = true }
        #endif
        #if DEBUG
        if selectedNotionTab != nil || connectionPreview != nil { data.notionEnabled = true }
        #endif
        #if DEBUG
        // TASK-NOTCH-018: fixtures are compiled only into the debug preview.
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--fixed-display=") }) {
            let mode = String(argument.dropFirst(16))
            let display: NotionTabDisplay = mode == "title" ? .titleOnly : mode == "both" ? .iconAndTitle : .iconOnly
            data.tasksTabDisplay = display; data.meetingsTabDisplay = display; data.notionTabDisplay = display
        }
        if CommandLine.arguments.contains("--fixed-pages-drag") {
            data.fixedPageOrder = [PinnedTabsSettings.tasksID] + data.pinnedTabs.prefix(1).map(\.id) +
                [PinnedTabsSettings.meetingsID, PinnedTabsSettings.notionID] + data.pinnedTabs.dropFirst().map(\.id)
        }
        #endif
        SettingsStore.shared.data = data
        let manager = NotchManager(shelfStore: ShelfStore(file: fixture.deletingLastPathComponent().appendingPathComponent("preview-shelf.json")))
        if CommandLine.arguments.contains("--shelf") {
            let files = (1...8).map { index in fixture.deletingLastPathComponent().appendingPathComponent("preview-file-\(index).txt") }
            for (index, file) in files.enumerated() { try? Data("Preview file \(index + 1)".utf8).write(to: file) }
            _ = manager.shelf.store.add(Array(files.prefix(2)))
            for file in files.dropFirst(2) { _ = manager.shelf.store.add([file]) }
        }
        let settings = SettingsWindowController()
        var requestedPreviewAction: (() -> Void)? = nil
        #if DEBUG
        if CommandLine.arguments.contains("--web-lifecycle=settings") {
            requestedPreviewAction = { settings.present(section: .general) }
        } else if CommandLine.arguments.contains("--web-lifecycle=rest-demo") {
            requestedPreviewAction = { manager.browser.previewWebRestDemo(fixture: fixture) }
        } else if CommandLine.arguments.contains("--web-lifecycle=snapshot") || CommandLine.arguments.contains("--web-lifecycle=failed") {
            requestedPreviewAction = {
                manager.browser.previewWebLifecycle(failed: CommandLine.arguments.contains("--web-lifecycle=failed"))
            }
        } else if CommandLine.arguments.contains("--fixed-pages-drag") {
            requestedPreviewAction = { settings.present(section: .tabs, pinnedSelection: .tasks) }
        } else if let preview = SettingsPreviewLaunch.parse(arguments: CommandLine.arguments) {
            requestedPreviewAction = { settings.present(section: preview.section, pinnedSelection: preview.selection) }
        } else if let selectedNotionTab {
            requestedPreviewAction = {
                switch selectedNotionTab {
                case .tasks: manager.browser.showTasks()
                case .agents: manager.browser.showNotion()
                case .meetings: manager.browser.showMeetings()
                }
            }
        } else if MeetingSearchPreviewState.parse(arguments: CommandLine.arguments) != nil {
            requestedPreviewAction = { manager.browser.showMeetings() }
        } else if CommandLine.arguments.contains(where: { $0.hasPrefix("--meetings=") }) {
            requestedPreviewAction = { manager.browser.showMeetings() }
        }
        #endif
        var onboardingSettings = data
        onboardingSettings.countdownEnabled = false
        onboardingSettings.toolbarActions.removeAll { $0 == .notion }
        onboardingSettings.hideFromScreenCapture = true
        let onboarding: OnboardingWindowController? = CommandLine.arguments.contains("--onboarding")
            ? OnboardingWindowController(settings: onboardingSettings, onFinish: { _, _ in }, onSkip: {}) : nil
        manager.browser.onOpenSettings = { settings.present() }
        manager.browser.onOpenNotionSettings = { settings.present(section: .notion) }
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
        if !CommandLine.arguments.contains("--drag-preview") && !CommandLine.arguments.contains("--notion-settings") { manager.toggle() }
        if CommandLine.arguments.contains("--shelf") { manager.showShelf() }
        if let onboarding {
            DispatchQueue.main.async { onboarding.present() }
        } else if let requestedPreviewAction {
            DispatchQueue.main.async(execute: requestedPreviewAction)
        } else if CommandLine.arguments.contains(where: { $0.hasPrefix("--tasks=") }) {
            DispatchQueue.main.async { manager.browser.showTasks() }
        } else if CommandLine.arguments.contains(where: { $0.hasPrefix("--agents=") }) {
            DispatchQueue.main.async { manager.showNotion() }
        } else if CommandLine.arguments.contains("--notion-panel") {
            DispatchQueue.main.async { manager.showNotion() }
        } else if CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--notion-settings") {
            DispatchQueue.main.async { settings.present(section: CommandLine.arguments.contains("--notion-settings") ? .notion : nil) }
        } else {
            manager.browser.newTab(nil)
        }
        if CommandLine.arguments.contains("--tabs") {
            DispatchQueue.main.async { app.activate(); manager.browser.showTabSwitcher(nil) }
        }
        if CommandLine.arguments.contains("--address") {
            DispatchQueue.main.async { app.activate(); manager.browser.focusAddressBar(nil) }
        }
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
        withExtendedLifetime((manager, settings, onboarding, updatePreview, dragFixture, quitDelegate)) { app.run() }
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

/// Exercise the production quit confirmation without starting production services.
final class PreviewQuitDelegate: NSObject, NSApplicationDelegate {
    private let delegate = AppDelegate()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        delegate.applicationShouldTerminate(sender)
    }
}
