import SwiftUI

struct QuickSwitchView: View {
    @ObservedObject var store: QuickSwitchStore
    @ObservedObject var system: SystemSwitchStore
    var onBack: () -> Void
    @AppStorage("quickSwitch.cardOrder") private var cardOrder = ""
    @AppStorage("quickSwitch.shortcut") private var shortcut = ""
    @AppStorage("quickSwitch.pinnedShortcuts") private var pinnedShortcutsJSON = "[]"
    @AppStorage("quickSwitch.hiddenCards") private var hiddenCards = ""
    @State private var customizing = false
    @AppStorage("quickSwitch.awakeDuration") private var duration = 30
    @AppStorage("quickSwitch.displayAwake") private var displayAwake = false
    private let columns = [GridItem(.adaptive(minimum: 172), spacing: 10)]
    private let cards: [(String, String)] = [("awake", "スリープ抑止"), ("dark", "ダークモード"), ("desktop", "デスクトップ"), ("dock", "Dock"), ("hidden", "隠しファイル"), ("wifi", "Wi-Fi"), ("mute", "ミュート"), ("microphone", "マイク"), ("saver", "スクリーンセーバー"), ("sleep", "画面を消灯")]
    private var orderedCards: [(String, String)] {
        let saved = cardOrder.split(separator: ",").map(String.init)
        let ids = saved.filter { id in cards.contains { $0.0 == id } } + cards.map(\.0).filter { !saved.contains($0) }
        return ids.compactMap { id in cards.first { $0.0 == id } }
    }
    private func move(_ id: String, by offset: Int) {
        var ids = orderedCards.map(\.0)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset); cardOrder = ids.joined(separator: ",")
    }
    private var pinnedShortcuts: [String] { (try? JSONDecoder().decode([String].self, from: Data(pinnedShortcutsJSON.utf8))) ?? [] }
    private func pinShortcut(_ name: String, _ value: Bool) {
        var names = pinnedShortcuts.filter { $0 != name }
        if value { names.append(name) }
        if let data = try? JSONEncoder().encode(names), let json = String(data: data, encoding: .utf8) { pinnedShortcutsJSON = json }
    }
    private func visible(_ id: String) -> Bool { !hiddenCards.split(separator: ",").contains(Substring(id)) }
    private func setVisible(_ id: String, _ value: Bool) {
        var hidden = Set(hiddenCards.split(separator: ",").map(String.init))
        if value { hidden.remove(id) } else { hidden.insert(id) }
        hiddenCards = hidden.sorted().joined(separator: ",")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("ブラウザ", systemImage: "chevron.left") }.accessibilityLabel("ブラウザに戻る")
                Spacer()
                Button { customizing.toggle() } label: { Label(customizing ? "完了" : "編集", systemImage: customizing ? "checkmark" : "slider.horizontal.3") }.accessibilityLabel(customizing ? "編集を完了" : "カードを編集")
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if customizing {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(orderedCards, id: \.0) { id, name in
                                VStack(alignment: .leading, spacing: 10) {
                                Toggle(name, isOn: Binding(get: { visible(id) }, set: { setVisible(id, $0) }))
                                HStack {
                                    Button { move(id, by: -1) } label: { Image(systemName: "arrow.left") }.disabled(orderedCards.first?.0 == id).help("前へ移動")
                                    Button { move(id, by: 1) } label: { Image(systemName: "arrow.right") }.disabled(orderedCards.last?.0 == id).help("後ろへ移動")
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        Text("ショートカットをカードに追加").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(Set(store.shortcuts + pinnedShortcuts)).sorted(), id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { pinnedShortcuts.contains(name) }, set: { pinShortcut(name, $0) }))
                        }
                        if store.shortcuts.isEmpty { Text("ショートカットアプリで作成した操作を追加できます。").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(orderedCards, id: \.0) { id, _ in
                                if visible(id) { switchCard(id) }
                            }
                            ForEach(pinnedShortcuts, id: \.self) { name in
                                tile(name, "square.stack.3d.up.fill", store.shortcuts.contains(name) ? "実行" : "見つかりません", false, enabled: !store.running && store.shortcuts.contains(name), actionIcon: "play.fill") { store.runShortcut(name) }
                            }
                        }
                        if visible("awake") {
                            HStack(spacing: 12) {
                                Label("抑止時間", systemImage: "timer").foregroundStyle(.secondary)
                                Picker("抑止時間", selection: $duration) {
                                    ForEach([15, 25, 30, 60, 120], id: \.self) { Text("\($0)分").tag($0) }
                                    Text("無期限").tag(-1)
                                }.labelsHidden().frame(width: 100)
                                Toggle("画面も点灯", isOn: $displayAwake).toggleStyle(.checkbox)
                                Spacer(minLength: 0)
                            }.font(.caption)
                                .onChange(of: duration) { _, value in if store.isAwake { store.keepAwake(minutes: value, display: displayAwake) } }
                                .onChange(of: displayAwake) { _, value in if store.isAwake { store.keepAwake(minutes: duration, display: value) } }
                            Text("蓋を閉じた時や手動スリープは対象外です。").font(.caption2).foregroundStyle(.secondary)
                        }
                        audioCard
                        shortcutCard
                        HStack(spacing: 16) {
                            settingsLink("Bluetooth", "wave.3.right", "com.apple.BluetoothSettings")
                            settingsLink("集中モード", "moon", "com.apple.Focus-Settings.extension")
                            settingsLink("ディスプレイ", "display", "com.apple.Displays-Settings.extension")
                            settingsLink("省電力", "battery.50percent", "com.apple.Battery-Settings.extension")
                            Spacer(minLength: 0)
                        }.font(.caption)
                    }
                    if let message = system.message ?? store.message {
                        Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
        .background(Color(nsColor: .init(white: 0.065, alpha: 1)))
        .onAppear { store.startObserving(); system.start(); store.loadShortcuts() }
        .onDisappear { store.stopObserving(); system.stop() }
    }
    @ViewBuilder private func switchCard(_ id: String) -> some View {
        if id == "awake" { tile("スリープ抑止", "cup.and.saucer.fill", awakeDetail, store.isAwake) { store.keepAwake(minutes: store.isAwake ? 0 : duration, display: displayAwake) } }
        if id == "dark" { tile("ダークモード", "moon.fill", system.dark ? "オン" : "オフ", system.dark, enabled: !system.busy) { system.setDark(!system.dark) } }
        if id == "desktop" { tile("デスクトップ", "rectangle.grid.2x2", system.desktopHidden ? "アイコンを非表示" : "アイコンを表示", system.desktopHidden, enabled: !system.busy) { system.setFinderPreference("CreateDesktop", value: system.desktopHidden) }.help("Finderを再起動してアイコンの表示を切り替えます") }
        if id == "dock" { tile("Dockを自動で隠す", "dock.rectangle", system.dockHidden ? "オン" : "オフ", system.dockHidden, enabled: !system.busy) { system.setDockHidden(!system.dockHidden) } }
        if id == "hidden" { tile("隠しファイル", "eye", system.hiddenFiles ? "表示中" : "非表示", system.hiddenFiles, enabled: !system.busy) { system.setFinderPreference("AppleShowAllFiles", value: !system.hiddenFiles) }.help("Finderを再起動して隠しファイルの表示を切り替えます") }
        if id == "wifi" { tile("Wi-Fi", "wifi", system.wifi == nil ? "利用できません" : (system.wifi == true ? "オン" : "オフ"), system.wifi == true, enabled: system.wifi != nil && !system.busy) { system.setWiFi(system.wifi != true) } }
        if id == "mute" { tile("スピーカーをミュート", "speaker.slash.fill", store.muteAvailable ? (store.muted ? "オン" : "オフ") : "機器が非対応", store.muted, enabled: store.muteAvailable) { store.setMuted(!store.muted) } }
        if id == "microphone" { tile("マイクをミュート", "mic.slash.fill", system.microphoneAvailable ? (system.microphoneMuted ? "オン" : "オフ") : "機器が非対応", system.microphoneMuted, enabled: system.microphoneAvailable) { system.setMicrophoneMuted(!system.microphoneMuted) } }
        if id == "saver" { tile("スクリーンセーバー", "sparkles.tv", "開始", false, actionIcon: "play.fill") { system.startScreenSaver() } }
        if id == "sleep" { tile("画面を消灯", "display", "クリックで消灯", false, actionIcon: "power") { store.keepAwake(minutes: 0); system.sleepDisplay() } }
    }
    private var awakeDetail: String {
        guard let until = store.awakeUntil else { return "オフ" }
        if until == .distantFuture { return "無期限・" + (store.keepsDisplayAwake ? "画面も点灯" : "画面消灯可") }
        return until.formatted(date: .omitted, time: .shortened) + "まで"
    }
    private func tile(_ title: String, _ icon: String, _ detail: String, _ active: Bool, enabled: Bool = true, actionIcon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 21, weight: .medium)).frame(height: 24)
                    Spacer()
                    Image(systemName: actionIcon ?? (active ? "checkmark.circle.fill" : "circle"))
                        .font(.system(size: 14)).opacity(active ? 1 : 0.4)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(active ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(active ? .white : .primary)
                .background(active ? Color.accentColor.opacity(0.75) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(active ? 0.18 : 0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(Text(title)).accessibilityValue(Text(detail))
    }
    private var audioCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("音声出力", systemImage: "hifispeaker").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("出力先", selection: Binding(get: { system.outputID }, set: { system.selectOutput($0); store.refreshAudio() })) {
                    if !system.outputs.contains(where: { $0.id == system.outputID }) { Text("未接続").tag(system.outputID) }
                    ForEach(system.outputs) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 270)
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { store.volume }, set: store.setVolume), in: 0...1).accessibilityLabel("音量")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("\(Int(store.volume * 100))%").monospacedDigit().font(.caption).frame(width: 36)
            }.disabled(!store.volumeAvailable)
        }.padding(14).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
    }
    private var shortcutCard: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill").font(.title3)
            Picker("ショートカット", selection: $shortcut) {
                Text("選択してください").tag("")
                ForEach(store.shortcuts, id: \.self) { Text($0).tag($0) }
            }
            Button { store.loadShortcuts() } label: { Image(systemName: "arrow.clockwise") }.help("一覧を更新")
            Button { store.runShortcut(shortcut) } label: { Image(systemName: "play.fill") }.help("実行")
                .disabled(store.running || !store.shortcuts.contains(shortcut))
            if store.running { ProgressView().controlSize(.small) }
        }.padding(14).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
    }
    private func settingsLink(_ title: String, _ icon: String, _ pane: String) -> some View {
        Button { system.openSettings(pane) } label: { Label(title, systemImage: icon) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("システム設定を開く").accessibilityLabel(title + "の設定を開く")
    }
}
