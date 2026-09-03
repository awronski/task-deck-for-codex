import Darwin
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
    func repositoryWriterLockFailureRemainsQueuedUntilTheRealLockIsReleased() async throws {
        let repositoryFixture = try ArchiveRepositoryFixture()
        defer { repositoryFixture.remove() }
        let defaultsFixture = try DefaultsFixture()
        defer { defaultsFixture.remove() }

        let taskID = UUID().uuidString.lowercased()
        try repositoryFixture.writeDatabase(taskID: taskID)
        let lock = try repositoryFixture.holdWriterLock(taskID: taskID)
        let codexExecutable = try repositoryFixture.writeConditionalArchiveExecutable()
        let repository = CodexTaskRepository(
            codexHome: repositoryFixture.root,
            homeDirectory: "/Users/test",
            codexExecutableURL: codexExecutable
        )
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: repository,
            archiveStateReader: repository,
            defaultsSuiteName: defaultsFixture.suiteName,
            retryInterval: 0
        )

        #expect(try await coordinator.setArchived(true, taskID: taskID) == .deferred)
        #expect(await coordinator.pendingArchiveTaskIDs() == [taskID])
        #expect(defaultsFixture.storedTaskIDs == [taskID])

        try await coordinator.retryPendingArchives()
        #expect(await coordinator.pendingArchiveTaskIDs() == [taskID])
        #expect(defaultsFixture.storedTaskIDs == [taskID])

        lock.unlock()
        try repositoryFixture.enableArchiveSuccess()
        try await coordinator.retryPendingArchives()

        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(defaultsFixture.storedTaskIDs == [])
        #expect(try await !repository.isTaskUnarchived(taskID))
    }

    @Test
    func repositoryDescendantWriterLockQueuesAndPersistsTheRootTask() async throws {
        let repositoryFixture = try ArchiveRepositoryFixture()
        defer { repositoryFixture.remove() }
        let defaultsFixture = try DefaultsFixture()
        defer { defaultsFixture.remove() }

        let rootTaskID = UUID().uuidString.lowercased()
        let descendantTaskID = UUID().uuidString.lowercased()
        try repositoryFixture.writeDatabase(
            taskID: rootTaskID,
            descendantTaskID: descendantTaskID
        )
        let lock = try repositoryFixture.holdWriterLock(taskID: descendantTaskID)
        defer { lock.unlock() }
        let codexExecutable = try repositoryFixture.writeConditionalArchiveExecutable()
        let repository = CodexTaskRepository(
            codexHome: repositoryFixture.root,
            homeDirectory: "/Users/test",
            codexExecutableURL: codexExecutable
        )
        let coordinator = CodexArchiveCoordinator(
            primaryArchiver: repository,
            archiveStateReader: repository,
            defaultsSuiteName: defaultsFixture.suiteName,
            retryInterval: 0
        )

        #expect(
            try await coordinator.setArchived(true, taskID: rootTaskID) == .deferred
        )
        #expect(await coordinator.pendingArchiveTaskIDs() == [rootTaskID])
        #expect(defaultsFixture.storedTaskIDs == [rootTaskID])

        try await coordinator.retryPendingArchives()
        #expect(await coordinator.pendingArchiveTaskIDs() == [rootTaskID])
        #expect(defaultsFixture.storedTaskIDs == [rootTaskID])

        lock.unlock()
        try repositoryFixture.enableArchiveSuccess()
        try await coordinator.retryPendingArchives()

        #expect(await coordinator.pendingArchiveTaskIDs().isEmpty)
        #expect(defaultsFixture.storedTaskIDs == [])
        #expect(try await !repository.isTaskUnarchived(rootTaskID))
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

private struct ArchiveRepositoryFixture {
    let root: URL
    private let successMarker: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp/td-coordinator-\(UUID().uuidString)", isDirectory: true)
        successMarker = root.appendingPathComponent("archive-can-succeed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeDatabase(taskID: String, descendantTaskID: String? = nil) throws {
        var statements = [
            "CREATE TABLE threads (id TEXT PRIMARY KEY, archived INTEGER)",
            "CREATE TABLE thread_spawn_edges (child_thread_id TEXT, parent_thread_id TEXT)",
            "INSERT INTO threads VALUES ('\(taskID)', 0)"
        ]
        if let descendantTaskID {
            statements.append("INSERT INTO threads VALUES ('\(descendantTaskID)', 0)")
            statements.append(
                "INSERT INTO thread_spawn_edges VALUES ('\(descendantTaskID)', '\(taskID)')"
            )
        }
        try executeSQL(statements.joined(separator: ";"))
    }

    func holdWriterLock(taskID: String) throws -> CoordinatorHeldWriterLock {
        let directory = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(taskID.lowercased()).lock")
        try Data().write(to: url)
        return try CoordinatorHeldWriterLock(url: url)
    }

    func writeConditionalArchiveExecutable() throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let escapedMarkerPath = successMarker.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        if [ "$1" = 'app-server' ]; then
            exit 1
        fi
        if [ -f '\(escapedMarkerPath)' ]; then
            /usr/bin/sqlite3 "$CODEX_HOME/state_5.sqlite" 'UPDATE threads SET archived = 1'
            exit 0
        fi
        printf '%s\n' 'Error: failed to archive session' >&2
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func enableArchiveSuccess() throws {
        try Data().write(to: successMarker)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func executeSQL(_ sql: String) throws {
        let database = root.appendingPathComponent("state_5.sqlite")
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw ArchiveRepositoryFixtureError.sqlite(message)
        }
    }
}

private final class CoordinatorHeldWriterLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32

    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ArchiveRepositoryFixtureError.lock(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            descriptor = -1
            throw ArchiveRepositoryFixtureError.lock(lockError)
        }
    }

    func unlock() {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        unlock()
    }
}

private enum ArchiveRepositoryFixtureError: Error {
    case sqlite(String)
    case lock(Int32)
}
