import Foundation

enum NotchAnimationStyle: String, Codable, CaseIterable, Identifiable {
    case responsive, easeInOut, linear, none

    var id: Self { self }
    var title: String {
        switch self {
        case .responsive: "すばやく滑らか（従来の動き）"
        case .easeInOut: "ゆっくり加速・減速"
        case .linear: "一定速度"
        case .none: "アニメーションなし"
        }
    }
}

struct MotionSettings: Codable, Equatable {
    var openDelay: Double = 0.12
    var closeDelay: Double = 0.4
    var openDuration: Double = 0.28
    var closeDuration: Double = 0.28
    var style: NotchAnimationStyle = .responsive

    static let delayRange = 0.0...3.0
    static let durationRange = 0.05...1.5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MotionSettings()
        func value(_ key: CodingKeys, fallback: Double, range: ClosedRange<Double>) -> Double {
            guard let value = try? c.decode(Double.self, forKey: key), value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        openDelay = value(.openDelay, fallback: defaults.openDelay, range: Self.delayRange)
        closeDelay = value(.closeDelay, fallback: defaults.closeDelay, range: Self.delayRange)
        openDuration = value(.openDuration, fallback: defaults.openDuration, range: Self.durationRange)
        closeDuration = value(.closeDuration, fallback: defaults.closeDuration, range: Self.durationRange)
        style = (try? c.decode(NotchAnimationStyle.self, forKey: .style)) ?? defaults.style
    }
}
