import Foundation

enum ArcaneDateFormatting {
    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(fromISO8601 value: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: value) ?? iso8601Plain.date(from: value)
    }

    static func formattedISO8601(
        _ value: String,
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle
    ) -> String {
        guard let date = date(fromISO8601: value) else { return value }
        return date.formatted(date: dateStyle, time: timeStyle)
    }

    static func formattedClockTime(fromISO8601 value: String) -> String? {
        guard let date = date(fromISO8601: value) else { return nil }
        return date.formatted(.dateTime.hour().minute().second())
    }
}
