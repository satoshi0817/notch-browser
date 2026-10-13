import AppKit
import WebKit
import SwiftUI
import Combine

private final class LinkMenuMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserViewController?
    init(owner: BrowserViewController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        (message.webView?.uiDelegate as? BrowserViewController ?? owner)?.showLinkMenu(for: message)
    }
}

private final class LinkMenuContext: NSObject {
    let url: URL
    weak var opener: Tab?
    init(url: URL, opener: Tab?) { self.url = url; self.opener = opener }
}

final class Tab {
    /// Set when the tab is pinned; its name, icon and profile come from settings.
    var pinnedID: UUID?
    var profileID: UUID
    /// The pinned URL last loaded, to notice when it's edited in settings.
    var homeURL: String?
    private(set) var webView: WKWebView
    var observations: [NSKeyValueObservation] = []
    var refreshTimer: Timer?
    var refreshInterval: TimeInterval = 0
    deinit { refreshTimer?.invalidate() }

    init(pinnedID: UUID?, profileID: UUID, webView: WKWebView) {
        self.pinnedID = pinnedID
        self.profileID = profileID
        self.webView = webView
    }

    var pinned: PinnedTab? { pinnedID.flatMap { SettingsStore.shared.pinnedTab($0) } }

    var displayName: String {
        if let pinned { return pinned.name }
        if let title = webView.title, !title.isEmpty { return title }
        return webView.url?.host() ?? "新規タブ"
    }

    func icon(grayscale: Bool) -> NSImage {
        TabIconRenderer.image(for: pinned?.icon ?? .favicon, hosts: [webView.url?.host(), pinned?.host], grayscale: grayscale)
    }

    func replaceWebView(_ newWebView: WKWebView) {
        webView = newWebView
    }
}

final class BrowserViewController: NSViewController {
    var onToggleDetached: (() -> Void)?
    var onDetachTab: ((Tab, NSPoint?) -> Void)?
    var onCreateTabWindow: ((Tab) -> Void)?
    var onNewTabInNotch: (() -> Void)?
    var onReturnTab: (() -> Void)?
    var onPageTitleChanged: ((String) -> Void)?
    var onSingleTabClosed: (() -> Void)?
    var isSingleTabWindow = false
    var tabCount: Int { tabs.count }
    var currentTab: Tab? { selectedTab }

    func takeTab(_ tab: Tab) -> Tab? {
        guard tab.pinnedID == nil, let index = tabs.firstIndex(where: { $0 === tab }) else { return nil }
        let selected = selectedTab
        tabs.remove(at: index)
        tab.observations.removeAll()
        tab.webView.removeFromSuperview()
        select(selected === tab ? (tabs.isEmpty ? nil : min(index, tabs.count - 1)) : selected.flatMap { old in tabs.firstIndex { $0 === old } })
        return tab
    }

    func receiveTab(_ tab: Tab) {
        _ = view
        precondition(!isSingleTabWindow || tabs.isEmpty)
        tabs.append(tab)
        let controller = tab.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "notchBrowserLinkMenu")
        controller.add(LinkMenuMessageHandler(owner: self), name: "notchBrowserLinkMenu")
        linkMenuControllers.add(controller)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        install(tab)
        select(tab)
    }

    @objc func detachCurrentTab(_ sender: Any?) {
        guard let tab = selectedTab, tab.pinnedID == nil, !isSingleTabWindow else { return }
        onDetachTab?(tab, nil)
    }

    @objc private func detachTabFromMenu(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), tabs[sender.tag].pinnedID == nil else { return }
        onDetachTab?(tabs[sender.tag], nil)
    }

    @objc private func returnSingleTab(_ sender: Any?) { onReturnTab?() }

    var isDetached = false { didSet {
        guard isViewLoaded else { return }
        detachButton.image = symbol(isDetached ? "arrow.down.backward" : "arrow.up.forward.app")
        detachButton.toolTip = isDetached ? "ノッチに戻す" : "ブラウザ全体をウインドウにする"
        detachButton.setAccessibilityLabel(detachButton.toolTip!)
        updateCompactControls()
        rebuildToolsMenu()
        rebuildTabButtons()
    } }
    var onToggleKeepOpen: (() -> Void)?
    var onModalChange: ((Bool) -> Void)?
    var onOpenShelf: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenNotionSettings: (() -> Void)?
    var onExternalTabOpened: (() -> Void)?
    var keepOpen = false { didSet { updateChrome() } }
    var hideFromScreenCapture = true

    private var preservingWebState = false
    private var detachedTrafficInset: CGFloat = 80
    private let titlebarDrag = BrowserTitlebarDragView()
    private var tabLeadingConstraint: NSLayoutConstraint!
    private var detachedTabTrailingConstraint: NSLayoutConstraint!
    private var detachedControlWidthConstraint: NSLayoutConstraint!
    private var notchStripHeight: CGFloat = 32
    private var tabs: [Tab] = []
    private var tabButtons: [TabButton] = []
    private var isDraggingTab = false
    private var selectedIndex: Int?
    private var selectedTab: Tab? { selectedIndex.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private let linkMenuControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var store: SettingsStore { .shared }

    private let glass = GlassSurface()
    private let tabScroll = NSScrollView()
    private let pinnedTabStack = NSStackView()
    private let tabStrip = BrowserTabStripView()
    private var pinnedTabWidth: NSLayoutConstraint!
    private var needsTabReveal = true
    private lazy var addTabButton = iconButton("plus", "新規タブ (⌘T)", #selector(newTab))
    private lazy var notionTabButton: TabButton = {
        let button = TabButton(title: "Notion", image: NotionTabIcon.image(for: NSApp.effectiveAppearance),
                               target: self, action: #selector(toggleNotion))
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageLeading
        button.contentTintColor = nil
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityLabel("Notionエージェント")
        button.toolTip = "Notionエージェント"
        button.onDragBegan = { [weak self] _ in self?.isDraggingTab = true }
        button.onDragEnded = { [weak self] button in self?.tabDragEnded(button) }
        return button
    }()
    private let tabStack = NSStackView()
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")
    private var findHeight: NSLayoutConstraint!
    private var findGeneration = 0
    private let notes = ScratchpadView()
    private var notionPanel: NSHostingView<NotionAgentsPanel>?
    private var meetingsPanel: NSHostingView<NotionMeetingsPanel>?
    private lazy var meetingsTabButton: TabButton = {
        let button = TabButton(title: "議事録", image: NSImage(systemSymbolName: "person.2", accessibilityDescription: "議事録") ?? NSImage(), target: self, action: #selector(showMeetings))
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.font = .systemFont(ofSize: 12)
        button.tag = -998
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("議事録")
        return button
    }()
    private var tasksPanel: NSHostingView<NotionTasksPanel>?
    var notionConnection = NotionConnectionStore.shared
    private var tasksSubscriptions = Set<AnyCancellable>()
    private lazy var tasksTabButton: TabButton = {
        let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "タスク") ?? NSImage()
        let button = TabButton(title: "タスク", image: image, target: self, action: #selector(showTasks))
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.font = .systemFont(ofSize: 12)
        button.tag = -999
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("タスク")
        button.onDragBegan = { [weak self] _ in self?.isDraggingTab = true }
        button.onDragEnded = { [weak self] button in
            button.alphaValue = 1
            self?.isDraggingTab = false
            self?.updateChrome()
        }
        return button
    }()
    private var systemAppearanceObserver: NSObjectProtocol?
    private let switcher = NSView()
    private let tabSearch = NSSearchField()
    private let switchResults = TopAlignedStackView()
    private var searchRow = 0
    private var startPage: NSHostingView<StartPage>?
    private var closedTabs = ClosedTabHistory()
    private lazy var toolsButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .recessed
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.toolTip = "ページの操作"
        button.setAccessibilityLabel("ページの操作")
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }()
    private let controlStack = NSStackView()
    private let defaultToolbarSpacer = NSView()
    private let placedToolbarSpacer = NSView()
    private var arrangedToolbarActions: [ToolbarAction] = []
    private let webContainer = NSView()
    private let addressField = NSTextField()
    private let addressPopover = NSPopover()
    private lazy var addressButton = iconButton("magnifyingglass", "URLを表示・検索 (⌘L)", #selector(focusAddressBar))
    private lazy var homeButton = iconButton("house", "設定したページに戻る", #selector(goHome))
    private lazy var backButton = iconButton("chevron.left", "戻る", #selector(goBack))
    private lazy var forwardButton = iconButton("chevron.right", "進む", #selector(goForward))
    private lazy var reloadButton = iconButton("arrow.clockwise", "再読み込み", #selector(reloadOrStop))
    private lazy var detachButton = iconButton("arrow.up.forward.app", "ブラウザ全体をウインドウにする", #selector(toggleDetached))
    private lazy var keepOpenButton = iconButton("pin", "開いたままにする", #selector(toggleKeepOpen))

    private lazy var toolbarButtons: [ToolbarAction: NSButton] = {
        var buttons: [ToolbarAction: NSButton] = [
            .back: backButton, .forward: forwardButton, .home: homeButton,
            .reload: reloadButton, .address: addressButton, .keepOpen: keepOpenButton
        ]
        let extras: [(ToolbarAction, String, Selector)] = [
            (.find, "magnifyingglass", #selector(showFind)),
            (.copyURL, "link", #selector(copyPageURL)),
            (.zoomIn, "plus.magnifyingglass", #selector(zoomIn)),
            (.zoomOut, "minus.magnifyingglass", #selector(zoomOut)),
            (.resetZoom, "arrow.up.left.and.arrow.down.right", #selector(resetZoom)),
            (.autoRefresh, "arrow.triangle.2.circlepath", #selector(showAutoRefresh)),
            (.restore, "arrow.uturn.backward", #selector(reopenClosedTab)),
            (.tabSearch, "square.stack", #selector(showTabSwitcher)),
            (.closeTab, "xmark", #selector(closeCurrentTab)),
            (.notes, "square.and.pencil", #selector(toggleNotes)),
            (.external, "safari", #selector(openExternally)),
            (.settings, "gearshape", #selector(openSettings)),
            (.quit, "power", #selector(quitApplication))
        ]
        for (action, icon, selector) in extras {
            buttons[action] = iconButton(icon, action.title, selector)
        }
        return buttons
    }()

    private var autoRefreshMenu = NSMenu()

    @objc private func showAutoRefresh() {
        guard let button = toolbarButtons[.autoRefresh] else { return }
        autoRefreshMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }

    private var tabTrailingConstraint: NSLayoutConstraint!
    private var controlLeadingConstraint: NSLayoutConstraint!
    private var stripHeightConstraints: [NSLayoutConstraint] = []

    /// Matches the installed Safari so sites like Slack don't reject us as outdated.
    static let userAgent: String = {
        let safariVersion = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }()

    override func loadView() {
        view = BrowserRootView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glass.topAnchor.constraint(equalTo: view.topAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let chrome = glass.content
        tabStack.orientation = .horizontal
        pinnedTabStack.alignment = .centerY
        tabStack.alignment = .centerY
        pinnedTabStack.orientation = .horizontal
        pinnedTabStack.spacing = 4
        pinnedTabStack.translatesAutoresizingMaskIntoConstraints = false
        pinnedTabStack.wantsLayer = true
        pinnedTabStack.layer?.masksToBounds = true
        tabStack.spacing = 4
        controlStack.orientation = .horizontal
        controlStack.spacing = 4
        addressField.placeholderString = "検索またはURLを入力"
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .small
        addressField.font = .systemFont(ofSize: 12)
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.setAccessibilityLabel("検索またはURL")
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.delegate = self
        let addressController = NSViewController()
        addressController.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 92))
        let label = NSTextField(labelWithString: "URLを入力、または検索")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        addressField.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addressController.view.addSubview(label)
        addressController.view.addSubview(addressField)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: addressController.view.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: addressController.view.topAnchor, constant: 14),
            addressField.leadingAnchor.constraint(equalTo: addressController.view.leadingAnchor, constant: 16),
            addressField.trailingAnchor.constraint(equalTo: addressController.view.trailingAnchor, constant: -16),
            addressField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            addressField.heightAnchor.constraint(equalToConstant: 28)
        ])
        addressPopover.contentViewController = addressController
        addressPopover.behavior = .transient
        addressPopover.animates = false
        addressPopover.delegate = self
        for action in ToolbarAction.allCases {
            if let button = toolbarButtons[action] { controlStack.addArrangedSubview(button) }
        }
        controlStack.addArrangedSubview(defaultToolbarSpacer)
        controlStack.addArrangedSubview(toolsButton)
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.contentView.drawsBackground = false
        tabScroll.documentView = tabStack
        tabStrip.fixed = pinnedTabStack
        tabStrip.scroll = tabScroll
        tabStrip.addSubview(pinnedTabStack)
        tabStrip.addSubview(tabScroll)
        // Width is budgeted separately, but the fixed stack must fill the same
        // row as the scrolling stack instead of adopting its intrinsic height.
        NSLayoutConstraint.activate([
            pinnedTabStack.topAnchor.constraint(equalTo: tabStrip.topAnchor),
            pinnedTabStack.bottomAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            pinnedTabStack.leadingAnchor.constraint(equalTo: tabStrip.leadingAnchor),
        ])
        webContainer.wantsLayer = true
        webContainer.layer?.cornerRadius = 10
        webContainer.layer?.masksToBounds = true
        webContainer.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        findBar.orientation = .horizontal
        findBar.spacing = 8
        findField.placeholderString = "ページ内を検索"
        findField.sendsWholeSearchString = true
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findNext)
        findField.setAccessibilityLabel("ページ内を検索")
        findStatus.font = .systemFont(ofSize: 11)
        findStatus.textColor = .secondaryLabelColor
        findBar.addArrangedSubview(findField)
        findBar.addArrangedSubview(findStatus)
        findBar.addArrangedSubview(iconButton("chevron.up", "前の一致 (⇧↩)", #selector(findPrevious)))
        findBar.addArrangedSubview(iconButton("chevron.down", "次の一致 (↩)", #selector(findNext)))
        findBar.addArrangedSubview(iconButton("xmark", "検索を閉じる", #selector(closeFind)))
        findBar.isHidden = true
        for sub in [tabStrip, addTabButton, controlStack, findBar, webContainer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(sub)
        }
        tabTrailingConstraint = addTabButton.trailingAnchor.constraint(equalTo: chrome.centerXAnchor, constant: -110)
        controlLeadingConstraint = controlStack.leadingAnchor.constraint(equalTo: chrome.centerXAnchor, constant: 110)
        tabLeadingConstraint = tabStrip.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 14)
        pinnedTabWidth = pinnedTabStack.widthAnchor.constraint(equalToConstant: 0)
        pinnedTabWidth.isActive = true
        detachedTabTrailingConstraint = addTabButton.trailingAnchor.constraint(equalTo: controlStack.leadingAnchor, constant: -DetachedToolbarLayout.tabControlGap)
        detachedControlWidthConstraint = controlStack.widthAnchor.constraint(equalToConstant: 0)
        overflowTabButton.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(overflowTabButton)
        NSLayoutConstraint.activate([
            overflowTabButton.widthAnchor.constraint(equalToConstant: 28),
            overflowTabButton.heightAnchor.constraint(equalToConstant: 28),
            overflowTabButton.centerYAnchor.constraint(equalTo: tabStrip.centerYAnchor)
        ])
        normalTabScrollTrailingConstraint = tabStrip.trailingAnchor.constraint(equalTo: addTabButton.leadingAnchor, constant: -4)
        overflowTabConstraints = [
            tabStrip.trailingAnchor.constraint(equalTo: overflowTabButton.leadingAnchor, constant: -4),
            addTabButton.leadingAnchor.constraint(equalTo: overflowTabButton.trailingAnchor, constant: 4)
        ]
        overflowTabLeadingConstraint = overflowTabButton.leadingAnchor.constraint(equalTo: tabStrip.leadingAnchor)
        overflowControlGapConstraint = addTabButton.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -8)
        let tabHeight = tabStrip.heightAnchor.constraint(equalToConstant: 32)
        let controlHeight = controlStack.heightAnchor.constraint(equalToConstant: 32)
        stripHeightConstraints = [tabHeight, controlHeight]
        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: chrome.topAnchor),
            tabLeadingConstraint,
            tabTrailingConstraint, tabHeight,
            normalTabScrollTrailingConstraint,
            addTabButton.centerYAnchor.constraint(equalTo: tabStrip.centerYAnchor),
            controlStack.topAnchor.constraint(equalTo: chrome.topAnchor),
            controlStack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -12),
            controlLeadingConstraint, controlHeight,
            findBar.topAnchor.constraint(equalTo: controlStack.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 14),
            findBar.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -14), findHeight,
            webContainer.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 8),
            webContainer.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -8),
            webContainer.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -8)
        ])
        titlebarDrag.isHidden = true
        titlebarDrag.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(titlebarDrag)
        NSLayoutConstraint.activate([
            titlebarDrag.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            titlebarDrag.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            titlebarDrag.topAnchor.constraint(equalTo: chrome.topAnchor),
            titlebarDrag.heightAnchor.constraint(equalTo: controlStack.heightAnchor)
        ])
        configureSwitcher(in: chrome)
        notes.isHidden = true
        notes.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(notes)
        NSLayoutConstraint.activate([
            notes.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -18),
            notes.topAnchor.constraint(equalTo: controlStack.bottomAnchor, constant: 10),
            notes.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -18),
            notes.widthAnchor.constraint(equalToConstant: 320)
        ])
        notes.onClose = { [weak self] in self?.notes.isHidden = true; self?.focusContent() }
        notes.pageLink = { [weak self] in
            guard let tab = self?.selectedTab, let url = tab.webView.url else { return nil }
            return (tab.displayName, url)
        }
        let notion = NSHostingView(rootView: NotionAgentsPanel(onOpenSettings: { [weak self] in
            if let openNotion = self?.onOpenNotionSettings { openNotion() }
            else { self?.onOpenSettings?() }
        }))
        notion.isHidden = true
        notion.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(notion)
        NSLayoutConstraint.activate([
            notion.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            notion.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            notion.topAnchor.constraint(equalTo: webContainer.topAnchor),
            notion.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        notionPanel = notion
        let tasks = NSHostingView(rootView: NotionTasksPanel(onOpenSettings: { [weak self] in self?.onOpenNotionSettings?() }))
        tasks.isHidden = true
        tasks.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(tasks)
        NSLayoutConstraint.activate([
            tasks.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            tasks.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            tasks.topAnchor.constraint(equalTo: webContainer.topAnchor),
            tasks.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        tasksPanel = tasks
        let meetings = NSHostingView(rootView: NotionMeetingsPanel(onOpenSettings: { [weak self] in self?.onOpenNotionSettings?() }))
        meetings.isHidden = true
        meetings.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(meetings)
        NSLayoutConstraint.activate([
            meetings.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            meetings.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            meetings.topAnchor.constraint(equalTo: webContainer.topAnchor),
            meetings.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        meetingsPanel = meetings
        NotionTasksStore.shared.$configuration.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshTasksAvailability()
        }.store(in: &tasksSubscriptions)
        notionConnection.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshTasksAvailability()
        }.store(in: &tasksSubscriptions)
        updateNotionAppearance()
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateNotionAppearance()
            self?.updateChrome()
        }
        syncPinnedTabs()
        selectInitialTab()
        refreshTasksAvailability()
    }

    /// Preserve the original single strip, with the camera cutout between tabs and navigation.
    func updateNotchMetrics(notchWidth: CGFloat, stripHeight: CGFloat) {
        _ = view
        notchStripHeight = stripHeight
        let gap = notchWidth / 2 + 12
        tabTrailingConstraint.constant = -gap
        controlLeadingConstraint.constant = gap
        for constraint in stripHeightConstraints { constraint.constant = stripHeight }
        needsTabReveal = true
        view.needsUpdateConstraints = true
        view.needsLayout = true
        updateCompactControls()
        tabStack.setFrameSize(NSSize(width: tabStack.frame.width, height: stripHeight))
    }

    func updateDetachedMetrics(trafficInset: CGFloat, rowHeight: CGFloat) {
        // This scroll view intentionally lives inside the full-size titlebar.
        // Automatic safe-area insets would subtract that same titlebar from its
        // 28pt row, leaving a zero-height clip view and unreachable tab controls.
        tabStack.spacing = 2
        tabStack.detachesHiddenViews = true
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.contentInsets = NSEdgeInsetsZero
        detachedTrafficInset = trafficInset
        tabTrailingConstraint.isActive = false
        controlLeadingConstraint.isActive = false
        detachedTabTrailingConstraint.isActive = true
        detachedControlWidthConstraint.isActive = true
        tabLeadingConstraint.constant = trafficInset
        for constraint in stripHeightConstraints { constraint.constant = rowHeight }
        titlebarDrag.isHidden = false
        tabStack.setFrameSize(NSSize(width: tabStack.frame.width, height: rowHeight))
        updateCompactControls()
    }

    private func restoreNotchMetrics() {
        overflowTabLeadingConstraint.isActive = false
        NSLayoutConstraint.deactivate(overflowTabConstraints)
        normalTabScrollTrailingConstraint.isActive = true
        overflowTabButton.isHidden = true
        overflowControlGapConstraint.isActive = false
        tabStack.spacing = 4
        tabScroll.automaticallyAdjustsContentInsets = true
        // Hidden arranged views may be detached from NSStackView. Restore the
        // saved complete order, not only the currently attached visible slots.
        if !detachedTabViews.isEmpty {
            tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for item in detachedTabViews {
                item.isHidden = false
                item.constraints.filter { $0.identifier == "detached-tab-divider" }.forEach { $0.isActive = false }
                tabStack.addArrangedSubview(item)
            }
        }
        detachedTabViews = []
        lastDetachedSettle = nil
        lastDetachedRebuild = nil
        for case let button as TabButton in tabStack.arrangedSubviews {
            button.isHidden = false
            button.detachedWidthConstraint?.isActive = false
            button.isDetachedLayout = false
            if let original = button.detachedOriginalTitle {
                button.title = original
                button.imagePosition = button.detachedOriginalImagePosition
                button.detachedOriginalTitle = nil
            }
            button.cell?.truncatesLastVisibleLine = button.notchTruncatesLastVisibleLine
        }
        tabStack.setFrameSize(NSSize(width: tabStack.fittingSize.width, height: notchStripHeight))
        tabScroll.contentView.scroll(to: .zero)
        tabScroll.reflectScrolledClipView(tabScroll.contentView)
        needsTabReveal = true
        view.needsLayout = true

        detachedTabTrailingConstraint.isActive = false
        detachedControlWidthConstraint.isActive = false
        tabTrailingConstraint.isActive = true
        controlLeadingConstraint.isActive = true
        tabLeadingConstraint.constant = 14
        titlebarDrag.isHidden = true
        addTabButton.title = ""
        addTabButton.image = symbol("plus")
        addTabButton.imagePosition = .imageOnly
        addTabButton.action = #selector(newTab)
        addTabButton.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil }?.constant = 28

        for constraint in stripHeightConstraints { constraint.constant = notchStripHeight }
    }

    private func updateDetachedControls() {
        addTabButton.isHidden = isSingleTabWindow
        let result = detachedTabPlan().toolbar
        let visible = Set(result.visible)
        var changed = arrangeToolbar(ifNeeded: [.back, .forward, .home, .reload, .address, .settings, .quit])
        if controlStack.spacing != DetachedToolbarLayout.spacing { controlStack.spacing = DetachedToolbarLayout.spacing }
        if !defaultToolbarSpacer.isHidden { defaultToolbarSpacer.isHidden = true }
        if !placedToolbarSpacer.isHidden { placedToolbarSpacer.isHidden = true }
        for (action, button) in toolbarButtons {
            if button.isHidden != !visible.contains(action) {
                button.isHidden = !visible.contains(action)
                changed = true
            }
        }
        for button in Array(toolbarButtons.values) + [detachButton] {
            if let width = button.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil }),
               width.constant != 28 { width.constant = 28 }
        }
        if detachedControlWidthConstraint.constant != result.width { detachedControlWidthConstraint.constant = result.width }
        if changed { rebuildToolsMenu() }
    }

    private func updateCompactControls() {
        if isDetached { updateDetachedControls(); return }
        if detachedControlWidthConstraint?.isActive == true { restoreNotchMetrics() }
        defaultToolbarSpacer.isHidden = false
        placedToolbarSpacer.isHidden = false
        let available = view.bounds.width / 2 - controlLeadingConstraint.constant - 12
        let capacity = max(0, Int((available - 32) / 32))
        let requested = store.data.toolbarActions.filter { $0 != .notion && $0.isAvailable }
        let visible = Set(requested.filter { $0 != .spacer }.prefix(capacity))
        var changed = arrangeToolbar(ifNeeded: requested)
        // Keep the original visible actions and camera gap. Narrow only their hit areas
        // when the extra detach button needs room; retain at least 3pt between controls.
        let iconCount = CGFloat(visible.count + 1) // visible actions plus detach
        let gapCount = iconCount + 1 // includes the existing toolbar spacer
        let spacing: CGFloat = 24 * iconCount + 28 + 4 * gapCount <= available ? 4 : 3
        if controlStack.spacing != spacing { controlStack.spacing = spacing }
        let iconWidth = max(24, min(28, floor((available - 28 - spacing * gapCount) / iconCount)))
        for button in Array(toolbarButtons.values) + [detachButton] {
            if let width = button.constraints.first(where: { $0.firstAttribute == .width && $0.secondItem == nil }),
               width.constant != iconWidth {
                width.constant = iconWidth
            }
        }
        for (action, button) in toolbarButtons {
            let hidden = !visible.contains(action)
            if button.isHidden != hidden { button.isHidden = hidden; changed = true }
        }
        if changed { rebuildToolsMenu() }
    }

    @discardableResult
    private func arrangeToolbar(ifNeeded requested: [ToolbarAction]) -> Bool {
        guard arrangedToolbarActions != requested else { return false }
        arrangedToolbarActions = requested
        controlStack.arrangedSubviews.forEach { controlStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let ordered = requested + ToolbarAction.allCases.filter { !requested.contains($0) && $0 != .spacer && $0 != .notion && $0.isAvailable }
        for action in ordered {
            if action == .spacer {
                placedToolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                controlStack.addArrangedSubview(placedToolbarSpacer)
            } else if let button = toolbarButtons[action] {
                controlStack.addArrangedSubview(button)
            }
        }
        if !requested.contains(.spacer) {
            defaultToolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            controlStack.addArrangedSubview(defaultToolbarSpacer)
        }
        let pinIndex = controlStack.arrangedSubviews.firstIndex(of: keepOpenButton) ?? controlStack.arrangedSubviews.count
        controlStack.insertArrangedSubview(detachButton, at: min(pinIndex + 1, controlStack.arrangedSubviews.count))
        controlStack.addArrangedSubview(toolsButton)
        return true
    }

    private var layingOutDetachedTabs = false
    private var lastDetachedSettle: [String]?
    private var lastDetachedRebuild: [String]?
    private var detachedTabViews: [NSView] = []
    private lazy var overflowTabButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(showOverflowTabs))
        button.bezelStyle = .recessed
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        button.isHidden = true
        return button
    }()
    private var normalTabScrollTrailingConstraint: NSLayoutConstraint!
    private var overflowTabConstraints: [NSLayoutConstraint] = []
    private var overflowTabLeadingConstraint: NSLayoutConstraint!
    private var overflowControlGapConstraint: NSLayoutConstraint!

    private func detachedSettleKey() -> [String] {
        [String(describing: view.bounds.size), String(describing: detachedTrafficInset),
         String(describing: selectedIndex), String(describing: controlStack.spacing),
         String(describing: detachedControlWidthConstraint.constant)]
        + stripHeightConstraints.map { String(describing: $0.constant) }
        + tabStack.arrangedSubviews.map { item in
            let button = item as? TabButton
            return "\(ObjectIdentifier(item)):\(button?.detachedOriginalTitle ?? button?.title ?? ""):\(button?.detachedNaturalWidth ?? item.fittingSize.width):\(button?.detachedWidthConstraint?.constant ?? 0)"
        }
        + controlStack.arrangedSubviews.map { "\(ObjectIdentifier($0)):\($0.isHidden)" }
    }

    private func detachedTabPlan() -> DetachedTabLayout.Plan {
        let allViews = detachedTabViews.isEmpty ? tabStack.arrangedSubviews : detachedTabViews
        let buttons = allViews.compactMap { $0 as? TabButton }
        let full = buttons.map { $0.detachedMeasuredWidth }.max() ?? 100
        let minimum: CGFloat = 66 // Designer-approved text/icon boundary
        let divider = allViews.filter { !($0 is TabButton) }.reduce(CGFloat(0)) { total, _ in total + 4 + tabStack.spacing }
        // Use the settled chrome span, independent of the chosen toolbar width.
        // Its right edge remains fixed while the optional controls are folded.
        // Anchor the budget to the window, never to a controlStack that may
        // already overflow. Using its displaced maxX creates a positive feedback
        // loop: wider tabs push controls right, which then reports a larger budget.
        let rightEdge = glass.content.convert(view.bounds, from: view).maxX - DetachedToolbarLayout.rightInset
        let scrollLeft = glass.content.convert(tabScroll.bounds, from: tabScroll).minX
        let actualSpan = rightEdge - scrollLeft
        let geometrySettled = abs(glass.content.bounds.width - view.bounds.width) < 1
            && abs(scrollLeft - detachedTrafficInset) < 1 && actualSpan > 0
        let addWidth: CGFloat = isSingleTabWindow ? 0 : 28
        let available = geometrySettled ? actualSpan - addWidth - 4 - 8 - divider
            : view.bounds.width - detachedTrafficInset - addWidth - 4 - 8 - 12 - divider
        let initial = DetachedTabLayout.planWithOverflowButton(available: available, count: buttons.count, fullWidth: full, textMinimum: minimum, spacing: tabStack.spacing, minimumVisible: min(buttons.count, buttons.filter { tabs.indices.contains($0.tag) && tabs[$0.tag].pinnedID != nil }.count + 1))
        return initial
    }

    private func updateTabTitleWidths() {
        let arranged = isDetached && !detachedTabViews.isEmpty ? detachedTabViews : tabStack.arrangedSubviews
        for case let button as TabButton in arranged where button.detachedOriginalTitle == nil {
            button.detachedNaturalWidth = min(150, max(40, button.fittingSize.width))
        }
        let items: [CGFloat?] = arranged.map { view in
            if let button = view as? TabButton {
                let title = button.detachedOriginalTitle ?? button.title
                if !title.isEmpty { return nil }
            }
            return view.fittingSize.width
        }
        let toolbarAvailable = view.bounds.width - detachedTrafficInset - DetachedToolbarLayout.tabWidth
            - DetachedToolbarLayout.iconWidth - DetachedToolbarLayout.spacing
            - DetachedToolbarLayout.tabControlGap - DetachedToolbarLayout.rightInset
        let toolbarWidth = DetachedToolbarLayout.resolve(availableWidth: toolbarAvailable).width
        let visibleWidth = view.bounds.width - detachedTrafficInset - DetachedToolbarLayout.iconWidth
            - DetachedToolbarLayout.spacing - DetachedToolbarLayout.tabControlGap
            - DetachedToolbarLayout.rightInset - toolbarWidth
        let plan = detachedTabPlan()
        var widths = isDetached ? arranged.map { $0 is TabButton ? plan.width : 4 }
            : DetachedTabLayout.widths(available: max(0, visibleWidth), items: items, spacing: tabStack.spacing)
        if isDetached {
            let normals = tabButtons.filter { tabs.indices.contains($0.tag) && tabs[$0.tag].pinnedID == nil }
            let pinnedCount = arranged.compactMap { $0 as? TabButton }.count - normals.count
            let selectedNormal = normals.firstIndex { $0.tag == selectedIndex }
            let distribution = DetachedTabLayout.distribute(plan: plan, pinnedCount: pinnedCount, normalCount: normals.count, selectedNormal: selectedNormal)
            for (index, button) in normals.enumerated() { button.isHidden = !distribution.visibleNormalIndices.contains(index) }
            widths = arranged.map { $0 is TabButton ? distribution.width : 4 }
            let hidden = distribution.hiddenNormalCount
            addTabButton.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil }?.constant = isSingleTabWindow ? 0 : 28
            detachedTabTrailingConstraint.isActive = hidden == 0
            overflowControlGapConstraint.isActive = hidden > 0
            overflowTabLeadingConstraint.isActive = hidden > 0
            normalTabScrollTrailingConstraint.isActive = hidden == 0
            if hidden > 0 { NSLayoutConstraint.activate(overflowTabConstraints) }
            else { NSLayoutConstraint.deactivate(overflowTabConstraints) }
            overflowTabButton.isHidden = hidden == 0
            overflowTabButton.title = "+\(hidden)"
            overflowTabButton.toolTip = "あと \(hidden) 個"
            overflowTabButton.setAccessibilityLabel("あと \(hidden) 個")
            addTabButton.title = ""
            addTabButton.image = symbol("plus")
            addTabButton.imagePosition = .imageOnly
            addTabButton.action = #selector(newTab)
        }
        var changed = false
        for (index, view) in arranged.enumerated() {
            guard let button = view as? TabButton else { continue }
            if isDetached {
                button.onDetachedTitleChange = { [weak self] in self?.settleDetachedTabsAfterRebuild() }
                if button.detachedOriginalTitle == nil {
                    button.detachedOriginalTitle = button.title
                    button.detachedOriginalImagePosition = button.imagePosition
                }
                button.isDetachedLayout = true
                if button.detachedWidthConstraint == nil {
                    button.detachedWidthConstraint = button.widthAnchor.constraint(equalToConstant: widths[index])
                }
                if button.detachedWidthConstraint?.constant != widths[index] || button.detachedWidthConstraint?.isActive != true {
                    button.detachedWidthConstraint?.constant = widths[index]
                    button.detachedWidthConstraint?.isActive = true
                    changed = true
                }
                let oldTitle = button.title
                let oldPosition = button.imagePosition
                button.detachedMode = plan.mode
                button.detachedNaturalWidth = arranged.compactMap { ($0 as? TabButton)?.detachedMeasuredWidth }.max() ?? 150
                button.configureDetachedTitle(width: widths[index])
                changed = changed || oldTitle != button.title || oldPosition != button.imagePosition
            } else {
                if button.detachedWidthConstraint?.isActive == true {
                    button.detachedWidthConstraint?.isActive = false
                    changed = true
                }
                button.isDetachedLayout = false
                if let original = button.detachedOriginalTitle {
                    button.title = original
                    button.imagePosition = button.detachedOriginalImagePosition
                    button.detachedOriginalTitle = nil
                }
                button.isDetachedLayout = false
            }
            button.cell?.lineBreakMode = .byTruncatingTail
            button.cell?.truncatesLastVisibleLine = isDetached ? true : button.notchTruncatesLastVisibleLine
        }
        if changed || isDetached {
            let documentWidth = isDetached
                ? arranged.indices.filter { !arranged[$0].isHidden }.reduce(CGFloat(0)) { $0 + widths[$1] } + CGFloat(max(0, arranged.filter { !$0.isHidden }.count - 1)) * tabStack.spacing
                : tabStack.fittingSize.width
            if isDetached && overflowTabLeadingConstraint.isActive { overflowTabLeadingConstraint.constant = documentWidth + 4 }
            tabStack.setFrameSize(NSSize(width: documentWidth, height: tabStack.frame.height))
            tabStack.layoutSubtreeIfNeeded()
            needsTabReveal = true
        }
    }

    private func settleDetachedTabsAfterRebuild() {
        guard isDetached, !layingOutDetachedTabs else { return }
        guard lastDetachedSettle != detachedSettleKey() else { return }
        layingOutDetachedTabs = true
        defer { layingOutDetachedTabs = false }
        for case let button as TabButton in tabStack.arrangedSubviews {
            button.onDetachedTitleChange = { [weak self] in self?.settleDetachedTabsAfterRebuild() }
        }
        view.layoutSubtreeIfNeeded()
        updateCompactControls()
        view.layoutSubtreeIfNeeded()
        glass.layoutSubtreeIfNeeded()
        updateTabTitleWidths()
        view.layoutSubtreeIfNeeded()
        glass.layoutSubtreeIfNeeded()
        tabStack.layoutSubtreeIfNeeded()
        normalizeDetachedTabScroll()
        lastDetachedSettle = detachedSettleKey()
    }

    @objc private func showOverflowTabs() {
        let menu = NSMenu()
        for (index, tab) in tabs.enumerated() {
            let item = NSMenuItem(title: tab.displayName, action: #selector(selectTabByNumber), keyEquivalent: "")
            item.tag = index + 1
            item.state = index == selectedIndex ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let add = NSMenuItem(title: "新規タブ", action: #selector(newTab), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowTabButton.bounds.maxY), in: overflowTabButton)
    }


    private func normalizeDetachedTabScroll() {
        guard isDetached else { return }
        // Re-tile after replacing/resizing the document; NSClipView can retain its old
        // viewport and scroll origin even though the document now fits.
        tabScroll.tile()
        tabButtons.forEach { $0.updateTrackingAreas() }
        if tabStack.frame.width <= tabScroll.contentSize.width + 1 {
            tabScroll.contentView.scroll(to: .zero)
            tabScroll.reflectScrolledClipView(tabScroll.contentView)
            tabButtons.forEach { $0.updateTrackingAreas() }
            needsTabReveal = false
            return
        }
        if let index = selectedIndex, tabButtons.indices.contains(index) {
            tabButtons[index].scrollToVisible(tabButtons[index].bounds)
            let clip = tabScroll.contentView
            let maxX = max(0, tabStack.frame.width - clip.bounds.width)
            clip.scroll(to: NSPoint(x: min(max(0, clip.bounds.minX), maxX), y: 0))
            tabScroll.reflectScrolledClipView(clip)
            needsTabReveal = false
        }
        tabButtons.forEach { $0.updateTrackingAreas(); $0.needsDisplay = true }

    }

    override func updateViewConstraints() {
        // Resolve the fixed group's width before Auto Layout places the scroll
        // view. Mutating it in viewDidLayout left the sibling clip at its old x.
        if !isDetached {
            let items = pinnedTabStack.arrangedSubviews
            let naturalWidths = items.map { item -> CGFloat in
                guard let button = item as? TabButton else { return 4 }
                return min(150, max(28, button.cell?.cellSize.width ?? 28))
            }
            let natural = naturalWidths.reduce(CGFloat(0), +)
                + CGFloat(max(0, items.count - 1)) * pinnedTabStack.spacing
            let addWidth = addTabButton.constraints.first {
                $0.firstAttribute == .width && $0.secondItem == nil
            }?.constant ?? 28
            let available = max(0, view.bounds.width / 2 + tabTrailingConstraint.constant
                - addWidth - tabLeadingConstraint.constant - 4)
            let normalButtons = tabButtons.filter { tabs.indices.contains($0.tag) && tabs[$0.tag].pinnedID == nil }
            let normalButton = normalButtons.first { $0.tag == selectedIndex } ?? normalButtons.first
            let normalWidth = NotchTabLayout.normalSlotWidth(natural: normalButton?.cell?.cellSize.width ?? 150)
            let fixedWidth = NotchTabLayout.pinnedWidth(natural: natural, available: available, hasNormal: !normalButtons.isEmpty, normalWidth: normalWidth)
            if pinnedTabWidth.constant != fixedWidth { needsTabReveal = true }
            pinnedTabWidth.constant = fixedWidth
            tabStrip.fixedWidth = fixedWidth
            let widths = NotchTabLayout.fixedWidths(natural: naturalWidths, available: pinnedTabWidth.constant, spacing: pinnedTabStack.spacing)
            for (index, item) in items.enumerated() {
                if let button = item as? TabButton {
                    if button.notchFixedWidth == nil { button.notchFixedWidth = button.widthAnchor.constraint(equalToConstant: widths[index]) }
                    button.notchFixedWidth?.constant = widths[index]
                    button.notchFixedWidth?.isActive = true
                }
            }
        }
        super.updateViewConstraints()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !layingOutDetachedTabs else { return }
        layingOutDetachedTabs = true
        defer { layingOutDetachedTabs = false }
        updateCompactControls()
        if !isDetached {
            layoutAndRevealNotchTabs()
            return
        }
        if isDetached { glass.layoutSubtreeIfNeeded(); updateTabTitleWidths() }
        if isDetached { glass.layoutSubtreeIfNeeded(); tabStack.layoutSubtreeIfNeeded() }
        if isDetached { normalizeDetachedTabScroll() }
        revealSelectedNormalTab()
    }

    private func layoutAndRevealNotchTabs() {
        // Complete every nested layout before reading the viewport. The strip
        // assigns both sibling frames together, even without a visible window.
        glass.layoutSubtreeIfNeeded()
        tabStrip.needsLayout = true
        tabStrip.layoutSubtreeIfNeeded()
        tabStack.layoutSubtreeIfNeeded()
        tabScroll.tile()
        revealSelectedNormalTab()
    }

    private func revealSelectedNormalTab() {
        if needsTabReveal, tabScroll.bounds.width > 0, let index = selectedIndex, tabButtons.indices.contains(index) {
            needsTabReveal = false
            tabStack.layoutSubtreeIfNeeded()
            let button = tabButtons[index]
            if button.superview === tabStack {
                let clip = tabScroll.contentView
                // NSStackView's document origin may be inset from the clip.
                // Use one coordinate space for the selection and scroll limits.
                let selected = button.convert(button.bounds, to: clip)
                let x = NotchTabLayout.revealOrigin(current: clip.bounds.minX, viewport: clip.bounds.width, document: clip.documentRect.maxX, selected: selected)
                clip.scroll(to: NSPoint(x: x, y: 0))
                tabScroll.reflectScrolledClipView(clip)
            }
        }
    }

    func revealSelectedTabAfterNotchLayout() {
        guard !isDetached else { return }
        needsTabReveal = true
        view.needsUpdateConstraints = true
        view.updateConstraintsForSubtreeIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        needsTabReveal = true
        layoutAndRevealNotchTabs()
    }

    func preservingPagePosition(move: @escaping () -> Void, completion: @escaping () -> Void) {
        guard !preservingWebState else { return }
        preservingWebState = true
        let sourceWindow = NSApp.keyWindow ?? view.window
        let previousResponder = sourceWindow?.firstResponder
        let fallbackToContent = previousResponder == nil || previousResponder === sourceWindow
            || previousResponder === view || previousResponder === detachButton
        let nativeFocus = WebTransferResponderState(webView: selectedTab?.webView,
                                                   sourceWindow: sourceWindow, fallbackToContent: fallbackToContent)
        let addressWasEditing = addressField.currentEditor() === previousResponder && previousResponder != nil
        let views = ([selectedTab?.webView].compactMap { $0 } + tabs.map(\.webView))
            .reduce(into: [WKWebView]()) { result, view in
                if !result.contains(where: { $0 === view }) { result.append(view) }
            }
        let group = DispatchGroup()
        for webView in views {
            group.enter()
            webView.evaluateJavaScript(WebViewTransferState.capture, in: nil, in: .defaultClient) { _ in
                group.leave()
            }
        }
        let captured = WebTransferCompletionGate()
        let continueTransfer: () -> Void = { [weak self] in
            captured.run {
                guard let self else { return }
                move()
                self.view.layoutSubtreeIfNeeded()
                if addressWasEditing && !self.addressPopover.isShown {
                    self.addressPopover.show(relativeTo: self.addressButton.bounds, of: self.addressButton, preferredEdge: .minY)
                }
                let restoreWebFocus = nativeFocus.restore(to: self.view.window,
                                                         contentVisible: self.selectedTab?.webView.superview === self.webContainer)
                // Restore DOM selection only after native focus, overwriting any WebKit select-all.
                let restored = DispatchGroup()
                for webView in views {
                    restored.enter()
                    webView.callAsyncJavaScript(WebViewTransferState.restore,
                                               arguments: ["restoreFocus": restoreWebFocus && webView === self.selectedTab?.webView],
                                               in: nil, in: .defaultClient) { _ in
                        restored.leave()
                    }
                }
                let restoredGate = WebTransferCompletionGate()
                let finish: () -> Void = {
                    restoredGate.run {
                        self.preservingWebState = false
                        completion()
                    }
                }
                restored.notify(queue: .main, execute: finish)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: finish)
            }
        }
        group.notify(queue: .main, execute: continueTransfer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: continueTransfer)
    }

    func focusContent() {
        guard !preservingWebState else { return }
        if let tab = selectedTab, tab.webView.url != nil {
            view.window?.makeFirstResponder(tab.webView)
            addressField.stringValue = tab.webView.url?.absoluteString ?? ""
        } else {
            view.window?.makeFirstResponder(addressButton)
        }
    }

    func settingsChanged() {
        guard isViewLoaded else { return }
        if !notionAgentTabVisible && notionPanel?.isHidden == false {
            notionPanel?.isHidden = true
            NotionAgentsStore.shared.setPanelVisible(false)
            updateNotionTabSelection()
        }
        updateNotionAppearance()
        syncPinnedTabs()
        glass.updateAppearance()
        updateCompactControls()
        updateChrome()
    }

    deinit {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
        }
    }

    private func updateNotionAppearance() {
        notionPanel?.appearance = store.data.notionAppearance.resolvedAppearance
    }

    // MARK: Tabs

    private static func makeConfiguration(profileID: UUID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ProfileDataStores.store(for: profileID) // persistent, per profile
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        return config
    }

    private func makeWebView(profileID: UUID, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration = configuration ?? Self.makeConfiguration(profileID: profileID)
        installLinkMenu(in: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Google refuses sign-in from "embedded" browsers; present as Safari.
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    private func installLinkMenu(in controller: WKUserContentController) {
        guard !linkMenuControllers.contains(controller) else { return }
        let script = """
        (() => {
          if (window.__notchBrowserLinkMenuInstalled) return;
          window.__notchBrowserLinkMenuInstalled = true;
          document.addEventListener('contextmenu', event => {
            const link = event.composedPath().map(node =>
              node instanceof Element ? node.closest('a[href]') : null).find(Boolean);
            if (!link) return;
            let url;
            try { url = new URL(link.href, document.baseURI); } catch (_) { return; }
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
            event.preventDefault();
            event.stopImmediatePropagation();
            window.webkit.messageHandlers.notchBrowserLinkMenu.postMessage(url.href);
          }, true);
        })();
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(LinkMenuMessageHandler(owner: self), name: "notchBrowserLinkMenu")
        linkMenuControllers.add(controller)
    }

    fileprivate func showLinkMenu(for message: WKScriptMessage) {
        guard let rawURL = message.body as? String, let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let webView = message.webView, let window = webView.window,
              let index = index(of: webView) else { return }
        let context = LinkMenuContext(url: url, opener: tabs[index])
        let menu = NSMenu()
        for (title, action, symbolName) in [
            ("新規タブで開く", #selector(openLinkInNewTab(_:)), "plus.square.on.square"),
            ("ブラウザで開く", #selector(openLinkExternally(_:)), "safari"),
            ("リンクをコピー", #selector(copyLink(_:)), "link")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = context
            item.image = symbol(symbolName)
            menu.addItem(item)
        }
        let point = webView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LinkMenuContext else { return }
        openInNewTab(context.url, from: context.opener)
    }

    @objc private func openLinkExternally(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LinkMenuContext else { return }
        ExternalBrowserLauncher.open(context.url, bundleID: store.data.externalBrowserBundleID)
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? LinkMenuContext else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(context.url.absoluteString, forType: .string)
    }

    /// Pinned tabs come first, in settings order; other tabs follow.
    private func syncPinnedTabs() {
        guard !isSingleTabWindow else { return }
        let pinned = store.data.pinnedTabs
        let pinnedIDs = Set(pinned.map(\.id))
        let selected = selectedTab

        for tab in tabs where tab.pinnedID.map({ !pinnedIDs.contains($0) }) ?? false {
            discard(tab)
        }
        tabs.removeAll { $0.pinnedID.map { !pinnedIDs.contains($0) } ?? false }

        var ordered: [Tab] = []
        for entry in pinned {
            if let tab = tabs.first(where: { $0.pinnedID == entry.id }) {
                if tab.profileID != entry.profileID {
                    switchProfile(of: tab, to: entry.profileID, reloading: tab.webView.url ?? URL(string: entry.url))
                }
                if tab.homeURL != entry.url {
                    tab.homeURL = entry.url
                    if let url = URL(string: entry.url), url.host() != nil { tab.webView.load(URLRequest(url: url)) }
                }
                ordered.append(tab)
            } else {
                let tab = makeTab(pinnedID: entry.id, profileID: entry.profileID)
                tab.homeURL = entry.url
                if let url = URL(string: entry.url) { tab.webView.load(URLRequest(url: url)) }
                ordered.append(tab)
            }
        }
        tabs = ordered + tabs.filter { $0.pinnedID == nil }
        let index = selected.flatMap { s in tabs.firstIndex { $0 === s } } ?? (tabs.isEmpty ? nil : 0)
        select(index, preservingNotion: true)
    }

    private func makeTab(pinnedID: UUID?, profileID: UUID, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(pinnedID: pinnedID, profileID: profileID, webView: makeWebView(profileID: profileID, configuration: configuration))
        install(tab)
        return tab
    }

    /// Adds the tab's web view to the container and observes it.
    private func install(_ tab: Tab) {
        let webView = tab.webView
        tab.observations = [
            webView.observe(\.url) { [weak self] _, _ in self?.chromeNeedsUpdate() },
            webView.observe(\.title) { [weak self] _, _ in self?.chromeNeedsUpdate() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.chromeNeedsUpdate() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.chromeNeedsUpdate() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.chromeNeedsUpdate() },
        ]
        webView.isHidden = tab !== selectedTab
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
        ])
    }

    private func discard(_ tab: Tab) {
        tab.refreshTimer?.invalidate()
        tab.refreshTimer = nil
        tab.refreshInterval = 0
        tab.observations.removeAll()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
    }

    /// A web view's data store is fixed at creation, so changing profile means a new web view.
    private func switchProfile(of tab: Tab, to profileID: UUID, reloading url: URL?) {
        discard(tab)
        tab.profileID = profileID
        tab.replaceWebView(makeWebView(profileID: profileID))
        install(tab)
        if let url { tab.webView.load(URLRequest(url: url)) }
    }

    @discardableResult
    private func insertTab(_ tab: Tab, after anchor: Tab?) -> Tab {
        let index = anchor.flatMap { a in tabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: max(index, firstUnpinnedIndex))
        return tab
    }

    private var firstUnpinnedIndex: Int { tabs.firstIndex { $0.pinnedID == nil } ?? tabs.count }

    private func selectInitialTab() {
        let id: UUID?
        switch store.data.openTabBehavior {
        case .lastViewed: id = store.lastViewedPinnedID
        case .pinned(let pinnedID): id = pinnedID
        }
        select(id.flatMap { id in tabs.firstIndex { $0.pinnedID == id } } ?? (tabs.isEmpty ? nil : 0))
    }

    /// Called just before the notch expands.
    func prepareForOpen() {
        guard case .pinned(let id) = store.data.openTabBehavior,
              let tab = tabs.first(where: { $0.pinnedID == id }) else { return }
        select(tab)
    }

    private func select(_ index: Int?, preservingNotion: Bool = false) {
        if !preservingNotion { hideNotion() }
        if !notes.isHidden { notes.isHidden = true }
        findGeneration += 1
        findStatus.stringValue = ""
        if selectedIndex != index { addressPopover.close() }
        selectedIndex = index
        if let index, let id = tabs[index].pinnedID { store.lastViewedPinnedID = id }
        for (i, tab) in tabs.enumerated() { tab.webView.isHidden = i != index }
        updateChrome()
        needsTabReveal = true
        view.needsLayout = true
        if isDetached { settleDetachedTabsAfterRebuild() }
    }

    private func select(_ tab: Tab) {
        select(tabs.firstIndex { $0 === tab })
    }

    private func closeTab(at index: Int) {
        let tab = tabs.remove(at: index)
        if tab.pinnedID == nil, let url = tab.webView.url {
            closedTabs.push(ClosedTab(url: url, profileID: tab.profileID, zoom: tab.webView.pageZoom))
        }
        discard(tab)
        if tabs.isEmpty {
            select(nil)
        } else if let selected = selectedIndex {
            select(selected == index ? min(index, tabs.count - 1) : (selected > index ? selected - 1 : selected))
        }
        if isSingleTabWindow { onSingleTabClosed?() }
    }

    private func index(of webView: WKWebView) -> Int? {
        tabs.firstIndex { $0.webView === webView }
    }

    @objc func newTab(_ sender: Any?) {
        if isSingleTabWindow { onNewTabInNotch?(); return }
        let tab = makeTab(pinnedID: nil, profileID: store.data.newTabProfileID)
        insertTab(tab, after: nil)
        select(tab)
    }

    private func openInNewTab(_ url: URL, from opener: Tab? = nil) {
        let profileID = opener?.profileID ?? store.data.newTabProfileID
        let tab = makeTab(pinnedID: nil, profileID: profileID)
        tab.webView.load(URLRequest(url: url))
        if isSingleTabWindow { releaseNewTabToWindow(tab); return }
        insertTab(tab, after: opener ?? selectedTab)
        select(tab)
    }

    private func releaseNewTabToWindow(_ tab: Tab) {
        tab.observations.removeAll()
        tab.webView.removeFromSuperview()
        onCreateTabWindow?(tab)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        if tabs[index].pinnedID != nil {
            NSSound.beep() // pinned tabs are unpinned from the tab's context menu instead
            return
        }
        closeTab(at: index)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        if tabs.indices.contains(index) { select(index) }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        select(sender.tag)
        // NSButton/AXPress can toggle the reused selected button before its action.
        for button in tabButtons {
            let active = button.tag == selectedIndex && notionPanel?.isHidden != false && tasksPanel?.isHidden != false && meetingsPanel?.isHidden != false
            button.state = active ? .on : .off
            button.setAccessibilityValue(active ? "選択中" : "")
        }
        focusContent()
    }

    /// Drops the dragged tab where it was released, within its own group (pinned or not).
    private func tabDragEnded(_ button: TabButton) {
        isDraggingTab = false
        button.alphaValue = 1
        if button === notionTabButton || (tabs.indices.contains(button.tag) && tabs[button.tag].pinnedID != nil) {
            reorderPinnedButtons(afterDragging: button)
            return
        }
        let from = button.tag
        guard tabs.indices.contains(from) else { return updateChrome() }
        let tab = tabs[from]
        let midX = button.frame.midX
        let others = tabButtons.filter { $0 !== button && (isDetached || tabs[$0.tag].pinnedID == nil) }
        var destination = others.filter { $0.frame.midX < midX }.count + (isDetached ? 0 : firstUnpinnedIndex)

        let pinnedCount = tabs.filter { $0.pinnedID != nil }.count - (tab.pinnedID != nil ? 1 : 0)
        destination = tab.pinnedID != nil ? min(destination, pinnedCount) : max(destination, pinnedCount)

        let selected = selectedTab
        tabs.remove(at: from)
        tabs.insert(tab, at: destination)
        selectedIndex = selected.flatMap { s in tabs.firstIndex { $0 === s } }

        if tab.pinnedID != nil {
            let order = tabs.compactMap(\.pinnedID)
            store.data.pinnedTabs.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
        updateChrome()
    }

    private func reorderPinnedButtons(afterDragging button: TabButton) {
        let dragged = button === notionTabButton ? "notion" : tabs[button.tag].pinnedID!.uuidString
        var order = store.data.pinnedTabs.map { $0.id.uuidString }
        if notionAgentTabVisible {
            order.insert("notion", at: min(store.data.notionTabPosition, order.count))
        }
        order.removeAll { $0 == dragged }
        let otherButtons = (isDetached ? tabStack : pinnedTabStack).arrangedSubviews.compactMap { $0 as? TabButton }
            .filter { candidate in
                candidate !== button && (candidate === notionTabButton ||
                    (tabs.indices.contains(candidate.tag) && tabs[candidate.tag].pinnedID != nil))
            }
        let destination = otherButtons.filter { $0.frame.midX < button.frame.midX }.count
        order.insert(dragged, at: min(destination, order.count))
        var data = store.data
        if notionAgentTabVisible {
            data.notionTabPosition = order.firstIndex(of: "notion") ?? data.pinnedTabs.count
        }
        data.pinnedTabs.sort { left, right in
            (order.firstIndex(of: left.id.uuidString) ?? .max) <
            (order.firstIndex(of: right.id.uuidString) ?? .max)
        }
        store.data = data
        updateChrome()
    }

    // MARK: Tab context menu

    @objc private func pinTab(_ sender: NSMenuItem) {
        guard !isSingleTabWindow else { return }
        let tab = tabs[sender.tag]
        guard tab.pinnedID == nil, let url = tab.webView.url else { return }
        let name = tab.webView.title.flatMap { $0.isEmpty ? nil : String($0.prefix(14)) } ?? url.host() ?? "Web"
        let entry = PinnedTab(name: name, url: url.absoluteString, profileID: tab.profileID)
        tab.pinnedID = entry.id
        tab.homeURL = entry.url
        store.data.pinnedTabs.append(entry)
    }

    @objc private func unpinTab(_ sender: NSMenuItem) {
        let tab = tabs[sender.tag]
        guard let id = tab.pinnedID else { return }
        // Keep the page open as a regular tab.
        tab.pinnedID = nil
        store.data.pinnedTabs.removeAll { $0.id == id }
    }

    @objc private func setPinnedHome(_ sender: NSMenuItem) {
        let tab = tabs[sender.tag]
        guard let id = tab.pinnedID, let url = tab.webView.url else { return }
        tab.homeURL = url.absoluteString
        store.updatePinnedTab(id) { $0.url = url.absoluteString }
    }

    @objc private func openTabExternally(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag), let url = tabs[sender.tag].webView.url else { return }
        let tab = tabs[sender.tag]
        ExternalBrowserLauncher.open(url, bundleID: store.data.externalBrowserBundleID) { [weak self, weak tab] opened in
            guard opened, let self, let tab,
                  let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(at: index)
            self.onExternalTabOpened?()
        }
    }

    @objc private func toggleIconOnly(_ sender: NSMenuItem) {
        guard let id = tabs[sender.tag].pinnedID else { return }
        store.updatePinnedTab(id) { $0.iconOnly.toggle() }
    }

    @objc private func changeProfile(_ sender: NSMenuItem) {
        guard let (index, profileID) = sender.representedObject as? (Int, UUID) else { return }
        let tab = tabs[index]
        if let id = tab.pinnedID {
            store.updatePinnedTab(id) { $0.profileID = profileID } // syncPinnedTabs swaps the web view
        } else {
            switchProfile(of: tab, to: profileID, reloading: tab.webView.url)
            updateChrome()
        }
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        closeTab(at: sender.tag)
    }

    @objc private func openSettings() { onOpenSettings?() }

    // MARK: Chrome

    private var updateScheduled = false

    private func chromeNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.updateChrome()
        }
    }

    private func updateChrome() {
        onPageTitleChanged?(selectedTab?.displayName ?? "新規タブ")
        guard isViewLoaded else { return }
        rebuildTabButtons()

        let webView = selectedTab?.webView
        backButton.isEnabled = webView?.canGoBack ?? false
        forwardButton.isEnabled = webView?.canGoForward ?? false
        reloadButton.image = symbol(webView?.isLoading == true ? "xmark" : "arrow.clockwise")
        keepOpenButton.image = symbol(keepOpen ? "pin.fill" : "pin")
        keepOpenButton.contentTintColor = keepOpen ? .controlAccentColor : nil
        homeButton.isEnabled = selectedTab?.homeURL.flatMap(Self.url(from:)) != nil
        addressButton.toolTip = "URLを表示・検索 (⌘L)" + (webView?.url.map { "\n" + $0.absoluteString } ?? "")
        rebuildToolsMenu()
        updateStartPage()
        if !switcher.isHidden { rebuildSwitcherResults() }

        // Don't clobber what the user is typing.
        if addressField.currentEditor() == nil {
            addressField.stringValue = webView?.url?.absoluteString ?? ""
        }
        // Start-page hosting and other chrome updates above can invalidate ancestor layout.
        // Settle again before returning to tab commands, rather than waiting for a run loop.
        settleDetachedTabsAfterRebuild()
    }

    private func rebuildTabButtons() {
        guard !isDraggingTab else { return } // the dragged button must stay alive
        if isDetached {
            // Loading progress alone does not change the tabs. Preserve the buttons
            // so the settle cache also avoids synchronous layout on these updates.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let key = [(try? encoder.encode(store.data))?.base64EncodedString() ?? "",
                       String(describing: selectedIndex), String(describing: notionPanel?.isHidden), String(describing: tasksPanel?.isHidden), String(notionTabsConnected), String(describing: meetingsPanel?.isHidden),
                       String(describing: view.effectiveAppearance.name)]
                + tabs.map { "\(ObjectIdentifier($0)):\($0.profileID):\($0.displayName):\($0.webView.url?.absoluteString ?? "")" }
            let titlesMatch = tabButtons.count == tabs.count && zip(tabButtons, tabs).allSatisfy { button, tab in
                (button.detachedOriginalTitle ?? button.title) == (tab.pinned?.iconOnly == true ? "" : tab.displayName)
            }
            if lastDetachedRebuild == key && titlesMatch { return }
            lastDetachedRebuild = key
        } else {
            lastDetachedRebuild = nil
            lastDetachedSettle = nil
        }
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pinnedTabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabButtons = []
        let grayscale = store.data.grayscaleIcons
        if !isSingleTabWindow && notionTabsConnected {
            tasksTabButton.isDetachedLayout = false
            tasksTabButton.detachedOriginalTitle = nil
            tasksTabButton.detachedWidthConstraint?.isActive = false
            tasksTabButton.notchFixedWidth?.isActive = false
            tasksTabButton.state = tasksPanel?.isHidden == false ? .on : .off
            tabStack.addArrangedSubview(tasksTabButton)
            meetingsTabButton.isDetachedLayout = false
            meetingsTabButton.detachedOriginalTitle = nil
            meetingsTabButton.detachedWidthConstraint?.isActive = false
            meetingsTabButton.notchFixedWidth?.isActive = false
            meetingsTabButton.state = meetingsPanel?.isHidden == false ? .on : .off
            tabStack.addArrangedSubview(meetingsTabButton)
        }
        let notionPosition = min(store.data.notionTabPosition, firstUnpinnedIndex)
        func addNotion() {
            // This button is reused; discard the previous detached title/width snapshot.
            notionTabButton.isDetachedLayout = false
            notionTabButton.detachedOriginalTitle = nil
            notionTabButton.detachedWidthConstraint?.isActive = false
            notionTabButton.notchFixedWidth?.isActive = false
            let display = store.data.notionTabDisplay
            notionTabButton.title = display == .iconOnly ? "" : "Notion"
            notionTabButton.image = display == .titleOnly ? nil : NotionTabIcon.image(for: view.effectiveAppearance)
            notionTabButton.imagePosition = switch display {
            case .iconAndTitle: .imageLeading
            case .iconOnly: .imageOnly
            case .titleOnly: .noImage
            }
            notionTabButton.state = notionPanel?.isHidden == false ? .on : .off
            notionTabButton.showsBorderOnlyWhileMouseInside = notionPanel?.isHidden != false
            notionTabButton.alphaValue = 1
            tabStack.addArrangedSubview(notionTabButton)
        }
        for (i, tab) in tabs.enumerated() {
            if !isSingleTabWindow && notionAgentTabVisible && i == notionPosition { addNotion() }
            if i == firstUnpinnedIndex {
                let divider = NSBox()
                divider.boxType = .separator
                divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
                if !isDetached { divider.widthAnchor.constraint(equalToConstant: 4).isActive = true }
                if isDetached {
                    let width = divider.widthAnchor.constraint(equalToConstant: 4)
                    width.identifier = "detached-tab-divider"
                    width.isActive = true
                }
                tabStack.addArrangedSubview(divider)
            }
            let iconOnly = tab.pinned?.iconOnly ?? false
            let colored = !grayscale || (store.data.colorSelectedIcon && i == selectedIndex)
            let button = TabButton(title: iconOnly ? "" : tab.displayName, image: tab.icon(grayscale: !colored), target: self, action: #selector(tabClicked))
            button.onDragBegan = { [weak self] _ in self?.isDraggingTab = true }
            button.onDragEnded = { [weak self] button in self?.tabDragEnded(button) }
            if tab.pinnedID == nil && !isSingleTabWindow {
                button.onDragOut = { [weak self, weak tab] point in
                    guard let self, let tab else { return }
                    self.isDraggingTab = false
                    self.onDetachTab?(tab, point)
                }
            }
            if tab.pinnedID == nil {
                button.onClose = { [weak self, weak tab] in
                    guard let self, let tab, let index = self.tabs.firstIndex(where: { $0 === tab }),
                          tab.pinnedID == nil else { return }
                    self.closeTab(at: index)
                }
            }
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            let active = i == selectedIndex && notionPanel?.isHidden != false && tasksPanel?.isHidden != false && meetingsPanel?.isHidden != false
            button.state = active ? .on : .off
            button.showsBorderOnlyWhileMouseInside = !active
            button.imagePosition = iconOnly ? .imageOnly : .imageLeading
            button.contentTintColor = .white
            button.setAccessibilityLabel(tab.displayName)
            button.setAccessibilityValue(active ? "選択中" : "")
            button.font = .systemFont(ofSize: 12, weight: isDetached ? .regular : (i == selectedIndex ? .semibold : .regular))
            button.lineBreakMode = .byTruncatingTail
            button.notchTruncatesLastVisibleLine = button.cell?.truncatesLastVisibleLine ?? false
            button.tag = i
            let profile = store.profile(tab.profileID)
            button.toolTip = [tab.displayName, profile.isDefault ? nil : "プロファイル: \(profile.name)"]
                .compactMap { $0 }.joined(separator: "\n")
            if !iconOnly {
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.maximumTitleWidth = button.widthAnchor.constraint(lessThanOrEqualToConstant: 150)
                button.maximumTitleWidth?.isActive = true
            }
            button.menu = contextMenu(for: tab, at: i)
            tabStack.addArrangedSubview(button)
            tabButtons.append(button)
        }
        if !isSingleTabWindow && notionAgentTabVisible && notionPosition == tabs.count { addNotion() }
        if !isDetached {
            for item in tabStack.arrangedSubviews {
                // Notion participates in the pinned order; keep the divider at
                // the fixed group's trailing edge, outside the scrolling clip.
                let fixed = (item as? TabButton).map {
                    $0 === notionTabButton || $0 === tasksTabButton || $0 === meetingsTabButton || (tabs.indices.contains($0.tag) && tabs[$0.tag].pinnedID != nil)
                } ?? true
                if fixed { item.removeFromSuperview(); pinnedTabStack.addArrangedSubview(item) }
            }
        } else {
            pinnedTabWidth.constant = 0
            tabStrip.fixedWidth = 0
        }
        detachedTabViews = isDetached ? tabStack.arrangedSubviews : []
        tabStack.frame = NSRect(origin: .zero, size: NSSize(width: tabStack.fittingSize.width, height: stripHeightConstraints.first?.constant ?? 32))
        settleDetachedTabsAfterRebuild()
        if !isDetached {
            needsTabReveal = true
            view.needsUpdateConstraints = true
            view.needsLayout = true
        }
    }

    private func contextMenu(for tab: Tab, at index: Int) -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, _ action: Selector, to menu: NSMenu = menu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            let icons: [Selector: String] = [#selector(toggleIconOnly): "eye", #selector(setPinnedHome): "house", #selector(openSettings): "slider.horizontal.3", #selector(pinTab): "pin", #selector(unpinTab): "pin.slash", #selector(closeTabFromMenu): "xmark", #selector(changeProfile): "person.crop.circle", #selector(openTabExternally): "safari", #selector(returnSingleTab): "arrow.down.backward", #selector(detachTabFromMenu): "arrow.up.forward.app"]
            item.image = symbol(icons[action] ?? "circle")
            item.tag = index
            menu.addItem(item)
            return item
        }

        menu.autoenablesItems = false
        if isSingleTabWindow {
            add("ノッチに戻す", #selector(returnSingleTab))
        } else {
            let detach = add("このタブを別ウインドウで開く", #selector(detachTabFromMenu))
            detach.image = symbol("arrow.up.forward.app")
            detach.isEnabled = tab.pinnedID == nil
        }
        menu.addItem(.separator())
        if let pinned = tab.pinned {
            add("アイコンのみ表示", #selector(toggleIconOnly)).state = pinned.iconOnly ? .on : .off
            add("現在のページをホームに設定", #selector(setPinnedHome))
            add("固定タブを編集…", #selector(openSettings))
            menu.addItem(.separator())
        } else {
            add("固定タブにする", #selector(pinTab)).isEnabled = !isSingleTabWindow
        }

        add("ブラウザで開く", #selector(openTabExternally)).isEnabled = tab.webView.url != nil

        let profiles = NSMenu()
        for profile in store.data.profiles {
            let item = add(profile.name, #selector(changeProfile), to: profiles)
            item.representedObject = (index, profile.id)
            item.state = profile.id == tab.profileID ? .on : .off
        }
        let profileItem = NSMenuItem(title: "プロファイル", action: nil, keyEquivalent: "")
        profileItem.submenu = profiles
        menu.addItem(profileItem)
        menu.addItem(.separator())

        if tab.pinnedID != nil {
            add("固定を解除", #selector(unpinTab))
        } else {
            add("タブを閉じる", #selector(closeTabFromMenu))
        }
        return menu
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    private func iconButton(_ name: String, _ tooltip: String, _ action: Selector, target: AnyObject? = nil) -> NSButton {
        let button = NSButton(image: symbol(name) ?? NSImage(), target: target ?? self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.contentTintColor = .white
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: Navigation

    @objc func focusAddressBar(_ sender: Any? = nil) {
        guard let window = view.window else { return }
        // Only explicit URL editing activates the app; hover opening stays nonactivating.
        NSApp.activate()
        if !addressPopover.isShown {
            addressField.stringValue = selectedTab?.webView.url?.absoluteString ?? ""
            onModalChange?(true)
            let anchor: NSView = addressButton.isHidden ? toolsButton : addressButton
            addressPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            addressField.window?.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            addressField.window?.sharingType = hideFromScreenCapture ? .none : .readOnly
        }
        addressField.window?.makeKey()
        addressField.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressSubmitted(_ sender: NSTextField) {
        navigate(sender.stringValue)
        addressPopover.close()
    }

    private func navigate(_ text: String) {
        guard let url = Self.url(from: text) else { return }
        if let tab = selectedTab {
            if tab.homeURL == nil { tab.homeURL = url.absoluteString }
            tab.webView.load(URLRequest(url: url))
        } else {
            openInNewTab(url)
        }
        if let webView = selectedTab?.webView { view.window?.makeFirstResponder(webView) }
    }

    @objc func goHome(_ sender: Any?) {
        guard let tab = selectedTab, let home = tab.homeURL, let url = Self.url(from: home) else { return }
        addressPopover.close()
        tab.webView.load(URLRequest(url: url))
        focusContent()
    }

    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" ") {
            if text.hasPrefix("localhost") { return URL(string: "http://" + text) }
            if text.contains(".") { return URL(string: "https://" + text) }
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    @objc func goBack(_ sender: Any?) { selectedTab?.webView.goBack() }
    @objc func goForward(_ sender: Any?) { selectedTab?.webView.goForward() }
    @objc func reloadPage(_ sender: Any?) { selectedTab?.webView.reload() }

    @objc private func reloadOrStop() {
        guard let webView = selectedTab?.webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    @objc func toggleDetached(_ sender: Any?) { ShortcutController.shared.cancelPending(); if isSingleTabWindow { onReturnTab?() } else { onToggleDetached?() } }

    @objc private func toggleKeepOpen() { onToggleKeepOpen?() }

    @objc private func openExternally() {
        if let url = selectedTab?.webView.url { ExternalBrowserLauncher.open(url, bundleID: store.data.externalBrowserBundleID) }
    }

    // MARK: Page tools

    private func rebuildToolsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heading.image = symbol("ellipsis.circle")
        menu.addItem(heading)
        let detach = NSMenuItem(title: isDetached ? "ノッチに戻す" : "ブラウザ全体をウインドウにする", action: #selector(toggleDetached), keyEquivalent: "n")
        if !isSingleTabWindow { SettingsStore.shared.data.shortcuts[.detach].apply(to: detach) }
        else { detach.keyEquivalent = "" }
        detach.target = self
        detach.image = detachButton.image
        menu.addItem(detach)
        let hasPage = selectedTab?.webView.url != nil
        let zoom = selectedTab?.webView.pageZoom ?? 1
        for action in ToolbarAction.allCases {
            guard let button = toolbarButtons[action] else { continue }
            switch action {
            case .find, .copyURL, .resetZoom, .external, .autoRefresh: button.isEnabled = hasPage
            case .zoomIn: button.isEnabled = hasPage && zoom < 3
            case .zoomOut: button.isEnabled = hasPage && zoom > 0.5
            case .restore: button.isEnabled = !closedTabs.isEmpty
            case .closeTab: button.isEnabled = selectedTab != nil && selectedTab?.pinnedID == nil
            case .reload: button.isEnabled = hasPage || selectedTab?.webView.isLoading == true
            default: break
            }
            guard button.isHidden, action != .autoRefresh, !(isDetached && action == .keepOpen) else { continue }
            let item = NSMenuItem(title: action.title, action: button.action, keyEquivalent: "")
            item.target = self
            item.image = button.image
            item.isEnabled = button.isEnabled
            if action == .keepOpen { item.state = keepOpen ? .on : .off }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "自動更新", action: nil, keyEquivalent: "")
        refresh.image = symbol("arrow.triangle.2.circlepath")
        refresh.isEnabled = hasPage
        let intervals = NSMenu()
        intervals.autoenablesItems = false
        for (seconds, title) in [(0, "オフ"), (30, "30秒ごと"), (60, "1分ごと"), (300, "5分ごと")] {
            let item = NSMenuItem(title: title, action: #selector(setAutoRefresh), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = selectedTab?.refreshInterval == Double(seconds) ? .on : .off
            item.isEnabled = hasPage
            intervals.addItem(item)
        }
        refresh.submenu = intervals
        autoRefreshMenu = intervals
        if toolbarButtons[.autoRefresh]?.isHidden == true { menu.addItem(refresh) }
        toolsButton.menu = menu
        reloadButton.toolTip = (selectedTab?.refreshInterval ?? 0) > 0
            ? "再読み込み・自動更新中 (\(Int(selectedTab!.refreshInterval))秒ごと)" : "再読み込み (⌘R)"
        reloadButton.contentTintColor = (selectedTab?.refreshInterval ?? 0) > 0 ? .systemCyan : .white
    }

    @objc private func openShelf() { onOpenShelf?() }

    @objc func copyPageURL(_ sender: Any?) {
        guard let url = selectedTab?.webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func zoomIn(_ sender: Any?) { changeZoom(by: 0.1) }
    @objc func zoomOut(_ sender: Any?) { changeZoom(by: -0.1) }
    @objc func resetZoom(_ sender: Any?) { selectedTab?.webView.pageZoom = 1; updateChrome() }
    private func changeZoom(by delta: Double) {
        guard let webView = selectedTab?.webView else { return }
        webView.pageZoom = BrowserTools.zoom(((webView.pageZoom + delta) * 100).rounded() / 100)
        updateChrome()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let entry = closedTabs.pop() else { return }
        let profileID = store.data.profiles.contains { $0.id == entry.profileID } ? entry.profileID : Profile.defaultID
        let tab = makeTab(pinnedID: nil, profileID: profileID)
        tab.webView.pageZoom = BrowserTools.zoom(entry.zoom)
        tab.webView.load(URLRequest(url: entry.url))
        if isSingleTabWindow { releaseNewTabToWindow(tab); return }
        insertTab(tab, after: nil)
        select(tab)
        focusContent()
    }

    @objc private func setAutoRefresh(_ sender: NSMenuItem) {
        guard let tab = selectedTab else { return }
        tab.refreshTimer?.invalidate()
        tab.refreshTimer = nil
        tab.refreshInterval = Double(sender.tag)
        if sender.tag > 0 {
            let timer = Timer(timeInterval: Double(sender.tag), repeats: true) { [weak tab] _ in
                guard let tab, !tab.webView.isLoading else { return }
                tab.webView.reload()
            }
            timer.tolerance = min(5, Double(sender.tag) * 0.1)
            RunLoop.main.add(timer, forMode: .common)
            tab.refreshTimer = timer
        }
        updateChrome()
    }

    @objc func showFind(_ sender: Any?) {
        addressPopover.close()
        guard selectedTab?.webView.url != nil else { return }
        switcher.isHidden = true
        notes.isHidden = true
        findBar.isHidden = false
        findHeight.constant = 34
        view.window?.makeKey()
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }
    @objc func closeFind(_ sender: Any?) {
        findGeneration += 1
        findBar.isHidden = true
        findHeight.constant = 0
        findStatus.stringValue = ""
        selectedTab?.webView.find("", configuration: WKFindConfiguration()) { _ in }
        focusContent()
    }
    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }
    private func find(backwards: Bool) {
        guard let webView = selectedTab?.webView else { return }
        findGeneration += 1
        let generation = findGeneration
        let query = findField.stringValue
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(query, configuration: config) { [weak self, weak webView] result in
            guard let self, generation == self.findGeneration, webView === self.selectedTab?.webView else { return }
            self.findStatus.stringValue = query.isEmpty ? "" : (result.matchFound ? "一致あり" : "見つかりません")
        }
    }

    // MARK: Start page and tab switcher

    private func updateStartPage() {
        let show = selectedTab == nil || (selectedTab?.webView.url == nil && selectedTab?.webView.isLoading != true)
        guard show else { startPage?.isHidden = true; return }
        let page = StartPage(tabID: selectedTab.map(ObjectIdentifier.init), tabs: store.data.pinnedTabs, open: { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.pinnedID == id }) else { return }
            self.select(tab)
            self.focusContent()
        }, navigate: { [weak self] text in self?.navigate(text) })
        if let startPage { startPage.rootView = page; startPage.isHidden = false }
        else {
            let host = NSHostingView(rootView: page)
            host.frame = webContainer.bounds
            host.autoresizingMask = [.width, .height]
            webContainer.addSubview(host)
            startPage = host
        }
        if let startPage { webContainer.addSubview(startPage, positioned: .above, relativeTo: nil) }
    }

    private func configureSwitcher(in chrome: NSView) {
        switcher.wantsLayer = true
        switcher.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.18, alpha: 1).cgColor
        switcher.layer?.cornerRadius = 20
        switcher.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        switcher.layer?.borderWidth = 1
        switcher.isHidden = true
        switcher.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(switcher)
        tabSearch.placeholderString = "タブ名・URL・プロファイルで検索"
        tabSearch.setAccessibilityLabel("タブを検索")
        tabSearch.sendsWholeSearchString = true
        tabSearch.delegate = self
        tabSearch.target = self
        tabSearch.action = #selector(selectFirstSearchResult)
        let close = iconButton("xmark", "タブ検索を閉じる (Esc)", #selector(closeSwitcher))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        switchResults.orientation = .vertical
        switchResults.alignment = .leading
        switchResults.spacing = 6
        scroll.documentView = switchResults
        for sub in [tabSearch, close, scroll] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            switcher.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            switcher.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            switcher.topAnchor.constraint(equalTo: controlStack.bottomAnchor, constant: 10),
            switcher.widthAnchor.constraint(equalTo: chrome.widthAnchor, multiplier: 0.75),
            switcher.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -26),
            tabSearch.topAnchor.constraint(equalTo: switcher.topAnchor, constant: 18),
            tabSearch.leadingAnchor.constraint(equalTo: switcher.leadingAnchor, constant: 18),
            tabSearch.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            tabSearch.heightAnchor.constraint(equalToConstant: 30),
            close.centerYAnchor.constraint(equalTo: tabSearch.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: switcher.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: tabSearch.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: switcher.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: switcher.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: switcher.bottomAnchor, constant: -18)
        ])
    }
    @objc func showTabSwitcher(_ sender: Any?) {
        addressPopover.close()
        notes.isHidden = true
        switcher.isHidden = false
        tabSearch.stringValue = ""
        rebuildSwitcherResults()
        view.window?.makeKey()
        view.window?.makeFirstResponder(tabSearch)
    }
    @objc private func closeSwitcher(_ sender: Any?) { switcher.isHidden = true; focusContent() }
    @objc private func selectFirstSearchResult(_ sender: Any?) {
        let buttons = switchResults.arrangedSubviews.compactMap { $0 as? NSButton }
        if buttons.indices.contains(searchRow) { switcherTabClicked(buttons[searchRow]) }
    }
    @objc private func switcherTabClicked(_ sender: NSButton) {
        select(sender.tag)
        switcher.isHidden = true
        focusContent()
    }
    private func rebuildSwitcherResults() {
        switchResults.arrangedSubviews.forEach { $0.removeFromSuperview() }
        searchRow = 0
        let width = max(220, view.bounds.width * 0.75 - 40)
        for (index, tab) in tabs.enumerated() where BrowserTools.matches(query: tabSearch.stringValue,
                title: tab.displayName, url: tab.webView.url?.absoluteString ?? tab.homeURL ?? "", profile: store.profile(tab.profileID).name) {
            let button = NSButton(title: "  \(tab.displayName)  ·  \(store.profile(tab.profileID).name)",
                                  image: tab.icon(grayscale: false), target: self, action: #selector(switcherTabClicked))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.state = switchResults.arrangedSubviews.isEmpty ? .on : .off
            button.bezelStyle = .recessed
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 13, weight: index == selectedIndex ? .semibold : .regular)
            button.contentTintColor = index == selectedIndex ? .systemCyan : .white
            button.toolTip = tab.webView.url?.absoluteString
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            switchResults.addArrangedSubview(button)
        }
        if switchResults.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: "一致するタブがありません")
            empty.textColor = .secondaryLabelColor
            switchResults.addArrangedSubview(empty)
        }
        switchResults.frame = NSRect(origin: .zero, size: NSSize(width: width, height: switchResults.fittingSize.height))
    }
    private func moveSearchSelection(by delta: Int) {
        let buttons = switchResults.arrangedSubviews.compactMap { $0 as? NSButton }
        guard !buttons.isEmpty else { return }
        searchRow = min(buttons.count - 1, max(0, searchRow + delta))
        for (index, button) in buttons.enumerated() { button.state = index == searchRow ? .on : .off }
        buttons[searchRow].scrollToVisible(buttons[searchRow].bounds)
    }
    @objc func toggleNotes(_ sender: Any?) {
        addressPopover.close()
        hideNotion()
        if !notes.isHidden { notes.isHidden = true; focusContent(); return }
        switcher.isHidden = true
        notes.show(profile: store.profile(selectedTab?.profileID ?? store.data.newTabProfileID))
    }
    @objc func toggleNotion(_ sender: Any?) {
        guard !isSingleTabWindow, notionAgentTabVisible else { return }
        meetingsPanel?.isHidden = true
        tasksPanel?.isHidden = true
        addressPopover.close()
        updateNotionAppearance()
        let willShow = notionPanel?.isHidden == true
        notes.isHidden = true
        switcher.isHidden = true
        notionPanel?.isHidden = !willShow
        updateNotionTabSelection()
        NotionAgentsStore.shared.setPanelVisible(willShow)
        if !willShow { focusContent() }
    }
    func showNotion() {
        guard !isSingleTabWindow, notionAgentTabVisible else { return }
        _ = view
        meetingsPanel?.isHidden = true
        tasksPanel?.isHidden = true
        updateNotionAppearance()
        notionPanel?.isHidden = false
        updateNotionTabSelection()
        notes.isHidden = true
        NotionAgentsStore.shared.setPanelVisible(true)
    }
    func hideNotion() {
        let tasksWereVisible = tasksPanel?.isHidden == false || meetingsPanel?.isHidden == false
        meetingsPanel?.isHidden = true
        tasksPanel?.isHidden = true
        if tasksWereVisible { updateNotionTabSelection() }
        guard notionPanel?.isHidden == false else { return }
        notionPanel?.isHidden = true
        updateNotionTabSelection()
        NotionAgentsStore.shared.setPanelVisible(false)
    }

    private func updateNotionTabSelection() {
        let active = notionPanel?.isHidden == false || tasksPanel?.isHidden == false || meetingsPanel?.isHidden == false
        glass.opaqueBackdrop = active
        meetingsTabButton.state = meetingsPanel?.isHidden == false ? .on : .off
        meetingsTabButton.setAccessibilityValue(meetingsPanel?.isHidden == false ? "選択中" : "")
        notionTabButton.state = notionPanel?.isHidden == false ? .on : .off
        notionTabButton.setAccessibilityValue(notionPanel?.isHidden == false ? "選択中" : "")
        tasksTabButton.state = tasksPanel?.isHidden == false ? .on : .off
        tasksTabButton.setAccessibilityValue(tasksPanel?.isHidden == false ? "選択中" : "")
        for (index, button) in tabButtons.enumerated() {
            let selected = !active && index == selectedIndex
            button.state = selected ? .on : .off
            button.showsBorderOnlyWhileMouseInside = !selected
            button.setAccessibilityValue(selected ? "選択中" : "")
        }
    }
    func dismissOverlay() -> Bool {
        if meetingsPanel?.isHidden == false { hideNotion(); updateChrome(); focusContent(); return true }
        if tasksPanel?.isHidden == false { tasksPanel?.isHidden = true; updateNotionTabSelection(); updateChrome(); focusContent(); return true }
        if addressPopover.isShown { addressPopover.close(); focusContent(); return true }
        if notionPanel?.isHidden == false { hideNotion(); focusContent(); return true }
        if !notes.isHidden { notes.isHidden = true; focusContent(); return true }
        if !switcher.isHidden { closeSwitcher(nil); return true }
        if !findBar.isHidden { closeFind(nil); return true }
        return false
    }

    private var notionAgentTabVisible: Bool {
        NotionTaskRules.agentTabVisible(state: notionConnection.state, hasStoredToken: notionConnection.hasStoredToken,
                                       enabled: store.data.notionEnabled)
    }

    private var notionTabsConnected: Bool {
        NotionTaskRules.tabVisible(state: notionConnection.state, hasStoredToken: notionConnection.hasStoredToken)
    }

    func refreshTasksAvailability() {
        guard isViewLoaded, !isSingleTabWindow else { return }
        #if DEBUG
        if NotionMeetingsStore.shared.isMock {
            if notionTabsConnected { showMeetings() } else { hideNotion(); updateChrome(); focusContent() }
            return
        }
        #endif
        let tasks = NotionTasksStore.shared
        if !notionTabsConnected {
            // Panels overlay the last selected browser tab; closing them restores it.
            hideNotion()
            focusContent()
        }
        if NotionTaskRules.shouldAutoSelect(available: notionTabsConnected && tasks.available, alreadySelected: tasks.configuration.autoSelected) {
            tasks.configuration.autoSelected = true
            showTasks()
        }
        updateChrome()
    }

    @objc func showTasks() {
        guard !isSingleTabWindow, notionTabsConnected else { return }
        hideNotion()
        notes.isHidden = true; switcher.isHidden = true
        tasksPanel?.rootView = NotionTasksPanel(onOpenSettings: { [weak self] in self?.onOpenNotionSettings?() })
        tasksPanel?.isHidden = false
        updateNotionTabSelection()
        updateChrome()
        Task { await NotionTasksStore.shared.refresh() }
    }

    @objc func showMeetings() {
        guard !isSingleTabWindow, notionTabsConnected else { return }
        hideNotion()
        notes.isHidden = true; switcher.isHidden = true
        meetingsPanel?.rootView = NotionMeetingsPanel(onOpenSettings: { [weak self] in self?.onOpenNotionSettings?() })
        meetingsPanel?.isHidden = false
        updateNotionTabSelection()
        updateChrome()
    }

    // MARK: Modals

    /// Modal windows must sit above the notch panel, and it must not collapse while one is up.
    private func runModal<T>(_ body: () -> T) -> T {
        onModalChange?(true)
        defer { onModalChange?(false) }
        return body()
    }

    private func raise(_ window: NSWindow) {
        window.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
        if hideFromScreenCapture { window.sharingType = .none }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {
    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        // mailto:, zoommtg:, etc. go to their native apps.
        if let scheme = url.scheme?.lowercased(), !Self.webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            openInNewTab(url, from: index(of: webView).map { tabs[$0] })
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        chromeNeedsUpdate()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

// MARK: - WKDownloadDelegate

extension BrowserViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var destination = folder.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            destination = folder.appendingPathComponent(name)
            counter += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if ShelfFeature.isAvailable && SettingsStore.shared.data.shelfDownloads { ShelfStore.shared.add([url]) }
        // Bounces the Downloads stack in the Dock, like Safari.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {
    /// target=_blank links and OAuth popups open as tabs, keeping window.opener intact.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let opener = index(of: webView).map { tabs[$0] }
        let tab = makeTab(pinnedID: nil, profileID: opener?.profileID ?? store.data.newTabProfileID, configuration: configuration)
        if isSingleTabWindow { releaseNewTabToWindow(tab) }
        else { insertTab(tab, after: opener); select(tab) }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = index(of: webView), tabs[index].pinnedID == nil else { return }
        closeTab(at: index)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        runModal {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            raise(panel)
            return panel.runModal() == .OK ? panel.urls : nil
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        runModal {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host() ?? ""
            alert.informativeText = message
            raise(alert.window)
            alert.runModal()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        runModal {
            let alert = NSAlert()
            alert.messageText = frame.request.url?.host() ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "キャンセル")
            raise(alert.window)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

// MARK: - TabButton

/// Hover opening deliberately leaves the panel non-key. AppKit's recessed bezel
/// desaturates in that state, so draw the selected tab independently of focus.
final class TabButtonCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard let button = controlView as? TabButton, button.isDetachedLayout else {
            return super.titleRect(forBounds: rect)
        }
        return button.detachedTitleRect(in: rect)
    }

    func displayedTitle(forBounds rect: NSRect) -> String {
        guard let button = controlView as? TabButton, button.isDetachedLayout else { return title }
        guard button.detachedContentFullyVisible else { return "" }
        let width = titleRect(forBounds: rect).width
        let attributes: [NSAttributedString.Key: Any] = [.font: button.font ?? NSFont.systemFont(ofSize: 12)]
        return DetachedTabLayout.displayedTitle(button.title, mode: button.detachedMode, available: width) {
            ($0 as NSString).size(withAttributes: attributes).width
        }
    }

    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        if let button = controlView as? TabButton, button.isDetachedLayout {
            guard button.detachedContentFullyVisible else { return }
            let closeWidth: CGFloat = button.detachedCloseVisible && button.detachedMode != .iconOnly ? 20 : 0
            let iconSide = button.detachedIconSide
            if let image = button.image, button.imagePosition != .noImage, button.detachedDrawsIcon {
                let x = button.title.isEmpty ? frame.minX + (frame.width - closeWidth - iconSide) / 2 : frame.minX + 6
                let rendered: NSImage
                if let tint = button.detachedIconTint {
                    rendered = NSImage(size: image.size, flipped: false) { rect in
                        image.draw(in: rect)
                        tint.setFill()
                        rect.fill(using: .sourceIn)
                        return true
                    }
                } else { rendered = image } // colored/grayscale favicon pixels are unchanged
                rendered.draw(in: NSRect(x: x, y: frame.midY - iconSide / 2, width: iconSide, height: iconSide),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let text = displayedTitle(forBounds: frame)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: button.font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: button.contentTintColor ?? NSColor.labelColor, .paragraphStyle: paragraph]
            let rect = titleRect(forBounds: frame)
            let height = (text as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(in: NSRect(x: rect.minX, y: frame.midY - height / 2, width: rect.width, height: height), withAttributes: attributes)
            return
        }
        var contentFrame = frame
        if let button = controlView as? TabButton, button.onClose != nil {
            contentFrame.size.width = max(0, frame.width - 20)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: contentFrame).addClip()
        super.drawInterior(withFrame: contentFrame, in: controlView)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        if let button = controlView as? TabButton, button.isDetachedLayout, !button.detachedContentFullyVisible { return }
        guard state == .on else {
            super.drawBezel(withFrame: frame, in: controlView)
            return
        }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// Own the fixed/scroll boundary in one layout pass. Internal stack constraints
/// cannot position the sibling scroll view or leave it at a previous strip width.
private final class BrowserTabStripView: NSView {
    weak var fixed: NSStackView?
    weak var scroll: NSScrollView?
    var fixedWidth: CGFloat = 0 {
        didSet { if fixedWidth != oldValue { needsLayout = true } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(max(0, fixedWidth), bounds.width)
        fixed?.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll?.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        fixed?.layoutSubtreeIfNeeded()
        if let scroll {
            scroll.wantsLayer = true
            let mask = CAGradientLayer()
            mask.frame = scroll.bounds
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
            mask.locations = [0, NSNumber(value: Double(min(1, 12 / max(1, scroll.bounds.width)))), 1]
            scroll.layer?.mask = mask
        }
        scroll?.tile()
        if let scroll, let document = scroll.documentView {
            if abs(document.frame.height - scroll.contentSize.height) > 0.5 {
                document.setFrameSize(NSSize(width: document.frame.width, height: scroll.contentSize.height))
            }
            document.layoutSubtreeIfNeeded()
            if scroll.contentView.bounds.origin.y != 0 {
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 0))
            }
        }
    }
}

/// A resize changes the budget used by BrowserViewController.updateViewConstraints.
private final class BrowserRootView: NSView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsUpdateConstraints = true
    }
}

/// Tab button that can be dragged sideways to reorder. A click without movement acts normally.
final class TabButton: NSButton {
    var maximumTitleWidth: NSLayoutConstraint?
    var notchFixedWidth: NSLayoutConstraint?
    var detachedWidthConstraint: NSLayoutConstraint?
    var detachedNaturalWidth: CGFloat = 150
    var detachedIconTint: NSColor? { image?.isTemplate == true ? (contentTintColor ?? .labelColor) : nil }
    var detachedOriginalTitle: String?
    var detachedOriginalImagePosition: NSControl.ImagePosition = .imageLeading
    var isDetachedLayout = false
    var detachedMode: DetachedTabLayout.Mode = .full
    var detachedCloseVisible: Bool { onClose != nil && closeButton.isEnabled && closeButton.alphaValue > 0 }
    var detachedIconSide: CGFloat { 16 }
    var detachedDrawsIcon: Bool { !(detachedMode == .iconOnly && detachedCloseVisible) }
    private var detachedCloseFrame: NSRect {
        NSRect(x: detachedMode == .iconOnly ? bounds.midX - 10 : bounds.maxX - 16, y: bounds.midY - 10, width: detachedMode == .iconOnly ? 20 : 16, height: 20)
    }
    override var mouseDownCanMoveWindow: Bool { isDetachedLayout ? false : super.mouseDownCanMoveWindow }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isDetachedLayout || super.acceptsFirstMouse(for: event) }
    var detachedContentFullyVisible: Bool {
        guard isDetachedLayout else { return true }
        guard !isHidden else { return false }
        var parent = superview
        while parent != nil && !(parent is NSClipView) { parent = parent?.superview }
        guard let clip = parent as? NSClipView else { return true }
        let rect = convert(bounds, to: clip)
        return rect.minX >= clip.bounds.minX - 0.5 && rect.maxX <= clip.bounds.maxX + 0.5
    }
    var onDetachedTitleChange: (() -> Void)?
    private var applyingDetachedTitle = false

    override var title: String {
        didSet {
            guard isDetachedLayout, !applyingDetachedTitle, title != oldValue else { return }
            detachedOriginalTitle = title
            // Match the normal drawing geometry; hovering reserves close space separately.
            detachedNaturalWidth = detachedMeasuredWidth
            onDetachedTitleChange?()
        }
    }

    private var detachedTextAttributes: [NSAttributedString.Key: Any] { [.font: font ?? NSFont.systemFont(ofSize: 12)] }
    var detachedMeasuredWidth: CGFloat {
        let text = detachedOriginalTitle ?? title
        return 12 + (image == nil ? 0 : 20)
            + (text as NSString).size(withAttributes: detachedTextAttributes).width
    }
    var detachedMinimumTextWidth: CGFloat {
        let text = String((detachedOriginalTitle ?? title).prefix(2)) + "…"
        return 12 + (image == nil ? 0 : 20)
            + (text as NSString).size(withAttributes: detachedTextAttributes).width
    }

    func detachedTitleRect(in rect: NSRect) -> NSRect {
        let icon: CGFloat = image != nil && imagePosition != .noImage ? 20 : 0
        let hoveringText = detachedCloseVisible && detachedMode != .iconOnly
        let padding: CGFloat = hoveringText ? 8 : 12
        let close: CGFloat = hoveringText ? 14 : 0
        return NSRect(x: rect.minX + padding / 2 + icon, y: rect.minY,
                      width: max(0, rect.width - padding - icon - close), height: rect.height)
    }

    func configureDetachedTitle(width: CGFloat) {
        applyingDetachedTitle = true
        defer { applyingDetachedTitle = false }
        let original = detachedOriginalTitle ?? title
        let hide = detachedMode == .iconOnly
        let newTitle = hide ? "" : original
        if title != newTitle { title = newTitle }
        let position = hide && image != nil ? NSControl.ImagePosition.imageOnly : detachedOriginalImagePosition
        if imagePosition != position { imagePosition = position }
        cell?.wraps = false
        setHovered(isHovered)
        needsDisplay = true
    }

    var notchTruncatesLastVisibleLine = false
    override class var cellClass: AnyClass? {
        get { TabButtonCell.self }
        set { }
    }

    var onDragOut: ((NSPoint) -> Void)?
    var onDragBegan: ((TabButton) -> Void)?
    var onDragEnded: ((TabButton) -> Void)?
    var onClose: (() -> Void)? {
        didSet {
            if onClose != nil, closeButton.superview == nil { addSubview(closeButton) }
            if onClose == nil { closeButton.removeFromSuperview() }
            needsLayout = true
            needsDisplay = true
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private lazy var closeButton: NSButton = {
        let button = TabCloseButton()
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "タブを閉じる")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .white
        button.target = self
        button.action = #selector(closeClicked)
        button.setAccessibilityLabel("タブを閉じる")
        button.alphaValue = 0
        button.isEnabled = false
        return button
    }()

    override func layout() {
        super.layout()
        closeButton.frame = isDetachedLayout ? detachedCloseFrame : NSRect(x: bounds.maxX - 20, y: bounds.midY - 10, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        let hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        setHovered(hovered)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }
    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        if isDetachedLayout {
            isHovered = hovered
            // A direct update survives document re-layout and tracking-area refresh;
            // repeatedly restarted implicit alpha animations need not complete.
            closeButton.frame = isDetachedLayout ? detachedCloseFrame : NSRect(x: bounds.maxX - 20, y: bounds.midY - 10, width: 20, height: 20)
            let visible = hovered && onClose != nil && detachedContentFullyVisible && (detachedMode != .iconOnly || state == .on)
            closeButton.isEnabled = visible
            closeButton.alphaValue = visible ? 1 : 0
            needsDisplay = true
            return
        }
        guard isHovered != hovered else { return }
        isHovered = hovered
        closeButton.isEnabled = hovered
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            closeButton.animator().alphaValue = hovered ? 1 : 0
        }
    }

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menu ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if isDetachedLayout, let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        // Dispatch the tab action explicitly: NSButton's default accessibility
        // implementation need not invoke this custom mouseDown selection path.
        return sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let contextMenu = self.menu(for: event) {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
            return
        }
        guard let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        let originX = frame.origin.x
        var dragging = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start.x
            if next.type == .leftMouseUp {
                if dragging {
                    onDragEnded?(self)
                } else {
                    sendAction(action, to: target)
                }
                return
            }
            let row = superview ?? self
            let local = row.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged, let onDragOut,
               TabDetachmentGesture.shouldDetach(pointer: local, strip: row.bounds, flipped: row.isFlipped) {
                alphaValue = 1
                onDragOut(window.convertPoint(toScreen: next.locationInWindow))
                return
            }
            if !dragging, abs(dx) > 4 {
                dragging = true
                onDragBegan?(self)
                alphaValue = 0.85
            }
            if dragging {
                frame.origin.x = originX + dx
            }
        }
    }
}

/// Hidden close controls leave the entire tab body available for selection/dragging.
private final class TabCloseButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = isEnabled ? super.hitTest(point) : nil
        return hit
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }
}


extension BrowserViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === tabSearch { rebuildSwitcherResults() }
        if notification.object as? NSSearchField === findField { find(backwards: false) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { return dismissOverlay() }
        if control === tabSearch {
            if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSearchSelection(by: 1); return true }
            if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSearchSelection(by: -1); return true }
        }
        if control === findField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }
}

private final class TopAlignedStackView: NSStackView { override var isFlipped: Bool { true } }

extension BrowserViewController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        onModalChange?(false)
    }
}

/// The threshold is measured from the strip, independent of the tab button's height.
enum TabDetachmentGesture {
    static func shouldDetach(pointer: NSPoint, strip: NSRect, flipped: Bool) -> Bool {
        flipped ? pointer.y >= strip.maxY + 40 : pointer.y <= strip.minY - 40
    }
}
