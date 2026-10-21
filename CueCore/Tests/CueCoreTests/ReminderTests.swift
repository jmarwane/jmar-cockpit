@testable import CueCore
import Foundation
import Testing

@Suite struct ReminderTests {
    let calendar = QuickAddTests.calendar
    let now = QuickAddTests.now  // Tue 2026-10-20 15:00, Paris

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func pastTimesRollOverAroundMidnight() {
        let lateNight = at(20, 23, 59)
        #expect(ReminderParser.parse("x at 23:58", now: lateNight, calendar: calendar).due == at(21, 23, 58))
        #expect(ReminderParser.parse("x at 23:59", now: lateNight, calendar: calendar).due == at(21, 23, 59))
        let afterMidnight = at(21, 0, 10)
        #expect(ReminderParser.parse("x at 12am", now: afterMidnight, calendar: calendar).due == at(22, 0))
        #expect(ReminderParser.parse("x at 12:30am", now: afterMidnight, calendar: calendar).due == at(21, 0, 30))
        #expect(ReminderParser.parse("x at 12pm", now: afterMidnight, calendar: calendar).due == at(21, 12))
        #expect(ReminderParser.parse("x tomorrow at 12am", now: now, calendar: calendar).due == at(21, 0))
        #expect(ReminderParser.parse("x tomorrow at 12pm", now: now, calendar: calendar).due == at(21, 12))
    }

    @Test func dueRemindersFireOnTimeOrAreMissed() {
        var reminders = [
            Reminder(text: "on time", due: now.addingTimeInterval(-5)),
            Reminder(text: "missed", due: now.addingTimeInterval(-3600)),
            Reminder(text: "later", due: now.addingTimeInterval(600)),
        ]
        let changed = ReminderBook.markDue(&reminders, now: now)
        #expect(changed.count == 2)
        #expect(reminders[0].state == .fired && reminders[0].firedAt == now)
        #expect(reminders[1].state == .fired && reminders[1].firedAt == nil)
        #expect(reminders[2].state == .pending)
        #expect(ReminderBook.markDue(&reminders, now: now).isEmpty)
        #expect(ReminderBook.nextDue(reminders) == now.addingTimeInterval(600))
    }

    @Test func rowsAndSummary() {
        let pending = Reminder(text: "Stretch", due: at(20, 15, 12))
        #expect(ReminderBook.presentation(pending, now: now, calendar: calendar) == RowPresentation(glyph: .bell, subtitle: "in 12 min · 15:12", primary: .none))
        var fired = Reminder(text: "Tea", due: at(20, 14, 0), state: .fired, firedAt: at(20, 14, 0))
        #expect(ReminderBook.presentation(fired, now: now, calendar: calendar).subtitle == "Fired at 14:00")
        fired.firedAt = nil
        #expect(ReminderBook.presentation(fired, now: now, calendar: calendar).subtitle == "Was due 14:00")
        let tomorrow = Reminder(text: "Dentist", due: at(21, 9))
        #expect(ReminderBook.presentation(tomorrow, now: now, calendar: calendar).subtitle == "in 18 h · tomorrow 9:00")

        #expect(ReminderBook.summary([], now: now, calendar: calendar) == "Write a note, pick a time")
        #expect(ReminderBook.summary([pending, tomorrow, fired], now: now, calendar: calendar) == "2 upcoming · next 15:12")
        #expect(ReminderBook.upcoming([tomorrow, pending, fired]).map(\.text) == ["Tea", "Stretch", "Dentist"])
    }

    @Test func snoozeAndChips() {
        let fired = Reminder(text: "Tea", due: at(20, 14), state: .fired, firedAt: at(20, 14))
        let snoozed = ReminderBook.snoozed(fired, now: now)
        #expect(snoozed.state == .pending && snoozed.due == at(20, 15, 10) && snoozed.firedAt == nil && snoozed.id == fired.id)
        let chips = ReminderBook.chips(now: now, calendar: calendar)
        #expect(chips.map(\.label) == ["15 min", "1 hour", "Tomorrow 9:00"])
        #expect(chips.map(\.due) == [at(20, 15, 15), at(20, 16), at(21, 9)])
    }
}
