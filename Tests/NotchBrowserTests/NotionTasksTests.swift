import XCTest
import Foundation
@testable import NotchBrowser

final class NotionTasksTests: XCTestCase {
    func testUnconfirmedOrDifferentURLDoesNotCompleteChecklistOrShowTab() {
        let url = "https://notion.so/0123456789abcdef0123456789abcdef"
        for confirmed in [Optional<String>.none, "https://notion.so/ffffffffffffffffffffffffffffffff"] {
            XCTAssertFalse(NotionTaskRules.available(token: true, url: url, confirmedURL: confirmed))
            let checklist = NotionTaskRules.checklist(tokenValid: true, checking: false, url: url, confirmedURL: confirmed)
            XCTAssertFalse(checklist.databaseURL)
            XCTAssertEqual(checklist.hint, "2つそろうと、ノッチにタスクのタブが表示されます")
        }
    }
    @MainActor func testEveryConfirmationFailureRevokesPreviousSuccessAndPersistsIt() async throws {
        let url = "https://notion.so/0123456789abcdef0123456789abcdef"
        for status in [400, 401, 403, 404, 500] {
            let suite = "notion-confirmation-failure-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var config = NotionTasksStore.Configuration()
            config.url = url; config.confirmedURL = url
            defaults.set(try JSONEncoder().encode(config), forKey: "notionTasks.configuration")
            let store = NotionTasksStore(defaults: defaults, tokenProvider: { "test" }, apiFactory: { token in
                NotionDatabaseAPI(token: token) { request in
                    (Data("{\"message\":\"failed\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
            })
            XCTAssertTrue(store.available)
            await store.configure()
            XCTAssertFalse(store.verified)
            XCTAssertFalse(store.available)
            XCTAssertNil(store.configuration.confirmedURL)
            XCTAssertNotNil(store.message)
            let checklist = NotionTaskRules.checklist(tokenValid: true, checking: false, url: url, confirmedURL: store.configuration.confirmedURL)
            XCTAssertFalse(checklist.databaseURL)
            XCTAssertEqual(checklist.hint, "2つそろうと、ノッチにタスクのタブが表示されます")
            XCTAssertFalse(NotionTasksStore(defaults: defaults, tokenProvider: { "test" }).available)
        }
    }
    @MainActor func testSuccessfulConfirmationPersistsExactURLAndEditingInvalidatesIt() async throws {
        let suite = "notion-confirmation-success-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NotionTasksStore(defaults: defaults, tokenProvider: { "test" }, apiFactory: { token in
            NotionDatabaseAPI(token: token) { request in
                let json: String
                if request.url!.path.contains("databases/") {
                    json = "{\"object\":\"database\",\"title\":[],\"data_sources\":[{\"id\":\"source\"}]}"
                } else if request.url!.path.hasSuffix("/query") {
                    json = "{\"results\":[],\"has_more\":false}"
                } else { json = "{\"properties\":{}}" }
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        })
        store.configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
        XCTAssertFalse(store.available)
        await store.configure()
        XCTAssertTrue(store.available)
        XCTAssertTrue(NotionTasksStore(defaults: defaults, tokenProvider: { "test" }).available)
        let original = store.configuration.url
        store.configuration.url = "https://notion.so/ffffffffffffffffffffffffffffffff"
        XCTAssertFalse(store.available)
        store.configuration.url = original
        XCTAssertFalse(store.available, "Retyping an old URL requires confirmation again")
    }
    @MainActor func testMissingTokenAndTransportFailureAlsoRevokeConfirmation() async throws {
        for missingToken in [true, false] {
            let suite = "notion-confirmation-transport-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = NotionTasksStore(defaults: defaults, tokenProvider: { missingToken ? nil : "test" }, apiFactory: { token in
                NotionDatabaseAPI(token: token) { _ in throw URLError(.notConnectedToInternet) }
            })
            store.configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
            store.verified = true
            await store.configure()
            XCTAssertFalse(store.verified)
            XCTAssertFalse(store.available)
            XCTAssertNil(store.configuration.confirmedURL)
            XCTAssertNotNil(store.message)
        }
    }
    #if DEBUG
    @MainActor func testSettingsErrorMockUsesUnconfirmedStateAndNoTab() {
        let store = NotionTasksStore(previewState: "settings-error")
        XCTAssertFalse(store.available)
        XCTAssertFalse(store.verified)
        let checklist = NotionTaskRules.checklist(tokenValid: true, checking: false, url: store.configuration.url, confirmedURL: store.configuration.confirmedURL)
        XCTAssertFalse(checklist.databaseURL)
        XCTAssertEqual(checklist.hint, "2つそろうと、ノッチにタスクのタブが表示されます")
        XCTAssertNotNil(NotionTaskRules.errorLink(store.message!, url: store.configuration.url))
    }
    #endif
    func testChecklistUsesVerifiedTokenStateAndChangesHintOnlyWhenBothComplete() {
        let url = "https://www.notion.so/0123456789abcdef0123456789abcdef"
        let unverified = NotionTaskRules.checklist(tokenValid: false, checking: false, url: url, confirmedURL: url)
        XCTAssertFalse(unverified.loggedIn, "A saved but unverified token must not show a checkmark")
        XCTAssertTrue(unverified.databaseURL)
        XCTAssertEqual(unverified.hint, "2つそろうと、ノッチにタスクのタブが表示されます")
        let checking = NotionTaskRules.checklist(tokenValid: true, checking: true, url: url, confirmedURL: url)
        XCTAssertFalse(checking.loggedIn)
        XCTAssertEqual(checking.hint, unverified.hint)
        let noURL = NotionTaskRules.checklist(tokenValid: true, checking: false, url: "", confirmedURL: nil)
        XCTAssertTrue(noURL.loggedIn)
        XCTAssertFalse(noURL.databaseURL)
        XCTAssertEqual(noURL.hint, unverified.hint)
        let complete = NotionTaskRules.checklist(tokenValid: true, checking: false, url: url, confirmedURL: url)
        XCTAssertTrue(complete.loggedIn && complete.databaseURL)
        XCTAssertEqual(complete.hint, "ノッチにタスクのタブが表示されています")
    }
    func testConfirmButtonRequiresNonemptyInputAndNoActiveCheck() {
        XCTAssertFalse(NotionTaskRules.canConfirm(url: "", checking: false))
        XCTAssertFalse(NotionTaskRules.canConfirm(url: " \n\t", checking: false))
        XCTAssertFalse(NotionTaskRules.canConfirm(url: "https://www.notion.so/example", checking: true))
        XCTAssertTrue(NotionTaskRules.canConfirm(url: "https://www.notion.so/example", checking: false))
        XCTAssertTrue(NotionTaskRules.canConfirm(url: "invalid URL", checking: false), "Confirmation must be able to explain invalid input")
    }
    func testSharingErrorHasASeparateLinkOnlyFor404() {
        let url = "https://www.notion.so/0123456789abcdef0123456789abcdef"
        let error = NotionTaskRules.errorMessage(NotionAPIError.server(404, "object_not_found"))
        XCTAssertEqual(NotionTaskRules.errorLink(error, url: url), URL(string: url))
        XCTAssertNil(NotionTaskRules.errorLink("URL がデータベースではありません", url: url))
        XCTAssertNil(NotionTaskRules.errorLink(error, url: ""))
    }
    #if DEBUG
    @MainActor func testPreviewBodyIncludesListsLinkAndOfflineImage() {
        let blocks = NotionTasksStore.previewBlocks()
        XCTAssertTrue(blocks.contains { $0.type == "bulleted_list_item" })
        XCTAssertEqual(blocks.filter { $0.type == "numbered_list_item" }.map(\.listNumber), [1, 2])
        XCTAssertTrue(blocks.contains { $0.runs.contains { $0.url != nil } })
        XCTAssertEqual(blocks.first { $0.type == "image" }?.image?.scheme, "notch-preview")
        XCTAssertTrue(blocks.contains { $0.type == "to_do" })
    }
    #endif
    private func task(_ id: String, due: Date? = nil, edited: Date = .distantPast, completed: Bool = false) -> NotionTask {
        .init(id: id, title: id, url: nil, status: "", completed: completed, due: due, edited: edited)
    }
    func testDatabaseURLIgnoresViewAndOtherQueryParameters() {
        let id = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(NotionDatabaseInput.id(from: "https://www.notion.so/workspace/Tasks-\(id)?v=ffffffffffffffffffffffffffffffff&foo=bar"),
                       "01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(NotionDatabaseInput.id(from: "https://notion.so/\(id)#section"), NotionDatabaseInput.id(from: id))
        XCTAssertNil(NotionDatabaseInput.id(from: "https://example.com/\(id)"))
        XCTAssertNil(NotionDatabaseInput.id(from: "https://notion.so/tasks?v=\(id)"))
        XCTAssertNil(NotionDatabaseInput.id(from: "https://notion.so/not-a-database"))
    }
    func testMappingUsesFirstPropertyOfEachType() {
        let schema: [NotionDatabaseProperty] = [
            .init(id: "a", name: "Title", type: "title"),
            .init(id: "b", name: "State", type: "status"),
            .init(id: "c", name: "Other State", type: "status"),
            .init(id: "d", name: "Deadline", type: "date"),
            .init(id: "e", name: "Owner", type: "people")]
        XCTAssertEqual(NotionTaskMapping.automatic(schema), .init(status: "State", due: "Deadline"))
        XCTAssertEqual(NotionTaskMapping.automatic([]), NotionTaskMapping())
    }
    func testGroupsAndSortByDayThenLastEditedDescending() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12)))
        let morning = calendar.startOfDay(for: now)
        let evening = morning.addingTimeInterval(20 * 3600)
        let old = task("old", due: morning, edited: now.addingTimeInterval(-10))
        let new = task("new", due: evening, edited: now)
        let overdue = task("overdue", due: morning.addingTimeInterval(-86400))
        let future = task("future", due: morning.addingTimeInterval(86400))
        let undated = task("undated")
        XCTAssertEqual(NotionTaskRules.group(overdue, now: now, calendar: calendar), .overdue)
        XCTAssertEqual(NotionTaskRules.group(new, now: now, calendar: calendar), .today)
        XCTAssertEqual(NotionTaskRules.group(future, now: now, calendar: calendar), .upcoming)
        XCTAssertEqual(NotionTaskRules.group(undated, now: now, calendar: calendar), .undated)
        XCTAssertEqual(NotionTaskRules.rows([old, undated, new, future, overdue], filter: .all, calendar: calendar).map(\.id),
                       ["overdue", "new", "old", "future", "undated"])
        XCTAssertEqual(NotionTaskRules.dateLabel(morning, now: now, calendar: calendar), "今日")
        XCTAssertEqual(NotionTaskRules.dateLabel(future.due!, now: now, calendar: calendar), "明日")
        XCTAssertEqual(NotionTaskRules.dateLabel(morning.addingTimeInterval(7 * 86400), now: now, calendar: calendar), "10/20")
    }
    func testFiltersIncludeCompletedOnlyWhenRequested() {
        let tasks = [task("a"), task("b", completed: true), task("c")]
        XCTAssertEqual(NotionTaskFilter.allCases, [.incomplete, .all])
        XCTAssertEqual(NotionTaskRules.rows(tasks, filter: .incomplete).map(\.id), ["a", "c"])
        XCTAssertEqual(NotionTaskRules.rows(tasks, filter: .all).count, 3)
    }
    @MainActor func testLegacyMineFilterMigratesAndPersistsIncomplete() throws {
        let suite = "notion-filter-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotionTasksStore(defaults: defaults).filter, .incomplete)
        defaults.set("自分の担当", forKey: "notionTasks.filter")
        XCTAssertEqual(NotionTasksStore(defaults: defaults).filter, .incomplete)
        XCTAssertEqual(defaults.string(forKey: "notionTasks.filter"), "未完了")
        XCTAssertEqual(NotionTasksStore(defaults: defaults).filter, .incomplete)
    }
    func testLegacyTaskAndMappingDecodeWithoutUserFields() throws {
        let data = Data(#"{"id":"old","title":"Old","status":"Done","completed":true,"edited":0,"people":[{"id":"person","name":"Name"}]}"#.utf8)
        let restored = try JSONDecoder().decode(NotionTask.self, from: data)
        XCTAssertEqual(restored.category, .complete)
        let mapping = try JSONDecoder().decode(NotionTaskMapping.self, from: Data(#"{"status":"State","due":"Date","assignee":"Owner"}"#.utf8))
        XCTAssertEqual(mapping, .init(status: "State", due: "Date"))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(restored), encoding: .utf8))
        XCTAssertFalse(encoded.contains("people"))
    }
    func testCategorySymbolsAreNotCheckboxes() {
        XCTAssertEqual(NotionTaskStatusCategory.notStarted.symbol, "circle.fill")
        XCTAssertEqual(NotionTaskStatusCategory.inProgress.symbol, "circle.lefthalf.filled")
        XCTAssertEqual(NotionTaskStatusCategory.complete.symbol, "checkmark")
    }
    #if DEBUG
    @MainActor func testMocksIncludeEveryStatusCategoryAndTwoFilters() {
        for state in ["list", "detail", "no-people", "sources", "settings"] {
            let store = NotionTasksStore(previewState: state)
            XCTAssertEqual(store.filter, .incomplete)
            XCTAssertEqual(Set(store.tasks.map(\.category)), Set(NotionTaskStatusCategory.allCases))
            XCTAssertTrue(store.tasks.allSatisfy { $0.statusColor != nil })
            XCTAssertFalse(store.properties.contains { $0.type == "people" })
        }
    }
    #endif
    func testTabRequiresBothConnectionAndDatabaseURL() {
        let url = "https://notion.so/0123456789abcdef0123456789abcdef"
        XCTAssertTrue(NotionTaskRules.available(token: true, url: url, confirmedURL: url))
        XCTAssertFalse(NotionTaskRules.available(token: false, url: url, confirmedURL: url))
        XCTAssertFalse(NotionTaskRules.available(token: true, url: "", confirmedURL: nil))
        XCTAssertFalse(NotionTaskRules.available(token: false, url: "", confirmedURL: nil))
        XCTAssertTrue(NotionTaskRules.shouldAutoSelect(available: true, alreadySelected: false))
        XCTAssertFalse(NotionTaskRules.shouldAutoSelect(available: false, alreadySelected: false))
        XCTAssertFalse(NotionTaskRules.shouldAutoSelect(available: true, alreadySelected: true))
    }
    func testUnsharedAndNonDatabaseErrorsAreDistinct() {
        XCTAssertEqual(NotionTaskRules.errorMessage(NotionAPIError.server(404, "object_not_found")), "このデータベースが NotchBrowser に共有されていません")
        XCTAssertEqual(NotionTaskRules.errorMessage(NotionAPIError.server(400, "validation_error")), "URL がデータベースではありません")
        XCTAssertNotEqual(NotionTaskRules.errorMessage(NotionAPIError.server(401, "unauthorized")), "このデータベースが NotchBrowser に共有されていません")
    }
    func testDataSourcePickerOnlyForMultipleAndDefaultsToFirst() {
        let sources = [NotionTaskSource(id: "first", name: "First"), NotionTaskSource(id: "second", name: "Second")]
        XCTAssertFalse(NotionTaskRules.showsSourcePicker([]))
        XCTAssertFalse(NotionTaskRules.showsSourcePicker(Array(sources.prefix(1))))
        XCTAssertTrue(NotionTaskRules.showsSourcePicker(sources))
        XCTAssertEqual(NotionTaskRules.selectedSource(nil, sources: sources), "first")
        XCTAssertEqual(NotionTaskRules.selectedSource("deleted", sources: sources), "first")
        XCTAssertEqual(NotionTaskRules.selectedSource("second", sources: sources), "second")
        XCTAssertNil(NotionTaskRules.selectedSource(nil, sources: []))
    }
    func testBlockRenderingModelPreservesTextChecksLinksImagesAndNesting() {
        let todo = NotionTaskBlock.parse(["id": "todo", "type": "to_do", "to_do": ["checked": true, "rich_text": [["plain_text": "Read", "href": "https://example.com"]]]], depth: 2)
        XCTAssertEqual(todo.type, "to_do")
        XCTAssertTrue(todo.checked)
        XCTAssertEqual(todo.text, "Read")
        XCTAssertEqual(todo.runs.first?.url?.absoluteString, "https://example.com")
        XCTAssertEqual(todo.depth, 2)
        let image = NotionTaskBlock.parse(["id": "image", "type": "image", "image": ["type": "file", "file": ["url": "https://example.com/image.png"]]], depth: 0)
        XCTAssertEqual(image.image?.absoluteString, "https://example.com/image.png")
        let unsupported = NotionTaskBlock.parse(["id": "unknown", "type": "callout", "callout": ["rich_text": [["plain_text": "Plain fallback"]]]], depth: 0)
        XCTAssertEqual(unsupported.text, "Plain fallback")
        let heading = NotionTaskBlock.parse(["id": "heading", "type": "heading_1", "heading_1": ["rich_text": [["text": ["content": "Heading"]]]]], depth: 0)
        XCTAssertEqual(heading.text, "Heading")
    }
    func testReadOnlyDatabaseSourceQueryAndNestedBlockPagination() async throws {
        final class Recorder {
            let lock = NSLock()
            var paths: [String] = []
            func record(_ value: String) { lock.lock(); defer { lock.unlock() }; paths.append(value) }
        }
        let recorder = Recorder()
        let api = NotionDatabaseAPI(token: "test") { request in
            let path = request.url!.path
            recorder.record(path)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let cursor = query?.first { $0.name == "start_cursor" }?.value
            let json: String
            switch path {
            case "/v1/databases/db":
                XCTAssertEqual(request.httpMethod, "GET")
                json = "{\"object\":\"database\",\"title\":[{\"plain_text\":\"Tasks\"}],\"data_sources\":[{\"id\":\"source\",\"name\":\"Main\"}]}"
            case "/v1/data_sources/source":
                XCTAssertEqual(request.httpMethod, "GET")
                json = "{\"properties\":{\"Status\":{\"id\":\"s\",\"type\":\"status\",\"status\":{\"groups\":[{\"option_ids\":[\"open\"]},{\"option_ids\":[\"done\"]}]}}}}"
            case "/v1/data_sources/source/query":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["page_size"] as? Int, 100)
                let second = body["start_cursor"] as? String == "next"
                json = "{\"results\":[{\"id\":\"\(second ? "b" : "a")\",\"properties\":{\"Name\":{\"type\":\"title\",\"title\":[{\"plain_text\":\"Task\"}]},\"Status\":{\"type\":\"status\",\"status\":{\"id\":\"done\",\"name\":\"Done\"}}}}],\"has_more\":\(!second),\"next_cursor\":\(second ? "null" : "\"next\"")}"
            case "/v1/blocks/page/children":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query?.first { $0.name == "page_size" }?.value, "100")
                json = cursor == nil ? "{\"results\":[{\"id\":\"child\",\"type\":\"paragraph\",\"has_children\":true,\"paragraph\":{\"rich_text\":[{\"plain_text\":\"Parent\"}]}}],\"has_more\":true,\"next_cursor\":\"next\"}" : "{\"results\":[{\"id\":\"last\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[]}}],\"has_more\":false}"
            case "/v1/blocks/child/children":
                XCTAssertEqual(request.httpMethod, "GET")
                json = "{\"results\":[{\"id\":\"nested\",\"type\":\"to_do\",\"to_do\":{\"checked\":true,\"rich_text\":[{\"plain_text\":\"Nested\"}]}}],\"has_more\":false}"
            default:
                XCTFail("Unexpected or writing endpoint: \(path)")
                throw NotionAPIError.invalidResponse
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let db = try await api.taskDatabase("db")
        XCTAssertEqual(db.name, "Tasks")
        let (schema, complete, categories) = try await api.taskSchema(db.sources[0].id, statusName: nil)
        let tasks = try await api.tasks(source: "source", mapping: .automatic(schema), completedIDs: complete, categories: categories)
        XCTAssertEqual(tasks.map(\.id), ["a", "b"])
        XCTAssertTrue(tasks.allSatisfy(\.completed))
        XCTAssertTrue(tasks.allSatisfy { $0.category == .complete })
        XCTAssertEqual(categories["open"], .notStarted)
        XCTAssertEqual(categories["done"], .complete)
        XCTAssertFalse(recorder.paths.contains { $0.contains("blocks") })
        let blocks = try await api.taskBlocks("page")
        XCTAssertEqual(blocks.map(\.id), ["child", "nested", "last"])
        XCTAssertEqual(blocks.map(\.depth), [0, 1, 0])
        _ = try await api.taskBlocks("page")
        XCTAssertEqual(recorder.paths.filter { $0 == "/v1/blocks/child/children" }.count, 2, "Reopening must refetch expiring image URLs")
    }
    func testStatusCategoriesUseSchemaIDsAndColorsUsePageStatus() async throws {
        let api = NotionDatabaseAPI(token: "test") { request in
            let json: String
            if request.url!.path == "/v1/data_sources/source" {
                json = #"{"properties":{"State":{"id":"s","type":"status","status":{"groups":[{"name":"Custom A","option_ids":["todo"]},{"name":"Custom B","option_ids":["active"]},{"name":"Custom C","option_ids":["done"]}]}}}}"#
            } else {
                XCTAssertEqual(request.url!.path, "/v1/data_sources/source/query")
                json = #"{"results":[{"id":"task","properties":{"State":{"type":"status","status":{"id":"active","name":"Review","color":"purple"}}}}],"has_more":false}"#
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let (schema, completed, categories) = try await api.taskSchema("source", statusName: nil)
        XCTAssertEqual(categories, ["todo": .notStarted, "active": .inProgress, "done": .complete])
        XCTAssertEqual(completed, ["done"])
        let tasks = try await api.tasks(source: "source", mapping: .automatic(schema), completedIDs: completed, categories: categories)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.category, .inProgress)
        XCTAssertEqual(task.statusColor, "purple")
        XCTAssertFalse(task.completed)
    }
    func test429RetriesReadOnlyQuery() async throws {
        final class Counter { var value = 0 }
        let counter = Counter()
        let api = NotionDatabaseAPI(token: "test") { request in
            counter.value += 1
            XCTAssertEqual(request.url?.path, "/v1/data_sources/source/query")
            let status = counter.value == 1 ? 429 : 200
            return (Data("{\"results\":[],\"has_more\":false}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "1"])!)
        }
        let rows = try await api.tasks(source: "source", mapping: .init(), completedIDs: [])
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(counter.value, 2)
    }
    func testSharedPageURLIsNotADatabaseAndUnsharedDatabaseStays404() async throws {
        for sharedPage in [true, false] {
            let api = NotionDatabaseAPI(token: "test") { request in
                let page = request.url!.path == "/v1/pages/id" && sharedPage
                return (Data((page ? "{\"object\":\"page\"}" : "{\"message\":\"object_not_found\"}").utf8),
                        HTTPURLResponse(url: request.url!, statusCode: page ? 200 : 404, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await api.taskDatabase("id"); XCTFail("Must reject") }
            catch NotionAPIError.server(let code, _) { XCTAssertEqual(code, sharedPage ? 400 : 404) }
        }
    }
    @MainActor func testBoundedJSONCacheFilterAndFirstSelectionPersist() throws {
        let suite = "notion-tasks-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = NotionTasksStore.Configuration()
        configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
        configuration.source = "source"
        defaults.set(try JSONEncoder().encode(configuration), forKey: "notionTasks.configuration")
        defaults.set(try JSONEncoder().encode(NotionTasksStore.Cache(url: configuration.url, source: "source", tasks: (0..<1005).map { task("\($0)") })), forKey: "notionTasks.cache.v1")
        let store = NotionTasksStore(defaults: defaults)
        XCTAssertEqual(store.tasks.count, 1000)
        store.configuration.autoSelected = true
        store.filter = .all
        let restored = NotionTasksStore(defaults: defaults)
        XCTAssertTrue(restored.configuration.autoSelected)
        XCTAssertEqual(restored.filter, .all)
        configuration.source = "other"
        defaults.set(try JSONEncoder().encode(configuration), forKey: "notionTasks.configuration")
        XCTAssertTrue(NotionTasksStore(defaults: defaults).tasks.isEmpty, "Do not display another source's cache")
        store.connectionChanged()
        XCTAssertNil(defaults.data(forKey: "notionTasks.cache.v1"))
    }
    func testCacheSerializesConcurrentReadModifyWriteAndPersistsAllThreads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notion-cache-race-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = NotionAgentsCache(url: url)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let thread = NotionThread(id: "thread-\(index)", title: "Thread", status: "completed", last_edited_time: "2026-10-13T00:00:00Z", pending_user_actions: nil)
            cache.rememberThreads([thread], agentID: "agent")
            cache.rememberMessages([NotionMessage(id: "message-\(index)", role: "agent", content: "Reply", created_time: "2026-10-13T00:00:00Z", pending_user_actions: nil)], agentID: "agent", threadID: "shared-thread")
            _ = cache.threads(for: "agent")
            _ = cache.messages(for: thread.id)
            cache.retainAgents(["agent"])
        }
        XCTAssertEqual(Set(cache.threads(for: "agent").map(\.id)).count, 64)
        XCTAssertEqual(Set(NotionAgentsCache(url: url).threads(for: "agent").map(\.id)).count, 64)
        XCTAssertEqual(Set(NotionAgentsCache(url: url).messages(for: "shared-thread").map(\.id)).count, 64)
    }
}
