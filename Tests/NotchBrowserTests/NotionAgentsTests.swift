import Foundation
import XCTest
@testable import NotchBrowser

final class NotionAgentsTests: XCTestCase {
    private func response(_ request: URLRequest, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testOldSettingsKeepNotionDefaultsAndNewPreferencesRoundTrip() throws {
        var settings = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.notionHiddenAgentIDs.isEmpty)
        XCTAssertTrue(settings.notionNotificationsEnabled)
        settings.notionHiddenAgentIDs.insert("agent-1")
        settings.notionNotificationsEnabled = false
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.notionHiddenAgentIDs, ["agent-1"])
        XCTAssertFalse(restored.notionNotificationsEnabled)
    }

    func testAgentsPaginationAndCustomFilter() async throws {
        var requests: [URLRequest] = []
        let api = NotionAgentsAPI(token: "test-token") { request in
            requests.append(request)
            let next = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "start_cursor" })?.value
            let body: [String: Any] = next == nil
                ? ["results": [["id": "a", "name": "Helper", "description": "", "agent_type": "custom", "status": "active"],
                               ["id": "b", "name": "Notion AI", "description": "", "agent_type": "notion_ai", "status": "active"]],
                   "has_more": true, "next_cursor": "next"]
                : ["results": [["id": "c", "name": "Writer", "description": "", "agent_type": "custom", "status": "active"]],
                   "has_more": false, "next_cursor": NSNull()]
            return (try JSONSerialization.data(withJSONObject: body), self.response(request))
        }
        let agents = try await api.agents()
        XCTAssertEqual(agents.map(\.id), ["a", "c"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Notion-Version"), "2025-09-03")
        XCTAssertEqual(requests[1].url?.path, "/v1/agents")
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
        do { _ = try await api.agents(); XCTFail("Expected a 403") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("403"))
            XCTAssertFalse(error.localizedDescription.contains("secret-value"))
        }
    }
}
