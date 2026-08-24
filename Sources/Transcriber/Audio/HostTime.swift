import Darwin
import Foundation

/// Converts mach host-time values, which is what both capture paths timestamp their first
/// block with, into seconds.
///
/// Mach time is one clock for the whole machine but its unit is not a nanosecond — the
/// conversion depends on the hardware and must be read from `mach_timebase_info`. On Apple
/// silicon it is 125/3, so treating the raw difference as nanoseconds would be off by more
/// than a factor of forty.
enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Host ticks for a duration in seconds. The inverse of `seconds(from:to:)`, and only
    /// needed to build a known interval in tests.
    static func hostTicks(forSeconds seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Seconds from `start` to `end`. Negative when `end` came first.
    static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        let ticks = Double(end) - Double(start)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
