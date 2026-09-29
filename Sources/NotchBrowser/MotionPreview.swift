import SwiftUI

/// An isolated preview: checking motion never opens the real browser or changes focus.
struct MotionPreview: View {
    let settings: MotionSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date.distantPast
    @State private var playing = false

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(started))
                let opening = elapsed < settings.openDuration + 0.65
                let duration = opening ? settings.openDuration : settings.closeDuration
                let raw = opening ? elapsed / duration : (elapsed - settings.openDuration - 0.65) / duration
                let immediate = reduceMotion || settings.style == .none
                let shape = immediate ? 1 : NotchMotionTiming.shape(raw, style: settings.style, opening: opening)
                let amount = playing ? (opening ? shape : 1 - shape) : 0
                let content = immediate ? 1 : NotchMotionTiming.content(raw, opening: opening)
                let opacity = playing ? (opening ? content : 1 - content) : 0
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.035))
                    UnevenRoundedRectangle(bottomLeadingRadius: 8 + 6 * amount, bottomTrailingRadius: 8 + 6 * amount)
                        .fill(.black)
                        .frame(width: 90 + 170 * amount, height: 17 + 89 * amount)
                        .overlay(alignment: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Image(systemName: "globe"); Text("NotchBrowser").font(.caption); Spacer() }
                                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)).frame(height: 25)
                            }.foregroundStyle(.secondary).padding(14).frame(width: 260)
                                .opacity(opacity)
                        }.clipped()
                }.frame(height: 126)
            }.accessibilityHidden(true)
            HStack {
                Text(reduceMotion ? "視差効果を減らす：オン" : "開く → 表示 → 閉じる").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { play() } label: { Label("動きを確認", systemImage: "play") }.disabled(reduceMotion)
            }
        }
        .onChange(of: settings) { _, _ in play() }
        .task(id: started) {
            guard playing else { return }
            do { try await Task.sleep(for: .seconds(settings.openDuration + 0.65 + settings.closeDuration)) }
            catch { return }
            playing = false
        }
    }
    private func play() {
        guard !reduceMotion else { return }
        started = Date(); playing = true
    }
}
