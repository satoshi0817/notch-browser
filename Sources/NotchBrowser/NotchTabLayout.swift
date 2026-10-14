import AppKit

enum NotchTabLayout {
    static let fixedIconSide: CGFloat = 16
    static func fixedTabWidth(title: String, display: NotionTabDisplay, iconSide: CGFloat = fixedIconSide, maximum: CGFloat = 120, measure: (String) -> CGFloat) -> CGFloat {
        let icon: CGFloat = display == .titleOnly ? 0 : iconSide + 4
        return min(maximum, max(28, 12 + icon + (display == .iconOnly ? 0 : ceil(measure(title)))))
    }
    static func fixedTabBudget(windowWidth: CGFloat, trailingOffset: CGFloat, leadingInset: CGFloat,
                               addWidth: CGFloat, hasNormal: Bool, normalWidth: CGFloat, showingFixedPanel: Bool) -> CGFloat {
        let strip = max(0, windowWidth / 2 + trailingOffset - addWidth - leadingInset - 4)
        let reserved = hasNormal ? (showingFixedPanel ? 28 : normalWidth) : 0
        return max(0, strip - reserved)
    }
    struct CompressionPlan {
        let widths: [CGFloat]
        let spacing: CGFloat
        let contentWidth: CGFloat
        let viewportWidth: CGFloat
        var scrolls: Bool { contentWidth > viewportWidth + 0.000001 }
    }
    /// Titles yield first, then gaps; icon-sized slots never yield to the budget.
    static func compressionPlan(natural: [CGFloat], minimum: [CGFloat], available: CGFloat, spacing: CGFloat = 4) -> CompressionPlan {
        precondition(natural.count == minimum.count)
        let gaps = CGFloat(max(0, natural.count - 1))
        let natural = zip(natural, minimum).map { value, floor in max(value, floor) }
        let full = natural.reduce(0, +) + gaps * spacing
        let budget = max(0, available)
        if full <= budget {
            return .init(widths: natural, spacing: spacing, contentWidth: full, viewportWidth: full)
        }
        let floor = minimum.reduce(0, +)
        if floor + gaps * spacing <= budget {
            // Cap long titles first instead of distributing equal *extra* width
            // above icon floors, which erased the text of every short tab.
            var low: CGFloat = 0
            var high = natural.max() ?? 0
            for _ in 0..<48 {
                let cap = (low + high) / 2
                let sum = zip(natural, minimum).reduce(CGFloat(0)) { $0 + max($1.1, min($1.0, cap)) }
                if sum > budget - gaps * spacing { high = cap } else { low = cap }
            }
            let widths = zip(natural, minimum).map { value, floor in max(floor, min(value, low)) }
            return .init(widths: widths, spacing: spacing, contentWidth: budget, viewportWidth: budget)
        }
        let gap = gaps > 0 ? max(0, min(spacing, (budget - floor) / gaps)) : 0
        let content = floor + gap * gaps
        return .init(widths: minimum, spacing: gap, contentWidth: content, viewportWidth: min(content, budget))
    }
    static let notionTabMaximumWidth: CGFloat = 120
    static func notionTabWidth(title: String, display: NotionTabDisplay, measure: (String) -> CGFloat) -> CGFloat {
        let icon: CGFloat = display == .titleOnly ? 0 : 22
        let text = display == .iconOnly ? 0 : measure(title)
        return min(notionTabMaximumWidth, max(28, 12 + icon + ceil(text)))
    }
    static func notionTitleRect(in bounds: NSRect, display: NotionTabDisplay, iconSide: CGFloat = 18) -> NSRect {
        let icon: CGFloat = display == .iconAndTitle ? iconSide + 4 : 0
        return NSRect(x: bounds.minX + 6 + icon, y: bounds.minY,
                      width: max(0, bounds.width - 12 - icon), height: bounds.height)
    }
    /// A truncated title must retain at least two characters; otherwise hide it.
    static func displayedTitle(_ title: String, available: CGFloat, measure: (String) -> CGFloat) -> String {
        let rendered = DetachedTabLayout.displayedTitle(title, mode: .full, available: available, measure: measure)
        return rendered.hasSuffix("…") && rendered.dropLast().count < 2 ? "" : rendered
    }
    /// Reserve the displayed browser title, without wasting 150pt on a short title.
    static func normalSlotWidth(natural: CGFloat) -> CGFloat {
        min(150, max(28, natural))
    }
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

    /// Keep Notion's measured title widths while compressing other fixed pages
    /// first. If even these tabs cannot fit, retain the existing narrow fallback.
    static func fixedWidths(natural: [CGFloat], available: CGFloat, spacing: CGFloat, preserving: Set<Int>) -> [CGFloat] {
        let protected = natural.indices.filter { preserving.contains($0) }
        let budget = max(0, available - CGFloat(max(0, natural.count - 1)) * spacing)
        let reserved = protected.reduce(CGFloat(0)) { $0 + natural[$1] }
        guard !protected.isEmpty, reserved <= budget else {
            return fixedWidths(natural: natural, available: available, spacing: spacing)
        }
        let others = natural.indices.filter { !preserving.contains($0) }
        let widths = fixedWidths(natural: others.map { natural[$0] }, available: budget - reserved, spacing: 0)
        var result = natural
        for (index, width) in zip(others, widths) { result[index] = width }
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
