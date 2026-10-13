import Foundation

/// A bounded, on-disk snapshot so chat navigation does not depend on network timing.
final class NotionAgentsCache {
    private struct Snapshot: Codable {
        var threadsByAgent: [String: [NotionThread]] = [:]
        var messagesByThread: [String: [NotionMessage]] = [:]
        var threadOwners: [String: String] = [:]
    }

    static let live: NotionAgentsCache = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NotionAgentsCache(url: support.appendingPathComponent("NotchBrowser/NotionAgentsCache.json"))
    }()

    // Multiple stores can share this cache. Keep merging and JSON encoding in
    // the same critical section; locking only the file write leaves dictionaries racing.
    private let lock = NSRecursiveLock()
    private let url: URL
    private var snapshot: Snapshot
    private var lastSavedData: Data?

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        snapshot = data.flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        lastSavedData = data
    }

    func threads(for agentID: String) -> [NotionThread] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.threadsByAgent[agentID] ?? []
    }

    func messages(for threadID: String) -> [NotionMessage] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.messagesByThread[threadID] ?? []
    }

    @discardableResult
    func rememberThreads(_ fetched: [NotionThread], agentID: String) -> [NotionThread] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        let merged = (fetched + threads(for: agentID)).filter { seen.insert($0.id).inserted }
        snapshot.threadsByAgent[agentID] = Array(merged.prefix(200))
        for thread in fetched { snapshot.threadOwners[thread.id] = agentID }
        save()
        return snapshot.threadsByAgent[agentID] ?? []
    }

    @discardableResult
    func rememberMessages(_ fetched: [NotionMessage], agentID: String, threadID: String) -> [NotionMessage] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        let merged = (fetched + messages(for: threadID)).filter { seen.insert($0.id).inserted }
        snapshot.messagesByThread[threadID] = Array(NotionMessage.oldestFirst(merged).suffix(500))
        snapshot.threadOwners[threadID] = agentID
        save()
        return snapshot.messagesByThread[threadID] ?? []
    }

    func retainAgents(_ agentIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        snapshot.threadsByAgent = snapshot.threadsByAgent.filter { agentIDs.contains($0.key) }
        snapshot.threadOwners = snapshot.threadOwners.filter { agentIDs.contains($0.value) }
        snapshot.messagesByThread = snapshot.messagesByThread.filter { snapshot.threadOwners[$0.key] != nil }
        save()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        snapshot = Snapshot()
        lastSavedData = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot), data != lastSavedData else { return }
        let directory = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastSavedData = data
    }
}
