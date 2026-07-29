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

    @ObservationIgnored private let loader: any CodexTaskLoading
    @ObservationIgnored private let archiver: any CodexTaskArchiving
    @ObservationIgnored private let storage: any VisibilityStoring
    @ObservationIgnored private let titleStorage: any TaskTitleStoring
    @ObservationIgnored private let priorityStorage: any TaskPriorityStoring
    @ObservationIgnored private let noteStorage: any TaskNoteStoring
    @ObservationIgnored private let reminderStorage: any TaskReminderStoring
    @ObservationIgnored private let projectOrderStorage: any ProjectOrderStoring
    @ObservationIgnored private let launchedAt: Date
    private var ledger: VisibilityLedger
    private var titleOverrides: [String: String]
    private var priorities: [String: TaskPriority]
    private var notes: [String: String]
    private var reminders: [String: TaskReminder]
    public private(set) var projectOrderIDs: [String]
    public private(set) var includedTaskKinds = CodexTaskKind.defaultVisible
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshRequested = false

    public init(
        loader: any CodexTaskLoading,
        archiver: any CodexTaskArchiving,
        storage: any VisibilityStoring,
        titleStorage: any TaskTitleStoring,
        priorityStorage: any TaskPriorityStoring,
        noteStorage: any TaskNoteStoring = UserDefaultsTaskNoteStorage(),
        reminderStorage: any TaskReminderStoring = UserDefaultsTaskReminderStorage(),
        projectOrderStorage: any ProjectOrderStoring,
        launchedAt: Date = .now
    ) {
        self.loader = loader
        self.archiver = archiver
        self.storage = storage
        self.titleStorage = titleStorage
        self.priorityStorage = priorityStorage
        self.noteStorage = noteStorage
        self.reminderStorage = reminderStorage
        self.projectOrderStorage = projectOrderStorage
        self.launchedAt = launchedAt
        self.ledger = storage.load()
        self.titleOverrides = titleStorage.load()
        self.priorities = priorityStorage.load()
        self.notes = noteStorage.load()
        self.reminders = reminderStorage.load()
        self.projectOrderIDs = projectOrderStorage.load()
    }

    public var allTasks: [CodexTask] {
        sourceTasks.map(taskWithDisplayPreferences)
    }

    public var monitoredTasks: [CodexTask] {
        allTasks.filter { ledger.isMonitored($0.id) }
    }

    public func isMonitored(_ taskID: String) -> Bool {
        ledger.isMonitored(taskID)
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
        guard !refreshInFlight else {
            refreshRequested = true
            return
        }
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
            let loadedKinds = ledger.isBootstrapped
                ? requestedKinds
                : requestedKinds.union(CodexTaskKind.defaultVisible)
            let snapshot = try await loader.loadSnapshot(including: loadedKinds)
            let loadedTasks = snapshot.tasks
            let displayedTasks = loadedTasks.filter { includedTaskKinds.contains($0.kind) }
            var reconciledLedger = ledger
            reconciledLedger.reconcileFinishedStates(with: loadedTasks)
            reconciledLedger.reconcileMembership(
                with: loadedTasks.filter { CodexTaskKind.defaultVisible.contains($0.kind) }
            )
            for task in loadedTasks
            where task.status == .finished && task.finishedAt.map({ $0 <= launchedAt }) == true
            {
                reconciledLedger.acknowledgeFinished(taskID: task.id)
            }

            let tasksChanged = displayedTasks != sourceTasks
            let projectsChanged = snapshot.projects != projects
            let ledgerChanged = reconciledLedger != ledger
            let recoveredFromError = errorMessage != nil

            if ledgerChanged {
                ledger = reconciledLedger
                storage.save(ledger)
            }
            if tasksChanged {
                sourceTasks = displayedTasks
            }
            if projectsChanged {
                projects = snapshot.projects
            }
            if lastUpdated == nil || tasksChanged || projectsChanged || recoveredFromError {
                lastUpdated = Date()
            }
            if recoveredFromError {
                errorMessage = nil
            }
        } catch {
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

    public func setArchived(_ archived: Bool, for taskID: String) async -> Bool {
        do {
            try await archiver.setArchived(archived, taskID: taskID)
            if archived {
                sourceTasks.removeAll { $0.id == taskID }
                lastUpdated = Date()
            } else {
                await refresh(showsActivity: false)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

    public func setIncludedTaskKinds(_ kinds: Set<CodexTaskKind>) {
        guard includedTaskKinds != kinds else { return }
        includedTaskKinds = kinds
        sourceTasks.removeAll { !kinds.contains($0.kind) }
        Task { await refresh() }
    }

    public func markInactiveAfterOpening(_ taskID: String) {
        guard sourceTasks.first(where: { $0.id == taskID })?.status == .finished else { return }
        ledger.acknowledgeFinished(taskID: taskID)
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
