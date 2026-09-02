import Foundation

public actor CodexArchiveCoordinator: CodexTaskArchiving {
    private let primaryArchiver: any CodexTaskArchiving
    private let archiveStateReader: (any CodexTaskArchiveStateReading)?
    private let defaults: UserDefaults
    private let storageKey: String
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var pendingTaskIDs: Set<String>
    private var lastRetryAttempt: Date?
    private var operationTail: Task<Void, Never>?

    public init(
        primaryArchiver: any CodexTaskArchiving,
        archiveStateReader: (any CodexTaskArchiveStateReading)? = nil,
        defaultsSuiteName: String? = nil,
        storageKey: String = "task-deck-for-codex.pending-archives.v1",
        retryInterval: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.primaryArchiver = primaryArchiver
        self.archiveStateReader = archiveStateReader
        self.defaults = defaults
        self.storageKey = storageKey
        self.retryInterval = max(0, retryInterval)
        self.now = now
        self.pendingTaskIDs = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    public func setArchived(
        _ archived: Bool,
        taskID: String
    ) async throws -> CodexTaskArchiveResult {
        let previousOperation = operationTail
        let operation = Task<CodexTaskArchiveResult, Error> {
            await previousOperation?.value
            return try await self.performArchiveUpdate(archived, taskID: taskID)
        }
        operationTail = Task {
            _ = try? await operation.value
        }
        return try await operation.value
    }

    public func retryPendingArchives() async throws {
        let previousOperation = operationTail
        let operation = Task<Void, Error> {
            await previousOperation?.value
            try await self.performPendingArchiveRetry()
        }
        operationTail = Task {
            _ = try? await operation.value
        }
        try await operation.value
    }

    public func pendingArchiveTaskIDs() async -> Set<String> {
        let pendingOperation = operationTail
        await pendingOperation?.value
        return pendingTaskIDs
    }

    private func performArchiveUpdate(
        _ archived: Bool,
        taskID: String
    ) async throws -> CodexTaskArchiveResult {
        if archived, pendingTaskIDs.contains(taskID) {
            return .deferred
        }
        if !archived, pendingTaskIDs.contains(taskID) {
            if let archiveStateReader,
               try await !archiveStateReader.isTaskUnarchived(taskID)
            {
                _ = try await primaryArchiver.setArchived(false, taskID: taskID)
            }
            pendingTaskIDs.remove(taskID)
            savePendingTaskIDs()
            return .completed
        }

        do {
            let result = try await primaryArchiver.setArchived(archived, taskID: taskID)
            if pendingTaskIDs.remove(taskID) != nil {
                savePendingTaskIDs()
            }
            return result
        } catch CodexRepositoryError.codexTaskHasActiveWriter where archived {
            pendingTaskIDs.insert(taskID)
            lastRetryAttempt = now()
            savePendingTaskIDs()
            return .deferred
        }
    }

    private func performPendingArchiveRetry() async throws {
        guard !pendingTaskIDs.isEmpty else { return }

        let attemptDate = now()
        if let lastRetryAttempt,
           attemptDate.timeIntervalSince(lastRetryAttempt) < retryInterval
        {
            return
        }
        lastRetryAttempt = attemptDate

        var didChange = false
        var firstError: (any Error)?
        defer {
            if didChange {
                savePendingTaskIDs()
            }
        }
        for taskID in pendingTaskIDs.sorted() {
            if let archiveStateReader {
                do {
                    if try await !archiveStateReader.isTaskUnarchived(taskID) {
                        pendingTaskIDs.remove(taskID)
                        didChange = true
                        continue
                    }
                } catch {
                    if firstError == nil { firstError = error }
                    continue
                }
            }
            do {
                _ = try await primaryArchiver.setArchived(true, taskID: taskID)
                pendingTaskIDs.remove(taskID)
                didChange = true
            } catch CodexRepositoryError.codexTaskHasActiveWriter {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func savePendingTaskIDs() {
        defaults.set(pendingTaskIDs.sorted(), forKey: storageKey)
    }
}
