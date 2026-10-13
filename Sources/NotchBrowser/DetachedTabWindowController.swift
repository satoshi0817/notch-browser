import AppKit
import WebKit

/// Independent ownership keeps tab windows alive across whole-browser transfers.
final class DetachedTabWindowController: NSWindowController, NSWindowDelegate {
    let browser = BrowserViewController()
    var onReturn: (() -> Void)?
    var onClosed: (() -> Void)?
    private var normalFrameState: DetachedNormalFrameState?
    private var fullScreenTransition = false

    init(tab: Tab) {
        let saved = UserDefaults.standard.string(forKey: "detachedTabWindowSize").map(NSSizeFromString)
        let size = saved.flatMap { $0.width.isFinite && $0.height.isFinite && $0.width >= 600 && $0.height >= 320 ? $0 : nil } ?? NSSize(width: 1000, height: 700)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 600, height: 320)
        window.sharingType = SettingsStore.shared.data.hideFromScreenCapture ? .none : .readOnly
        browser.isSingleTabWindow = true
        window.contentViewController = browser
        browser.isDetached = true
        browser.receiveTab(tab)
        window.setContentSize(size)
        browser.onReturnTab = { [weak self] in self?.onReturn?() }
        browser.onSingleTabClosed = { [weak self] in self?.window?.close() }
        window.title = tab.displayName
        browser.onPageTitleChanged = { [weak window] title in window?.title = title }
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(at point: NSPoint?) {
        guard let window else { return }
        window.delegate = nil
        window.center()
        if let point { window.setFrameTopLeftPoint(point) }
        let frame = DetachedWindowGeometry.constrain(window.frame, screens: NSScreen.screens.map(\.visibleFrame),
            primary: NSScreen.main?.visibleFrame ?? window.frame, minimumSize: window.minSize)
        window.setFrame(frame, display: false)
        // Settle single-tab chrome before the first visible frame, including
        // traffic-light spacing and the absence of the new-tab button.
        updateMetrics()
        window.contentView?.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        updateMetrics()
        normalFrameState = DetachedNormalFrameState(frame: frame)
        window.delegate = self
        browser.focusContent()
    }

    private func updateMetrics() {
        guard let window, let content = window.contentView else { return }
        let inset = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: content).maxX }.max().map { $0 + 12 } ?? 80
        let fullscreen = window.styleMask.contains(.fullScreen)
        let buttonFrame = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: content) }
        let height = fullscreen ? CGFloat(36) : max(28, buttonFrame.map { 2 * (content.bounds.maxY - $0.midY) } ?? 28)
        browser.updateDetachedMetrics(trafficInset: fullscreen ? 14 : inset, rowHeight: height)
    }

    func windowDidResize(_ notification: Notification) {
        updateMetrics()
        saveSize()
    }

    private func saveSize() {
        guard let window, !fullScreenTransition, !window.styleMask.contains(.fullScreen),
              let state = normalFrameState else { return }
        var updated = state
        let normal = updated.observe(frame: window.frame, visibleFrame: window.screen?.visibleFrame ?? window.frame,
                                     isZoomed: window.isZoomed)
        normalFrameState = updated
        UserDefaults.standard.set(NSStringFromSize(window.contentRect(forFrameRect: normal).size), forKey: "detachedTabWindowSize")
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        normalFrameState?.beginZoom(frame: window.frame, target: newFrame,
                                   visibleFrame: window.screen?.visibleFrame ?? newFrame, isZoomed: window.isZoomed)
        return true
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenTransition = false; updateMetrics() }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenTransition = false; updateMetrics() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenTransition = false; updateMetrics() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenTransition = false; updateMetrics() }

    func windowWillClose(_ notification: Notification) {
        saveSize()
        browser.onPageTitleChanged = nil
        browser.onSingleTabClosed = nil
        browser.closeCurrentTab(nil)
        onClosed?()
    }
}
