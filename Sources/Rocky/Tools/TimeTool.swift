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
    static func register(in registry: ToolRegistry) async {
        await registry.register(
            name: "get_current_time",
            description: "Get the current local date and time. Use this whenever the user asks about today, this week, the day of the week, or anything else that depends on knowing 'now'. The local LLM does not know what day it is on its own.",
            handler: { _ in
                let now = Date()
                let cal = Calendar.current
                let tz = TimeZone.current
                let isoFmt = ISO8601DateFormatter()
                isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let dateFmt = DateFormatter()
                dateFmt.locale = Locale(identifier: "en_US_POSIX")
                dateFmt.dateFormat = "EEEE, d MMMM yyyy"
                let timeFmt = DateFormatter()
                timeFmt.locale = Locale(identifier: "en_US_POSIX")
                timeFmt.dateFormat = "HH:mm"
                let dayFmt = DateFormatter()
                dayFmt.locale = Locale(identifier: "en_US_POSIX")
                dayFmt.dateFormat = "EEEE"

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
