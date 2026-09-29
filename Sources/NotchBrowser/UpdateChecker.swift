import AppKit
import Combine
import SwiftUI

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ tag: String) {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return nil }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable { let name: String; let state: String; let size: Int }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    var pageURL: URL? {
        guard version != nil else { return nil }
        // Construct from the fixed repository, never follow a URL supplied in a response.
        return URL(string: "https://github.com/satoshi0817/notch-browser/releases/tag/" + tag_name)
    }
    var hasDownload: Bool {
        assets.contains { $0.state == "uploaded" && $0.size > 0 && $0.name == "NotchBrowser-" + (tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name) + ".zip" }
    }
    func isUpdate(from current: String) -> Bool {
        guard !draft, !prerelease, let version, let installed = ReleaseVersion(current), version > installed else { return false }
        return hasDownload
    }
}

struct UpdateSchedule {
    static let day: TimeInterval = 24 * 60 * 60
    let defaults: UserDefaults
    var enabled: Bool {
        get { defaults.object(forKey: "updates.enabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "updates.enabled") }
    }
    func isDue(at now: Date) -> Bool {
        enabled && now >= (defaults.object(forKey: "updates.nextCheck") as? Date ?? .distantPast)
    }
    func recordAttempt(at now: Date, succeeded: Bool) {
        defaults.set(now.addingTimeInterval(succeeded ? Self.day : 3600), forKey: "updates.nextCheck")
        if succeeded { defaults.set(now, forKey: "updates.lastSuccess") }
    }
    func shouldRemind(_ tag: String, at now: Date) -> Bool {
        guard defaults.string(forKey: "updates.skippedTag") != tag else { return false }
        return defaults.string(forKey: "updates.remindedTag") != tag || now >= (defaults.object(forKey: "updates.remindAfter") as? Date ?? .distantPast)
    }
    func remindLater(_ tag: String, at now: Date) {
        defaults.set(tag, forKey: "updates.remindedTag")
        defaults.set(now.addingTimeInterval(Self.day), forKey: "updates.remindAfter")
    }
    func skip(_ tag: String) { defaults.set(tag, forKey: "updates.skippedTag") }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let endpoint = URL(string: "https://api.github.com/repos/satoshi0817/notch-browser/releases/latest")!
    @Published private(set) var isChecking = false
    @Published private(set) var status = ""
    @Published private(set) var available: GitHubRelease?
    @Published var automatic: Bool { didSet { schedule.enabled = automatic } }
    let currentVersion: String
    private let schedule: UpdateSchedule
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private var timer: Timer?
    private var launchTask: Task<Void, Never>?
    var onUpdate: ((GitHubRelease, Bool) -> Void)?
    var onMessage: ((String) -> Void)?

    init(defaults: UserDefaults = .standard, currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        schedule = UpdateSchedule(defaults: defaults)
        automatic = schedule.enabled
        self.currentVersion = currentVersion
        self.fetch = fetch
        if let date = defaults.object(forKey: "updates.lastSuccess") as? Date {
            status = "最終確認: " + date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
        timer?.tolerance = 60
        launchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.check(manual: false)
        }
    }

    func check(manual: Bool = true, now: Date = Date()) async {
        guard !isChecking, manual || schedule.isDue(at: now) else { return }
        isChecking = true
        status = "アップデートを確認中…"
        defer { isChecking = false }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NotchBrowser/" + currentVersion, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard release.version != nil, release.hasDownload, !release.draft, !release.prerelease else { throw URLError(.cannotParseResponse) }
            schedule.recordAttempt(at: now, succeeded: true)
            if release.isUpdate(from: currentVersion) {
                available = release
                status = "新しいバージョン \(release.tag_name) があります"
                if (manual || automatic) && (manual || schedule.shouldRemind(release.tag_name, at: now)) {
                    schedule.remindLater(release.tag_name, at: now)
                    onUpdate?(release, manual)
                }
            } else {
                available = nil
                status = "現在のバージョン \(currentVersion) は最新です"
                if manual { onMessage?(status) }
            }
        } catch {
            schedule.recordAttempt(at: now, succeeded: false)
            status = "確認できませんでした。通信環境を確認して、あとでお試しください。"
            if manual { onMessage?(status) }
        }
    }
    func later(_ release: GitHubRelease) { schedule.remindLater(release.tag_name, at: Date()) }
    func skip(_ release: GitHubRelease) { schedule.skip(release.tag_name) }
}

@MainActor
final class UpdateWindowController: NSWindowController {
    init(release: GitHubRelease, checker: UpdateChecker, manual: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NotchBrowser アップデート"
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: UpdateReminderView(release: release, current: checker.currentVersion, open: { [weak self] in
            guard let url = release.pageURL else { return }
            if NSWorkspace.shared.open(url) { checker.later(release); self?.close() }
        }, later: { [weak self] in checker.later(release); self?.close() }, skip: { [weak self] in checker.skip(release); self?.close() }))
        window.center()
        if manual { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct UpdateReminderView: View {
    let release: GitHubRelease
    let current: String
    let open: () -> Void
    let later: () -> Void
    let skip: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("新しいバージョンがあります", systemImage: "arrow.down.circle").font(.title3.bold())
            Text("\(current) → \(release.tag_name)").font(.headline).foregroundStyle(.cyan)
            Text("GitHubで変更内容を確認し、アップデートをダウンロードできます。置き換える前にNotchBrowserを終了してください。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("このバージョンをスキップ", action: skip).buttonStyle(.link)
                Spacer()
                Button("あとで", action: later).keyboardShortcut(.cancelAction)
                Button("リリースを開く", action: open).keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }.padding(24).frame(width: 460).preferredColorScheme(.dark)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var checker = UpdateChecker.shared
    var body: some View {
        Section("アップデート") {
            Toggle("新しいバージョンを自動で確認", isOn: $checker.automatic)
            HStack {
                Text("バージョン \(checker.currentVersion)").foregroundStyle(.secondary)
                Spacer()
                Button(checker.isChecking ? "確認中…" : "アップデートを確認") { Task { await checker.check() } }.disabled(checker.isChecking)
            }
            if !checker.status.isEmpty { Text(checker.status).font(.caption).foregroundStyle(.secondary) }
            Text("起動中に1日1回、GitHubの正式版を確認します。あとでは翌日以降に再通知し、スキップはそのバージョンだけ通知しません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
