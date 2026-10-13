import AppKit

enum NotchTabLayout {
    static func pinnedWidth(natural: CGFloat, available: CGFloat, hasNormal: Bool, normalWidth: CGFloat = 150) -> CGFloat {
        min(max(0, natural), max(0, available - (hasNormal ? normalWidth : 0)))
    }

    /// Shrink long titles first, retaining the natural width of short/icon tabs.
    static func fixedWidths(natural: [CGFloat], available: CGFloat, spacing: CGFloat = 4) -> [CGFloat] {
        var result = natural.map { max(0, $0) }
        var pending = Array(result.indices)
        var budget = max(0, available - CGFloat(max(0, result.count - 1)) * spacing)
        while !pending.isEmpty {
            let share = budget / CGFloat(pending.count)
            let short = pending.filter { result[$0] <= share }
            if short.isEmpty {
                for index in pending { result[index] = share }
                break
            }
            for index in short { budget -= result[index] }
            pending.removeAll { short.contains($0) }
        }
        return result
    }

    static func revealOrigin(current: CGFloat, viewport: CGFloat, document: CGFloat, selected: NSRect) -> CGFloat {
        var origin = current
        if selected.minX < origin { origin = selected.minX }
        else if selected.maxX > origin + viewport { origin = selected.maxX - viewport }
        if selected.width > viewport { origin = selected.minX }
        return min(max(0, origin), max(0, document - viewport))
    }
}
