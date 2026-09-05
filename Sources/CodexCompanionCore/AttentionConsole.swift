import Foundation
import Observation

@Observable
@MainActor
public final class AttentionConsole {
    private var sourceTasks: [CodexTask] = []
    public private(set) var projects: [ProjectIdentity] = []
    public private(set) var lastUpdated: Date?
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    public private(set) var triggeredReminders: [TaskReminder] = []
    public private(set) var missedReminders: [TaskReminder] = []
    public private(set) var reminderSoundSequence = 0
    public private(set) var pendingArchiveTaskIDs: Set<String> = []

    @ObservationIgnored private let loader: any CodexTaskLoading
    @ObservationIgnored private let archiver: any CodexTaskArchiving & CodexTaskArchiveUndoing
    @ObservationIgnored private let archiveStateReader: (any CodexTaskArchiveStateReading)?
    @ObservationIgnored private let renamer: (any CodexTaskRenaming)?
    @ObservationIgnored private let storage: any VisibilityStoring
    @ObservationIgnored private let titleStorage: any TaskTitleStoring
    @ObservationIgnored private let priorityStorage: any TaskPriorityStoring
    @ObservationIgnored private let noteStorage: any TaskNoteStoring
    @ObservationIgnored private let reminderStorage: any TaskReminderStoring
    @ObservationIgnored private let projectOrderStorage: any ProjectOrderStoring
    @ObservationIgnored private let projectAppearanceStorage: (any ProjectAppearanceStoring)?
    @ObservationIgnored private let launchedAt: Date
    private var ledger: VisibilityLedger
    private var titleOverrides: [String: String]
    private var priorities: [String: TaskPriority]
    private var notes: [String: String]
    private var reminders: [String: TaskReminder]
    public private(set) var projectOrderIDs: [String]
    public private(set) var projectAppearances: [String: ProjectAppearance]
    public private(set) var includedTaskKinds = CodexTaskKind.defaultVisible
    public var automaticallyFocusStartedTasks = true
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var archiveMutationRevision: UInt64 = 0
    @ObservationIgnored private var archiveUndosInFlight = 0
    @ObservationIgnored private var restoredTaskIDsAwaitingSnapshot: Set<String> = []

    public init(
        loader: any CodexTaskLoading,
        archiver: any CodexTaskArchiving & CodexTaskArchiveUndoing,
        storage: any VisibilityStoring,
        titleStorage: any TaskTitleStoring,
        priorityStorage: any TaskPriorityStoring,
        noteStorage: any TaskNoteStoring = UserDefaultsTaskNoteStorage(),
        reminderStorage: any TaskReminderStoring = UserDefaultsTaskReminderStorage(),
        projectOrderStorage: any ProjectOrderStoring,
        projectAppearanceStorage: (any ProjectAppearanceStoring)? = nil,
        renamer: (any CodexTaskRenaming)? = nil,
        launchedAt: Date = .now,
        archiveStateReader: (any CodexTaskArchiveStateReading)? = nil
    ) {
        self.loader = loader
        self.archiver = archiver
        self.archiveStateReader = archiveStateReader
        self.renamer = renamer
        self.storage = storage
        self.titleStorage = titleStorage
        self.priorityStorage = priorityStorage
        self.noteStorage = noteStorage
        self.reminderStorage = reminderStorage
        self.projectOrderStorage = projectOrderStorage
        self.projectAppearanceStorage = projectAppearanceStorage
        self.launchedAt = launchedAt
        self.ledger = storage.load()
        self.titleOverrides = titleStorage.load()
        self.priorities = priorityStorage.load()
        self.notes = noteStorage.load()
        self.reminders = reminderStorage.load()
        self.projectOrderIDs = projectOrderStorage.load()
        self.projectAppearances = projectAppearanceStorage?.load() ?? [:]
    }

    public var allTasks: [CodexTask] {
        sourceTasks.filter { includedTaskKinds.contains($0.kind) }.map(taskWithDisplayPreferences)
    }

    public var monitoredTasks: [CodexTask] {
        allTasks.filter {
            !pendingArchiveTaskIDs.contains($0.id) && ledger.isMonitored($0.id)
        }
    }

    public var focusedTaskIDs: [String] {
        ledger.focusedTaskIDs
    }

    public var focusCandidates: [CodexTask] {
        sourceTasks.filter {
            ledger.isMonitored($0.id) && !pendingArchiveTaskIDs.contains($0.id)
        }.map(taskWithDisplayPreferences)
    }

    public var focusedTasks: [CodexTask] {
        let tasksByID = Dictionary(uniqueKeysWithValues: focusCandidates.map { ($0.id, $0) })
        return focusedTaskIDs.compactMap { tasksByID[$0] }
    }

    public var outsideFocusAttentionTasks: [CodexTask] {
        let focusedIDs = Set(focusedTaskIDs)
        return focusCandidates.filter { task in
            guard !focusedIDs.contains(task.id) else { return false }
            switch task.status {
            case .waitingForInput, .waitingForPermission, .error: return true
            case .working, .finished, .inactive: return false
            }
        }
    }

    public func setFocusedTasks(_ taskIDs: [String]) {
        let previousIDs = ledger.focusedTaskIDs
        let eligibleIDs = Set(focusCandidates.map(\.id)).union(previousIDs)
        ledger.setFocusedTasks(taskIDs.filter {
            eligibleIDs.contains($0) && !pendingArchiveTaskIDs.contains($0)
        })
        guard ledger.focusedTaskIDs != previousIDs else { return }
        storage.save(ledger)
    }

    public func restoreFocusedTasks(_ taskIDs: Set<String>, from previousIDs: [String]) {
        let currentIDs = ledger.focusedTaskIDs
        var restoredIDs = currentIDs
        for (index, taskID) in previousIDs.enumerated() {
            guard taskIDs.contains(taskID), ledger.isMonitored(taskID),
                  !pendingArchiveTaskIDs.contains(taskID), !restoredIDs.contains(taskID)
            else { continue }

            if let predecessor = previousIDs[..<index].last(where: { restoredIDs.contains($0) }),
               let insertionIndex = restoredIDs.firstIndex(of: predecessor)
            {
                restoredIDs.insert(taskID, at: insertionIndex + 1)
            } else if let successor = previousIDs[(index + 1)...].first(where: { restoredIDs.contains($0) }),
                      let insertionIndex = restoredIDs.firstIndex(of: successor)
            {
                restoredIDs.insert(taskID, at: insertionIndex)
            } else {
                restoredIDs.append(taskID)
            }
        }
        ledger.setFocusedTasks(restoredIDs)
        guard ledger.focusedTaskIDs != currentIDs else { return }
        storage.save(ledger)
    }

    public func isMonitored(_ taskID: String) -> Bool {
        sourceTasks.contains { $0.id == taskID }
            && !pendingArchiveTaskIDs.contains(taskID)
            && ledger.isMonitored(taskID)
    }

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            processDueReminders(at: .now, groupingAsMissed: true)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await refresh(showsActivity: false)
                processDueReminders(at: .now, groupingAsMissed: false)
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func refresh() async {
        await refresh(showsActivity: true)
    }

    private func refresh(showsActivity: Bool) async {
        guard !refreshInFlight, archiveUndosInFlight == 0 else {
            refreshRequested = true
            return
        }
        let refreshArchiveRevision = archiveMutationRevision
        refreshInFlight = true
        if showsActivity {
            isRefreshing = true
        }
        defer {
            if showsActivity {
                isRefreshing = false
            }
            refreshInFlight = false
            if refreshRequested {
                refreshRequested = false
                Task { [weak self] in
                    await self?.refresh(showsActivity: false)
                }
            }
        }

        do {
            let requestedKinds = includedTaskKinds
            var latestPendingArchiveTaskIDs = await archiver.pendingArchiveTaskIDs()
            var loadedKinds = requestedKinds.union(CodexTaskKind.defaultVisible)
            if !latestPendingArchiveTaskIDs.isEmpty {
                loadedKinds.formUnion(CodexTaskKind.allCases)
            }
            var snapshot = try await loader.loadSnapshot(
                including: loadedKinds,
                alwaysIncluding: ledger.monitoredTaskIDs
            )
            var loadedTasks = snapshot.tasks
            let newlyActiveTaskIDs = Set(
                loadedTasks.lazy.filter(\.status.isActive).map(\.id)
            ).subtracting(ledger.activeTaskIDs)
            let resumedPendingArchiveTaskIDs = latestPendingArchiveTaskIDs.intersection(
                newlyActiveTaskIDs
            )
            for taskID in resumedPendingArchiveTaskIDs {
                _ = try await archiver.setArchived(false, taskID: taskID)
            }
            latestPendingArchiveTaskIDs = await archiver.pendingArchiveTaskIDs()

            let pendingArchiveTaskIDsBeforeRetry = latestPendingArchiveTaskIDs
            var retryError: (any Error)?
            do {
                try await archiver.retryPendingArchives()
            } catch {
                retryError = error
            }
            latestPendingArchiveTaskIDs = await archiver.pendingArchiveTaskIDs()
            if latestPendingArchiveTaskIDs != pendingArchiveTaskIDsBeforeRetry {
                snapshot = try await loader.loadSnapshot(
                    including: loadedKinds,
                    alwaysIncluding: ledger.monitoredTaskIDs
                )
                loadedTasks = snapshot.tasks
            }

            var removedFocusTaskIDs = latestPendingArchiveTaskIDs
            if let archiveStateReader {
                let loadedTaskIDs = Set(loadedTasks.map(\.id))
                for taskID in ledger.focusedTaskIDs where !loadedTaskIDs.contains(taskID) {
                    do {
                        if try await !archiveStateReader.isTaskUnarchived(taskID) {
                            removedFocusTaskIDs.insert(taskID)
                        }
                    } catch {
                        // Missing titles or a failed state read must not erase the selection.
                        if retryError == nil { retryError = error }
                    }
                }
            }

            guard refreshArchiveRevision == archiveMutationRevision else {
                refreshRequested = true
                return
            }
            var reconciledLedger = ledger
            reconciledLedger.reconcileFinishedStates(with: loadedTasks)
            reconciledLedger.reconcileMembership(
                with: loadedTasks.filter { CodexTaskKind.defaultVisible.contains($0.kind) },
                observing: loadedTasks
            )
            reconciledLedger.setFocusedTasks(
                reconciledLedger.focusedTaskIDs.filter { !removedFocusTaskIDs.contains($0) }
            )
            if automaticallyFocusStartedTasks, lastUpdated != nil {
                let startedTasks = loadedTasks.filter { task in
                    reconciledLedger.isMonitored(task.id)
                        && !removedFocusTaskIDs.contains(task.id)
                        && !restoredTaskIDsAwaitingSnapshot.contains(task.id)
                        && (!ledger.knownTaskIDs.contains(task.id)
                            || (task.status.isActive && !ledger.activeTaskIDs.contains(task.id)))
                }.sorted {
                    $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
                }
                reconciledLedger.setFocusedTasks(
                    reconciledLedger.focusedTaskIDs + startedTasks.map(\.id)
                )
            }
            // Keep exclusions through coalesced refreshes or temporary absence;
            // after observation, a later inactive-to-active transition is a new start.
            restoredTaskIDsAwaitingSnapshot.subtract(loadedTasks.map(\.id))
            for task in loadedTasks
            where task.status == .finished && task.finishedAt.map({ $0 <= launchedAt }) == true
            {
                reconciledLedger.acknowledgeFinished(taskID: task.id, finishedAt: task.finishedAt)
            }

            let tasksChanged = loadedTasks != sourceTasks
            let projectsChanged = snapshot.projects != projects
            let pendingArchivesChanged = latestPendingArchiveTaskIDs != pendingArchiveTaskIDs
            let ledgerChanged = reconciledLedger != ledger
            let recoveredFromError = errorMessage != nil

            if ledgerChanged {
                ledger = reconciledLedger
                storage.save(ledger)
            }
            if tasksChanged {
                sourceTasks = loadedTasks
            }
            if projectsChanged {
                projects = snapshot.projects
            }
            if pendingArchivesChanged {
                pendingArchiveTaskIDs = latestPendingArchiveTaskIDs
            }
            if lastUpdated == nil
                || tasksChanged
                || projectsChanged
                || pendingArchivesChanged
                || recoveredFromError
            {
                lastUpdated = Date()
            }
            if recoveredFromError {
                errorMessage = nil
            }
            if let retryError {
                throw retryError
            }
        } catch {
            guard refreshArchiveRevision == archiveMutationRevision else {
                refreshRequested = true
                return
            }
            let message = error.localizedDescription
            if errorMessage != message {
                errorMessage = message
            }
        }
    }

    public func hide(_ taskID: String) {
        ledger.hide(taskID: taskID)
        storage.save(ledger)
    }

    public func enable(_ taskID: String) {
        ledger.enable(taskID: taskID)
        storage.save(ledger)
    }

    public func setArchived(
        _ archived: Bool,
        for taskID: String
    ) async -> CodexTaskArchiveResult? {
        archiveMutationRevision &+= 1
        defer {
            archiveMutationRevision &+= 1
            if refreshInFlight { refreshRequested = true }
        }
        do {
            let result = try await archiver.setArchived(archived, taskID: taskID)
            pendingArchiveTaskIDs = await archiver.pendingArchiveTaskIDs()
            if archived {
                setFocusedTasks(focusedTaskIDs.filter { $0 != taskID })
                if result == .completed {
                    sourceTasks.removeAll { $0.id == taskID }
                    lastUpdated = Date()
                }
            } else {
                await refresh(showsActivity: false)
            }
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func undoArchive(
        for taskID: String,
        restoringFocusFrom previousFocusIDs: [String] = []
    ) async -> Bool {
        archiveMutationRevision &+= 1
        defer {
            archiveMutationRevision &+= 1
            if refreshInFlight { refreshRequested = true }
        }
        let restoredTaskIDs: Set<String>
        archiveUndosInFlight += 1
        do {
            // Polling must not classify restored tasks before Undo returns their IDs.
            defer { archiveUndosInFlight -= 1 }
            restoredTaskIDs = try await archiver.undoArchive(taskID: taskID)
            restoredTaskIDsAwaitingSnapshot.formUnion(restoredTaskIDs)
            pendingArchiveTaskIDs = await archiver.pendingArchiveTaskIDs()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        await refresh(showsActivity: false)
        restoreFocusedTasks(restoredTaskIDs, from: previousFocusIDs)
        return true
    }

    public func setTitle(_ title: String, for taskID: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            titleOverrides.removeValue(forKey: taskID)
        } else {
            titleOverrides[taskID] = trimmedTitle
        }
        titleStorage.save(titleOverrides)

        if let reminder = reminders[taskID] {
            let updatedTitle = trimmedTitle.isEmpty
                ? sourceTasks.first(where: { $0.id == taskID })?.title ?? reminder.title
                : trimmedTitle
            reminders[taskID] = TaskReminder(taskID: taskID, title: updatedTitle, dueAt: reminder.dueAt)
            reminderStorage.save(reminders)
        }
    }

    @discardableResult
    public func setTitle(_ title: String, for taskID: String, syncsToCodex: Bool) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        setTitle(title, for: taskID)
        guard syncsToCodex, !trimmedTitle.isEmpty else { return true }
        guard let renamer else {
            errorMessage = "Codex title syncing is unavailable."
            return false
        }

        do {
            try await renamer.setTitle(trimmedTitle, taskID: taskID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func setPriority(_ priority: TaskPriority, for taskID: String) {
        guard (priorities[taskID] ?? .none) != priority else { return }
        if priority == .none {
            priorities.removeValue(forKey: taskID)
        } else {
            priorities[taskID] = priority
        }
        priorityStorage.save(priorities)
    }

    public func note(for taskID: String) -> String {
        notes[taskID] ?? ""
    }

    public func setNote(_ note: String, for taskID: String) {
        let storedNote = String(note.prefix(2_000))
        let isEmpty = storedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let currentNote = notes[taskID] ?? ""
        let nextNote = isEmpty ? "" : storedNote
        guard currentNote != nextNote else { return }

        if isEmpty {
            notes.removeValue(forKey: taskID)
        } else {
            notes[taskID] = storedNote
        }
        noteStorage.save(notes)
    }

    public var currentTriggeredReminder: TaskReminder? {
        triggeredReminders.first
    }

    public func reminder(for taskID: String) -> TaskReminder? {
        reminders[taskID]
    }

    @discardableResult
    public func setReminder(
        for taskID: String,
        title: String,
        at dueAt: Date,
        now: Date = .now
    ) -> Bool {
        guard dueAt > now else { return false }
        removePresentedReminders(for: taskID)
        reminders[taskID] = TaskReminder(taskID: taskID, title: title, dueAt: dueAt)
        reminderStorage.save(reminders)
        return true
    }

    public func removeReminder(for taskID: String) {
        removePresentedReminders(for: taskID)
        if reminders.removeValue(forKey: taskID) != nil {
            reminderStorage.save(reminders)
        }
    }

    public func processDueReminders(at date: Date, groupingAsMissed: Bool) {
        let presentedTaskIDs = Set(triggeredReminders.map(\.taskID))
            .union(missedReminders.map(\.taskID))
        let dueReminders = reminders.values
            .filter { reminder in
                reminder.dueAt <= date
                    && !presentedTaskIDs.contains(reminder.taskID)
            }
            .sorted {
                if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
                return $0.taskID < $1.taskID
            }
            .map { reminder in
                let currentTitle = allTasks.first(where: { $0.id == reminder.taskID })?.title
                return TaskReminder(
                    taskID: reminder.taskID,
                    title: currentTitle ?? reminder.title,
                    dueAt: reminder.dueAt
                )
            }
        guard !dueReminders.isEmpty else { return }

        for reminder in dueReminders {
            ledger.enable(taskID: reminder.taskID)
        }
        storage.save(ledger)

        if groupingAsMissed {
            missedReminders.append(contentsOf: dueReminders)
            missedReminders.sort {
                if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
                return $0.taskID < $1.taskID
            }
        } else {
            triggeredReminders.append(contentsOf: dueReminders)
        }
        reminderSoundSequence &+= 1
    }

    public func dismissReminder(_ reminder: TaskReminder) {
        removePresentedReminders(for: reminder.taskID)
        guard reminders[reminder.taskID]?.dueAt == reminder.dueAt else { return }
        reminders.removeValue(forKey: reminder.taskID)
        reminderStorage.save(reminders)
    }

    public func dismissAllMissedReminders() {
        var removedStoredReminder = false
        for reminder in missedReminders where reminders[reminder.taskID]?.dueAt == reminder.dueAt {
            reminders.removeValue(forKey: reminder.taskID)
            removedStoredReminder = true
        }
        missedReminders.removeAll()
        if removedStoredReminder {
            reminderStorage.save(reminders)
        }
    }

    @discardableResult
    public func snooze(_ reminder: TaskReminder, until dueAt: Date, now: Date = .now) -> Bool {
        setReminder(for: reminder.taskID, title: reminder.title, at: dueAt, now: now)
    }

    private func removePresentedReminders(for taskID: String) {
        triggeredReminders.removeAll { $0.taskID == taskID }
        missedReminders.removeAll { $0.taskID == taskID }
    }

    public func setProjectOrder(_ projectIDs: [String]) {
        var seenProjectIDs: Set<String> = []
        let uniqueProjectIDs = projectIDs.filter { seenProjectIDs.insert($0).inserted }
        self.projectOrderIDs = uniqueProjectIDs
        projectOrderStorage.save(uniqueProjectIDs)
    }

    public func projectAppearance(for projectID: String) -> ProjectAppearance? {
        projectAppearances[projectID]
    }

    public func setProjectAppearance(_ appearance: ProjectAppearance?, for projectID: String) {
        guard !projectID.isEmpty, projectAppearances[projectID] != appearance else { return }
        if let appearance {
            projectAppearances[projectID] = appearance
        } else {
            projectAppearances.removeValue(forKey: projectID)
        }
        projectAppearanceStorage?.save(projectAppearances)
    }

    public func setIncludedTaskKinds(_ kinds: Set<CodexTaskKind>) {
        guard includedTaskKinds != kinds else { return }
        includedTaskKinds = kinds
        Task { await refresh() }
    }

    public func markInactiveAfterOpening(_ taskID: String) {
        guard let task = sourceTasks.first(where: { $0.id == taskID }),
              task.status == .finished
        else { return }
        ledger.acknowledgeFinished(taskID: taskID, finishedAt: task.finishedAt)
        storage.save(ledger)
    }

    private func taskWithDisplayPreferences(_ task: CodexTask) -> CodexTask {
        let title = titleOverrides[task.id] ?? task.title
        let priority = priorities[task.id] ?? .none
        let status: AttentionStatus = task.status == .finished && ledger.isFinishedAcknowledged(task.id)
            ? .inactive
            : task.status
        guard title != task.title || priority != task.priority || status != task.status else { return task }
        return CodexTask(
            id: task.id,
            title: title,
            projectKey: task.projectKey,
            projectName: task.projectName,
            projectPath: task.projectPath,
            isChat: task.isChat,
            kind: task.kind,
            priority: priority,
            status: status,
            modelName: task.modelName,
            thinkingEffort: task.thinkingEffort,
            activity: status == .inactive ? nil : task.activity,
            updatedAt: task.updatedAt,
            workingSince: task.workingSince,
            finishedAt: task.finishedAt,
            createdAt: task.createdAt
        )
    }
}
