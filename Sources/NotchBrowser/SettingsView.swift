import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchBrowser 設定"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(SettingsStore.shared))
        window.setContentSize(NSSize(width: 920, height: 620))
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
    }

    func present(section: SettingsSection? = nil, selectNotion: Bool = false, pinnedSelection: PinnedPageSelection = .none) {
        guard let window else { return }
        if let section {
            window.contentViewController = NSHostingController(rootView: SettingsView(initialSection: section,
                selectNotion: selectNotion, pinnedSelection: pinnedSelection).environmentObject(SettingsStore.shared))
        }
        if !window.isVisible { center(on: screenUnderMouse) }
        window.level = Self.frontLevel
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Above the notch while being used; a normal window otherwise, so it doesn't
    /// float over other apps (or over the notch once the notch is clicked).
    private static let frontLevel = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)

    func windowDidBecomeKey(_ notification: Notification) {
        window?.level = Self.frontLevel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard window?.attachedSheet == nil else { return }
        window?.level = .normal
    }

    func windowWillBeginSheet(_ notification: Notification) {
        window?.level = Self.frontLevel
    }

    private var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func center(on screen: NSScreen?) {
        guard let window, let visible = screen?.visibleFrame else { return window?.center() ?? () }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1))
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case tabs = "固定ページ", notion = "Notion", profiles = "プロファイル", displays = "ディスプレイ", motion = "動き", toolbar = "ボタン配置", general = "一般"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .tabs: "square.stack"
        case .notion: "bubble.left.and.bubble.right"
        case .profiles: "person.crop.circle"
        case .displays: "display"
        case .motion: "waveform.path"
        case .general: "slider.horizontal.3"
        case .toolbar: "rectangle.topthird.inset.filled"
        }
    }

}

struct SettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var section: SettingsSection
    private let pinnedSelection: PinnedPageSelection

    init(initialSection: SettingsSection = .tabs, selectNotion: Bool = false, pinnedSelection: PinnedPageSelection = .none) {
        _section = State(initialValue: initialSection)
        self.pinnedSelection = selectNotion ? .agents : pinnedSelection
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "safari").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NotchBrowser").font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                }.padding(.top, 8)
                VStack(spacing: 8) {
                    ForEach(SettingsSection.allCases) { item in
                        Button { section = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol).frame(width: 20)
                                Text(item.rawValue)
                                Spacer()
                                if item == section { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                            }
                            .font(.system(size: 13, weight: item == section ? .semibold : .regular))
                            .padding(12)
                            .contentShape(Rectangle())
                            .background(item == section ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 13))
                            .foregroundStyle(item == section ? .white : .secondary)
                        }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
                    }
                }
                Spacer()
                if let hint = store.data.shortcuts.openHint {
                    Label(hint, systemImage: "keyboard")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(20).frame(width: 210).background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch section {
                    case .tabs: PinnedTabsSettings(initialSelection: pinnedSelection, onOpenConnection: { section = .notion })
                    case .notion: NotionSettingsView(onOpenPinnedPages: { section = NotionSettingsView.pageSettingsDestination })
                    case .profiles: ProfilesSettings()
                    case .displays: DisplaysSettings()
                    case .motion: MotionSettingsView()
                    case .general: GeneralSettings()
                    case .toolbar: ToolbarSettingsView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 880, minHeight: 560).preferredColorScheme(.dark).tint(.blue)
    }
}

// MARK: - Pinned tabs

enum PinnedPageSelection: String, CaseIterable {
    case none, agents, tasks, meetings
    var id: UUID? {
        switch self {
        case .none: nil
        case .agents: PinnedTabsSettings.notionID
        case .tasks: PinnedTabsSettings.tasksID
        case .meetings: PinnedTabsSettings.meetingsID
        }
    }
}

#if DEBUG
struct SettingsPreviewLaunch {
    let section: SettingsSection
    let selection: PinnedPageSelection
    static func parse(arguments: [String]) -> SettingsPreviewLaunch? {
        if arguments.contains("--meetings=pinned-unconnected") { return .init(section: .tabs, selection: .meetings) }
        guard let pane = arguments.first(where: { $0.hasPrefix("--settings-pane=") }) else { return nil }
        let section: SettingsSection
        switch String(pane.dropFirst("--settings-pane=".count)) {
        case "pinned": section = .tabs
        case "notion": section = .notion
        default: return nil
        }
        let selection = arguments.first(where: { $0.hasPrefix("--pinned-selection=") })
            .flatMap { PinnedPageSelection(rawValue: String($0.dropFirst("--pinned-selection=".count))) } ?? .none
        return SettingsPreviewLaunch(section: section, selection: selection)
    }
}
#endif

struct PinnedTabsSettings: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var connection = NotionConnectionStore.shared
    @State private var selection: UUID?
    var onOpenConnection: () -> Void
    static let notionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let tasksID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let meetingsID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let emptySelectionMessage = "固定ページを選ぶと設定が表示されます"
    static let connectionRequiredMessage = "先に Notion に接続してください"
    struct Row: Identifiable {
        let id: UUID
        let tab: PinnedTab?
    }
    init(selectNotion: Bool = false, initialSelection: PinnedPageSelection = .none,
         onOpenConnection: @escaping () -> Void = {}) {
        _selection = State(initialValue: selectNotion ? Self.notionID : initialSelection.id)
        self.onOpenConnection = onOpenConnection
    }
    static func pageRows(pinnedTabs: [PinnedTab], notionPosition: Int) -> [Row] {
        var result = pinnedTabs.map { Row(id: $0.id, tab: $0) }
        result.insert(Row(id: notionID, tab: nil), at: max(0, min(notionPosition, result.count)))
        result.append(Row(id: tasksID, tab: nil))
        result.append(Row(id: meetingsID, tab: nil))
        return result
    }
    private var rows: [Row] { Self.pageRows(pinnedTabs: store.data.pinnedTabs, notionPosition: store.data.notionTabPosition) }
    enum EditorKind: Equatable { case pinned, notionAgents, notionTasks, notionMeetings, empty }
    static func editorKind(selection: UUID?, pinnedIDs: [UUID]) -> EditorKind {
        if let selection, pinnedIDs.contains(selection) { return .pinned }
        if selection == notionID { return .notionAgents }
        if selection == tasksID { return .notionTasks }
        if selection == meetingsID { return .notionMeetings }
        return .empty
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            if let tab = row.tab {
                                Image(nsImage: TabIconRenderer.image(for: tab.icon, hosts: [tab.host]))
                                Text(tab.name)
                            } else {
                                Image(systemName: row.id == Self.meetingsID ? "person.2" : row.id == Self.tasksID ? "checklist" : "bubble.left.and.bubble.right")
                                Text(row.id == Self.meetingsID ? "議事録" : row.id == Self.tasksID ? "タスク" : "エージェント")
                            }
                            Spacer()
                        }.tag(row.id)
                    }.onMove(perform: move)
                }
                .listStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("固定ページを追加")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil || selection == Self.notionID || selection == Self.tasksID || selection == Self.meetingsID)
                        .help("選択した固定ページを削除")
                    Spacer()
                }.buttonStyle(.borderless).padding(4)
            }
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            Divider()

            Group {
                if let id = selection, let binding = binding(for: id) {
                    PinnedTabEditor(tab: binding)
                } else if Self.editorKind(selection: selection, pinnedIDs: store.data.pinnedTabs.map(\.id)) == .notionAgents {
                    NotionAgentsSettings(onOpenSettings: onOpenConnection)
                } else if selection == Self.tasksID {
                    NotionTasksSettingsPage(onOpenSettings: onOpenConnection)
                } else if selection == Self.meetingsID {
                    NotionMeetingsSettingsPage(onOpenSettings: onOpenConnection)
                } else {
                    Text(Self.emptySelectionMessage).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for id: UUID) -> Binding<PinnedTab>? {
        guard store.data.pinnedTabs.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.pinnedTab(id) ?? PinnedTab(name: "", url: "") },
            set: { newValue in store.updatePinnedTab(id) { $0 = newValue } }
        )
    }

    private func add() {
        let tab = PinnedTab(name: "新しいタブ", url: "https://")
        store.data.pinnedTabs.append(tab)
        selection = tab.id
    }

    private func remove() {
        guard let id = selection, id != Self.notionID, id != Self.tasksID, id != Self.meetingsID else { return }
        if let index = store.data.pinnedTabs.firstIndex(where: { $0.id == id }),
           index < store.data.notionTabPosition {
            store.data.notionTabPosition -= 1
        }
        store.data.pinnedTabs.removeAll { $0.id == id }
        selection = store.data.pinnedTabs.first?.id
    }

    private func move(fromOffsets: IndexSet, toOffset: Int) {
        var reordered = rows
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        var data = store.data
        let orderedPages = reordered.filter { $0.id != Self.tasksID && $0.id != Self.meetingsID }
        data.notionTabPosition = orderedPages.firstIndex(where: { $0.id == Self.notionID }) ?? data.pinnedTabs.count
        data.pinnedTabs = reordered.compactMap(\.tab)
        store.data = data
    }
}

struct PinnedTabEditor: View {
    @EnvironmentObject var store: SettingsStore
    @Binding var tab: PinnedTab

    var body: some View {
        Form {
            TextField("名前", text: $tab.name)
            TextField("URL", text: $tab.url)
            Picker("プロファイル", selection: $tab.profileID) {
                ForEach(store.data.profiles) { Text($0.name).tag($0.id) }
            }
            Toggle("タブにアイコンのみ表示", isOn: $tab.iconOnly)

            Section("アイコン") {
                LabeledContent("現在のアイコン") {
                    Image(nsImage: TabIconRenderer.image(for: tab.icon, hosts: [tab.host], size: 24))
                }
                SymbolGrid(selected: TabIconRenderer.symbolName(for: tab.icon, hosts: [tab.host])) {
                    tab.icon = .symbol($0)
                }
                Button("URLに合わせて自動選択") { tab.icon = .favicon }
                Text("ページの用途に合うアイコンを選べます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SymbolGrid: View {
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 6) {
            ForEach(TabIconRenderer.presetSymbols, id: \.self) { name in
                Button { onSelect(name) } label: {
                    Image(systemName: name)
                        .frame(width: 28, height: 28)
                        .background(name == selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(name).accessibilityLabel(name)
            }
        }
    }
}

// MARK: - Profiles

struct ProfilesSettings: View {
    @EnvironmentObject var store: SettingsStore
    @State private var confirmDelete: Profile?
    @State private var confirmClear: Profile?

    var body: some View {
        Form {
            Section {
                ForEach($store.data.profiles) { $profile in
                    HStack {
                        Image(systemName: profile.isDefault ? "person.crop.circle.fill" : "person.crop.circle")
                        TextField("名前", text: $profile.name).labelsHidden()
                        Text("\(usage(of: profile.id)) タブ").foregroundStyle(.secondary).font(.caption)
                        Menu {
                            Button("ログイン情報を消去…") { confirmClear = profile }
                            if !profile.isDefault {
                                Button("削除…", role: .destructive) { confirmDelete = profile }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                }
                Button("プロファイルを追加") {
                    store.data.profiles.append(Profile(id: UUID(), name: "プロファイル \(store.data.profiles.count + 1)"))
                }
            } header: {
                Text("プロファイル")
            } footer: {
                Text("Cookie とログイン状態はプロファイルごとに分かれます。同じプロファイルのタブ同士はログインを共有します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("新規タブのプロファイル", selection: $store.data.newTabProfileID) {
                    ForEach(store.data.profiles) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("リンクから開いたタブは、元のタブのプロファイルを引き継ぎます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("「\(confirmDelete?.name ?? "")」を削除しますか？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("削除", role: .destructive) { if let p = confirmDelete { store.deleteProfile(p.id) } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このプロファイルのログイン情報とクイックメモも削除されます。使っていた固定タブはデフォルトに戻ります。")
        }
        .alert("「\(confirmClear?.name ?? "")」のログイン情報を消去しますか？", isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("消去", role: .destructive) { if let p = confirmClear { ProfileDataStores.clearData(for: p.id) } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func usage(of id: UUID) -> Int {
        store.data.pinnedTabs.filter { $0.profileID == id }.count
    }
}

// MARK: - Displays

// MARK: - General

struct GeneralSettings: View {
    @StateObject private var shortcutRecorder = ShortcutRecorder()
    @EnvironmentObject var store: SettingsStore

    private var browsers: [ExternalBrowser] { ExternalBrowserLauncher.installed() }

    var body: some View {
        Form {
            Section("使い方") {
                Button("使い方ガイドをもう一度見る") {
                    NotificationCenter.default.post(name: .showNotchBrowserOnboarding, object: nil)
                }
                Text("基本操作とよく使う機能をいつでも見直せます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PrecisionSlider(title: "ガラスの濃度", value: Binding(get: { store.data.glassTint * 100 }, set: { store.data.glassTint = $0 / 100 }), range: 0...100, step: 1, unit: "%")
                Text("透明感と読みやすさのバランスを調整します。macOSの「透明度を下げる」「コントラストを上げる」が有効なときは、不透明な背景で表示します。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Liquid Glass", systemImage: "circle.hexagongrid") }

            Section {
                Picker("ノッチを開いたときのタブ", selection: $store.data.openTabBehavior) {
                    Text("前回見ていたタブ").tag(OpenTabBehavior.lastViewed)
                    if !store.data.pinnedTabs.isEmpty {
                        Divider()
                        ForEach(store.data.pinnedTabs) { tab in
                            Text(tab.name).tag(OpenTabBehavior.pinned(tab.id))
                        }
                    }
                }

            } header: {
                Text("タブ")
            } footer: {
                Text("タブはノッチ上でドラッグして並べ替えられます（固定タブと通常タブはそれぞれのグループ内で移動します）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("外部ブラウザ") {
                Picker("ブラウザで開く先", selection: $store.data.externalBrowserBundleID) {
                    Text("システムのデフォルト").tag(nil as String?)
                    ForEach(browsers) { browser in
                        Text(browser.name).tag(Optional(browser.id))
                    }
                    if let selected = store.data.externalBrowserBundleID,
                       !browsers.contains(where: { $0.id == selected }) {
                        Text("見つからないブラウザ（\(selected)）").tag(Optional(selected))
                    }
                }
                Text("リンクやタブの右クリックメニューと、ボタン配置の「ブラウザで開く」に適用します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("次の予定") {
                Toggle("次の予定を表示", isOn: $store.data.countdownEnabled)
                Toggle("予定名をスクロール表示", isOn: $store.data.calendarMarqueeEnabled)
                    .disabled(!store.data.countdownEnabled)
                    .opacity(store.data.countdownEnabled ? 1 : 0.5)
                Stepper(value: $store.data.countdownMinutes, in: 5...120, step: 5) {
                    LabeledContent("表示し始めるタイミング", value: "\(store.data.countdownMinutes) 分前から")
                }
                .disabled(!store.data.countdownEnabled)
                .opacity(store.data.countdownEnabled ? 1 : 0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("長い予定を表示しない")
                        Text("終日の予定はいつも表示しません")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Form の Picker 専用配置を避け、Stepper と同じ行末へ
                    // 値側のポップアップを自然幅で右寄せする。
                    Picker("長い予定を表示しない", selection: $store.data.calendarLongEventLimit) {
                        ForEach(CalendarLongEventLimit.allCases, id: \.self) { limit in
                            Text(limit.label).tag(limit)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                // ラベルを含む行全体に適用し、オフ時は dim と操作不可を揃える。
                .disabled(!store.data.countdownEnabled)
                .opacity(store.data.countdownEnabled ? 1 : 0.5)
                Text("Mac の「カレンダー」アプリの予定を使うため、オンのときだけカレンダーへのアクセスを求めます。タブで開くカレンダーのサイトとは別です。Google カレンダーは システム設定 › インターネットアカウント で追加できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("画面共有・スクリーンショットに表示しない", isOn: $store.data.hideFromScreenCapture)
            } header: {
                Text("プライバシー")
            } footer: {
                Text("Zoom や Google Meet などで画面を共有しているとき、ノッチのブラウザは相手に映りません。一部の録画・共有アプリでは効かない場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("終了前に確認する", isOn: $store.data.confirmBeforeQuit)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NotchBrowser を終了")
                        Text("メニューバーのアイコン、ノッチの右クリック、ブラウザ右上の操作メニューからも終了できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("終了") { NSApp.terminate(nil) }
                }
            }

            UpdateSettingsView()

            Section {
                ShortcutSettingsView(recorder: shortcutRecorder)
                LabeledContent("設定", value: "⌘,")
            } header: {
                Text("ショートカット")
            } footer: {
                HStack {
                    Spacer()
                    Button("すべて既定に戻す") { shortcutRecorder.resetAll() }
                }
                .padding(.top, -2)
                .padding(.bottom, 20)
            }
        }
        .formStyle(.grouped)
        .onDisappear { shortcutRecorder.cancel() }
    }
}

struct ToolbarSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    private var placed: [ToolbarAction] { store.data.toolbarActions.filter { $0 != .notion && $0.isAvailable } }
    private var available: [ToolbarAction] { ToolbarAction.allCases.filter { $0 != .notion && $0.isAvailable && !placed.contains($0) } }
    private var previewActions: [ToolbarAction] { Array(placed.filter { $0 != .spacer }.prefix(10)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ボタン配置").font(.title2.weight(.semibold))
                    Text("並びをドラッグして変更できます。追加・削除すると上のプレビューにも反映されます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("ノッチでの見え方").font(.headline)
                    GeometryReader { geometry in
                        preview
                            .frame(width: 960, height: 108)
                            .scaleEffect(geometry.size.width / 960, anchor: .topLeading)
                    }
                    .frame(height: 76)
                    Text("右側の操作エリアを実寸比で表示。幅を超えたボタンは「•••」メニューに入ります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("ノッチに表示").font(.headline)
                        Spacer()
                        Text("上から左→右の順").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 5) {
                        ForEach(placed) { action in
                            placementRow(action)
                                .onDrag { NSItemProvider(object: action.rawValue as NSString) }
                                .onDrop(of: [UTType.text.identifier], isTargeted: nil) { drop($0, before: action) }
                        }
                        if placed.isEmpty {
                            Text("下のボタンをここへドラッグするか、追加してください。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        Color.clear.frame(height: 14)
                            .contentShape(Rectangle())
                            .onDrop(of: [UTType.text.identifier], isTargeted: nil) { drop($0, before: nil) }
                    }
                    .padding(8)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                    Text("可変スペーサーを先頭に置くと右寄せ、末尾に置くと左寄せ、途中に置くと左右に分けられます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("追加できるボタン").font(.headline)
                    if available.isEmpty {
                        Text("すべて配置済みです。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(available) { action in
                                Button { insert(action, before: nil) } label: {
                                    Label(action.title, systemImage: action.symbolName)
                                        .font(.system(size: 12))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .onDrag { NSItemProvider(object: action.rawValue as NSString) }
                                .help("クリックで末尾に追加、または上へドラッグ")
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("標準の配置に戻す") { store.data.toolbarActions = ToolbarAction.defaults }
                }
            }
            .padding(26)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var preview: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "envelope").frame(width: 64)
                Image(systemName: "calendar").frame(width: 64)
                Image(systemName: "plus").frame(width: 28)
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 366, height: 38)
            .padding(.leading, 14)
            Color.black.frame(width: 200, height: 52)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            HStack(spacing: 4) {
                ForEach(placed.filter { $0 == .spacer || previewActions.contains($0) }) { action in
                    if action == .spacer {
                        Spacer(minLength: 0)
                    } else {
                        Image(systemName: action.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            .help(action.title)
                    }
                }
                if !placed.contains(.spacer) { Spacer(minLength: 0) }
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            .foregroundStyle(.white)
            .frame(width: 358, height: 38)
            .padding(.leading, 10)
            .padding(.trailing, 12)
        }
        .frame(width: 960, height: 108)
        .background(Color(red: 0.08, green: 0.10, blue: 0.16), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.18)))
    }

    private func placementRow(_ action: ToolbarAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: action.symbolName)
                .frame(width: 26)
                .foregroundStyle(action == .spacer ? .blue : .primary)
            Text(action.title).font(.system(size: 13, weight: .medium))
            if action == .spacer { Text("余白を広げる").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                store.data.toolbarActions.removeAll { $0 == action }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action.title)を外す")
        }
        .padding(.horizontal, 12)
        .frame(height: 39)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func insert(_ action: ToolbarAction, before target: ToolbarAction?) {
        var actions = placed
        actions.removeAll { $0 == action }
        let index = target.flatMap { actions.firstIndex(of: $0) } ?? actions.endIndex
        actions.insert(action, at: index)
        store.data.toolbarActions = actions
    }

    private func drop(_ providers: [NSItemProvider], before target: ToolbarAction?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let action = ToolbarAction(rawValue: raw) else { return }
            DispatchQueue.main.async { insert(action, before: target) }
        }
        return true
    }
}
