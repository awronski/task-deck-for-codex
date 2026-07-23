import Foundation

@MainActor
public protocol TaskPriorityStoring: AnyObject {
    func load() -> [String: TaskPriority]
    func save(_ priorities: [String: TaskPriority])
}

@MainActor
public final class UserDefaultsTaskPriorityStorage: TaskPriorityStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "task-deck-for-codex.task-priorities.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: TaskPriority] {
        guard let storedValues = defaults.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }
        return storedValues.reduce(into: [:]) { priorities, entry in
            priorities[entry.key] = TaskPriority(rawValue: entry.value)
        }
    }

    public func save(_ priorities: [String: TaskPriority]) {
        defaults.set(priorities.mapValues(\.rawValue), forKey: key)
    }
}
