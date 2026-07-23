import CodexCompanionCore
import Foundation
import Testing

@Suite
struct TaskReminderTests {
    @Test
    func relativeUnitsAddCalendarMinutesHoursAndDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 10, minute: 30))
        )

        #expect(
            ReminderOffsetUnit.minutes.date(after: start, value: 7, calendar: calendar)
                == calendar.date(byAdding: .minute, value: 7, to: start)
        )
        #expect(
            ReminderOffsetUnit.hours.date(after: start, value: 4, calendar: calendar)
                == calendar.date(byAdding: .hour, value: 4, to: start)
        )
        #expect(
            ReminderOffsetUnit.days.date(after: start, value: 3, calendar: calendar)
                == calendar.date(byAdding: .day, value: 3, to: start)
        )
        #expect(ReminderOffsetUnit.minutes.date(after: start, value: 0, calendar: calendar) == nil)
    }

    @Test
    @MainActor
    func userDefaultsStorageRoundTripsAndRemovesEmptyState() throws {
        let suiteName = "TaskReminderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "reminders"
        let storage = UserDefaultsTaskReminderStorage(defaults: defaults, key: key)
        let reminder = TaskReminder(
            taskID: "task",
            title: "Deploy release",
            dueAt: Date(timeIntervalSince1970: 1_000_000)
        )

        storage.save([reminder.taskID: reminder])
        #expect(storage.load() == [reminder.taskID: reminder])

        storage.save([:])
        #expect(storage.load().isEmpty)
        #expect(defaults.object(forKey: key) == nil)
    }
}
