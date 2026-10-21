import XCTest
@testable import NotchBrowser

final class Notch020Tests: XCTestCase {
    private func row(_ id: String, title: String = "本文", edited: Date = .distantPast) -> NotionTask {
        .init(id: id, title: title, url: nil, status: "", completed: false, due: nil, edited: edited)
    }
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("notch020-\(UUID()).json") }
    func testDeltaKeepsUnchangedRowsAndFullFetchDeletesAbsentRows() {
        let old = [row("a"), row("b")]
        let delta = NotionPageRefreshRules.merge(old, fetched: [row("b", title: "変更"), row("c")], full: false)
        XCTAssertEqual(delta.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(delta[0], old[0]); XCTAssertEqual(delta[1].title, "変更")
        let full = NotionPageRefreshRules.merge(delta, fetched: [row("b", title: "変更")], full: true)
        XCTAssertEqual(full.map(\.id), ["b"])
        XCTAssertTrue(NotionPageRefreshRules.deletedSelection("a", rows: full))
        XCTAssertFalse(NotionPageRefreshRules.deletedSelection("b", rows: full))
        XCTAssertFalse(NotionPageRefreshRules.deletedSelection(nil, rows: full))
    }
    func testSingleFlightSixtySecondSkipAndDailyFullFetch() {
        let now = Date()
        for force in [true, false] {
            XCTAssertFalse(NotionPageRefreshRules.shouldStart(refreshing: true, force: force, updated: nil, now: now))
        }
        XCTAssertFalse(NotionPageRefreshRules.shouldStart(refreshing: false, force: false, updated: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(NotionPageRefreshRules.shouldStart(refreshing: false, force: false, updated: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(NotionPageRefreshRules.shouldStart(refreshing: false, force: true, updated: now, now: now))
        XCTAssertFalse(NotionPageRefreshRules.full(force: false, updated: now.addingTimeInterval(-86399), now: now))
        XCTAssertTrue(NotionPageRefreshRules.full(force: false, updated: now.addingTimeInterval(-86400), now: now))
        XCTAssertTrue(NotionPageRefreshRules.full(force: true, updated: now, now: now))
    }
    func testVersionAndScopeMismatchDiscardFile() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let cache = NotionPageCache<NotionTask>(name: "test", url: url)
        let snapshot = NotionPageSnapshot(scope: "source", rows: [row("a")])
        cache.save(snapshot)
        XCTAssertEqual(cache.load(scope: "source").rows.count, 1)
        XCTAssertTrue(cache.load(scope: "other").rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        var future = snapshot; future.version = 2; cache.save(future)
        XCTAssertTrue(cache.load(scope: "source").rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor func testTokenNeverEntersFileAndAllTaskInvalidationConditions() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let suite = "notch020-\(UUID())"
        let defaults = TestDefaults.make(suite, test: self)
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = "secret-test-token-never-serialize"
        let store = NotionTasksStore(defaults: defaults, tokenProvider: { token }, apiFactory: { token in
            NotionDatabaseAPI(token: token) { request in
                let json: String
                if request.url!.path.contains("databases/") {
                    json = "{\"object\":\"database\",\"title\":[],\"data_sources\":[{\"id\":\"source\"}]}"
                } else if request.url!.path.hasSuffix("/query") {
                    json = "{\"results\":[{\"id\":\"a\",\"properties\":{}}],\"has_more\":false}"
                } else { json = "{\"properties\":{}}" }
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }, cacheURL: url)
        store.configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
        await store.configure()
        XCTAssertTrue(store.hasCache)
        XCTAssertFalse(try String(contentsOf: url).contains(token))
        XCTAssertEqual(try JSONDecoder().decode(NotionPageSnapshot<NotionTask>.self, from: Data(contentsOf: url)).rows.count, 1)
        store.configuration.source = "another"
        XCTAssertFalse(store.hasCache); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await store.configure()
        XCTAssertTrue(store.hasCache)
        store.configuration.url = "https://notion.so/ffffffffffffffffffffffffffffffff"
        XCTAssertFalse(store.hasCache)
        await store.configure()
        XCTAssertTrue(store.hasCache)
        store.connectionChanged()
        XCTAssertFalse(store.hasCache)
        await store.configure()
        XCTAssertTrue(store.hasCache)
        store.clearCache()
        XCTAssertTrue(store.tasks.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testImageURLsAreNeverSaved() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let cache = NotionPageCache<NotionTask>(name: "test", url: url)
        let block = NotionTaskBlock.parse(["id": "image", "type": "image", "image": ["type": "external", "external": ["url": "https://image.invalid/signed-secret"]]], depth: 0)
        cache.save(.init(scope: "source", rows: [row("a")], bodies: ["a": [block]]))
        XCTAssertFalse(try String(contentsOf: url).contains("signed-secret"))
        XCTAssertNil(cache.load(scope: "source").bodies["a"]?.first?.image)
    }
    @MainActor func testNewCacheLimitsSavedDisplayedAndFetchedRowsToOneThousand() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let suite = "notch020-limit-\(UUID())"
        let defaults = TestDefaults.make(suite, test: self)
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = NotionTasksStore.Configuration()
        configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
        configuration.confirmedURL = configuration.url
        configuration.source = "source"; configuration.mappedSource = "source"
        defaults.set(try JSONEncoder().encode(configuration), forKey: "notionTasks.configuration")
        let rows = (0..<1005).map { row("\($0)") }
        let cache = NotionPageCache<NotionTask>(name: "test", url: url)
        let scope = configuration.url + "|source"
        cache.save(.init(scope: scope, rows: rows, updated: Date()))
        func savedRows() throws -> [NotionTask] {
            try JSONDecoder().decode(NotionPageSnapshot<NotionTask>.self, from: Data(contentsOf: url)).rows
        }
        XCTAssertEqual(try savedRows(), Array(rows.prefix(1000)))
        let store = NotionTasksStore(defaults: defaults, tokenProvider: { "test-token" }, apiFactory: { token in
            NotionDatabaseAPI(token: token) { request in
                let object: [String: Any]
                if request.url!.path.contains("databases/") {
                    object = ["object": "database", "title": [], "data_sources": [["id": "source"]]]
                } else if request.url!.path.hasSuffix("/query") {
                    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                    let start = (body["start_cursor"] as? String).flatMap(Int.init) ?? 0
                    let end = min(start + 100, 1005)
                    var page: [String: Any] = ["results": (start..<end).map { ["id": "\($0)", "properties": [:]] as [String: Any] }, "has_more": end < 1005]
                    if end < 1005 { page["next_cursor"] = "\(end)" }
                    object = page
                } else { object = ["properties": [:]] }
                return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }, cacheURL: url)
        XCTAssertEqual(store.tasks, Array(rows.prefix(1000)))
        XCTAssertEqual(NotionTaskRules.rows(store.tasks, filter: .all).count, 1000)
        await store.refresh()
        XCTAssertNil(store.message)
        XCTAssertEqual(store.tasks.count, 1000)
        XCTAssertEqual(try savedRows().map(\.id), store.tasks.map(\.id))
        XCTAssertEqual(try savedRows().count, 1000)

        // A previously oversized v1 file must also be bounded on load and rewritten.
        try JSONEncoder().encode(NotionPageSnapshot(scope: scope, rows: rows, updated: Date())).write(to: url)
        let restored = NotionTasksStore(defaults: defaults, tokenProvider: { nil }, cacheURL: url)
        XCTAssertEqual(restored.tasks.count, 1000)
        XCTAssertEqual(try savedRows().count, 1000)
    }
    @MainActor func testFailureKeepsCacheAndFirstFailureHasNoCache() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let cache = NotionPageCache<NotionMeeting>(name: "test", url: url)
        let meeting = try XCTUnwrap(NotionMeeting.parse(["id": "a", "type": "meeting_notes", "meeting_notes": ["title": "保存済み", "status": "notes_ready"]]))
        let date = Date().addingTimeInterval(-120)
        cache.save(.init(scope: "", rows: [meeting], updated: date))
        let suite = "notch020-\(UUID())"; let defaults = TestDefaults.make(suite, test: self)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotionMeetingsStore(defaults: defaults, tokenProvider: { "token" }, apiFactory: { token in
            NotionDatabaseAPI(token: token) { _ in throw URLError(.notConnectedToInternet) }
        }, cacheURL: url)
        await store.refresh()
        XCTAssertEqual(store.meetings, [meeting]); XCTAssertEqual(store.lastUpdated, date)
        XCTAssertNotNil(store.message); XCTAssertTrue(store.hasCache); XCTAssertFalse(store.refreshing)
        store.clearCache(); await store.refresh()
        XCTAssertFalse(store.hasCache); XCTAssertTrue(store.meetings.isEmpty); XCTAssertNotNil(store.message)
        store.fallback = "another-page"
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testMeetingBodyRefreshOnEditOrNotesReadyTransition() throws {
        func meeting(_ status: String, edited: Date) throws -> NotionMeeting {
            var result = try XCTUnwrap(NotionMeeting.parse(["id": "a", "type": "meeting_notes", "meeting_notes": ["status": status]]))
            result.edited = edited; return result
        }
        let old = try meeting("summarizing", edited: .distantPast)
        XCTAssertFalse(NotionPageRefreshRules.meetingBodyChanged(old: old, new: old))
        XCTAssertTrue(NotionPageRefreshRules.meetingBodyChanged(old: old, new: try meeting("notes_ready", edited: .distantPast)))
        XCTAssertTrue(NotionPageRefreshRules.meetingBodyChanged(old: old, new: try meeting("summarizing", edited: Date())))
    }

    @MainActor func testStoreActuallySkipsRecentTabOpenAndCoalescesRefreshes() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url) }
        let cache = NotionPageCache<NotionMeeting>(name: "test", url: url)
        cache.save(.init(scope: "", updated: Date()))
        let suite = "notch020-\(UUID())"; let defaults = TestDefaults.make(suite, test: self)
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Notch020TransportGate()
        let store = NotionMeetingsStore(defaults: defaults, tokenProvider: { "token" }, apiFactory: { token in
            NotionDatabaseAPI(token: token) { request in
                await gate.wait()
                return (Data("{\"results\":[],\"has_more\":false}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }, cacheURL: url)
        await store.refresh(force: false)
        let skipped = await gate.count
        XCTAssertEqual(skipped, 0)
        let first = Task { await store.refresh() }
        for _ in 0..<1000 {
            if await gate.count == 1 { break }
            await Task.yield()
        }
        XCTAssertTrue(store.refreshing)
        await store.refresh()
        let calls = await gate.count
        XCTAssertEqual(calls, 1)
        // Changing settings while the request is pending must invalidate its result.
        store.fallback = "new-page"
        await gate.release()
        await first.value
        XCTAssertFalse(store.hasCache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(store.refreshing)
    }

    func testDeltaRequestIncludesOverlapAndManualFullRequestOmitsFilter() async throws {
        let since = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-60)
        let recorder = Notch020RequestRecorder()
        let api = NotionDatabaseAPI(token: "token") { request in
            await recorder.record(request.httpBody)
            return (Data("{\"results\":[],\"has_more\":false}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await api.tasks(source: "source", mapping: .init(), completedIDs: [], editedSince: since)
        _ = try await api.tasks(source: "source", mapping: .init(), completedIDs: [])
        let recorded = await recorder.bodies
        let delta = try XCTUnwrap(try JSONSerialization.jsonObject(with: recorded[0]) as? [String: Any])
        let filter = try XCTUnwrap(delta["filter"] as? [String: Any])
        XCTAssertEqual(filter["timestamp"] as? String, "last_edited_time")
        XCTAssertEqual((filter["last_edited_time"] as? [String: String])?["on_or_after"], ISO8601DateFormatter().string(from: since))
        let full = try XCTUnwrap(try JSONSerialization.jsonObject(with: recorded[1]) as? [String: Any])
        XCTAssertNil(full["filter"])
    }
}

private actor Notch020TransportGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        count += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor Notch020RequestRecorder {
    private(set) var bodies: [Data] = []
    func record(_ body: Data?) { bodies.append(body ?? Data()) }
}
