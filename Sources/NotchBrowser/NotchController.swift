import AppKit
import Combine

/// Borderless panel that sits over the menu bar, on top of the notch.
final class NotchPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // AppKit pushes windows below the menu bar by default; we need to cover it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        // Take keyboard focus on click without activating the app (like Spotlight),
        // so the app underneath keeps its menu bar.
        if event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Black rounded shape that clips a fixed-size content view anchored to its top center,
/// so resizing the window "reveals" the browser from inside the notch.
final class NotchRootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    let content = NSView()
    var contentSize: NSSize = .zero { didSet { positionContent() } }
    private var trackingArea: NSTrackingArea?

    /// Width of each "wing" beside the notch that shows the next-event countdown.
    static let wingWidth: CGFloat = 40
    private let badgeIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        // Round only the bottom corners; the top is flush with the screen edge.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(content)

        badgeIcon.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        badgeLabel.alignment = .center
        for view in [badgeIcon, badgeLabel] as [NSView] {
            view.alphaValue = 0
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    /// Minutes until the next event, or nil to hide the wings.
    func setBadge(minutes: Int?, visible: Bool) {
        if let minutes {
            badgeLabel.stringValue = "\(minutes)分"
            let tint: NSColor = minutes <= 5 ? .systemOrange : .white
            badgeLabel.textColor = tint
            badgeIcon.contentTintColor = tint
        }
        let alpha: CGFloat = minutes != nil && visible ? 1 : 0
        badgeIcon.animator().alphaValue = alpha
        badgeLabel.animator().alphaValue = alpha
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resizeSubviews(withOldSize oldSize: NSSize) { positionContent() }
    override func layout() {
        super.layout()
        positionContent()
    }

    private func positionContent() {
        let wing = Self.wingWidth
        let labelHeight = badgeLabel.intrinsicContentSize.height
        badgeIcon.frame = NSRect(x: 4, y: ((bounds.height - 18) / 2).rounded(), width: wing - 4, height: 18)
        badgeLabel.frame = NSRect(x: bounds.width - wing, y: ((bounds.height - labelHeight) / 2).rounded(), width: wing - 4, height: labelHeight)
        content.frame = NSRect(
            x: ((bounds.width - contentSize.width) / 2).rounded(),
            y: bounds.height - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

/// One notch on one display. The single browser view moves to whichever notch expands.
final class NotchController: NSObject, NSWindowDelegate {
    let panel: NotchPanel
    let root = NotchRootView()
    private(set) var screen: NSScreen
    private unowned let manager: NotchManager
    private(set) var isExpanded = false
    private var hoverTimer: Timer?

    static let level = NSWindow.Level.popUpMenu

    /// Drops the notch just below a launcher window (e.g. Raycast), or restores it.
    func applyScreenCaptureSetting() {
        panel.sharingType = SettingsStore.shared.data.hideFromScreenCapture ? .none : .readOnly
    }

    func setBelowLauncher(level launcherLevel: Int?) {
        panel.level = launcherLevel.map { NSWindow.Level(rawValue: $0 - 1) } ?? Self.level
    }

    init(screen: NSScreen, manager: NotchManager) {
        self.screen = screen
        self.manager = manager
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = Self.level // after isFloatingPanel, which resets the level to .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        applyScreenCaptureSetting()
        panel.delegate = self
        panel.contentView = root
        panel.onCancel = { [weak self] in self?.collapse() }

        root.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        root.onClick = { [weak self] in self?.expand(focus: true) }
    }

    func show() {
        relayout(animated: false)
        panel.orderFrontRegardless()
    }

    func close() {
        hoverTimer?.invalidate()
        panel.orderOut(nil)
    }

    func update(screen: NSScreen) {
        self.screen = screen
        relayout(animated: false)
    }

    // MARK: Geometry

    private var settings: DisplaySettings { SettingsStore.shared.displaySettings(for: screen) }

    var notchSize: NSSize {
        if screen.hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NSSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return NSSize(width: 200, height: NSStatusBar.system.thickness)
    }

    var stripHeight: CGFloat { max(notchSize.height, 32) }

    var expandedSize: NSSize {
        let frame = screen.frame
        return NSSize(
            width: min(settings.width, frame.width - 40).rounded(),
            height: min(settings.height, frame.height - 40).rounded()
        )
    }

    private var collapsedFrame: NSRect {
        var size = notchSize
        if manager.minutesToNextEvent != nil { size.width += NotchRootView.wingWidth * 2 }
        return topCenteredFrame(size)
    }

    private var expandedFrame: NSRect { topCenteredFrame(expandedSize) }

    private func topCenteredFrame(_ size: NSSize) -> NSRect {
        let frame = screen.frame
        return NSRect(x: (frame.midX - size.width / 2).rounded(), y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Opacity of the idle notch. Kept just above zero so the window still receives hover.
    private var idleOpacity: CGFloat { max(CGFloat(settings.idleOpacity), 0.01) }

    /// Re-applies size and opacity, e.g. after settings or the calendar badge changed.
    func relayout(animated: Bool = true) {
        root.contentSize = expandedSize
        root.cornerRadius = isExpanded ? 18 : 10
        root.setBadge(minutes: manager.minutesToNextEvent, visible: !isExpanded)
        let frame = isExpanded ? expandedFrame : collapsedFrame
        let alpha = isExpanded ? 1 : idleOpacity
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = alpha
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = alpha
        }
    }

    // MARK: Expand / collapse

    func expand(focus: Bool) {
        hoverTimer?.invalidate()
        if !isExpanded {
            manager.browser.prepareForOpen()
            manager.willExpand(self)
            isExpanded = true
            panel.hasShadow = true
            root.setBadge(minutes: manager.minutesToNextEvent, visible: false)
            animate(to: expandedFrame, radius: 18, contentAlpha: 1)
        }
        if focus {
            panel.makeKey()
            manager.browser.focusContent()
        }
    }

    func collapse(animated: Bool = true) {
        hoverTimer?.invalidate()
        guard isExpanded else { return }
        isExpanded = false
        if panel.isKeyWindow {
            // Hand keyboard focus back to the app underneath.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.hasShadow = false
        root.setBadge(minutes: manager.minutesToNextEvent, visible: true)
        if animated {
            animate(to: collapsedFrame, radius: 10, contentAlpha: 0)
        } else {
            root.cornerRadius = 10
            manager.browser.view.alphaValue = 0
            panel.setFrame(collapsedFrame, display: true)
            panel.alphaValue = idleOpacity
        }
        manager.didCollapse()
    }

    private func animate(to frame: NSRect, radius: CGFloat, contentAlpha: CGFloat) {
        root.cornerRadius = radius
        let windowAlpha = isExpanded ? 1 : idleOpacity
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = windowAlpha
            manager.browser.view.animator().alphaValue = contentAlpha
        }
    }

    /// Hover just peeks. Once the panel has keyboard focus, it stays open until the
    /// user clicks elsewhere, presses Esc, or hits the hotkey.
    private func hoverChanged(_ inside: Bool) {
        hoverTimer?.invalidate()
        if inside {
            guard !isExpanded else { return }
            hoverTimer = .scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                self?.expand(focus: false)
            }
        } else {
            guard isExpanded, !manager.keepOpen, !panel.isKeyWindow, !manager.isShowingModal else { return }
            hoverTimer = .scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.collapse()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !manager.keepOpen, !manager.isShowingModal, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }
}

/// Owns the browser and one notch per enabled display.
final class NotchManager {
    let browser = BrowserViewController()
    private var controllers: [String: NotchController] = [:]
    private let calendar = CalendarMonitor()
    private let launcherWatcher = LauncherWatcher()
    private var cancellables: Set<AnyCancellable> = []
    private(set) var minutesToNextEvent: Int?
    var isShowingModal = false

    var keepOpen = false {
        didSet { browser.keepOpen = keepOpen }
    }

    init() {
        browser.onToggleKeepOpen = { [weak self] in self?.keepOpen.toggle() }
        browser.onModalChange = { [weak self] showing in self?.isShowingModal = showing }
        calendar.onChange = { [weak self] minutes in
            self?.minutesToNextEvent = minutes
            self?.controllers.values.forEach { $0.relayout() }
        }

        launcherWatcher.onChange = { [weak self] level in
            self?.controllers.values.forEach { $0.setBelowLauncher(level: level) }
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        SettingsStore.shared.$data
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
    }

    func start() {
        browser.view.alphaValue = 0
        applyCalendarSettings()
        rebuild()
        applyWindowSettings()
        calendar.start()
    }

    private func settingsChanged() {
        applyCalendarSettings()
        rebuild()
        applyWindowSettings()
        browser.settingsChanged()
    }

    private func applyWindowSettings() {
        controllers.values.forEach { $0.applyScreenCaptureSetting() }
        browser.hideFromScreenCapture = SettingsStore.shared.data.hideFromScreenCapture
    }

    private func applyCalendarSettings() {
        let data = SettingsStore.shared.data
        calendar.isEnabled = data.countdownEnabled
        calendar.thresholdMinutes = data.countdownMinutes
    }

    /// Syncs notch windows with connected displays and their settings.
    private func rebuild() {
        let store = SettingsStore.shared
        let enabled = NSScreen.screens.filter { store.displaySettings(for: $0).enabled }
        let ids = Set(enabled.map(\.displayUUID))

        for (id, controller) in controllers where !ids.contains(id) {
            controller.collapse(animated: false)
            controller.close()
            controllers[id] = nil
        }
        for screen in enabled {
            if let controller = controllers[screen.displayUUID] {
                controller.update(screen: screen)
                if controller.isExpanded { attachBrowser(to: controller) }
            } else {
                let controller = NotchController(screen: screen, manager: self)
                controllers[screen.displayUUID] = controller
                controller.show()
            }
        }
    }

    private var orderedControllers: [NotchController] {
        NSScreen.screens.compactMap { controllers[$0.displayUUID] }
    }

    func willExpand(_ controller: NotchController) {
        for other in controllers.values where other !== controller && other.isExpanded {
            other.collapse(animated: false)
        }
        attachBrowser(to: controller)
        launcherWatcher.start()
    }

    func didCollapse() {
        guard !controllers.values.contains(where: \.isExpanded) else { return }
        launcherWatcher.stop()
    }

    private func attachBrowser(to controller: NotchController) {
        let view = browser.view
        if view.superview !== controller.root.content {
            view.removeFromSuperview()
            controller.root.content.addSubview(view)
        }
        view.frame = controller.root.content.bounds
        view.autoresizingMask = [.width, .height]
        browser.updateNotchMetrics(notchWidth: controller.notchSize.width, stripHeight: controller.stripHeight)
    }

    /// Hotkey: collapse if focused, otherwise open on the display under the pointer.
    func toggle() {
        if let open = controllers.values.first(where: \.isExpanded), open.panel.isKeyWindow {
            open.collapse()
            return
        }
        let mouse = NSEvent.mouseLocation
        let target = orderedControllers.first { $0.screen.frame.contains(mouse) } ?? orderedControllers.first
        target?.expand(focus: true)
    }
}
