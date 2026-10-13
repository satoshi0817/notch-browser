import Foundation
import XCTest
@testable import NotchBrowser

final class NotionSettingsHotfixTests: XCTestCase {
    #if DEBUG
    @MainActor func testThreeConnectionStatesKeepTaskSettingsReachable() async {
        let cases: [(NotionConnectionStore.PreviewState, Bool, Bool, Bool, String)] = [
            (.unconnected, false, false, false, "未接続"),
            (.connected, true, true, false, "接続済み"),
            (.unverified, false, true, true, "未確認"),
            (.verifying, false, true, true, "確認中"),
            (.invalid, false, true, true, "無効なトークン")
        ]
        for (state, enabled, tabVisible, retryVisible, label) in cases {
            let connection = NotionConnectionStore.preview(state: state)
            XCTAssertTrue(NotionTaskRules.settingsEntryVisible, "\(state)")
            XCTAssertEqual(NotionTaskRules.settingsEnabled(state: connection.state), enabled, "\(state)")
            XCTAssertEqual(NotionTaskRules.tabVisible(state: connection.state,
                                                      hasStoredToken: connection.hasStoredToken), tabVisible, "\(state)")
            XCTAssertEqual(connection.canReverify, retryVisible, "\(state)")
            XCTAssertEqual(connection.stateLabel, label)
            // The startup check must preserve the requested DEBUG state, without a keychain lookup.
            await connection.verifySaved()
            XCTAssertEqual(connection.stateLabel, label)
            XCTAssertEqual(connection.hasStoredToken, state != .unconnected)
            connection.disconnect()
            XCTAssertFalse(connection.hasStoredToken)
            XCTAssertFalse(connection.tokenValid)
            XCTAssertFalse(connection.canReverify)
        }
    }

    @MainActor func testNetworkFailureKeepsUnverifiedTabAndRetryEntry() async {
        var attempts = 0
        let connection = NotionConnectionStore.preview(state: .unverified, verification: {
            attempts += 1
            throw URLError(.notConnectedToInternet)
        })
        for expected in 1...2 {
            await connection.verifySaved()
            XCTAssertEqual(attempts, expected)
            XCTAssertFalse(connection.tokenValid)
            XCTAssertTrue(connection.hasStoredToken)
            XCTAssertEqual(connection.stateLabel, "未確認")
            XCTAssertTrue(connection.canReverify)
            XCTAssertFalse(connection.isChecking)
            XCTAssertNotNil(connection.message)
            XCTAssertEqual(connection.state, .unverified)
            XCTAssertFalse(connection.showsLoading)
            XCTAssertTrue(connection.message?.contains("未確認") == true)
            XCTAssertNotNil(connection.failureMessage)
            XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state, hasStoredToken: true))
            var openedSettings = false
            let notice = NotionConnectionNotice(connection: connection, onOpenSettings: { openedSettings = true })
            notice.openSettings()
            XCTAssertTrue(openedSettings)
            XCTAssertFalse(NotionTaskRules.settingsEnabled(state: connection.state))
            XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state,
                                                    hasStoredToken: connection.hasStoredToken))
        }
    }

    @MainActor func testSuccessfulReverificationEnablesTaskSettings() async {
        var attempts = 0
        let connection = NotionConnectionStore.preview(state: .unverified, verification: { attempts += 1 })
        await connection.verifySaved()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(connection.tokenValid)
        XCTAssertTrue(connection.hasStoredToken)
        XCTAssertTrue(NotionTaskRules.settingsEnabled(state: connection.state))
        XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state,
                                                hasStoredToken: connection.hasStoredToken))
        XCTAssertEqual(connection.stateLabel, "接続済み")
        XCTAssertFalse(connection.canReverify)
    }

    @MainActor func testCheckingKeepsTabVisibleAndIgnoresDuplicateReverification() async {
        var attempts = 0
        var connection: NotionConnectionStore!
        defer { connection = nil }
        connection = NotionConnectionStore.preview(state: .unverified, verification: {
            attempts += 1
            XCTAssertTrue(connection.isChecking)
            XCTAssertTrue(connection.showsLoading)
            XCTAssertEqual(connection.stateLabel, "確認中")
            XCTAssertTrue(connection.canReverify)
            XCTAssertFalse(NotionTaskRules.settingsEnabled(state: connection.state))
            XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state,
                                                    hasStoredToken: connection.hasStoredToken))
            await connection.verifySaved()
        })
        await connection.verifySaved()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(connection.isChecking)
        XCTAssertTrue(connection.tokenValid)
    }

    func testDebugConnectionArgumentParsesAllThreeStates() {
        for state in NotionConnectionStore.PreviewState.allCases {
            XCTAssertEqual(NotionConnectionStore.previewState(arguments: ["app", "--notion-connection=\(state.rawValue)"]), state)
        }
        XCTAssertNil(NotionConnectionStore.previewState(arguments: ["app"]))
        XCTAssertNil(NotionConnectionStore.previewState(arguments: ["app", "--notion-connection=unsupported"]))
    }

    func testDebugDefaultsSuiteArgumentKeepsWritesInNamedDomain() throws {
        let name = "NotionSettingsHotfixTests.Argument.\(UUID().uuidString)"
        let defaults = SettingsDefaults.make(arguments: ["app", "--defaults-suite=\(name)"])
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "previewIsolationProbe")
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["previewIsolationProbe"] as? Bool, true)
        XCTAssertTrue(SettingsDefaults.make(arguments: ["app"]) === UserDefaults.standard)
        XCTAssertTrue(SettingsDefaults.make(arguments: ["app", "--defaults-suite="]) === UserDefaults.standard)
    }
    #endif

    @MainActor func testPinnedTabsNotionSelectionRoutesToAgentsSettings() throws {
        let pinnedID = UUID()
        XCTAssertEqual(PinnedTabsSettings.editorKind(selection: PinnedTabsSettings.notionID,
                                                     pinnedIDs: [pinnedID]), .notionAgents)
        XCTAssertEqual(PinnedTabsSettings.editorKind(selection: pinnedID, pinnedIDs: [pinnedID]), .pinned)
        XCTAssertEqual(PinnedTabsSettings.editorKind(selection: nil, pinnedIDs: [pinnedID]), .empty)
        XCTAssertEqual(PinnedTabsSettings.editorKind(selection: UUID(), pinnedIDs: [pinnedID]), .empty)
        // Guard the actual view branch too: a correct routing rule alone would not detect
        // the old placeholder replacing NotionAgentsSettings.
        let source = try sourceFile("SettingsView.swift")
        let branch = try XCTUnwrap(source.range(of: "== .notionAgents {"))
        let remainder = source[branch.upperBound...]
        let end = try XCTUnwrap(remainder.range(of: "} else {"))
        XCTAssertTrue(remainder[..<end.lowerBound].contains("NotionAgentsSettings(onOpenSettings: onOpenConnection)"))
        XCTAssertFalse(source.contains("タブの中で設定できます"))
    }

    func testAppAndTabSettingsUseSameTaskViewAndStore() throws {
        let pinned = try sourceFile("SettingsView.swift")
        let tasks = try sourceFile("NotionTasksView.swift")
        let notion = try sourceFile("NotionSettingsView.swift")
        XCTAssertTrue(pinned.contains("NotionTasksSettingsPage(onOpenSettings: onOpenConnection)"))
        XCTAssertTrue(tasks.contains("NotionTasksSettingsPage(onOpenSettings: onOpenSettings)"))
        XCTAssertTrue(tasks.contains("Section(title)"))
        XCTAssertTrue(tasks.contains("private var store = NotionTasksStore.shared"))
        XCTAssertTrue(tasks.contains(".disabled(!NotionTaskRules.settingsEnabled(state: connection.state))"))
        XCTAssertFalse(tasks.contains("先に Notion に接続してください"))
        XCTAssertTrue(tasks.contains("タスクの既定フィルタ"))
        XCTAssertFalse(tasks.contains("Notion にログイン"))
        XCTAssertFalse(notion.contains("NotionTasksSettings"))
        XCTAssertTrue(notion.contains("Section(\"データベースの更新通知\")"))
    }

    func testBothTabsExposeReverificationBeforeOpeningGear() throws {
        let tasks = try sourceFile("NotionTasksView.swift")
        let agents = try sourceFile("NotionAgents.swift")
        for (source, panel) in [(tasks, "struct NotionTasksPanel"), (agents, "struct NotionAgentsPanel")] {
            let start = try XCTUnwrap(source.range(of: panel))
            let remainder = source[start.upperBound...]
            let notice = try XCTUnwrap(remainder.range(of: "NotionConnectionNotice(onOpenSettings: onOpenSettings)"))
            let gear = try XCTUnwrap(remainder.range(of: "if showingSettings"))
            XCTAssertLessThan(notice.lowerBound, gear.lowerBound)
        }
        XCTAssertTrue(tasks.contains("if connection.canReverify {"))
        XCTAssertTrue(tasks.contains("Button(\"再確認\") { Task { await connection.verifySaved() } }"))
        XCTAssertTrue(tasks.contains(".disabled(connection.isChecking)"))
        XCTAssertTrue(tasks.contains("Button(\"設定を開く\", action: openSettings)"))
        XCTAssertTrue(tasks.contains("func openSettings() { onOpenSettings() }"))
        XCTAssertTrue(try sourceFile("AppDelegate.swift").contains("self?.presentSettings(section: .notion)"))
        XCTAssertTrue(try sourceFile("BrowserViewController.swift").contains("self?.onOpenNotionSettings?()"))
        XCTAssertTrue(try sourceFile("BrowserViewController.swift").contains("hasStoredToken: notionConnection.hasStoredToken"))
    }

    func testAgentsSettingsMatchesTabSectionOrderWithConnectionGroup() throws {
        let source = try sourceFile("NotionAgents.swift")
        let start = try XCTUnwrap(source.range(of: "struct NotionAgentsSettings: View"))
        let remainder = source[start.upperBound...]
        let end = try XCTUnwrap(remainder.range(of: "private func saveBaseURL"))
        let body = remainder[..<end.lowerBound]
        var previous = body.startIndex
        for title in ["Notionで開く", "登録したエージェント", "名前で探す", "表示"] {
            let section = try XCTUnwrap(body.range(of: "Section(\"\(title)\")"))
            XCTAssertGreaterThanOrEqual(section.lowerBound, previous)
            previous = section.upperBound
        }
        let connection = try XCTUnwrap(body.range(of: "NotionTabConnectionSettings(onOpenSettings: onOpenSettings)"))
        let firstSection = try XCTUnwrap(body.range(of: "Section(\"Notionで開く\")"))
        XCTAssertLessThan(connection.lowerBound, firstSection.lowerBound)
        let appearance = try XCTUnwrap(body.range(of: "Picker(\"チャットの外観\""))
        let display = try XCTUnwrap(body.range(of: "Section(\"表示\")"))
        XCTAssertLessThan(display.lowerBound, appearance.lowerBound)
        XCTAssertFalse(body.contains("有効にするには、通常の設定画面"))
        XCTAssertFalse(body.contains(".safeAreaInset"))
        XCTAssertTrue(body.contains("Text(\"ベース URL\")"))
        XCTAssertTrue(body.contains("prompt: Text(\"https://app.dev.notion.com\")"))
    }

    @MainActor func testSettingsAndTaskConfigurationUseInjectedIsolatedDefaults() throws {
        let name = "NotionSettingsHotfixTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let pinnedID = UUID()
        settings.lastViewedPinnedID = pinnedID
        XCTAssertEqual(defaults.string(forKey: "lastViewedPinnedID"), pinnedID.uuidString)
        settings.data.notionEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).data.notionEnabled)
        let tasks = NotionTasksStore(defaults: defaults, tokenProvider: { nil })
        let url = "https://notion.so/0123456789abcdef0123456789abcdef"
        tasks.configuration.url = url
        XCTAssertEqual(NotionTasksStore(defaults: defaults, tokenProvider: { nil }).configuration.url, url)
        XCTAssertFalse(tasks.available)
    }

    #if DEBUG
    @MainActor func testPinnedPageListAlwaysContainsAgentsAndTasksInAllConnectionStates() {
        for state in NotionConnectionState.allCases {
            let connection = NotionConnectionStore.preview(state: state)
            let rows = PinnedTabsSettings.pageRows(pinnedTabs: [], notionPosition: 0)
            XCTAssertEqual(rows.map(\.id), [PinnedTabsSettings.notionID, PinnedTabsSettings.tasksID, PinnedTabsSettings.meetingsID], "\(state)")
            XCTAssertEqual(NotionTaskRules.settingsEnabled(state: connection.state), state == .connected)
            XCTAssertEqual(PinnedTabsSettings.editorKind(selection: PinnedTabsSettings.tasksID, pinnedIDs: []), .notionTasks)
        }
        let page = PinnedTab(name: "Example", url: "https://example.com")
        let rows = PinnedTabsSettings.pageRows(pinnedTabs: [page], notionPosition: 1)
        XCTAssertEqual(rows.map(\.id), [page.id, PinnedTabsSettings.notionID, PinnedTabsSettings.tasksID, PinnedTabsSettings.meetingsID])
    }

    @MainActor func testUnauthorizedSavedTokenKeepsBothTabsWithErrorAndRecoveryActions() async {
        let connection = NotionConnectionStore.preview(state: .unverified, verification: {
            throw NotionAPIError.server(401, "unauthorized")
        })
        await connection.verifySaved()
        XCTAssertEqual(connection.state, .invalid)
        XCTAssertTrue(connection.hasStoredToken)
        XCTAssertFalse(connection.tokenValid)
        XCTAssertFalse(connection.showsLoading)
        XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state, hasStoredToken: connection.hasStoredToken))
        XCTAssertFalse(NotionTaskRules.settingsEnabled(state: connection.state))
        XCTAssertEqual(PinnedTabsSettings.pageRows(pinnedTabs: [], notionPosition: 0).count, 3)
        XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state, hasStoredToken: true))
        XCTAssertTrue(connection.failureMessage?.contains("トークンが無効です") == true)
        XCTAssertTrue(connection.canReverify)
        var openedSettings = false
        let notice = NotionConnectionNotice(connection: connection, onOpenSettings: { openedSettings = true })
        notice.openSettings()
        XCTAssertTrue(openedSettings)
    }

    @MainActor func testSavedTokenVerifyingShowsTabsAndLoading() async {
        let connection = NotionConnectionStore.preview(state: .verifying)
        XCTAssertTrue(connection.hasStoredToken)
        XCTAssertTrue(connection.isChecking)
        XCTAssertTrue(connection.showsLoading)
        XCTAssertTrue(NotionTaskRules.tabVisible(state: connection.state, hasStoredToken: connection.hasStoredToken))
        XCTAssertFalse(NotionTaskRules.settingsEnabled(state: connection.state))
        XCTAssertFalse(NotionTaskRules.tabVisible(state: .verifying, hasStoredToken: false))
        XCTAssertFalse(NotionTaskRules.showsConnectionLoading(state: .verifying, hasStoredToken: false))
        await connection.verifySaved()
        XCTAssertEqual(connection.state, .verifying, "Startup verification must preserve screenshot fixtures")
    }

    @MainActor func testScreenshotArgumentsSelectPaneAndPinnedPage() throws {
        for pane in ["pinned", "notion"] {
            for selection in PinnedPageSelection.allCases {
                let launch = try XCTUnwrap(SettingsPreviewLaunch.parse(arguments:
                    ["app", "--settings-pane=\(pane)", "--pinned-selection=\(selection.rawValue)"]))
                XCTAssertEqual(launch.section, pane == "pinned" ? .tabs : .notion)
                XCTAssertEqual(launch.selection, selection)
            }
        }
        XCTAssertNil(SettingsPreviewLaunch.parse(arguments: ["app"]))
        XCTAssertNil(SettingsPreviewLaunch.parse(arguments: ["app", "--settings-pane=unsupported"]))
    }

    @MainActor func testNotionPanePinnedLinkInvokesNavigationInAllConnectionStates() {
        for state in NotionConnectionState.allCases {
            var destination: SettingsSection?
            let view = NotionSettingsView(connection: .preview(state: state), onOpenPinnedPages: {
                destination = NotionSettingsView.pageSettingsDestination
            })
            view.openPinnedPages()
            XCTAssertEqual(destination, .tabs, "\(state)")
        }
    }
    #endif

    @MainActor func testUnselectedPinnedPagePlaceholderAndFullHeightBorderedList() throws {
        XCTAssertEqual(PinnedTabsSettings.emptySelectionMessage, "固定ページを選ぶと設定が表示されます")
        XCTAssertEqual(PinnedTabsSettings.connectionRequiredMessage, "先に Notion に接続してください")
        let source = try sourceFile("SettingsView.swift")
        XCTAssertTrue(source.contains("Text(Self.emptySelectionMessage)"))
        XCTAssertTrue(source.contains(".listStyle(.plain)"))
        XCTAssertTrue(source.contains(".frame(width: 200)"))
        XCTAssertTrue(source.contains(".overlay(Rectangle().stroke"))
        XCTAssertFalse(source.contains("selection = selection ??"))
        let list = try XCTUnwrap(source.range(of: "List(selection: $selection)"))
        let plus = try XCTUnwrap(source.range(of: "Button { add() }"))
        XCTAssertLessThan(list.lowerBound, plus.lowerBound)
        XCTAssertTrue(try sourceFile("NotionAgents.swift").contains(".disabled(!NotionTaskRules.settingsEnabled(state: connection.state))"))
        XCTAssertFalse(try sourceFile("NotionAgents.swift").contains("Text(PinnedTabsSettings.connectionRequiredMessage)"))
    }

    @MainActor func testNotionPaneHasConnectionAndDatabaseNotificationsAndNavigatesToPinnedPages() throws {
        XCTAssertEqual(NotionSettingsView.pageSettingsHint, "タスクと議事録は［固定ページ］で設定します")
        XCTAssertEqual(NotionSettingsView.pageSettingsDestination, .tabs)
        let notion = try sourceFile("NotionSettingsView.swift")
        XCTAssertTrue(notion.contains("SecureField"))
        XCTAssertTrue(notion.contains("Text(Self.pageSettingsHint)"))
        XCTAssertTrue(notion.contains("Button(\"固定ページの設定を開く\", action: openPinnedPages)"))
        XCTAssertTrue(notion.contains("func openPinnedPages() { onOpenPinnedPages() }"))
        XCTAssertFalse(notion.contains("NotionTasksSettings"))
        XCTAssertFalse(notion.contains("NotionAgentsSettings"))
        XCTAssertTrue(try sourceFile("SettingsView.swift").contains(
            "NotionSettingsView(onOpenPinnedPages: { section = NotionSettingsView.pageSettingsDestination })"))
    }

    func testBothTabListRegionsRenderConnectionLoading() throws {
        for name in ["NotionTasksView.swift", "NotionAgents.swift"] {
            let source = try sourceFile(name)
            XCTAssertTrue(source.contains("else if connection.showsLoading {"))
            XCTAssertTrue(source.contains("NotionConnectionLoading().frame(maxWidth: .infinity, maxHeight: .infinity)"))
        }
        let tasks = try sourceFile("NotionTasksView.swift")
        XCTAssertTrue(tasks.contains("ProgressView()"))
        XCTAssertTrue(tasks.contains("Text(connection.bannerTitle).foregroundStyle(.primary)"))
        XCTAssertTrue(tasks.contains("Text(connection.bannerDetail).font(.caption).foregroundStyle(.secondary)"))
        XCTAssertTrue(tasks.contains("exclamationmark.triangle.fill"))
    }

    func testAllVerificationFailuresKeepTabsWithDistinctUnauthorizedMessage() {
        XCTAssertEqual(NotionTaskRules.connectionState(after: NotionAPIError.server(401, "unauthorized")), .invalid)
        for error in [NotionAPIError.server(403, "forbidden"), .server(429, "rate limit"), .server(500, "server error"), .invalidResponse] {
            XCTAssertEqual(NotionTaskRules.connectionState(after: error), .unverified)
        }
        XCTAssertEqual(NotionTaskRules.connectionState(after: URLError(.timedOut)), .unverified)
        for state in NotionConnectionState.allCases {
            XCTAssertTrue(NotionTaskRules.tabVisible(state: state, hasStoredToken: true))
            XCTAssertFalse(NotionTaskRules.tabVisible(state: state, hasStoredToken: false))
        }
        for state in [NotionConnectionState.invalid, .unverified] {
            XCTAssertTrue(NotionTaskRules.showsConnectionError(state: state, hasStoredToken: true))
            XCTAssertTrue(NotionTaskRules.showsReverificationEntry(state: state, hasStoredToken: true))
            XCTAssertTrue(NotionTaskRules.tabVisible(state: state, hasStoredToken: true))
            XCTAssertFalse(NotionTaskRules.tabVisible(state: state, hasStoredToken: false))
        }
    }

    func testMissingTokenHidesTabsAndRecoveryNoticeInAllStates() {
        for state in NotionConnectionState.allCases {
            XCTAssertFalse(NotionTaskRules.tabVisible(state: state, hasStoredToken: false))
            XCTAssertFalse(NotionTaskRules.showsConnectionError(state: state, hasStoredToken: false))
            XCTAssertFalse(NotionTaskRules.showsReverificationEntry(state: state, hasStoredToken: false))
            XCTAssertFalse(NotionTaskRules.showsConnectionLoading(state: state, hasStoredToken: false))
        }
    }

    func testAgentFeatureSwitchHidesOnlyAgentsAcrossConnectionStates() {
        for state in NotionConnectionState.allCases {
            XCTAssertTrue(NotionTaskRules.tabVisible(state: state, hasStoredToken: true))
            XCTAssertTrue(NotionTaskRules.agentTabVisible(state: state, hasStoredToken: true, enabled: true))
            XCTAssertFalse(NotionTaskRules.agentTabVisible(state: state, hasStoredToken: true, enabled: false))
            XCTAssertFalse(NotionTaskRules.agentTabVisible(state: state, hasStoredToken: false, enabled: true))
        }
    }

    #if DEBUG
    @MainActor func testEmptyStateSettingsButtonIsSuppressedOnlyWhenBannerIsVisible() throws {
        for state in NotionConnectionState.allCases {
            let connection = NotionConnectionStore.preview(state: state)
            let bannerVisible = [.verifying, .invalid, .unverified].contains(state)
            XCTAssertEqual(connection.canReverify, bannerVisible, "\(state)")
            XCTAssertEqual(connection.showsEmptySettingsButton, !bannerVisible, "\(state)")
        }
        // Both empty-state settings entries use the same rule; the banner keeps its action.
        for name in ["NotionTasksView.swift", "NotionAgents.swift"] {
            let source = try sourceFile(name)
            XCTAssertTrue(source.contains("if connection.showsEmptySettingsButton {\n                        NotionTabEmptySettingsButton { showingSettings = true }"))
        }
        let agents = try sourceFile("NotionAgents.swift")
        XCTAssertTrue(agents.contains("if connection.showsEmptySettingsButton {\n                        Button(\"Notion設定を開く\", action: onOpenSettings)"))
        let tasks = try sourceFile("NotionTasksView.swift")
        XCTAssertTrue(tasks.contains("Button(\"設定を開く\", action: openSettings)"))
    }
    #endif

    func testNotionPaneRestoresDatabaseNotificationControlsAndAgentEnableButton() throws {
        let source = try sourceFile("NotionSettingsView.swift")
        let connection = try XCTUnwrap(source.range(of: "Section(\"Notion接続\")"))
        let notifications = try XCTUnwrap(source.range(of: "Section(\"データベースの更新通知\")"))
        let pageLink = try XCTUnwrap(source.range(of: "Text(Self.pageSettingsHint)"))
        XCTAssertLessThan(connection.lowerBound, notifications.lowerBound)
        XCTAssertLessThan(notifications.lowerBound, pageLink.lowerBound)
        for control in [
            "データベース更新をノッチで通知", "通知を閉じるまで",
            "NotionのデータベースURLまたはID", "ForEach(settings.data.notionDatabases)",
            "Toggle(database.name", "removeDatabase(database.id)", "プロパティを再取得",
            "ForEach(DatabasePollingFrequency.allCases)", "frequencyCard(frequency)",
            "pollingFrequency = .matching(settings.data.notionDatabasePollingSeconds)",
            "if connection.tokenValid && !settings.data.notionEnabled",
            "カスタムエージェントを有効にする", "settings.data.notionEnabled = true"
        ] {
            XCTAssertTrue(source.contains(control), control)
        }
        for function in ["frequencyCard", "savePollingDraft", "currentDatabase", "updateDatabase",
                         "removeDatabase", "addDatabase", "loadProperties"] {
            XCTAssertTrue(source.contains("private func " + function), function)
        }
        XCTAssertTrue(source.contains("static func matching(_ seconds: Int) -> Self"))
        XCTAssertTrue(source.contains("min(300, max(30, value))"))
        XCTAssertTrue(source.contains("$settings.data.notionDatabaseNotificationsEnabled"))
        XCTAssertTrue(source.contains("$settings.data.notionDatabaseNotificationDuration"))
        XCTAssertTrue(source.contains("settings.data.notionDatabasePollingSeconds"))
        XCTAssertFalse(source.contains("NotionTasksSettings"))
    }

    #if DEBUG
    func testDesignPreviewSelectTabArgumentsAndConnectionFixturesAreWired() throws {
        for tab in NotionPreviewTab.allCases {
            XCTAssertEqual(NotionPreviewTab.parse(arguments: ["preview", "--select-tab=\(tab.rawValue)"]), tab)
        }
        XCTAssertNil(NotionPreviewTab.parse(arguments: ["preview"]))
        XCTAssertNil(NotionPreviewTab.parse(arguments: ["preview", "--select-tab=unsupported"]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/DesignPreview.swift"), encoding: .utf8)
        XCTAssertTrue(script.contains("NotionPreviewTab.parse(arguments: CommandLine.arguments)"))
        XCTAssertTrue(script.contains("NotionConnectionStore.launchPreviewState"))
        XCTAssertTrue(script.contains("case .tasks: manager.browser.showTasks()"))
        XCTAssertTrue(script.contains("case .agents: manager.browser.showNotion()"))
    }
    #endif

    #if DEBUG
    @MainActor func testUnconnectedAgentToggleIsOffDisabledWithoutChangingSavedPreference() throws {
        let name = "AgentTogglePreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        for saved in [true, false] {
            for state in NotionConnectionState.allCases {
                settings.data.notionEnabled = saved
                let connection = NotionConnectionStore.preview(state: state)
                let binding = NotionAgentsSettings.enabledBinding(settings: settings, connection: connection)
                XCTAssertEqual(binding.wrappedValue, state == .connected && saved)
                XCTAssertEqual(NotionTaskRules.settingsEnabled(state: state), state == .connected)
                if state != .connected {
                    binding.wrappedValue = true
                    binding.wrappedValue = false
                    XCTAssertEqual(settings.data.notionEnabled, saved)
                    XCTAssertEqual(SettingsStore(defaults: defaults).data.notionEnabled, saved)
                }
            }
        }
        let source = try sourceFile("NotionAgents.swift")
        XCTAssertTrue(source.contains("isOn: Self.enabledBinding(settings: settings, connection: connection)"))
        XCTAssertTrue(source.contains(".disabled(!connection.tokenValid)"))
    }
    #endif

    func testTaskChecklistNoteAndExpandedURLField() throws {
        for connected in [true, false] {
            let checklist = NotionTaskRules.checklist(tokenValid: connected, checking: false, url: "", confirmedURL: nil)
            XCTAssertEqual(checklist.hint, "2つそろうと、ノッチにタスクのタブが表示されます")
        }
        let source = try sourceFile("NotionTasksView.swift")
        XCTAssertFalse(source.contains("先に Notion に接続してください"))
        XCTAssertTrue(source.contains(".frame(minWidth: 0, maxWidth: .infinity)"))
        XCTAssertTrue(source.contains(".layoutPriority(1)"))
        XCTAssertTrue(source.contains("Section(\"接続\")"))
        XCTAssertTrue(source.contains("「Notion 接続」の設定を開く"))
    }

    func testPinnedPagesSidebarUsesFixedWidthWithoutSplitResize() throws {
        let source = try sourceFile("SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "struct PinnedTabsSettings: View"))
        let remainder = source[start.upperBound...]
        let end = try XCTUnwrap(remainder.range(of: "struct PinnedTabEditor"))
        let body = remainder[..<end.lowerBound]
        XCTAssertTrue(body.contains("HStack(spacing: 0)"))
        XCTAssertTrue(body.contains(".frame(width: 200)"))
        XCTAssertTrue(body.contains(".frame(maxHeight: .infinity)"))
        XCTAssertFalse(body.contains("HSplitView"))
        XCTAssertFalse(body.contains("idealWidth: 200"))
    }

    #if DEBUG
    @MainActor func testConnectionErrorBannerCopyAndHiddenListContent() throws {
        let cases: [(NotionConnectionState, String, String)] = [
            (.invalid, "Notion のトークンが無効です", "設定を開いて、トークンを入れ直してください"),
            (.unverified, "Notion に接続できませんでした", "ネットワークを確認して、再確認してください")
        ]
        for (state, title, detail) in cases {
            let connection = NotionConnectionStore.preview(state: state)
            XCTAssertTrue(connection.showsConnectionError)
            XCTAssertEqual(connection.bannerTitle, title)
            XCTAssertEqual(connection.bannerDetail, detail)
            XCTAssertTrue(connection.canReverify)
            XCTAssertFalse(connection.showsEmptySettingsButton)
        }
        for state in [NotionConnectionState.unconnected, .verifying, .connected] {
            XCTAssertFalse(NotionConnectionStore.preview(state: state).showsConnectionError)
        }
        for name in ["NotionTasksView.swift", "NotionAgents.swift"] {
            let source = try sourceFile(name)
            XCTAssertTrue(source.contains("if connection.showsConnectionError {\n                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)"))
            let gear = try XCTUnwrap(source.range(of: "@ViewBuilder private var settingsButton"))
            let remainder = source[gear.upperBound...]
            XCTAssertTrue(remainder.hasPrefix(": some View {\n        if !connection.showsConnectionError {"))
            XCTAssertTrue(source.contains("else if !connection.showsConnectionError &&"))
        }
        let tasks = try sourceFile("NotionTasksView.swift")
        let start = try XCTUnwrap(tasks.range(of: "struct NotionConnectionNotice:"))
        let end = try XCTUnwrap(tasks.range(of: "struct NotionTasksSettingsPage:"))
        let banner = tasks[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(banner.contains("Image(systemName: \"exclamationmark.triangle.fill\")\n                        .foregroundStyle(.orange)"))
        XCTAssertFalse(banner.contains("Text(message)"))
        XCTAssertTrue(banner.contains("Text(connection.bannerTitle).foregroundStyle(.primary)"))
        XCTAssertTrue(banner.contains("Text(connection.bannerDetail).font(.caption).foregroundStyle(.secondary)"))
        XCTAssertTrue(banner.contains("Button(\"再確認\")"))
        XCTAssertTrue(banner.contains("Button(\"設定を開く\", action: openSettings)"))
    }
    #endif

    func testAgentRegistrationLabelUsesSingleLineDisplay() throws {
        let source = try sourceFile("NotionAgents.swift")
        XCTAssertTrue(source.contains("Text(\"エージェントの URL または ID\")\n                            .fixedSize(horizontal: true, vertical: false).lineLimit(1)"))
        XCTAssertTrue(source.contains(".labelsHidden().accessibilityLabel(\"エージェントの URL または ID\")"))
        XCTAssertFalse(source.contains("TextField(\"NotionのエージェントURLまたはID\""))
    }

    private func sourceFile(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/NotchBrowser/\(name)"), encoding: .utf8)
    }
}
