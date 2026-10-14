import XCTest
@testable import NotchBrowser

final class MeetingFP16Tests: XCTestCase {
    func testRepresentativeValuesAndSignedZero() {
        let cases: [(Float, UInt16)] = [(0, 0x0000), (-Float.zero, 0x8000), (1, 0x3c00), (-1, 0xbc00),
                                     (0.5, 0x3800), (45.25, 0x51a8), (-22.625, 0xcda8), (65504, 0x7bff)]
        for (value, expected) in cases {
            XCTAssertEqual(MeetingFP16.bits(value), expected)
        }
    }
    func testNormalRoundingTiesToEvenAndMantissaCarry() {
        let tie: Float = 1 + 1 / 2048
        XCTAssertEqual(MeetingFP16.bits(tie.nextDown), 0x3c00)
        XCTAssertEqual(MeetingFP16.bits(tie), 0x3c00)
        XCTAssertEqual(MeetingFP16.bits(tie.nextUp), 0x3c01)
        XCTAssertEqual(MeetingFP16.bits(1 + 3 / 2048), 0x3c02)
        XCTAssertEqual(MeetingFP16.bits(-tie), 0xbc00)
        XCTAssertEqual(MeetingFP16.bits(2 - 1 / 2048), 0x4000)
    }
    func testSubnormalRoundingAndNormalBoundary() {
        let minimum: Float = 1 / 16_777_216 // 2^-24
        XCTAssertEqual(MeetingFP16.bits(minimum), 0x0001)
        XCTAssertEqual(MeetingFP16.bits(-minimum), 0x8001)
        XCTAssertEqual(MeetingFP16.bits(minimum / 2), 0x0000)
        XCTAssertEqual(MeetingFP16.bits((minimum / 2).nextUp), 0x0001)
        XCTAssertEqual(MeetingFP16.bits(-minimum / 2), 0x8000)
        XCTAssertEqual(MeetingFP16.bits(minimum * 1.5), 0x0002)
        XCTAssertEqual(MeetingFP16.bits(Float.leastNonzeroMagnitude), 0x0000)
        XCTAssertEqual(MeetingFP16.bits(-Float.leastNonzeroMagnitude), 0x8000)
        XCTAssertEqual(MeetingFP16.bits(minimum * 1023), 0x03ff)
        XCTAssertEqual(MeetingFP16.bits(minimum * 1023.5), 0x0400)
        XCTAssertEqual(MeetingFP16.bits(minimum * 1024), 0x0400)
    }
    func testOverflowInfinityAndNaN() {
        XCTAssertEqual(MeetingFP16.bits(Float(65520).nextDown), 0x7bff)
        XCTAssertEqual(MeetingFP16.bits(65520), 0x7c00)
        XCTAssertEqual(MeetingFP16.bits(-65520), 0xfc00)
        XCTAssertEqual(MeetingFP16.bits(.infinity), 0x7c00)
        XCTAssertEqual(MeetingFP16.bits(-Float.infinity), 0xfc00)
        XCTAssertEqual(MeetingFP16.bits(Float(bitPattern: 0x7f800001)), 0x7e00)
        XCTAssertFalse(MeetingFP16.isFinite(MeetingFP16.bits(.nan)))
        XCTAssertFalse(MeetingFP16.isFinite(0x7c00)); XCTAssertTrue(MeetingFP16.isFinite(0x7bff))
    }
    #if arch(arm64)
    func testEveryScaledBF16MatchesNativeArm64Conversion() {
        for raw in UInt32(0)...UInt32(0xffff) {
            let value = Float(bitPattern: raw << 16) * MeetingModelManifest.embeddingScale
            let reference = Float16(value)
            let actual = MeetingFP16.bits(value)
            if reference.isNaN { XCTAssertFalse(MeetingFP16.isFinite(actual)) }
            else { XCTAssertEqual(actual, reference.bitPattern, "BF16: \(raw)") }
        }
    }
    #endif
}
