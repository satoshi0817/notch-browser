import XCTest
import Foundation
@testable import NotchBrowser

final class NotionMeetingsTests: XCTestCase {
    func testJapaneseDateLabelsIgnoreSystemLanguage() throws {
        let date = try XCTUnwrap(NotionMessage.parseDate("2026-10-13T15:05:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(NotionMeetingDateLabels.day(date, timeZone: zone), "10月14日（水）")
        XCTAssertEqual(NotionMeetingDateLabels.detail(date, timeZone: zone), "2026年10月14日（水）0:05")
        XCTAssertEqual(NotionMeetingDateLabels.time(date, timeZone: zone), "0:05")
        XCTAssertEqual(NotionMeetingDateLabels.detail(.distantPast, timeZone: zone), "日時なし")
    }
    func testDetailMetadataFitsOneJapaneseLine() throws {
        let meeting = try XCTUnwrap(NotionMeeting.parse(fixture()))
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(meeting.detailMetadata(timeZone: zone), "2026年10月13日（火）18:00・45分・3人")
    }
    private func fixture(type: String = "meeting_notes", status: String = "notes_ready", summary: String? = "summary") -> [String: Any] {
        var value: [String: Any] = [
            "title": [["plain_text": "定例"]],
            "status": status, "attendees": [["id": "a"], ["id": "b"], ["id": "c"]],
            "calendar": ["start": "2026-10-13T09:00:00Z", "end": "2026-10-13T10:00:00Z"],
            "recording": ["start": "2026-10-13T09:05:00Z", "end": "2026-10-13T09:50:00Z"],
            "notes": ["id": "notes"], "transcript": ["block_id": "transcript"]
        ]
        if let summary { value["summary"] = summary }
        return ["id": "meeting", "type": type, type: value]
    }
    func testCurrentAndLegacyDecode() throws {
        for type in ["meeting_notes", "transcription"] {
            let meeting = try XCTUnwrap(NotionMeeting.parse(fixture(type: type)))
            XCTAssertEqual(meeting.title, "定例")
            XCTAssertEqual(meeting.attendees.count, 3)
            XCTAssertEqual(meeting.duration, 45)
            XCTAssertNotNil(meeting.calendarEnd)
            XCTAssertNotNil(meeting.recordingStart)
            XCTAssertEqual(meeting.sections.map { $0.0 }, ["要約", "メモ", "文字起こし"])
        }
    }
    func testStateLabelsAndDefaultSection() throws {
        for (status, label, progressing) in [
            ("notes_ready", Optional<String>.none, false),
            ("transcribing", "文字起こし中", true),
            ("summarizing", "要約作成中", true),
            ("failed", "作成に失敗しました", false),
            ("future_status", "future_status", false)
        ] {
            let meeting = try XCTUnwrap(NotionMeeting.parse(fixture(status: status)))
            XCTAssertEqual(meeting.label, label)
            XCTAssertEqual(meeting.progressing, progressing)
        }
        XCTAssertEqual(NotionMeeting.parse(fixture(summary: nil))?.sections.first?.0, "メモ")
    }
    func testTabVisibilityUsesConnectionRule() {
        XCTAssertTrue(NotionTaskRules.tabVisible(connected: true))
        XCTAssertFalse(NotionTaskRules.tabVisible(connected: false))
    }
    func testEmptyBodiesAreHiddenAndNotesBecomeDefault() throws {
        let meeting = try XCTUnwrap(NotionMeeting.parse(fixture()))
        let paragraph = NotionTaskBlock.parse(["id": "body", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "メモ"]]]], depth: 0)
        XCTAssertTrue(meeting.visibleSections(bodies: [:]).isEmpty)
        let sections = meeting.visibleSections(bodies: ["summary": [], "notes": [paragraph], "transcript": [paragraph]])
        XCTAssertEqual(sections.map { $0.0 }, ["メモ", "文字起こし"])
        XCTAssertEqual(sections.first?.1, "notes")
    }
    func testQueryVersionLimitAndNoFallbackWhenNonempty() async throws {
        var calls = 0
        let row = fixture()
        var api = NotionDatabaseAPI(token: "test", fetch: { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/v1/blocks/meeting_notes/query")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(body?["page_size"] as? Int, 50)
            XCTAssertNil(body?["start_cursor"])
            return (try JSONSerialization.data(withJSONObject: ["results": [row], "has_more": true]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        api.version = "2026-03-11"
        let result = try await api.meetingNotes(fallback: "https://notion.so/0123456789abcdef0123456789abcdef")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(calls, 1)
    }
    func testEmptyQueryFallsBackToNestedPageBlocks() async throws {
        var paths: [String] = []
        let row = fixture(type: "transcription")
        let api = NotionDatabaseAPI(token: "test", fetch: { request in
            let path = request.url!.path
            paths.append(path)
            let status: Int
            let raw: [String: Any]
            if path.contains("meeting_notes/query") { status = 200; raw = ["results": []] }
            else if path.contains("/databases/") { status = 404; raw = ["message": "page"] }
            else if path.contains("/nested/children") { status = 200; raw = ["results": [row]] }
            else { status = 200; raw = ["results": [["id": "nested", "type": "toggle", "has_children": true]]] }
            return (try JSONSerialization.data(withJSONObject: raw),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await api.meetingNotes(fallback: "https://notion.so/0123456789abcdef0123456789abcdef")
        XCTAssertEqual(result.map { $0.id }, ["meeting"])
        XCTAssertTrue(paths.contains("/v1/blocks/nested/children"))
    }
    func test429WaitsRetryAfterAndRetriesSameQuery() async throws {
        var calls = 0
        var waits: [Double] = []
        var api = NotionDatabaseAPI(token: "test", fetch: { request in
            calls += 1
            return (Data(#"{"results":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: calls == 1 ? 429 : 200,
                                    httpVersion: nil, headerFields: ["Retry-After": "2.5"])!)
        })
        api.wait = { waits.append($0) }
        let result = try await api.meetingNotes(fallback: "")
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(waits, [2.5])
    }
    func testDatabaseFallbackQueriesSourcePages() async throws {
        var paths: [String] = []
        let row = fixture()
        let api = NotionDatabaseAPI(token: "test", fetch: { request in
            let path = request.url!.path
            paths.append(path)
            let raw: [String: Any]
            if path.contains("meeting_notes/query") { raw = ["results": []] }
            else if path.contains("/databases/") { raw = ["data_sources": [["id": "source"]]] }
            else if path.contains("/source/query") { raw = ["results": [["id": "page"]]] }
            else { raw = ["results": [row]] }
            return (try JSONSerialization.data(withJSONObject: raw),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await api.meetingNotes(fallback: "https://notion.so/0123456789abcdef0123456789abcdef")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(paths.contains("/v1/data_sources/source/query"))
        XCTAssertTrue(paths.contains("/v1/blocks/page/children"))
    }
    func testFallbackDepthIsBounded() async throws {
        var childrenCalls = 0
        let api = NotionDatabaseAPI(token: "test", fetch: { request in
            let path = request.url!.path
            var status = 200
            let raw: [String: Any]
            if path.contains("meeting_notes/query") { raw = ["results": []] }
            else if path.contains("/databases/") { status = 404; raw = [:] }
            else {
                childrenCalls += 1
                raw = ["results": [["id": "level-\(childrenCalls)", "type": "toggle", "has_children": true]]]
            }
            return (try JSONSerialization.data(withJSONObject: raw),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await api.meetingNotes(fallback: "https://notion.so/0123456789abcdef0123456789abcdef")
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(childrenCalls, 5)
    }
    func testRateLimitExhaustionDoesNotBecomeEmptyFallback() async throws {
        var calls = 0
        var api = NotionDatabaseAPI(token: "test", fetch: { request in
            calls += 1
            XCTAssertTrue(request.url!.path.contains("meeting_notes/query"))
            return (Data(#"{"message":"rate limited"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!)
        })
        api.wait = { _ in }
        do {
            _ = try await api.meetingNotes(fallback: "https://notion.so/0123456789abcdef0123456789abcdef")
            XCTFail("Expected exhausted retry error")
        } catch NotionAPIError.server(let status, _) { XCTAssertEqual(status, 429) }
        XCTAssertEqual(calls, 3)
    }
    #if DEBUG
    @MainActor func testDisplayPreferencesSortLimitAndPersist() throws {
        let suite = "meeting-display-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotionMeetingsStore(defaults: defaults, tokenProvider: { nil })
        store.meetings = (0..<30).compactMap { index in
            var raw = fixture()
            raw["id"] = "meeting-\(index)"
            var value = raw["meeting_notes"] as? [String: Any] ?? [:]
            value["calendar"] = ["start": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(index * 86400)))]
            raw["meeting_notes"] = value
            return NotionMeeting.parse(raw)
        }
        store.newestFirst = false; store.displayLimit = 10
        XCTAssertEqual(store.displayedMeetings.count, 10)
        XCTAssertEqual(store.displayedMeetings.first?.id, "meeting-0")
        store.newestFirst = true
        XCTAssertEqual(store.displayedMeetings.first?.id, "meeting-29")
        let restored = NotionMeetingsStore(defaults: defaults, tokenProvider: { nil })
        XCTAssertTrue(restored.newestFirst)
        XCTAssertEqual(restored.displayLimit, 10)
        let mock = NotionMeetingsStore(defaults: defaults, previewState: "detail")
        mock.newestFirst = false; mock.displayLimit = 25
        XCTAssertEqual(defaults.integer(forKey: "notionMeetings.displayLimit"), 10)
        XCTAssertEqual(defaults.object(forKey: "notionMeetings.newestFirst") as? Bool, true)
    }
    func testDesignerLayoutSettingsAndProgressPresentation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotchBrowser/NotionMeetingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("list.frame(width: (geometry.size.width - 1) / 2)"))
        XCTAssertTrue(source.contains("議事録を選ぶと内容が表示されます"))
        XCTAssertFalse(source.contains("‹ 一覧"))
        XCTAssertTrue(source.contains(".padding(.top, 16).padding(.bottom, 5)"))
        XCTAssertTrue(source.contains(".frame(height: 36)"))
        XCTAssertTrue(source.contains("Link(\"Notion で開く\", destination: meeting.url)"))
        XCTAssertFalse(source.contains("Button(\"更新\")"))
        XCTAssertTrue(source.contains("Notion で作成中です。しばらくしてから更新してください"))
        XCTAssertTrue(source.contains("Text(\"議事録のページ URL\").fixedSize(horizontal: true, vertical: false).lineLimit(1)"))
        XCTAssertTrue(source.contains("空欄のときは、参加した議事録を自動で探します"))
        XCTAssertFalse(source.contains("子ブロックを探索"))
        XCTAssertEqual(source.components(separatedBy: ".pickerStyle(.menu)").count - 1, 2)
        let browser = try String(contentsOf: root.appendingPathComponent("Sources/NotchBrowser/BrowserViewController.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/NotchBrowser/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(browser.contains("systemSymbolName: \"person.2\", accessibilityDescription: \"議事録\""))
        XCTAssertTrue(settings.contains("Self.meetingsID ? \"person.2\""))
    }
    @MainActor func testPinnedMeetingsEditorInEveryConnectionState() {
        for state in NotionConnectionState.allCases {
            let connection = NotionConnectionStore.preview(state: state)
            XCTAssertTrue(PinnedTabsSettings.pageRows(pinnedTabs: [], notionPosition: 0).contains { $0.id == PinnedTabsSettings.meetingsID })
            XCTAssertEqual(PinnedTabsSettings.editorKind(selection: PinnedTabsSettings.meetingsID, pinnedIDs: []), .notionMeetings)
            XCTAssertEqual(NotionTaskRules.settingsEnabled(state: connection.state), state == .connected)
            XCTAssertEqual(NotionTaskRules.tabVisible(state: state, hasStoredToken: connection.hasStoredToken), state != .unconnected)
            XCTAssertEqual(connection.showsLoading, state == .verifying)
            XCTAssertEqual(connection.showsConnectionError, state == .invalid || state == .unverified)
        }
    }
    func testMeetingConnectionPreviewArguments() throws {
        let launch = try XCTUnwrap(SettingsPreviewLaunch.parse(arguments: ["app", "--meetings=pinned-unconnected"]))
        XCTAssertEqual(launch.section, .tabs)
        XCTAssertEqual(launch.selection, .meetings)
        XCTAssertEqual(NotionConnectionStore.previewState(arguments: ["app", "--meetings=pinned-unconnected"]), .unconnected)
        XCTAssertEqual(NotionConnectionStore.previewState(arguments: ["app", "--meetings=error"]), .unverified)
    }
    func testMeetingPanelUsesConnectionBannerAndSharedSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotchBrowser/NotionMeetingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NotionConnectionNotice(onOpenSettings: onOpenSettings)"))
        XCTAssertTrue(source.contains("if connection.showsConnectionError {\n            Color.clear"))
        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains("if connection.showsConnectionError {\n            Color.clear"))
        XCTAssertTrue(source.contains("else if connection.showsLoading {"))
        XCTAssertTrue(source.contains("NotionMeetingsSettingsPage(onOpenSettings: onOpenSettings)"))
        XCTAssertTrue(source.contains(".disabled(!NotionTaskRules.settingsEnabled(state: connection.state))"))
    }
    @MainActor func testMeetingPreviewBodiesAndProgressAreDistinct() async throws {
        let detail = NotionMeetingsStore(previewState: "detail")
        let summary = try await detail.blocks("summary")
        let notes = try await detail.blocks("notes")
        let transcript = try await detail.blocks("transcript")
        XCTAssertTrue(summary.contains { $0.type == "bulleted_list_item" && $0.text.contains("リリース") })
        XCTAssertTrue(notes.contains { $0.text.contains("議論したこと") })
        XCTAssertTrue(transcript.contains { $0.text.hasPrefix("0:00 田中：") })
        XCTAssertNotEqual(summary, notes)
        XCTAssertNotEqual(notes, transcript)
        XCTAssertFalse(summary.contains { $0.text.contains("タスクの詳細") })
        let progress = NotionMeetingsStore(previewState: "progress")
        XCTAssertTrue(try XCTUnwrap(progress.meetings.first).progressing)
        XCTAssertTrue(try XCTUnwrap(progress.meetings.first).sections.isEmpty)
        for section in ["summary", "notes", "transcript"] {
            let blocks = try await progress.blocks(section)
            XCTAssertTrue(blocks.isEmpty)
        }
    }
    @MainActor func testMocksNeverPersistOrCallAPI() async throws {
        let suite = "meetings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for state in ["list", "detail", "progress", "empty", "settings"] {
            let store = NotionMeetingsStore(defaults: defaults, tokenProvider: { XCTFail("mock token access"); return nil },
                apiFactory: { _ in XCTFail("mock API access"); return NotionDatabaseAPI(token: "") }, previewState: state)
            store.fallback = "https://notion.so/0123456789abcdef0123456789abcdef"
            await store.refresh()
            _ = try await store.blocks("summary")
            XCTAssertNil(defaults.string(forKey: "notionMeetings.fallback"))
        }
    }
    #endif
}
