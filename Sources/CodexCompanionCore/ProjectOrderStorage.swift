import Foundation

@MainActor
public protocol ProjectOrderStoring: AnyObject {
    func load() -> [String]
    func save(_ projectIDs: [String])
}

@MainActor
public final class UserDefaultsProjectOrderStorage: ProjectOrderStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "task-deck-for-codex.project-order.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func save(_ projectIDs: [String]) {
        defaults.set(projectIDs, forKey: key)
    }
}
