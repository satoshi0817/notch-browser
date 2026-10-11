import AppKit

enum DetachedTabLayout {
    static let overflowButtonWidth: CGFloat = 28
    static let overflowButtonGap: CGFloat = 4
    static func planWithOverflowButton(available: CGFloat, count: Int, fullWidth: CGFloat, textMinimum: CGFloat = 66, spacing: CGFloat = 2, minimumVisible: Int = 1) -> Plan {
        let initial = plan(available: available, count: count, fullWidth: fullWidth, textMinimum: textMinimum, spacing: spacing)
        guard initial.overflow > 0 else { return initial }
        let reserved = available - overflowButtonWidth - overflowButtonGap
        let compact = plan(available: reserved, count: count, fullWidth: fullWidth, textMinimum: textMinimum, spacing: spacing)
        guard compact.capacity < minimumVisible, compact.toolbar.visible.contains(.reload) else { return compact }
        // Only overflow can relax reload permanence, after every optional action
        // has been folded and normal slots have been reduced to the selected one.
        let toolbar = DetachedToolbarLayout.Result(visible: compact.toolbar.visible.filter { $0 != .reload }, overflow: compact.toolbar.overflow + [.reload])
        let budget = max(0, reserved - toolbar.width)
        let capacity = min(minimumVisible, count, max(1, Int(floor((budget + spacing + 0.000001) / (28 + spacing)))))
        return Plan(toolbar: toolbar, width: 28, mode: .iconOnly, capacity: capacity, overflow: max(0, count - capacity), bandWidth: budget, spacing: spacing)
    }
    struct Distribution {
        let plan: Plan
        let visibleNormalIndices: [Int]
        let hiddenNormalCount: Int
        let width: CGFloat
    }
    static func distribute(available: CGFloat, pinnedCount: Int, normalCount: Int, selectedNormal: Int?, fullWidth: CGFloat, textMinimum: CGFloat = 66, spacing: CGFloat = 4) -> Distribution {
        let plan = plan(available: available, count: pinnedCount + normalCount, fullWidth: fullWidth, textMinimum: textMinimum, spacing: spacing)
        return distribute(plan: plan, pinnedCount: pinnedCount, normalCount: normalCount, selectedNormal: selectedNormal)
    }
    static func distribute(plan: Plan, pinnedCount: Int, normalCount: Int, selectedNormal: Int?) -> Distribution {
        let capacity = min(normalCount, max(0, plan.capacity - pinnedCount))
        var visible = Array(0..<capacity)
        if let selectedNormal, selectedNormal >= 0, selectedNormal < normalCount,
           !visible.contains(selectedNormal), !visible.isEmpty {
            visible[visible.count - 1] = selectedNormal
        }
        let displayed = pinnedCount + visible.count
        let width = normalCount > capacity && displayed > 0
            ? min(36, max(28, floor((plan.bandWidth - CGFloat(displayed - 1) * plan.spacing) / CGFloat(displayed)))) : plan.width
        return Distribution(plan: plan, visibleNormalIndices: visible, hiddenNormalCount: normalCount - capacity, width: width)
    }
    static func fullyVisibleCount(frames: [NSRect], viewport: NSRect) -> Int {
        frames.filter { $0.minX >= viewport.minX - 0.5 && $0.maxX <= viewport.maxX + 0.5 }.count
    }
    enum Mode: Int { case iconOnly, truncated, full }
    static func displayedTitle(_ title: String, mode: Mode, available: CGFloat, measure: (String) -> CGFloat) -> String {
        guard mode != .iconOnly, !title.isEmpty else { return "" }
        if measure(title) <= available { return title }
        var prefix = title
        while !prefix.isEmpty {
            if measure(prefix + "…") <= available { return prefix + "…" }
            prefix.removeLast()
        }
        return ""
    }
    struct Plan {
        let toolbar: DetachedToolbarLayout.Result
        var width: CGFloat
        let mode: Mode
        let capacity: Int
        let overflow: Int
        let bandWidth: CGFloat
        let spacing: CGFloat
        func visibleRange(selected: Int, count: Int) -> Range<Int> {
            let start = min(max(0, selected - capacity + 1), max(0, count - capacity))
            return start..<min(count, start + capacity)
        }
    }

    /// Preserve toolbar actions until the equal text share reaches two characters
    /// plus an ellipsis. At overflow boundaries hold that share constant.
    static func plan(available: CGFloat, count: Int, fullWidth: CGFloat, textMinimum: CGFloat, spacing: CGFloat = 4) -> Plan {
        let n = max(1, count)
        let epsilon: CGFloat = 0.000001 // points; absorb arithmetic roundoff at exact fits
        let gaps = CGFloat(n - 1) * spacing
        let textMinimum = ceil(textMinimum)
        let fullCap = min(150, ceil(max(textMinimum, fullWidth)))
        let all = DetachedToolbarLayout.resolve(availableWidth: .greatestFiniteMagnitude)
        let shareAll = (available - all.width - gaps) / CGFloat(n)
        let toolbar = shareAll + epsilon >= textMinimum ? all
            : DetachedToolbarLayout.resolve(availableWidth: available - CGFloat(n) * textMinimum - gaps + epsilon)
        let budget = max(0, available - toolbar.width)
        let share = (budget - gaps) / CGFloat(n)
        let width: CGFloat
        if shareAll + epsilon >= textMinimum { width = min(fullCap, max(textMinimum, floor(shareAll + epsilon))) }
        else if share + epsilon >= textMinimum { width = textMinimum }
        else { width = max(28, min(textMinimum, floor(share + epsilon))) }
        let mode: Mode = width + epsilon < textMinimum ? .iconOnly
            : (width + epsilon >= fullWidth ? .full : .truncated)
        // A fractional equal share already fits all n tabs. Do not divide it back
        // into the budget and truncate n-minus-roundoff to n-1. Only a genuine
        // minimum-click-width shortage may create hidden tabs.
        let needsOverflow = mode == .iconOnly && budget + epsilon < CGFloat(n) * 28 + gaps
        let capacity = needsOverflow
            ? max(1, min(n, Int(floor((budget + spacing + epsilon) / (28 + spacing)))))
            : n
        return Plan(toolbar: toolbar, width: width, mode: mode, capacity: capacity, overflow: max(0, count - capacity), bandWidth: budget, spacing: spacing)
    }
    /// nil denotes a flexible title; fixed icons/dividers keep their intrinsic widths.
    static func widths(available: CGFloat, items: [CGFloat?], naturalWidths: [CGFloat]? = nil, spacing: CGFloat = 4) -> [CGFloat] {
        let natural = items.indices.map { min(150, max(40, naturalWidths?[$0] ?? 150)) }
        var result = items.map { $0 ?? 40 }
        var pending = items.indices.filter { items[$0] == nil }
        var budget = available - items.compactMap { $0 }.reduce(0, +)
            - CGFloat(max(0, items.count - 1)) * spacing
        while !pending.isEmpty {
            let share = max(40, budget / CGFloat(pending.count))
            let short = pending.filter { natural[$0] <= share }
            if short.isEmpty {
                for index in pending { result[index] = min(natural[index], share) }
                break
            }
            for index in short { result[index] = natural[index]; budget -= natural[index] }
            pending.removeAll { short.contains($0) }
        }
        return result
    }
}
