import AppKit
import SwiftUI

/// Keep an unfinished first-run tour visible on the next launch even after it saves defaults.
enum OnboardingState {
    private static let startedKey = "onboarding.started.v1"
    private static let completedKey = "onboarding.completed.v1"

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: completedKey) { return false }
        if defaults.bool(forKey: startedKey) { return true }
        let previousUseKeys = ["settings.v1", "savedApps", "lastViewedPinnedID", "updates.nextCheck", "updates.lastSuccess"]
        return previousUseKeys.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    static func begin(defaults: UserDefaults = .standard) { defaults.set(true, forKey: startedKey) }

    static func complete(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
        defaults.removeObject(forKey: startedKey)
    }
}

struct OnboardingChoices {
    var pinnedTabs: [PinnedTab]
    var enabledDisplayIDs: Set<String>
    var displayPreset: DisplayPreset?
    var displayPresetChanged = false
    var motion: MotionSettings
    var automaticShelf: Bool
    var calendarCountdown: Bool
    var notionButton: Bool
    var hideFromCapture: Bool
    var externalBrowserBundleID: String?

    init(settings: SettingsData, screens: [NSScreen] = NSScreen.screens) {
        pinnedTabs = settings.pinnedTabs
        let enabledIDs = Set(screens.filter { Self.currentDisplay($0, in: settings, screens: screens).enabled }.map(\.displayUUID))
        enabledDisplayIDs = enabledIDs
        if let screen = screens.first(where: { enabledIDs.contains($0.displayUUID) }) {
            let current = Self.currentDisplay(screen, in: settings, screens: screens)
            displayPreset = DisplayPreset.allCases.first {
                let preset = $0.settings(for: screen, enabled: true)
                return preset.width == current.width && preset.height == current.height
            }
        } else { displayPreset = nil }
        motion = settings.motion
        automaticShelf = settings.shelfTrigger != .manual
        calendarCountdown = settings.countdownEnabled
        notionButton = settings.toolbarActions.contains(.notion)
        hideFromCapture = settings.hideFromScreenCapture
        externalBrowserBundleID = settings.externalBrowserBundleID
    }

    private static func currentDisplay(_ screen: NSScreen, in settings: SettingsData, screens: [NSScreen]) -> DisplaySettings {
        if let saved = settings.displays[screen.displayUUID] { return saved }
        let enabled = screen.hasNotch || (!screens.contains(where: \.hasNotch) && screen == screens.first)
        return DisplaySettings(enabled: enabled, width: min(960, screen.frame.width - 80).rounded(),
                               height: min(660, screen.frame.height * 0.75).rounded())
    }

    mutating func setDisplay(_ id: String, enabled: Bool) {
        if enabled { enabledDisplayIDs.insert(id) }
        else if enabledDisplayIDs.count > 1 { enabledDisplayIDs.remove(id) }
    }

    mutating func selectDisplayPreset(_ preset: DisplayPreset) {
        displayPreset = preset
        displayPresetChanged = true
    }

    @discardableResult mutating func addPage(name: String, address: String) -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: \.isWhitespace) else { return false }
        let input = raw.contains("://") ? raw : "https://" + raw
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, host.contains(".") || host == "localhost",
              components.user == nil, components.password == nil,
              let url = components.url else { return false }
        func pageKey(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if parts?.path == "" { parts?.path = "/" }
            return parts?.url?.absoluteString ?? url.absoluteString
        }
        if pinnedTabs.contains(where: { URL(string: $0.url).map(pageKey) == pageKey(url) }) { return false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pinnedTabs.append(PinnedTab(name: title.isEmpty ? host : title, url: url.absoluteString))
        return true
    }

    func apply(to settings: inout SettingsData, screens: [NSScreen] = NSScreen.screens) {
        settings.pinnedTabs = pinnedTabs
        for screen in screens {
            let id = screen.displayUUID
            let enabled = enabledDisplayIDs.contains(id)
            var current = Self.currentDisplay(screen, in: settings, screens: screens)
            guard current.enabled != enabled || displayPresetChanged else { continue }
            if displayPresetChanged, let displayPreset {
                let opacity = current.idleOpacity
                current = displayPreset.settings(for: screen, enabled: enabled)
                current.idleOpacity = opacity
            }
            current.enabled = enabled
            settings.displays[id] = current
        }
        settings.motion = motion
        if !automaticShelf { settings.shelfTrigger = .manual }
        else if settings.shelfTrigger == .manual { settings.shelfTrigger = .automatic }
        settings.countdownEnabled = calendarCountdown
        settings.hideFromScreenCapture = hideFromCapture
        settings.externalBrowserBundleID = externalBrowserBundleID
        if notionButton && !settings.toolbarActions.contains(.notion) {
            let position = settings.toolbarActions.firstIndex(of: .settings) ?? settings.toolbarActions.count
            settings.toolbarActions.insert(.notion, at: position)
        } else if !notionButton {
            settings.toolbarActions.removeAll { $0 == .notion }
        }
    }
}

extension Notification.Name {
    static let showNotchBrowserOnboarding = Notification.Name("NotchBrowser.showOnboarding")
}

enum OnboardingDestination { case notch, settings, notionSettings }

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: (OnboardingChoices, OnboardingDestination) -> Void
    private let onSkip: () -> Void

    init(settings: SettingsData, onFinish: @escaping (OnboardingChoices, OnboardingDestination) -> Void, onSkip: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onSkip = onSkip
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NotchBrowserをはじめる"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(settings: settings, onFinish: onFinish, onSkip: onSkip))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) { window?.level = .normal }
    func windowDidBecomeKey(_ notification: Notification) { window?.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1) }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, pages, display, motion, personalize, ready
    var title: String {
        switch self {
        case .welcome: "ようこそ"
        case .pages: "固定ページ"
        case .display: "表示場所"
        case .motion: "動き"
        case .personalize: "使う機能"
        case .ready: "準備完了"
        }
    }
    var subtitle: String {
        switch self {
        case .welcome: "必要なときだけ、すぐそばに。"
        case .pages: "すぐ開きたいページを置きましょう。"
        case .display: "表示する画面と大きさを選びます。"
        case .motion: "ノッチの開閉を試しながら選べます。"
        case .personalize: "まず使うものだけ選びましょう。"
        case .ready: "いつでも設定から変更できます。"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .pages: "square.stack"
        case .display: "display"
        case .motion: "waveform.path"
        case .personalize: "slider.horizontal.3"
        case .ready: "checkmark"
        }
    }
}

private struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = OnboardingStep.welcome
    @State private var choices: OnboardingChoices
    @State private var pageName = ""
    @State private var pageAddress = ""
    @State private var pageError: String?
    private let browsers = ExternalBrowserLauncher.installed()
    let onFinish: (OnboardingChoices, OnboardingDestination) -> Void
    let onSkip: () -> Void

    init(settings: SettingsData, onFinish: @escaping (OnboardingChoices, OnboardingDestination) -> Void, onSkip: @escaping () -> Void) {
        _choices = State(initialValue: OnboardingChoices(settings: settings))
        self.onFinish = onFinish
        self.onSkip = onSkip
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("STEP \(step.rawValue + 1) / \(OnboardingStep.allCases.count)")
                        .font(.caption.weight(.bold)).tracking(2).foregroundStyle(.cyan)
                    Text(step.title).font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(step.subtitle).font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal, 34).padding(.top, 35).padding(.bottom, 18)

                ScrollView {
                    Group {
                        switch step {
                        case .welcome: welcome
                        case .pages: pages
                        case .display: display
                        case .motion: motion
                        case .personalize: personalize
                        case .ready: ready
                        }
                    }
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34).padding(.bottom, 18)
                }.id(step)

                Divider()
                HStack {
                    if step != .ready {
                        Button("今はスキップ", action: onSkip)
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("オンボーディングをスキップ")
                    }
                    Spacer()
                    if step != .welcome {
                        Button("戻る") { move(to: OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome) }
                            .accessibilityLabel("前のステップに戻る")
                    }
                    if step == .ready {
                        Button("設定を開く") { onFinish(choices, .settings) }
                            .accessibilityLabel("設定を開いて完了")
                        Button("ノッチを開いて始める") { onFinish(choices, .notch) }
                            .buttonStyle(OnboardingPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityLabel("ノッチを開いてオンボーディングを完了")
                    } else {
                        Button("次へ") { move(to: OnboardingStep(rawValue: step.rawValue + 1) ?? .ready) }
                            .buttonStyle(OnboardingPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityLabel("次のステップへ")
                    }
                }
                .padding(.horizontal, 34).padding(.vertical, 17)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 840, height: 570)
        .preferredColorScheme(.dark)
        .tint(.cyan)
    }

    private func move(to next: OnboardingStep) {
        if reduceMotion { step = next }
        else { withAnimation(.easeInOut(duration: 0.24)) { step = next } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 24)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NotchBrowser").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("GETTING STARTED").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 48)
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : item.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24)
                        .foregroundStyle(item.rawValue <= step.rawValue ? .cyan : .secondary)
                    Text(item.title).font(.system(size: 13, weight: item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? .white : .secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(item == step ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 5)
            }
            Spacer()
            Text("後からメニューバーと設定で\nこのガイドを開けます。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
        }
        .padding(22).frame(width: 225)
        .background(LinearGradient(colors: [Color(red: 0.09, green: 0.16, blue: 0.22), Color(red: 0.07, green: 0.08, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotchIllustration()
            Text("ブラウザと、ちょっとした道具をノッチに。")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("いつものページ、ファイル棚、メモ、Notionエージェント。まずはよく使うページとノッチの見え方を決めましょう。")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            HStack(alignment: .top, spacing: 10) {
                instruction("cursorarrow.motionlines", title: "カーソルで開く", detail: "画面上端に乗せ、クリックで入力")
                instruction("keyboard", title: "⌃⌥N でも開く", detail: "どのアプリからでも呼び出せます")
            }
        }
    }

    private var pages: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("固定ページはノッチの上部に並びます。後から設定で名前や順番も変えられます。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(choices.pinnedTabs) { page in
                HStack(spacing: 11) {
                    Image(systemName: "globe").foregroundStyle(.cyan).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.name).font(.subheadline.weight(.medium))
                        Text(page.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { choices.pinnedTabs.removeAll { $0.id == page.id } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("\(page.name)を外す")
                    .accessibilityLabel("\(page.name)を固定ページから外す")
                }
                .padding(11).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }
            if choices.pinnedTabs.isEmpty {
                Text("固定ページなしでも使えます。新規タブから検索やURLの入力ができます。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            HStack(spacing: 9) {
                TextField("名前（省略可）", text: $pageName).frame(width: 140)
                TextField("example.com", text: $pageAddress)
                    .onSubmit(addPage)
                Button("追加", action: addPage).disabled(pageAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let pageError { Text(pageError).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 8) {
                Text("おすすめ").font(.caption).foregroundStyle(.secondary)
                quickPage("Claude", url: "https://claude.ai/")
                quickPage("ChatGPT", url: "https://chatgpt.com/")
            }
        }
    }

    private func addPage() {
        guard choices.addPage(name: pageName, address: pageAddress) else {
            pageError = "URLを確認してください。http(s)のページを1つずつ追加できます。"
            return
        }
        pageName = ""; pageAddress = ""; pageError = nil
    }

    private func quickPage(_ name: String, url: String) -> some View {
        let added = choices.pinnedTabs.contains { URL(string: $0.url)?.host() == URL(string: url)?.host() }
        return Button { _ = choices.addPage(name: name, address: url); pageError = nil } label: {
            Label(name, systemImage: added ? "checkmark" : "plus")
        }
        .buttonStyle(.bordered).controlSize(.small).disabled(added)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("表示するディスプレイ").font(.headline)
                ForEach(NSScreen.screens, id: \.displayUUID) { screen in
                    let id = screen.displayUUID
                    let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Toggle(isOn: Binding(
                        get: { choices.enabledDisplayIDs.contains(id) },
                        set: { choices.setDisplay(id, enabled: $0) })) {
                            Label(name.isEmpty ? "ディスプレイ \((NSScreen.screens.firstIndex(of: screen) ?? 0) + 1)" : name,
                                  systemImage: screen.hasNotch ? "laptopcomputer" : "display")
                        }
                        .disabled(choices.enabledDisplayIDs.count == 1 && choices.enabledDisplayIDs.contains(id))
                        .padding(10)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("少なくとも1つの画面に表示します。後から画面ごとに細かく調整できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("開いたときの大きさ").font(.headline)
                HStack(spacing: 10) {
                    ForEach(DisplayPreset.allCases) { preset in
                        PresetCard(title: preset.title, subtitle: displaySize(for: preset),
                                   symbol: preset.symbol, selected: choices.displayPreset == preset) {
                            choices.selectDisplayPreset(preset)
                        }
                    }
                }
                if choices.displayPreset == nil {
                    Text("現在のサイズを維持中。カードを選ぶと変更します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func displaySize(for preset: DisplayPreset) -> String {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return "表示サイズを選ぶ" }
        let size = preset.settings(for: screen, enabled: true)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var motion: some View {
        VStack(alignment: .leading, spacing: 12) {
            MotionPreview(settings: choices.motion, autoPlay: true)
                .padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(MotionPreset.allCases) { preset in
                    PresetCard(title: preset.title, subtitle: preset.subtitle, symbol: preset.symbol,
                               selected: choices.motion == preset.settings) {
                        choices.motion = preset.settings
                    }
                }
            }
            if !MotionPreset.allCases.contains(where: { $0.settings == choices.motion }) {
                Text("現在のカスタム設定を維持中。カードを選ぶと変更します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("選ぶたびに上で再生します。macOSの「視差効果を減らす」が有効な場合は動きを省きます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func instruction(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.cyan)
                .frame(width: 36, height: 36).background(.cyan.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var personalize: some View {
        VStack(alignment: .leading, spacing: 11) {
            option("tray", title: "ファイル棚を自動で出す", detail: "ドラッグを始めたときに棚を開きます。手動でもいつでも開けます。", isOn: $choices.automaticShelf)
            option("calendar", title: "次の予定を表示", detail: "カレンダーへのアクセスは、完了後に必要なときだけ確認します。", isOn: $choices.calendarCountdown)
            option("sparkles.rectangle.stack", title: "Notionボタンを置く", detail: "接続は後から設定します。使わない場合もメニューから開けます。", isOn: $choices.notionButton)
            option("eye.slash", title: "画面共有から隠す", detail: "対応する画面共有・録画ではノッチを映しません。", isOn: $choices.hideFromCapture)
            HStack {
                Image(systemName: "safari").frame(width: 28).foregroundStyle(.cyan)
                Picker("ブラウザで開く先", selection: $choices.externalBrowserBundleID) {
                    Text("システムのデフォルト").tag(nil as String?)
                    ForEach(browsers) { browser in
                        Text(browser.name).tag(Optional(browser.id))
                    }
                    if let selected = choices.externalBrowserBundleID,
                       !browsers.contains(where: { $0.id == selected }) {
                        Text("現在の設定を維持").tag(Optional(selected))
                    }
                }
            }
            .padding(11).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            Text("リンクやタブの右クリックからブラウザで開くときに使います。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func option(_ symbol: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(isOn.wrappedValue ? .cyan : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(13)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("準備ができました").font(.title3.weight(.semibold))
                    Text("選んだ機能は後からいつでも変更できます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 12) {
                summary("ブラウザ", "ノッチにカーソルを乗せるか、⌃⌥Nで開く")
                summary("固定ページ", "\(choices.pinnedTabs.count)件")
                summary("サイズ", choices.displayPreset?.title ?? "現在の設定")
                summary("動き", MotionPreset.allCases.first(where: { $0.settings == choices.motion })?.title ?? "現在の設定")
                summary("ファイル棚", choices.automaticShelf ? "ドラッグ時に自動で表示" : "メニューから手動で開く")
                summary("次の予定", choices.calendarCountdown ? "表示する" : "表示しない")
                if choices.notionButton {
                    summary("Notionエージェント", "設定からトークンを登録して接続")
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            if choices.notionButton {
                Button("Notionの接続設定を開く") { onFinish(choices, .notionSettings) }
                    .buttonStyle(.link)
                    .accessibilityLabel("Notionの接続設定を開いて完了")
            }
        }
    }

    private func summary(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").foregroundStyle(.cyan).frame(width: 16)
            Text(name).fontWeight(.medium).frame(width: 105, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
        }.font(.caption)
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .frame(height: 31)
            .background(Color.cyan.opacity(configuration.isPressed ? 0.72 : 0.95), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NotchIllustration: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.18, blue: 0.25), Color(red: 0.08, green: 0.10, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 0).fill(.black).frame(width: 155, height: 28)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                    Image(systemName: "house")
                    Spacer()
                    Image(systemName: "sparkles.rectangle.stack")
                    Image(systemName: "tray")
                    Image(systemName: "gearshape")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 20).frame(height: 42)
                RoundedRectangle(cornerRadius: 11)
                    .fill(.white.opacity(0.07))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.cyan)
                            Text("検索する、ページを開く").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 17)
            }
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.10)))
        .accessibilityLabel("ノッチが開いたときのイメージ")
    }
}
