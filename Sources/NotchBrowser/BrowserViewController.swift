import AppKit
import WebKit

final class Tab {
    /// Set when the tab is pinned; its name, icon and profile come from settings.
    var pinnedID: UUID?
    var profileID: UUID
    /// The pinned URL last loaded, to notice when it's edited in settings.
    var homeURL: String?
    private(set) var webView: WKWebView
    var observations: [NSKeyValueObservation] = []

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

    private let tabStack = NSStackView()
    private let controlStack = NSStackView()
    private let webContainer = NSView()
    private let addressField = NSTextField()
    private lazy var backButton = iconButton("chevron.left", "戻る", #selector(goBack))
    private lazy var forwardButton = iconButton("chevron.right", "進む", #selector(goForward))
    private lazy var reloadButton = iconButton("arrow.clockwise", "再読み込み", #selector(reloadOrStop))
    private lazy var keepOpenButton = iconButton("pin", "開いたままにする", #selector(toggleKeepOpen))
    private lazy var externalButton = iconButton("safari", "デフォルトブラウザで開く", #selector(openExternally))
    private lazy var settingsButton = iconButton("gearshape", "設定 (⌘,)", #selector(openSettings))
    private lazy var quitButton = iconButton("power", "NotchBrowser を終了 (⌘Q)", #selector(NSApplication.terminate(_:)), target: NSApp)

    private var tabTrailingConstraint: NSLayoutConstraint?
    private var controlLeadingConstraint: NSLayoutConstraint?
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

        tabStack.orientation = .horizontal
        tabStack.spacing = 4
        controlStack.orientation = .horizontal
        controlStack.spacing = 2

        addressField.placeholderString = "検索またはURLを入力"
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .small
        addressField.font = .systemFont(ofSize: 12)
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for button in [backButton, forwardButton, reloadButton] { controlStack.addArrangedSubview(button) }
        controlStack.addArrangedSubview(addressField)
        for button in [keepOpenButton, externalButton, settingsButton, quitButton] { controlStack.addArrangedSubview(button) }

        webContainer.wantsLayer = true
        webContainer.layer?.cornerRadius = 10
        webContainer.layer?.masksToBounds = true
        webContainer.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        for sub in [tabStack, controlStack, webContainer] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }

        let tabTrailing = tabStack.trailingAnchor.constraint(lessThanOrEqualTo: view.centerXAnchor, constant: -110)
        let controlLeading = controlStack.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 110)
        let tabHeight = tabStack.heightAnchor.constraint(equalToConstant: 32)
        let controlHeight = controlStack.heightAnchor.constraint(equalToConstant: 32)
        let containerTop = webContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 32)
        tabTrailingConstraint = tabTrailing
        controlLeadingConstraint = controlLeading
        stripHeightConstraints = [tabHeight, controlHeight, containerTop]

        NSLayoutConstraint.activate([
            tabStack.topAnchor.constraint(equalTo: view.topAnchor),
            tabStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            tabTrailing, tabHeight,
            controlStack.topAnchor.constraint(equalTo: view.topAnchor),
            controlStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            controlLeading, controlHeight,
            containerTop,
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        syncPinnedTabs()
        selectInitialTab()

        NotificationCenter.default.addObserver(forName: .faviconUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.chromeNeedsUpdate()
        }
    }

    /// Tabs go left of the notch, navigation goes right of it.
    func updateNotchMetrics(notchWidth: CGFloat, stripHeight: CGFloat) {
        _ = view
        let gap = notchWidth / 2 + 12
        tabTrailingConstraint?.constant = -gap
        controlLeadingConstraint?.constant = gap
        for constraint in stripHeightConstraints { constraint.constant = stripHeight }
    }

    func focusContent() {
        if let tab = selectedTab, tab.webView.url != nil {
            view.window?.makeFirstResponder(tab.webView)
        } else {
            focusAddressBar()
        }
    }

    func settingsChanged() {
        guard isViewLoaded else { return }
        syncPinnedTabs()
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
        selectedIndex = index
        if let index, let id = tabs[index].pinnedID { store.lastViewedPinnedID = id }
        for (i, tab) in tabs.enumerated() { tab.webView.isHidden = i != index }
        updateChrome()
    }

    private func select(_ tab: Tab) {
        select(tabs.firstIndex { $0 === tab })
    }

    private func closeTab(at index: Int) {
        let tab = tabs.remove(at: index)
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
        FaviconCache.shared.fetch(from: tab.webView)
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
        externalButton.isEnabled = webView?.url != nil

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
        tabStack.addArrangedSubview(iconButton("plus", "新規タブ (⌘T)", #selector(newTab)))
    }

    private func contextMenu(for tab: Tab, at index: Int) -> NSMenu {
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, _ action: Selector, to menu: NSMenu = menu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
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
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: Navigation

    @objc func focusAddressBar(_ sender: Any? = nil) {
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressSubmitted(_ sender: NSTextField) {
        guard let url = Self.url(from: sender.stringValue) else { return }
        if let tab = selectedTab {
            tab.webView.load(URLRequest(url: url))
        } else {
            openInNewTab(url)
        }
        if let webView = selectedTab?.webView { view.window?.makeFirstResponder(webView) }
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
        FaviconCache.shared.fetch(from: webView)
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
