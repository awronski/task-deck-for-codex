import Foundation

public struct ProjectAppearance: Codable, Equatable, Sendable {
    public static let noBackgroundColorID = "no-background"

    public let iconName: String
    public let colorID: String

    public var usesBackgroundColor: Bool {
        colorID != Self.noBackgroundColorID
    }

    public init(iconName: String, colorID: String) {
        self.iconName = iconName
        self.colorID = colorID
    }
}

@MainActor
public protocol ProjectAppearanceStoring: AnyObject {
    func load() -> [String: ProjectAppearance]
    func save(_ appearances: [String: ProjectAppearance])
}

@MainActor
public final class UserDefaultsProjectAppearanceStorage: ProjectAppearanceStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "task-deck-for-codex.project-appearances.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: ProjectAppearance] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ProjectAppearance].self, from: data)) ?? [:]
    }

    public func save(_ appearances: [String: ProjectAppearance]) {
        guard !appearances.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(appearances) else { return }
        defaults.set(data, forKey: key)
    }
}
