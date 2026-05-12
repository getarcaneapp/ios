import Foundation

/// Tiny best-effort cron-to-prose translator. Recognizes a handful of common
/// patterns (every N minutes/hours/days, daily at midnight, hourly on the hour)
/// and returns `nil` for anything it can't confidently describe — the raw cron
/// expression is shown verbatim in those cases.
enum CronExpression {
    static func readable(_ expression: String) -> String? {
        var parts = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        // Strip a leading seconds field so 6-field cron behaves like 5-field.
        if parts.count == 6 { parts.removeFirst() }
        guard parts.count == 5 else { return nil }

        let minute = parts[0]
        let hour = parts[1]
        let day = parts[2]
        let month = parts[3]
        let weekday = parts[4]

        // Every N minutes
        if let n = stepValue(minute), hour == "*", day == "*", month == "*", weekday == "*" {
            return n == 1 ? "Every minute" : "Every \(n) minutes"
        }
        // Every N hours, on the hour
        if minute == "0", let n = stepValue(hour), day == "*", month == "*", weekday == "*" {
            return n == 1 ? "Every hour" : "Every \(n) hours"
        }
        // Every N days at midnight
        if minute == "0", hour == "0", let n = stepValue(day), month == "*", weekday == "*" {
            return n == 1 ? "Daily at midnight" : "Every \(n) days at midnight"
        }
        // Daily at HH:00
        if minute == "0", let h = Int(hour), day == "*", month == "*", weekday == "*" {
            return "Daily at \(formatHour(h)):00"
        }
        return nil
    }

    private static func stepValue(_ field: String) -> Int? {
        guard field.hasPrefix("*/") else { return nil }
        return Int(field.dropFirst(2))
    }

    private static func formatHour(_ hour: Int) -> String {
        let clamped = max(0, min(23, hour))
        return String(format: "%02d", clamped)
    }
}
