import Foundation

/// Shared limit-window text formatting (ports the renderer's `formatReset`,
/// `formatDuration` and `formatUpdatedAge`). Both the limits view and the home
/// limits module render these strings, so they live here rather than being
/// duplicated per view.
enum LimitsFormat {
    /// "Reset 5h 21m" / "Reset 26d 23h" / "Reset now".
    static func resetText(_ iso: String) -> String {
        let ms = UsageCore.timestampMs(iso)
        guard ms > 0 else { return "" }
        let remaining = ms / 1000 - Date().timeIntervalSince1970
        guard remaining > 0 else { return "Reset now" }
        return "Reset \(durationText(remaining))"
    }

    /// Renderer's `formatDuration`, in seconds.
    static func durationText(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// Renderer's `formatUpdatedAge`.
    static func updatedAgeText(_ iso: String) -> String {
        let ms = UsageCore.timestampMs(iso)
        guard ms > 0 else { return "" }
        let age = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if age < 45 { return "Updated just now" }
        let minutes = Int((age / 60).rounded())
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(hours / 24)d ago"
    }
}
