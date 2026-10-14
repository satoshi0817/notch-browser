import Foundation
import os

enum MeetingPreparationState: Equatable {
    case idle, download(bytes: Int64, total: Int64), compile, compileWaiting, ingest(completed: Int, total: Int), ready, failed
    var label: String {
        switch self {
        case let .download(bytes, total): return "意味検索を準備中・モデルをダウンロード中 \(total > 0 ? min(100, bytes * 100 / total) : 0)%"
        case .compileWaiting: return "意味検索を準備中・初回の準備の完了を待っています"
        case .compile: return "意味検索を準備中・初回の準備中（数分かかります）"
        case let .ingest(completed, total): return "意味検索を準備中・\(completed)/\(total)件"
        case .failed: return "意味検索を準備できませんでした"
        default: return ""
        }
    }
}

struct MeetingPreparationTimeouts {
    var downloadStall: TimeInterval = 60
    var compile: TimeInterval = 15 * 60
    var vocabulary: TimeInterval = 120
    var embedding: TimeInterval = 60
    var body: TimeInterval = 60
}

protocol MeetingPreparationClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}
struct MeetingSystemClock: MeetingPreparationClock {
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}
enum MeetingPreparationError: Error { case timeout }
enum MeetingSearchLog {
    static let logger = Logger(subsystem: "com.satoshi0817.NotchBrowser", category: "meeting-search")
}
enum MeetingSearchLogStage: String {
    case operation, compile, vocabulary, embedding, body
    case downloadStall = "download stall"
    case queryEmbedding = "query embedding"
}

final class MeetingCompiledLocation: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
    func set(_ url: URL) { lock.lock(); self.url = url; lock.unlock() }
}

// A structured task group waits for an uncooperative Core ML operation even after
// cancellation. Resume the caller independently; discard any late result.
private final class MeetingDeadlineResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
func meetingWithTimeout<T>(seconds: TimeInterval, clock: any MeetingPreparationClock,
                           stage: MeetingSearchLogStage = .operation,
                           operation: @escaping @Sendable () async throws -> T) async throws -> T {
    MeetingSearchLog.logger.debug("\(stage.rawValue, privacy: .public) start")
    let tasks = MeetingDeadlineTasks()
    do {
        let value: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let result = MeetingDeadlineResult(continuation)
                tasks.install(
                    Task.detached { do { result.finish(.success(try await operation())) } catch { result.finish(.failure(error)) }; tasks.cancel() },
                    Task.detached { do { try await clock.sleep(seconds: seconds); result.finish(.failure(MeetingPreparationError.timeout)); tasks.cancel() } catch {} },
                    cancel: { result.finish(.failure(CancellationError())) })
            }
        } onCancel: { tasks.cancel(notify: true) }
        MeetingSearchLog.logger.debug("\(stage.rawValue, privacy: .public) end")
        return value
    } catch {
        MeetingSearchLog.logger.error("\(stage.rawValue, privacy: .public) failed")
        throw error
    }
}
private final class MeetingDeadlineTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false
    private var cancellation: (() -> Void)?
    func install(_ work: Task<Void, Never>, _ timer: Task<Void, Never>, cancel: @escaping () -> Void) {
        lock.lock(); let stopped = self.stopped
        if !stopped { tasks = [work, timer]; cancellation = cancel }; lock.unlock()
        if stopped { work.cancel(); timer.cancel(); cancel() }
    }
    func cancel(notify: Bool = false) {
        lock.lock(); stopped = true; let tasks = self.tasks; self.tasks = []; let callback = cancellation; lock.unlock()
        tasks.forEach { $0.cancel() }; if notify { callback?() }
    }
}

protocol MeetingStagedEmbeddingProvider: MeetingEmbeddingProvider {
    func prepare(report: @escaping @Sendable (MeetingPreparationState) async -> Void) async throws
    func resetForRetry() async
}
extension MeetingStagedEmbeddingProvider { func resetForRetry() async {} }

// The underlying task survives the UI deadline. A fallback may only begin after
// the previous operation has actually terminated with an error.
func meetingCompileWithFallback<T>(timeouts: MeetingPreparationTimeouts, clock: any MeetingPreparationClock,
                                   waiting: @escaping @Sendable () async -> Void = {},
                                   operation: @escaping @Sendable (Bool) async throws -> T) async throws -> T {
    // One display deadline covers the complete sequential preparation, including
    // a fallback. The underlying work is never cancelled by this deadline.
    let work = Task.detached {
        do { return try await operation(false) }
        catch {
            try Task.checkCancellation()
            MeetingSearchLog.logger.error("compile finished with failure; retrying cpuAndGPU")
            return try await operation(true)
        }
    }
    do {
        return try await meetingWithTimeout(seconds: timeouts.compile, clock: clock, stage: .compile) { try await work.value }
    } catch is MeetingPreparationError {
        MeetingSearchLog.logger.info("compile deadline; waiting for active operation")
        await waiting()
        return try await work.value
    } catch {
        if Task.isCancelled { return try await work.value }
        throw error
    }
}

actor MeetingCompileCoordinator<T> {
    private var active: (UUID, Task<T, Error>)?
    private(set) var observers = 0
    var isRunning: Bool { active != nil }
    func run(timeouts: MeetingPreparationTimeouts, clock: any MeetingPreparationClock,
             waiting: @escaping @Sendable () async -> Void,
             operation: @escaping @Sendable (Bool) async throws -> T) async throws -> T {
        observers += 1
        defer { observers -= 1 }
        if let active { return try await active.1.value }
        let id = UUID()
        let task = Task.detached { try await meetingCompileWithFallback(timeouts: timeouts, clock: clock, waiting: waiting, operation: operation) }
        active = (id, task)
        defer { if active?.0 == id { active = nil } }
        return try await task.value
    }
}

// Each increasing-byte event starts a fresh stall deadline. There is no total
// duration limit and no polling window that can postpone detection by 60 seconds.
final class MeetingDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Int64 = 0
    private let stream: AsyncStream<Int64>
    private let continuation: AsyncStream<Int64>.Continuation
    init() {
        var continuation: AsyncStream<Int64>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
    }
    func received(_ bytes: Int64) {
        lock.lock(); let advanced = bytes > latest; latest = max(latest, bytes); lock.unlock()
        if advanced { continuation.yield(bytes) }
    }
    func finish() { continuation.finish() }
    func next() async -> Int64? { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
}
func meetingWatchDownloadStall(interval: TimeInterval, clock: any MeetingPreparationClock,
                               progress: MeetingDownloadProgress) async throws {
    var previous: Int64 = 0
    while let current = try await meetingWithTimeout(seconds: interval, clock: clock, stage: .downloadStall, operation: { await progress.next() }) {
        if current > previous { previous = current }
    }
}

func meetingReuseVerifiedFile(_ url: URL, artifact: MeetingModelManifest.Artifact) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    if (try? MeetingModelManifest.verifyFile(url, artifact: artifact)) == true { return true }
    try FileManager.default.removeItem(at: url)
    return false
}

enum MeetingPreparationLayout {
    static let rowHeight: CGFloat = 18
}

final class MeetingModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var cancelled = false
    private let destination: URL
    private let events = MeetingDownloadProgress()
    private let filename: String
    private let progress: @Sendable (Int64) async -> Void
    init(destination: URL, filename: String, progress: @escaping @Sendable (Int64) async -> Void) {
        self.destination = destination; self.filename = filename; self.progress = progress
    }
    private func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
    func receivedBytes() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
    func start(url: URL, timeouts: MeetingPreparationTimeouts, clock: any MeetingPreparationClock) async throws -> URL {
        defer { session?.invalidateAndCancel() }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let config = URLSessionConfiguration.ephemeral
                    // Only our byte-progress watchdog determines timeout.
                    config.timeoutIntervalForRequest = .greatestFiniteMagnitude
                    config.timeoutIntervalForResource = .greatestFiniteMagnitude
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    self.session = session; lock.unlock(); session.downloadTask(with: url).resume()
                    Task.detached { [self] in
                        do {
                            try await meetingWatchDownloadStall(interval: timeouts.downloadStall, clock: clock,
                                                                progress: self.events)
                        } catch {
                            finish(.failure(error)); session.invalidateAndCancel()
                        }
                    }
                }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let session = self.session; lock.unlock()
        finish(.failure(CancellationError())); session?.invalidateAndCancel()
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        events.finish(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData count: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let advanced = totalBytesWritten > bytes; bytes = max(bytes, totalBytesWritten); lock.unlock()
        if advanced { events.received(totalBytesWritten) }
        MeetingSearchLog.logger.debug("download \(self.filename, privacy: .public) \(totalBytesWritten, privacy: .public) bytes")
        Task { await progress(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw MeetingModelError.checksum }
            try FileManager.default.moveItem(at: location, to: destination); finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }
}
