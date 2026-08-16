import Foundation

/// Thread-safe shared date formatting helpers.
///
/// `DateFormatter` allocation is expensive (~0.1-0.3ms per instance) and
/// the formatter itself is not thread-safe. These helpers replace the
/// per-call `DateFormatter()` instances that used to pepper the collector
/// hot path (every tick, every row).
///
/// - ISO8601: `ISO8601DateFormatter` is thread-safe per Apple docs, so a
///   single shared static instance replaces dozens of per-call allocs.
/// - Day/month keys: `Calendar` + `DateComponents` are value types — no
///   locking, no formatter allocation, fully thread-safe.
enum DateFormatUtil {
    /// Shared ISO8601 writer (thread-safe — unlike DateFormatter).
    static let iso8601 = ISO8601DateFormatter()

    /// Local "yyyy-MM-dd" key for a date.
    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Local "yyyy-MM" key for a date.
    static func monthKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Today's local "yyyy-MM-dd" key.
    static func localTodayKey() -> String {
        dayKey(Date())
    }

    /// Parse a "yyyy-MM-dd" key into a Date (start of that local day).
    static func parseDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// Add `delta` days to a "yyyy-MM-dd" key and return the new key.
    static func dayKeyByAdding(_ key: String, delta: Int) -> String {
        guard let date = parseDayKey(key) else { return key }
        let next = Calendar.current.date(byAdding: .day, value: delta, to: date) ?? date
        return dayKey(next)
    }
}
