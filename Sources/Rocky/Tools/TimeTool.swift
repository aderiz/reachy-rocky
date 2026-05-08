import Foundation
import Cognition

/// Tells Rocky what day, date, and time it is. Local LLMs don't have
/// a reliable sense of "now" — they default to whatever date is in
/// their training data and confidently lie about it. Wiring an
/// explicit tool means questions like "what's today?" or "is it the
/// weekend?" route through the system clock, not vibes.
///
/// Returns ISO-8601, a human-readable date, the day of the week, and
/// a coarse time-of-day bucket the persona prompt can use to vary
/// tone ("morning" / "afternoon" / "evening" / "night").
enum TimeTool {
    // Static formatters — initialised once and reused across calls.
    // The pattern strings never change, so building a fresh
    // formatter per invocation was pure allocation churn.
    // ISO8601DateFormatter / DateFormatter are documented
    // thread-safe for read-only use on macOS 10.9+, but neither is
    // Sendable in Swift 6 strict mode — `nonisolated(unsafe)` is
    // the right escape hatch given the actual runtime contract.
    private nonisolated(unsafe) static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()
    private nonisolated(unsafe) static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private nonisolated(unsafe) static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f
    }()

    static func register(in registry: ToolRegistry) async {
        await registry.register(
            name: "get_current_time",
            description: "Get the current local date and time. Use this whenever the user asks about today, this week, the day of the week, or anything else that depends on knowing 'now'. The local LLM does not know what day it is on its own.",
            handler: { _ in
                let now = Date()
                let cal = Calendar.current
                let tz = TimeZone.current
                let isoFmt = Self.isoFmt
                let dateFmt = Self.dateFmt
                let timeFmt = Self.timeFmt
                let dayFmt = Self.dayFmt

                let hour = cal.component(.hour, from: now)
                let timeOfDay: String
                switch hour {
                case 5..<12:  timeOfDay = "morning"
                case 12..<17: timeOfDay = "afternoon"
                case 17..<21: timeOfDay = "evening"
                default:      timeOfDay = "night"
                }

                return .object([
                    "iso":              .string(isoFmt.string(from: now)),
                    "date":             .string(dateFmt.string(from: now)),
                    "time":             .string(timeFmt.string(from: now)),
                    "day_of_week":      .string(dayFmt.string(from: now)),
                    "time_of_day":      .string(timeOfDay),
                    "timezone":         .string(tz.identifier),
                    "tz_offset_minutes": .number(Double(tz.secondsFromGMT() / 60)),
                ])
            }
        )
    }
}
