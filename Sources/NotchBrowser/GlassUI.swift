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
    let tabID: ObjectIdentifier?
    let tabs: [PinnedTab]
    let open: (UUID) -> Void
    let navigate: (String) -> Void
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 44) {
                    VStack(spacing: 22) {
                        Image(systemName: "safari")
                            .font(.system(size: 34, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("どこへ行きますか？")
                            .font(.system(size: 29, weight: .medium, design: .rounded))
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                            TextField("URLを入力、または検索", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 17))
                                .focused($queryFocused)
                                .onSubmit(submitQuery)
                                .accessibilityLabel("検索またはURLを入力")
                            if !query.isEmpty {
                                Button(action: submitQuery) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(width: 30, height: 30)
                                        .background(.white.opacity(0.14), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("開く")
                            }
                        }
                        .padding(.horizontal, 22)
                        .frame(height: 64)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(queryFocused ? 0.32 : 0.13)))
                    }
                    VStack(alignment: .leading, spacing: 15) {
                        Text("固定したページ")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if tabs.isEmpty {
                            Text("タブのメニューからページを固定すると、ここに表示されます。")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                                ForEach(tabs) { tab in
                                    Button { open(tab.id) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: TabIconRenderer.symbolName(for: tab.icon, hosts: [tab.host]))
                                                .font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).frame(width: 26)
                                            Text(tab.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(15)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(tab.name)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: tabID) { _, _ in query = "" }
    }

    private func submitQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        navigate(text)
    }
}
