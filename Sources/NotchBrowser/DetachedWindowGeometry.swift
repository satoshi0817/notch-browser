import AppKit

enum DetachedWindowGeometry {
    static func constrain(_ frame: NSRect, screens: [NSRect], primary: NSRect, minimumSize: NSSize = NSSize(width: 480, height: 320)) -> NSRect {
        let valid = frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
        let proposed = valid ? frame : NSRect(x: primary.midX - 500, y: primary.midY - 350, width: 1000, height: 700)
        let screen = screens.first(where: { $0.contains(proposed) })
            ?? screens.max(by: { $0.intersection(proposed).area < $1.intersection(proposed).area })
                .flatMap { $0.intersects(proposed) ? $0 : nil } ?? primary
        let width = min(max(minimumSize.width, proposed.width), screen.width)
        let height = min(max(minimumSize.height, proposed.height), screen.height)
        return NSRect(x: min(max(proposed.minX, screen.minX), screen.maxX - width),
                      y: min(max(proposed.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}

struct DetachedNormalFrameState {
    private(set) var lastNormalFrame: NSRect
    private var transitionTarget: NSRect?
    private var zoomFrame: NSRect?

    init(frame: NSRect) { lastNormalFrame = frame }

    private static func matches(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    mutating func beginZoom(frame: NSRect, target: NSRect, visibleFrame: NSRect, isZoomed: Bool) {
        let expanded = isZoomed || Self.matches(frame, visibleFrame)
            || zoomFrame.map { Self.matches(frame, $0) } == true
        if !expanded { lastNormalFrame = frame }
        zoomFrame = expanded ? nil : target
        transitionTarget = target
    }

    mutating func observe(frame: NSRect, visibleFrame: NSRect, isZoomed: Bool) -> NSRect {
        if let target = transitionTarget {
            guard Self.matches(frame, target) else { return lastNormalFrame }
            transitionTarget = nil
        }
        let expanded = isZoomed || Self.matches(frame, visibleFrame)
            || zoomFrame.map { Self.matches(frame, $0) } == true
        if !expanded { lastNormalFrame = frame; zoomFrame = nil }
        return lastNormalFrame
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
