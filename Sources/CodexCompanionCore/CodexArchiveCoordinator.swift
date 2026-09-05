import Foundation

public actor CodexArchiveCoordinator: CodexTaskArchiving, CodexTaskArchiveUndoing {
    private struct UndoReceipt {
        var archivedTaskIDs: Set<String> = []
        var unreconciledTaskIDs: Set<String> = []
        var restoredTaskIDs: Set<String> = []
    }

    private let primaryArchiver: any CodexTaskArchiving
    private let archiveStateReader: any CodexTaskArchiveStateReading
    private let defaults: UserDefaults
    private let storageKey: String
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var pendingTaskIDs: Set<String>
    private var lastRetryAttempt: Date?
    private var operationTail: Task<Void, Never>?
    private var undoReceipts: [String: UndoReceipt] = [:]

    public init(
        primaryArchiver: any CodexTaskArchiving,
        archiveStateReader: any CodexTaskArchiveStateReading,
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

    @discardableResult
    public func undoArchive(taskID: String) async throws -> Set<String> {
        let previousOperation = operationTail
        let operation = Task<Set<String>, Error> {
            await previousOperation?.value
            return try await self.performArchiveUndo(taskID: taskID)
        }
        operationTail = Task {
            _ = try? await operation.value
        }
        return try await operation.value
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
            if try await !archiveStateReader.isTaskUnarchived(taskID) {
                _ = try await primaryArchiver.setArchived(false, taskID: taskID)
            }
            pendingTaskIDs.remove(taskID)
            undoReceipts.removeValue(forKey: taskID)
            savePendingTaskIDs()
            return .completed
        }

        do {
            let result: CodexTaskArchiveResult
            if archived {
                result = try await performRecordedArchive(taskID: taskID, startsNewArchive: true)
            } else {
                result = try await primaryArchiver.setArchived(false, taskID: taskID)
                undoReceipts.removeValue(forKey: taskID)
            }
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

    private func performRecordedArchive(
        taskID: String,
        startsNewArchive: Bool
    ) async throws -> CodexTaskArchiveResult {
        if !startsNewArchive {
            try await reconcileUndoReceipt(taskID: taskID)
        }
        let states = try await archiveStateReader.archiveStatesInSubtree(taskID: taskID)
        if startsNewArchive {
            undoReceipts[taskID] = UndoReceipt()
        }
        undoReceipts[taskID, default: UndoReceipt()].unreconciledTaskIDs = Set(
            states.compactMap { $0.value ? nil : $0.key }
        )

        let result: Result<CodexTaskArchiveResult, any Error>
        do {
            result = .success(try await primaryArchiver.setArchived(true, taskID: taskID))
        } catch {
            result = .failure(error)
        }
        // A failed response can follow a partial or completed mutation. Keep the
        // before-snapshot if this read fails, so Undo can reconcile it later.
        try? await reconcileUndoReceipt(taskID: taskID)
        return try result.get()
    }

    private func reconcileUndoReceipt(taskID: String) async throws {
        guard let receipt = undoReceipts[taskID],
              !receipt.unreconciledTaskIDs.isEmpty
        else { return }
        let states = try await archiveStateReader.archiveStatesInSubtree(taskID: taskID)
        undoReceipts[taskID]?.archivedTaskIDs.formUnion(
            receipt.unreconciledTaskIDs.filter { states[$0] == true }
        )
        undoReceipts[taskID]?.unreconciledTaskIDs.removeAll()
    }

    private func performArchiveUndo(taskID: String) async throws -> Set<String> {
        let wasPending = pendingTaskIDs.remove(taskID) != nil
        if wasPending {
            savePendingTaskIDs()
        }
        guard undoReceipts[taskID] != nil else {
            // Pending requests survive relaunch; their session-local Undo notice does not.
            if wasPending { return [taskID] }
            throw CodexRepositoryError.archiveUndoUnavailable
        }
        if wasPending {
            undoReceipts[taskID]?.restoredTaskIDs.insert(taskID)
        }
        try await reconcileUndoReceipt(taskID: taskID)
        let states = try await archiveStateReader.archiveStatesInSubtree(taskID: taskID)
        var firstError: (any Error)?
        for archivedTaskID in undoReceipts[taskID]?.archivedTaskIDs.sorted() ?? [] {
            do {
                if states[archivedTaskID] == true {
                    _ = try await primaryArchiver.setArchived(false, taskID: archivedTaskID)
                }
                if states[archivedTaskID] != nil {
                    undoReceipts[taskID]?.restoredTaskIDs.insert(archivedTaskID)
                }
                undoReceipts[taskID]?.archivedTaskIDs.remove(archivedTaskID)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return undoReceipts.removeValue(forKey: taskID)?.restoredTaskIDs ?? []
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
            do {
                _ = try await performRecordedArchive(taskID: taskID, startsNewArchive: false)
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
