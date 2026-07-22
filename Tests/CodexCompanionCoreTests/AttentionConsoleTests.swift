import CodexCompanionCore
import Foundation
import Observation
import Synchronization
import Testing

@Suite
@MainActor
struct AttentionConsoleTests {
    @Test
    func exposesWhetherAnAvailableTaskIsActuallyOnTheConsole() {
        let historical = "historical"
        let storage = TestVisibilityStorage(
            ledger: VisibilityLedger(
                isBootstrapped: true,
                knownTaskIDs: [historical],
                monitoredTaskIDs: [],
                hiddenTaskIDs: []
            )
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: []),
            archiver: TestTaskArchiver(),
            storage: storage,
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        #expect(!console.isMonitored(historical))

        let membershipChangeWasObserved = Mutex(false)
        withObservationTracking {
            _ = console.isMonitored(historical)
        } onChange: {
            membershipChangeWasObserved.withLock { $0 = true }
        }

        console.enable(historical)
        #expect(console.isMonitored(historical))
        #expect(membershipChangeWasObserved.withLock { $0 })

        console.hide(historical)
        #expect(!console.isMonitored(historical))
    }

    @Test
    func titleOverridesAreTrimmedPersistedAndRemovable() async {
        let task = codexTask(
            "task",
            title: "Generated title",
            status: .inactive
        )
        let titles = TestTaskTitleStorage()
        let visibility = TestVisibilityStorage()
        let loader = StaticTaskLoader(tasks: [task])
        let projectOrder = TestProjectOrderStorage()
        let console = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: titles,
            projectOrderStorage: projectOrder
        )
        await console.refresh()

        let titleChangeWasObserved = Mutex(false)
        withObservationTracking {
            _ = console.allTasks.first?.title
        } onChange: {
            titleChangeWasObserved.withLock { $0 = true }
        }

        console.setTitle("  My local title  ", for: task.id)
        #expect(console.allTasks.first?.title == "My local title")
        #expect(titleChangeWasObserved.withLock { $0 })
        #expect(TaskGrouping.sections(from: console.allTasks, matching: "local").count == 1)

        let relaunched = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: titles,
            projectOrderStorage: projectOrder
        )
        await relaunched.refresh()
        #expect(relaunched.allTasks.first?.title == "My local title")

        relaunched.setTitle("  \n ", for: task.id)
        #expect(relaunched.allTasks.first?.title == "Generated title")
        #expect(TaskGrouping.sections(from: relaunched.allTasks, matching: "Generated").count == 1)
        #expect(titles.load().isEmpty)
    }

    @Test
    func archiveRemovesTaskAndUndoReloadsIt() async {
        let task = codexTask(
            "task",
            title: "Task to archive",
            status: .inactive
        )
        let archiver = TestTaskArchiver()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: archiver,
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        #expect(await console.setArchived(true, for: task.id))
        #expect(console.allTasks.isEmpty)
        #expect(await archiver.isArchived(task.id))

        #expect(await console.setArchived(false, for: task.id))
        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(await !archiver.isArchived(task.id))
    }

    @Test
    func restoreKeepsARefreshFailureVisible() async {
        let console = AttentionConsole(
            loader: FailingTaskLoader(),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        #expect(await console.setArchived(false, for: "task"))
        #expect(console.errorMessage == "Could not reload tasks")
    }

    @Test
    func pinnedTaskCustomTitleAndProjectOrderSurviveRelaunch() async {
        let task = codexTask(
            "task",
            title: "Generated title",
            projectKey: "/code/project",
            projectName: "project",
            status: .inactive
        )
        let loader = StaticTaskLoader(tasks: [task])
        let visibility = TestVisibilityStorage()
        let titles = TestTaskTitleStorage()
        let projectOrder = TestProjectOrderStorage()
        let console = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: titles,
            projectOrderStorage: projectOrder
        )
        await console.refresh()

        console.enable(task.id)
        console.setTitle("My task", for: task.id)
        console.setProjectOrder(["/code/project", "chats"])

        let relaunched = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: titles,
            projectOrderStorage: projectOrder
        )
        await relaunched.refresh()

        #expect(relaunched.isMonitored(task.id))
        #expect(relaunched.allTasks.first?.title == "My task")
        #expect(relaunched.projectOrderIDs == ["/code/project", "chats"])
    }

    @Test
    func unchangedRefreshDoesNotRepublishTaskOrLedgerState() async {
        let task = codexTask(
            "task",
            title: "Stable task",
            status: .working,
            workingSince: .now
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        let taskStateWasRepublished = Mutex(false)
        withObservationTracking {
            _ = console.monitoredTasks
        } onChange: {
            taskStateWasRepublished.withLock { $0 = true }
        }

        await console.refresh()

        #expect(!taskStateWasRepublished.withLock { $0 })
    }

    @Test
    func optionalTaskKindsAreNotAutomaticallyPinnedWhenEnabled() async {
        let agent = codexTask(
            "agent",
            title: "Internal agent",
            kind: .agent,
            status: .working
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [agent]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(
                ledger: VisibilityLedger(isBootstrapped: true)
            ),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        console.setIncludedTaskKinds([.regular, .automation, .agent])
        await console.refresh()

        #expect(console.allTasks.map(\.id) == ["agent"])
        #expect(!console.isMonitored(agent.id))
    }

    @Test
    func optionalOnlyFirstRefreshStillBootstrapsFromAllDefaultTasks() async {
        let inactiveRegular = codexTask(
            "old-regular",
            title: "Old regular task",
            status: .inactive
        )
        let workingAutomation = codexTask(
            "working-automation",
            title: "Working automation",
            kind: .automation,
            status: .working
        )
        let agent = codexTask(
            "agent",
            title: "Agent",
            kind: .agent,
            status: .working
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [inactiveRegular, workingAutomation, agent]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        console.setIncludedTaskKinds([.agent])
        await console.refresh()

        #expect(console.allTasks.map(\.id) == [agent.id])
        #expect(!console.isMonitored(agent.id))

        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible)
        await console.refresh()

        #expect(!console.isMonitored(inactiveRegular.id))
        #expect(console.isMonitored(workingAutomation.id))
    }

    @Test
    func deselectedTaskKindsDisappearBeforeTheRefreshCompletes() async {
        let regular = codexTask(
            "regular",
            title: "Regular",
            status: .inactive
        )
        let agent = codexTask(
            "agent",
            title: "Agent",
            kind: .agent,
            status: .inactive
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [regular, agent]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible.union([.agent]))
        await console.refresh()
        #expect(console.allTasks.map(\.id) == [regular.id, agent.id])

        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible)

        #expect(console.allTasks.map(\.id) == [regular.id])
    }

    @Test
    func openingFinishedTaskMakesItInactiveAndPersistsAcknowledgement() async {
        let launchedAt = Date(timeIntervalSince1970: 1_000)
        let workingTask = codexTask(
            "finished",
            title: "Finished task",
            status: .working,
            updatedAt: launchedAt.addingTimeInterval(-1)
        )
        let finishedTask = codexTask(
            workingTask.id,
            title: workingTask.title,
            status: .finished,
            updatedAt: launchedAt.addingTimeInterval(1),
            finishedAt: launchedAt.addingTimeInterval(1)
        )
        let visibility = TestVisibilityStorage(
            ledger: VisibilityLedger(
                isBootstrapped: true,
                knownTaskIDs: [workingTask.id],
                monitoredTaskIDs: [workingTask.id]
            )
        )
        let loader = SequenceTaskLoader(taskSets: [[workingTask], [finishedTask]])
        let console = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            launchedAt: launchedAt
        )
        await console.refresh()
        #expect(console.allTasks.first?.status == .working)

        await console.refresh()
        #expect(console.allTasks.first?.status == .finished)

        console.markInactiveAfterOpening(workingTask.id)
        #expect(console.allTasks.first?.status == .inactive)

        let relaunched = AttentionConsole(
            loader: StaticTaskLoader(tasks: [finishedTask]),
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            launchedAt: launchedAt.addingTimeInterval(2)
        )
        await relaunched.refresh()
        #expect(relaunched.allTasks.first?.status == .inactive)
    }

    @Test
    func taskCompletedBeforeLaunchStartsInactiveDespiteNewerDatabaseRecency() async {
        let launchedAt = Date(timeIntervalSince1970: 1_000)
        let finishedTask = codexTask(
            "finished-before-launch",
            title: "Finished before launch",
            status: .finished,
            updatedAt: launchedAt.addingTimeInterval(1),
            finishedAt: launchedAt.addingTimeInterval(-1)
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [finishedTask]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(
                ledger: VisibilityLedger(
                    isBootstrapped: true,
                    knownTaskIDs: [finishedTask.id],
                    monitoredTaskIDs: [finishedTask.id]
                )
            ),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            launchedAt: launchedAt
        )

        await console.refresh()

        #expect(console.allTasks.first?.status == .inactive)
    }

    @Test
    func historicalOptionalTaskFirstRevealedAfterLaunchStartsInactive() async {
        let launchedAt = Date(timeIntervalSince1970: 1_000)
        let historicalAgent = codexTask(
            "historical-agent",
            title: "Historical agent",
            kind: .agent,
            status: .finished,
            updatedAt: launchedAt.addingTimeInterval(1),
            finishedAt: launchedAt.addingTimeInterval(-1)
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [historicalAgent]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            launchedAt: launchedAt
        )

        await console.refresh()
        #expect(console.allTasks.isEmpty)

        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible.union([.agent]))
        await console.refresh()

        #expect(console.allTasks.first?.status == .inactive)
        #expect(!console.isMonitored(historicalAgent.id))
    }

    @Test
    func optionalTaskCompletedAfterLaunchNeedsAttentionDespiteOlderDatabaseRecency() async {
        let launchedAt = Date(timeIntervalSince1970: 1_000)
        let newlyFinishedAgent = codexTask(
            "new-agent",
            title: "New agent",
            kind: .agent,
            status: .finished,
            updatedAt: launchedAt.addingTimeInterval(-1),
            finishedAt: launchedAt.addingTimeInterval(1)
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [newlyFinishedAgent]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            launchedAt: launchedAt
        )

        await console.refresh()
        #expect(console.allTasks.isEmpty)

        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible.union([.agent]))
        await console.refresh()

        #expect(console.allTasks.first?.status == .finished)
        #expect(!console.isMonitored(newlyFinishedAgent.id))
    }
}

private struct StaticTaskLoader: CodexTaskLoading {
    let tasks: [CodexTask]
    func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot {
        snapshot(for: tasks.filter { kinds.contains($0.kind) })
    }
}

private struct FailingTaskLoader: CodexTaskLoading {
    func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot {
        throw TestLoaderError()
    }
}

private struct TestLoaderError: LocalizedError {
    var errorDescription: String? { "Could not reload tasks" }
}

private actor SequenceTaskLoader: CodexTaskLoading {
    private var taskSets: [[CodexTask]]

    init(taskSets: [[CodexTask]]) {
        self.taskSets = taskSets
    }

    func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot {
        guard taskSets.count > 1 else { return snapshot(for: taskSets.first ?? []) }
        return snapshot(for: taskSets.removeFirst())
    }
}

private actor TestTaskArchiver: CodexTaskArchiving {
    private var archivedTaskIDs: Set<String> = []

    func setArchived(_ archived: Bool, taskID: String) async throws {
        if archived {
            archivedTaskIDs.insert(taskID)
        } else {
            archivedTaskIDs.remove(taskID)
        }
    }

    func isArchived(_ taskID: String) -> Bool {
        archivedTaskIDs.contains(taskID)
    }
}

private func codexTask(
    _ id: String,
    title: String,
    projectKey: String = "project",
    projectName: String = "Project",
    projectPath: String = "/code/project",
    kind: CodexTaskKind = .regular,
    status: AttentionStatus,
    updatedAt: Date = .now,
    workingSince: Date? = nil,
    finishedAt: Date? = nil
) -> CodexTask {
    CodexTask(
        id: id,
        title: title,
        projectKey: projectKey,
        projectName: projectName,
        projectPath: projectPath,
        isChat: false,
        kind: kind,
        status: status,
        updatedAt: updatedAt,
        workingSince: workingSince,
        finishedAt: finishedAt
    )
}

private func snapshot(for tasks: [CodexTask]) -> CodexTaskSnapshot {
    var seen: Set<String> = []
    let projects = tasks.compactMap { task -> ProjectIdentity? in
        guard seen.insert(task.projectKey).inserted else { return nil }
        return ProjectIdentity(
            key: task.projectKey,
            name: task.projectName,
            path: task.projectPath,
            isChat: task.isChat
        )
    }
    return CodexTaskSnapshot(tasks: tasks, projects: projects)
}

@MainActor
private final class TestVisibilityStorage: VisibilityStoring {
    private var ledger: VisibilityLedger

    init(ledger: VisibilityLedger = VisibilityLedger()) {
        self.ledger = ledger
    }

    func load() -> VisibilityLedger { ledger }
    func save(_ ledger: VisibilityLedger) { self.ledger = ledger }
}

@MainActor
private final class TestTaskTitleStorage: TaskTitleStoring {
    private var titles: [String: String]

    init(titles: [String: String] = [:]) {
        self.titles = titles
    }

    func load() -> [String: String] { titles }
    func save(_ titles: [String: String]) { self.titles = titles }
}

@MainActor
private final class TestProjectOrderStorage: ProjectOrderStoring {
    private var projectIDs: [String]

    init(projectIDs: [String] = []) {
        self.projectIDs = projectIDs
    }

    func load() -> [String] { projectIDs }
    func save(_ projectIDs: [String]) { self.projectIDs = projectIDs }
}
