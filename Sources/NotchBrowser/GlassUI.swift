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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: search) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("検索、またはURLを入力")
                        Spacer()
                        Text("⌘ L").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(16).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("検索またはURLを入力")
                VStack(alignment: .leading, spacing: 12) {
                    if tabs.isEmpty {
                        Text("タブのメニューからページを固定すると、ここに表示されます。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(tabs) { tab in
                            Button { open(tab.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: TabIconRenderer.symbolName(for: tab.icon, hosts: [tab.host]))
                                        .font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tab.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(tab.name)
                        }
                    }
                }
            }.padding(.horizontal, 32).padding(.top, 64).padding(.bottom, 32).frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
