import AppKit
import SwiftUI

/// A single glass layer for the app chrome. Web pages remain opaque and readable.
final class GlassSurface: NSView {
    let content = NSView()
    private let tint = NSView()
    private var effect: NSView!
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            glass.contentView = content
            effect = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(content)
            effect = material
        }
        addSubview(effect)
        tint.wantsLayer = true
        content.addSubview(tint)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateAppearance() }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    func updateAppearance() {
        let accessible = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let strength = SettingsStore.shared.data.glassTint
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.13,
                                             alpha: accessible ? 1 : 0.18 + strength * 0.64).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(accessible ? 0.5 : 0.15).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 18
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        if #available(macOS 26.0, *) { } else { content.frame = bounds }
        tint.frame = content.bounds
    }
}

struct GlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content
                .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
        }
    }
}

struct StartPage: View {
    let tabs: [PinnedTab]
    let open: (UUID) -> Void
    let search: () -> Void
    let restore: () -> Void
    let canRestore: Bool
    let settings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: "safari").font(.system(size: 32, weight: .light))
                        .foregroundStyle(.cyan).frame(width: 64, height: 64).modifier(GlassCard())
                    VStack(alignment: .leading, spacing: 6) {
                        Text("次の作業を、ここから。").font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text("いつものページへ、ひと続きで。").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Button(action: search) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("検索、またはURLを入力")
                        Spacer()
                        Text("⌘ L").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(16).modifier(GlassCard())
                }.buttonStyle(.plain).accessibilityLabel("検索またはURLを入力")
                VStack(alignment: .leading, spacing: 12) {
                    Label("固定したページ", systemImage: "pin").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    if tabs.isEmpty {
                        Text("タブのメニューからページを固定すると、ここに表示されます。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(tabs) { tab in
                            Button { open(tab.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: TabIconRenderer.symbolName(for: tab.icon, hosts: [tab.host]))
                                        .font(.system(size: 20, weight: .medium)).foregroundStyle(.cyan).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tab.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(tab.host ?? "Web").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(GlassCard())
                            }.buttonStyle(.plain).accessibilityLabel(tab.name)
                        }
                    }
                }
                HStack(spacing: 16) {
                    Button(action: restore) { Label("閉じたタブを戻す", systemImage: "arrow.uturn.backward") }
                        .disabled(!canRestore)
                    Spacer()
                    Button(action: settings) { Label("固定ページを編集", systemImage: "slider.horizontal.3") }
                }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: [Color(red: 0.085, green: 0.12, blue: 0.2), Color(red: 0.04, green: 0.055, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
    }
}
