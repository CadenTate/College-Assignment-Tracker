import UserNotifications

enum Notifier {
    /// Replaces all pending reminders with `reminders`. Asks for permission on first use.
    static func schedule(_ reminders: [Reminder]) async {
        let c = UNUserNotificationCenter.current()
        guard (try? await c.requestAuthorization(options: [.alert, .sound])) == true else { return }
        c.removeAllPendingNotificationRequests()
        for r in reminders {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.date)
            try? await c.add(UNNotificationRequest(identifier: r.id, content: content,
                                                   trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }
}
