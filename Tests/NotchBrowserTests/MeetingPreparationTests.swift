import XCTest
import Combine
@testable import NotchBrowser

private actor PreparationTestClock: MeetingPreparationClock {
    private var waits: [(TimeInterval, CheckedContinuation<Void, Error>, TimeInterval, UUID)] = []
    private var registrations: [TimeInterval: Int] = [:]
    private(set) var elapsed: TimeInterval = 0
    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                registrations[seconds, default: 0] += 1
                waits.append((seconds, continuation, elapsed + seconds, id))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        let matching = waits.filter { $0.3 == id }; waits.removeAll { $0.3 == id }
        matching.forEach { $0.1.resume(throwing: CancellationError()) }
    }
    func hasFreshDeadline(_ seconds: TimeInterval) -> Bool {
        waits.contains { $0.0 == seconds && $0.2 >= elapsed + seconds }
    }
    func registered(_ seconds: TimeInterval) -> Int { registrations[seconds, default: 0] }
    func advance(_ seconds: TimeInterval) {
        elapsed += seconds
        let due = waits.filter { $0.2 <= elapsed }; waits.removeAll { $0.2 <= elapsed }
        due.forEach { $0.1.resume() }
    }
    func count(_ seconds: TimeInterval) -> Int { waits.filter { $0.0 == seconds }.count }
    func fire(_ seconds: TimeInterval) {
        let matching = waits.filter { $0.0 == seconds }; waits.removeAll { $0.0 == seconds }
        matching.forEach { $0.1.resume() }
    }
    func finish() { let waits = self.waits; self.waits = []; waits.forEach { $0.1.resume(throwing: CancellationError()) } }
}
private actor PreparationFakeProvider: MeetingStagedEmbeddingProvider {
    nonisolated let identity = MeetingModelManifest.identity
    var attempts = 0
    let failFirst: Bool
    let clock: PreparationTestClock?
    let pause: Bool
    let lateCompile: Bool
    let failEmbedding: Bool
    init(failFirst: Bool = false, clock: PreparationTestClock? = nil, pause: Bool = false, failEmbedding: Bool = false, lateCompile: Bool = false) {
        self.lateCompile = lateCompile; self.failFirst = failFirst; self.clock = clock; self.pause = pause; self.failEmbedding = failEmbedding
    }
    func prepare() async throws { try await prepare(report: { _ in }) }
    func prepare(report: @escaping @Sendable (MeetingPreparationState) async -> Void) async throws {
        attempts += 1
        await report(.download(bytes: 32, total: 100))
        if pause, let clock { try await clock.sleep(seconds: 999) }
        await report(.compile)
        if lateCompile, let clock {
            let _: Int = try await meetingCompileWithFallback(timeouts: .init(), clock: clock, waiting: { await report(.compileWaiting) }) { _ in
                try await clock.sleep(seconds: 999); return 1
            }
        }
        // A late delegate progress callback must not regress the compile stage.
        await report(.download(bytes: 20, total: 100))
        if failFirst && attempts == 1 { throw MeetingModelError.unconfigured }
    }
    func embedding(_ text: String, isQuery: Bool) async throws -> [Float] {
        if failEmbedding { throw MeetingModelError.invalidEmbedding }
        return [1] + Array(repeating: 0, count: 255)
    }
}
private actor PreparationAttempts {
    var modes: [Bool] = []
    func add(_ mode: Bool) { modes.append(mode) }
}
private func preparationRunsOnMainThread() -> Bool { Thread.isMainThread }

final class MeetingPreparationTests: XCTestCase {
    private func wait(_ clock: PreparationTestClock, seconds: TimeInterval, count: Int = 1) async {
        for _ in 0..<10000 { if await clock.count(seconds) >= count { return }; await Task.yield() }
        XCTFail("Fake clock waiter was not registered")
    }
    private func timeout(_ seconds: TimeInterval) async {
        let clock = PreparationTestClock()
        let task = Task { try await meetingWithTimeout(seconds: seconds, clock: clock) { try await clock.sleep(seconds: 999); return 1 } }
        await wait(clock, seconds: seconds); await clock.fire(seconds)
        do { _ = try await task.value; XCTFail("Expected timeout") } catch { XCTAssertTrue(error is MeetingPreparationError) }
        await clock.finish()
    }
    func testDownloadContinuesBeyondThirtyMinutesWithProgress() async throws {
        let clock = PreparationTestClock(); let progress = MeetingDownloadProgress()
        let task = Task { try await meetingWatchDownloadStall(interval: 60, clock: clock, progress: progress) }
        // 40 x 55 seconds exceeds 1800 seconds, but no gap reaches 60 seconds.
        for count in 1...40 {
            for _ in 0..<10000 { if await clock.hasFreshDeadline(60) { break }; await Task.yield() }
            let fresh = await clock.hasFreshDeadline(60); XCTAssertTrue(fresh)
            await clock.advance(55)
            progress.received(Int64(count))
        }
        for _ in 0..<10000 { if await clock.hasFreshDeadline(60) { break }; await Task.yield() }
        let elapsed = await clock.elapsed; XCTAssertEqual(elapsed, 2200)
        progress.finish(); try await task.value; await clock.finish()
    }
    func testCompileTimeout() async { await timeout(MeetingPreparationTimeouts().compile) }
    func testVocabularyTimeout() async { await timeout(MeetingPreparationTimeouts().vocabulary) }
    func testEmbeddingTimeout() async { await timeout(MeetingPreparationTimeouts().embedding) }
    func testBodyTimeout() async { await timeout(MeetingPreparationTimeouts().body) }
    func testDownloadStallTimeout() async {
        let clock = PreparationTestClock(); let progress = MeetingDownloadProgress()
        let task = Task { try await meetingWatchDownloadStall(interval: 7, clock: clock, progress: progress) }
        await wait(clock, seconds: 7); await clock.fire(7)
        do { try await task.value; XCTFail("Expected stall") } catch { XCTAssertTrue(error is MeetingPreparationError) }
        progress.finish(); await clock.finish()
    }
    func testDownloadProgressResetsStall() async throws {
        let clock = PreparationTestClock(); let progress = MeetingDownloadProgress()
        let task = Task { try await meetingWatchDownloadStall(interval: 7, clock: clock, progress: progress) }
        await wait(clock, seconds: 7); progress.received(20)
        for _ in 0..<10000 { if await clock.registered(7) >= 2 { break }; await Task.yield() }
        progress.finish(); try await task.value; await clock.finish()
    }
    func testCompileFailureFallsBackToCPUAndGPU() async throws {
        let attempts = PreparationAttempts()
        let value = try await meetingCompileWithFallback(timeouts: .init(), clock: MeetingSystemClock()) { fallback in
            await attempts.add(fallback)
            if !fallback { throw MeetingModelError.invalidEmbedding }; return 42
        }
        XCTAssertEqual(value, 42); let modes = await attempts.modes; XCTAssertEqual(modes, [false, true])
    }
    func testCompileAndFallbackFailure() async {
        let attempts = PreparationAttempts()
        do {
            let _: Int = try await meetingCompileWithFallback(timeouts: .init(), clock: MeetingSystemClock()) { fallback in
                await attempts.add(fallback); throw MeetingModelError.invalidEmbedding
            }; XCTFail("Expected failure")
        } catch {}
        let modes = await attempts.modes; XCTAssertEqual(modes, [false, true])
    }
    func testCompileTimeoutWaitsWithoutStartingFallback() async throws {
        let clock = PreparationTestClock(); let attempts = PreparationAttempts(); let waiting = PreparationAttempts()
        var timeouts = MeetingPreparationTimeouts(); timeouts.compile = 7
        let task = Task {
            try await meetingCompileWithFallback(timeouts: timeouts, clock: clock, waiting: { await waiting.add(true) }) { fallback in
                await attempts.add(fallback); try await clock.sleep(seconds: 999); return 42
            }
        }
        await wait(clock, seconds: 7); await wait(clock, seconds: 999); await clock.fire(7)
        for _ in 0..<10000 { if await waiting.modes.count == 1 { break }; await Task.yield() }
        let modes = await attempts.modes; XCTAssertEqual(modes, [false])
        await clock.fire(999); let value = try await task.value; XCTAssertEqual(value, 42)
        await clock.finish()
    }
    @MainActor func testHeavyOperationRunsOffMainThread() async throws {
        let main = try await meetingWithTimeout(seconds: 60, clock: MeetingSystemClock()) { preparationRunsOnMainThread() }
        XCTAssertFalse(main)
    }
    func testCompileLateFailureThenSequentialFallback() async throws {
        let clock = PreparationTestClock(); let attempts = PreparationAttempts()
        let task = Task {
            try await meetingCompileWithFallback(timeouts: .init(), clock: clock) { fallback in
                await attempts.add(fallback)
                if !fallback { try await clock.sleep(seconds: 999); throw MeetingModelError.invalidEmbedding }
                return 42
            }
        }
        await wait(clock, seconds: 900); await wait(clock, seconds: 999); await clock.fire(900)
        let before = await attempts.modes; XCTAssertEqual(before, [false])
        await clock.fire(999); let value = try await task.value; XCTAssertEqual(value, 42)
        let modes = await attempts.modes; XCTAssertEqual(modes, [false, true]); await clock.finish()
    }
    func testConcurrentCompileRequestsShareOneOperation() async throws {
        let clock = PreparationTestClock(); let attempts = PreparationAttempts()
        let coordinator = MeetingCompileCoordinator<Int>()
        let operation: @Sendable (Bool) async throws -> Int = { mode in
            await attempts.add(mode); try await clock.sleep(seconds: 999); return 42
        }
        let first = Task { try await coordinator.run(timeouts: .init(), clock: clock, waiting: {}, operation: operation) }
        await wait(clock, seconds: 999)
        let second = Task { try await coordinator.run(timeouts: .init(), clock: clock, waiting: {}, operation: operation) }
        await wait(clock, seconds: 900); await clock.fire(900)
        for _ in 0..<10000 { if await coordinator.observers == 2 { break }; await Task.yield() }
        let observers = await coordinator.observers; XCTAssertEqual(observers, 2)
        let modes = await attempts.modes; XCTAssertEqual(modes, [false])
        await clock.fire(999)
        let values = try await (first.value, second.value); XCTAssertEqual(values.0, 42); XCTAssertEqual(values.1, 42)
        await clock.finish()
    }
    func testRetryReusesOnlySizeAndSHA256VerifiedFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tmp/reuse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = MeetingModelManifest.Artifact(path: "test", size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let good = root.appendingPathComponent("good"); try Data("abc".utf8).write(to: good)
        let bad = root.appendingPathComponent("bad"); try Data("abd".utf8).write(to: bad)
        XCTAssertTrue(try meetingReuseVerifiedFile(good, artifact: artifact))
        XCTAssertFalse(try meetingReuseVerifiedFile(bad, artifact: artifact)); XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertFalse(try meetingReuseVerifiedFile(root.appendingPathComponent("missing"), artifact: artifact))
        XCTAssertEqual(try Data(contentsOf: good), Data("abc".utf8))
        try Data("ab".utf8).write(to: bad); XCTAssertFalse(try meetingReuseVerifiedFile(bad, artifact: artifact))
    }
    func testPreparationRowsShareOneFixedHeight() { XCTAssertEqual(MeetingPreparationLayout.rowHeight, 18) }
    func testLabelsAndActualTotalBytes() {
        let total = Int64(MeetingModelManifest.artifacts.reduce(0) { $0 + $1.size })
        XCTAssertEqual(total, 584748275)
        XCTAssertEqual(MeetingPreparationState.download(bytes: total * 32 / 100 + 1, total: total).label, "意味検索を準備中・モデルをダウンロード中 32%")
        XCTAssertEqual(MeetingPreparationState.compile.label, "意味検索を準備中・初回の準備中（数分かかります）")
        XCTAssertEqual(MeetingPreparationState.ingest(completed: 12, total: 48).label, "意味検索を準備中・12/48件")
        XCTAssertEqual(MeetingPreparationState.failed.label, "意味検索を準備できませんでした")
    }
    private func meeting() -> NotionMeeting {
        .init(id: "test", title: "採用会議", status: "notes_ready", calendarStart: nil, calendarEnd: nil,
              recordingStart: nil, recordingEnd: nil, attendees: [], summary: "summary", notes: "notes", transcript: nil, created: Date(), edited: Date())
    }
    private func block() -> NotionTaskBlock {
        .parse(["id": "test-block", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "採用の話をする。"]]]], depth: 0)
    }
    @MainActor func testPreparationTransitionsAndLateDownloadIgnored() async {
        let store = MeetingSearchStore(provider: PreparationFakeProvider(), persist: false, semanticSupport: true)
        var states: [MeetingPreparationState] = []
        let observer = store.$preparation.sink { states.append($0) }
        await store.index(meetings: [meeting()]) { _ in [self.block()] }
        XCTAssertTrue(states.contains(.download(bytes: 32, total: 100)))
        XCTAssertTrue(states.contains(.compile)); XCTAssertFalse(states.contains(.download(bytes: 20, total: 100)))
        XCTAssertTrue(states.contains(.ingest(completed: 0, total: 1)))
        XCTAssertTrue(states.contains(.ingest(completed: 1, total: 1))); XCTAssertEqual(store.preparation, .ready)
        XCTAssertTrue(store.ready); XCTAssertFalse(store.preparing); _ = observer
    }
    @MainActor func testRetryAndFailureLiteralSearch() async {
        let provider = PreparationFakeProvider(failFirst: true)
        let store = MeetingSearchStore(provider: provider, persist: false, semanticSupport: true)
        let meetings = [meeting()]
        await store.index(meetings: meetings) { _ in [self.block()] }
        XCTAssertEqual(store.preparation, .failed); XCTAssertFalse(store.ready)
        let hits = await store.search(meetings: meetings, query: .parse("採用")); XCTAssertEqual(hits.count, 1)
        await store.retry(); XCTAssertEqual(store.preparation, .ready)
        let attempts = await provider.attempts; XCTAssertEqual(attempts, 2)
    }
    @MainActor func testLiteralSearchWhilePreparing() async {
        let clock = PreparationTestClock()
        let store = MeetingSearchStore(provider: PreparationFakeProvider(clock: clock, pause: true), persist: false, semanticSupport: true)
        let meetings = [meeting()]
        let task = Task { await store.index(meetings: meetings) { _ in [self.block()] } }
        await wait(clock, seconds: 999)
        XCTAssertTrue(store.preparing)
        let hits = await store.search(meetings: meetings, query: .parse("採用")); XCTAssertEqual(hits.count, 1)
        await clock.fire(999); await task.value; XCTAssertEqual(store.preparation, .ready)
    }
    @MainActor func testEmbeddingFailureKeepsLiteralSearch() async {
        let store = MeetingSearchStore(provider: PreparationFakeProvider(failEmbedding: true), persist: false, semanticSupport: true)
        let meetings = [meeting()]
        await store.index(meetings: meetings) { _ in [self.block()] }
        XCTAssertEqual(store.preparation, .failed)
        let hits = await store.search(meetings: meetings, query: .parse("採用")); XCTAssertEqual(hits.count, 1)
    }
    @MainActor func testLateCompileSuccessAutomaticallyIngestsAndBecomesReady() async {
        let clock = PreparationTestClock()
        let store = MeetingSearchStore(provider: PreparationFakeProvider(clock: clock, lateCompile: true), persist: false, semanticSupport: true)
        let meetings = [meeting()]
        let task = Task { await store.index(meetings: meetings) { _ in [self.block()] } }
        await wait(clock, seconds: 900); await wait(clock, seconds: 999); await clock.fire(900)
        for _ in 0..<10000 { if store.preparation == .failed { break }; await Task.yield() }
        XCTAssertEqual(store.preparation, .failed)
        let hits = await store.search(meetings: meetings, query: .parse("採用")); XCTAssertEqual(hits.count, 1)
        await store.retry() // Must not overlap the operation already being awaited.
        await clock.fire(999); await task.value
        XCTAssertEqual(store.preparation, .ready); XCTAssertTrue(store.ready); XCTAssertEqual(store.completed, 1)
        await clock.finish()
    }
    @MainActor func testPlanADisplayFailsAtFifteenMinutesAndLateSuccessRecovers() async {
        let clock = PreparationTestClock()
        let provider = PreparationFakeProvider(clock: clock, lateCompile: true)
        let store = MeetingSearchStore(provider: provider, persist: false, semanticSupport: true)
        var states: [MeetingPreparationState] = []
        let observer = store.$preparation.sink { states.append($0) }
        let task = Task { await store.index(meetings: [self.meeting()]) { _ in [self.block()] } }
        await wait(clock, seconds: 900); await wait(clock, seconds: 999)
        await clock.advance(899)
        XCTAssertEqual(store.preparation, .compile); XCTAssertTrue(store.preparing)
        await clock.advance(1)
        for _ in 0..<10000 { if store.preparation == .failed { break }; await Task.yield() }
        XCTAssertEqual(store.preparation, .failed); XCTAssertFalse(store.preparing)
        XCTAssertEqual(store.progressLabel, "意味検索を準備できませんでした")
        let attempts = await provider.attempts; XCTAssertEqual(attempts, 1)
        await clock.advance(99); await task.value
        XCTAssertEqual(store.preparation, .ready); XCTAssertTrue(store.ready); XCTAssertNil(store.error)
        XCTAssertTrue(states.contains(.ingest(completed: 0, total: 1))); _ = observer
        await clock.finish()
    }
    @MainActor func testPlanARetryDuringCompileOnlyChangesDisplay() async {
        let clock = PreparationTestClock()
        let provider = PreparationFakeProvider(clock: clock, lateCompile: true)
        let store = MeetingSearchStore(provider: provider, persist: false, semanticSupport: true)
        let meetings = [meeting()]
        let task = Task { await store.index(meetings: meetings) { _ in [self.block()] } }
        await wait(clock, seconds: 900); await wait(clock, seconds: 999); await clock.fire(900)
        for _ in 0..<10000 { if store.preparation == .failed { break }; await Task.yield() }
        await store.retry()
        XCTAssertEqual(store.preparation, .compile); XCTAssertTrue(store.preparing); XCTAssertNil(store.error)
        XCTAssertEqual(store.progressLabel, "意味検索を準備中・初回の準備中（数分かかります）")
        await store.retry()
        let attempts = await provider.attempts; XCTAssertEqual(attempts, 1)
        let timers = await clock.registered(900); XCTAssertEqual(timers, 1)
        let hits = await store.search(meetings: meetings, query: .parse("採用")); XCTAssertEqual(hits.count, 1)
        await clock.fire(999); await task.value; XCTAssertEqual(store.preparation, .ready)
        await clock.finish()
    }
    func testPlanAFallbackSharesOriginalFifteenMinuteDeadline() async throws {
        let clock = PreparationTestClock(); let waiting = PreparationAttempts()
        let task = Task {
            try await meetingCompileWithFallback(timeouts: .init(), clock: clock, waiting: { await waiting.add(true) }) { fallback in
                if !fallback { try await clock.sleep(seconds: 400); throw MeetingModelError.invalidEmbedding }
                try await clock.sleep(seconds: 999); return 42
            }
        }
        await wait(clock, seconds: 900); await wait(clock, seconds: 400)
        await clock.advance(400); await wait(clock, seconds: 999)
        await clock.advance(499)
        let before = await waiting.modes; XCTAssertTrue(before.isEmpty)
        await clock.advance(1)
        for _ in 0..<10000 { if await waiting.modes.count == 1 { break }; await Task.yield() }
        let after = await waiting.modes; XCTAssertEqual(after, [true])
        await clock.advance(499); let value = try await task.value; XCTAssertEqual(value, 42)
        await clock.finish()
    }
    @MainActor func testPlanANewStoreStartsFromIdle() async {
        let clock = PreparationTestClock()
        let provider = PreparationFakeProvider(clock: clock, lateCompile: true)
        let first = MeetingSearchStore(provider: provider, persist: false, semanticSupport: true)
        let task = Task { await first.index(meetings: [self.meeting()]) { _ in [self.block()] } }
        await wait(clock, seconds: 900); await wait(clock, seconds: 999); await clock.fire(900)
        for _ in 0..<10000 { if first.preparation == .failed { break }; await Task.yield() }
        let freshProvider = PreparationFakeProvider()
        let restarted = MeetingSearchStore(provider: freshProvider, persist: false, semanticSupport: true)
        XCTAssertEqual(restarted.preparation, .idle); XCTAssertFalse(restarted.preparing)
        await restarted.index(meetings: [meeting()]) { _ in [self.block()] }
        let attempts = await freshProvider.attempts; XCTAssertEqual(attempts, 1); XCTAssertEqual(restarted.preparation, .ready)
        await clock.fire(999); await task.value; await clock.finish()
    }
    @MainActor func testPreviewPreparationStates() {
        #if DEBUG
        let store = MeetingSearchStore(provider: PreparationFakeProvider(), persist: false, semanticSupport: true)
        for state in [MeetingSearchPreviewState.preparingDownload, .preparingCompile, .preparingIngest, .preparingFailed] {
            XCTAssertEqual(MeetingSearchPreviewState.parse(arguments: ["--meeting-search=\(state.rawValue)"]), state)
            XCTAssertTrue(state.isPreparation)
            store.preview(state: state.rawValue, meetings: [])
            XCTAssertFalse(store.progressLabel.isEmpty); XCTAssertFalse(store.ready)
        }
        #endif
    }
}
