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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
    func taskFlagsPersistAndNoFlagRemovesTheOverride() async {
        let task = codexTask(
            "task",
            title: "Prioritized task",
            status: .inactive
        )
        let priorities = TestTaskPriorityStorage()
        let loader = StaticTaskLoader(tasks: [task])
        let console = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: priorities,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        let priorityChangeWasObserved = Mutex(false)
        withObservationTracking {
            _ = console.allTasks.first?.priority
        } onChange: {
            priorityChangeWasObserved.withLock { $0 = true }
        }

        console.setPriority(.red, for: task.id)
        #expect(console.allTasks.first?.priority == .red)
        #expect(priorityChangeWasObserved.withLock { $0 })

        let relaunched = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: priorities,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await relaunched.refresh()

        #expect(relaunched.allTasks.first?.priority == .red)

        relaunched.setPriority(.none, for: task.id)
        #expect(relaunched.allTasks.first?.priority == TaskPriority.none)
        #expect(priorities.load().isEmpty)
    }

    @Test
    func taskNotesPersistAndWhitespaceClearsTheNote() async {
        let task = codexTask(
            "task",
            title: "Waiting task",
            status: .inactive
        )
        let notes = TestTaskNoteStorage()
        let loader = StaticTaskLoader(tasks: [task])
        let console = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            noteStorage: notes,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        let noteChangeWasObserved = Mutex(false)
        withObservationTracking {
            _ = console.note(for: task.id)
        } onChange: {
            noteChangeWasObserved.withLock { $0 = true }
        }

        console.setNote("Waiting for the production update.", for: task.id)
        #expect(console.note(for: task.id) == "Waiting for the production update.")
        #expect(noteChangeWasObserved.withLock { $0 })

        let relaunched = AttentionConsole(
            loader: loader,
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            noteStorage: notes,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await relaunched.refresh()

        #expect(relaunched.note(for: task.id) == "Waiting for the production update.")

        relaunched.setNote("  \n ", for: task.id)
        #expect(relaunched.note(for: task.id).isEmpty)
        #expect(notes.load().isEmpty)
    }

    @Test
    func reminderSchedulingPersistsAndReplacesTheTaskReminder() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let task = codexTask("task", title: "Deploy release", status: .inactive)
        let reminders = TestTaskReminderStorage()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        let firstDate = now.addingTimeInterval(5 * 60)
        let replacementDate = now.addingTimeInterval(2 * 3_600)
        #expect(console.setReminder(for: task.id, title: task.title, at: firstDate, now: now))
        #expect(console.setReminder(for: task.id, title: task.title, at: replacementDate, now: now))

        #expect(console.reminder(for: task.id)?.dueAt == replacementDate)
        #expect(reminders.load().count == 1)
        #expect(reminders.load()[task.id]?.dueAt == replacementDate)
        #expect(!console.setReminder(for: task.id, title: task.title, at: now, now: now))

        let relaunched = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        #expect(relaunched.reminder(for: task.id)?.dueAt == replacementDate)
    }

    @Test
    func dueReminderStaysStoredUntilDismissedAndIsPinnedAndPresented() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let dueAt = now.addingTimeInterval(60)
        let task = codexTask("task", title: "Deploy release", status: .inactive)
        let reminders = TestTaskReminderStorage()
        let visibility = TestVisibilityStorage(
            ledger: VisibilityLedger(
                isBootstrapped: true,
                knownTaskIDs: [task.id],
                hiddenTaskIDs: [task.id]
            )
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()
        #expect(console.setReminder(for: task.id, title: "Original title", at: dueAt, now: now))

        console.processDueReminders(at: now.addingTimeInterval(30), groupingAsMissed: false)
        #expect(console.reminder(for: task.id)?.dueAt == dueAt)
        #expect(!console.isMonitored(task.id))

        console.processDueReminders(at: dueAt, groupingAsMissed: false)

        #expect(console.reminder(for: task.id)?.dueAt == dueAt)
        #expect(reminders.load()[task.id]?.dueAt == dueAt)
        #expect(console.isMonitored(task.id))
        #expect(console.currentTriggeredReminder == TaskReminder(taskID: task.id, title: task.title, dueAt: dueAt))
        #expect(console.missedReminders.isEmpty)
        #expect(console.reminderSoundSequence == 1)

        console.processDueReminders(at: dueAt.addingTimeInterval(30), groupingAsMissed: false)
        #expect(console.triggeredReminders.count == 1)
        #expect(console.reminderSoundSequence == 1)

        let relaunched = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: visibility,
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await relaunched.refresh()
        relaunched.processDueReminders(at: dueAt.addingTimeInterval(30), groupingAsMissed: true)
        let recoveredReminder = try #require(relaunched.missedReminders.first)
        #expect(recoveredReminder.title == task.title)

        relaunched.dismissReminder(recoveredReminder)
        #expect(relaunched.missedReminders.isEmpty)
        #expect(relaunched.reminder(for: task.id) == nil)
        #expect(reminders.load().isEmpty)
    }

    @Test
    func missedRemindersAreGroupedInDueOrderAndPinned() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = codexTask("first", title: "First", status: .inactive)
        let second = codexTask("second", title: "Second", status: .inactive)
        let reminders = TestTaskReminderStorage(reminders: [
            second.id: TaskReminder(taskID: second.id, title: second.title, dueAt: now.addingTimeInterval(-60)),
            first.id: TaskReminder(taskID: first.id, title: first.title, dueAt: now.addingTimeInterval(-120)),
        ])
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [first, second]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        console.processDueReminders(at: now, groupingAsMissed: true)

        #expect(console.missedReminders.map(\.taskID) == [first.id, second.id])
        #expect(console.triggeredReminders.isEmpty)
        #expect(console.isMonitored(first.id))
        #expect(console.isMonitored(second.id))
        #expect(reminders.load().count == 2)
        #expect(console.reminderSoundSequence == 1)

        console.processDueReminders(at: now, groupingAsMissed: true)
        #expect(console.missedReminders.map(\.taskID) == [first.id, second.id])
        #expect(console.reminderSoundSequence == 1)

        let relaunched = AttentionConsole(
            loader: StaticTaskLoader(tasks: [first, second]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await relaunched.refresh()
        relaunched.processDueReminders(at: now, groupingAsMissed: true)
        #expect(relaunched.missedReminders.map(\.taskID) == [first.id, second.id])

        relaunched.dismissAllMissedReminders()
        #expect(relaunched.missedReminders.isEmpty)
        #expect(reminders.load().isEmpty)
    }

    @Test
    func snoozingClearsTheNotificationAndPersistsTheNewExactTime() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let dueAt = now.addingTimeInterval(60)
        let snoozedUntil = now.addingTimeInterval(3 * 86_400)
        let task = codexTask("task", title: "Deploy release", status: .inactive)
        let reminders = TestTaskReminderStorage()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            reminderStorage: reminders,
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()
        #expect(console.setReminder(for: task.id, title: task.title, at: dueAt, now: now))
        console.processDueReminders(at: dueAt, groupingAsMissed: false)
        let triggered = try #require(console.currentTriggeredReminder)

        #expect(console.snooze(triggered, until: snoozedUntil, now: now))
        #expect(console.currentTriggeredReminder == nil)
        #expect(console.reminder(for: task.id)?.dueAt == snoozedUntil)
        #expect(reminders.load()[task.id]?.dueAt == snoozedUntil)
    }

    @Test
    func displayPreferencesPreserveActiveTaskActivity() async {
        let activity = TaskActivityPreview(headline: "Running the test suite.")
        let task = codexTask(
            "task",
            title: "Generated title",
            status: .working,
            activity: activity
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

        console.setTitle("Local title", for: task.id)
        console.setPriority(.orange, for: task.id)

        #expect(console.allTasks.first?.activity == activity)
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
            priorityStorage: TestTaskPriorityStorage(),
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
    activity: TaskActivityPreview? = nil,
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
        activity: activity,
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
private final class TestTaskPriorityStorage: TaskPriorityStoring {
    private var priorities: [String: TaskPriority]

    init(priorities: [String: TaskPriority] = [:]) {
        self.priorities = priorities
    }

    func load() -> [String: TaskPriority] { priorities }
    func save(_ priorities: [String: TaskPriority]) { self.priorities = priorities }
}

@MainActor
private final class TestTaskNoteStorage: TaskNoteStoring {
    private var notes: [String: String]

    init(notes: [String: String] = [:]) {
        self.notes = notes
    }

    func load() -> [String: String] { notes }
    func save(_ notes: [String: String]) { self.notes = notes }
}

@MainActor
private final class TestTaskReminderStorage: TaskReminderStoring {
    private var reminders: [String: TaskReminder]

    init(reminders: [String: TaskReminder] = [:]) {
        self.reminders = reminders
    }

    func load() -> [String: TaskReminder] { reminders }
    func save(_ reminders: [String: TaskReminder]) { self.reminders = reminders }
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
