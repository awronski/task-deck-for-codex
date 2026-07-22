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

    @ObservationIgnored private let loader: any CodexTaskLoading
    @ObservationIgnored private let archiver: any CodexTaskArchiving
    @ObservationIgnored private let storage: any VisibilityStoring
    @ObservationIgnored private let titleStorage: any TaskTitleStoring
    @ObservationIgnored private let projectOrderStorage: any ProjectOrderStoring
    @ObservationIgnored private let launchedAt: Date
    private var ledger: VisibilityLedger
    private var titleOverrides: [String: String]
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
        projectOrderStorage: any ProjectOrderStoring,
        launchedAt: Date = .now
    ) {
        self.loader = loader
        self.archiver = archiver
        self.storage = storage
        self.titleStorage = titleStorage
        self.projectOrderStorage = projectOrderStorage
        self.launchedAt = launchedAt
        self.ledger = storage.load()
        self.titleOverrides = titleStorage.load()
        self.projectOrderIDs = projectOrderStorage.load()
    }

    public var allTasks: [CodexTask] {
        sourceTasks.map(taskWithDisplayTitle)
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
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await refresh(showsActivity: false)
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

    private func taskWithDisplayTitle(_ task: CodexTask) -> CodexTask {
        let title = titleOverrides[task.id] ?? task.title
        let status: AttentionStatus = task.status == .finished && ledger.isFinishedAcknowledged(task.id)
            ? .inactive
            : task.status
        guard title != task.title || status != task.status else { return task }
        return CodexTask(
            id: task.id,
            title: title,
            projectKey: task.projectKey,
            projectName: task.projectName,
            projectPath: task.projectPath,
            isChat: task.isChat,
            kind: task.kind,
            status: status,
            updatedAt: task.updatedAt,
            workingSince: task.workingSince,
            finishedAt: task.finishedAt,
            createdAt: task.createdAt
        )
    }
}
