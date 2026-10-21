import Foundation

/// The rules for reminders (spec §10). Pure functions over `[Reminder]`, so the app's timer,
/// launch and notification paths all agree.
public enum ReminderBook {
    public static let snooze: TimeInterval = 10 * 60
    /// A due time noticed later than this (sleep, Cue not running) counts as missed: `Was due 14:00`.
    public static let lateness: TimeInterval = 60

    /// Soonest first; fired ones are past, so they come first.
    public static func upcoming(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted { ($0.due, $0.id.uuidString) < ($1.due, $1.id.uuidString) }
    }

    /// The next pending due time, for the in-app timer.
    public static func nextDue(_ reminders: [Reminder]) -> Date? {
        reminders.filter { $0.state == .pending }.map(\.due).min()
    }

    /// Marks pending reminders whose time has come as fired. One noticed on time gets `firedAt`;
    /// one noticed late (Mac asleep, Cue not running) has no `firedAt` and reads `Was due`.
    /// Returns the IDs that changed.
    @discardableResult
    public static func markDue(_ reminders: inout [Reminder], now: Date) -> [UUID] {
        var changed: [UUID] = []
        for index in reminders.indices where reminders[index].state == .pending && reminders[index].due <= now {
            reminders[index].state = .fired
            let late = now.timeIntervalSince(reminders[index].due) > lateness
            reminders[index].firedAt = late ? nil : now
            changed.append(reminders[index].id)
        }
        return changed
    }

    /// Snooze 10 min: pending again, due ten minutes from now.
    public static func snoozed(_ reminder: Reminder, now: Date) -> Reminder {
        var reminder = reminder
        reminder.due = now.addingTimeInterval(snooze)
        reminder.state = .pending
        reminder.firedAt = nil
        return reminder
    }

    /// A reminder's row: bell and countdown while pending, check and `Fired at` / `Was due` after.
    public static func presentation(_ reminder: Reminder, now: Date, calendar: Calendar = .current) -> RowPresentation {
        let time = clock(reminder.due, now: now, calendar: calendar)
        switch reminder.state {
        case .pending:
            return RowPresentation(glyph: .bell, subtitle: "in \(RelativeText.countdown(to: reminder.due, now: now)) · \(time)", primary: .none)
        case .fired:
            if let firedAt = reminder.firedAt {
                return RowPresentation(glyph: .fired, subtitle: "Fired at \(clock(firedAt, now: now, calendar: calendar))", primary: .none)
            }
            return RowPresentation(glyph: .fired, subtitle: "Was due \(time)", primary: .none)
        }
    }

    /// The New Reminder row's subtitle.
    public static func summary(_ reminders: [Reminder], now: Date, calendar: Calendar = .current) -> String {
        let pending = reminders.filter { $0.state == .pending }
        guard let next = pending.map(\.due).min() else { return "Write a note, pick a time" }
        return "\(pending.count) upcoming · next \(clock(next, now: now, calendar: calendar))"
    }

    /// `23:58` today, `Tue 9:00` within a week, else the date.
    public static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 1 { return "tomorrow \(time)" }
        if days == -1 { return "yesterday \(time)" }
        if abs(days) < 7 {
            let weekday = date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
            return "\(weekday) \(time)"
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// The form's chips: `15 min`, `1 hour`, `Tomorrow 9:00`.
    public static func chips(now: Date, calendar: Calendar = .current) -> [(label: String, due: Date)] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let nine = calendar.date(bySettingHour: ReminderParser.tomorrowHour, minute: 0, second: 0, of: tomorrow)!
        return [
            ("15 min", now.addingTimeInterval(15 * 60)),
            ("1 hour", now.addingTimeInterval(3600)),
            ("Tomorrow \(nine.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)))", nine),
        ]
    }
}
