import EventKit
import SwiftUI
import Security
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("ics") private var raw = ""          // imported file text, re-parsed on launch
    @AppStorage("bufferDays") private var bufferDays = 1.0
    @AppStorage("dayStart") private var dayStart = 9.0
    @AppStorage("dayEnd") private var dayEnd = 22.0
    @AppStorage("maxPerDay") private var maxPerDay = 4.0
    @AppStorage("overrides") private var overridesJSON = "{}"
    @AppStorage("dismissed") private var dismissedJSON = "{}"   // assignment id -> "done" | "hidden"
    @AppStorage("autoSync") private var autoSync = false
    @AppStorage("syncStatus") private var syncStatus = ""
    @AppStorage("avoidCalendar") private var avoidCalendar = false
    @AppStorage("courses") private var coursesJSON = "{}"      // course -> CourseSetting (Pro)
    @AppStorage("outcomes") private var outcomesJSON = "[]"    // finished tasks' real hours (Pro)
    @EnvironmentObject private var pro: Pro
    @State private var finishing: Plan?
    @State private var calendarBusy: [BusyEvent] = []
    @State private var calendarStatus = ""
    @State private var selectedDay: Date?
    @State private var showHelp = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var feedStatus = ""
    @State private var picking = false
    @State private var showSettings = false
    @State private var editing: Plan?
    @State private var error: String?

    var settings: Settings { Settings(dayStartHour: dayStart, dayEndHour: dayEnd, maxPerDayHours: maxPerDay) }
    var overrides: [String: Override] {
        get { (try? JSONDecoder().decode([String: Override].self, from: Data(overridesJSON.utf8))) ?? [:] }
        nonmutating set { overridesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }
    var dismissed: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(dismissedJSON.utf8))) ?? [:] }
        nonmutating set { dismissedJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }
    var courses: [String: CourseSetting] {
        get { (try? JSONDecoder().decode([String: CourseSetting].self, from: Data(coursesJSON.utf8))) ?? [:] }
        nonmutating set { coursesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }
    var outcomes: [Outcome] {
        get { (try? JSONDecoder().decode([Outcome].self, from: Data(outcomesJSON.utf8))) ?? [] }
        nonmutating set { outcomesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }
    var courseNames: [String] { Array(Set(ICS.parse(raw).assignments.compactMap(\.course))).sorted() }
    var plans: [Plan] {
        let p = ICS.parse(raw), gone = dismissed
        // Pro features only apply while Pro is active, so a refund or restore on another device behaves.
        return Planner.plans(p.assignments.filter { gone[$0.id] == nil }, busy: p.busy + (pro.isPro ? calendarBusy : []), bufferDays: bufferDays,
                             settings: settings, overrides: overrides,
                             courses: pro.isPro ? courses : [:], learned: pro.isPro ? Planner.learnedScales(outcomes) : [:])
    }

    /// Free: done right away. Pro: ask how long it took, so estimates can learn.
    func markDone(_ p: Plan) {
        if pro.isPro { finishing = p } else { dismissed[p.id] = "done" }
    }
    var dismissedItems: [(Assignment, String)] {
        let gone = dismissed
        return ICS.parse(raw).assignments.filter { gone[$0.id] != nil && $0.due > .now }
            .sorted { $0.due < $1.due }.map { ($0, gone[$0.id]!) }
    }

    /// Reads the user's calendar events when "avoid my calendar" is on, so plans route around them.
    func refreshCalendar() async {
        guard avoidCalendar, pro.isPro else { calendarBusy = []; calendarStatus = ""; return }
        if let b = await CalendarSync.busy() {
            calendarBusy = b
            calendarStatus = "Avoiding \(b.count) event\(b.count == 1 ? "" : "s") from your other calendars in the next 60 days."
        } else {
            calendarBusy = []; avoidCalendar = false
            calendarStatus = "Calendar access is off. Allow it in Settings > Privacy > Calendars."
        }
    }

    /// Re-downloads the saved feed, if any. A failed refresh keeps the last good data.
    func refreshFeed() async {
        let all = Feed.links()
        guard !all.isEmpty else { feedStatus = ""; return }
        let links = pro.isPro ? all : Array(all.prefix(Feed.freeLimit))
        do {
            raw = try await Feed.fetchAll(links)
            feedStatus = "Updated \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch { feedStatus = "Refresh failed: \(error.localizedDescription)" }
    }

    var body: some View {
        NavigationStack {
            let all = plans
            let ps = selectedDay.map { d in all.filter { p in p.sessions.contains { Calendar.current.isDate($0.start, inSameDayAs: d) } } } ?? all
            layout(all, ps)
            .background(Theme.paper)
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 560)
            #endif
            .tint(Theme.slate)
            .task(id: scenePhase) { if scenePhase == .active { await refreshFeed() } }
            .task(id: "\(scenePhase)-\(avoidCalendar)-\(pro.isPro)") { if scenePhase == .active { await refreshCalendar() } }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await refreshCalendar() } }
            .task(id: "\(raw.hashValue)-\(bufferDays)-\(dayStart)-\(dayEnd)-\(maxPerDay)-\(overridesJSON)-\(dismissedJSON)-\(autoSync)-\(calendarBusy.hashValue)-\(pro.isPro)-\(coursesJSON)-\(outcomesJSON)") {
                let ps = plans
                WidgetBridge.publish(ps, pro: pro.isPro)
                await Notifier.schedule(Reminders.build(ps))
                if autoSync && pro.isPro { syncStatus = await CalendarSync.run(ps) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .labelStyle(.iconOnly).foregroundStyle(Theme.ink)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(dayStart: $dayStart, dayEnd: $dayEnd, maxPerDay: $maxPerDay, autoSync: $autoSync, avoidCalendar: $avoidCalendar, calendarStatus: calendarStatus, syncStatus: $syncStatus, feedStatus: $feedStatus, onFeedChange: refreshFeed, onImport: { later { picking = true } }, onSample: { raw = SampleData.ics(); showSettings = false }, onHelp: { later { showHelp = true } },
                             courses: Binding(get: { courses }, set: { courses = $0 }), courseNames: courseNames,
                             outcomeCount: outcomes.count, onResetLearning: { outcomes = [] }, plans: plans)
                    .environmentObject(pro)
            }
            .sheet(isPresented: $showHelp) { HelpView() }
            .sheet(item: $finishing) { p in
                FinishView(plan: p) { actual in
                    if let actual {
                        let info = Planner.estimateInfo(p.assignment.title)
                        outcomes = Array((outcomes + [Outcome(key: info.key, base: info.hours, actual: actual)]).suffix(200))
                    }
                    dismissed[p.id] = "done"
                }
            }
            .sheet(item: $editing) { p in
                EditView(plan: p, overrides: Binding(get: { overrides }, set: { overrides = $0 }))
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "ics") ?? .calendarEvent]) { result in
                do {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                    defer { url.stopAccessingSecurityScopedResource() }
                    raw = try String(contentsOf: url, encoding: .utf8)
                } catch { self.error = error.localizedDescription }
            }
            .alert("Import failed", isPresented: Binding(get: { error != nil }, set: { _ in error = nil })) { } message: { Text(error ?? "") }
        }
    }


    /// Wide windows (Mac, iPad landscape) get a sidebar of controls and charts beside the task list; narrow ones stack.
    private func layout(_ all: [Plan], _ ps: [Plan]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ScrollView {
                    header(all, wide: true).padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 330)
                Theme.hairline.frame(width: 1)
                taskList { rows(ps) }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .background(Theme.paper)
            }
            .frame(minWidth: 720)
            taskList {
                header(all, wide: false).padding(.top, 4).padding(.bottom, 12)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(rowInsets)
                rows(ps)
            }
        }
    }

    private func taskList<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        List { content() }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.paper)
    }

    @ViewBuilder private func header(_ all: [Plan], wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month().day())).font(.footnote).foregroundStyle(Theme.muted)
                        Text("Your week").display(34).foregroundStyle(Theme.ink)
                    }
                    HStack(spacing: 8) {
                        bufferChip
                        Button { showSettings = true } label: { Chip(text: "\(hourLabel(dayStart)) – \(hourLabel(dayEnd))") }.buttonStyle(.plain)
                    }
                    if !all.isEmpty { WeekChart(load: Planner.dailyLoad(all), selected: $selectedDay) }
                    if all.isEmpty { emptyState } else { DayInfo(day: selectedDay ?? (wide ? Calendar.current.startOfDay(for: .now) : nil), plans: all, canClear: selectedDay != nil, onClear: { selectedDay = nil }) }
                }
    }

    @ViewBuilder private func rows(_ ps: [Plan]) -> some View {
                ForEach(Array(ps.enumerated()), id: \.element.id) { i, p in
                    PlanRow(plan: p, edited: overrides[p.id] != nil, onDone: { markDone(p) })
                        .contentShape(Rectangle())
                        .onTapGesture { editing = p }
                        .swipeActions(edge: .trailing) {
                            Button("Done", systemImage: "checkmark") { markDone(p) }.tint(.green)
                            Button("Hide", systemImage: "eye.slash") { dismissed[p.id] = "hidden" }.tint(.gray)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = p }
                            Button("Mark done", systemImage: "checkmark") { markDone(p) }
                            Button("Hide", systemImage: "eye.slash") { dismissed[p.id] = "hidden" }
                        }
                        .overlay(alignment: .top) {
                            // Thicker line where the start day changes, so each day's work reads as a group.
                            let newDay = i > 0 && ps[i - 1].start.map { a in p.start.map { !Calendar.current.isDate(a, inSameDayAs: $0) } ?? true } ?? true
                            Theme.hairline.frame(height: newDay ? 2 : 0.5)
                        }
                        .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(rowInsets)
                }

                if !dismissedItems.isEmpty {
                    Text("Done and hidden · \(dismissedItems.count)").font(.footnote).foregroundStyle(Theme.muted)
                        .padding(.top, 20).listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(rowInsets)
                    ForEach(dismissedItems, id: \.0.id) { a, why in
                        Label(a.title, systemImage: why == "done" ? "checkmark.circle" : "eye.slash")
                            .foregroundStyle(Theme.muted).padding(.vertical, 10)
                            .swipeActions(edge: .trailing) {
                                Button("Restore", systemImage: "arrow.uturn.backward") { dismissed[a.id] = nil }.tint(Theme.slate)
                            }
                            .contextMenu { Button("Restore", systemImage: "arrow.uturn.backward") { dismissed[a.id] = nil } }
                            .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(rowInsets)
                    }
                }
    }

    /// Runs after the Settings sheet has finished closing, so a second sheet or picker can open.
    private func later(_ work: @escaping () -> Void) {
        showSettings = false
        Task { try? await Task.sleep(for: .milliseconds(450)); work() }
    }

    private let rowInsets = EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)

    private var bufferChip: some View {
        HStack(spacing: 10) {
            Button { bufferDays = max(0, bufferDays - 1) } label: { Image(systemName: "minus") }
            Text(bufferDays == 0 ? "No safety margin" : "Safety margin \(Int(bufferDays)) day\(bufferDays == 1 ? "" : "s")").monospacedDigit()
            Button { bufferDays = min(14, bufferDays + 1) } label: { Image(systemName: "plus") }
        }
        .font(.system(size: 12)).foregroundStyle(Theme.ink).buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.chip, in: Capsule())
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start your first plan").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Import a .ics file, or paste your Canvas feed link in Settings.").font(.subheadline).foregroundStyle(Theme.muted)
            HStack {
                Button("Import file") { picking = true }
                Button("Try sample data") { raw = SampleData.ics() }
            }
            .buttonStyle(.bordered).padding(.top, 4)
        }
        .padding(.top, 10)
    }

    private func hourLabel(_ h: Double) -> String {
        Calendar.current.date(bySettingHour: Int(h) % 24, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour())
    }
}

struct HelpView: View {
    private struct Entry: Identifiable { let id = UUID(); let icon: String; let title: String; let text: String }
    private let how = [
        Entry(icon: "doc.text", title: "It reads your due dates", text: "Import a .ics file or paste your Canvas feed link in Settings. Assignments become tasks; classes and meetings count as busy time."),
        Entry(icon: "book", title: "It tells study from assignments", text: "Quizzes and exams are marked Study: the hours are time to prepare. Everything else is an Assignment: the hours are time to do the work. When both want the same free time, study goes first. If it guesses wrong, tap the task and change its type."),
        Entry(icon: "clock", title: "It estimates the work", text: "Hours come from a guess based on the title (an exam is about 10 h, a quiz about 2 h). Tap any assignment to change its hours."),
        Entry(icon: "calendar", title: "It finds free time", text: "Study sessions are placed backward from each due date, inside your work window, never on top of classes or events in your calendar, and never more than your daily maximum."),
        Entry(icon: "shield", title: "It keeps a safety margin", text: "Work is planned to finish a few days before the due date, so a long estimate, a sick day or a failed upload doesn't make you late. If there isn't room, sessions spill into the margin and the row says so."),
    ]
    private let use = [
        Entry(icon: "chart.bar", title: "Tap a day in the chart", text: "See only what you need to do that day: its sessions, total hours and anything due. Tap again or choose Show all to clear."),
        Entry(icon: "pencil", title: "Tap an assignment", text: "Change its hours or safety margin for that assignment only."),
        Entry(icon: "hand.draw", title: "Swipe an assignment left", text: "Mark it done or hide it. Both stay listed at the bottom and can be restored."),
        Entry(icon: "bell", title: "Get reminded", text: "You're notified when each session starts, plus a morning summary. Turn on calendar sync in Settings to see sessions in the Calendar app."),
    ]

    var body: some View {
        SheetScaffold(title: "How it works") {
            group("The idea", how)
            group("Using it", use)
            VStack(alignment: .leading, spacing: 8) {
                Text("Reading the colors").font(.footnote).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 10) {
                    legend(Theme.slate, "Each course gets its own color. The bar shows how much of the work fits.")
                    legend(Theme.warn, "Red means the work can't all fit before the deadline. The row says how many hours are short.")
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("Estimates are guesses. If a plan looks too tight or too loose, adjust the hours or your safety margin. This app isn't affiliated with or endorsed by Instructure or Canvas.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .presentationDetents([.large])
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(c).frame(width: 10, height: 10).padding(.top, 5)
            Text(t).font(.system(size: 14)).foregroundStyle(Theme.ink)
        }
    }

    private func group(_ title: String, _ items: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { RowDivider() }
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: e.icon).font(.system(size: 16)).foregroundStyle(Theme.slate).frame(width: 22).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(.system(size: 16, weight: .semibold)).tracking(-0.2).foregroundStyle(Theme.ink)
                            Text(e.text).font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Shared look for the Settings and Edit sheets: paper background, bold title, rounded chip-colored groups.
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).display(28).foregroundStyle(Theme.ink)
                        if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    Button("Done") { dismiss() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.slate)
                }
                content
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 560, idealHeight: 680)
        #endif
        .background(Theme.paper).presentationBackground(Theme.paper).tint(Theme.slate)
    }
}

struct SheetSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote).foregroundStyle(Theme.muted)
            VStack(spacing: 0) { content }.background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
            if let footer { Text(footer).font(.system(size: 12)).foregroundStyle(Theme.muted) }
        }
    }
}

struct RowDivider: View {
    var body: some View { Theme.hairline.frame(height: 0.5).padding(.leading, 16) }
}

struct StepRow: View {
    let label: String
    let value: String
    let minus: () -> Void
    let plus: () -> Void

    private func round(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30).background(Theme.paper, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(symbol == "minus" ? "Decrease \(label)" : "Increase \(label)")
    }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 16)).foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 6) {
                round("minus", minus)
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink).frame(minWidth: 54)
                round("plus", plus)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ActionRow: View {
    let title: String
    var color: Color = Theme.slate
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 16)).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProTag: View {
    var body: some View {
        Text("Pro").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.slate)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.slate.opacity(0.15), in: Capsule())
    }
}

struct SettingsView: View {
    @Binding var dayStart: Double
    @Binding var dayEnd: Double
    @Binding var maxPerDay: Double
    @Binding var autoSync: Bool
    @Binding var avoidCalendar: Bool
    let calendarStatus: String
    @Binding var syncStatus: String
    @Binding var feedStatus: String
    let onFeedChange: () async -> Void
    let onImport: () -> Void
    let onSample: () -> Void
    let onHelp: () -> Void
    @Binding var courses: [String: CourseSetting]
    let courseNames: [String]
    let outcomeCount: Int
    let onResetLearning: () -> Void
    let plans: [Plan]
    @EnvironmentObject private var pro: Pro
    @State private var links = Feed.links()
    @State private var newLink = ""
    @State private var paywallReason: String?

    /// A Pro toggle: turning it on without Pro opens the paywall instead.
    private func gated(_ b: Binding<Bool>, _ reason: String) -> Binding<Bool> {
        Binding(get: { b.wrappedValue && pro.isPro },
                set: { on in if on && !pro.isPro { paywallReason = reason } else { b.wrappedValue = on } })
    }

    private func toggleRow(_ title: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) {
            HStack(spacing: 8) { Text(title); if !pro.isPro { ProTag() } }
        }
        .font(.system(size: 16)).tint(Theme.slate).padding(.horizontal, 16).padding(.vertical, 10)
    }

    var body: some View {
        SheetScaffold(title: "Settings") {
            SheetSection(title: "Get started") {
                ActionRow(title: "Import a .ics file", action: onImport)
                RowDivider()
                ActionRow(title: "Try sample data", action: onSample)
                RowDivider()
                ActionRow(title: "How it works", action: onHelp)
                #if DEBUG
                if pro.isPro {
                    RowDivider()
                    ActionRow(title: "Debug: switch Pro off", color: Theme.warn) { pro.debugToggle() }
                }
                #endif
            }
            SheetSection(title: "Work window", footer: "Study sessions are only placed inside these hours.") {
                StepRow(label: "Start", value: hour(dayStart),
                        minus: { dayStart = max(0, dayStart - 1) }, plus: { dayStart = min(dayEnd - 1, dayStart + 1) })
                RowDivider()
                StepRow(label: "End", value: hour(dayEnd),
                        minus: { dayEnd = max(dayStart + 1, dayEnd - 1) }, plus: { dayEnd = min(24, dayEnd + 1) })
            }
            SheetSection(title: "Pacing") {
                StepRow(label: "Max per day", value: "\(Int(maxPerDay)) h",
                        minus: { maxPerDay = max(1, maxPerDay - 1) }, plus: { maxPerDay = min(12, maxPerDay + 1) })
            }
            SheetSection(title: "Calendar", footer: calendarFooter) {
                toggleRow("Avoid my calendar events", gated($avoidCalendar, "Plan around work, clubs and appointments, not just classes."))
                RowDivider()
                toggleRow("Add study blocks to calendar", gated($autoSync, "Put your study blocks in Apple Calendar."))
                RowDivider()
                ActionRow(title: "Sync now") {
                    if pro.isPro { Task { syncStatus = await CalendarSync.run(plans) } } else { paywallReason = "Put your study blocks in Apple Calendar." }
                }
            }
            if pro.isPro {
                SheetSection(title: "Courses", footer: courseNames.isEmpty ? "Courses appear after you import a feed." : "Give a class more time, or a bigger safety margin. Per-assignment edits still win.") {
                    ForEach(Array(courseNames.enumerated()), id: \.element) { i, c in
                        if i > 0 { RowDivider() }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted).padding(.horizontal, 16).padding(.top, 12)
                            StepRow(label: "Estimates", value: "×\((courses[c]?.hoursScale ?? 1).formatted())",
                                    minus: { courses[c, default: CourseSetting()].hoursScale = max(0.5, (courses[c]?.hoursScale ?? 1) - 0.25) },
                                    plus: { courses[c, default: CourseSetting()].hoursScale = min(3, (courses[c]?.hoursScale ?? 1) + 0.25) })
                            StepRow(label: "Safety margin", value: courses[c]?.bufferDays.map { "\(Int($0)) d" } ?? "Default",
                                    minus: { courses[c, default: CourseSetting()].bufferDays = max(0, (courses[c]?.bufferDays ?? 1) - 1) },
                                    plus: { courses[c, default: CourseSetting()].bufferDays = min(14, (courses[c]?.bufferDays ?? 1) + 1) })
                        }
                    }
                }
                SheetSection(title: "Learning", footer: outcomeCount < 2 ? "When you finish a task you'll be asked how long it took. After a few, estimates adjust to your pace."
                             : "Estimates are adjusting to the \(outcomeCount) tasks you've finished.") {
                    ActionRow(title: "Reset what it learned", color: Theme.warn, action: onResetLearning)
                }
            }
            SheetSection(title: "Calendar feeds",
                         footer: feedStatus.isEmpty ? "Canvas > Calendar > Calendar Feed. Treat each link like a password: they're stored in the Keychain. Refreshes whenever the app opens. Not affiliated with or endorsed by Instructure or Canvas." : feedStatus) {
                ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                    HStack {
                        Image(systemName: "link").foregroundStyle(Theme.slate)
                        Text(Feed.label(l)).font(.system(size: 16)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button { links.remove(at: i); Feed.setLinks(links); Task { await onFeedChange() } } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(Theme.warn)
                        }.buttonStyle(.plain).accessibilityLabel("Remove feed")
                    }
                    .padding(16)
                    RowDivider()
                }
                TextField(links.isEmpty ? "Paste Canvas calendar feed link" : "Add another feed link", text: $newLink)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .font(.system(size: 16)).padding(16)
                RowDivider()
                ActionRow(title: links.isEmpty ? "Save and refresh" : "Add feed") {
                    let t = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    if links.count >= Feed.freeLimit && !pro.isPro { paywallReason = "Combine several schools or accounts."; return }
                    links.append(t)
                    let status = Feed.setLinks(links)
                    if status == errSecSuccess { newLink = ""; Task { await onFeedChange() } }
                    else { links.removeLast(); feedStatus = "Couldn't save the link to the Keychain (error \(status))." }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: Binding(get: { paywallReason != nil }, set: { if !$0 { paywallReason = nil } })) {
            PaywallView(plans: plans, reason: paywallReason?.isEmpty == false ? paywallReason : nil).environmentObject(pro)
        }
    }

    private var calendarFooter: String {
        let notes = [calendarStatus, syncStatus].filter { !$0.isEmpty }
        return notes.isEmpty
            ? "Plans route around events in your calendars. Study blocks go to their own calendar, replaced each time; your other calendars are untouched."
            : notes.joined(separator: " ")
    }

    private func hour(_ h: Double) -> String {
        Calendar.current.date(bySettingHour: Int(h) % 24, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour())
    }
}

/// Pro: asked when a task is marked done, so estimates can learn.
struct FinishView: View {
    let plan: Plan
    let onFinish: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var actual: Double

    init(plan: Plan, onFinish: @escaping (Double?) -> Void) {
        self.plan = plan; self.onFinish = onFinish
        _actual = State(initialValue: plan.hours)
    }

    var body: some View {
        SheetScaffold(title: "Nice work", subtitle: plan.assignment.title) {
            SheetSection(title: "How long did it take?", footer: "Your answers help estimates match your real pace. You can skip.") {
                StepRow(label: plan.kind == .study ? "Time studying" : "Time working", value: "\(actual.formatted()) h",
                        minus: { actual = max(0.5, actual - 0.5) }, plus: { actual = min(60, actual + 0.5) })
                RowDivider()
                ActionRow(title: "Save and mark done") { onFinish(actual); dismiss() }
                RowDivider()
                ActionRow(title: "Skip", color: Theme.muted) { onFinish(nil); dismiss() }
            }
        }
        .presentationDetents([.medium])
    }
}

struct EditView: View {
    let plan: Plan
    @Binding var overrides: [String: Override]
    @Environment(\.dismiss) private var dismiss
    // `plan` is a snapshot from when the sheet opened; live values come from the override.
    var hours: Double { overrides[plan.id]?.hours ?? plan.hours }
    var buffer: Double { overrides[plan.id]?.bufferDays ?? plan.bufferDays }
    var kind: TaskKind { overrides[plan.id]?.kind ?? plan.kind }

    var body: some View {
        SheetScaffold(title: plan.assignment.title, subtitle: plan.assignment.course) {
            SheetSection(title: "Type", footer: kind == .study
                         ? "Quiz or exam: the hours are time to study. Study is scheduled before assignments when they compete for the same time."
                         : "Assignment: the hours are time to complete the work.") {
                Picker("Type", selection: Binding(get: { kind }, set: { overrides[plan.id, default: Override()].kind = $0 })) {
                    Text("Assignment").tag(TaskKind.complete)
                    Text("Study").tag(TaskKind.study)
                }
                .pickerStyle(.segmented).padding(10)
            }
            SheetSection(title: "Plan", footer: "Safety margin is the time you leave between finishing and the due date, in case the work runs long or something goes wrong. Changes apply to this assignment only.") {
                StepRow(label: kind == .study ? "Study time" : "Work needed", value: "\(hours.formatted()) h",
                        minus: { overrides[plan.id, default: Override()].hours = max(0.5, hours - 0.5) },
                        plus: { overrides[plan.id, default: Override()].hours = min(60, hours + 0.5) })
                RowDivider()
                StepRow(label: "Safety margin", value: "\(Int(buffer)) day\(buffer == 1 ? "" : "s")",
                        minus: { overrides[plan.id, default: Override()].bufferDays = max(0, buffer - 1) },
                        plus: { overrides[plan.id, default: Override()].bufferDays = min(14, buffer + 1) })
            }
            if overrides[plan.id] != nil {
                SheetSection(title: "Defaults") {
                    ActionRow(title: "Reset to defaults", color: Theme.warn) { overrides[plan.id] = nil; dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct KindBadge: View {
    let kind: TaskKind
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind == .study ? "book" : "checkmark.square").font(.system(size: 10, weight: .semibold))
            Text(kind.badge).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .fixedSize()
            .foregroundStyle(tint).padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.chip, in: Capsule())
    }
}

/// Planned hours for the next 7 days; terracotta marks days with work that won't fully fit.
struct WeekChart: View {
    let load: [DayLoad]
    @Binding var selected: Date?
    private func isSelected(_ d: Date) -> Bool { selected.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false }
    private var maxHours: Double { max(load.map(\.hours).max() ?? 1, 4) }
    private var total: Double { load.reduce(0) { $0 + $1.hours } }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Planned hours").foregroundStyle(Theme.muted)
                Spacer()
                Text("\(total.formatted(.number.precision(.fractionLength(0...1)))) h this week").foregroundStyle(Theme.ink)
            }
            .font(.system(size: 12))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(load) { d in
                    Button { selected = isSelected(d.day) ? nil : d.day } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(d.short ? Theme.warn : Theme.slate.opacity(d.hours > 0 ? 1 : 0.25))
                            .opacity(selected == nil || isSelected(d.day) ? 1 : 0.35)
                            .frame(height: max(4, 52 * d.hours / maxHours))
                        Text(d.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 11, weight: Calendar.current.isDateInToday(d.day) ? .bold : .regular))
                            .foregroundStyle(Calendar.current.isDateInToday(d.day) || isSelected(d.day) ? Theme.ink : Theme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(isSelected(d.day) ? Theme.paper : .clear, in: Capsule())
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(d.day.formatted(.dateTime.weekday(.wide))), \(d.hours.formatted(.number.precision(.fractionLength(0...1)))) hours planned")
                }
            }
            .frame(height: 70, alignment: .bottom)
        }
        .padding(14).background(Theme.chip, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// What's on for the picked day (or a hint when nothing is picked).
struct DayInfo: View {
    let day: Date?
    let plans: [Plan]
    var canClear = true
    let onClear: () -> Void
    private var cal: Calendar { .current }

    var body: some View {
        if let day {
            let items = Planner.sessions(on: day, in: plans)
            let due = plans.filter { cal.isDate($0.assignment.due, inSameDayAs: day) }
            let hours = items.reduce(0) { $0 + $1.session.duration } / 3600
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(cal.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.system(size: 17, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.ink)
                    Spacer()
                    if canClear { Button("Show all", action: onClear).font(.system(size: 12)).foregroundStyle(Theme.slate) }
                }
                Text(items.isEmpty ? "Nothing planned. A free day." : "\(hours.formatted(.number.precision(.fractionLength(0...1)))) h across \(items.count) session\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.accent(for: it.plan.assignment.course)).frame(width: 7, height: 7)
                        Text("\(it.session.start.formatted(.dateTime.hour().minute())) – \(it.session.end.formatted(.dateTime.hour().minute()))")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                        Text(it.plan.assignment.title).font(.system(size: 14)).foregroundStyle(Theme.ink).lineLimit(1)
                    }
                }
                if !due.isEmpty {
                    Text("Due this day: " + due.map(\.assignment.title).joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline, lineWidth: 0.5))
        } else {
            Text("Tap a day in the chart to see only what you need to do that day.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

struct PlanRow: View {
    let plan: Plan
    let edited: Bool
    let onDone: () -> Void
    private var short: Bool { plan.shortfall > 0 }
    private var tint: Color { short ? Theme.warn : Theme.accent(for: plan.assignment.course) }
    private var cal: Calendar { .current }

    private func num(_ h: Double) -> String { h.formatted(.number.precision(.fractionLength(0...1))) }

    private var dueLabel: String {
        let due = plan.assignment.due
        if cal.isDateInToday(due) { return cal.component(.hour, from: due) >= 17 ? "due tonight" : "due today" }
        if cal.isDateInTomorrow(due) { return "due tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: due).day ?? 99
        return days < 7 ? "due " + due.formatted(.dateTime.weekday(.abbreviated)) : "due " + due.formatted(.dateTime.month(.abbreviated).day())
    }
    private var startLabel: String {
        guard let s = plan.start else { return "No time" }
        return cal.isDateInToday(s) ? s.formatted(.dateTime.hour().minute()) : s.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    private var progress: Double { plan.hours > 0 ? max(0, min(1, (plan.hours - plan.shortfall) / plan.hours)) : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onDone) {
                    Circle().strokeBorder(tint, lineWidth: 1.5).frame(width: 22, height: 22).padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(-6).accessibilityLabel("Mark done")
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.assignment.title).font(.system(size: 17, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        KindBadge(kind: plan.kind, tint: tint)
                        if let c = plan.assignment.course { Text(c).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    }
                }
                Spacer(minLength: 8)
                Text(dueLabel).font(.system(size: 12)).foregroundStyle(short ? Theme.warn : Theme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.hairline).frame(height: 5)
                    .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(tint).frame(width: g.size.width * progress) } }
                HStack {
                    Text(short ? "\(num(plan.hours - plan.shortfall)) of \(num(plan.hours)) h fit · \(num(plan.shortfall)) h short"
                               : "\(num(plan.hours)) h to \(plan.kind.verb)\(edited ? " ✎" : "")")
                        .foregroundStyle(short ? Theme.warn : Theme.muted)
                    Spacer()
                    Text(startLabel).foregroundStyle(Theme.ink)
                }
                .font(.system(size: 12))
            }
            .padding(.leading, 34)
            if plan.intoBuffer && !short {
                Text("Cuts into your safety margin").font(.system(size: 12)).foregroundStyle(Theme.warn).padding(.leading, 34)
            }
            FlowLayout(spacing: 6) {
                ForEach(plan.sessions, id: \.start) { s in
                    Text("\(s.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(s.end.formatted(.dateTime.hour().minute()))")
                        .font(.system(size: 12)).foregroundStyle(tint)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.leading, 34)
        }
        .padding(.vertical, 16)
    }
}
