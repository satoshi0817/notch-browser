import XCTest
import AppKit
@testable import NotchBrowser

final class MeetingSearchTests: XCTestCase {
    func testDateWordsAreLiteralAndUnmatchedTermsDoNotMatch() {
        XCTAssertEqual(MeetingSearchQuery.parse(" 先月の採用 ").text, "先月の採用")
        let rows = [sentence("a", text: "先月の採用について確認する。")]
        XCTAssertEqual(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows,
                                               query: .parse("先月の採用")).first?.sentence, rows.first?.text)
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows,
                                               query: .parse("採用 予算 決算")).isEmpty)
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows,
                                               query: .parse("雇用")).isEmpty)
    }

    func testClearReturnsToDateOrderedList() {
        var input = MeetingSearchInputState()
        input.edit("先月の採用")
        XCTAssertEqual(input.mode, .searching)
        XCTAssertEqual(input.parsed().text, "先月の採用")
        input.escape()
        XCTAssertEqual(input.mode, .dateOrdered)
        XCTAssertEqual(input.text, "")
    }

    @MainActor func testBrowserEscapeControllerClearsOnceAndIsIsolated() {
        let controller = MeetingSearchEscapeController()
        let other = MeetingSearchEscapeController()
        controller.input.edit("採用"); controller.hasResults = true
        other.input.edit("別の検索")
        let reset = controller.resetID
        XCTAssertTrue(controller.clearIfActive(meetingsVisible: true))
        XCTAssertEqual(controller.input.mode, .dateOrdered)
        XCTAssertFalse(controller.hasResults)
        XCTAssertNotEqual(controller.resetID, reset)
        XCTAssertFalse(controller.clearIfActive(meetingsVisible: true))
        XCTAssertEqual(other.input.text, "別の検索")
    }

    func testOnlyTextSearchPreviewStatesRemain() {
        #if DEBUG
        XCTAssertEqual(Set(MeetingSearchPreviewState.allCases.map(\.rawValue)),
                       Set(["list", "results", "empty", "detail-highlight", "typing"]))
        for state in MeetingSearchPreviewState.allCases {
            let arguments = ["--meeting-search=\(state.rawValue)"]
            XCTAssertEqual(MeetingSearchPreviewState.parse(arguments: arguments), state)
            XCTAssertEqual(NotionConnectionStore.previewState(arguments: arguments), .connected)
        }
        for removed in ["preparing", "preparing-download", "preparing-compile", "preparing-ingest", "preparing-failed", "settings", "detail"] {
            XCTAssertNil(MeetingSearchPreviewState.parse(arguments: ["--meeting-search=\(removed)"]))
        }
        XCTAssertNil(SettingsPreviewLaunch.parse(arguments: ["--settings-pane=semantic-search"]))
        XCTAssertTrue(MeetingSearchPreviewState.detailHighlight.holdsHighlight)
        #endif
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ text: String) -> Date { NotionMessage.parseDate(text)! }
    private var now: Date { date("2026-10-14T12:00:00Z") }
    private func meeting(_ id: String = "a", status: String = "notes_ready", start: Date? = nil) -> NotionMeeting {
        .init(id: id, title: "採用会議", status: status, calendarStart: start, calendarEnd: start?.addingTimeInterval(2700), recordingStart: now, recordingEnd: nil,
              attendees: ["a", "b", "c"], summary: "summary", notes: "notes", transcript: "transcript", created: now, edited: now)
    }
    private func block(_ text: String, type: String = "paragraph", edited: String = "2026-10-14T12:01:00Z") -> NotionTaskBlock {
        .parse(["id": "block", "type": type, "last_edited_time": edited, type: ["rich_text": [["plain_text": text]]]], depth: 0)
    }
    private func sentence(_ id: String, text: String = "候補者の採用を進める") -> MeetingSearchSentence {
        .init(meetingID: id, sectionID: "notes", blockID: "block", text: text, edited: now)
    }
    func testFallbackMatchAndUnmatched() {
        let rows = [sentence("a")]
        XCTAssertEqual(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows, query: .init(text: "候補者")).first?.blockID, "block")
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows, query: .init(text: "予算")).isEmpty)
    }
    func testOnlyNotesReady() { XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting(status: "summarizing")], sentences: [sentence("a")], query: .init(text: "採用")).isEmpty) }
    func testTextResultsKeepTopTwentyAndOneHitPerMeeting() {
        let meetings = (0..<30).map { meeting(String($0)) }
        let rows = meetings.flatMap { [sentence($0.id), sentence($0.id)] }
        let hits = MeetingSearchRanking.hits(meetings: meetings, sentences: rows, query: .parse("採用"))
        XCTAssertEqual(hits.count, 20)
        XCTAssertEqual(Set(hits.map(\.meetingID)).count, 20)
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: meetings, sentences: rows, query: .parse("  ")).isEmpty)
    }
    func testSentenceSplitAndChildEditedTime() {
        let rows = MeetingSearchRanking.sentences(meeting: meeting(), section: "notes", blocks: [block("採用を進める。次回確認する！")])
        XCTAssertEqual(rows.map(\.text), ["採用を進める。", "次回確認する！"])
        XCTAssertEqual(rows.first?.edited, date("2026-10-14T12:01:00Z"))
    }
    func testImagesExcluded() {
        var image = block("画像説明", type: "image")
        image = .parse(["id": "image", "type": "image", "image": ["caption": [["plain_text": "画像説明"]], "type": "external", "external": ["url": "https://example.com/image"]]], depth: 0)
        XCTAssertTrue(MeetingSearchRanking.sentences(meeting: meeting(), section: "notes", blocks: [image]).isEmpty)
        XCTAssertTrue(MeetingSearchRanking.sentences(meeting: meeting(), section: "notes", blocks: [block("画像説明", type: "image")]).isEmpty)
    }
    func testEscapePriorityDependsOnVisibleMeetingsAndAnySearchState() {
        XCTAssertTrue(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: "採用", hasResults: false))
        XCTAssertTrue(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: "", hasResults: true))
        XCTAssertTrue(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: " ", hasResults: false))
        XCTAssertFalse(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: "", hasResults: false))
        XCTAssertFalse(MeetingSearchEscapeRules.shouldClear(meetingsVisible: false, text: "採用", hasResults: true))
    }
    @MainActor func testWindowFocusedEscapeClearsSearchBeforeExistingCancel() throws {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let controller = MeetingSearchEscapeController(); controller.input.edit("採用")
        var cancellations = 0
        panel.onEscape = { controller.clearIfActive(meetingsVisible: true) }
        panel.onCancel = { cancellations += 1 }
        panel.makeFirstResponder(nil)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.sendEvent(event)
        XCTAssertEqual(controller.input.mode, .dateOrdered); XCTAssertEqual(cancellations, 0)
        panel.cancelOperation(nil)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(panel.canBecomeKey)
    }
    func testResultRowHasCompactSpacingAndApproximately58PointHeight() {
        XCTAssertEqual(MeetingSearchRowLayout.resultHeight, 58)
        XCTAssertGreaterThanOrEqual(MeetingSearchRowLayout.lineSpacing, 2)
        XCTAssertLessThanOrEqual(MeetingSearchRowLayout.lineSpacing, 4)
    }
    func testHighlightHoldsThenFadesAndCannotRepeat() {
        var state = MeetingMatchHighlightState()
        XCTAssertEqual(state.phase, .idle); XCTAssertTrue(state.reveal())
        XCTAssertEqual(state.phase, .holding); XCTAssertEqual(state.opacity, 0.12)
        XCTAssertFalse(state.reveal())
        state.holdFinished(reduceMotion: false)
        XCTAssertEqual(state.phase, .fading); XCTAssertEqual(state.opacity, 0)
        state.fadeFinished(); XCTAssertEqual(state.phase, .dismissed); XCTAssertFalse(state.reveal())
        XCTAssertEqual(MeetingMatchHighlightState.holdSeconds, 2)
        XCTAssertEqual(MeetingMatchHighlightState.fadeSeconds, 1.2)
    }
    func testReduceMotionDismissesWithoutFade() {
        var state = MeetingMatchHighlightState(); _ = state.reveal()
        state.holdFinished(reduceMotion: true)
        XCTAssertEqual(state.phase, .dismissed); XCTAssertEqual(state.opacity, 0)
        state.fadeFinished(); XCTAssertEqual(state.phase, .dismissed)
        XCTAssertFalse(state.reveal())
    }
    func testHighlightIgnoresTimersBeforeReveal() {
        var state = MeetingMatchHighlightState()
        state.holdFinished(reduceMotion: false); state.fadeFinished()
        XCTAssertEqual(state.phase, .idle); XCTAssertTrue(state.reveal())
    }
    func testNormalMetadataUsesTimeAndSearchUsesDate() {
        let meeting = meeting(start: date("2026-09-11T01:41:00Z"))
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(meeting.rowMetadata(timeZone: zone), "1:41・45分・3人")
        XCTAssertEqual(meeting.listMetadata(timeZone: zone), "9/11・45分・3人")
    }
    func testMatchExpandsOnlyItsAncestorToggles() {
        func row(_ id: String, _ type: String, _ depth: Int) -> NotionTaskBlock {
            .parse(["id": id, "type": type, type: ["rich_text": [["plain_text": id]]]], depth: depth)
        }
        let blocks = [row("other", "toggle", 0), row("other-child", "paragraph", 1),
                      row("outer", "toggle", 0), row("inner", "toggle", 1), row("match", "paragraph", 2),
                      row("sibling", "paragraph", 0)]
        XCTAssertEqual(MeetingSearchBlockNavigation.expandedToggleIDs(for: "match", blocks: blocks), ["outer", "inner"])
        XCTAssertEqual(MeetingSearchBlockNavigation.expandedToggleIDs(for: "inner", blocks: blocks), ["outer"])
        XCTAssertTrue(MeetingSearchBlockNavigation.expandedToggleIDs(for: "sibling", blocks: blocks).isEmpty)
        XCTAssertTrue(MeetingSearchBlockNavigation.expandedToggleIDs(for: nil, blocks: blocks).isEmpty)
    }
    func testBlockParsingPreserves018SpeechAndChildEditedTime() {
        let block = NotionTaskBlock.parse(["id": "speech", "type": "paragraph", "last_edited_time": "2026-10-14T12:01:00Z",
                                          "paragraph": ["rich_text": [["plain_text": "採用の話"]], "speaker": ["name": "話者"], "start_time": "1:41"]], depth: 1)
        XCTAssertEqual(block.speaker, "話者"); XCTAssertEqual(block.timestamp, "1:41")
        XCTAssertEqual(block.edited, date("2026-10-14T12:01:00Z"))
        XCTAssertEqual(block.text, "採用の話"); XCTAssertEqual(block.depth, 1)
    }
    @MainActor func testIndexUsesChildrenIDsAnd018PaginatedRecursiveBodies() async throws {
        let parsed = try XCTUnwrap(NotionMeeting.parse([
            "id": "meeting", "type": "meeting_notes",
            "meeting_notes": ["title": "採用", "status": "notes_ready", "summary": "legacy-summary",
                              "children": ["summary_block_id": "summary-new", "notes_block_id": "notes-new", "transcript_block_id": "transcript-new"]]
        ]))
        var paths: [String] = []; var cursors: [String] = []
        let api = NotionDatabaseAPI(token: "fixture", fetch: { request in
            let path = try XCTUnwrap(request.url?.path); paths.append(path)
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "start_cursor" }?.value
            if let cursor { cursors.append(cursor) }
            func row(_ id: String, _ text: String) -> [String: Any] {
                ["id": id, "type": "paragraph", "paragraph": ["rich_text": [["plain_text": text]]]]
            }
            let response: [String: Any]
            switch path {
            case "/v1/blocks/summary-new/children" where cursor == nil:
                response = ["results": [row("first", "採用の候補者を確認する。")], "has_more": true, "next_cursor": "page-two"]
            case "/v1/blocks/summary-new/children":
                response = ["results": [["id": "nested", "type": "toggle", "has_children": true, "toggle": ["rich_text": []]]], "has_more": false]
            case "/v1/blocks/nested/children": response = ["results": [row("child", "面接日程を決める。")], "has_more": false]
            case "/v1/blocks/notes-new/children": response = ["results": [row("notes", "採用の条件を整理する。")], "has_more": false]
            default: XCTFail("Unexpected body request: \(path)"); response = ["results": [], "has_more": false]
            }
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let store = MeetingSearchStore()
        await store.index(meetings: [parsed]) { try await api.meetingBody($0) }
        XCTAssertEqual(store.sentences.count, 3)
        XCTAssertEqual(Set(store.sentences.map(\.sectionID)), ["summary-new", "notes-new"])
        XCTAssertTrue(store.sentences.contains { $0.blockID == "child" && $0.text == "面接日程を決める。" })
        XCTAssertEqual(cursors, ["page-two"])
        XCTAssertFalse(paths.contains { $0.contains("transcript") || $0.contains("legacy-summary") })
    }
    @MainActor func testSameMinuteRefetchesChangedBody() async {
        let store = MeetingSearchStore()
        await store.index(meetings: [meeting()]) { _ in [self.block("旧内容")] }
        await store.index(meetings: [meeting()]) { _ in [self.block("更新内容")] }
        XCTAssertEqual(Set(store.sentences.map(\.text)), ["更新内容"])
    }
    @MainActor func testFailedFetchDropsStaleSentences() async {
        let store = MeetingSearchStore()
        await store.index(meetings: [meeting()]) { _ in [self.block("旧内容")] }
        await store.index(meetings: [meeting()]) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(store.sentences.isEmpty)
    }
    @MainActor func testRemovedMeetingIsRemovedFromIndex() async {
        let store = MeetingSearchStore()
        await store.index(meetings: [meeting()]) { _ in [self.block("内容")] }
        await store.index(meetings: []) { _ in XCTFail("No body should be requested"); return [] }
        XCTAssertTrue(store.sentences.isEmpty)
    }
    func testCalendarEventStartDecode() throws {
        let meeting = try XCTUnwrap(NotionMeeting.parse(["id": "a", "type": "meeting_notes", "meeting_notes": ["title": "会議", "status": "notes_ready", "calendar_event": ["start": "2026-10-14T12:00:00Z"]]]))
        XCTAssertEqual(meeting.calendarStart, now)
    }
    func testMetadataSeparator() { XCTAssertEqual(meeting(start: now).listMetadata(timeZone: TimeZone(secondsFromGMT: 0)!), "10/14・45分・3人") }

}
