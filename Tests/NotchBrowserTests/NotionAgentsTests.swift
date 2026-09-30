import Foundation
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

    private func response(_ request: URLRequest, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testOldSettingsKeepNotionDefaultsAndNewPreferencesRoundTrip() throws {
        var settings = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.notionHiddenAgentIDs.isEmpty)
        XCTAssertTrue(settings.notionSavedAgents.isEmpty)
        XCTAssertTrue(settings.notionNotificationsEnabled)
        settings.notionHiddenAgentIDs.insert("agent-1")
        settings.notionNotificationsEnabled = false
        settings.notionSavedAgents = [SavedNotionAgent(id: "agent-1", name: "Writer")]
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.notionHiddenAgentIDs, ["agent-1"])
        XCTAssertFalse(restored.notionNotificationsEnabled)
        XCTAssertEqual(restored.notionSavedAgents, [SavedNotionAgent(id: "agent-1", name: "Writer")])
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
