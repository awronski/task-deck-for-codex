import CodexCompanionCore
import Foundation
import Testing

@Suite
@MainActor
struct ProjectAppearanceStorageTests {
    @Test
    func userDefaultsStorageRoundTripsAndRemovesEmptyState() throws {
        let suiteName = "ProjectAppearanceStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "project-appearances"
        let storage = UserDefaultsProjectAppearanceStorage(defaults: defaults, key: key)
        let appearances = [
            "/code/admin": ProjectAppearance(
                iconName: "chart.bar",
                colorID: "matrix-purple-medium",
                displayName: "Analytics Dashboard"
            ),
            "/code/cli": ProjectAppearance(
                iconName: "terminal",
                colorID: ProjectAppearance.noBackgroundColorID
            )
        ]

        storage.save(appearances)
        #expect(storage.load() == appearances)
        #expect(appearances["/code/cli"]?.usesBackgroundColor == false)

        storage.save([:])
        #expect(storage.load().isEmpty)
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func displayNameIsTrimmedAndEmptyNamesRestoreTheOriginalName() {
        let renamed = ProjectAppearance(
            iconName: "folder",
            colorID: ProjectAppearance.noBackgroundColorID,
            displayName: "  Customer portal  "
        )
        let restored = ProjectAppearance(
            iconName: "folder",
            colorID: ProjectAppearance.noBackgroundColorID,
            displayName: "  \n  "
        )

        #expect(renamed.displayName == "Customer portal")
        #expect(restored.displayName == nil)
    }

    @Test
    func storedAppearanceWithoutDisplayNameStillLoads() throws {
        let suiteName = "ProjectAppearanceStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "project-appearances"
        let storage = UserDefaultsProjectAppearanceStorage(defaults: defaults, key: key)
        let legacyJSON = """
        {
          "/code/cli": {
            "iconName": "terminal",
            "colorID": "no-background"
          }
        }
        """
        defaults.set(Data(legacyJSON.utf8), forKey: key)

        #expect(storage.load() == [
            "/code/cli": ProjectAppearance(
                iconName: "terminal",
                colorID: ProjectAppearance.noBackgroundColorID
            )
        ])
    }

    @Test
    func malformedStoredDataIsIgnored() throws {
        let suiteName = "ProjectAppearanceStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "project-appearances"
        let storage = UserDefaultsProjectAppearanceStorage(defaults: defaults, key: key)

        defaults.set(Data("not-json".utf8), forKey: key)

        #expect(storage.load().isEmpty)
    }
}
