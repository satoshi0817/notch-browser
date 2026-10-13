import AppKit

/// A WKWebView's responder chain need not include its content view controller.
/// Resolve the focused browser explicitly for the main menu's Command-T action.
final class BrowserNewTabCommand: NSObject {
    private weak var fallback: BrowserViewController?
    private let focusedWindow: () -> NSWindow?

    init(browser: BrowserViewController, focusedWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        fallback = browser
        self.focusedWindow = focusedWindow
        super.init()
    }

    // Do not use perform(_:): NSObject already exposes perform: with a Selector
    // argument. A menu sender is not a Selector and must never reach that API.
    @objc(openBrowserNewTab:) func openNewTab(_ sender: Any?) {
        let browser = focusedWindow()?.contentViewController as? BrowserViewController ?? fallback
        browser?.newTab(sender)
    }

    func makeMenuItem() -> NSMenuItem { BrowserNewTabMenuItem(command: self) }
}

/// NSMenuItem.target is weak; the item explicitly owns its action receiver.
private final class BrowserNewTabMenuItem: NSMenuItem {
    private let command: BrowserNewTabCommand

    init(command: BrowserNewTabCommand) {
        self.command = command
        super.init(title: "新規タブ", action: #selector(BrowserNewTabCommand.openNewTab(_:)), keyEquivalent: "t")
        keyEquivalentModifierMask = .command
        target = command
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
