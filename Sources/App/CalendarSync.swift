import EventKit

enum CalendarSync {
    /// Where the user can grant calendar access after denying it.
    static var settingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #else
        URL(string: "app-settings:")
        #endif
    }

    static let calendarTitle = "Study Plan"

    struct Failure: LocalizedError { var errorDescription: String? }

    /// Replaces everything in the "Study Plan" calendar with the plans' future sessions.
    /// Only touches that calendar, never the user's own.
    static func sync(_ plans: [Plan]) async throws -> Int {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw Failure(errorDescription: "Calendar access denied. Enable it in Settings > Privacy > Calendars.")
        }
        let cal = try studyCalendar(store)
        let today = Calendar.current.startOfDay(for: .now)
        let old = store.predicateForEvents(withStart: today, end: today.addingTimeInterval(2 * 365 * 86400), calendars: [cal])
        for e in store.events(matching: old) { try store.remove(e, span: .thisEvent, commit: false) }
        var n = 0
        for p in plans {
            for s in p.sessions where s.end > .now {
                let e = EKEvent(eventStore: store)
                e.calendar = cal
                e.title = (p.kind == .study ? "Study for " : "Work on ") + p.assignment.title
                e.notes = "Due \(p.assignment.due.formatted(.dateTime.weekday().month().day().hour().minute()))"
                e.startDate = s.start
                e.endDate = s.end
                try store.save(e, span: .thisEvent, commit: false)
                n += 1
            }
        }
        try store.commit()
        return n
    }

    /// Timed events from the user's other calendars over the next `days`, for the planner to avoid.
    /// Skips all-day, "free", cancelled and declined events, and our own Study Plan calendar (no feedback loop).
    /// nil means calendar access wasn't granted.
    static func busy(days: Int = 60) async -> [BusyEvent]? {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        let cals = store.calendars(for: .event).filter { $0.title != calendarTitle }
        guard !cals.isEmpty else { return [] }
        let start = Date.now
        let pred = store.predicateForEvents(withStart: start, end: start.addingTimeInterval(Double(days) * 86400), calendars: cals)
        return store.events(matching: pred)
            .filter { e in
                !e.isAllDay && e.availability != .free && e.status != .canceled
                    && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .map { BusyEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate, rrule: nil) }
    }

    /// sync() as a user-facing status line.
    static func run(_ plans: [Plan]) async -> String {
        do { let n = try await sync(plans); return "Added \(n) session\(n == 1 ? "" : "s") to the \"\(calendarTitle)\" calendar." }
        catch { return error.localizedDescription }
    }

    private static func studyCalendar(_ store: EKEventStore) throws -> EKCalendar {
        if let c = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) { return c }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = calendarTitle
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw Failure(errorDescription: "No calendar account available.")
        }
        c.source = source
        try store.saveCalendar(c, commit: true)
        return c
    }
}
