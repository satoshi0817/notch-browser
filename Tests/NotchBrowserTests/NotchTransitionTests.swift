import AppKit
import XCTest
@testable import NotchBrowser

final class NotchTransitionTests: XCTestCase {
    func testCurvesStayMonotonicWithoutOvershootAndReachExactEndpoints() {
        for style in NotchAnimationStyle.allCases where style != .none {
            for opening in [true, false] {
                let values = (0...100).map { NotchMotionTiming.shape(Double($0) / 100, style: style, opening: opening) }
                XCTAssertEqual(values.first, 0)
                XCTAssertEqual(values.last, 1)
                XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
                XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
            }
        }
        XCTAssertEqual(NotchMotionTiming.content(0.1, opening: true), 0)
        XCTAssertEqual(NotchMotionTiming.content(0.6, opening: false), 1)
        XCTAssertLessThan(NotchMotionTiming.content(0.3, opening: true), NotchMotionTiming.shape(0.3, style: .responsive, opening: true))
    }

    @MainActor func testCompletionCanStartANewTransitionWithoutLosingCancellation() {
        let transition = NotchTransition()
        var nextUpdates = 0
        var restarted = false
        transition.run(duration: 0.02) { progress in
            if progress == 1 {
                restarted = true
                transition.run(duration: 1) { _ in nextUpdates += 1 }
            }
        }
        let deadline = Date().addingTimeInterval(1)
        while !restarted && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(restarted)
        transition.cancel()
        let count = nextUpdates
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(nextUpdates, count)
    }

    @MainActor func testRetargetingStartsAtVisibleFrameAndLeavesNoOldCompletion() throws {
        _ = NSApplication.shared
        let saved = SettingsStore.shared.data
        defer { SettingsStore.shared.data = saved }
        var data = SettingsData(); data.pinnedTabs = []; data.countdownEnabled = false
        data.motion.openDuration = 0.12; data.motion.closeDuration = 0.12
        SettingsStore.shared.data = data
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = NotchManager(shelfStore: ShelfStore(file: directory.appendingPathComponent("shelf.json")))
        let controller = NotchController(screen: try XCTUnwrap(NSScreen.screens.first), manager: manager)
        defer { controller.close() }
        controller.show()
        let collapsed = controller.panel.frame
        controller.expand(focus: false)
        let deadline = Date().addingTimeInterval(1)
        while controller.panel.frame.height == collapsed.height && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let partial = controller.panel.frame
        XCTAssertGreaterThan(partial.height, collapsed.height)
        controller.collapse()
        XCTAssertEqual(controller.panel.frame, partial, "Closing must begin at the currently visible geometry")
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        let reversing = controller.panel.frame
        controller.expand(focus: false)
        XCTAssertEqual(controller.panel.frame, reversing)
        RunLoop.main.run(until: Date().addingTimeInterval(0.18))
        XCTAssertTrue(controller.isExpanded)
        XCTAssertEqual(controller.panel.frame.height, controller.expandedSize.height, accuracy: 1)
        XCTAssertEqual(controller.panel.frame.maxY, collapsed.maxY, accuracy: 1)
        XCTAssertEqual(controller.root.content.alphaValue, 1)
        controller.collapse(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(controller.panel.frame, collapsed)
        XCTAssertEqual(controller.root.content.alphaValue, 0)
    }
}
