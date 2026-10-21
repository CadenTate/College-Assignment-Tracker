import Foundation

struct Assignment: Identifiable, Hashable {
    var id: String
    var title: String
    var due: Date
    var course: String?
}

/// A timed event (class, lecture) that work sessions must avoid.
struct BusyEvent: Hashable {
    var title: String
    var start: Date
    var end: Date
    var rrule: String?
    var exdates: [Date] = []     // cancelled occurrences with a time
    var exdays: [Date] = []      // cancelled occurrences given as a whole day (start of day)

    /// Occurrences overlapping `range`. ponytail: DAILY/WEEKLY only, ignores EXDATE; add MONTHLY/EXDATE if feeds need it.
    func occurrences(in range: DateInterval, calendar cal: Calendar = .current) -> [DateInterval] {
        let len = end.timeIntervalSince(start)
        guard let rrule else {
            let i = DateInterval(start: start, duration: len)
            return i.intersects(range) ? [i] : []
        }
        var r: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
        }
        let interval = max(Int(r["INTERVAL"] ?? "1") ?? 1, 1)
        let freq = r["FREQ"]
        guard freq == "DAILY" || freq == "WEEKLY" else { return [] }
        let until = r["UNTIL"].flatMap { ICS.parseDate($0, [:]) }
        let count = r["COUNT"].flatMap { Int($0) }
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let days = r["BYDAY"].map { $0.split(separator: ",").compactMap { codes.firstIndex(of: String($0.suffix(2))).map { $0 + 1 } } }
            ?? [cal.component(.weekday, from: start)]
        let weekStart = cal.dateInterval(of: .weekOfYear, for: start)!.start
        let startDay = cal.startOfDay(for: start)
        let time = start.timeIntervalSince(startDay)
        var out: [DateInterval] = [], n = 0
        var day = startDay
        while day < range.end, out.count < 500 {
            let k = cal.dateComponents([.day], from: freq == "DAILY" ? startDay : weekStart, to: day).day!
            let hit = freq == "DAILY" ? k % interval == 0
                : (k / 7) % interval == 0 && days.contains(cal.component(.weekday, from: day))
            if hit {
                let s = day.addingTimeInterval(time)
                if let until, s > until { break }
                n += 1
                if let count, n > count { break }
                // A cancelled occurrence still counts toward COUNT, but is not busy time.
                let cancelled = exdates.contains { abs($0.timeIntervalSince(s)) < 60 } || exdays.contains(cal.startOfDay(for: s))
                let i = DateInterval(start: s, duration: len)
                if !cancelled, i.intersects(range) { out.append(i) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }
}

struct Parsed {
    var assignments: [Assignment] = []
    var busy: [BusyEvent] = []
}

enum ICS {
    /// Canvas marks them in the UID: "event-assignment-*" is a due date, "event-calendar-event-*" is a class/meeting.
    /// Otherwise: VTODOs, and VEVENTs shorter than 30 min with no recurrence, are assignments;
    /// longer or recurring VEVENTs are classes/busy time.
    static func parse(_ raw: String) -> Parsed {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var out = Parsed()
        var cur: [String: (params: [String: String], value: String)]?
        var isTodo = false
        for line in text.split(separator: "\n") {
            if line == "BEGIN:VEVENT" || line == "BEGIN:VTODO" { cur = [:]; isTodo = line == "BEGIN:VTODO"; continue }
            if line == "END:VEVENT" || line == "END:VTODO" {
                if let c = cur { add(c, isTodo, to: &out) }
                cur = nil; continue
            }
            guard cur != nil, let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].split(separator: ";", omittingEmptySubsequences: false)
            var params: [String: String] = [:]
            for p in head.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { params[String(kv[0]).uppercased()] = String(kv[1]) }
            }
            let key = String(head[0]).uppercased(), value = String(line[line.index(after: colon)...])
            if key == "EXDATE", let prev = cur?[key] { cur?[key] = (params, prev.value + "," + value) }   // EXDATE can repeat
            else { cur?[key] = (params, value) }
        }
        return out
    }

    private static func add(_ p: [String: (params: [String: String], value: String)], _ isTodo: Bool, to out: inout Parsed) {
        guard let d = p["DUE"] ?? p["DTSTART"], let due = parseDate(d.value, d.params) else { return }
        var title = unescape(p["SUMMARY"]?.value ?? "Untitled")
        let end = p["DTEND"].flatMap { parseDate($0.value, $0.params) }
        let uid = p["UID"]?.value ?? ""
        let looksBusy = p["RRULE"] != nil || (end.map { $0.timeIntervalSince(due) >= 30 * 60 } ?? false)
        let timed = end.map { $0 > due } ?? false   // all-day or end-less calendar events are deadlines, not busy time
        let isBusy = !uid.hasPrefix("event-assignment-") && (looksBusy || (uid.hasPrefix("event-calendar-event-") && timed))
        if !isTodo, p["DUE"] == nil, isBusy {
            var ev = BusyEvent(title: title, start: due, end: end ?? due.addingTimeInterval(3600), rrule: p["RRULE"]?.value)
            if let ex = p["EXDATE"] {
                for v in ex.value.split(separator: ",").map(String.init) {
                    if v.contains("T") { if let d = parseDate(v, ex.params) { ev.exdates.append(d) } }
                    else if let d = parseDate(v, ex.params) { ev.exdays.append(Calendar.current.startOfDay(for: d)) }
                }
            }
            out.busy.append(ev)
            return
        }
        var course: String?
        // Canvas style: "Essay 2 [CS101-001]"
        if title.hasSuffix("]"), let open = title.lastIndex(of: "[") {
            course = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
            // drop the 6-digit term suffix: "CS-3743-902-202710" -> "CS-3743-902"
            course = course?.replacingOccurrences(of: "-\\d{6}$", with: "", options: .regularExpression)
            title = title[..<open].trimmingCharacters(in: .whitespaces)
        }
        out.assignments.append(Assignment(id: p["UID"]?.value ?? "\(title)-\(due.timeIntervalSince1970)", title: title, due: due, course: course))
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func parseDate(_ v: String, _ params: [String: String]) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if v.hasSuffix("Z") { f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'" }
        else if v.contains("T") { f.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current; f.dateFormat = "yyyyMMdd'T'HHmmss" }
        else { // all-day: due at end of that day
            f.dateFormat = "yyyyMMdd"
            return f.date(from: v).map { Calendar.current.date(byAdding: .minute, value: 24 * 60 - 1, to: $0)! }
        }
        return f.date(from: v)
    }
}
