import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import NotchBrowser

final class NotionAgentsTests: XCTestCase {
    func testMessagesSortByActualTimeAcrossFractionalAndWholeSecondTimestamps() throws {
        func message(_ id: String, _ time: String) throws -> NotionMessage {
            try JSONDecoder().decode(NotionMessage.self, from: Data("""
            {"id":"\(id)","role":"assistant","content":"text","created_time":"\(time)"}
            """.utf8))
        }
        let later = try message("later", "2026-09-30T12:00:01Z")
        let earlier = try message("earlier", "2026-09-30T12:00:00.900Z")
        XCTAssertEqual(NotionMessage.oldestFirst([later, earlier]).map(\.id), ["earlier", "later"])
    }

    func testSentMessageStaysPendingUntilMatchingUserEventArrives() {
        let pending = NotionMessage(id: "pending", role: "user", content: "質問です",
                                    created_time: "2026-10-01T01:00:00Z", pending_user_actions: nil)
        XCTAssertTrue(NotionMessage(id: "server", role: "user", content: "質問です",
                                    created_time: "2026-10-01T01:00:00.500Z", pending_user_actions: nil)
            .confirms(pending))
        XCTAssertFalse(NotionMessage(id: "old", role: "user", content: "質問です",
                                     created_time: "2026-09-30T00:00:00Z", pending_user_actions: nil)
            .confirms(pending))
        XCTAssertFalse(NotionMessage(id: "agent", role: "agent", content: "質問です",
                                     created_time: "2026-10-01T01:00:01Z", pending_user_actions: nil)
            .confirms(pending))
    }

    private func response(_ request: URLRequest, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testOldSettingsKeepNotionDefaultsAndNewPreferencesRoundTrip() throws {
        var settings = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.notionHiddenAgentIDs.isEmpty)
        XCTAssertTrue(settings.notionSavedAgents.isEmpty)
        XCTAssertTrue(settings.notionEnabled)
        XCTAssertEqual(settings.notionTabDisplay, .iconAndTitle)
        XCTAssertTrue(settings.notionNotificationsEnabled)
        XCTAssertEqual(settings.notionNotificationDuration, 10)
        XCTAssertEqual(settings.notionAppearance, .system)
        XCTAssertEqual(settings.notionTabPosition, settings.pinnedTabs.count)
        settings.notionHiddenAgentIDs.insert("agent-1")
        settings.notionNotificationsEnabled = false
        settings.notionNotificationDuration = 30
        settings.notionTabPosition = 1
        settings.notionSavedAgents = [SavedNotionAgent(id: "agent-1", name: "Writer")]
        settings.notionEnabled = false
        settings.notionTabDisplay = .titleOnly
        settings.notionAppearance = .dark
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.notionHiddenAgentIDs, ["agent-1"])
        XCTAssertFalse(restored.notionNotificationsEnabled)
        XCTAssertEqual(restored.notionNotificationDuration, 30)
        XCTAssertEqual(restored.notionTabPosition, 1)
        XCTAssertEqual(restored.notionSavedAgents, [SavedNotionAgent(id: "agent-1", name: "Writer")])
        XCTAssertFalse(restored.notionEnabled)
        XCTAssertEqual(restored.notionTabDisplay, .titleOnly)
        XCTAssertEqual(restored.notionAppearance, .dark)
    }

    func testNotionChatPaletteHasDistinctReadableLightAndDarkColors() {
        var light: NSColor!
        var dark: NSColor!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            light = NotionPanelTheme.text.usingColorSpace(.deviceRGB)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = NotionPanelTheme.text.usingColorSpace(.deviceRGB)
        }
        XCTAssertLessThan(light.brightnessComponent, dark.brightnessComponent)
        var lightLink: NSColor!
        var darkLink: NSColor!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            lightLink = NotionPanelTheme.link.usingColorSpace(.deviceRGB)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            darkLink = NotionPanelTheme.link.usingColorSpace(.deviceRGB)
        }
        XCTAssertNotEqual(lightLink, darkLink)
    }

    func testNotionTabIconUsesTheSuppliedLightAndDarkAssets() {
        XCTAssertEqual(NotionTabIcon.assetName(for: NSAppearance(named: .aqua)!), "NotionAgentIcon-Light")
        XCTAssertEqual(NotionTabIcon.assetName(for: NSAppearance(named: .darkAqua)!), "NotionAgentIcon-Dark")
    }

    @MainActor
    func testTurningNotionOffStopsPanelPollingWithoutRemovingSavedAgents() {
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.notionSavedAgents = [SavedNotionAgent(id: "agent-1", name: "Writer")]
        settings.data.notionEnabled = false
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotionAgentsCache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = NotionAgentsStore(tokenProvider: { "test-token" },
            pendingRepliesKey: "notion-off-test-\(UUID().uuidString)", cache: NotionAgentsCache(url: cacheURL))
        store.start()
        store.setPanelVisible(true)
        XCTAssertFalse(store.isPolling)
        XCTAssertEqual(store.visibleAgents.map(\.id), ["agent-1"])
    }

    func testPollingAndNotificationOnlyFollowLocallyPendingThreads() {
        XCTAssertFalse(NotionReplyTracking.shouldPoll(hasToken: true, panelVisible: false, pendingCount: 0))
        XCTAssertTrue(NotionReplyTracking.shouldPoll(hasToken: true, panelVisible: true, pendingCount: 0))
        XCTAssertTrue(NotionReplyTracking.shouldPoll(hasToken: true, panelVisible: false, pendingCount: 1))
        XCTAssertFalse(NotionReplyTracking.shouldPoll(hasToken: false, panelVisible: true, pendingCount: 1))
        XCTAssertNil(NotionReplyTracking.notificationTitle(status: "completed", baselineSignature: nil,
            currentSignature: "completed:new", reply: nil), "Thread completion alone must not stop polling")
        XCTAssertNil(NotionReplyTracking.notificationTitle(status: "completed", baselineSignature: "completed:old",
            currentSignature: "completed:old", reply: nil))
        XCTAssertNil(NotionReplyTracking.notificationTitle(status: "in_progress", baselineSignature: "completed:old",
            currentSignature: "in_progress:new", reply: nil))
        XCTAssertEqual(NotionReplyTracking.notificationTitle(status: "requires_action", baselineSignature: nil,
            currentSignature: "requires_action:new", reply: nil), "確認が必要です")
        XCTAssertTrue(NotionReplyTracking.hasStoppedWithoutReply(status: "failed"))
        XCTAssertFalse(NotionReplyTracking.hasStoppedWithoutReply(status: "in_progress"))
    }

    func testDeliveredReplyAndStaleStatusDoNotKeepTheAgentBusy() {
        let now = NotionMessage.parseDate("2026-10-01T04:00:00Z")!
        let recent = NotionThread(id: "thread", title: "Chat", status: "in_progress",
                                  last_edited_time: "2026-10-01T03:59:00Z", pending_user_actions: nil)
        let stale = NotionThread(id: "thread", title: "Chat", status: "in_progress",
                                 last_edited_time: "2026-10-01T03:00:00Z", pending_user_actions: nil)
        let question = NotionMessage(id: "question", role: "user", content: "質問",
                                     created_time: "2026-10-01T03:59:01Z", pending_user_actions: nil)
        let answer = NotionMessage(id: "answer", role: "agent", content: "回答",
                                   created_time: "2026-10-01T03:59:02Z", pending_user_actions: nil)
        XCTAssertTrue(NotionAgentActivity.isBusy(recent, waitingForReply: true,
                                                 cachedMessages: [question, answer], now: now))
        XCTAssertTrue(NotionAgentActivity.isBusy(recent, waitingForReply: false,
                                                 cachedMessages: [question], now: now))
        XCTAssertFalse(NotionAgentActivity.isBusy(recent, waitingForReply: false,
                                                  cachedMessages: [question, answer], now: now))
        XCTAssertFalse(NotionAgentActivity.isBusy(stale, waitingForReply: false,
                                                  cachedMessages: [], now: now))
        XCTAssertFalse(NotionReplyTracking.completedWaitExpired(status: "completed",
            sentAt: now.addingTimeInterval(-29 * 60), now: now))
        XCTAssertTrue(NotionReplyTracking.completedWaitExpired(status: "completed",
            sentAt: now.addingTimeInterval(-30 * 60), now: now))
        XCTAssertFalse(NotionReplyTracking.completedWaitExpired(status: "in_progress",
            sentAt: now.addingTimeInterval(-60 * 60), now: now))
    }

    func testReplyTrackingWaitsForTheAnswerToOurQuestion() {
        let sentAt = ISO8601DateFormatter().date(from: "2026-10-01T02:00:00Z")!
        let ownHash = NotionReplyTracking.fingerprint("自分の質問")
        let messages = [
            NotionMessage(id: "old-user", role: "user", content: "他人の質問",
                          created_time: "2026-10-01T01:59:00Z", pending_user_actions: nil),
            NotionMessage(id: "old-reply", role: "agent", content: "前の返信",
                          created_time: "2026-10-01T01:59:05Z", pending_user_actions: nil),
            NotionMessage(id: "own-user", role: "user", content: "自分の質問",
                          created_time: "2026-10-01T02:00:01Z", pending_user_actions: nil),
        ]
        XCTAssertNil(NotionReplyTracking.reply(in: messages, messageFingerprint: ownHash,
                                               sentAt: sentAt, baselineSignature: nil))
        let otherQuestion = NotionMessage(id: "other-user", role: "user", content: "別の質問",
                                          created_time: "2026-10-01T02:00:05Z", pending_user_actions: nil)
        let answer = NotionMessage(id: "own-reply", role: "agent", content: "回答",
                                   created_time: "2026-10-01T02:00:10Z", pending_user_actions: nil)
        XCTAssertNil(NotionReplyTracking.reply(in: messages + [otherQuestion, answer],
            messageFingerprint: ownHash, sentAt: sentAt, baselineSignature: nil),
            "Another user's later question must not turn its answer into our notification")
        XCTAssertEqual(NotionReplyTracking.reply(in: messages + [answer], messageFingerprint: ownHash,
                                                sentAt: sentAt, baselineSignature: nil)?.id, answer.id)
        XCTAssertEqual(NotionReplyTracking.notificationTitle(status: nil, baselineSignature: nil,
            currentSignature: nil, reply: answer), "返信が届きました",
            "A reply must be noticed even when the thread falls outside the first history page")
    }

    func testPendingReplySavedByPreviousReleaseStillLoads() {
        let key = "notion-legacy-poll-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(Data("""
        {"agent-1:thread-1":{"agentID":"agent-1","threadID":"thread-1","baselineSignature":null}}
        """.utf8), forKey: key)
        let store = NotionAgentsStore(tokenProvider: { nil }, pendingRepliesKey: key)
        XCTAssertEqual(store.pendingReplyCount, 1)
    }

    @MainActor
    func testCachedHistoryAndNotificationConversationAppearBeforeNetwork() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotionAgentsCache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = NotionAgentsCache(url: url)
        let thread = NotionThread(id: "thread-1", title: "以前のチャット", status: "completed",
                                  last_edited_time: "2026-10-01T02:00:00Z", pending_user_actions: nil)
        let reply = NotionMessage(id: "reply-1", role: "agent", content: "届いた返信",
                                  created_time: "2026-10-01T02:00:00Z", pending_user_actions: nil)
        cache.rememberThreads([thread], agentID: "agent-1")
        cache.rememberMessages([reply], agentID: "agent-1", threadID: thread.id)
        let restored = NotionAgentsCache(url: url)
        XCTAssertEqual(restored.threads(for: "agent-1").map(\.id), [thread.id])
        XCTAssertEqual(restored.messages(for: thread.id).map(\.id), [reply.id])
        XCTAssertEqual(restored.rememberThreads([], agentID: "agent-1").map(\.id), [thread.id])
        XCTAssertEqual(restored.rememberMessages([], agentID: "agent-1", threadID: thread.id).map(\.id), [reply.id])
        let store = NotionAgentsStore(tokenProvider: { nil },
            pendingRepliesKey: "notion-cache-test-\(UUID().uuidString)", cache: restored)
        store.openThread(agentID: "agent-1", threadID: thread.id)
        XCTAssertEqual(store.threads.map(\.id), [thread.id])
        XCTAssertEqual(store.visibleMessages.map(\.id), [reply.id])
    }

    func testPendingMessageIsOrderedBeforeItsReplyAndRemovedAfterServerConfirmation() {
        let baseline = NotionMessage.parseDate("2026-10-01T02:00:00Z")!
        let pending = NotionAgentsStore.PendingOutbound(
            message: NotionMessage(id: "pending", role: "user", content: "質問",
                                   created_time: "2026-10-01T02:00:10Z", pending_user_actions: nil),
            agentID: "agent-1", threadID: "thread-1", baselineTime: baseline,
            knownMessageIDs: ["old-reply"])
        let oldReply = NotionMessage(id: "old-reply", role: "agent", content: "前の回答",
                                     created_time: "2026-10-01T02:00:00Z", pending_user_actions: nil)
        let newReply = NotionMessage(id: "new-reply", role: "agent", content: "新しい回答",
                                     created_time: "2026-10-01T02:00:05Z", pending_user_actions: nil)
        XCTAssertEqual(NotionConversation.display([newReply, oldReply], pending: [pending]).map(\.id),
                       ["old-reply", "pending", "new-reply"])
        let serverQuestion = NotionMessage(id: "server-question", role: "user", content: "質問",
                                           created_time: "2026-10-01T02:00:02Z", pending_user_actions: nil)
        XCTAssertEqual(NotionConversation.display([newReply, serverQuestion, oldReply, newReply],
                                                  pending: [pending]).map(\.id),
                       ["old-reply", "server-question", "new-reply"])
    }

    func testNewMessageIDsConfirmAReplyEvenWhenThreadTimestampIsAheadOfMessages() {
        let baseline = NotionMessage.parseDate("2026-10-01T02:01:00Z")!
        let oldQuestion = NotionMessage(id: "old-question", role: "user", content: "同じ質問",
                                        created_time: "2026-10-01T02:00:00Z", pending_user_actions: nil)
        let oldReply = NotionMessage(id: "old-reply", role: "agent", content: "前回の回答",
                                     created_time: "2026-10-01T02:00:01Z", pending_user_actions: nil)
        let newQuestion = NotionMessage(id: "new-question", role: "user", content: "同じ質問",
                                        created_time: "2026-10-01T02:00:02Z", pending_user_actions: nil)
        let newReply = NotionMessage(id: "new-reply", role: "agent", content: "今回の回答",
                                     created_time: "2026-10-01T02:00:03Z", pending_user_actions: nil)
        let pending = NotionAgentsStore.PendingOutbound(
            message: NotionMessage(id: "pending", role: "user", content: "同じ質問",
                                   created_time: "2026-10-01T02:01:00Z", pending_user_actions: nil),
            agentID: "agent-1", threadID: "thread-1", baselineTime: baseline,
            knownMessageIDs: ["old-question", "old-reply"])
        XCTAssertEqual(NotionConversation.display([oldQuestion, oldReply], pending: [pending]).map(\.id),
                       ["old-question", "old-reply", "pending"])
        XCTAssertEqual(NotionConversation.display([oldQuestion, oldReply, newQuestion, newReply],
                                                  pending: [pending]).map(\.id),
                       ["old-question", "old-reply", "new-question", "new-reply"])
        XCTAssertEqual(NotionReplyTracking.reply(in: [oldQuestion, oldReply, newQuestion, newReply],
            messageFingerprint: NotionReplyTracking.fingerprint("同じ質問"), sentAt: baseline,
            baselineSignature: "completed:2026-10-01T02:01:00Z",
            knownMessageIDs: ["old-question", "old-reply"])?.id, "new-reply")
        XCTAssertEqual(NotionReplyTracking.reply(in: [newQuestion, newReply],
            messageFingerprint: NotionReplyTracking.fingerprint("同じ質問"), sentAt: baseline,
            baselineSignature: "completed:2026-10-01T02:01:00Z")?.id, "new-reply",
            "Pending replies saved before message IDs were tracked must also recover")
    }

    @MainActor
    func testCompletedThreadKeepsPollingUntilReplyAppearsEvenWhenHistoryOmitsIt() async throws {
        let settings = SettingsStore.shared
        let saved = settings.data
        defer { settings.data = saved }
        settings.data.notionSavedAgents = [SavedNotionAgent(id: "agent-1", name: "Test agent")]
        settings.data.notionNotificationsEnabled = true
        let persistenceKey = "notion-poll-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotionAgentsCache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = NotionAgentsCache(url: cacheURL)
        final class ResponseState { var phase = 0 }
        let state = ResponseState()
        let questionTime = ISO8601DateFormatter().string(from: Date())
        let replyTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let threadTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        let api = NotionAgentsAPI(token: "test-token") { request in
            let path = request.url!.path
            let json: String
            switch (path, request.httpMethod) {
            case ("/v1/agents", _):
                json = """
                {"results":[{"id":"agent-1","name":"Test agent","agent_type":"custom_agent","status":"active"}],"has_more":false,"next_cursor":null}
                """
            case ("/v1/agents/agent-1/threads", _):
                let status = state.phase == 3 ? "in_progress" : "completed"
                let results = state.phase == 2 ? "[]" : """
                [{"id":"thread-1","title":"Chat","status":"\(status)","last_edited_time":"\(threadTime)"}]
                """
                json = "{\"results\":\(results),\"has_more\":false,\"next_cursor\":null}"
            case ("/v1/threads/thread-1/messages", "POST"):
                state.phase = 1
                json = "{\"thread_id\":\"thread-1\",\"status\":\"queued\"}"
            case ("/v1/threads/thread-1/messages", _):
                let question = "{\"id\":\"question\",\"role\":\"user\",\"content\":\"自分の質問\",\"created_time\":\"\(questionTime)\"}"
                let answer = "{\"id\":\"answer\",\"role\":\"agent\",\"content\":\"自分への回答\",\"created_time\":\"\(replyTime)\"}"
                json = "{\"results\":[\(question)\(state.phase == 2 ? "," + answer : "")],\"has_more\":false,\"next_cursor\":null}"
            default:
                throw NotionAPIError.invalidResponse
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                       httpVersion: nil, headerFields: nil)!)
        }
        let store = NotionAgentsStore(tokenProvider: { "test-token" }, apiFactory: { _ in api },
                                      pendingRepliesKey: persistenceKey, cache: cache)
        await store.refresh(forceFull: true)
        store.selectedThreadID = "thread-1"
        let sent = await store.send("自分の質問")
        XCTAssertTrue(sent)
        await store.refresh(forceFull: true)
        XCTAssertEqual(store.pendingReplyCount, 1, "A completed status without an agent message is still waiting")
        XCTAssertTrue(store.isPolling)
        let restored = NotionAgentsStore(tokenProvider: { "test-token" }, apiFactory: { _ in api },
                                         pendingRepliesKey: persistenceKey, cache: cache)
        restored.start()
        XCTAssertEqual(restored.pendingReplyCount, 1, "Pending replies must survive an app restart")
        XCTAssertTrue(restored.isPolling)
        state.phase = 2
        for _ in 0..<20 where store.pendingReplyCount > 0 {
            await store.refresh(forceFull: true)
            if store.pendingReplyCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(store.alert?.preview, "自分への回答")
        XCTAssertEqual(store.pendingReplyCount, 0)
        XCTAssertTrue(store.pendingMessages.isEmpty, "The server's question must replace the optimistic bubble")
        XCTAssertEqual(store.visibleMessages.map(\.id), ["question", "answer"])
        XCTAssertFalse(store.busyAgentIDs.contains("agent-1"), "The notch activity ring must stop")
        for _ in 0..<20 where restored.pendingReplyCount > 0 {
            await restored.refresh()
            if restored.pendingReplyCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(restored.alert?.title, "返信が届きました")
        XCTAssertEqual(restored.alert?.preview, "自分への回答")
        XCTAssertEqual(restored.pendingReplyCount, 0)
        XCTAssertFalse(restored.isPolling)
        restored.openThread(agentID: "agent-1", threadID: "thread-1")
        XCTAssertEqual(restored.visibleMessages.map(\.id), ["question", "answer"],
                       "Opening the notification must show the reply already fetched by polling")
        state.phase = 3
        store.setPanelVisible(true)
        await store.refresh(forceFull: true)
        XCTAssertFalse(store.busyAgentIDs.contains("agent-1"),
                       "A lagging in_progress status must not restart the notch spinner after the answer")
    }

    func testReplyAlertCoversNewAndCompletedThreadsWithoutRealertingOnSameState() throws {
        func thread(_ status: String, _ edited: String) throws -> NotionThread {
            let json = """
            {"id":"thread","title":"Chat","status":"\(status)","last_edited_time":"\(edited)"}
            """
            return try JSONDecoder().decode(NotionThread.self, from: Data(json.utf8))
        }
        let complete = try thread("completed", "2026-09-30T00:00:02Z")
        XCTAssertNil(NotionThreadAlertPolicy.title(for: complete, previousSignature: nil, hasBaseline: false))
        XCTAssertEqual(NotionThreadAlertPolicy.title(for: complete, previousSignature: nil, hasBaseline: true), "返信が届きました")
        XCTAssertEqual(NotionThreadAlertPolicy.title(for: complete, previousSignature: "pending:2026-09-30T00:00:01Z", hasBaseline: true), "返信が届きました")
        XCTAssertNil(NotionThreadAlertPolicy.title(for: complete, previousSignature: "completed:2026-09-30T00:00:02Z", hasBaseline: true))
        XCTAssertEqual(NotionThreadAlertPolicy.title(for: try thread("requires_action", "2026-09-30T00:00:03Z"), previousSignature: nil, hasBaseline: true), "確認が必要です")
    }

    func testNotionReplyMarkupProducesLinksListsAndCopyableText() {
        let raw = """
        <mention url="https://app.dev.notion.com/p/example">Business → Demo</mention> です。[^https://app.dev.notion.com/p/example]

        - **Security** の紹介
        1. [デモを見る](https://www.loom.com/share/example)

        <data_artifact toolResultId="tool-458" viewType="table" />
        """
        let blocks = NotionReplyFormatter.blocks(raw)
        XCTAssertEqual(blocks, [.paragraph("[Business → Demo](https://app.dev.notion.com/p/example) です。[出典](https://app.dev.notion.com/p/example)"),
                                .bullet("**Security** の紹介"), .numbered("1", "[デモを見る](https://www.loom.com/share/example)"), .artifact])
        let copied = NotionReplyFormatter.copyText(raw)
        XCTAssertFalse(copied.contains("<mention"))
        XCTAssertFalse(copied.contains("<data_artifact"))
        XCTAssertTrue(copied.contains("表データ（Notionで確認）"))
        let preview = NotionReplyFormatter.preview(raw)
        XCTAssertTrue(preview.contains("Business → Demo"))
        XCTAssertFalse(preview.contains("https://"))
        XCTAssertFalse(preview.contains("<data_artifact"))
    }

    @MainActor
    func testReplyLinkIsRenderedAsAnInteractiveTextLink() throws {
        _ = NSApplication.shared
        let message = try JSONDecoder().decode(NotionMessage.self, from: Data("""
        {"id":"reply","role":"assistant","content":"[デモを見る](https://example.com/demo)","created_time":"2026-09-30T00:00:00Z"}
        """.utf8))
        let view = NSHostingView(rootView: NotionMessageView(message: message,
            agent: SavedNotionAgent(id: "agent", name: "Demo")))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 160)
        view.layoutSubtreeIfNeeded()
        func textViews(in root: NSView) -> [NSTextView] {
            (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
        }
        let linkView = try XCTUnwrap(textViews(in: view).first { $0.string.contains("デモを見る") })
        XCTAssertTrue(linkView.isSelectable)
        XCTAssertNotNil(linkView.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testCustomAgentAvatarURLIsDecoded() throws {
        let json = """
        {"id":"agent","name":"Demo","agent_type":"custom_agent","status":"active","icon":{"type":"custom_agent_avatar","custom_agent_avatar":{"static_url":"https://images.example.com/avatar.png","animated_url":"https://images.example.com/avatar.gif"}}}
        """
        let agent = try JSONDecoder().decode(NotionAgent.self, from: Data(json.utf8))
        XCTAssertEqual(agent.iconURL, "https://images.example.com/avatar.png")
    }

    func testURLAndIDParsingRejectsOtherSitesAndNormalizesUUIDs() {
        let id = "3c90c3cc-0d44-4b50-8888-8dd25736052a"
        XCTAssertEqual(NotionAgentInput.id(from: id), id)
        XCTAssertEqual(NotionAgentInput.id(from: "https://www.notion.so/Workspace/Helper-3c90c3cc0d444b5088888dd25736052a?x=1"), id)
        XCTAssertEqual(NotionAgentInput.id(from: "https://www.notion.com/Workspace/Helper-3c90c3cc0d444b5088888dd25736052a"), id)
        XCTAssertEqual(NotionAgentInput.id(from: "agent_custom_123"), "agent_custom_123")
        XCTAssertNil(NotionAgentInput.id(from: "https://example.com/3c90c3cc0d444b5088888dd25736052a"))
        XCTAssertNil(NotionAgentInput.id(from: "https://www.notion.so/no-agent-id"))
        XCTAssertNil(NotionAgentInput.id(from: "abc"))
    }

    func testNameSearchLoadsOnePageAtATimeAndFiltersPartialMatches() async throws {
        var requests: [URLRequest] = []
        let api = NotionAgentsAPI(token: "test-token") { request in
            requests.append(request)
            let next = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "start_cursor" })?.value
            let body: [String: Any] = next == nil
                ? ["results": [["id": "a", "name": "Writer Helper", "description": "", "agent_type": "custom", "status": "active"],
                               ["id": "b", "name": "Notion AI", "description": "", "agent_type": "notion_ai", "status": "active"]],
                   "has_more": true, "next_cursor": "next"]
                : ["results": [["id": "c", "name": "Copywriter", "description": "", "agent_type": "custom", "status": "active"]],
                   "has_more": false, "next_cursor": NSNull()]
            return (try JSONSerialization.data(withJSONObject: body), self.response(request))
        }
        let first = try await api.searchAgents(named: "wri")
        XCTAssertEqual(first.results.map(\.id), ["a"])
        XCTAssertEqual(first.next_cursor, "next")
        XCTAssertEqual(requests.count, 1, "Searching must not walk the entire workspace")
        let second = try await api.searchAgents(named: "wri", cursor: first.next_cursor)
        XCTAssertEqual(second.results.map(\.id), ["c"])
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "name" })?.value, "wri")
        XCTAssertEqual(query.first(where: { $0.name == "page_size" })?.value, "50")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Notion-Version"), "2025-09-03")
        XCTAssertEqual(requests[1].url?.path, "/v1/agents")
    }

    func testNameSearchFallsBackWhenServerRejectsQuery() async throws {
        var requests: [URLRequest] = []
        let api = NotionAgentsAPI(token: "test-token") { request in
            requests.append(request)
            let hasQuery = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "name" }) == true
            let body = hasQuery ? "{\"message\":\"unsupported query\"}" : "{\"results\":[{\"id\":\"a\",\"name\":\"Morning helper\",\"agent_type\":\"custom\",\"status\":\"active\"}],\"has_more\":false,\"next_cursor\":null}"
            return (Data(body.utf8), self.response(request, hasQuery ? 400 : 200))
        }
        let page = try await api.searchAgents(named: "morn")
        XCTAssertEqual(page.results.map(\.id), ["a"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(where: { $0.name == "name" }))
    }

    func testAgentMetadataLookupOnlyRequestsRegisteredID() async throws {
        var urls: [URL] = []
        let api = NotionAgentsAPI(token: "test-token") { request in
            urls.append(request.url!)
            let json = """
            {"results":[{"id":"saved-agent","name":"Real Name","agent_type":"custom_agent","status":"active","icon":{"type":"emoji","emoji":"✨"}}],"has_more":false,"next_cursor":null}
            """
            return (Data(json.utf8), self.response(request))
        }
        let agent = try await api.agent(id: "saved-agent")
        XCTAssertEqual(agent?.name, "Real Name")
        XCTAssertEqual(agent?.glyph, "✨")
        XCTAssertEqual(urls.count, 1)
        let items = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "agent_ids" })?.value, "saved-agent")
        XCTAssertEqual(items.first(where: { $0.name == "page_size" })?.value, "1")
    }

    func testSessionEventsProvideMessagesWhenThreadListingIsEmpty() async throws {
        var paths: [String] = []
        let api = NotionAgentsAPI(token: "test-token") { request in
            paths.append(request.url!.path)
            let json: String
            if request.url!.path.hasSuffix("/events/query") {
                json = """
                {"results":[{"id":"event-2","type":"agent.message","sequence":2,"created_at":"2026-09-30T00:00:02Z","content":[{"type":"text","text":"答えです"}]},{"id":"event-1","type":"user.message","sequence":1,"created_at":"2026-09-30T00:00:01Z","content":[{"type":"text","text":"質問です"}]}],"has_more":false,"next_cursor":null}
                """
            } else { json = "{\"results\":[],\"has_more\":false,\"next_cursor\":null}" }
            return (Data(json.utf8), self.response(request))
        }
        let messages = try await api.messages(threadID: "thread-1")
        XCTAssertEqual(messages.map(\.content), ["質問です", "答えです"])
        XCTAssertEqual(paths, ["/v1/threads/thread-1/messages", "/v1/sessions/thread-1/events/query"])
    }

    func testRegisteredAgentPollCanStopAtFirstHistoryPage() async throws {
        var requests = 0
        let api = NotionAgentsAPI(token: "test-token") { request in
            requests += 1
            return (Data("{\"results\":[],\"has_more\":true,\"next_cursor\":\"next\"}".utf8), self.response(request))
        }
        _ = try await api.threads(agentID: "saved", allPages: false)
        XCTAssertEqual(requests, 1)
    }

    func testThreadHistoryChatAndActionEndpoints() async throws {
        var paths: [String] = []
        var bodies: [[String: String]] = []
        let api = NotionAgentsAPI(token: "test-token") { request in
            paths.append(request.url!.path)
            if let data = request.httpBody { bodies.append(try JSONDecoder().decode([String: String].self, from: data)) }
            let path = request.url!.path
            let json: String
            if path.hasSuffix("/threads") {
                json = """
                {"results":[{"id":"t1","title":"First","status":"requires_action","last_edited_time":"2026-09-30T00:00:00Z","pending_user_actions":[{"id":"act","title":"Delete?","options":[{"id":"approve","label":"Approve"},{"id":"reject","label":"Reject"}]}]}],"has_more":false,"next_cursor":null}
                """
            } else if path.hasSuffix("/messages") && request.httpMethod == "GET" {
                json = """
                {"results":[{"id":"m2","role":"agent","content":"Answer","created_time":"2026-09-30T00:00:02Z"},{"id":"m1","role":"user","content":"Hi","created_time":"2026-09-30T00:00:01Z"}],"has_more":false,"next_cursor":null}
                """
            } else { json = "{\"thread_id\":\"t1\",\"status\":\"pending\"}" }
            return (Data(json.utf8), self.response(request))
        }
        let threads = try await api.threads(agentID: "a")
        XCTAssertEqual(threads.first?.pending_user_actions?.first?.options.map(\.id), ["approve", "reject"])
        let messages = try await api.messages(threadID: "t1")
        XCTAssertEqual(messages.map(\.id), ["m1", "m2"])
        _ = try await api.send("Hi", agentID: "a", threadID: nil)
        _ = try await api.send("Again", agentID: "a", threadID: "t1")
        _ = try await api.respond(actionID: "act", optionID: "reject", threadID: "t1")
        XCTAssertEqual(paths, ["/v1/agents/a/threads", "/v1/threads/t1/messages", "/v1/agents/a/chat", "/v1/threads/t1/messages", "/v1/threads/t1/continue"])
        XCTAssertEqual(bodies, [["message": "Hi"], ["message": "Again"], ["action_id": "act", "option_id": "reject"]])
    }

    func testServerFailureDoesNotExposeToken() async {
        let api = NotionAgentsAPI(token: "secret-value") { request in
            (Data("{\"message\":\"No access\"}".utf8), self.response(request, 403))
        }
        do { _ = try await api.searchAgents(named: "secret"); XCTFail("Expected a 403") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("403"))
            XCTAssertFalse(error.localizedDescription.contains("secret-value"))
        }
    }
}
