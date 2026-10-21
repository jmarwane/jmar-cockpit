import CueCore
import Foundation
import os
@preconcurrency import UserNotifications

/// Local notifications for reminders, so they arrive even when Cue isn't running (spec §10).
@MainActor
protocol ReminderNotifying: AnyObject {
    var onAction: (_ reminderID: UUID, _ action: ReminderNotifications.Action) -> Void { get set }
    func schedule(_ reminder: Reminder)
    func cancel(_ reminder: Reminder)
}

@MainActor
final class ReminderNotifications: NSObject, ReminderNotifying, UNUserNotificationCenterDelegate {
    enum Action { case snooze, done, open }

    nonisolated static let category = "CUE_REMINDER"
    nonisolated static let snoozeAction = "SNOOZE"
    nonisolated static let doneAction = "DONE"
    private nonisolated static let idKey = "reminderID"

    var onAction: (UUID, Action) -> Void = { _, _ in }
    var onDenied: () -> Void = {}
    private let center = UNUserNotificationCenter.current()
    private var askedForPermission = false

    override init() {
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 10 min")
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Done")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [snooze, done], intentIdentifiers: []),
        ])
    }

    func schedule(_ reminder: Reminder) {
        guard reminder.state == .pending else { return }
        Task {
            guard await ensurePermission() else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.text
            content.body = "Due \(ReminderBook.clock(reminder.due, now: Date()))"
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.userInfo = [Self.idKey: reminder.id.uuidString]
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.due)
            let request = UNNotificationRequest(
                identifier: reminder.notificationID,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            do {
                try await center.add(request)
            } catch {
                appLog.error("reminder notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel(_ reminder: Reminder) {
        center.removePendingNotificationRequests(withIdentifiers: [reminder.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [reminder.notificationID])
    }

    private func ensurePermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            guard !askedForPermission else { return false }
            askedForPermission = true
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted { onDenied() }
            return granted
        default:
            onDenied()
            return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo[Self.idKey] as? String, let id = UUID(uuidString: text) else { return }
        let action: Action = switch response.actionIdentifier {
        case Self.snoozeAction: .snooze
        case Self.doneAction: .done
        default: .open
        }
        await MainActor.run { self.onAction(id, action) }
    }
}

/// Debug runs against a fixture library: log instead of scheduling, so no permission prompt appears.
@MainActor
final class LoggedReminderNotifications: ReminderNotifying {
    var onAction: (UUID, ReminderNotifications.Action) -> Void = { _, _ in }
    func schedule(_ reminder: Reminder) { appLog.notice("would schedule reminder \(reminder.text, privacy: .public) at \(reminder.due, privacy: .public)") }
    func cancel(_ reminder: Reminder) { appLog.notice("would cancel reminder \(reminder.text, privacy: .public)") }
}
