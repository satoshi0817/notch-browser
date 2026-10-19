import XCTest
@testable import NotchBrowser

/// Every store has an injected token and transport. No shared stores or real HTTP are used.
final class Notch022Tests: XCTestCase {
    private let todo = NotionStatusOption(id: "todo-id", name: "未着手", color: "gray", category: .notStarted)
    private let doing = NotionStatusOption(id: "doing-id", name: "進行中", color: "blue", category: .inProgress)
    private let done = NotionStatusOption(id: "done-id", name: "完了", color: "green", category: .complete)
    private func row(_ id: String = "page") -> NotionTask {
        .init(id: id, title: "Task", url: nil, status: todo.name, completed: false, due: nil,
              edited: .distantPast, dueEditable: true, statusCategory: .notStarted, statusColor: "gray")
    }
    @MainActor private func makeStore(_ transport: Notch022HTTP) throws -> (NotionTasksStore, URL) {
        let suite = "notch022-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let store = NotionTasksStore(defaults: defaults, tokenProvider: { "injected-test-token" }, apiFactory: { token in
            var api = NotionDatabaseAPI(token: token, fetch: { try await transport.fetch($0) })
            api.wait = { await transport.recordRetryWait($0) }
            return api
        }, cacheURL: file)
        store.configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
        store.configuration.source = "source"
        store.configuration.mapping = .init(status: "Status", due: "Due")
        store.configuration.mappedSource = "source"
        store.verified = true
        store.properties = [.init(id: "s", name: "Status", type: "status", statusOptions: [todo, doing, done]),
                            .init(id: "d", name: "Due", type: "date")]
        store.tasks = [row()]
        store.writeWait = { await transport.recordWriteWait($0) }
        return (store, file)
    }
    @MainActor private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Async operation did not finish", file: file, line: line)
    }
    @MainActor private func settle(_ store: NotionTasksStore, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually({ !store.writing }, file: file, line: line)
    }
    private func payload(_ request: URLRequest, property: String) throws -> [String: Any] {
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return try XCTUnwrap((body["properties"] as? [String: [String: Any]])?[property])
    }

    func testSchemaParsesOptionIDNameColorAndKeepsGroups() async throws {
        let http = Notch022HTTP()
        let api = NotionDatabaseAPI(token: "test", fetch: { try await http.fetch($0) })
        let (schema, completed, categories) = try await api.taskSchema("source", statusName: "Status")
        let options = try XCTUnwrap(schema.first { $0.name == "Status" }).statusOptions
        XCTAssertEqual(options, [todo, doing, done])
        XCTAssertEqual(completed, [done.id])
        XCTAssertEqual(categories[todo.id], .notStarted)
        XCTAssertEqual(categories[doing.id], .inProgress)
        XCTAssertEqual(categories[done.id], .complete)
        XCTAssertTrue(NotionStatusOption.parse(["type": "select", "status": ["options": [["id": "x", "name": "x"]]]]).isEmpty)
    }

    func testGETPOSTAndPATCHAndErrorCode() async throws {
        let http = Notch022HTTP()
        var api = NotionDatabaseAPI(token: "test", fetch: { try await http.fetch($0) })
        api.wait = { await http.recordRetryWait($0) }
        _ = try await api.request("pages/page")
        _ = try await api.request("data_sources/source/query", body: [:])
        _ = try await api.request("pages/page", body: ["properties": [:]], method: "PATCH")
        let methods = await http.requests.map(\.httpMethod)
        XCTAssertEqual(methods, ["GET", "POST", "PATCH"])
        await http.setStatuses([403])
        do {
            _ = try await api.request("pages/page", body: [:], method: "PATCH")
            XCTFail("Expected restricted_resource")
        } catch {
            XCTAssertEqual(NotionTaskEditRules.status(error).0, 403)
            XCTAssertEqual(NotionTaskEditRules.status(error).1, "restricted_resource")
        }
    }

    @MainActor func testStatusByIDOptimisticCacheAndReturnedTimestamp() async throws {
        let http = Notch022HTTP(); let (store, file) = try makeStore(http)
        store.edit(page: "page", value: .status(done))
        XCTAssertEqual(store.tasks[0].status, done.name)
        XCTAssertTrue(store.tasks[0].completed)
        XCTAssertNotNil(store.pendingEdits["page"]?[.status])
        let saved = try JSONDecoder().decode(NotionPageSnapshot<NotionTask>.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.rows[0].status, done.name)
        await settle(store)
        let patches = await http.patches
        XCTAssertEqual(patches.count, 1)
        let status = try XCTUnwrap(try payload(patches[0], property: "Status")["status"] as? [String: String])
        XCTAssertEqual(status, ["id": done.id]); XCTAssertNil(status["name"])
        XCTAssertEqual(store.tasks[0].edited, NotionTaskRules.parseDate("2026-10-20T01:00:00Z"))
        XCTAssertNil(store.pendingEdits["page"])
        XCTAssertTrue(store.writeFailures["page"]?.isEmpty ?? true)
    }

    @MainActor func testDateOnlyAndClearPayloads() async throws {
        let http = Notch022HTTP(); let (store, _) = try makeStore(http)
        let date = try XCTUnwrap(NotionTaskRules.parseDate("2026-10-21"))
        store.edit(page: "page", value: .due(date))
        XCTAssertEqual(store.tasks[0].due, date)
        await settle(store)
        store.edit(page: "page", value: .due(nil))
        XCTAssertNil(store.tasks[0].due)
        await settle(store)
        let patches = await http.patches
        XCTAssertEqual(patches.count, 2)
        let dateObject = try XCTUnwrap(try payload(patches[0], property: "Due")["date"] as? [String: String])
        XCTAssertEqual(dateObject, ["start": "2026-10-21"])
        XCTAssertTrue(try payload(patches[1], property: "Due")["date"] is NSNull)
        let waits = await http.writeWaits
        XCTAssertTrue(waits.allSatisfy { $0 >= 1.0 / 3.0 })
    }

    @MainActor func testLocalTypeRefusalAndFreshSchemaRefusalNeverPATCH() async throws {
        for type in ["select", "checkbox", "rich_text"] {
            let http = Notch022HTTP(); let (store, _) = try makeStore(http)
            store.properties[0] = .init(id: "s", name: "Status", type: type)
            store.edit(page: "page", value: .status(doing))
            XCTAssertTrue(store.pendingEdits.isEmpty)
            XCTAssertEqual(store.tasks[0].status, todo.name)
            let requests = await http.requests
            XCTAssertTrue(requests.isEmpty)
        }
        let http = Notch022HTTP(); let (store, _) = try makeStore(http)
        await http.setTypes(status: "select", due: "rich_text")
        store.edit(page: "page", value: .status(doing))
        await settle(store)
        XCTAssertEqual(store.tasks[0].status, todo.name)
        XCTAssertNotNil(store.writeFailures["page"]?[.status])
        store.edit(page: "page", value: .due(Date()))
        await settle(store)
        XCTAssertNil(store.tasks[0].due)
        let patches = await http.patches
        XCTAssertTrue(patches.isEmpty)
        XCTAssertThrowsError(try NotionTaskEditRules.validate(.due(nil), property: .init(id: "s", name: "x", type: "status")))
        XCTAssertThrowsError(try NotionTaskEditRules.validate(.status(.init(id: "unknown", name: "x", color: "gray")), property: store.properties[0]))
    }

    @MainActor func testOptimisticRollbackAndFailureRetryClearsWarning() async throws {
        let http = Notch022HTTP(); await http.setStatuses([500, 200])
        let (store, file) = try makeStore(http)
        store.edit(page: "page", value: .status(doing))
        XCTAssertEqual(store.tasks[0].status, doing.name)
        await settle(store)
        XCTAssertEqual(store.tasks[0].status, todo.name)
        XCTAssertEqual(store.writeFailures["page"]?[.status]?.text, "Notion に保存できませんでした")
        let saved = try JSONDecoder().decode(NotionPageSnapshot<NotionTask>.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.rows[0].status, todo.name)
        store.retryWrite(page: "page", field: .status)
        await settle(store)
        XCTAssertEqual(store.tasks[0].status, doing.name)
        XCTAssertTrue(store.writeFailures["page"]?.isEmpty ?? true)
    }

    @MainActor func testPendingMergePreservesOnlyEditedFieldIncludingFullRefreshDeletion() async throws {
        let gate = Notch022Gate(); let http = Notch022HTTP()
        let (store, _) = try makeStore(http)
        store.writeWait = { _ in await gate.wait() }
        store.edit(page: "page", value: .status(doing))
        var remote = row(); remote = NotionTaskEditRules.replacing(remote, value: .due(NotionTaskRules.parseDate("2026-10-22")))
        let merged = store.mergePending(previous: store.tasks, fetched: [remote], full: true)
        XCTAssertEqual(merged[0].status, doing.name)
        XCTAssertEqual(merged[0].due, remote.due)
        XCTAssertEqual(store.mergePending(previous: store.tasks, fetched: [], full: true).map(\.id), ["page"])
        await gate.release(); await settle(store)
    }

    @MainActor func testCoalescesSamePagePropertyBeforeSendingAndSerializesDifferentProperties() async throws {
        let gate = Notch022Gate(); let http = Notch022HTTP()
        let (store, _) = try makeStore(http)
        store.writeWait = { seconds in await http.recordWriteWait(seconds); await gate.wait() }
        store.edit(page: "page", value: .status(doing))
        store.edit(page: "page", value: .status(done))
        store.edit(page: "page", value: .status(todo))
        store.edit(page: "page", value: .due(NotionTaskRules.parseDate("2026-10-22")))
        XCTAssertEqual(store.writeOrder.count, 2)
        await gate.release(); await settle(store)
        let patches = await http.patches
        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual((try payload(patches[0], property: "Status")["status"] as? [String: String])?["id"], todo.id)
        XCTAssertNotNil(try payload(patches[1], property: "Due")["date"])
        let maxActive = await http.maximumActivePatches
        XCTAssertEqual(maxActive, 1)
    }

    @MainActor func testChangesWhilePATCHInFlightKeepLatestAndRollbackToLastConfirmedValue() async throws {
        let gate = Notch022Gate(); let http = Notch022HTTP()
        await http.setPatchGate(gate); await http.setStatuses([200, 500])
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing))
        await eventually { await gate.entered > 0 }
        store.edit(page: "page", value: .status(done))
        XCTAssertEqual(store.tasks[0].status, done.name)
        await gate.release(); await settle(store)
        XCTAssertEqual(store.tasks[0].status, doing.name)
        XCTAssertNotNil(store.writeFailures["page"]?[.status])
    }

    @MainActor func testRestrictedResourceStickyViewOnlyAndRetryReset() async throws {
        let http = Notch022HTTP(); await http.setStatuses([403, 200])
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing)); await settle(store)
        XCTAssertTrue(store.noPermission)
        XCTAssertEqual(store.tasks[0].status, todo.name)
        XCTAssertFalse(store.canEdit(.status, task: store.tasks[0]))
        XCTAssertFalse(store.canEdit(.due, task: store.tasks[0]))
        XCTAssertEqual(store.writeFailures["page"]?[.status]?.text, "編集するには Notion で『Update content』をオンにしてください")
        store.edit(page: "page", value: .due(Date()))
        let before = await http.patches.count
        XCTAssertEqual(before, 1)
        store.retryWrite(page: "page", field: .status); await settle(store)
        XCTAssertFalse(store.noPermission)
        XCTAssertEqual(store.tasks[0].status, doing.name)
    }

    @MainActor func testPermissionResetsOnManualRefreshTokenResetAndRelaunchOnlyNotBackgroundRefresh() async throws {
        let http = Notch022HTTP(); let (store, _) = try makeStore(http)
        store.noPermission = true
        await store.refresh(force: false)
        XCTAssertTrue(store.noPermission)
        await store.refresh()
        XCTAssertFalse(store.noPermission)
        store.noPermission = true
        // This is the same hook called by NotionConnectionStore.save after a token is saved.
        store.connectionChanged()
        XCTAssertFalse(store.noPermission)
        store.noPermission = true
        let (relaunched, _) = try makeStore(http)
        XCTAssertFalse(relaunched.noPermission)
    }

    @MainActor func testRestrictionRollsBackOtherQueuedFieldsWithoutSendingThem() async throws {
        let http = Notch022HTTP(); await http.setStatuses([403])
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing))
        store.edit(page: "page", value: .due(Date()))
        await settle(store)
        XCTAssertNil(store.tasks[0].due)
        XCTAssertEqual(store.tasks[0].status, todo.name)
        XCTAssertNotNil(store.writeFailures["page"]?[.due])
        XCTAssertTrue(store.pendingEdits.isEmpty)
        let patches = await http.patches
        XCTAssertEqual(patches.count, 1)
    }

    @MainActor func test409RefetchesPageAndSurfacesConflictWithRetry() async throws {
        let http = Notch022HTTP(); await http.setStatuses([409, 200])
        await http.setRemoteStatus("done-id")
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing)); await settle(store)
        XCTAssertEqual(store.tasks[0].status, done.name)
        XCTAssertTrue(store.tasks[0].completed)
        XCTAssertEqual(store.writeFailures["page"]?[.status]?.kind, .conflict)
        let methods = await http.requests.map(\.httpMethod)
        XCTAssertEqual(methods, ["GET", "PATCH", "GET"])
        store.retryWrite(page: "page", field: .status); await settle(store)
        XCTAssertEqual(store.tasks[0].status, doing.name)
    }

    @MainActor func test429And529RetryAfterThreeAttemptsThenFailureAndRecovery() async throws {
        for code in [429, 529] {
            let http = Notch022HTTP(); await http.setStatuses([code, code, code, 200])
            let (store, _) = try makeStore(http)
            store.edit(page: "page", value: .status(doing)); await settle(store)
            let patches = await http.patches; let waits = await http.retryWaits
            XCTAssertEqual(patches.count, 3)
            XCTAssertEqual(waits, [2, 2])
            XCTAssertEqual(store.tasks[0].status, todo.name)
            XCTAssertNotNil(store.writeFailures["page"]?[.status])
            store.retryWrite(page: "page", field: .status); await settle(store)
            XCTAssertEqual(store.tasks[0].status, doing.name)
        }
    }

    @MainActor func test503ConfirmsAppliedWriteWithoutDuplicateAndRewritesOnlyWhenUnconfirmed() async throws {
        for applied in [true, false] {
            let http = Notch022HTTP(); await http.setStatuses([503, 200]); await http.setApply503(applied)
            let (store, _) = try makeStore(http)
            store.edit(page: "page", value: .status(doing)); await settle(store)
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.httpMethod), applied ? ["GET", "PATCH", "GET"] : ["GET", "PATCH", "GET", "PATCH"])
            XCTAssertEqual(store.tasks[0].status, doing.name)
            XCTAssertTrue(store.writeFailures["page"]?.isEmpty ?? true)
        }
    }

    @MainActor func test404NetworkAnd5xxFailurePathsAndRefetchClearsListWarning() async throws {
        for status in [404, 500, 502] {
            let http = Notch022HTTP(); await http.setStatuses([status])
            let (store, _) = try makeStore(http)
            store.edit(page: "page", value: .status(doing)); await settle(store)
            XCTAssertEqual(store.tasks[0].status, todo.name)
            XCTAssertEqual(store.writeFailures["page"]?[.status]?.kind, status == 404 ? .deleted : .failed)
            await store.refresh()
            XCTAssertTrue(store.writeFailures.isEmpty)
        }
        let http = Notch022HTTP(); await http.setNetworkFailure(true)
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .due(Date())); await settle(store)
        XCTAssertNil(store.tasks[0].due)
        XCTAssertNotNil(store.writeFailures["page"]?[.due])
    }

    @MainActor func testTimeAndEndDatesAreViewOnlyButStatusEditableAndStaleDateIsRechecked() async throws {
        let values: [[String: Any]] = [["start": "2026-10-20T09:00:00+09:00"], ["start": "2026-10-20", "end": "2026-10-21"]]
        for value in values {
            let http = Notch022HTTP(); await http.setRemoteDate(value)
            let api = NotionDatabaseAPI(token: "test", fetch: { try await http.fetch($0) })
            let tasks = try await api.tasks(source: "source", mapping: .init(status: "Status", due: "Due"), completedIDs: [])
            XCTAssertEqual(tasks[0].dueEditable, false)
            let (store, _) = try makeStore(http)
            store.tasks = tasks
            XCTAssertFalse(store.canEdit(.due, task: tasks[0]))
            XCTAssertTrue(store.canEdit(.status, task: tasks[0]))
            store.edit(page: "page", value: .due(nil))
            XCTAssertTrue(store.pendingEdits.isEmpty)
            // A cached date-only row is also protected if Notion changed to a timed/ranged date.
            store.tasks = [row()]
            store.edit(page: "page", value: .due(nil)); await settle(store)
            let patches = await http.patches
            XCTAssertTrue(patches.isEmpty)
            XCTAssertEqual(store.tasks[0].dueEditable, false)
        }
        XCTAssertTrue(NotionTaskEditRules.dateEditable(nil))
        XCTAssertTrue(NotionTaskEditRules.dateEditable(["start": "2026-10-20", "end": NSNull()]))
    }

    @MainActor func testScopeChangeDiscardsInFlightResponseAndCacheMutation() async throws {
        let gate = Notch022Gate(); let http = Notch022HTTP(); await http.setPatchGate(gate)
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing))
        await eventually { await gate.entered > 0 }
        store.configuration.source = "different-source"
        await gate.release(); await settle(store)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(store.pendingEdits.isEmpty)
        XCTAssertTrue(store.writeFailures.isEmpty)
    }

    @MainActor func testActualRefreshDoesNotOverwritePendingEditOrItsCache() async throws {
        let gate = Notch022Gate(); let http = Notch022HTTP(); await http.setPatchGate(gate)
        let (store, file) = try makeStore(http)
        store.edit(page: "page", value: .status(doing))
        await eventually { await gate.entered > 0 }
        await store.refresh()
        XCTAssertEqual(store.tasks[0].status, doing.name)
        XCTAssertNotNil(store.pendingEdits["page"]?[.status])
        let cached = try JSONDecoder().decode(NotionPageSnapshot<NotionTask>.self, from: Data(contentsOf: file))
        XCTAssertEqual(cached.rows[0].status, doing.name)
        await gate.release(); await settle(store)
        XCTAssertEqual(store.tasks[0].status, doing.name)
    }

    @MainActor func testCoalescesChangesWhileSchemaGETIsInFlight() async throws {
        let gate = Notch022Gate(); let http = Notch022HTTP(); await http.setSchemaGate(gate)
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing))
        await eventually { await gate.entered > 0 }
        store.edit(page: "page", value: .status(todo))
        store.edit(page: "page", value: .status(done))
        await gate.release(); await settle(store)
        let patches = await http.patches
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual((try payload(patches[0], property: "Status")["status"] as? [String: String])?["id"], done.id)
    }

    @MainActor func test503FailedConfirmationNeverBlindlyRewrites() async throws {
        let http = Notch022HTTP(); await http.setStatuses([503])
        await http.setPageGETStatus(500)
        let (store, _) = try makeStore(http)
        store.edit(page: "page", value: .status(doing)); await settle(store)
        let patches = await http.patches
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(store.tasks[0].status, todo.name)
        XCTAssertNotNil(store.writeFailures["page"]?[.status])
    }
}

private actor Notch022Gate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    func wait() async {
        entered += 1
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let waiting = continuations; continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

private actor Notch022HTTP {
    private(set) var requests: [URLRequest] = []
    var patches: [URLRequest] { requests.filter { $0.httpMethod == "PATCH" } }
    private(set) var writeWaits: [Double] = []
    private(set) var retryWaits: [Double] = []
    private(set) var maximumActivePatches = 0
    private var activePatches = 0
    private var statuses: [Int] = []
    private var statusType = "status"
    private var dueType = "date"
    private var remoteStatus = "todo-id"
    private var remoteDate: [String: Any]?
    private var apply503 = false
    private var networkFailure = false
    private var patchGate: Notch022Gate?
    private var schemaGate: Notch022Gate?
    private var pageGETStatus = 200
    func setStatuses(_ values: [Int]) { statuses = values }
    func setTypes(status: String, due: String) { statusType = status; dueType = due }
    func setRemoteStatus(_ value: String) { remoteStatus = value }
    func setRemoteDate(_ value: [String: Any]) { remoteDate = value }
    func setApply503(_ value: Bool) { apply503 = value }
    func setNetworkFailure(_ value: Bool) { networkFailure = value }
    func setPatchGate(_ gate: Notch022Gate) { patchGate = gate }
    func setSchemaGate(_ gate: Notch022Gate) { schemaGate = gate }
    func setPageGETStatus(_ status: Int) { pageGETStatus = status }
    func recordWriteWait(_ seconds: Double) { writeWaits.append(seconds) }
    func recordRetryWait(_ seconds: Double) { retryWaits.append(seconds) }
    private var options: [[String: Any]] {
        [["id": "todo-id", "name": "未着手", "color": "gray"],
         ["id": "doing-id", "name": "進行中", "color": "blue"],
         ["id": "done-id", "name": "完了", "color": "green"]]
    }
    private var page: [String: Any] {
        ["id": "page", "object": "page", "last_edited_time": "2026-10-20T01:00:00Z",
         "properties": ["Status": ["type": "status", "status": options.first { $0["id"] as? String == remoteStatus }!],
                        "Due": ["type": "date", "date": remoteDate.map { $0 as Any } ?? NSNull()]]]
    }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let isPatch = request.httpMethod == "PATCH"
        if request.url!.path.hasSuffix("data_sources/source"), let gate = schemaGate {
            schemaGate = nil; await gate.wait()
        }
        if isPatch {
            activePatches += 1; maximumActivePatches = max(maximumActivePatches, activePatches)
            if let gate = patchGate { patchGate = nil; await gate.wait() }
        }
        defer { if isPatch { activePatches -= 1 } }
        if networkFailure { throw URLError(.notConnectedToInternet) }
        let status = isPatch && !statuses.isEmpty ? statuses.removeFirst() :
            request.httpMethod == "GET" && request.url!.path.contains("pages/") ? pageGETStatus : 200
        if isPatch && (status == 200 || status == 503 && apply503), let data = request.httpBody,
           let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let properties = body["properties"] as? [String: [String: Any]] {
            if let id = (properties["Status"]?["status"] as? [String: String])?["id"] { remoteStatus = id }
            if let due = properties["Due"] { remoteDate = due["date"] as? [String: Any] }
        }
        let object: [String: Any]
        if status != 200 { object = ["code": status == 403 ? "restricted_resource" : "test_error", "message": "Stub error"] }
        else if request.url!.path.contains("databases/") {
            object = ["object": "database", "title": [], "data_sources": [["id": "source", "name": "Test"]]]
        } else if request.url!.path.hasSuffix("/query") {
            object = ["results": [page], "has_more": false]
        } else if request.url!.path.contains("data_sources/") {
            object = ["properties": [
                "Status": ["id": "s", "type": statusType, "status": ["options": options, "groups": [
                    ["option_ids": ["todo-id"]], ["option_ids": ["doing-id"]], ["option_ids": ["done-id"]]]]],
                "Due": ["id": "d", "type": dueType]]]
        } else { object = page }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Retry-After": "2"])!)
    }
}
