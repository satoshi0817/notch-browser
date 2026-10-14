import SwiftUI

struct NotionRefreshButton: View {
    let refreshing: Bool
    let failureHelp: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !refreshing || reduceMotion)) { context in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshing && !reduceMotion ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) * 120 : 0))
            }
            .overlay(alignment: .bottomTrailing) {
                if failureHelp != nil { Text("⚠").font(.system(size: 8)).foregroundStyle(.orange).offset(x: 5, y: 5) }
            }
        }.help(failureHelp ?? "更新")
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if CommandLine.arguments.contains("--cache-tooltip"), let failureHelp {
                Text(failureHelp).font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize().offset(y: 32).allowsHitTesting(false)
            }
        }
        #endif
    }
}
struct NotionCacheSettingsRow: View {
    let updated: Date?
    let clear: () -> Void
    var body: some View {
        HStack {
            Text("最終更新 \(NotionPageRefreshRules.timestamp(updated))").foregroundStyle(.secondary)
            Spacer()
            Button("キャッシュを消去", action: clear)
        }
    }
}
struct NotionDeletedItemView: View {
    var body: some View {
        Text("この項目は Notion で削除されました").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
