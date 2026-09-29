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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Browser commands must also work while editing a note or a web form.
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
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
    var onFileDrag: (() -> Bool)?
    var onFileDrop: (([URL]) -> Bool)?
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
        registerForDraggedTypes([.fileURL])
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              !ShelfViewController.urls(from: sender.draggingPasteboard).isEmpty,
              onFileDrag?() == true else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileDrop?(ShelfViewController.urls(from: sender.draggingPasteboard)) ?? false
    }

    /// Right-click menu on the notch itself, so there's always a visible way to quit.
    var contextMenu: NSMenu?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }

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
    private var pointerInside = false
    private(set) var shelfVisible = false
    private(set) var shelfOnly = false

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
        panel.onCancel = { [weak self] in
            guard let self, !self.manager.browser.dismissOverlay() else { return }
            if self.shelfVisible { self.hideShelf() } else { self.collapse() }
        }

        root.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        root.onClick = { [weak self] in self?.expand(focus: true) }
        root.onFileDrag = { [weak self] in
            guard let self, SettingsStore.shared.data.shelfTrigger != .manual || self.shelfVisible else { return false }
            if !self.shelfVisible { self.manager.showShelf(on: self) }
            return true
        }
        root.onFileDrop = { [weak self] urls in
            guard let self, self.shelfVisible else { return false }
            let accepted = self.manager.shelf.store.add(urls)
            if accepted { self.manager.shelf.onDrop?() }
            return accepted
        }
        root.contextMenu = makeContextMenu()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "開く", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        let settings = NSMenuItem(title: "設定…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        let shelf = NSMenuItem(title: "ファイル棚", action: #selector(openShelfFromMenu), keyEquivalent: "")
        shelf.target = self
        shelf.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        let quit = NSMenuItem(title: "NotchBrowser を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.items = [open, shelf, settings, .separator(), quit]
        return menu
    }

    @objc private func openShelfFromMenu() { manager.showShelf(on: self) }
    @objc private func openFromMenu() { expand(focus: true) }
    @objc private func openSettingsFromMenu() { manager.browser.onOpenSettings?() }

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
        if shelfOnly { return NSSize(width: min(480, screen.frame.width - 40), height: 280 + stripHeight) }
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
        layoutContent()
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
        if shelfOnly { hideShelf() }
        hoverTimer?.invalidate()
        if !isExpanded {
            root.contentSize = expandedSize
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
        shelfVisible = false
        shelfOnly = false
        if manager.shelf.view.superview === root.content { manager.shelf.view.removeFromSuperview() }
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
            if manager.browser.view.superview === root.content { manager.browser.view.alphaValue = 0 }
            panel.setFrame(collapsedFrame, display: true)
            panel.alphaValue = idleOpacity
        }
        manager.didCollapse()
    }

    func showShelf() {
        hoverTimer?.invalidate()
        if !shelfVisible { shelfOnly = !isExpanded }
        shelfVisible = true
        isExpanded = true
        panel.hasShadow = true
        let shelf = manager.shelf.view
        shelf.removeFromSuperview()
        root.content.addSubview(shelf)
        relayout(animated: false)
        panel.orderFrontRegardless()
    }

    func hideShelf() {
        guard shelfVisible else { return }
        let wasOnly = shelfOnly
        shelfVisible = false
        shelfOnly = false
        manager.shelf.view.removeFromSuperview()
        if wasOnly { collapse() }
        else { relayout(animated: false) }
    }

    func layoutContent() {
        let bounds = root.content.bounds
        let shelfHeight: CGFloat = shelfVisible ? (shelfOnly ? max(0, bounds.height - stripHeight) : 220) : 0
        if manager.shelf.view.superview === root.content {
            manager.shelf.view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: shelfHeight)
        }
        if manager.browser.view.superview === root.content {
            manager.browser.view.isHidden = shelfOnly
            manager.browser.view.frame = NSRect(x: 0, y: shelfHeight, width: bounds.width, height: max(0, bounds.height - shelfHeight))
        }
    }

    private func animate(to frame: NSRect, radius: CGFloat, contentAlpha: CGFloat) {
        root.cornerRadius = radius
        let windowAlpha = isExpanded ? 1 : idleOpacity
        let motion = SettingsStore.shared.data.motion
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = motion.style == .none || reduceMotion ? 0 : (isExpanded ? motion.openDuration : motion.closeDuration)
            switch motion.style {
            case .responsive:
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            case .easeInOut:
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            case .linear, .none:
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            }
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = windowAlpha
            if manager.browser.view.superview === root.content { manager.browser.view.animator().alphaValue = contentAlpha }
        }
    }

    /// Leaving closes after the configured delay, even after clicking or typing.
    /// Only pinning or an active modal temporarily holds the notch open.
    private func hoverChanged(_ inside: Bool) {
        pointerInside = inside
        hoverTimer?.invalidate()
        hoverTimer = nil
        let motion = SettingsStore.shared.data.motion
        guard !manager.dragActive else { return }
        if inside {
            guard !isExpanded else { return }
            scheduleHover(after: motion.openDelay) { [weak self] in
                guard let self, self.pointerInside else { return }
                self.expand(focus: false)
            }
        } else {
            guard isExpanded, !manager.keepOpen, !manager.isShowingModal, !manager.dragActive else { return }
            scheduleHover(after: motion.closeDelay) { [weak self] in
                guard let self, !self.pointerInside, !self.manager.keepOpen,
                      !self.manager.isShowingModal, !self.manager.dragActive else { return }
                self.collapse()
            }
        }
    }

    private func scheduleHover(after delay: TimeInterval, action: @escaping () -> Void) {
        if delay <= 0 {
            action()
        } else {
            hoverTimer = .scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !manager.keepOpen, !manager.isShowingModal, !manager.dragActive, !shelfVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        // Preserve the timer already started by mouseExited instead of closing early.
        if hoverTimer?.isValid != true { hoverChanged(false) }
    }

    func resumeHoverCloseIfNeeded() {
        if isExpanded, !pointerInside { hoverChanged(false) }
    }
}

/// Owns the browser and one notch per enabled display.
final class NotchManager {
    let browser = BrowserViewController()
    let shelf: ShelfViewController
    private let dragMonitor = ShelfDragMonitor()
    private(set) var dragActive = false
    private var dragWasActive = false
    private var automaticShelf: NotchController?
    private var shelfDropReceived = false
    private var shelfDragOutgoing = false
    private var dragFinishWork: DispatchWorkItem?
    private var controllers: [String: NotchController] = [:]
    private let calendar = CalendarMonitor()
    private let launcherWatcher = LauncherWatcher()
    private var cancellables: Set<AnyCancellable> = []
    private(set) var minutesToNextEvent: Int?
    var isShowingModal = false

    var keepOpen = false {
        didSet {
            browser.keepOpen = keepOpen
            if !keepOpen { controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
        }
    }

    init(shelfStore: ShelfStore = .shared) {
        shelf = ShelfViewController(store: shelfStore)
        browser.onOpenShelf = { [weak self] in self?.showShelf() }
        shelf.onClose = { [weak self] in self?.controllers.values.filter(\.shelfVisible).forEach { $0.hideShelf() } }
        shelf.onDrop = { [weak self] in self?.shelfDropReceived = true }
        shelf.onDrag = { [weak self] active in
            self?.shelfDragOutgoing = active
            self?.dragActive = active
        }
        dragMonitor.onChange = { [weak self] active in self?.dragChanged(active) }
        browser.onToggleKeepOpen = { [weak self] in self?.keepOpen.toggle() }
        browser.onModalChange = { [weak self] showing in
            self?.isShowingModal = showing
            if !showing { self?.controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
        }
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
        dragMonitor.start()
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
                if controller.isExpanded && !controller.shelfOnly { attachBrowser(to: controller) }
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
        view.isHidden = controller.shelfOnly
        controller.layoutContent()
        view.autoresizingMask = []
        browser.updateNotchMetrics(notchWidth: controller.notchSize.width, stripHeight: controller.stripHeight)
    }

    func showShelf(on target: NotchController? = nil) {
        let target = target ?? orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? orderedControllers.first
        guard let target else { return }
        for other in controllers.values where other !== target && other.shelfVisible { other.hideShelf() }
        target.showShelf()
    }

    private func dragChanged(_ active: Bool) {
        dragActive = active || shelfDragOutgoing
        if active {
            dragFinishWork?.cancel()
            if !dragWasActive { shelfDropReceived = false }
            dragWasActive = true
            guard !shelfDragOutgoing,
                  NSPasteboard(name: .drag).availableType(from: [ShelfDragMonitor.originType]) == nil,
                  SettingsStore.shared.data.shelfTrigger != .manual,
                  let target = orderedControllers.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) else { return }
            if SettingsStore.shared.data.shelfTrigger == .nearby {
                let mouse = NSEvent.mouseLocation
                guard abs(mouse.x - target.screen.frame.midX) < 260,
                      mouse.y > target.screen.frame.maxY - 100 else { return }
            }
            if let previous = automaticShelf, previous !== target { previous.hideShelf(); automaticShelf = nil }
            if !target.shelfVisible {
                automaticShelf = target
                showShelf(on: target)
            }
        } else if dragWasActive {
            dragWasActive = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.dragActive else { return }
                if !self.shelfDropReceived { self.automaticShelf?.hideShelf() }
                self.automaticShelf = nil
                if !self.shelfDropReceived { self.controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
            }
            dragFinishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
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
