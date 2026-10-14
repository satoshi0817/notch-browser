import XCTest
import Foundation
@testable import NotchBrowser

final class Notch018Tests: XCTestCase {
    private func response(_ request: URLRequest, _ json: String, status: Int = 200,
                          headers: [String: String]? = nil) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!)
    }

    func testActualChildrenReferencesForBothMeetingTypes() throws {
        for type in ["meeting_notes", "transcription"] {
            let raw = """
            {"id":"meeting","type":"\(type)","\(type)":{"title":[{"plain_text":"定例"}],
             "status":"notes_ready","children":{"summary_block_id":"summary-root",
             "notes_block_id":"notes-root","transcript_block_id":"transcript-root"}}}
            """
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let meeting = try XCTUnwrap(NotionMeeting.parse(object))
            XCTAssertEqual(meeting.sections.map { $0.1 }, ["summary-root", "notes-root", "transcript-root"])
        }
    }

    func testBodyPaginationRecursionAndRetryUseGET() async throws {
        var paths: [String] = []
        var waits: [Double] = []
        var limited = false
        var api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let path = request.url!.path
            paths.append(path)
            if !limited {
                limited = true
                return self.response(request, #"{"object":"error","status":429,"code":"rate_limited"}"#,
                                     status: 429, headers: ["Retry-After": "1.5"])
            }
            if path == "/v1/blocks/toggle/children" {
                return self.response(request, """
                {"object":"list","results":[{"id":"nested","type":"paragraph","has_children":false,
                "paragraph":{"rich_text":[{"type":"text","plain_text":"内側","text":{"content":"内側"}}]}}],
                "has_more":false,"next_cursor":null}
                """)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if query?.contains(where: { $0.name == "start_cursor" && $0.value == "cursor-2" }) == true {
                return self.response(request, """
                {"object":"list","results":[{"id":"last","type":"numbered_list_item","has_children":false,
                "numbered_list_item":{"rich_text":[{"plain_text":"次の項目"}]}}],
                "has_more":false,"next_cursor":null}
                """)
            }
            return self.response(request, """
            {"object":"list","results":[{"id":"toggle","type":"toggle","has_children":true,
            "toggle":{"rich_text":[{"plain_text":"詳細"}]}}],
            "has_more":true,"next_cursor":"cursor-2"}
            """)
        })
        api.wait = { waits.append($0) }
        let blocks = try await api.meetingBody("summary-root")
        XCTAssertEqual(blocks.map(\.id), ["toggle", "nested", "last"])
        XCTAssertEqual(blocks.map(\.depth), [0, 1, 0])
        XCTAssertEqual(waits, [1.5])
        XCTAssertEqual(paths, ["/v1/blocks/summary-root/children", "/v1/blocks/summary-root/children",
                               "/v1/blocks/toggle/children", "/v1/blocks/summary-root/children"])
    }

    func testEmptyBodyAndMissingReferences() async throws {
        let api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            self.response(request, #"{"object":"list","results":[],"has_more":false,"next_cursor":null}"#)
        })
        let body = try await api.meetingBody("empty-root")
        XCTAssertTrue(body.isEmpty)
        let meeting = try XCTUnwrap(NotionMeeting.parse(["id": "empty", "type": "meeting_notes",
                                                       "meeting_notes": ["children": [String: Any]()]]))
        XCTAssertNil(meeting.summary)
        XCTAssertNil(meeting.notes)
        XCTAssertNil(meeting.transcript)
    }

    func testAllThreeChildrenReferencesAreFetchedIncludingEmptyTranscript() async throws {
        let raw = #"{"id":"meeting","type":"meeting_notes","meeting_notes":{"children":{"summary_block_id":"s","notes_block_id":"n","transcript_block_id":"t"}}}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let meeting = try XCTUnwrap(NotionMeeting.parse(object))
        var paths: [String] = []
        let api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            paths.append(request.url!.path)
            if request.url!.path == "/v1/blocks/t/children" {
                return self.response(request, #"{"results":[],"has_more":false,"next_cursor":null}"#)
            }
            return self.response(request, #"{"results":[{"id":"body","type":"paragraph","paragraph":{"rich_text":[{"plain_text":"本文"}]}}],"has_more":false,"next_cursor":null}"#)
        })
        var bodies: [[NotionTaskBlock]] = []
        for (_, id) in meeting.sections { bodies.append(try await api.meetingBody(id)) }
        XCTAssertEqual(paths, ["/v1/blocks/s/children", "/v1/blocks/n/children", "/v1/blocks/t/children"])
        XCTAssertEqual(bodies.map(\.count), [1, 1, 0])
    }

    func testFixedTitleHidesSingleCharacterRemainder() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        XCTAssertEqual(NotchTabLayout.displayedTitle("議事録", available: 30, measure: measure), "議事録")
        XCTAssertEqual(NotchTabLayout.displayedTitle("長い議事録", available: 30, measure: measure), "長い…")
        XCTAssertEqual(NotchTabLayout.displayedTitle("議事録", available: 20, measure: measure), "")
        XCTAssertEqual(NotchTabLayout.displayedTitle("議事録", available: 0, measure: measure), "")
    }

    #if DEBUG
    func testNewPreviewArgumentsSuppressLiveConnection() {
        for argument in ["--fixed-pages-drag", "--fixed-display=both", "--meeting-section=notes", "--meetings=empty-tabs"] {
            XCTAssertEqual(NotionConnectionStore.previewState(arguments: ["preview", argument]), .connected)
        }
        XCTAssertEqual(NotionConnectionStore.previewState(arguments: ["preview", "--fixed-pages-drag", "--notion-connection=unconnected"]), .unconnected)
    }
    #endif

    func testRetryWithoutHeaderUsesPositiveBackoff() async throws {
        var calls = 0
        var waits: [Double] = []
        var api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            calls += 1
            return self.response(request, #"{"results":[],"has_more":false}"#, status: calls < 3 ? 429 : 200)
        })
        api.wait = { waits.append($0) }
        let blocks = try await api.meetingBody("notes-root")
        XCTAssertTrue(blocks.isEmpty)
        XCTAssertEqual(waits, [1, 2])
    }

    func testBodyDoesNotTruncateAfterFiveHundredBlocksOrSixLevels() async throws {
        var page = 0
        let api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            let raw: [String: Any]
            if request.url!.path == "/v1/blocks/root/children" {
                page += 1
                var rows: [[String: Any]] = (0..<100).map { index in
                    ["id": "p-\(page)-\(index)", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "本文"]]]]
                }
                if page == 1 { rows[0] = ["id": "level-1", "type": "toggle", "has_children": true] }
                raw = ["results": rows, "has_more": page < 6, "next_cursor": "page-\(page + 1)"]
            } else {
                let level = Int(request.url!.path.split(separator: "/")[2].dropFirst(6))!
                raw = ["results": [["id": "level-\(level + 1)", "type": "toggle", "has_children": level < 8]], "has_more": false]
            }
            return (try JSONSerialization.data(withJSONObject: raw),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let blocks = try await api.meetingBody("root")
        XCTAssertEqual(blocks.count, 608)
        XCTAssertEqual(blocks.map(\.depth).max(), 8)
        XCTAssertEqual(blocks.last?.id, "p-6-99")
    }

    func testMissingCursorCannotSilentlyTruncateBody() async throws {
        let api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            self.response(request, #"{"results":[],"has_more":true,"next_cursor":null}"#)
        })
        do {
            _ = try await api.meetingBody("root")
            XCTFail("Expected invalid pagination response")
        } catch NotionAPIError.invalidResponse { }
    }

    #if DEBUG
    @MainActor func testEmptyTabsFixtureNeverReadsTokenOrCallsAPI() async throws {
        let store = NotionMeetingsStore(tokenProvider: { XCTFail("Unexpected token read"); return nil },
            apiFactory: { _ in XCTFail("Unexpected API call"); return NotionDatabaseAPI(token: "") },
            previewState: "empty-tabs")
        let meeting = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(meeting.sections.count, 3)
        for (_, id) in meeting.sections {
            let body = try await store.blocks(id)
            XCTAssertTrue(body.isEmpty)
        }
    }
    #endif

    @MainActor func testEveryFixedPageReordersAndPersistsWithDisplayPreferences() throws {
        var data = SettingsData()
        let ids = data.pinnedTabs.map(\.id)
        let order = [PinnedTabsSettings.meetingsID, ids[1], PinnedTabsSettings.tasksID,
                     PinnedTabsSettings.notionID, ids[0]]
        data.fixedPageOrder = order
        data.tasksTabDisplay = .titleOnly
        data.meetingsTabDisplay = .iconAndTitle
        data.tasksTabSymbol = "star"
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(PinnedTabsSettings.pageRows(pinnedTabs: restored.pinnedTabs,
            notionPosition: restored.notionTabPosition, order: restored.fixedPageOrder).map(\.id), order)
        XCTAssertEqual(restored.tasksTabDisplay, .titleOnly)
        XCTAssertEqual(restored.meetingsTabDisplay, .iconAndTitle)
        XCTAssertEqual(restored.tasksTabSymbol, "star")
    }

    @MainActor func testLegacySettingsDefaultsAndOrderNormalization() throws {
        let data = try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(data.tasksTabDisplay, .iconOnly)
        XCTAssertEqual(data.meetingsTabDisplay, .iconOnly)
        XCTAssertEqual(data.tasksTabSymbol, "checklist")
        XCTAssertEqual(data.meetingsTabSymbol, "person.2")
        let rows = PinnedTabsSettings.pageRows(pinnedTabs: data.pinnedTabs, notionPosition: data.notionTabPosition,
            order: [UUID(), PinnedTabsSettings.tasksID, PinnedTabsSettings.tasksID])
        XCTAssertEqual(rows.first?.id, PinnedTabsSettings.tasksID)
        XCTAssertEqual(Set(rows.map(\.id)).count, data.pinnedTabs.count + 3)
    }

    func testTranscriptSpeakerAndOptionalTimestamp() throws {
        XCTAssertEqual(NotionMeetingSpeech.parse("0:18 佐藤：確認します"),
                       .init(speaker: "佐藤", time: "0:18", text: "確認します"))
        XCTAssertEqual(NotionMeetingSpeech.parse("田中：開始します"),
                       .init(speaker: "田中", time: nil, text: "開始します"))
        XCTAssertNil(NotionMeetingSpeech.parse("話者なし"))
        let block = NotionTaskBlock.parse(["id": "speech", "type": "paragraph",
            "paragraph": ["speaker": ["name": "佐藤"], "timestamp": "00:18",
                          "rich_text": [["plain_text": "確認します"]]]], depth: 0)
        XCTAssertEqual(block.speaker, "佐藤")
        XCTAssertEqual(block.timestamp, "00:18")
    }
}
