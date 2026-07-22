import Foundation

@MainActor
public protocol TaskTitleStoring: AnyObject {
    func load() -> [String: String]
    func save(_ titles: [String: String])
}

@MainActor
public final class UserDefaultsTaskTitleStorage: TaskTitleStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "task-deck-for-codex.task-titles.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public func save(_ titles: [String: String]) {
        defaults.set(titles, forKey: key)
    }
}
