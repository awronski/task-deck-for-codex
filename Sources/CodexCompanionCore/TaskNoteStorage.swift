import Foundation

@MainActor
public protocol TaskNoteStoring: AnyObject {
    func load() -> [String: String]
    func save(_ notes: [String: String])
}

@MainActor
public final class UserDefaultsTaskNoteStorage: TaskNoteStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "task-deck-for-codex.task-notes.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public func save(_ notes: [String: String]) {
        defaults.set(notes, forKey: key)
    }
}
