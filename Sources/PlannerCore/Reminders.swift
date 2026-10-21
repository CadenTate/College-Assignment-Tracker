import Foundation

struct Reminder: Equatable {
    var id: String
    var date: Date
    var title: String
    var body: String
}

enum Reminders {
    static let digestHour = 8.0
    // iOS keeps at most 64 pending local notifications; stay under it.
    static let maxSessions = 50, digestDays = 7

    /// One reminder at each future session start, plus an 8am digest on each of the next days that has sessions.
    static func build(_ plans: [Plan], now: Date = .now, calendar cal: Calendar = .current) -> [Reminder] {
        let sessions = plans.flatMap { p in p.sessions.map { (p, $0) } }
            .filter { $0.1.start > now }.sorted { $0.1.start < $1.1.start }
        var out = sessions.prefix(maxSessions).map { p, s in
            Reminder(id: "s-\(p.id)-\(Int(s.start.timeIntervalSince1970))", date: s.start,
                     title: p.kind == .study ? "Time to study for \(p.assignment.title)" : "Time to work on \(p.assignment.title)",
                     body: "\(span(s)) · due \(p.assignment.due.formatted(.dateTime.weekday().month().day()))")
        }
        let today = cal.startOfDay(for: now)
        for i in 0..<digestDays {
            let day = cal.date(byAdding: .day, value: i, to: today)!
            let at = day.addingTimeInterval(digestHour * 3600)
            let todays = sessions.filter { cal.isDate($0.1.start, inSameDayAs: day) }
            guard at > now, !todays.isEmpty else { continue }
            out.append(Reminder(id: "d-\(Int(day.timeIntervalSince1970))", date: at,
                                title: "Today: \(todays.count) work session\(todays.count == 1 ? "" : "s")",
                                body: todays.map { "\($0.0.assignment.title) \(span($0.1))" }.joined(separator: "\n")))
        }
        return out.sorted { $0.date < $1.date }
    }

    private static func span(_ s: DateInterval) -> String {
        "\(s.start.formatted(.dateTime.hour().minute())) – \(s.end.formatted(.dateTime.hour().minute()))"
    }
}
