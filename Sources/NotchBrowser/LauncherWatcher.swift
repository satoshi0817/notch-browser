import AppKit

/// Notices when a launcher (Raycast, Alfred, Spotlight) is showing a window, so the
/// notch can drop below it. Launchers usually don't activate, so we poll the window list.
final class LauncherWatcher {
    static let bundleIDs: Set<String> = [
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
        "com.apple.Spotlight",
    ]

    /// The lowest window level of a visible launcher window, or nil when none is showing.
    var onChange: ((Int?) -> Void)?
    private var timer: Timer?
    private var current: Int?

    func start() {
        guard timer == nil else { return }
        timer = .scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        update(nil)
    }

    private func poll() {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(Self.bundleIDs.contains) ?? false }
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return update(nil) }

        let levels = windows.compactMap { info -> Int? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 100, (bounds["Height"] ?? 0) > 40,
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0
            else { return nil }
            return layer
        }
        update(levels.min())
    }

    private func update(_ level: Int?) {
        guard level != current else { return }
        current = level
        onChange?(level)
    }
}
