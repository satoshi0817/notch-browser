import SwiftUI

enum MotionPreviewTimeline {
    static func totalDuration(settings: MotionSettings, reduceMotion: Bool) -> Double {
        let animated = !reduceMotion && settings.style != .none
        return settings.openDelay + (animated ? settings.openDuration : 0) + 0.65
            + settings.closeDelay + (animated ? settings.closeDuration : 0)
    }

    static func values(at elapsed: Double, settings: MotionSettings, playing: Bool, reduceMotion: Bool) -> (size: Double, content: Double) {
        let immediate = reduceMotion || settings.style == .none
        let openStart = settings.openDelay
        let openEnd = openStart + (immediate ? 0 : settings.openDuration)
        let closeStart = openEnd + 0.65 + settings.closeDelay
        if !playing || elapsed < openStart { return (0, 0) }
        if elapsed < openEnd {
            let raw = (elapsed - openStart) / settings.openDuration
            return (immediate ? 1 : NotchMotionTiming.shape(raw, style: settings.style, opening: true),
                    immediate ? 1 : NotchMotionTiming.content(raw, opening: true))
        }
        if elapsed < closeStart { return (1, 1) }
        let raw = (elapsed - closeStart) / settings.closeDuration
        return (immediate ? 0 : 1 - NotchMotionTiming.shape(raw, style: settings.style, opening: false),
                immediate ? 0 : 1 - NotchMotionTiming.content(raw, opening: false))
    }
}

/// An isolated preview: checking motion never opens the real browser or changes focus.
struct MotionPreview: View {
    let settings: MotionSettings
    var autoPlay = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date.distantPast
    @State private var playing = false

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(started))
                let progress = MotionPreviewTimeline.values(at: elapsed, settings: settings, playing: playing, reduceMotion: reduceMotion)
                let amount = progress.size
                let opacity = progress.content
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
        .onAppear { if autoPlay { play() } }
        .onChange(of: settings) { _, _ in play() }
        .task(id: started) {
            guard playing else { return }
            do { try await Task.sleep(for: .seconds(MotionPreviewTimeline.totalDuration(settings: settings, reduceMotion: reduceMotion))) }
            catch { return }
            playing = false
        }
    }
    private func play() {
        guard !reduceMotion else { return }
        started = Date(); playing = true
    }

}
