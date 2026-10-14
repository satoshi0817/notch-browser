import Foundation

/// IEEE 754 binary32 -> binary16, round-to-nearest, ties-to-even.
/// Raw storage is available on Intel too, where Swift's Float16 type is unavailable.
enum MeetingFP16 {
    static func bits(_ value: Float) -> UInt16 {
        let raw = value.bitPattern
        let sign = UInt16((raw >> 16) & 0x8000)
        let exponent = Int((raw >> 23) & 0xff)
        let fraction = raw & 0x7fffff
        if exponent == 255 {
            return sign | 0x7c00 | (fraction == 0 ? 0 : UInt16(fraction >> 13) | 0x0200)
        }
        let unbiased = exponent - 127
        if unbiased > 15 { return sign | 0x7c00 }
        if unbiased < -25 { return sign }
        let truncated: UInt32
        let remainder: UInt32
        let midpoint: UInt32
        if unbiased >= -14 {
            truncated = UInt32(exponent - 112) << 10 | fraction >> 13
            remainder = fraction & 0x1fff
            midpoint = 0x1000
        } else {
            let significand = fraction | 0x800000
            let shift = UInt32(-unbiased - 1)
            truncated = significand >> shift
            remainder = significand & ((UInt32(1) << shift) - 1)
            midpoint = UInt32(1) << (shift - 1)
        }
        let roundUp = remainder > midpoint || (remainder == midpoint && truncated & 1 != 0)
        return sign | UInt16(truncated + (roundUp ? 1 : 0))
    }
    static func isFinite(_ bits: UInt16) -> Bool { bits & 0x7c00 != 0x7c00 }
}
