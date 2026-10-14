import Foundation

enum MeetingSearchLegacyCleanup {
    static func target(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/NotchBrowser/meeting-search", isDirectory: true)
    }

    /// Fail closed for aliases, traversal, links (including ancestors), and non-directories.
    @discardableResult
    static func remove(_ candidate: URL, home: URL, fileManager: FileManager = .default) throws -> Bool {
        let expected = target(home: home)
        guard candidate.isFileURL, candidate.path == expected.path,
              candidate.pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        var ancestor = candidate
        while ancestor.path != "/" {
            guard let attributes = try? fileManager.attributesOfItem(atPath: ancestor.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
            ancestor.deleteLastPathComponent()
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        var enumerationFailed = false
        guard let contents = fileManager.enumerator(at: candidate, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                    errorHandler: { _, _ in enumerationFailed = true; return false }) else { return false }
        for case let item as URL in contents {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return false }
        }
        guard !enumerationFailed else { return false }
        try fileManager.removeItem(at: candidate)
        return true
    }

    static func runAtStartup() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        _ = try? remove(target(home: home), home: home)
    }
}
