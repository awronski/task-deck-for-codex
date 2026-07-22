import Foundation

@MainActor
public protocol VisibilityStoring: AnyObject {
    func load() -> VisibilityLedger
    func save(_ ledger: VisibilityLedger)
}

@MainActor
public final class UserDefaultsVisibilityStorage: VisibilityStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "task-deck-for-codex.visibility.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> VisibilityLedger {
        guard let data = defaults.data(forKey: key),
              let ledger = try? JSONDecoder().decode(VisibilityLedger.self, from: data)
        else {
            return VisibilityLedger()
        }
        return ledger
    }

    public func save(_ ledger: VisibilityLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: key)
    }
}
