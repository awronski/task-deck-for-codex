import Foundation

@MainActor
public protocol TaskReminderStoring: AnyObject {
    func load() -> [String: TaskReminder]
    func save(_ reminders: [String: TaskReminder])
}

@MainActor
public final class UserDefaultsTaskReminderStorage: TaskReminderStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "task-deck-for-codex.task-reminders.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: TaskReminder] {
        guard let data = defaults.data(forKey: key),
              let reminders = try? JSONDecoder().decode([String: TaskReminder].self, from: data)
        else {
            return [:]
        }
        return reminders
    }

    public func save(_ reminders: [String: TaskReminder]) {
        guard !reminders.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        defaults.set(data, forKey: key)
    }
}
