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
    var automaticShelf: Bool
    var calendarCountdown: Bool
    var notionButton: Bool
    var hideFromCapture: Bool

    init(settings: SettingsData) {
        automaticShelf = settings.shelfTrigger != .manual
        calendarCountdown = settings.countdownEnabled
        notionButton = settings.toolbarActions.contains(.notion)
        hideFromCapture = settings.hideFromScreenCapture
    }

    func apply(to settings: inout SettingsData) {
        if !automaticShelf { settings.shelfTrigger = .manual }
        else if settings.shelfTrigger == .manual { settings.shelfTrigger = .automatic }
        settings.countdownEnabled = calendarCountdown
        settings.hideFromScreenCapture = hideFromCapture
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
    case welcome, controls, personalize, ready
    var title: String {
        switch self {
        case .welcome: "ようこそ"
        case .controls: "基本操作"
        case .personalize: "使う機能"
        case .ready: "準備完了"
        }
    }
    var subtitle: String {
        switch self {
        case .welcome: "必要なときだけ、すぐそばに。"
        case .controls: "ノッチから開いて、すぐ戻れます。"
        case .personalize: "まず使うものだけ選びましょう。"
        case .ready: "いつでも設定から変更できます。"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .controls: "cursorarrow.motionlines"
        case .personalize: "slider.horizontal.3"
        case .ready: "checkmark"
        }
    }
}

private struct OnboardingView: View {
    @State private var step = OnboardingStep.welcome
    @State private var choices: OnboardingChoices
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
                    Text("STEP \(step.rawValue + 1) / 4")
                        .font(.caption.weight(.bold)).tracking(2).foregroundStyle(.cyan)
                    Text(step.title).font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(step.subtitle).font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal, 34).padding(.top, 35).padding(.bottom, 18)

                ScrollView {
                    Group {
                        switch step {
                        case .welcome: welcome
                        case .controls: controls
                        case .personalize: personalize
                        case .ready: ready
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34).padding(.bottom, 18)
                }

                Divider()
                HStack {
                    if step != .ready {
                        Button("今はスキップ", action: onSkip)
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("オンボーディングをスキップ")
                    }
                    Spacer()
                    if step != .welcome {
                        Button("戻る") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                            .accessibilityLabel("前のステップに戻る")
                    }
                    if step == .ready {
                        Button("設定を開く") { onFinish(choices, .settings) }
                            .accessibilityLabel("設定を開いて完了")
                        Button("ノッチを開いて始める") { onFinish(choices, .notch) }
                            .buttonStyle(OnboardingPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityLabel("ノッチを開いてオンボーディングを完了")
                    } else {
                        Button("次へ") { step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready }
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
        VStack(alignment: .leading, spacing: 20) {
            NotchIllustration()
            Text("ブラウザと、ちょっとした道具をノッチに。")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("いつものページ、ファイル棚、メモ、Notionエージェント。使いたいときに開き、離れると作業に戻れます。まずは基本操作を見て、使う機能を選びましょう。")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
        }
    }

    private var controls: some View {
        VStack(spacing: 11) {
            instruction("cursorarrow.motionlines", title: "カーソルを乗せる", detail: "画面上端のノッチに近づくと開きます。クリックすると入力できます。")
            instruction("keyboard", title: "⌃⌥N で開く・閉じる", detail: "どのアプリを使っていても、すぐ呼び出せます。")
            instruction("arrow.uturn.backward", title: "離れると閉じる", detail: "閉じるまでの時間や開閉の動きは設定で調整できます。")
            instruction("tray.and.arrow.down", title: "ファイルを置く", detail: "ファイルをノッチへドラッグすると棚に並びます。元ファイルはそのままです。")
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
