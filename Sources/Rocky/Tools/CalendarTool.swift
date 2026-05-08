import Foundation
import EventKit
import Cognition

/// Read-only window into the Mac's Calendar database (iCloud, local,
/// Google-via-the-Calendar-app, etc — anything EventKit knows about).
/// First call triggers the system TCC prompt; the user has to grant
/// "Full Calendar Access" once and Rocky remembers it after that.
///
/// Args:
///   - `days_ahead` (int, default 7, max 30) — how far forward to look.
///     Pass `0` for "today only", `1` for "today + tomorrow", etc.
///   - `start_iso` (string, optional) — overrides the start date if
///     the LLM wants a specific day; format must be ISO-8601 like
///     `2026-05-12T00:00:00Z`.
///
/// Returns `{events: [{title, start, end, all_day, location, calendar}],
/// source: "eventkit", count: N}` or `{error: "..."}` if access is
/// denied or the request is malformed. The LLM gets enough to answer
/// "what's on tomorrow?" without us shipping the full event payload.
enum CalendarTool {
    /// One shared store across calls — EventKit itself is thread-safe
    /// for reads and the access grant is per-process, so a single
    /// instance avoids re-prompting on every invocation. Pinned to
    /// MainActor because EKEventStore predates Sendable; all our
    /// access already happens via async handlers, so the actor hop
    /// is free.
    @MainActor private static let store = EKEventStore()

    static func register(in registry: ToolRegistry) async {
        await registry.register(
            name: "read_calendar",
            description: "Read upcoming events from the Mac's Calendar app. Use this for questions about the user's schedule, meetings, what's on today / tomorrow / this week. Read-only — Rocky cannot create or modify events. First call may prompt the user for Calendar permission.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "days_ahead": .object([
                        "type": .string("integer"),
                        "description": .string("Days from start_iso (or now) to include. 0 = today only, 7 = next week (default), max 30."),
                    ]),
                    "start_iso": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO-8601 start; defaults to today at 00:00 local."),
                    ]),
                ]),
            ]),
            handler: { args in
                let days = max(0, min(30, Int(args.asObject?["days_ahead"]?.asNumber ?? 7)))
                let startISO = args.asObject?["start_iso"]?.asString
                return await readEvents(days: days, startISO: startISO)
            }
        )
    }

    @MainActor
    private static func readEvents(days: Int, startISO: String?) async -> JSONValue {
        do {
            try await ensureAuthorized()
        } catch {
            return .object(["error": .string("\(error)")])
        }

        let cal = Calendar.current
        let start: Date = {
            if let s = startISO,
               let parsed = ISO8601DateFormatter().date(from: s) {
                return parsed
            }
            return cal.startOfDay(for: Date())
        }()
        // `days_ahead = 0` means "rest of today" → end at start-of-tomorrow.
        let end = cal.date(byAdding: .day, value: max(1, days), to: start)
                  ?? start.addingTimeInterval(86_400)

        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: nil
        )
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let mapped = events.map { ev -> JSONValue in
            .object([
                "title":    .string(ev.title ?? ""),
                "start":    .string(isoFmt.string(from: ev.startDate)),
                "end":      .string(isoFmt.string(from: ev.endDate)),
                "all_day":  .bool(ev.isAllDay),
                "location": .string(ev.location ?? ""),
                "calendar": .string(ev.calendar?.title ?? ""),
            ])
        }
        return .object([
            "source": .string("eventkit"),
            "start":  .string(isoFmt.string(from: start)),
            "end":    .string(isoFmt.string(from: end)),
            "count":  .number(Double(mapped.count)),
            "events": .array(mapped),
        ])
    }

    /// Block until we either have access or know we don't. macOS 14+
    /// uses `requestFullAccessToEvents`; older split read/write APIs
    /// are out of scope (Rocky targets macOS 15).
    @MainActor
    private static func ensureAuthorized() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .denied, .restricted, .writeOnly:
            throw CalendarError.denied
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            if !granted { throw CalendarError.denied }
        @unknown default:
            throw CalendarError.denied
        }
    }
}

enum CalendarError: Error, CustomStringConvertible {
    case denied
    var description: String {
        switch self {
        case .denied:
            return "Calendar access denied. Open System Settings → Privacy & Security → Calendars and turn Rocky on."
        }
    }
}
