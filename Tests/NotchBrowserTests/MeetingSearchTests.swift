import XCTest
import AppKit
@testable import NotchBrowser

private struct FakeMeetingEmbedding: MeetingEmbeddingProvider {
    let identity = MeetingEmbeddingIdentity(model: "fake", dimensions: 256, documentPrefix: "doc:", queryPrefix: "query:")
    func prepare() async throws {}
    func embedding(_ text: String, isQuery: Bool) async throws -> [Float] { [1] + Array(repeating: 0, count: 255) }
}
private struct UnavailableMeetingEmbedding: MeetingEmbeddingProvider {
    let identity = FakeMeetingEmbedding().identity
    func prepare() async throws { throw MeetingModelError.unconfigured }
    func embedding(_ text: String, isQuery: Bool) async throws -> [Float] { throw MeetingModelError.invalidEmbedding }
}

final class MeetingSearchTests: XCTestCase {
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
    private func sentence(_ id: String, text: String = "候補者の採用を進める", vector: [Float] = []) -> MeetingSearchSentence {
        .init(meetingID: id, sectionID: "notes", blockID: "block", text: text, edited: now, vector: vector)
    }
    func testPreviousMonthAndRemainder() {
        let query = MeetingSearchQuery.parse("先月の採用", now: now, calendar: calendar)
        XCTAssertEqual(query.text, "採用"); XCTAssertEqual(query.range?.start, date("2026-09-01T00:00:00Z")); XCTAssertEqual(query.range?.end, date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(query.range?.label(calendar: calendar), "9月1日〜9月30日")
    }
    func testPreviousWeek() {
        let query = MeetingSearchQuery.parse("先週の採用", now: now, calendar: calendar)
        XCTAssertEqual(query.range?.start, date("2026-10-05T00:00:00Z")); XCTAssertEqual(query.range?.end, date("2026-10-12T00:00:00Z"))
    }
    func testExplicitMonth() {
        let query = MeetingSearchQuery.parse("10月の採用", now: now, calendar: calendar)
        XCTAssertEqual(query.text, "採用"); XCTAssertEqual(query.range?.start, date("2026-10-01T00:00:00Z"))
    }
    func testExplicitYear() { XCTAssertEqual(MeetingSearchQuery.parse("2025年12月の採用", now: now, calendar: calendar).range?.start, date("2025-12-01T00:00:00Z")) }
    func testLeapMonth() { XCTAssertEqual(MeetingSearchQuery.parse("2024年2月", now: now, calendar: calendar).range?.label(calendar: calendar), "2月1日〜2月29日") }
    func testNoDateExpression() { XCTAssertNil(MeetingSearchQuery.parse("採用", now: now, calendar: calendar).range) }
    func testInvalidMonthIsNotPartiallyParsed() { XCTAssertNil(MeetingSearchQuery.parse("13月の採用", now: now, calendar: calendar).range) }
    func testCurrentMonthAndWeek() {
        XCTAssertEqual(MeetingSearchQuery.parse("今月", now: now, calendar: calendar).range?.start, date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(MeetingSearchQuery.parse("今週", now: now, calendar: calendar).range?.start, date("2026-10-12T00:00:00Z"))
    }
    func testExclusiveEndAndMissingDate() {
        let range = MeetingSearchQuery.parse("先月", now: now, calendar: calendar).range!
        XCTAssertTrue(range.contains(range.start)); XCTAssertFalse(range.contains(range.end)); XCTAssertFalse(range.contains(nil))
    }
    func testRangeUsesCalendarEventOnly() {
        let query = MeetingSearchQuery.parse("今月", now: now, calendar: calendar)
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting()], sentences: [], query: query).isEmpty)
        XCTAssertEqual(MeetingSearchRanking.hits(meetings: [meeting(start: now)], sentences: [], query: query).count, 1)
    }
    func testFallbackMatchAndUnmatched() {
        let rows = [sentence("a")]
        XCTAssertEqual(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows, query: .init(text: "候補者", range: nil)).first?.blockID, "block")
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting()], sentences: rows, query: .init(text: "予算", range: nil)).isEmpty)
    }
    func testOnlyNotesReady() { XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting(status: "summarizing")], sentences: [sentence("a")], query: .init(text: "採用", range: nil)).isEmpty) }
    func testTopTwentyAndDeduplication() {
        let meetings = (0..<30).map { meeting(String($0)) }
        let rows = meetings.flatMap { [sentence($0.id), sentence($0.id)] }
        let hits = MeetingSearchRanking.hits(meetings: meetings, sentences: rows, query: .init(text: "採用", range: nil))
        XCTAssertEqual(hits.count, 20); XCTAssertEqual(Set(hits.map(\.id)).count, 20)
    }
    func testSemanticOrderAndThreshold() {
        let unit = [Float(1)] + Array(repeating: Float(0), count: 255)
        let rows = [sentence("a", vector: unit), sentence("b", vector: unit.map { $0 * 0.6 }), sentence("c", vector: unit.map { $0 * 0.1 })]
        XCTAssertEqual(MeetingSearchRanking.hits(meetings: [meeting("b"), meeting("c"), meeting("a")], sentences: rows, query: .init(text: "雇用", range: nil), queryVector: unit).map(\.id), ["a", "b"])
    }
    func testTruncateAndNormalize() {
        let values = MeetingSearchRanking.normalized(Array(repeating: Float(1), count: 768))
        XCTAssertEqual(values.count, 256); XCTAssertEqual(values.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
        XCTAssertTrue(MeetingSearchRanking.normalized([1]).isEmpty)
        XCTAssertTrue(MeetingSearchRanking.normalized(Array(repeating: 0, count: 256)).isEmpty)
        XCTAssertTrue(MeetingSearchRanking.normalized(Array(repeating: .nan, count: 256)).isEmpty)
    }
    func testCacheExcludesTranscriptAndOtherStatuses() {
        XCTAssertTrue(MeetingSearchRanking.sentences(meeting: meeting(), section: "transcript", blocks: [block("秘密")]).isEmpty)
        XCTAssertTrue(MeetingSearchRanking.sentences(meeting: meeting(status: "transcribing"), section: "notes", blocks: [block("秘密")]).isEmpty)
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
    func testCacheRoundTripAndIdentityChanges() throws {
        let identity = FakeMeetingEmbedding().identity
        let cache = MeetingSearchCache(identity: identity, sentences: [sentence("a")], updated: now)
        let decoded = try JSONDecoder().decode(MeetingSearchCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(decoded.identity, identity); XCTAssertEqual(decoded.sentences, cache.sentences)
        XCTAssertNotEqual(identity, MeetingEmbeddingIdentity(model: "new", dimensions: 256, documentPrefix: "doc:", queryPrefix: "query:"))
        XCTAssertNotEqual(identity, MeetingEmbeddingIdentity(model: "fake", dimensions: 768, documentPrefix: "doc:", queryPrefix: "query:"))
        XCTAssertNotEqual(identity, MeetingEmbeddingIdentity(model: "fake", dimensions: 256, documentPrefix: "changed:", queryPrefix: "query:"))
    }
    @MainActor func testChangedIdentityDiscardsPersistedCache() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/tmp/meeting-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let identity = FakeMeetingEmbedding().identity
        let alternatives = [
            identity,
            MeetingEmbeddingIdentity(model: "new", dimensions: 256, documentPrefix: "doc:", queryPrefix: "query:"),
            MeetingEmbeddingIdentity(model: "fake", dimensions: 768, documentPrefix: "doc:", queryPrefix: "query:"),
            MeetingEmbeddingIdentity(model: "fake", dimensions: 256, documentPrefix: "changed:", queryPrefix: "query:"),
            MeetingEmbeddingIdentity(model: "fake", dimensions: 256, documentPrefix: "doc:", queryPrefix: "changed:"),
            MeetingEmbeddingIdentity(model: "fake", dimensions: 256, documentPrefix: "doc:", queryPrefix: "query:", revision: "new-revision")
        ]
        for savedIdentity in alternatives {
            let cache = MeetingSearchCache(identity: savedIdentity, sentences: [sentence("a")], updated: now)
            try JSONEncoder().encode(cache).write(to: url)
            let store = MeetingSearchStore(provider: FakeMeetingEmbedding(), cacheURL: url)
            XCTAssertEqual(store.sentences.count, savedIdentity == identity ? 1 : 0)
        }
    }
    func testSHA256RejectsMismatch() {
        XCTAssertTrue(MeetingModelManifest.verify(Data("abc".utf8), sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        XCTAssertFalse(MeetingModelManifest.verify(Data("tampered".utf8), sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    }
    func testTokenizerChoosesGlobalUnigramScore() throws {
        let rows: [[Any]] = [["▁", -1.0], ["a", -2.0], ["b", -2.0], ["ab", -1.0], ["▁a", -1.0], ["▁ab", -5.0]]
        let data = try JSONSerialization.data(withJSONObject: ["model": ["type": "Unigram", "vocab": rows]])
        let tokenizer = try MeetingUnigramTokenizer(data: data)
        XCTAssertEqual(try tokenizer.encode("ab", limit: 100), [0, 3])
        XCTAssertEqual(try tokenizer.encode("ab", limit: 1), [0])
    }
    func testTokenizerByteFallbackAndUnsupportedFormat() throws {
        let rows: [[Any]] = [["▁", -1.0], ["<0xE7>", 0.0], ["<0x8C>", 0.0], ["<0xAB>", 0.0]]
        let data = try JSONSerialization.data(withJSONObject: ["model": ["type": "Unigram", "vocab": rows]])
        let tokenizer = try MeetingUnigramTokenizer(data: data)
        XCTAssertEqual(try tokenizer.encode("猫", limit: 100), [0, 1, 2, 3])
        XCTAssertThrowsError(try tokenizer.encode("犬", limit: 100))
        let unsupported = try JSONSerialization.data(withJSONObject: ["model": ["type": "BPE", "vocab": rows]])
        XCTAssertThrowsError(try MeetingUnigramTokenizer(data: unsupported))
    }
    func testPinnedTextManifestAndSHA256Integrity() {
        XCTAssertTrue(MeetingModelManifest.configured)
        XCTAssertEqual(MeetingModelManifest.artifacts.count, 6)
        XCTAssertFalse(MeetingModelManifest.artifacts.contains { $0.path.contains("Audio") || $0.path.contains("Vision") || $0.path.contains("position_embeddings") })
        XCTAssertEqual(MeetingModelManifest.identity.revision, "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4")
        let artifact = MeetingModelManifest.Artifact(path: "fixture.json", size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(MeetingModelManifest.verify(Data("abc".utf8), artifact: artifact))
        XCTAssertFalse(MeetingModelManifest.verify(Data("abd".utf8), artifact: artifact))
        XCTAssertFalse(MeetingModelManifest.verify(Data("abc\n".utf8), artifact: artifact))
        XCTAssertEqual(MeetingModelManifest.downloadURL(MeetingModelManifest.artifacts[0]).absoluteString,
                       "https://huggingface.co/FluidInference/embeddinggemma-2-coreml/resolve/3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4/EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel")
    }
    func testSmallestCoreMLFunctionSelection() {
        for (tokens, expected) in [(0, 32), (32, 32), (33, 48), (48, 48), (49, 64), (64, 64), (65, 128), (128, 128), (129, 256), (256, 256), (257, 512), (512, 512), (513, 512)] {
            XCTAssertEqual(MeetingModelManifest.functionLength(tokenCount: tokens), expected)
        }
    }
    func testStreamingArtifactVerificationRejectsTampering() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/tmp/meeting-artifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        let sha = MeetingModelManifest.Artifact(path: "fixture.json", size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("abc".utf8).write(to: url)
        XCTAssertTrue(try MeetingModelManifest.verifyFile(url, artifact: sha))
        XCTAssertNoThrow(try MeetingModelManifest.requireVerifiedFile(url, artifact: sha))
        try Data("abd".utf8).write(to: url)
        XCTAssertFalse(try MeetingModelManifest.verifyFile(url, artifact: sha))
        try Data("abc\n".utf8).write(to: url)
        XCTAssertFalse(try MeetingModelManifest.verifyFile(url, artifact: sha))
        XCTAssertThrowsError(try MeetingModelManifest.requireVerifiedFile(url, artifact: sha))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testEveryDownloadedFileHasPinnedSizeAndContentSHA256() {
        let expected: [String: (Int, String)] = [
            "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel": (7_323_423, "0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677"),
            "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin": (276_815_424, "75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f"),
            "EmbeddingGemma2Text.mlpackage/Manifest.json": (617, "83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19"),
            "embeddings.bf16": (268_435_456, "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877"),
            "tokenizer.json": (32_170_510, "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
            "config.json": (2_845, "30668aba89f54a200a3fa38913f21e2a2f18aba7215de67c1806542a75b9629b")
        ]
        XCTAssertEqual(Set(MeetingModelManifest.artifacts.map(\.path)), Set(expected.keys))
        for artifact in MeetingModelManifest.artifacts {
            XCTAssertEqual(artifact.size, expected[artifact.path]?.0)
            XCTAssertEqual(artifact.sha256, expected[artifact.path]?.1)
            XCTAssertEqual(artifact.sha256.count, 64)
        }
    }
    func testEscapeReturnsToDateOrderedListAndClearsRange() {
        var input = MeetingSearchInputState()
        input.edit("先月の採用")
        XCTAssertEqual(input.mode, .searching)
        XCTAssertNotNil(input.parsed(now: now, calendar: calendar).range)
        input.allPeriods(); XCTAssertNil(input.parsed(now: now, calendar: calendar).range)
        input.escape()
        XCTAssertEqual(input.mode, .dateOrdered); XCTAssertEqual(input.text, ""); XCTAssertFalse(input.ignoresDateRange)
        XCTAssertNil(input.parsed(now: now, calendar: calendar).range)
    }
    func testEscapePriorityDependsOnVisibleMeetingsAndAnySearchState() {
        XCTAssertTrue(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: "採用", hasResults: false))
        XCTAssertTrue(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: "", hasResults: true))
        XCTAssertTrue(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: " ", hasResults: false))
        XCTAssertFalse(MeetingSearchEscapeRules.shouldClear(meetingsVisible: true, text: "", hasResults: false))
        XCTAssertFalse(MeetingSearchEscapeRules.shouldClear(meetingsVisible: false, text: "採用", hasResults: true))
    }
    @MainActor func testBrowserEscapeControllerClearsOnceAndIsIsolated() {
        let controller = MeetingSearchEscapeController(); let other = MeetingSearchEscapeController()
        controller.input.edit("先月の採用"); controller.input.allPeriods(); controller.hasResults = true
        other.input.edit("別の検索")
        let reset = controller.resetID
        XCTAssertTrue(controller.clearIfActive(meetingsVisible: true))
        XCTAssertEqual(controller.input.mode, .dateOrdered); XCTAssertFalse(controller.hasResults)
        XCTAssertFalse(controller.input.ignoresDateRange); XCTAssertNotEqual(controller.resetID, reset)
        XCTAssertFalse(controller.clearIfActive(meetingsVisible: true))
        XCTAssertEqual(other.input.text, "別の検索")
        controller.input.edit("採用")
        XCTAssertFalse(controller.clearIfActive(meetingsVisible: false)); XCTAssertEqual(controller.input.text, "採用")
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
    func testEditedQueryRestoresDateParsingAfterAllPeriods() {
        var input = MeetingSearchInputState(); input.edit("先月の採用"); input.allPeriods()
        input.edit("今月の採用")
        XCTAssertEqual(input.parsed(now: now, calendar: calendar).range?.start, date("2026-10-01T00:00:00Z"))
        input.edit("  "); XCTAssertEqual(input.mode, .dateOrdered)
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
    func testJapaneseSearchUpdateDate() {
        XCTAssertEqual(MeetingSearchDateLabels.updated(date("2026-10-14T01:37:00Z"), timeZone: TimeZone(identifier: "Asia/Tokyo")!), "10月14日 10:37")
        XCTAssertEqual(MeetingSearchDateLabels.updated(nil), "未更新")
    }
    func testNormalMetadataUsesTimeAndSearchUsesDate() {
        let meeting = meeting(start: date("2026-09-11T01:41:00Z"))
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(meeting.rowMetadata(timeZone: zone), "1:41・45分・3人")
        XCTAssertEqual(meeting.listMetadata(timeZone: zone), "9/11・45分・3人")
    }
    func testAllSemanticPreviewStatesAndHighlightAlias() {
        #if DEBUG
        for state in MeetingSearchPreviewState.allCases {
            XCTAssertEqual(MeetingSearchPreviewState.parse(arguments: ["--meeting-search=\(state.rawValue)"]), state)
        }
        XCTAssertTrue(MeetingSearchPreviewState.detailHighlight.holdsHighlight)
        XCTAssertTrue(MeetingSearchPreviewState.detail.holdsHighlight)
        XCTAssertFalse(MeetingSearchPreviewState.typing.holdsHighlight)
        #endif
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
        let store = MeetingSearchStore(provider: FakeMeetingEmbedding(), persist: false)
        await store.index(meetings: [parsed]) { try await api.meetingBody($0) }
        XCTAssertEqual(store.sentences.count, 3)
        XCTAssertEqual(Set(store.sentences.map(\.sectionID)), ["summary-new", "notes-new"])
        XCTAssertTrue(store.sentences.contains { $0.blockID == "child" && $0.text == "面接日程を決める。" })
        XCTAssertEqual(cursors, ["page-two"])
        XCTAssertFalse(paths.contains { $0.contains("transcript") || $0.contains("legacy-summary") })
    }
    func testBF16RowsScalingAndRightPadding() throws {
        let data = Data([0x00, 0x00, 0x80, 0x3f, 0x00, 0x40, 0x80, 0xbf]) // [0, 1], [2, -1]
        let table = try MeetingEmbeddingTable(data: data, rows: 2, dimensions: 2)
        let values = try table.inputValues(tokens: [1], length: 2)
        XCTAssertEqual(values.map(Float.init), [45.25, -22.625, 0, 22.625])
        XCTAssertThrowsError(try table.inputValues(tokens: [2], length: 1))
        XCTAssertThrowsError(try table.inputValues(tokens: [-1], length: 1))
        XCTAssertThrowsError(try table.inputValues(tokens: [1, 1], length: 1))
        XCTAssertThrowsError(try MeetingEmbeddingTable(data: data.dropLast(), rows: 2, dimensions: 2))
        let invalid = try MeetingEmbeddingTable(data: Data([0xc0, 0x7f]), rows: 1, dimensions: 1)
        XCTAssertThrowsError(try invalid.inputValues(tokens: [0], length: 1))
    }
    private func bpeFixture(normalizer: Any = NSNull(), pretokenizer: Any = NSNull(), added: [[String: Any]] = []) throws -> Data {
        let vocabulary = ["a": 3, "b": 4, "ba": 5, "ab": 6, "bab": 7, "▁": 8, "▁a": 9, "▁ab": 10,
                          "<0xE7>": 11, "<0x8C>": 12, "<0xAB>": 13]
        return try JSONSerialization.data(withJSONObject: [
            "model": ["type": "BPE", "vocab": vocabulary, "merges": [["▁", "a"], ["▁a", "b"], ["b", "a"], ["a", "b"], ["ba", "b"]], "byte_fallback": true],
            "normalizer": normalizer, "pre_tokenizer": pretokenizer, "added_tokens": added,
            "post_processor": ["type": "TemplateProcessing", "single": [["SpecialToken": ["id": "<bos>", "type_id": 0]], ["Sequence": ["id": "A", "type_id": 0]], ["SpecialToken": ["id": "<eos>", "type_id": 0]]],
                               "special_tokens": ["<bos>": ["ids": [2]], "<eos>": ["ids": [1]]]]
        ])
    }
    func testBPEMergePriorityAndByteFallback() throws {
        let tokenizer = try MeetingGemmaTokenizer(data: bpeFixture())
        XCTAssertEqual(try tokenizer.encode("abab"), [2, 3, 7, 1])
        XCTAssertEqual(try tokenizer.encode("猫"), [2, 11, 12, 13, 1])
        XCTAssertThrowsError(try tokenizer.encode("犬"))
    }
    func testBPEUsesFileNormalizationAndSplitRules() throws {
        let normalizer: [String: Any] = ["type": "Sequence", "normalizers": [["type": "Prepend", "prepend": "▁"], ["type": "Replace", "pattern": ["String": " "], "content": "▁"]]]
        let pretokenizer: [String: Any] = ["type": "Split", "pattern": ["String": "▁"], "behavior": "MergedWithNext", "invert": false]
        let tokenizer = try MeetingGemmaTokenizer(data: bpeFixture(normalizer: normalizer, pretokenizer: pretokenizer))
        XCTAssertEqual(try tokenizer.encode("ab ab"), [2, 10, 10, 1])
        XCTAssertThrowsError(try MeetingGemmaTokenizer(data: bpeFixture(normalizer: ["type": "unknown"])))
    }
    func testBPESpecialTokensAnd512TokenTruncation() throws {
        let tokenizer = try MeetingGemmaTokenizer(data: bpeFixture(added: [["id": 15, "content": "<tag>", "normalized": false, "single_word": false, "lstrip": true, "rstrip": true]]))
        XCTAssertEqual(try tokenizer.encode("ab <tag> ab"), [2, 6, 15, 6, 1])
        let tokens = try tokenizer.encode(String(repeating: "ab", count: 2_000))
        XCTAssertEqual(tokens.count, 512); XCTAssertEqual(tokens.first, 2); XCTAssertEqual(tokens.last, 1)
    }
    @MainActor func testFakeProviderIndexSearchAndClear() async {
        let store = MeetingSearchStore(provider: FakeMeetingEmbedding(), persist: false)
        await store.index(meetings: [meeting(start: now)]) { _ in [self.block("候補者の採用を進める")] }
        XCTAssertEqual(store.completed, 1); XCTAssertEqual(store.sentences.count, 2)
        let hits = await store.search(meetings: [meeting(start: now)], query: .init(text: "採用", range: nil))
        XCTAssertEqual(hits.count, 1)
        store.clear(); XCTAssertTrue(store.sentences.isEmpty); XCTAssertNil(store.updated)
    }
    @MainActor func testUnavailableModelFallsBackToText() async {
        let store = MeetingSearchStore(provider: UnavailableMeetingEmbedding(), persist: false)
        await store.index(meetings: [meeting()]) { _ in [self.block("候補者を面接する")] }
        XCTAssertFalse(store.ready); XCTAssertFalse(store.preparing)
        let hits = await store.search(meetings: [meeting()], query: .init(text: "面接", range: nil))
        XCTAssertEqual(hits.first?.sentence, "候補者を面接する")
    }
    @MainActor func testSameMinuteRefetchesChangedBody() async {
        let store = MeetingSearchStore(provider: FakeMeetingEmbedding(), persist: false)
        await store.index(meetings: [meeting()]) { _ in [self.block("旧内容")] }
        await store.index(meetings: [meeting()]) { _ in [self.block("更新内容")] }
        XCTAssertEqual(Set(store.sentences.map(\.text)), ["更新内容"])
    }
    @MainActor func testFailedFetchDropsStaleSentences() async {
        let store = MeetingSearchStore(provider: FakeMeetingEmbedding(), persist: false)
        await store.index(meetings: [meeting()]) { _ in [self.block("旧内容")] }
        await store.index(meetings: [meeting()]) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(store.sentences.isEmpty)
    }
    @MainActor func testRemovedMeetingIsRemovedFromIndex() async {
        let store = MeetingSearchStore(provider: FakeMeetingEmbedding(), persist: false)
        await store.index(meetings: [meeting()]) { _ in [self.block("内容")] }
        await store.index(meetings: []) { _ in XCTFail("No body should be requested"); return [] }
        XCTAssertTrue(store.sentences.isEmpty)
    }
    func testCalendarEventStartDecode() throws {
        let meeting = try XCTUnwrap(NotionMeeting.parse(["id": "a", "type": "meeting_notes", "meeting_notes": ["title": "会議", "status": "notes_ready", "calendar_event": ["start": "2026-10-14T12:00:00Z"]]]))
        XCTAssertEqual(meeting.calendarStart, now)
    }
    func testAllPeriodKeepsRemainingTerms() {
        let parsed = MeetingSearchQuery.parse("先月の採用", now: now, calendar: calendar)
        let allDates = MeetingSearchQuery(text: parsed.text, range: nil)
        XCTAssertTrue(MeetingSearchRanking.hits(meetings: [meeting(start: now)], sentences: [sentence("a")], query: parsed).isEmpty)
        XCTAssertEqual(MeetingSearchRanking.hits(meetings: [meeting(start: now)], sentences: [sentence("a")], query: allDates).count, 1)
    }
    func testMetadataSeparator() { XCTAssertEqual(meeting(start: now).listMetadata(timeZone: TimeZone(secondsFromGMT: 0)!), "10/14・45分・3人") }
    func testDebugSettingsLaunch() {
        #if DEBUG
        XCTAssertEqual(SettingsPreviewLaunch.parse(arguments: ["--settings-pane=semantic-search"])?.section, .semanticSearch)
        #endif
    }
}
