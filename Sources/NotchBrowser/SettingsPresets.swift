import AppKit
import SwiftUI

enum MotionPreset: String, CaseIterable, Identifiable {
    case standard, quick, gentle, instant
    var id: Self { self }
    var title: String { switch self { case .standard: "標準"; case .quick: "きびきび"; case .gentle: "ゆったり"; case .instant: "すぐに表示" } }
    var subtitle: String { switch self { case .standard: "素早く開き、静かに収まる"; case .quick: "短い待ち時間で軽快に"; case .gentle: "余裕のある、穏やかな開閉"; case .instant: "待ち時間・アニメーションなし" } }
    var symbol: String { switch self { case .standard: "waveform.path"; case .quick: "bolt"; case .gentle: "wind"; case .instant: "rectangle" } }
    var settings: MotionSettings {
        var value = MotionSettings()
        switch self {
        case .standard: break
        case .quick: value.openDelay = 0.05; value.closeDelay = 0.2; value.openDuration = 0.16; value.closeDuration = 0.16
        case .gentle: value.openDelay = 0.3; value.closeDelay = 0.7; value.openDuration = 0.5; value.closeDuration = 0.4; value.style = .easeInOut
        case .instant: value.openDelay = 0; value.closeDelay = 0; value.style = .none
        }
        return value
    }
}

enum DisplayPreset: String, CaseIterable, Identifiable {
    case compact, standard, spacious
    var id: Self { self }
    var title: String { switch self { case .compact: "コンパクト"; case .standard: "標準"; case .spacious: "ゆったり" } }
    var symbol: String { switch self { case .compact: "rectangle.compress.vertical"; case .standard: "rectangle"; case .spacious: "rectangle.expand.vertical" } }
    func settings(for screen: NSScreen, enabled: Bool) -> DisplaySettings {
        let size: (Double, Double) = switch self { case .compact: (720, 480); case .standard: (960, 660); case .spacious: (1200, 800) }
        return DisplaySettings(enabled: enabled, idleOpacity: 1, width: min(size.0, max(600, screen.frame.width - 40)), height: min(size.1, max(400, screen.frame.height - 40)))
    }
}

struct PresetCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(selected ? .cyan : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.blue : Color.secondary.opacity(0.4))
                }
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(minHeight: 30, alignment: .top)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.16) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.blue : Color.white.opacity(0.10), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel(title + (selected ? "、選択中" : ""))
    }
}

/// Full-width track, keyboard-editable value, and fixed-step buttons share one clamped binding.
struct PrecisionSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var digits: Int = 0
    private var bounded: Binding<Double> {
        Binding(get: { value }, set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, value: bounded, format: .number.precision(.fractionLength(digits)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 76).accessibilityLabel(title + "の数値")
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { bounded.wrappedValue -= step } label: { Image(systemName: "minus").frame(width: 16, height: 18) }
                    .disabled(value <= range.lowerBound).accessibilityLabel(title + "を減らす")
                Slider(value: Binding(get: { value }, set: { bounded.wrappedValue = ($0 / step).rounded() * step }), in: range).accessibilityLabel(title)
                Button { bounded.wrappedValue += step } label: { Image(systemName: "plus").frame(width: 16, height: 18) }
                    .disabled(value >= range.upperBound).accessibilityLabel(title + "を増やす")
            }
            HStack {
                Text(range.lowerBound, format: .number.precision(.fractionLength(digits)))
                Spacer()
                Text(range.upperBound, format: .number.precision(.fractionLength(digits)))
            }.font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 40)
        }.padding(.vertical, 5)
    }
}

struct MotionSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var editing = false
    @State private var draft = MotionSettings()
    private var preset: MotionPreset? { MotionPreset.allCases.first { $0.settings == store.data.motion } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(MotionPreset.allCases) { item in
                        PresetCard(title: item.title, subtitle: item.subtitle, symbol: item.symbol, selected: preset == item) { store.data.motion = item.settings }
                    }
                    PresetCard(title: "カスタム", subtitle: "待ち時間と速さを自分で調整", symbol: "slider.horizontal.3", selected: preset == nil) {
                        draft = store.data.motion; editing = true
                    }
                }
                MotionPreview(settings: store.data.motion)
                Text("カードを選ぶと次の開閉から反映されます。「視差効果を減らす」が有効な場合、動きを省略します。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("動きをカスタマイズ").font(.title2.bold())
                ScrollView {
                    VStack(spacing: 18) {
                        MotionPreview(settings: draft)
                        PrecisionSlider(title: "開くまでの待ち時間", value: $draft.openDelay, range: MotionSettings.delayRange, step: 0.01, unit: "秒", digits: 2)
                        PrecisionSlider(title: "閉じるまでの待ち時間", value: $draft.closeDelay, range: MotionSettings.delayRange, step: 0.01, unit: "秒", digits: 2)
                        Picker("アニメーション", selection: $draft.style) { ForEach(NotchAnimationStyle.allCases) { Text($0.title).tag($0) } }
                        PrecisionSlider(title: "開くアニメーション", value: $draft.openDuration, range: MotionSettings.durationRange, step: 0.01, unit: "秒", digits: 2).disabled(draft.style == .none)
                        PrecisionSlider(title: "閉じるアニメーション", value: $draft.closeDuration, range: MotionSettings.durationRange, step: 0.01, unit: "秒", digits: 2).disabled(draft.style == .none)
                    }
                }
                HStack { Button("キャンセル") { editing = false }.keyboardShortcut(.cancelAction); Spacer(); Button("保存") { store.data.motion = draft; editing = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 460, height: 570)
        }
    }
}

struct DisplaysSettings: View {
    @State private var screens = NSScreen.screens
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { ForEach(screens, id: \.displayUUID) { DisplayRow(screen: $0) } }.padding(24)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens }
    }
}

struct DisplayRow: View {
    @EnvironmentObject var store: SettingsStore
    let screen: NSScreen
    @State private var editing = false
    @State private var draft = DisplaySettings(enabled: true)
    private var displayName: String {
        let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ディスプレイ \((NSScreen.screens.firstIndex(of: screen) ?? 0) + 1)" : name
    }
    private var current: DisplaySettings { store.displaySettings(for: screen) }
    private var preset: DisplayPreset? { DisplayPreset.allCases.first { $0.settings(for: screen, enabled: current.enabled) == current } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(displayName, systemImage: screen.hasNotch ? "laptopcomputer" : "display").font(.headline)
                Spacer()
                Toggle("表示", isOn: Binding(get: { current.enabled }, set: { var next = current; next.enabled = $0; store.setDisplaySettings(next, for: screen) }))
                    .toggleStyle(.switch).accessibilityLabel(displayName + "に表示")
            }
            if current.enabled {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(DisplayPreset.allCases) { item in
                        let size = item.settings(for: screen, enabled: true)
                        PresetCard(title: item.title, subtitle: "\(Int(size.width)) × \(Int(size.height))", symbol: item.symbol, selected: preset == item) { store.setDisplaySettings(size, for: screen) }
                    }
                    PresetCard(title: "カスタム", subtitle: "サイズ・待機中の透明度を調整", symbol: "slider.horizontal.3", selected: preset == nil) { draft = current; editing = true }
                }
                Text("\(Int(current.width)) × \(Int(current.height)) · 待機時の不透明度 \(Int(current.idleOpacity * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 20) {
                Text("表示をカスタマイズ").font(.title2.bold())
                Text(displayName).foregroundStyle(.secondary)
                PrecisionSlider(title: "幅", value: $draft.width, range: 600...max(600, screen.frame.width - 40), step: 10, unit: "pt")
                PrecisionSlider(title: "高さ", value: $draft.height, range: 400...max(400, screen.frame.height - 40), step: 10, unit: "pt")
                PrecisionSlider(title: "待機時の不透明度", value: Binding(get: { draft.idleOpacity * 100 }, set: { draft.idleOpacity = $0 / 100 }), range: 0...100, step: 1, unit: "%")
                Text("0%でも、画面上端の中央にカーソルを乗せると開けます。") .font(.caption).foregroundStyle(.secondary)
                HStack { Button("キャンセル") { editing = false }.keyboardShortcut(.cancelAction); Spacer(); Button("保存") {
                    draft.enabled = current.enabled
                    draft.width = min(max(600, draft.width), max(600, screen.frame.width - 40))
                    draft.height = min(max(400, draft.height), max(400, screen.frame.height - 40))
                    store.setDisplaySettings(draft, for: screen); editing = false
                }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 460)
        }
    }
}
