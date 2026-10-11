import AppKit

enum DetachedToolbarLayout {
    static let iconWidth: CGFloat = 28
    static let spacing: CGFloat = 4
    static let tabWidth: CGFloat = 100
    static let rightInset: CGFloat = 12
    static let tabControlGap: CGFloat = 8
    static let permanent: [ToolbarAction] = [.back, .forward, .reload]
    static let overflowOrder: [ToolbarAction] = [.quit, .settings, .address, .home]

    struct Result {
        let visible: [ToolbarAction]
        let overflow: [ToolbarAction]
        var width: CGFloat { DetachedToolbarLayout.width(for: visible.count) }
    }

    // Reserve traffic lights, one 100pt tab, the new-tab button and its gap,
    // three navigation icons, return-to-notch and the menu. No large minimum width.
    static func minimumWidth(trafficInset: CGFloat) -> CGFloat {
        trafficInset + tabWidth + iconWidth + spacing + tabControlGap + rightInset
            + width(for: permanent.count)
    }

    static func width(for actionCount: Int) -> CGFloat {
        let count = CGFloat(actionCount + 2) // return-to-notch and menu always remain
        return count * iconWidth + (count - 1) * spacing
    }

    static func resolve(availableWidth: CGFloat) -> Result {
        var visible: [ToolbarAction] = [.back, .forward, .home, .reload, .address, .settings, .quit]
        var overflow: [ToolbarAction] = []
        for action in overflowOrder where width(for: visible.count) > availableWidth {
            visible.removeAll { $0 == action }
            overflow.append(action)
        }
        return Result(visible: visible, overflow: overflow)
    }
}

/// Transparent overlay on empty titlebar areas; controls underneath retain their clicks.
final class BrowserTitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let parent = superview,
              frame.contains(point) else { return nil }
        func containsControl(_ view: NSView) -> Bool {
            guard !view.isHidden else { return false }
            let local = view.convert(point, from: parent)
            guard view.bounds.contains(local) else { return false }
            if view is NSControl { return true }
            return view.subviews.contains { containsControl($0) }
        }
        let blocked = parent.subviews.contains(where: { $0 !== self && containsControl($0) })
        return blocked ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
}
