import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Hands the next two days of sessions to the widget through the shared App Group.
enum WidgetBridge {
    static let group = "group.com.cadentate.assignmenttracker"

    struct Snapshot: Codable {
        struct Item: Codable { var title: String; var start: Date; var end: Date; var study: Bool }
        var pro: Bool
        var sessions: [Item]
    }

    static func publish(_ plans: [Plan], pro: Bool) {
        let horizon = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now))!
        let items = pro ? plans.flatMap { p in
            p.sessions.map { Snapshot.Item(title: p.assignment.title, start: $0.start, end: $0.end, study: p.kind == .study) }
        }.filter { $0.end > .now && $0.start < horizon }.sorted { $0.start < $1.start } : []
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let defaults = UserDefaults(suiteName: group), let data = try? enc.encode(Snapshot(pro: pro, sessions: items)) else { return }
        defaults.set(data, forKey: "today")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
