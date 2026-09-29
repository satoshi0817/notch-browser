import AppKit
import QuartzCore

/// Shared timing for the notch and the settings preview. No overshoot or spring bounce.
enum NotchMotionTiming {
    static func shape(_ progress: Double, style: NotchAnimationStyle, opening: Bool) -> Double {
        let t = min(1, max(0, progress))
        switch style {
        case .responsive: return opening ? 1 - pow(1 - t, 4) : t * t * (3 - 2 * t)
        case .easeInOut: return t * t * t * (t * (6 * t - 15) + 10)
        case .linear: return t
        case .none: return 1
        }
    }
    static func content(_ progress: Double, opening: Bool) -> Double {
        // The surface leads on opening; content withdraws before the surface on closing.
        let t = min(1, max(0, opening ? (progress - 0.12) / 0.78 : progress / 0.6))
        return t * t * (3 - 2 * t)
    }
}

/// Retarget from the visible frame, rather than from a previous animation's destination.
/// A short-lived timer runs in common modes so dragging and menus cannot stall a transition.
final class NotchTransition {
    private var timer: Timer?
    private var generation: UInt64 = 0
    deinit { timer?.invalidate() }
    func cancel() { generation &+= 1; timer?.invalidate(); timer = nil }
    func run(duration: TimeInterval, update: @escaping (Double) -> Void) {
        cancel()
        let token = generation
        guard duration > 0 else { update(1); return }
        let start = CACurrentMediaTime()
        update(0)
        guard generation == token else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self, self.generation == token else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - start) / duration)
            update(progress)
            if progress >= 1 {
                timer.invalidate()
                if self.generation == token { self.timer = nil }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
