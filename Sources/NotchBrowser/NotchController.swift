import AppKit
import Combine
import SwiftUI

enum CalendarHelperLayout {
    static let calendarHelperRowGapPts: CGFloat = 2
    static let bottomPadding: CGFloat = 4
    static let rowHeight: CGFloat = 18
    static let horizontalInset: CGFloat = 6
    static let primaryFontSize: CGFloat = 13
    static let secondaryFontSize = primaryFontSize * 0.88
    static let height = rowHeight + calendarHelperRowGapPts + bottomPadding
}

/// A single clipped line with automatic overflow motion and no scroll controls.
private final class CalendarHelperView: NSView {
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CalendarHelperLayout.secondaryFontSize),
        .foregroundColor: NSColor.white.withAlphaComponent(0.6)
    ]
    private var text = ""
    private var textWidth: CGFloat = 0
    private var startedAt = Date()
    private var timer: Timer?

    func setText(_ value: String, visible: Bool) {
        if value != text || isHidden == visible { startedAt = Date() }
        text = value
        textWidth = (text as NSString).size(withAttributes: attributes).width
        isHidden = !visible
        updateTimer()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { startedAt = Date() }
        updateTimer()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        guard !isHidden, window != nil, bounds.width > 0, textWidth > bounds.width else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        var offset: CGFloat = 0
        if textWidth > bounds.width {
            let travel = textWidth - bounds.width
            let duration = Double(travel / 24)
            let elapsed = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: duration + 4)
            // Pause at the leading edge and at the end before restarting.
            offset = min(travel, CGFloat(max(0, elapsed - 2)) * 24)
        }
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(at: NSPoint(x: -offset, y: (bounds.height - height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { timer?.invalidate() }
}

private struct RunningAgentBadge: View {
    let agent: SavedNotionAgent?
    @State private var rotating = false

    var body: some View {
        ZStack {
            if let agent {
                NotionAgentAvatar(agent: agent, size: 16)
                Circle().trim(from: 0.08, to: 0.82)
                    .stroke(AngularGradient(colors: [NotionPanelTheme.blue.opacity(0.2), NotionPanelTheme.blue, .cyan], center: .center),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: rotating)
            }
        }
        .frame(width: 24, height: 24)
        .onAppear { rotating = agent != nil }
        .onChange(of: agent?.id) { _, id in
            rotating = false
            if id != nil { DispatchQueue.main.async { rotating = true } }
        }
    }
}

private struct NotionNotificationBanner: View {
    let agent: SavedNotionAgent?
    let name: String
    let title: String
    let preview: String
    let deadline: Date
    let duration: Int
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let agent { NotionAgentAvatar(agent: agent, size: 32) }
            else {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NotionPanelTheme.blue)
                    .frame(width: 32, height: 32)
                    .background(NotionPanelTheme.blueWash, in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(NotionPanelTheme.blue)
                Text(preview.isEmpty ? title : preview)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let remaining = max(0, deadline.timeIntervalSince(context.date))
                ZStack {
                    Circle().stroke(NotionPanelTheme.hairline, lineWidth: 3)
                    Circle().trim(from: 0, to: min(1, remaining / Double(duration)))
                        .stroke(NotionPanelTheme.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(ceil(remaining)))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 33, height: 33)
                .accessibilityLabel("あと\(Int(ceil(remaining)))秒で閉じる")
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(NotionPanelTheme.ink)
        .background(NotionPanelTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NotionPanelTheme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onOpen)
    }
}

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
        if let table = firstResponder as? ShelfTilesView, event.modifierFlags.contains(.command),
           ["a", "c", "v", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            table.keyDown(with: event); return true
        }
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
    var onCalendarClick: (() -> Void)?
    var onFileDrag: (() -> Bool)?
    var onFileDrop: (([URL]) -> Bool)?
    let content = NSView()
    var contentSize: NSSize = .zero { didSet { positionContent() } }
    private var trackingArea: NSTrackingArea?

    /// Keep the existing wing width so the collapsed notch does not widen.
    static let wingWidth: CGFloat = 40
    static let helperHeight = CalendarHelperLayout.height
    private let calendarHelper = CalendarHelperView()
    private var showsCalendarHelper = false
    private var showsCalendarBadge = false
    private let badgeIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let agentBadge = NSHostingView(rootView: RunningAgentBadge(agent: nil))
    private var notificationBanner: NSHostingView<NotionNotificationBanner>?

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
            .withSymbolConfiguration(.init(pointSize: CalendarHelperLayout.primaryFontSize, weight: .semibold))
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: CalendarHelperLayout.primaryFontSize, weight: .semibold)
        badgeLabel.alignment = .center
        agentBadge.isHidden = true
        addSubview(agentBadge)
        calendarHelper.isHidden = true
        addSubview(calendarHelper)
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

    /// Minutes until the next event, or nil to hide the calendar helper.
    func setBadge(event: CalendarBadge?, visible: Bool, marqueeEnabled: Bool = true) {
        let minutes = event?.minutes
        showsCalendarBadge = event != nil && visible
        showsCalendarHelper = showsCalendarBadge && marqueeEnabled
        calendarHelper.setText(event?.helperText ?? "", visible: showsCalendarHelper)
        if let minutes {
            badgeLabel.stringValue = "\(minutes)分"
            let tint: NSColor = minutes <= 5 ? .systemOrange : .white
            badgeLabel.textColor = tint
            badgeIcon.contentTintColor = tint
        }
        let alpha: CGFloat = minutes != nil && visible ? 1 : 0
        badgeIcon.alphaValue = alpha
        badgeLabel.alphaValue = alpha
        positionContent()
    }

    func setRunningAgent(_ agent: SavedNotionAgent?) {
        agentBadge.rootView = RunningAgentBadge(agent: agent)
        agentBadge.isHidden = agent == nil
    }

    func setNotification(agent: SavedNotionAgent?, name: String = "", title: String = "", preview: String = "",
                         deadline: Date = .now, duration: Int = 10, onOpen: @escaping () -> Void = {}) {
        notificationBanner?.removeFromSuperview()
        notificationBanner = nil
        guard agent != nil || !name.isEmpty else { return }
        let banner = NSHostingView(rootView: NotionNotificationBanner(agent: agent, name: agent?.name ?? name,
                                                                      title: title, preview: preview,
                                                                      deadline: deadline, duration: duration,
                                                                      onOpen: onOpen))
        banner.appearance = SettingsStore.shared.data.notionAppearance.resolvedAppearance
        addSubview(banner)
        notificationBanner = banner
        positionContent()
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if calendarHit(local) { return self }
        return super.hitTest(point)
    }

    private func calendarHit(_ point: NSPoint) -> Bool {
        showsCalendarBadge && (badgeIcon.frame.contains(point) || badgeLabel.frame.contains(point)
            || (showsCalendarHelper && calendarHelper.frame.contains(point)))
    }

    override func mouseDown(with event: NSEvent) {
        if calendarHit(convert(event.locationInWindow, from: nil)) { onCalendarClick?() }
        else { onClick?() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [ShelfDragMonitor.originType]) == nil,
              sender.draggingSourceOperationMask.contains(.copy),
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
        let helperHeight = showsCalendarHelper ? Self.helperHeight : 0
        let primaryHeight = bounds.height - helperHeight
        let inset = CalendarHelperLayout.horizontalInset
        let rowHeight = CalendarHelperLayout.rowHeight
        calendarHelper.frame = NSRect(x: inset, y: CalendarHelperLayout.bottomPadding,
                                      width: max(0, bounds.width - inset * 2), height: rowHeight)
        // Align both wings beside the physical notch, above the helper line.
        let topRowY = helperHeight + ((primaryHeight - rowHeight) / 2).rounded()
        badgeIcon.frame = NSRect(x: (Self.wingWidth - rowHeight) / 2, y: topRowY, width: rowHeight, height: rowHeight)
        badgeLabel.frame = NSRect(x: bounds.width - Self.wingWidth, y: topRowY, width: Self.wingWidth, height: rowHeight)
        agentBadge.frame = NSRect(x: 8, y: helperHeight + ((primaryHeight - 24) / 2).rounded(), width: 24, height: 24)
        content.frame = NSRect(
            x: ((bounds.width - contentSize.width) / 2).rounded(),
            y: bounds.height - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
        notificationBanner?.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16),
                                           height: max(0, bounds.height - 8 - min(bounds.height, 34)))
    }
}

/// One notch on one display. The single browser view moves to whichever notch expands.
final class NotchController: NSObject, NSWindowDelegate {
    private enum NoticeTarget {
        case agent(agentID: String, threadID: String)
        case database(URL?)
    }
    let panel: NotchPanel
    let root = NotchRootView()
    private(set) var screen: NSScreen
    private unowned let manager: NotchManager
    private(set) var isExpanded = false
    private var hoverTimer: Timer?
    private var notificationDismissTimer: Timer?
    private var notification: NoticeTarget?
    private let transition = NotchTransition()
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
        root.onCalendarClick = { [weak self] in self?.manager.dismissCalendarEvent() }
        root.onClick = { [weak self] in
            guard let self else { return }
            if self.notification != nil { self.openNotificationChat() }
            else { self.expand(focus: true) }
        }
        root.onFileDrag = { [weak self] in
            guard let self, ShelfFeature.isAvailable,
                  SettingsStore.shared.data.shelfTrigger != .manual || self.shelfVisible else { return false }
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
        let quit = NSMenuItem(title: "NotchBrowser を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        let notion = NSMenuItem(title: "Notionエージェント", action: #selector(openNotionFromMenu), keyEquivalent: "")
        notion.target = self
        notion.image = NotionTabIcon.image(for: NSApp.effectiveAppearance, size: 16)
        menu.items = [open] + (SettingsStore.shared.data.notionEnabled ? [notion] : [])
            + [settings, .separator(), quit]
        return menu
    }

    func refreshNotionAvailability() {
        root.contextMenu = makeContextMenu()
        switch notification {
        case .agent where !SettingsStore.shared.data.notionEnabled,
             .database where !SettingsStore.shared.data.notionDatabaseNotificationsEnabled:
            clearNotification(animated: false)
        default: break
        }
    }

    @objc private func openNotionFromMenu() { manager.showNotion(on: self) }
    @objc private func openFromMenu() { expand(focus: true) }
    @objc private func openSettingsFromMenu() { manager.browser.onOpenSettings?() }

    func show() {
        relayout(animated: false)
        panel.orderFrontRegardless()
    }

    func close() {
        transition.cancel()
        hoverTimer?.invalidate()
        clearHoverSuppression()
        notificationDismissTimer?.invalidate()
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
        if shelfOnly { return NSSize(width: min(480, screen.frame.width - 40), height: manager.shelf.preferredShelfHeight + stripHeight) }
        let frame = screen.frame
        return NSSize(
            width: min(settings.width, frame.width - 40).rounded(),
            height: min(settings.height, frame.height - 40).rounded()
        )
    }

    private var collapsedFrame: NSRect {
        var size = notchSize
        size.height = stripHeight
        if manager.minutesToNextEvent != nil || !manager.notion.busyAgentIDs.isEmpty { size.width += NotchRootView.wingWidth * 2 }
        if manager.nextCalendarEvent != nil && SettingsStore.shared.data.calendarMarqueeEnabled {
            size.height += NotchRootView.helperHeight
        }
        return topCenteredFrame(size)
    }

    private var expandedFrame: NSRect { topCenteredFrame(expandedSize) }
    private var notificationFrame: NSRect {
        topCenteredFrame(NSSize(width: min(480, screen.frame.width - 40), height: stripHeight + 76))
    }

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
        root.setBadge(event: manager.nextCalendarEvent, visible: !isExpanded && notification == nil,
                      marqueeEnabled: SettingsStore.shared.data.calendarMarqueeEnabled)
        root.setRunningAgent(isExpanded || notification != nil ? nil : manager.runningAgent)
        animate(to: isExpanded ? expandedFrame : notification != nil ? notificationFrame : collapsedFrame,
                radius: isExpanded || notification != nil ? 18 : 10,
                contentAlpha: isExpanded ? 1 : 0, animated: animated)
    }

    // MARK: Expand / collapse

    private var hoverSuppressionRegion: NSRect?
    private var hoverExitTimer: Timer?
    private var explicitReturnOpen = false
    var hoverPointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    var deactivateAfterDetaching: () -> Void = { NSApp.deactivate() }

    func openFromHotKey(preservingContent: Bool = false, returningFromDetached: Bool = false) {
        clearHoverSuppression()
        // Release only activation inherited from the detached window. Ordinary
        // hotkey opens must not deactivate our settings or other app windows.
        if returningFromDetached { deactivateAfterDetaching(); explicitReturnOpen = true }
        expand(focus: true, preservingContent: preservingContent)
    }

    func expand(focus: Bool, preservingContent: Bool = false) {
        if manager.isDetached { manager.bringDetachedForward(); return }
        if shelfOnly { hideShelf() }
        if notification != nil {
            notification = nil
            notificationDismissTimer?.invalidate()
            notificationDismissTimer = nil
            root.setNotification(agent: nil)
        }
        hoverTimer?.invalidate()
        if !isExpanded {
            root.contentSize = expandedSize
            if !preservingContent {
                manager.browser.hideNotion()
                manager.browser.prepareForOpen()
            }
            manager.willExpand(self)
            isExpanded = true
            if ShelfFeature.isAvailable && !manager.shelf.store.entries.isEmpty { manager.showShelf(on: self) }
            panel.hasShadow = true
            root.setBadge(event: manager.nextCalendarEvent, visible: false)
            root.setRunningAgent(nil)
            animate(to: expandedFrame, radius: 18, contentAlpha: 1)
        }
        manager.browser.revealSelectedTabAfterNotchLayout()
        if focus {
            panel.makeKey()
            manager.browser.focusContent()
        }
    }

    func collapse(animated: Bool = true, preservingShelf: Bool = true) {
        hoverTimer?.invalidate()
        explicitReturnOpen = false
        guard isExpanded else { return }
        if !manager.isDetached { manager.browser.hideNotion() }
        if preservingShelf && shelfVisible && !manager.shelf.store.entries.isEmpty {
            shelfOnly = true
            if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
            relayout(animated: animated)
            return
        }
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
        root.setBadge(event: manager.nextCalendarEvent, visible: true,
                      marqueeEnabled: SettingsStore.shared.data.calendarMarqueeEnabled)
        root.setRunningAgent(manager.runningAgent)
        animate(to: collapsedFrame, radius: 10, contentAlpha: 0, animated: animated)
        manager.didCollapse()
    }

    func showNotification(agentID: String, threadID: String, title: String, preview: String) {
        guard SettingsStore.shared.data.notionEnabled else { return }
        guard let agent = manager.notion.visibleAgents.first(where: { $0.id == agentID }) else { return }
        guard !isExpanded else { return }
        let duration = SettingsStore.shared.data.notionNotificationDuration
        let deadline = Date().addingTimeInterval(TimeInterval(duration))
        notification = .agent(agentID: agentID, threadID: threadID)
        root.setNotification(agent: agent, title: title, preview: preview,
                             deadline: deadline, duration: duration,
                             onOpen: { [weak self] in self?.openNotificationChat() })
        notificationDismissTimer?.invalidate()
        notificationDismissTimer = .scheduledTimer(withTimeInterval: TimeInterval(duration), repeats: false) { [weak self] _ in
            self?.clearNotification(animated: true)
        }
        relayout()
        panel.orderFrontRegardless()
    }

    func showDatabaseNotification(_ notice: NotionDatabaseNotice) {
        guard SettingsStore.shared.data.notionDatabaseNotificationsEnabled, !isExpanded else { return }
        let duration = SettingsStore.shared.data.notionDatabaseNotificationDuration
        notification = .database(notice.pageURL)
        root.setNotification(agent: nil, name: notice.databaseName,
                             title: notice.propertyName, preview: notice.preview,
                             deadline: Date().addingTimeInterval(TimeInterval(duration)), duration: duration,
                             onOpen: { [weak self] in self?.openNotificationChat() })
        notificationDismissTimer?.invalidate()
        notificationDismissTimer = .scheduledTimer(withTimeInterval: TimeInterval(duration), repeats: false) { [weak self] _ in
            self?.clearNotification(animated: true)
        }
        relayout()
        panel.orderFrontRegardless()
    }

    private func clearNotification(animated: Bool) {
        guard notification != nil else { return }
        notification = nil
        notificationDismissTimer?.invalidate()
        notificationDismissTimer = nil
        root.setNotification(agent: nil)
        relayout(animated: animated)
    }

    private func openNotificationChat() {
        guard let notice = notification else { return }
        switch notice {
        case .agent(let agentID, let threadID):
            manager.notion.openThread(agentID: agentID, threadID: threadID)
            manager.showNotion(on: self, focus: true)
        case .database(let url):
            clearNotification(animated: true)
            if let url { NSWorkspace.shared.open(url) }
        }
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
        relayout(animated: true)
        panel.orderFrontRegardless()
    }

    func hideShelf() {
        guard shelfVisible else { return }
        let wasOnly = shelfOnly
        shelfVisible = false
        shelfOnly = false
        manager.shelf.view.removeFromSuperview()
        if wasOnly { collapse() }
        else { relayout(animated: true) }
    }

    func layoutContent() {
        let bounds = root.content.bounds
        let shelfHeight: CGFloat = shelfVisible ? (shelfOnly ? max(0, bounds.height - stripHeight) : manager.shelf.preferredShelfHeight) : 0
        if manager.shelf.view.superview === root.content {
            manager.shelf.view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: shelfHeight)
        }
        if manager.browser.view.superview === root.content {
            manager.browser.view.isHidden = shelfOnly
            manager.browser.view.frame = NSRect(x: 0, y: shelfHeight, width: bounds.width, height: max(0, bounds.height - shelfHeight))
        }
    }

    private func animate(to frame: NSRect, radius: CGFloat, contentAlpha: CGFloat, animated: Bool = true) {
        let opening = isExpanded || notification != nil
        let windowAlpha = opening ? 1 : idleOpacity
        let motion = SettingsStore.shared.data.motion
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = !animated || motion.style == .none || reduced ? 0 : (opening ? motion.openDuration : motion.closeDuration)
        let startFrame = panel.frame
        let startAlpha = panel.alphaValue
        let startContent = root.content.alphaValue
        let startRadius = root.cornerRadius
        transition.run(duration: duration) { [weak self] progress in
            guard let self else { return }
            let shape = CGFloat(NotchMotionTiming.shape(progress, style: motion.style, opening: opening))
            let content = CGFloat(NotchMotionTiming.content(progress, opening: opening))
            func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.panel.setFrame(NSRect(x: mix(startFrame.minX, frame.minX, shape),
                y: mix(startFrame.minY, frame.minY, shape),
                width: mix(startFrame.width, frame.width, shape),
                height: mix(startFrame.height, frame.height, shape)), display: true)
            self.panel.alphaValue = mix(startAlpha, windowAlpha, shape)
            self.root.cornerRadius = mix(startRadius, radius, shape)
            self.root.content.alphaValue = mix(startContent, contentAlpha, content)
            CATransaction.commit()
            if progress >= 1, self.isExpanded, !self.manager.isDetached { self.manager.browser.revealSelectedTabAfterNotchLayout() }
        }
    }

    /// Leaving closes after the configured delay, even after clicking or typing.
    /// Explicit returns remain open until explicitly closed; ordinary hover keeps its delays.
    private func hoverChanged(_ inside: Bool) {
        pointerInside = inside
        if hoverSuppressionRegion != nil {
            // The frozen expanded region does not shrink with the animation.
            // Tracking-area exit/entry pairs alone cannot rearm hover.
            rearmHoverAfterPhysicalExit()
            return
        }
        if explicitReturnOpen { return }
        if manager.isDetached {
            hoverTimer?.invalidate()
            if inside { manager.bringDetachedForward() }
            return
        }
        hoverTimer?.invalidate()
        hoverTimer = nil
        let motion = SettingsStore.shared.data.motion
        guard !manager.dragActive else { return }
        if inside {
            if case .agent = notification { openNotificationChat(); return }
            if notification != nil { return }
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
        guard !manager.keepOpen, !manager.isShowingModal, !manager.dragActive,
              !shelfVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        // Preserve the timer already started by mouseExited instead of closing early.
        if hoverTimer?.isValid != true { hoverChanged(false) }
    }

    func closeFromHotKey(animated: Bool = true) {
        explicitReturnOpen = false
        clearHoverSuppression()
        hoverSuppressionRegion = panel.frame.union(expandedFrame).union(collapsedFrame)
        // After collapse the pointer can leave the old expanded region without
        // crossing a live tracking area. Poll only while hover is suppressed.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.rearmHoverAfterPhysicalExit()
        }
        hoverExitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        collapse(animated: animated, preservingShelf: false)
    }

    private func rearmHoverAfterPhysicalExit() {
        guard let region = hoverSuppressionRegion, !region.contains(hoverPointerLocation()) else { return }
        clearHoverSuppression()
    }

    private func clearHoverSuppression() {
        hoverSuppressionRegion = nil
        hoverExitTimer?.invalidate()
        hoverExitTimer = nil
    }

    func resumeHoverCloseIfNeeded() {
        if isExpanded, !pointerInside { hoverChanged(false) }
    }
}

/// Owns the browser and one notch per enabled display.
final class NotchManager: NSObject, NSWindowDelegate {
    private var tabTransfers: Set<ObjectIdentifier> = []
    private(set) var detachedTabs: [DetachedTabWindowController] = []
    private var detachedWindow: NSWindow?
    private var normalFrameState: DetachedNormalFrameState?
    private var contentTransferInProgress = false
    private var returningFromFullScreen = false
    private var fullScreenTransition = false
    private var returnDisplayID: String?
    var isDetached: Bool { detachedWindow != nil }
    let browser = BrowserViewController()
    let shelf: ShelfViewController
    let notion = NotionAgentsStore.shared
    let databaseMonitor = NotionDatabaseMonitor.shared
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
    private var calendarPresentation = CalendarBadgePresentation()
    var nextCalendarEvent: CalendarBadge? {
        SettingsStore.shared.data.countdownEnabled ? calendarPresentation.visible : nil
    }
    var minutesToNextEvent: Int? { nextCalendarEvent?.minutes }
    var isShowingModal = false

    func dismissCalendarEvent() {
        calendarPresentation.dismiss()
        controllers.values.forEach { $0.relayout() }
    }

    var keepOpen = false {
        didSet {
            browser.keepOpen = keepOpen
            if !keepOpen { controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
        }
    }

    init(shelfStore: ShelfStore = .shared) {
        shelf = ShelfViewController(store: shelfStore)
        super.init()
        browser.onDetachTab = { [weak self] tab, point in self?.detachTab(tab, at: point) }
        browser.onToggleDetached = { [weak self] in self?.toggleDetached() }
        browser.onOpenShelf = { [weak self] in self?.showShelf() }
        browser.onExternalTabOpened = { [weak self] in
            guard let self else { return }
            self.controllers.values.first(where: { $0.isExpanded && self.browser.view.superview === $0.root.content })?
                .collapse(preservingShelf: false)
        }
        shelf.onClose = { [weak self] in self?.controllers.values.filter(\.shelfVisible).forEach { $0.hideShelf() } }
        shelf.onSizeChange = { [weak self] in self?.controllers.values.filter(\.shelfVisible).forEach { $0.relayout(animated: false) } }
        shelf.onDrop = { [weak self] in self?.shelfDropReceived = true }
        shelf.onDrag = { [weak self] active in
            self?.shelfDragOutgoing = active
            self?.dragActive = active
        }
        shelf.store.$entries.receive(on: RunLoop.main).sink { [weak self] entries in
            guard let self else { return }
            if ShelfFeature.isAvailable && !entries.isEmpty && !self.controllers.values.contains(where: \.shelfVisible) { self.showShelf() }
            if entries.isEmpty { self.controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
        }.store(in: &cancellables)
        dragMonitor.onChange = { [weak self] active in self?.dragChanged(active) }
        browser.onToggleKeepOpen = { [weak self] in self?.keepOpen.toggle() }
        browser.onModalChange = { [weak self] showing in
            self?.isShowingModal = showing
            if !showing { self?.controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
        }
        calendar.onChange = { [weak self] event in
            self?.calendarPresentation.update(event)
            self?.controllers.values.forEach { $0.relayout() }
        }
        notion.$busyAgentIDs.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.controllers.values.forEach { $0.relayout() }
        }.store(in: &cancellables)
        notion.$alert.receive(on: RunLoop.main).sink { [weak self] notice in
            guard let self, let notice else { return }
            let target = self.orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) }
                ?? self.orderedControllers.first
            target?.showNotification(agentID: notice.agentID, threadID: notice.threadID,
                                     title: notice.title, preview: notice.preview)
            Task { @MainActor in
                self.notion.clearAlert()
            }
        }.store(in: &cancellables)
        databaseMonitor.$latestNotice.receive(on: RunLoop.main).sink { [weak self] notice in
            guard let self, let notice else { return }
            let target = self.orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) }
                ?? self.orderedControllers.first
            target?.showDatabaseNotification(notice)
            self.databaseMonitor.clearNotice()
        }.store(in: &cancellables)

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
        browser.view.alphaValue = 1
        applyCalendarSettings()
        rebuild()
        applyWindowSettings()
        calendar.start()
        notion.start()
        databaseMonitor.start()
        if ShelfFeature.isAvailable { dragMonitor.start() }
    }

    private func settingsChanged() {
        notion.settingsChanged()
        databaseMonitor.settingsChanged()
        applyCalendarSettings()
        rebuild()
        applyWindowSettings()
        shelf.settingsChanged()
        browser.settingsChanged()
        for controller in detachedTabs {
            controller.browser.settingsChanged()
            controller.window?.sharingType = SettingsStore.shared.data.hideFromScreenCapture ? .none : .readOnly
        }
        controllers.values.forEach { $0.refreshNotionAvailability() }
    }

    private func applyWindowSettings() {
        controllers.values.forEach { $0.applyScreenCaptureSetting() }
        detachedWindow?.sharingType = SettingsStore.shared.data.hideFromScreenCapture ? .none : .readOnly
        browser.hideFromScreenCapture = SettingsStore.shared.data.hideFromScreenCapture
    }

    private func applyCalendarSettings() {
        let data = SettingsStore.shared.data
        calendar.isEnabled = data.countdownEnabled
        calendar.thresholdMinutes = data.countdownMinutes
        calendar.longEventLimit = data.calendarLongEventLimit
    }

    /// Syncs notch windows with connected displays and their settings.
    func rebuild() {
        let store = SettingsStore.shared
        let enabled = NSScreen.screens.filter { store.displaySettings(for: $0).enabled }
        let ids = Set(enabled.map(\.displayUUID))

        for (id, controller) in controllers where !ids.contains(id) {
            controller.collapse(animated: false, preservingShelf: false)
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
        if ShelfFeature.isAvailable && !shelf.store.entries.isEmpty && !controllers.values.contains(where: \.shelfVisible) { showShelf() }
    }

    private var orderedControllers: [NotchController] {
        NSScreen.screens.compactMap { controllers[$0.displayUUID] }
    }

    func willExpand(_ controller: NotchController) {
        for other in controllers.values where other !== controller && other.isExpanded {
            other.collapse(animated: false, preservingShelf: false)
        }
        attachBrowser(to: controller)
        launcherWatcher.start()
    }

    func didCollapse() {
        guard !controllers.values.contains(where: \.isExpanded) else { return }
        launcherWatcher.stop()
    }

    private func attachBrowser(to controller: NotchController) {
        guard !isDetached else { return }
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
        guard ShelfFeature.isAvailable else { return }
        let target = target ?? orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? orderedControllers.first
        guard let target else { return }
        for other in controllers.values where other !== target && other.shelfVisible { other.hideShelf() }
        target.showShelf()
    }

    var runningAgent: SavedNotionAgent? {
        notion.visibleAgents.first(where: { notion.busyAgentIDs.contains($0.id) })
    }

    func showNotion(on target: NotchController? = nil, focus: Bool = true) {
        guard SettingsStore.shared.data.notionEnabled else { return }
        let target = target ?? orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? orderedControllers.first
        guard let target else { return }
        target.expand(focus: focus)
        browser.showNotion()
        if !isDetached { target.panel.orderFrontRegardless() }
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
                if !self.shelfDropReceived && self.shelf.store.entries.isEmpty { self.automaticShelf?.hideShelf() }
                self.automaticShelf = nil
                if !self.shelfDropReceived { self.controllers.values.forEach { $0.resumeHoverCloseIfNeeded() } }
            }
            dragFinishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func bringDetachedForward() {
        guard let window = detachedWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func toggleDetached() {
        guard tabTransfers.isEmpty else { return }
        guard !contentTransferInProgress else { return }
        if let window = detachedWindow {
            guard !returningFromFullScreen else { return }
            if fullScreenTransition || window.styleMask.contains(.fullScreen) {
                returningFromFullScreen = true
                if !fullScreenTransition { window.toggleFullScreen(nil) }
            } else { returnToNotch() }
            return
        }
        contentTransferInProgress = true
        browser.preservingPagePosition(move: { [weak self] in
            self?.detachBrowser()
        }, completion: { [weak self] in
            self?.contentTransferInProgress = false
        })
    }

    func detachTab(_ tab: Tab, at point: NSPoint? = nil) {
        guard tab.pinnedID == nil, !contentTransferInProgress else { return }
        transferTab(tab) { [weak self] in
            guard let self, let moved = self.browser.takeTab(tab) else { return false }
            if point != nil {
                // A normal-level tab window would otherwise sit behind the
                // pop-up-level notch throughout the drag. Collapse immediately
                // and hold hover off before displaying the final tab window.
                for controller in self.controllers.values where controller.isExpanded {
                    controller.closeFromHotKey(animated: false)
                }
            }
            self.openTabWindow(moved, at: point)
            return true
        }
    }

    /// Capture scroll/selection before reparenting; timeouts keep a busy page from blocking UI.
    private func transferTab(_ tab: Tab, move: @escaping () -> Bool) {
        let id = ObjectIdentifier(tab)
        guard tabTransfers.insert(id).inserted else { return }
        let web = tab.webView
        let nativeFocus = WebTransferResponderState(webView: web, sourceWindow: web.window, fallbackToContent: true)
        let gate = WebTransferCompletionGate()
        let proceed = { [weak self] in
            gate.run {
                guard let self else { return }
                guard tab.webView === web, move() else { self.tabTransfers.remove(id); return }
                web.window?.contentView?.layoutSubtreeIfNeeded()
                let restoreFocus = nativeFocus.restore(to: web.window, contentVisible: !web.isHidden)
                guard web.url != nil else { self.tabTransfers.remove(id); return }
                let finished = WebTransferCompletionGate()
                let finish = { [weak self] in finished.run { self?.tabTransfers.remove(id) } }
                web.callAsyncJavaScript(WebViewTransferState.restore, arguments: ["restoreFocus": restoreFocus],
                                       in: nil, in: .defaultClient) { _ in finish() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: finish)
            }
        }
        guard web.url != nil else { proceed(); return }
        web.evaluateJavaScript(WebViewTransferState.capture, in: nil, in: .defaultClient) { _ in proceed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: proceed)
    }

    private func openTabWindow(_ moved: Tab, at point: NSPoint? = nil) {
        let controller = DetachedTabWindowController(tab: moved)
        detachedTabs.append(controller)
        controller.browser.onCreateTabWindow = { [weak self] tab in self?.openTabWindow(tab) }
        controller.browser.onNewTabInNotch = { [weak self] in
            guard let self else { return }
            self.browser.newTab(nil)
            if self.isDetached { self.toggleDetached() }
            else {
                let target = self.orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? self.orderedControllers.first
                target?.openFromHotKey(preservingContent: true, returningFromDetached: true)
            }
        }
        controller.browser.onOpenSettings = browser.onOpenSettings
        controller.browser.onModalChange = browser.onModalChange
        controller.onReturn = { [weak self, weak controller] in
            guard let self, let controller, let tab = controller.browser.currentTab,
                  !self.contentTransferInProgress else { return }
            self.transferTab(tab) { [weak self, weak controller] in
                guard let self, let controller, let moved = controller.browser.takeTab(tab) else { return false }
                self.browser.receiveTab(moved)
                controller.window?.close()
                if self.isDetached { self.bringDetachedForward() }
                else {
                    let target = self.orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? self.orderedControllers.first
                    target?.openFromHotKey(preservingContent: true, returningFromDetached: true)
                }
                return true
            }
        }
        controller.onClosed = { [weak self, weak controller] in
            self?.detachedTabs.removeAll { $0 === controller }
        }
        controller.present(at: point)
    }

    private func detachBrowser() {
        let source = orderedControllers.first { browser.view.superview === $0.root.content }
            ?? orderedControllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) }
            ?? orderedControllers.first
        returnDisplayID = source?.screen.displayUUID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "NotchBrowser"
        window.isMovableByWindowBackground = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: DetachedToolbarLayout.minimumWidth(trafficInset: trafficLightInset(for: window)), height: 320)
        window.appearance = NSAppearance(named: .darkAqua)
        window.sharingType = SettingsStore.shared.data.hideFromScreenCapture ? .none : .readOnly
        window.center()
        let saved = UserDefaults.standard.string(forKey: "detachedBrowserFrame")
        let frame = saved.map(NSRectFromString)
            ?? NSRect(x: window.frame.midX - 500, y: window.frame.midY - 350, width: 1000, height: 700)
        detachedWindow = window
        controllers.values.forEach { $0.collapse(animated: false, preservingShelf: false) }
        browser.view.removeFromSuperview()
        browser.view.isHidden = false
        browser.view.autoresizingMask = [.width, .height]
        window.contentViewController = browser
        browser.isDetached = true
        updateDetachedTitlebar()
        let restored = DetachedWindowGeometry.constrain(frame, screens: NSScreen.screens.map(\.visibleFrame),
                                                        primary: (NSScreen.screens.first?.visibleFrame ?? window.frame),
                                                        minimumSize: window.minSize)
        // Apply outer frame after AppKit's initial presentation/placement, with delegate
        // disconnected so intermediate view-sized or cascaded frames cannot be saved.
        window.setFrame(restored, display: false)
        bringDetachedForward()
        window.setFrame(restored, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        updateDetachedTitlebar()
        window.delegate = self
        normalFrameState = DetachedNormalFrameState(frame: restored)
        saveDetachedFrame()
    }

    private func trafficLightInset(for window: NSWindow) -> CGFloat {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let content = window.contentView else { return 80 }
        return buttons.map { $0.convert($0.bounds, to: content).maxX }.max().map { $0 + 12 } ?? 80
    }

    private func updateDetachedTitlebar() {
        guard let window = detachedWindow, let content = window.contentView else { return }
        let fullscreen = window.styleMask.contains(.fullScreen)
        let inset = fullscreen ? CGFloat(14) : trafficLightInset(for: window)
        if !fullscreen {
            let minimum = DetachedToolbarLayout.minimumWidth(trafficInset: inset)
            if window.minSize.width != minimum { window.minSize = NSSize(width: minimum, height: 320) }
        }
        let button = window.standardWindowButton(.closeButton)
        let buttonFrame = button.map { $0.convert($0.bounds, to: content) }
        let height = fullscreen ? CGFloat(36) : max(28, buttonFrame.map { 2 * (content.bounds.maxY - $0.midY) } ?? 28)
        browser.updateDetachedMetrics(trafficInset: inset, rowHeight: height)
    }

    private func saveDetachedFrame() {
        guard let window = detachedWindow, !fullScreenTransition,
              !window.styleMask.contains(.fullScreen), !returningFromFullScreen else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? window.frame
        let normal = normalFrameState?.observe(frame: window.frame, visibleFrame: visible, isZoomed: window.isZoomed)
            ?? window.frame
        UserDefaults.standard.set(NSStringFromRect(normal), forKey: "detachedBrowserFrame")
    }

    private func returnToNotch() {
        guard !contentTransferInProgress else { return }
        contentTransferInProgress = true
        browser.preservingPagePosition(move: { [weak self] in
            self?.restoreBrowserToNotch()
        }, completion: { [weak self] in
            self?.contentTransferInProgress = false
        })
    }

    private func restoreBrowserToNotch() {
        guard let window = detachedWindow,
              let target = returnDisplayID.flatMap({ controllers[$0] }) ?? orderedControllers.first else {
            returningFromFullScreen = false
            return
        }
        saveDetachedFrame()
        window.delegate = nil
        window.contentViewController = nil
        browser.view.removeFromSuperview()
        window.orderOut(nil)
        detachedWindow = nil
        returningFromFullScreen = false
        browser.isDetached = false
        target.openFromHotKey(preservingContent: true, returningFromDetached: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        toggleDetached()
        return false
    }

    func windowDidMove(_ notification: Notification) { saveDetachedFrame() }
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        let visible = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? newFrame
        normalFrameState?.beginZoom(frame: window.frame, target: newFrame, visibleFrame: visible, isZoomed: window.isZoomed)
        saveDetachedFrame()
        return true
    }
    func windowDidResize(_ notification: Notification) {
        updateDetachedTitlebar()
        saveDetachedFrame()
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        saveDetachedFrame()
        fullScreenTransition = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        updateDetachedTitlebar()
        if returningFromFullScreen { detachedWindow?.toggleFullScreen(nil) }
    }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        updateDetachedTitlebar()
        if returningFromFullScreen { returnToNotch() }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = false
        if returningFromFullScreen { returnToNotch() }
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransition = false
        returningFromFullScreen = false
    }

    /// Hotkey: collapse if focused, otherwise open on the display under the pointer.
    func toggle() {
        if isDetached { bringDetachedForward(); return }
        if let open = controllers.values.first(where: \.isExpanded) {
            open.closeFromHotKey()
            return
        }
        let mouse = NSEvent.mouseLocation
        let target = orderedControllers.first { $0.screen.frame.contains(mouse) } ?? orderedControllers.first
        target?.openFromHotKey()
    }
}
