import AppKit
import XCTest
@testable import NotchBrowser

final class DetachedWindowGeometryTests: XCTestCase {
    private let primary = NSRect(x: 0, y: 24, width: 1440, height: 876)

    func testZoomAndIntermediateFramesKeepNormalFrameUntilUnzoomCompletes() {
        let normal = NSRect(x: 200, y: 268, width: 901, height: 613)
        var state = DetachedNormalFrameState(frame: normal)
        state.beginZoom(frame: normal, target: primary, visibleFrame: primary, isZoomed: false)
        XCTAssertEqual(state.observe(frame: NSRect(x: 100, y: 100, width: 1200, height: 750), visibleFrame: primary, isZoomed: false), normal)
        XCTAssertEqual(state.observe(frame: primary, visibleFrame: primary, isZoomed: true), normal)
        XCTAssertEqual(state.observe(frame: primary, visibleFrame: primary, isZoomed: false), normal)
        state.beginZoom(frame: primary, target: normal, visibleFrame: primary, isZoomed: true)
        XCTAssertEqual(state.observe(frame: primary, visibleFrame: primary, isZoomed: false), normal)
        XCTAssertEqual(state.observe(frame: normal, visibleFrame: primary, isZoomed: false), normal)
        let resized = NSRect(x: 210, y: 250, width: 800, height: 500)
        XCTAssertEqual(state.observe(frame: resized, visibleFrame: primary, isZoomed: false), resized)
    }

    func testIsZoomedAndNonScreenStandardFrameAreAlsoExcluded() {
        let normal = NSRect(x: 200, y: 100, width: 700, height: 500)
        let standard = NSRect(x: 100, y: 24, width: 1000, height: 800)
        var state = DetachedNormalFrameState(frame: normal)
        XCTAssertEqual(state.observe(frame: standard, visibleFrame: primary, isZoomed: true), normal)
        state.beginZoom(frame: normal, target: standard, visibleFrame: primary, isZoomed: false)
        XCTAssertEqual(state.observe(frame: standard, visibleFrame: primary, isZoomed: false), normal)
    }

    func testSavedOuterFrameRoundTripsWithoutDrift() {
        var frame = NSRect(x: 200, y: 268, width: 901, height: 613)
        let original = frame
        for _ in 0..<10 {
            frame = DetachedWindowGeometry.constrain(NSRectFromString(NSStringFromRect(frame)),
                                                      screens: [primary], primary: primary)
            XCTAssertEqual(frame, original)
        }
    }

    func testSavedFrameSmallerThanDetachedMinimumIsRaisedAndStable() {
        let minimum = NSSize(width: DetachedToolbarLayout.minimumWidth(trafficInset: 80), height: 320)
        let frame = DetachedWindowGeometry.constrain(NSRect(x: 200, y: 268, width: 300, height: 200),
                                                      screens: [primary], primary: primary, minimumSize: minimum)
        XCTAssertEqual(frame, NSRect(x: 200, y: 268, width: 388, height: 320))
        XCTAssertEqual(DetachedWindowGeometry.constrain(NSRectFromString(NSStringFromRect(frame)),
                                                         screens: [primary], primary: primary, minimumSize: minimum), frame)
    }

    func testKeepsFrameAlreadyInsideScreen() {
        let frame = NSRect(x: 100, y: 100, width: 1000, height: 700)
        XCTAssertEqual(DetachedWindowGeometry.constrain(frame, screens: [primary], primary: primary), frame)
    }

    func testDisconnectedDisplayMovesToPrimary() {
        let result = DetachedWindowGeometry.constrain(NSRect(x: 3000, y: -1000, width: 1000, height: 700),
                                                      screens: [primary], primary: primary)
        XCTAssertTrue(primary.contains(result))
        XCTAssertEqual(result.size, NSSize(width: 1000, height: 700))
    }

    func testOversizedWindowFitsVisibleFrame() {
        let result = DetachedWindowGeometry.constrain(NSRect(x: -100, y: -100, width: 3000, height: 2000),
                                                      screens: [primary], primary: primary)
        XCTAssertEqual(result, primary)
    }

    func testRetainsSecondaryScreenWithNegativeCoordinates() {
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = NSRect(x: -1800, y: 100, width: 1000, height: 700)
        XCTAssertEqual(DetachedWindowGeometry.constrain(frame, screens: [primary, secondary], primary: primary), frame)
    }

    func testPartiallyOffscreenAndInvalidFramesAreContained() {
        for frame in [NSRect(x: 1300, y: 800, width: 1000, height: 700), .zero] {
            let result = DetachedWindowGeometry.constrain(frame, screens: [primary], primary: primary)
            XCTAssertTrue(primary.contains(result))
        }
    }
}
