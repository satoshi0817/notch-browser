import AppKit
import SwiftUI

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

    func present() {
        guard let window else { return }
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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case tabs = "固定ページ", profiles = "プロファイル", displays = "ディスプレイ", motion = "動き", general = "一般"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .tabs: "square.stack"
        case .profiles: "person.crop.circle"
        case .displays: "display"
        case .motion: "waveform.path"
        case .general: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .tabs: "いつものページを、自分の並びで。"
        case .profiles: "仕事とプライベートのログインを分ける。"
        case .displays: "画面ごとに、ちょうどいいサイズへ。"
        case .motion: "開く、閉じる。その感触まで自分好みに。"
        case .general: "見た目と、日々の使い方を整える。"
        }
    }
}

struct SettingsView: View {
    @State private var section = SettingsSection.tabs
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "safari").font(.system(size: 25, weight: .light)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NotchBrowser").font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("あなたの小さなワークスペース").font(.system(size: 9)).foregroundStyle(.secondary)
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
                            .background(item == section ? Color.blue.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 13))
                            .foregroundStyle(item == section ? .white : .secondary)
                        }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
                    }
                }
                Spacer()
                Label("⌃ ⌥ N で開く", systemImage: "keyboard").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20).frame(width: 210).background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol).font(.system(size: 22)).foregroundStyle(.cyan)
                        .frame(width: 48, height: 48).modifier(GlassCard())
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.rawValue).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
                Group {
                    switch section {
                    case .tabs: PinnedTabsSettings()
                    case .profiles: ProfilesSettings()
                    case .displays: DisplaysSettings()
                    case .motion: MotionSettingsView()
                    case .general: GeneralSettings()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.19), Color(red: 0.055, green: 0.065, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.frame(minWidth: 880, minHeight: 560).preferredColorScheme(.dark).tint(.blue)
    }
}

// MARK: - Pinned tabs

struct PinnedTabsSettings: View {
    @EnvironmentObject var store: SettingsStore
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.data.pinnedTabs) { tab in
                        HStack(spacing: 8) {
                            Image(nsImage: TabIconRenderer.image(for: tab.icon, hosts: [tab.host]))
                            Text(tab.name)
                            Spacer()
                            if tab.iconOnly {
                                Image(systemName: "eye.slash").foregroundStyle(.secondary).help("アイコンのみ")
                            }
                        }
                        .tag(tab.id)
                    }
                    .onMove { store.data.pinnedTabs.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }.help("固定ページを追加")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                        .help("選択した固定ページを削除")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            Group {
                if let id = selection, let binding = binding(for: id) {
                    PinnedTabEditor(tab: binding)
                } else {
                    Label("タブを選択するか、追加してください", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)
        }
        .onAppear { selection = selection ?? store.data.pinnedTabs.first?.id }
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
        guard let id = selection else { return }
        store.data.pinnedTabs.removeAll { $0.id == id }
        selection = store.data.pinnedTabs.first?.id
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
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
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

            Section("次の予定") {
                Toggle("次の予定までの分数をノッチに表示", isOn: $store.data.countdownEnabled)
                Stepper(value: $store.data.countdownMinutes, in: 5...120, step: 5) {
                    LabeledContent("表示し始めるタイミング", value: "\(store.data.countdownMinutes) 分前から")
                }
                .disabled(!store.data.countdownEnabled)
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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NotchBrowser を終了")
                        Text("メニューバーのアイコン、ノッチの右クリック、ブラウザ右上の電源ボタンからも終了できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("終了") { NSApp.terminate(nil) }
                }
            }

            Section("ショートカット") {
                LabeledContent("開く / 閉じる", value: "⌃⌥N")
                LabeledContent("設定", value: "⌘,")
            }
        }
        .formStyle(.grouped)
    }
}
