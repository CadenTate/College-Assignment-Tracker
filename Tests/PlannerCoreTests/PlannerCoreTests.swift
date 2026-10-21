import XCTest
@testable import PlannerCore

final class PlannerCoreTests: XCTestCase {
    var cal = Calendar(identifier: .gregorian)
    override func setUp() { cal.timeZone = TimeZone(identifier: "UTC")! }
    func d(_ s: String) -> Date { ICS.parseDate(s, [:])! }

    let ics = """
    BEGIN:VCALENDAR\r
    BEGIN:VEVENT\r
    UID:a1\r
    SUMMARY:Essay 2 [CS101-001]\r
    DTSTART:20261020T235900Z\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:a2\r
    SUMMARY:Quiz\\, ch. 3\r
    DTSTART;VALUE=DATE:20261101\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:c1\r
    SUMMARY:Biology lecture\r
    DTSTART:20261019T140000Z\r
    DTEND:20261019T153000Z\r
    RRULE:FREQ=WEEKLY;BYDAY=MO,WE\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    func testParseSplitsAssignmentsFromClasses() {
        let p = ICS.parse(ics)
        XCTAssertEqual(p.assignments.count, 2)
        XCTAssertEqual(p.busy.count, 1)
        XCTAssertEqual(p.assignments[0].title, "Essay 2")
        XCTAssertEqual(p.assignments[0].course, "CS101-001")
        XCTAssertEqual(p.assignments[1].title, "Quiz, ch. 3")
    }

    func testWeeklyOccurrences() {
        let b = ICS.parse(ics).busy[0]
        let occ = b.occurrences(in: DateInterval(start: d("20261019T000000Z"), end: d("20261026T000000Z")), calendar: cal)
        XCTAssertEqual(occ.map(\.start), [d("20261019T140000Z"), d("20261021T140000Z")]) // Mon, Wed
    }

    func testSessionsAvoidClassesAndFitDeadline() {
        let p = ICS.parse(ics)
        let now = d("20261019T000000Z")
        let plans = Planner.plans(p.assignments, busy: p.busy, bufferDays: 0, now: now, calendar: cal)
        let essay = plans.first { $0.assignment.title == "Essay 2" }!
        XCTAssertEqual(essay.sessions.reduce(0) { $0 + $1.duration }, 6 * 3600)
        XCTAssertEqual(essay.shortfall, 0)
        let classes = p.busy[0].occurrences(in: DateInterval(start: now, end: essay.assignment.due), calendar: cal)
        for s in essay.sessions {
            XCTAssertLessThanOrEqual(s.end, essay.assignment.due.addingTimeInterval(0))
            XCTAssertTrue(classes.allSatisfy { !$0.intersects(s) || $0.intersection(with: s)!.duration == 0 })
        }
    }

    func testShortfallWhenNoTime() {
        let a = Assignment(id: "x", title: "Final project", due: d("20261019T060000Z"), course: nil)
        let plans = Planner.plans([a], busy: [], bufferDays: 0, now: d("20261019T000000Z"), calendar: cal)
        XCTAssertEqual(plans[0].shortfall, 12) // due before the 09:00 working window opens
    }

    func testDailyCap() {
        let a = Assignment(id: "m", title: "Midterm", due: d("20261024T230000Z"), course: nil)
        let p = Planner.plans([a], busy: [], bufferDays: 0, now: d("20261019T000000Z"), calendar: cal)[0]
        for day in Set(p.sessions.map { cal.startOfDay(for: $0.start) }) {
            let h = p.sessions.filter { cal.startOfDay(for: $0.start) == day }.reduce(0) { $0 + $1.duration }
            XCTAssertLessThanOrEqual(h, 4 * 3600)
        }
        XCTAssertEqual(p.shortfall, 0)
    }

    func testReminders() {
        let a = Assignment(id: "h", title: "Homework 1", due: d("20261022T230000Z"), course: nil)
        let now = d("20261019T000000Z")
        let plans = Planner.plans([a], busy: [], bufferDays: 0, now: now, calendar: cal)
        let r = Reminders.build(plans, now: now, calendar: cal)
        let sessions = plans[0].sessions
        XCTAssertEqual(r.filter { $0.id.hasPrefix("s-") }.map(\.date), sessions.map(\.start))
        XCTAssertTrue(r.contains { $0.id.hasPrefix("d-") && $0.date == cal.startOfDay(for: sessions[0].start).addingTimeInterval(8 * 3600) })
        XCTAssertEqual(r.map(\.date), r.map(\.date).sorted())
    }

    func testOverridesAndSettings() {
        let a = Assignment(id: "h", title: "Homework 1", due: d("20261022T230000Z"), course: nil)
        let now = d("20261019T000000Z")
        let p = Planner.plans([a], busy: [], bufferDays: 0, settings: Settings(dayStartHour: 12, dayEndHour: 14, maxPerDayHours: 1),
                              overrides: ["h": Override(hours: 3, bufferDays: 1)], now: now, calendar: cal)[0]
        XCTAssertEqual(p.hours, 3)
        XCTAssertEqual(p.bufferDays, 1)
        XCTAssertEqual(p.sessions.reduce(0) { $0 + $1.duration }, 3 * 3600)
        XCTAssertTrue(p.sessions.allSatisfy { $0.start >= d("20261019T120000Z") && $0.duration <= 3600 })
        XCTAssertLessThanOrEqual(p.sessions.last!.end, d("20261021T230000Z")) // 1-day buffer
    }

    func testCanvasFeed() {
        let feed = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        UID:event-assignment-1\r
        DTSTART:20261023T045900Z\r
        DTEND:20261023T045900Z\r
        SUMMARY:Lab 4: Where Does it\r
          Live? [CS-3743-902-202710]\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:event-calendar-event-2\r
        DTSTART:20261021T230000Z\r
        DTEND:20261022T001500Z\r
        SUMMARY:CS-3423 (Class Zoom) [CS-3423-903-202710]\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:event-assignment-3\r
        DTSTART:20261023T050000Z\r
        DTEND:20261023T060000Z\r
        SUMMARY:Long assignment [CS-1]\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:event-calendar-event-4\r
        DTSTART;VALUE=DATE:20261105\r
        SUMMARY:Course Evaluation [CS-1]\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let p = ICS.parse(feed)
        XCTAssertEqual(p.assignments.map(\.title), ["Lab 4: Where Does it Live?", "Long assignment", "Course Evaluation"])
        XCTAssertEqual(p.assignments[0].course, "CS-3743-902")
        XCTAssertEqual(p.busy.count, 1)
        XCTAssertEqual(Planner.estimate("Course Evaluation"), 0.5)
    }

    func testSpillsIntoBuffer() {
        // Due tomorrow 23:00 with a 2-day buffer: the buffered window is already past, so work must use the buffer.
        let a = Assignment(id: "q", title: "Quiz", due: d("20261020T230000Z"), course: nil)
        let p = Planner.plans([a], busy: [], bufferDays: 2, now: d("20261019T000000Z"), calendar: cal)[0]
        XCTAssertEqual(p.shortfall, 0)
        XCTAssertTrue(p.intoBuffer)
        XCTAssertLessThanOrEqual(p.sessions.last!.end, a.due)
    }

    func testFeedURL() {
        XCTAssertEqual(FeedURL.normalize(" webcal://x.instructure.com/feeds/calendars/user_a.ics ")?.absoluteString,
                       "https://x.instructure.com/feeds/calendars/user_a.ics")
        XCTAssertNotNil(FeedURL.normalize("https://x.instructure.com/a.ics"))
        XCTAssertNil(FeedURL.normalize("file:///etc/passwd"))
        XCTAssertNil(FeedURL.normalize("http://x.com/a.ics"))
        XCTAssertNil(FeedURL.normalize("not a url"))
    }

    func testDailyLoad() {
        let now = d("20261019T000000Z")
        let a = Assignment(id: "m", title: "Midterm", due: d("20261019T230000Z"), course: nil) // 10h due today: can't fit
        let b = Assignment(id: "h", title: "Homework", due: d("20261022T230000Z"), course: nil)
        let plans = Planner.plans([a, b], busy: [], bufferDays: 0, now: now, calendar: cal)
        let load = Planner.dailyLoad(plans, days: 5, now: now, calendar: cal)
        XCTAssertEqual(load.count, 5)
        XCTAssertTrue(load[0].short)
        XCTAssertFalse(load[1].short)
        XCTAssertEqual(load.reduce(0) { $0 + $1.hours }, plans.flatMap(\.sessions).reduce(0) { $0 + $1.duration } / 3600)
    }

    func testSessionsOnDay() {
        let now = d("20261019T000000Z")
        let a = Assignment(id: "h", title: "Homework", due: d("20261022T230000Z"), course: nil)
        let plans = Planner.plans([a], busy: [], bufferDays: 0, now: now, calendar: cal)
        let day = cal.startOfDay(for: plans[0].sessions[0].start)
        let on = Planner.sessions(on: day, in: plans, calendar: cal)
        XCTAssertFalse(on.isEmpty)
        XCTAssertTrue(on.allSatisfy { cal.isDate($0.session.start, inSameDayAs: day) })
        XCTAssertTrue(Planner.sessions(on: d("20261201T000000Z"), in: plans, calendar: cal).isEmpty)
    }

    func testInsideMarginStartsNow() {
        // Due tomorrow evening with a 2-day margin: the margin is already gone, so work starts today, not the night before.
        let a = Assignment(id: "hw", title: "Homework", due: d("20261020T230000Z"), course: nil)
        let now = d("20261019T120000Z")
        let p = Planner.plans([a], busy: [], bufferDays: 2, now: now, calendar: cal)[0]
        XCTAssertTrue(cal.isDate(p.sessions[0].start, inSameDayAs: now))
        XCTAssertEqual(p.shortfall, 0)
        XCTAssertTrue(p.intoBuffer)
    }

    func testKindGuess() {
        XCTAssertEqual(TaskKind.guess("Quiz 11: Advanced ER Modeling"), .study)
        XCTAssertEqual(TaskKind.guess("EGR 1343-Midterm Exam"), .study)
        XCTAssertEqual(TaskKind.guess("Final Exam"), .study)
        XCTAssertEqual(TaskKind.guess("Final Project"), .complete)
        XCTAssertEqual(TaskKind.guess("HW4"), .complete)
        XCTAssertEqual(TaskKind.guess("Quiz 0 - Honorlock Setup"), .complete)
        XCTAssertEqual(TaskKind.guess("Course Evaluation"), .complete)
    }

    func testStudyWinsSharedTime() {
        // Only 9-11 is available today and both want it; the homework is due earlier but study is scheduled first.
        let hw = Assignment(id: "hw", title: "HW 3", due: d("20261019T220000Z"), course: nil)
        let quiz = Assignment(id: "q", title: "Quiz 3", due: d("20261019T230000Z"), course: nil)
        let plans = Planner.plans([hw, quiz], busy: [], bufferDays: 0, settings: Settings(dayStartHour: 9, dayEndHour: 11, maxPerDayHours: 8),
                                  now: d("20261019T000000Z"), calendar: cal)
        let q = plans.first { $0.id == "q" }!, h = plans.first { $0.id == "hw" }!
        XCTAssertEqual(q.kind, .study)
        XCTAssertEqual(q.shortfall, 0)
        XCTAssertEqual(h.shortfall, 2)
        // and a manual override flips it
        let flipped = Planner.plans([hw, quiz], busy: [], bufferDays: 0, settings: Settings(dayStartHour: 9, dayEndHour: 11, maxPerDayHours: 8),
                                    overrides: ["hw": Override(kind: .study), "q": Override(kind: .complete)], now: d("20261019T000000Z"), calendar: cal)
        XCTAssertEqual(flipped.first { $0.id == "hw" }!.shortfall, 0)
    }

    func testCourseSettingsAndLearning() {
        let a = Assignment(id: "q", title: "Quiz 1", due: d("20261030T230000Z"), course: "BIO-110")
        let now = d("20261019T000000Z")
        let base = Planner.plans([a], busy: [], bufferDays: 1, now: now, calendar: cal)[0]
        XCTAssertEqual(base.hours, 2)
        let c = Planner.plans([a], busy: [], bufferDays: 1, courses: ["BIO-110": CourseSetting(bufferDays: 3, hoursScale: 2)], now: now, calendar: cal)[0]
        XCTAssertEqual(c.hours, 4)
        XCTAssertEqual(c.bufferDays, 3)
        // an explicit per-assignment override beats the course
        let o = Planner.plans([a], busy: [], bufferDays: 1, overrides: ["q": Override(hours: 1, bufferDays: 0)],
                              courses: ["BIO-110": CourseSetting(bufferDays: 3, hoursScale: 2)], now: now, calendar: cal)[0]
        XCTAssertEqual(o.hours, 1); XCTAssertEqual(o.bufferDays, 0)
        // learning needs 2 samples, then scales that keyword
        XCTAssertTrue(Planner.learnedScales([Outcome(key: "quiz", base: 2, actual: 4)]).isEmpty)
        let learned = Planner.learnedScales([Outcome(key: "quiz", base: 2, actual: 3), Outcome(key: "quiz", base: 2, actual: 5)])
        XCTAssertEqual(learned["quiz"], 2.0)
        let l = Planner.plans([a], busy: [], bufferDays: 1, learned: learned, now: now, calendar: cal)[0]
        XCTAssertEqual(l.hours, 4)
        XCTAssertEqual(Planner.learnedScales([Outcome(key: "x", base: 1, actual: 20), Outcome(key: "x", base: 1, actual: 20)])["x"], 2.5)
    }

    func testConflictCount() {
        let a = Assignment(id: "h", title: "Homework", due: d("20261022T230000Z"), course: nil)
        let now = d("20261019T000000Z")
        let plans = Planner.plans([a], busy: [], bufferDays: 0, now: now, calendar: cal)
        let s = plans[0].sessions[0]
        let ev = BusyEvent(title: "Shift", start: s.start.addingTimeInterval(600), end: s.start.addingTimeInterval(1800), rrule: nil)
        let far = BusyEvent(title: "Later", start: d("20270101T100000Z"), end: d("20270101T110000Z"), rrule: nil)
        let r = Planner.conflicts(plans, busy: [ev, far], calendar: cal)
        XCTAssertEqual(r.sessions, 1); XCTAssertEqual(r.events, 1)
        XCTAssertEqual(Planner.conflicts(plans, busy: [], calendar: cal).sessions, 0)
    }

    func testCancelledClassDates() {
        let feed = """
        BEGIN:VCALENDAR\r
        BEGIN:VEVENT\r
        UID:event-calendar-event-9\r
        SUMMARY:Lecture\r
        DTSTART:20261019T140000Z\r
        DTEND:20261019T153000Z\r
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR\r
        EXDATE:20261021T140000Z\r
        EXDATE;VALUE=DATE:20261023\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let b = ICS.parse(feed).busy[0]
        XCTAssertEqual(b.exdates.count, 1); XCTAssertEqual(b.exdays.count, 1)
        // Date-only EXDATEs are read in the local time zone, so use the local calendar here, as the app does.
        let occ = b.occurrences(in: DateInterval(start: d("20261018T000000Z"), end: d("20261025T000000Z")), calendar: .current)
        XCTAssertEqual(occ.map(\.start), [d("20261019T140000Z")])   // Wed and Fri cancelled
    }

    func testSampleDataParses() {
        let p = ICS.parse(SampleData.ics(now: d("20261019T090000Z"), calendar: cal))
        XCTAssertEqual(p.assignments.count, 6)
        XCTAssertEqual(p.busy.count, 1)
        XCTAssertTrue(p.assignments.contains { TaskKind.guess($0.title) == .study })
        XCTAssertTrue(p.assignments.contains { TaskKind.guess($0.title) == .complete })
    }
}
