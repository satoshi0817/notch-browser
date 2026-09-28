import Foundation

/// v0.1.0 shipped as `com.ssuzuki.NotchBrowser`. Copies its settings and website data
/// (logins) to the current bundle ID once. The old data is left in place.
enum LegacyMigration {
    private static let legacyID = "com.ssuzuki.NotchBrowser"
    private static let doneKey = "migratedFromLegacyBundleID"

    /// Must run before any WKWebView or UserDefaults access.
    static func run() {
        guard let currentID = Bundle.main.bundleIdentifier, currentID != legacyID else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        if let legacy = defaults.persistentDomain(forName: legacyID), defaults.persistentDomain(forName: currentID)?.isEmpty ?? true {
            defaults.setPersistentDomain(legacy, forName: currentID)
        }

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let items = [
            ("WebKit/\(legacyID)", "WebKit/\(currentID)"),
            ("HTTPStorages/\(legacyID)", "HTTPStorages/\(currentID)"),
            ("HTTPStorages/\(legacyID).binarycookies", "HTTPStorages/\(currentID).binarycookies"),
        ]
        for (from, to) in items {
            let source = library.appendingPathComponent(from)
            let destination = library.appendingPathComponent(to)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: destination)
        }

        defaults.set(true, forKey: doneKey)
    }
}
