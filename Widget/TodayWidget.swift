import SwiftUI
import WidgetKit

private let group = "group.com.cadentate.assignmenttracker"

/// Mirrors WidgetBridge.Snapshot in the app (the two targets don't share source files).
private struct Snapshot: Codable {
    struct Item: Codable { var title: String; var start: Date; var end: Date; var study: Bool }
    var pro: Bool
    var sessions: [Item]
}

private func load() -> Snapshot? {
    guard let data = UserDefaults(suiteName: group)?.data(forKey: "today") else { return nil }
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    return try? d.decode(Snapshot.self, from: data)
}

struct Entry: TimelineEntry { let date: Date; fileprivate let snapshot: Snapshot? }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: Snapshot(pro: true, sessions: [
            .init(title: "Midterm exam", start: .now, end: .now.addingTimeInterval(7200), study: true),
            .init(title: "HW4", start: .now.addingTimeInterval(9000), end: .now.addingTimeInterval(16200), study: false)]))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now, snapshot: load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snap = load()
        // Refresh when the current session ends or in 15 minutes, whichever is sooner.
        let next = snap?.sessions.map(\.end).filter { $0 > .now }.min().map { min($0, Date.now.addingTimeInterval(900)) } ?? Date.now.addingTimeInterval(900)
        completion(Timeline(entries: [Entry(date: .now, snapshot: snap)], policy: .after(next)))
    }
}

struct TodayView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var upcoming: [Snapshot.Item] {
        (entry.snapshot?.sessions ?? []).filter { $0.end > entry.date }.sorted { $0.start < $1.start }
    }

    var body: some View {
        Group {
            if entry.snapshot == nil {
                message("Open Assignments to set up your plan.")
            } else if entry.snapshot?.pro == false {
                message("The widget is part of Pro. Open the app to unlock it.")
            } else if upcoming.isEmpty {
                message("Nothing planned. A free stretch.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Calendar.current.isDateInToday(upcoming[0].start) || upcoming[0].start < entry.date ? "Today" : "Next up")
                        .font(.system(size: 13, weight: .bold))
                    ForEach(Array(upcoming.prefix(family == .systemSmall ? 2 : 4).enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(s.study ? "Study" : "Work") · \(s.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(s.end.formatted(.dateTime.hour().minute()))")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func message(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: Provider()) { TodayView(entry: $0) }
            .configurationDisplayName("Today's sessions")
            .description("Your next study and work sessions.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
