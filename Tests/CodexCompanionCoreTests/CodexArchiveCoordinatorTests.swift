import CodexCompanionCore
import Foundation
import Testing

@Suite
struct CodexArchiveCoordinatorTests {
    @Test
    func completesImmediatelyWhenThePrimaryArchiverSucceeds() async throws {
        let primary = RecordingTaskArchiver()
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName
        )

        let result = try await coordinator.setArchived(true, taskID: "task")

        #expect(result == .completed)
        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(await primary.updates == [.init(archived: true, taskID: "task")])
    }

    @Test
    func queuesAnArchiveWhenCodexOwnsTheTask() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName
        )

        let result = try await coordinator.setArchived(true, taskID: "task")

        #expect(result == .deferred)
        #expect(await coordinator.pendingArchiveTaskIDs() == ["task"])
        #expect(fixture.storedTaskIDs == ["task"])
    }

    @Test
    func retryCompletesAQueuedArchiveAfterCodexReleasesIt() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict, .success])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName,
            retryInterval: 0
        )

        #expect(try await coordinator.setArchived(true, taskID: "task") == .deferred)
        try await coordinator.retryPendingArchives()

        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(await primary.updates == [
            .init(archived: true, taskID: "task"),
            .init(archived: true, taskID: "task")
        ])
    }

    @Test
    func immediatePollingDoesNotRepeatTheArchiveCommand() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict, .success])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName
        )

        #expect(try await coordinator.setArchived(true, taskID: "task") == .deferred)
        try await coordinator.retryPendingArchives()

        #expect(await coordinator.pendingArchiveTaskIDs() == ["task"])
        #expect(await primary.updates == [.init(archived: true, taskID: "task")])
    }

    @Test
    func restoringAQueuedTaskCancelsWithoutCallingUnarchive() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName
        )

        #expect(try await coordinator.setArchived(true, taskID: "task") == .deferred)
        #expect(try await coordinator.setArchived(false, taskID: "task") == .completed)

        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(await primary.updates == [.init(archived: true, taskID: "task")])
    }

    @Test
    func cancellingAQueuedTaskRestoresItWhenAlreadyArchived() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict, .success])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            archiveStateReader: StaticArchiveStateReader(isUnarchived: false),
            defaultsSuiteName: fixture.suiteName
        )

        #expect(try await coordinator.setArchived(true, taskID: "task") == .deferred)
        #expect(try await coordinator.setArchived(false, taskID: "task") == .completed)

        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(await primary.updates == [
            .init(archived: true, taskID: "task"),
            .init(archived: false, taskID: "task")
        ])
    }

    @Test
    func retryClearsARequestAlreadyCompletedInCodex() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            archiveStateReader: StaticArchiveStateReader(isUnarchived: false),
            defaultsSuiteName: fixture.suiteName,
            retryInterval: 0
        )

        #expect(try await coordinator.setArchived(true, taskID: "task") == .deferred)
        try await coordinator.retryPendingArchives()

        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(await primary.updates == [.init(archived: true, taskID: "task")])
    }

    @Test
    func queuedArchivesSurviveCoordinatorRelaunch() async throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let firstPrimary = RecordingTaskArchiver(outcomes: [.ownerConflict])
        let firstCoordinator = CodexArchiveCoordinator(
            primaryArchiver: firstPrimary,
            defaultsSuiteName: fixture.suiteName
        )
        #expect(try await firstCoordinator.setArchived(true, taskID: "task") == .deferred)

        let secondPrimary = RecordingTaskArchiver()
        let secondCoordinator = CodexArchiveCoordinator(
            primaryArchiver: secondPrimary,
            defaultsSuiteName: fixture.suiteName,
            retryInterval: 0
        )
        #expect(await secondCoordinator.pendingArchiveTaskIDs() == ["task"])

        try await secondCoordinator.retryPendingArchives()

        #expect(await secondCoordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(await secondPrimary.updates == [.init(archived: true, taskID: "task")])
    }

    @Test
    func retrySurfacesANonOwnerFailureAndKeepsTheRequestPending() async throws {
        let primary = RecordingTaskArchiver(outcomes: [.ownerConflict, .failure])
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName,
            retryInterval: 0
        )
        #expect(try await coordinator.setArchived(true, taskID: "task") == .deferred)

        do {
            try await coordinator.retryPendingArchives()
            Issue.record("Expected the retry failure")
        } catch let error as CodexRepositoryError {
            #expect(error == .codexCommandFailed("Retry failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await coordinator.pendingArchiveTaskIDs() == ["task"])
        #expect(fixture.storedTaskIDs == ["task"])
    }

    @Test
    func retryFailureDoesNotBlockLaterPendingArchives() async throws {
        let primary = RecordingTaskArchiver(
            outcomes: [.ownerConflict, .ownerConflict, .failure, .success]
        )
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: primary,
            defaultsSuiteName: fixture.suiteName,
            retryInterval: 0
        )
        #expect(try await coordinator.setArchived(true, taskID: "a") == .deferred)
        #expect(try await coordinator.setArchived(true, taskID: "b") == .deferred)

        do {
            try await coordinator.retryPendingArchives()
            Issue.record("Expected the retry failure")
        } catch let error as CodexRepositoryError {
            #expect(error == .codexCommandFailed("Retry failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await coordinator.pendingArchiveTaskIDs() == ["a"])
        #expect(fixture.storedTaskIDs == ["a"])
        #expect(await primary.updates == [
            .init(archived: true, taskID: "a"),
            .init(archived: true, taskID: "b"),
            .init(archived: true, taskID: "a"),
            .init(archived: true, taskID: "b")
        ])
    }
}

private actor RecordingTaskArchiver: CodexTaskArchiving {
    struct Update: Equatable {
        let archived: Bool
        let taskID: String
    }

    enum Outcome: Equatable {
        case success
        case ownerConflict
        case failure
    }

    private(set) var updates: [Update] = []
    private var outcomes: [Outcome]

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func setArchived(
        _ archived: Bool,
        taskID: String
    ) throws -> CodexTaskArchiveResult {
        updates.append(Update(archived: archived, taskID: taskID))
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        if outcome == .ownerConflict {
            throw CodexRepositoryError.codexTaskHasActiveWriter
        }
        if outcome == .failure {
            throw CodexRepositoryError.codexCommandFailed("Retry failed")
        }
        return .completed
    }
}

private struct StaticArchiveStateReader: CodexTaskArchiveStateReading {
    let isUnarchived: Bool

    func isTaskUnarchived(_ taskID: String) -> Bool {
        isUnarchived
    }
}

private struct DefaultsFixture {
    static let storageKey = "task-deck-for-codex.pending-archives.v1"

    let suiteName: String

    init() throws {
        suiteName = "CodexArchiveCoordinatorTests.\(UUID().uuidString)"
        try #require(UserDefaults(suiteName: suiteName))
            .removePersistentDomain(forName: suiteName)
    }

    var storedTaskIDs: [String]? {
        UserDefaults(suiteName: suiteName)?.stringArray(forKey: Self.storageKey)
    }

    func remove() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}
