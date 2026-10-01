import AppKit
import Combine
import WebKit

/// A set of cookies / logins. Tabs sharing a profile share their sessions.
struct Profile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String

    /// The default profile uses WebKit's default data store, so existing logins carry over.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var isDefault: Bool { id == Self.defaultID }
}

/// Only agents explicitly added by the user are shown and polled.
struct SavedNotionAgent: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var glyph: String = "✦"
    var iconURL: String? = nil
}

enum NotionAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }
    var isDark: Bool {
        switch self {
        case .light: false
        case .dark: true
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
    var resolvedAppearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua)!
    }
}

enum NotionTabDisplay: String, Codable, CaseIterable, Identifiable {
    case iconAndTitle, iconOnly, titleOnly
    var id: Self { self }
    var title: String {
        switch self {
        case .iconAndTitle: "アイコンとタイトル"
        case .iconOnly: "アイコンのみ"
        case .titleOnly: "タイトルのみ"
        }
    }
}

enum TabIcon: Codable, Hashable {
    case favicon
    case symbol(String)
    // Retained only to decode preferences from older releases.
    case emoji(String)
    /// Legacy custom image file name; rendered as an automatic symbol now.
    case image(String)
}

/// A tab that is always present and restored on launch.
struct PinnedTab: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var icon: TabIcon = .favicon
    var iconOnly = false
    var profileID = Profile.defaultID

    var host: String? { URL(string: url)?.host() }
}

/// Which tab to show when the notch opens.
enum OpenTabBehavior: Codable, Hashable {
    case lastViewed
    case pinned(UUID)
}

struct DisplaySettings: Codable, Hashable {
    var enabled: Bool
    /// Opacity of the collapsed notch (1 = solid black).
    var idleOpacity: Double = 1
    var width: Double = 960
    var height: Double = 660
}

enum ToolbarAction: String, Codable, CaseIterable, Identifiable {
    case back, forward, home, reload, address, keepOpen, find, copyURL
    case zoomIn, zoomOut, resetZoom, autoRefresh, restore, tabSearch, closeTab, shelf, notes, notion, external, settings, quit
    case spacer
    var id: Self { self }
    var title: String {
        switch self {
        case .back: "戻る"
        case .forward: "進む"
        case .home: "設定したページに戻る"
        case .reload: "再読み込み"
        case .address: "URLを表示・検索"
        case .keepOpen: "開いたままにする"
        case .find: "ページ内を検索"
        case .copyURL: "URLをコピー"
        case .zoomIn: "拡大"
        case .zoomOut: "縮小"
        case .resetZoom: "実際のサイズ"
        case .autoRefresh: "自動更新"
        case .restore: "閉じたタブを戻す"
        case .tabSearch: "タブを検索"
        case .closeTab: "タブを閉じる"
        case .shelf: "ファイル棚"
        case .notes: "クイックメモ"
        case .notion: "Notionエージェント"
        case .external: "ブラウザで開く"
        case .settings: "設定"
        case .quit: "終了"
        case .spacer: "可変スペーサー"
        }
    }
    var symbolName: String {
        switch self {
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .home: "house"
        case .reload: "arrow.clockwise"
        case .address, .find: "magnifyingglass"
        case .keepOpen: "pin"
        case .copyURL: "link"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .resetZoom: "arrow.up.left.and.arrow.down.right"
        case .autoRefresh: "arrow.triangle.2.circlepath"
        case .restore: "arrow.uturn.backward"
        case .tabSearch: "square.stack"
        case .closeTab: "xmark"
        case .shelf: "tray"
        case .notes: "square.and.pencil"
        case .notion: "sparkles.rectangle.stack"
        case .external: "safari"
        case .settings: "gearshape"
        case .quit: "power"
        case .spacer: "arrow.left.and.right"
        }
    }
    static let defaults: [Self] = [.back, .forward, .home, .reload, .address, .keepOpen, .settings, .quit]
}

struct SettingsData: Codable {
    var profiles = [Profile(id: Profile.defaultID, name: "デフォルト")]
    var pinnedTabs = [
        PinnedTab(name: "メール", url: "https://mail.google.com/", icon: .symbol("envelope")),
        PinnedTab(name: "カレンダー", url: "https://calendar.google.com/", icon: .symbol("calendar")),
    ]
    /// Insertion point among pinned pages for the Notion agent panel.
    var notionTabPosition = 2
    var notionEnabled = true
    var notionTabDisplay = NotionTabDisplay.iconAndTitle
    var newTabProfileID = Profile.defaultID
    /// Keyed by display UUID.
    var displays: [String: DisplaySettings] = [:]
    var countdownEnabled = true
    var countdownMinutes = 30
    var openTabBehavior = OpenTabBehavior.lastViewed
    var grayscaleIcons = false
    /// With grayscale icons, still show the selected tab's icon in color.
    var colorSelectedIcon = true
    /// Keep the notch out of screen sharing and screenshots.
    var hideFromScreenCapture = true
    var motion = MotionSettings()
    var glassTint = 0.5
    var shelfTrigger = ShelfTrigger.automatic
    var shelfTileSize = ShelfTileSize.medium
    var shelfHoverDetails = true
    /// nil follows the macOS default browser; otherwise use the selected app bundle ID.
    var externalBrowserBundleID: String? = nil
    var toolbarActions = ToolbarAction.defaults
    var confirmBeforeQuit = true
    var shelfDownloads = false
    var shelfRemoveAfterDrag = true
    var notionHiddenAgentIDs: Set<String> = []
    var notionSavedAgents: [SavedNotionAgent] = []
    var notionAppearance = NotionAppearance.system
    /// nil uses each thread's URL when available, or the standard Notion site.
    var notionBaseURL: String? = nil
    var notionNotificationsEnabled = true
    var notionNotificationDuration = 10

    init() {}

    // Tolerate missing keys so adding settings later doesn't wipe saved ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SettingsData()
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? fallback.profiles
        pinnedTabs = try c.decodeIfPresent([PinnedTab].self, forKey: .pinnedTabs) ?? fallback.pinnedTabs
        notionTabPosition = min(pinnedTabs.count, max(0,
            (try? c.decode(Int.self, forKey: .notionTabPosition)) ?? pinnedTabs.count))
        notionEnabled = (try? c.decode(Bool.self, forKey: .notionEnabled)) ?? true
        notionTabDisplay = (try? c.decode(NotionTabDisplay.self, forKey: .notionTabDisplay)) ?? .iconAndTitle
        newTabProfileID = try c.decodeIfPresent(UUID.self, forKey: .newTabProfileID) ?? fallback.newTabProfileID
        displays = try c.decodeIfPresent([String: DisplaySettings].self, forKey: .displays) ?? fallback.displays
        countdownEnabled = try c.decodeIfPresent(Bool.self, forKey: .countdownEnabled) ?? fallback.countdownEnabled
        countdownMinutes = try c.decodeIfPresent(Int.self, forKey: .countdownMinutes) ?? fallback.countdownMinutes
        hideFromScreenCapture = try c.decodeIfPresent(Bool.self, forKey: .hideFromScreenCapture) ?? fallback.hideFromScreenCapture
        openTabBehavior = try c.decodeIfPresent(OpenTabBehavior.self, forKey: .openTabBehavior) ?? fallback.openTabBehavior
        grayscaleIcons = try c.decodeIfPresent(Bool.self, forKey: .grayscaleIcons) ?? fallback.grayscaleIcons
        colorSelectedIcon = try c.decodeIfPresent(Bool.self, forKey: .colorSelectedIcon) ?? fallback.colorSelectedIcon
        shelfTrigger = (try? c.decode(ShelfTrigger.self, forKey: .shelfTrigger)) ?? .automatic
        shelfTileSize = (try? c.decode(ShelfTileSize.self, forKey: .shelfTileSize)) ?? .medium
        shelfHoverDetails = (try? c.decode(Bool.self, forKey: .shelfHoverDetails)) ?? true
        externalBrowserBundleID = try? c.decodeIfPresent(String.self, forKey: .externalBrowserBundleID)
        shelfRemoveAfterDrag = (try? c.decode(Bool.self, forKey: .shelfRemoveAfterDrag)) ?? true
        shelfDownloads = (try? c.decode(Bool.self, forKey: .shelfDownloads)) ?? false
        notionHiddenAgentIDs = (try? c.decode(Set<String>.self, forKey: .notionHiddenAgentIDs)) ?? []
        notionSavedAgents = (try? c.decode([SavedNotionAgent].self, forKey: .notionSavedAgents)) ?? []
        notionAppearance = (try? c.decode(NotionAppearance.self, forKey: .notionAppearance)) ?? .system
        notionBaseURL = (try? c.decodeIfPresent(String.self, forKey: .notionBaseURL))
            .flatMap(NotionChatLink.normalizedBaseURL)
        notionNotificationsEnabled = (try? c.decode(Bool.self, forKey: .notionNotificationsEnabled)) ?? true
        notionNotificationDuration = min(60, max(5,
            (try? c.decode(Int.self, forKey: .notionNotificationDuration)) ?? 10))
        toolbarActions = (try? c.decode([String].self, forKey: .toolbarActions))
            .map { raw in
                var seen = Set<ToolbarAction>()
                return raw.compactMap(ToolbarAction.init(rawValue:)).filter { seen.insert($0).inserted }
            } ?? fallback.toolbarActions
        confirmBeforeQuit = (try? c.decode(Bool.self, forKey: .confirmBeforeQuit)) ?? true
        let tint = (try? c.decode(Double.self, forKey: .glassTint)) ?? fallback.glassTint
        glassTint = tint.isFinite ? min(1, max(0, tint)) : fallback.glassTint
        motion = (try? c.decode(MotionSettings.self, forKey: .motion)) ?? fallback.motion
        if !profiles.contains(where: \.isDefault) {
            profiles.insert(Profile(id: Profile.defaultID, name: "デフォルト"), at: 0)
        }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "settings.v1"

    @Published var data: SettingsData {
        didSet {
            if case .pinned(let id) = data.openTabBehavior, pinnedTab(id) == nil {
                data.openTabBehavior = .lastViewed
            }
            save()
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            data = decoded
        } else {
            data = Self.migrateLegacyApps() ?? SettingsData()
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }

    /// v0.1 stored saved tabs as `savedApps`.
    private static func migrateLegacyApps() -> SettingsData? {
        struct LegacyApp: Codable { var name: String; var url: String; var symbol: String }
        guard let raw = UserDefaults.standard.data(forKey: "savedApps"),
              let apps = try? JSONDecoder().decode([LegacyApp].self, from: raw) else { return nil }
        var data = SettingsData()
        data.pinnedTabs = apps.map { PinnedTab(name: $0.name, url: $0.url, icon: $0.symbol == "star" ? .favicon : .symbol($0.symbol)) }
        return data
    }

    func profile(_ id: UUID) -> Profile {
        data.profiles.first { $0.id == id } ?? data.profiles[0]
    }

    func pinnedTab(_ id: UUID) -> PinnedTab? {
        data.pinnedTabs.first { $0.id == id }
    }

    func updatePinnedTab(_ id: UUID, _ change: (inout PinnedTab) -> Void) {
        guard let index = data.pinnedTabs.firstIndex(where: { $0.id == id }) else { return }
        change(&data.pinnedTabs[index])
    }

    func displaySettings(for screen: NSScreen) -> DisplaySettings {
        if let saved = data.displays[screen.displayUUID] { return saved }
        // By default show on displays with a notch, or on the primary display if none has one.
        let screens = NSScreen.screens
        let enabled = screen.hasNotch || (!screens.contains(where: \.hasNotch) && screen == screens.first)
        return DisplaySettings(
            enabled: enabled,
            width: min(960, screen.frame.width - 80).rounded(),
            height: min(660, screen.frame.height * 0.75).rounded()
        )
    }

    func setDisplaySettings(_ settings: DisplaySettings, for screen: NSScreen) {
        data.displays[screen.displayUUID] = settings
    }

    /// The pinned tab last viewed, restored on launch. Kept out of `data` so selecting a
    /// tab doesn't trigger a settings sync.
    var lastViewedPinnedID: UUID? {
        get { UserDefaults.standard.string(forKey: "lastViewedPinnedID").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastViewedPinnedID") }
    }

    func deleteProfile(_ id: UUID) {
        guard id != Profile.defaultID else { return }
        for i in data.pinnedTabs.indices where data.pinnedTabs[i].profileID == id {
            data.pinnedTabs[i].profileID = Profile.defaultID
        }
        if data.newTabProfileID == id { data.newTabProfileID = Profile.defaultID }
        data.profiles.removeAll { $0.id == id }
        ScratchpadStore().remove(for: id)
        // Give open tabs a moment to move off the store before deleting it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ProfileDataStores.delete(id) }
    }
}

enum ProfileDataStores {
    private static var cache: [UUID: WKWebsiteDataStore] = [:]

    static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Profile.defaultID { return .default() }
        if let store = cache[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        cache[id] = store
        return store
    }

    static func clearData(for id: UUID) {
        store(for: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    static func delete(_ id: UUID) {
        cache[id] = nil
        WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Stable across reboots and reconnects, unlike `displayID`.
    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }
}
