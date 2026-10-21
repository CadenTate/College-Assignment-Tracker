import Foundation

/// A small made-up semester, dated relative to today, so the app can be tried without a Canvas account.
enum SampleData {
    static func ics(now: Date = .now, calendar cal: Calendar = .current) -> String {
        func stamp(_ date: Date, hour: Int, minute: Int) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d%02d%02dT%02d%02d00", c.year!, c.month!, c.day!, hour, minute)
        }
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: now))! }
        var out = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Assignments//Sample//EN"]
        // A class that meets Mon/Wed/Fri: busy time the planner must avoid.
        out += ["BEGIN:VEVENT", "UID:event-calendar-event-sample-lecture",
                "SUMMARY:Intro to Biology (Lecture) [BIO-110-001]",
                "DTSTART:\(stamp(day(0), hour: 10, minute: 0))", "DTEND:\(stamp(day(0), hour: 10, minute: 50))",
                "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR", "END:VEVENT"]
        let items: [(String, Int, String)] = [
            ("HW 5", 2, "MATH-220-003"), ("Quiz 3", 3, "BIO-110-001"), ("Lab Report 2", 5, "BIO-110-001"),
            ("Midterm Exam", 6, "HIST-201-002"), ("Essay 2", 9, "ENG-101-004"), ("Final Project", 20, "ENG-101-004"),
        ]
        for (i, it) in items.enumerated() {
            let due = stamp(day(it.1), hour: 23, minute: 59)
            out += ["BEGIN:VEVENT", "UID:event-assignment-sample-\(i)", "SUMMARY:\(it.0) [\(it.2)]",
                    "DTSTART:\(due)", "DTEND:\(due)", "END:VEVENT"]
        }
        out.append("END:VCALENDAR")
        return out.joined(separator: "\r\n")
    }
}
