import Foundation

struct Settings {
    var dayStartHour = 9.0, dayEndHour = 22.0   // sessions only inside this window
    var maxPerDayHours = 4.0                    // per assignment
}

/// What the hours are for: `.study` = preparing for a quiz or exam, `.complete` = producing the work itself.
enum TaskKind: String, Codable {
    case study, complete

    var verb: String { self == .study ? "study" : "complete" }
    var badge: String { self == .study ? "Study" : "Assignment" }

    // "final" alone means the exam; "final project" is caught by the assignment words first.
    private static let completeWords = ["project", "paper", "essay", "report", "lab", "homework", "hw", "assignment",
                                        "presentation", "discussion", "reading", "evaluation", "survey", "setup", "invitation", "activity", "wrap-up"]
    private static let studyWords = ["quiz", "exam", "midterm", "test", "final"]

    static func guess(_ title: String) -> TaskKind {
        let t = title.lowercased()
        if completeWords.contains(where: t.contains) { return .complete }
        return studyWords.contains(where: t.contains) ? .study : .complete
    }
}

/// Per-assignment edits; nil falls back to the keyword estimate / global buffer / guessed kind.
struct Override: Codable, Equatable {
    var hours: Double?
    var bufferDays: Double?
    var kind: TaskKind?
}

/// Per-course tweaks (paid). nil falls back to the global value.
struct CourseSetting: Codable, Equatable {
    var bufferDays: Double?
    var hoursScale: Double?      // multiplies the estimated hours, e.g. 1.5 for a course that always runs long
}

/// How long a finished task really took, against the keyword estimate it was planned from.
struct Outcome: Codable, Equatable {
    var key: String
    var base: Double
    var actual: Double
}

struct Plan: Identifiable {
    var assignment: Assignment
    var hours: Double
    var sessions: [DateInterval]   // chronological
    var shortfall: Double          // hours that didn't fit before the deadline
    var bufferDays: Double
    var kind: TaskKind = .complete
    var intoBuffer = false         // some sessions had to run inside the buffer window
    var id: String { assignment.id }
    var start: Date? { sessions.first?.start }
}

struct DayLoad: Identifiable {
    var day: Date
    var hours: Double
    var short: Bool        // a plan that doesn't fully fit has work (or its deadline) on this day
    var id: Date { day }
}

enum Planner {
    // ponytail: keyword guess (editable per assignment in the UI); replace with learned per-user times if it proves too coarse.
    static let keywordHours: [(String, Double)] = [
        ("evaluation", 0.5), ("survey", 0.5), ("invitation", 0.5), ("setup", 0.5),
        ("final", 12), ("exam", 10), ("midterm", 10), ("project", 10), ("paper", 8), ("essay", 6),
        ("report", 6), ("lab", 4), ("presentation", 5), ("homework", 2), ("hw", 2), ("quiz", 2), ("reading", 2),
    ]
    static let defaultHours = 3.0
    static let maxSession = 2.0 * 3600, minSession = 30.0 * 60

    static func estimate(_ title: String) -> Double { estimateInfo(title).hours }

    /// The keyword that matched (or "default") and its base hours.
    static func estimateInfo(_ title: String) -> (key: String, hours: Double) {
        let t = title.lowercased()
        if let m = keywordHours.first(where: { t.contains($0.0) }) { return (m.0, m.1) }
        return ("default", defaultHours)
    }

    /// Per-keyword scale from finished tasks: total actual / total estimated, once a keyword has 2+ samples.
    /// Clamped so a couple of odd outliers can't make a plan absurd.
    static func learnedScales(_ outcomes: [Outcome]) -> [String: Double] {
        Dictionary(grouping: outcomes, by: \.key).compactMapValues { rows in
            guard rows.count >= 2 else { return nil }
            let base = rows.reduce(0) { $0 + $1.base }
            return base > 0 ? min(2.5, max(0.5, rows.reduce(0) { $0 + $1.actual } / base)) : nil
        }
    }

    /// Number of planned sessions that overlap any of `busy` (the user's calendar events).
    static func conflicts(_ plans: [Plan], busy: [BusyEvent], calendar cal: Calendar = .current) -> (sessions: Int, events: Int) {
        guard let end = plans.flatMap(\.sessions).map(\.end).max() else { return (0, 0) }
        let occ = busy.flatMap { e in e.occurrences(in: DateInterval(start: .distantPast, end: end), calendar: cal).map { (e, $0) } }
        var hitEvents = Set<Int>(), hitSessions = 0
        for s in plans.flatMap(\.sessions) {
            var hit = false
            for (i, o) in occ.enumerated() where o.1.intersection(with: s).map({ $0.duration > 0 }) ?? false { hit = true; hitEvents.insert(i) }
            if hit { hitSessions += 1 }
        }
        return (hitSessions, hitEvents.count)
    }

    /// Schedules upcoming tasks (study before assignments, then earliest due first) into free time, filling backwards from
    /// (due - buffer) so work lands just-in-time but never overlaps classes or other sessions.
    /// Whatever doesn't fit before the buffer spills into the buffer window, then counts as shortfall.
    /// ponytail: greedy; per-assignment daily cap only, no breaks or cross-assignment daily limit.
    static func plans(_ items: [Assignment], busy: [BusyEvent], bufferDays: Double, settings: Settings = Settings(),
                      overrides: [String: Override] = [:], courses: [String: CourseSetting] = [:], learned: [String: Double] = [:],
                      now: Date = .now, calendar cal: Calendar = .current) -> [Plan] {
        func kindOf(_ a: Assignment) -> TaskKind { overrides[a.id]?.kind ?? TaskKind.guess(a.title) }
        // Study is scheduled first, so when study and an assignment compete for the same free time, study gets it.
        let upcoming = items.filter { $0.due > now }.sorted {
            let (k0, k1) = (kindOf($0) == .study, kindOf($1) == .study)
            return k0 != k1 ? k0 : $0.due < $1.due
        }
        guard let last = upcoming.last else { return [] }
        let horizon = DateInterval(start: now, end: last.due)
        var taken = busy.flatMap { $0.occurrences(in: horizon, calendar: cal) }
        var result: [Plan] = []
        for a in upcoming {
            let o = overrides[a.id]
            let course = a.course.flatMap { courses[$0] }
            let info = estimateInfo(a.title)
            let scaled = info.hours * (course?.hoursScale ?? 1) * (learned[info.key] ?? 1)
            let hours = o?.hours ?? max(0.5, (scaled * 2).rounded() / 2)   // nearest half hour
            let buffer = o?.bufferDays ?? course?.bufferDays ?? bufferDays
            var need = hours * 3600
            let deadline = a.due.addingTimeInterval(-buffer * 86400)
            var sessions: [DateInterval] = []
            var perDay: [Date: TimeInterval] = [:]
            // Fill inside [from, to]. Backward = just-in-time (latest slots first); forward = as early as possible.
            func fill(_ from: Date, _ to: Date, forward: Bool) {
                guard from < to else { return }
                var gaps = freeGaps(from: from, to: to, taken: taken + sessions, settings: settings, calendar: cal)
                while need >= minSession, !gaps.isEmpty {
                    let g = forward ? gaps.removeFirst() : gaps.removeLast()
                    let day = cal.startOfDay(for: g.start)
                    let len = min(g.duration, need, maxSession, settings.maxPerDayHours * 3600 - perDay[day, default: 0])
                    if len < minSession { continue }
                    perDay[day, default: 0] += len
                    let used = forward ? DateInterval(start: g.start, duration: len) : DateInterval(start: g.end.addingTimeInterval(-len), duration: len)
                    sessions.append(used)
                    need -= len
                    let rest = forward ? DateInterval(start: used.end, end: g.end) : DateInterval(start: g.start, end: used.start)
                    if rest.duration >= minSession { forward ? gaps.insert(rest, at: 0) : gaps.append(rest) }
                }
            }
            fill(now, deadline, forward: false)
            // Safety margin is a preference: when work doesn't fit before it, start now and finish as early as possible,
            // so as little of the margin as possible is used.
            fill(max(now, deadline), a.due, forward: true)
            let intoBuffer = sessions.contains { $0.end > deadline }
            taken += sessions
            result.append(Plan(assignment: a, hours: hours, sessions: merged(sessions), shortfall: need / 3600, bufferDays: buffer, kind: kindOf(a), intoBuffer: intoBuffer))
        }
        return result.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    /// Planned hours per day for `days` days starting today, for the week chart.
    static func dailyLoad(_ plans: [Plan], days: Int = 7, now: Date = .now, calendar cal: Calendar = .current) -> [DayLoad] {
        let today = cal.startOfDay(for: now)
        return (0..<days).map { i in
            let day = cal.date(byAdding: .day, value: i, to: today)!
            let sessions = plans.flatMap { p in p.sessions.map { (p, $0) } }.filter { cal.isDate($0.1.start, inSameDayAs: day) }
            let hours = sessions.reduce(0) { $0 + $1.1.duration } / 3600
            let short = plans.contains { p in
                p.shortfall > 0 && (p.sessions.isEmpty ? cal.isDate(p.assignment.due, inSameDayAs: day)
                                                       : p.sessions.contains { cal.isDate($0.start, inSameDayAs: day) })
            }
            return DayLoad(day: day, hours: hours, short: short)
        }
    }

    /// Every session that starts on `day`, with its plan, in time order.
    static func sessions(on day: Date, in plans: [Plan], calendar cal: Calendar = .current) -> [(plan: Plan, session: DateInterval)] {
        plans.flatMap { p in p.sessions.map { (plan: p, session: $0) } }
            .filter { cal.isDate($0.session.start, inSameDayAs: day) }
            .sorted { $0.session.start < $1.session.start }
    }

    /// Chronological, with back-to-back sessions joined.
    static func merged(_ s: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for i in s.sorted(by: { $0.start < $1.start }) {
            if let l = out.last, l.end == i.start { out[out.count - 1] = DateInterval(start: l.start, end: i.end) } else { out.append(i) }
        }
        return out
    }

    /// Free intervals inside each day's working window, minus `taken`. Chronological.
    static func freeGaps(from: Date, to: Date, taken: [DateInterval], settings: Settings = Settings(), calendar cal: Calendar) -> [DateInterval] {
        var out: [DateInterval] = []
        var day = cal.startOfDay(for: from)
        while day < to {
            let ws = max(day.addingTimeInterval(settings.dayStartHour * 3600), from)
            let we = min(day.addingTimeInterval(settings.dayEndHour * 3600), to)
            if ws < we {
                var cursor = ws
                for t in taken.sorted(by: { $0.start < $1.start }) where t.end > cursor && t.start < we {
                    if t.start > cursor { out.append(DateInterval(start: cursor, end: t.start)) }
                    cursor = max(cursor, t.end)
                }
                if cursor < we { out.append(DateInterval(start: cursor, end: we)) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out.filter { $0.duration >= minSession }
    }
}
