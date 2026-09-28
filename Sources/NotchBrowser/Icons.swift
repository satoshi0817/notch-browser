import AppKit

enum AppSupport {
    static func directory(_ name: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBrowser", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum TabIconRenderer {
    static let presetSymbols = [
        "envelope", "calendar", "bubble.left.and.bubble.right", "doc.text", "folder", "star",
        "bolt", "globe", "video", "music.note", "cart", "chart.bar", "person", "briefcase",
        "book", "checklist", "house", "heart", "newspaper", "gamecontroller", "terminal", "sparkles",
    ]

    /// Legacy icon preferences still decode, but all app UI uses SF Symbols.
    static func symbolName(for icon: TabIcon, hosts: [String?]) -> String {
        if case .symbol(let name) = icon, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        let host = hosts.compactMap { $0 }.first?.lowercased() ?? ""
        let categories: [(String, [String])] = [
            ("envelope", ["mail.", "outlook."]), ("calendar", ["calendar."]),
            ("bubble.left.and.bubble.right", ["slack.", "discord.", "teams.", "chat."]),
            ("play.rectangle", ["youtube.", "netflix.", "twitch.", "vimeo."]),
            ("music.note", ["spotify.", "music."]), ("doc.text", ["notion.", "docs."]),
            ("chevron.left.forwardslash.chevron.right", ["github.", "gitlab.", "localhost"]),
            ("folder", ["drive.", "dropbox."]), ("sparkles", ["chatgpt.", "claude.", "gemini."])
        ]
        return categories.first { pair in pair.1.contains { host.contains($0) } }?.0 ?? "globe"
    }

    static func image(for icon: TabIcon, hosts: [String?], size: CGFloat = 16, grayscale: Bool = false) -> NSImage {
        symbol(symbolName(for: icon, hosts: hosts), size: size) ?? NSImage()
    }

    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil))?
            .withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .medium))
    }
}
