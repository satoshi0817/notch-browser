import AppKit
import WebKit
import SwiftUI

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
    var onToggleKeepOpen: (() -> Void)?
    var onModalChange: ((Bool) -> Void)?
    var onOpenShelf: (() -> Void)?
    var onQuickSwitchChange: (() -> Void)?
    private(set) var quickSwitchVisible = false
    let quickSwitchStore = QuickSwitchStore()
    let systemSwitchStore = SystemSwitchStore()
    private var quickSwitchHost: NSHostingView<QuickSwitchView>?
    var onOpenSettings: (() -> Void)?
    var keepOpen = false { didSet { updateChrome() } }
    var hideFromScreenCapture = true

    private var tabs: [Tab] = []
    private var tabButtons: [TabButton] = []
    private var isDraggingTab = false
    private var selectedIndex: Int?
    private var selectedTab: Tab? { selectedIndex.map { tabs[$0] } }
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var store: SettingsStore { .shared }

    private let glass = GlassSurface()
    private let tabScroll = NSScrollView()
    private var needsTabReveal = true
    private lazy var addTabButton = iconButton("plus", "新規タブ (⌘T)", #selector(newTab))
    private let tabStack = NSStackView()
    private let findBar = NSStackView()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")
    private var findHeight: NSLayoutConstraint!
    private var findGeneration = 0
    private let notes = ScratchpadView()
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
    private let webContainer = NSView()
    private let addressField = NSTextField()
    private let addressPopover = NSPopover()
    private lazy var addressButton = iconButton("magnifyingglass", "URLを表示・検索 (⌘L)", #selector(focusAddressBar))
    private lazy var homeButton = iconButton("house", "設定したページに戻る", #selector(goHome))
    private lazy var backButton = iconButton("chevron.left", "戻る", #selector(goBack))
    private lazy var forwardButton = iconButton("chevron.right", "進む", #selector(goForward))
    private lazy var reloadButton = iconButton("arrow.clockwise", "再読み込み", #selector(reloadOrStop))
    private lazy var quickSwitchButton = iconButton("switch.2", "クイックスイッチ", #selector(openQuickSwitches))
    private lazy var keepOpenButton = iconButton("pin", "開いたままにする", #selector(toggleKeepOpen))

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
        view = NSView()
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
        for button in [backButton, forwardButton, homeButton, reloadButton, addressButton] { controlStack.addArrangedSubview(button) }
        controlStack.addArrangedSubview(NSView())
        for button in [keepOpenButton, quickSwitchButton, toolsButton] { controlStack.addArrangedSubview(button) }
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.documentView = tabStack
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
        for sub in [tabScroll, addTabButton, controlStack, findBar, webContainer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(sub)
        }
        tabTrailingConstraint = addTabButton.trailingAnchor.constraint(equalTo: chrome.centerXAnchor, constant: -110)
        controlLeadingConstraint = controlStack.leadingAnchor.constraint(equalTo: chrome.centerXAnchor, constant: 110)
        let tabHeight = tabScroll.heightAnchor.constraint(equalToConstant: 32)
        let controlHeight = controlStack.heightAnchor.constraint(equalToConstant: 32)
        stripHeightConstraints = [tabHeight, controlHeight]
        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabScroll.topAnchor.constraint(equalTo: chrome.topAnchor),
            tabScroll.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 14),
            tabTrailingConstraint, tabHeight,
            tabScroll.trailingAnchor.constraint(equalTo: addTabButton.leadingAnchor, constant: -4),
            addTabButton.centerYAnchor.constraint(equalTo: tabScroll.centerYAnchor),
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
        syncPinnedTabs()
        selectInitialTab()
    }

    /// Preserve the original single strip, with the camera cutout between tabs and navigation.
    func updateNotchMetrics(notchWidth: CGFloat, stripHeight: CGFloat) {
        _ = view
        let gap = notchWidth / 2 + 12
        tabTrailingConstraint.constant = -gap
        controlLeadingConstraint.constant = gap
        for constraint in stripHeightConstraints { constraint.constant = stripHeight }
        updateCompactControls()
        tabStack.setFrameSize(NSSize(width: tabStack.frame.width, height: stripHeight))
    }

    private func updateCompactControls() {
        let available = view.bounds.width / 2 - controlLeadingConstraint.constant - 12
        // Five 28pt controls plus spacing fit at 600pt with a physical camera cutout.
        forwardButton.isHidden = quickSwitchVisible || available < 265
        reloadButton.isHidden = quickSwitchVisible || available < 265
        backButton.isHidden = quickSwitchVisible || available < 160
        homeButton.isHidden = quickSwitchVisible || available < 195
        addressButton.isHidden = quickSwitchVisible || available < 130
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateCompactControls()
        if needsTabReveal, tabScroll.bounds.width > 0, let index = selectedIndex, tabButtons.indices.contains(index) {
            needsTabReveal = false
            tabStack.layoutSubtreeIfNeeded()
            tabButtons[index].scrollToVisible(tabButtons[index].bounds)
        }
    }

    func focusContent() {
        if quickSwitchVisible { view.window?.makeFirstResponder(quickSwitchHost); return }
        if let tab = selectedTab, tab.webView.url != nil {
            view.window?.makeFirstResponder(tab.webView)
            addressField.stringValue = tab.webView.url?.absoluteString ?? ""
        } else {
            view.window?.makeFirstResponder(addressButton)
        }
    }

    func settingsChanged() {
        guard isViewLoaded else { return }
        syncPinnedTabs()
        glass.updateAppearance()
        updateChrome()
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
        let webView = WKWebView(frame: .zero, configuration: configuration ?? Self.makeConfiguration(profileID: profileID))
        // Google refuses sign-in from "embedded" browsers; present as Safari.
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    /// Pinned tabs come first, in settings order; other tabs follow.
    private func syncPinnedTabs() {
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
        select(index)
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

    private func select(_ index: Int?) {
        if quickSwitchVisible { setQuickSwitchVisible(false) }
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
    }

    private func index(of webView: WKWebView) -> Int? {
        tabs.firstIndex { $0.webView === webView }
    }

    @objc func newTab(_ sender: Any?) {
        let tab = insertTab(makeTab(pinnedID: nil, profileID: store.data.newTabProfileID), after: nil)
        select(tab)
        focusAddressBar()
    }

    private func openInNewTab(_ url: URL, from opener: Tab? = nil) {
        let profileID = opener?.profileID ?? store.data.newTabProfileID
        let tab = insertTab(makeTab(pinnedID: nil, profileID: profileID), after: opener ?? selectedTab)
        tab.webView.load(URLRequest(url: url))
        select(tab)
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
        focusContent()
    }

    /// Drops the dragged tab where it was released, within its own group (pinned or not).
    private func tabDragEnded(_ button: TabButton) {
        isDraggingTab = false
        let from = button.tag
        guard tabs.indices.contains(from) else { return updateChrome() }
        let tab = tabs[from]
        let midX = button.frame.midX
        let others = tabButtons.filter { $0 !== button }
        var destination = others.filter { $0.frame.midX < midX }.count

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

    // MARK: Tab context menu

    @objc private func pinTab(_ sender: NSMenuItem) {
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
    }

    private func rebuildTabButtons() {
        guard !isDraggingTab else { return } // the dragged button must stay alive
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabButtons = []
        let grayscale = store.data.grayscaleIcons
        for (i, tab) in tabs.enumerated() {
            if i == firstUnpinnedIndex, i > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
                tabStack.addArrangedSubview(divider)
            }
            let iconOnly = tab.pinned?.iconOnly ?? false
            let colored = !grayscale || (store.data.colorSelectedIcon && i == selectedIndex)
            let button = TabButton(title: iconOnly ? "" : tab.displayName, image: tab.icon(grayscale: !colored), target: self, action: #selector(tabClicked))
            button.onDragBegan = { [weak self] _ in self?.isDraggingTab = true }
            button.onDragEnded = { [weak self] button in self?.tabDragEnded(button) }
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.state = i == selectedIndex ? .on : .off
            button.showsBorderOnlyWhileMouseInside = i != selectedIndex
            button.imagePosition = iconOnly ? .imageOnly : .imageLeading
            button.contentTintColor = .white
            button.setAccessibilityLabel(tab.displayName)
            button.setAccessibilityValue(i == selectedIndex ? "選択中" : "")
            button.font = .systemFont(ofSize: 12, weight: i == selectedIndex ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingTail
            button.tag = i
            let profile = store.profile(tab.profileID)
            button.toolTip = [tab.displayName, profile.isDefault ? nil : "プロファイル: \(profile.name)"]
                .compactMap { $0 }.joined(separator: "\n")
            if !iconOnly {
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
            }
            button.menu = contextMenu(for: tab, at: i)
            tabStack.addArrangedSubview(button)
            tabButtons.append(button)
        }
        tabStack.frame = NSRect(origin: .zero, size: NSSize(width: tabStack.fittingSize.width, height: stripHeightConstraints.first?.constant ?? 32))
    }

    private func contextMenu(for tab: Tab, at index: Int) -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, _ action: Selector, to menu: NSMenu = menu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            let icons: [Selector: String] = [#selector(toggleIconOnly): "eye", #selector(setPinnedHome): "house", #selector(openSettings): "slider.horizontal.3", #selector(pinTab): "pin", #selector(unpinTab): "pin.slash", #selector(closeTabFromMenu): "xmark", #selector(changeProfile): "person.crop.circle"]
            item.image = symbol(icons[action] ?? "circle")
            item.tag = index
            menu.addItem(item)
            return item
        }

        if let pinned = tab.pinned {
            add("アイコンのみ表示", #selector(toggleIconOnly)).state = pinned.iconOnly ? .on : .off
            add("現在のページをホームに設定", #selector(setPinnedHome))
            add("固定タブを編集…", #selector(openSettings))
            menu.addItem(.separator())
        } else {
            add("固定タブにする", #selector(pinTab))
        }

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
            addressPopover.show(relativeTo: addressButton.bounds, of: addressButton, preferredEdge: .minY)
            addressField.window?.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            addressField.window?.sharingType = hideFromScreenCapture ? .none : .readOnly
        }
        addressField.window?.makeKey()
        addressField.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressSubmitted(_ sender: NSTextField) {
        guard let url = Self.url(from: sender.stringValue) else { return }
        if let tab = selectedTab {
            if tab.homeURL == nil { tab.homeURL = url.absoluteString }
            tab.webView.load(URLRequest(url: url))
        } else {
            openInNewTab(url)
        }
        addressPopover.close()
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

    @objc private func toggleKeepOpen() { onToggleKeepOpen?() }

    @objc private func openExternally() {
        if let url = selectedTab?.webView.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Page tools

    private func rebuildToolsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heading.image = symbol("ellipsis.circle")
        menu.addItem(heading)
        func add(_ title: String, _ icon: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = symbol(icon)
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }
        let hasPage = selectedTab?.webView.url != nil
        _ = add("ページ内を検索  ⌘F", "magnifyingglass", #selector(showFind), enabled: hasPage)
        _ = add("URLをコピー", "link", #selector(copyPageURL), enabled: hasPage)
        menu.addItem(.separator())
        let zoom = selectedTab?.webView.pageZoom ?? 1
        _ = add("拡大  ⌘+", "plus.magnifyingglass", #selector(zoomIn), enabled: hasPage && zoom < 3)
        _ = add("縮小  ⌘−", "minus.magnifyingglass", #selector(zoomOut), enabled: hasPage && zoom > 0.5)
        _ = add("実際のサイズ (\(Int((zoom * 100).rounded()))%)  ⌘0", "arrow.up.left.and.arrow.down.right", #selector(resetZoom), enabled: hasPage)
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
        menu.addItem(refresh)
        menu.addItem(.separator())
        _ = add("閉じたタブを戻す  ⌘⇧T", "arrow.uturn.backward", #selector(reopenClosedTab), enabled: !closedTabs.isEmpty)
        _ = add("設定したページに戻る", "house", #selector(goHome), enabled: homeButton.isEnabled)
        _ = add("進む", "chevron.right", #selector(goForward), enabled: forwardButton.isEnabled)
        _ = add("再読み込み  ⌘R", "arrow.clockwise", #selector(reloadPage), enabled: hasPage)
        _ = add("URLを表示・検索  ⌘L", "magnifyingglass", #selector(focusAddressBar))
        _ = add("タブを検索  ⌘⇧A", "square.stack", #selector(showTabSwitcher))
        _ = add("タブを閉じる  ⌘W", "xmark", #selector(closeCurrentTab), enabled: selectedTab != nil && selectedTab?.pinnedID == nil)
        menu.addItem(.separator())
        _ = add("クイックスイッチ", "switch.2", #selector(openQuickSwitches))
        _ = add("ファイル棚", "tray", #selector(openShelf))
        _ = add("クイックメモ  ⌘⇧M", "square.and.pencil", #selector(toggleNotes))
        menu.addItem(.separator())
        _ = add("デフォルトブラウザで開く", "safari", #selector(openExternally), enabled: hasPage)
        _ = add("設定…  ⌘,", "gearshape", #selector(openSettings))
        let quit = add("NotchBrowser を終了  ⌘Q", "power", #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        toolsButton.menu = menu
        reloadButton.toolTip = (selectedTab?.refreshInterval ?? 0) > 0
            ? "再読み込み・自動更新中 (\(Int(selectedTab!.refreshInterval))秒ごと)" : "再読み込み (⌘R)"
        reloadButton.contentTintColor = (selectedTab?.refreshInterval ?? 0) > 0 ? .systemCyan : .white
    }

    @objc private func openQuickSwitches() { setQuickSwitchVisible(!quickSwitchVisible) }

    func setQuickSwitchVisible(_ visible: Bool) {
        _ = view
        guard quickSwitchVisible != visible else { return }
        quickSwitchVisible = visible
        addressPopover.close(); notes.isHidden = true; switcher.isHidden = true
        if visible {
            let host = NSHostingView(rootView: QuickSwitchView(store: quickSwitchStore, system: systemSwitchStore, onBack: { [weak self] in self?.setQuickSwitchVisible(false) }))
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: controlStack.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
            ])
            quickSwitchHost = host
        } else {
            quickSwitchHost?.removeFromSuperview(); quickSwitchHost = nil
            quickSwitchStore.stopObserving(); systemSwitchStore.stop()
        }
        webContainer.isHidden = visible
        quickSwitchButton.contentTintColor = visible ? .systemBlue : .white
        updateCompactControls()
        onQuickSwitchChange?()
        focusContent()
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
        let tab = insertTab(makeTab(pinnedID: nil, profileID: profileID), after: nil)
        tab.webView.pageZoom = BrowserTools.zoom(entry.zoom)
        tab.webView.load(URLRequest(url: entry.url))
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
        let page = StartPage(tabs: store.data.pinnedTabs, open: { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.pinnedID == id }) else { return }
            self.select(tab)
            self.focusContent()
        }, search: { [weak self] in self?.focusAddressBar() }, restore: { [weak self] in
            self?.reopenClosedTab(nil)
        }, canRestore: !closedTabs.isEmpty, settings: { [weak self] in self?.onOpenSettings?() })
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
        if !notes.isHidden { notes.isHidden = true; focusContent(); return }
        switcher.isHidden = true
        notes.show(profile: store.profile(selectedTab?.profileID ?? store.data.newTabProfileID))
    }
    func dismissOverlay() -> Bool {
        if quickSwitchVisible { setQuickSwitchVisible(false); return true }
        if addressPopover.isShown { addressPopover.close(); focusContent(); return true }
        if !notes.isHidden { notes.isHidden = true; focusContent(); return true }
        if !switcher.isHidden { closeSwitcher(nil); return true }
        if !findBar.isHidden { closeFind(nil); return true }
        return false
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
        if SettingsStore.shared.data.shelfDownloads { ShelfStore.shared.add([url]) }
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
        insertTab(tab, after: opener)
        select(tab)
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
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        guard state == .on else {
            super.drawBezel(withFrame: frame, in: controlView)
            return
        }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// Tab button that can be dragged sideways to reorder. A click without movement acts normally.
final class TabButton: NSButton {
    override class var cellClass: AnyClass? {
        get { TabButtonCell.self }
        set { }
    }

    var onDragBegan: ((TabButton) -> Void)?
    var onDragEnded: ((TabButton) -> Void)?

    override func mouseDown(with event: NSEvent) {
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
