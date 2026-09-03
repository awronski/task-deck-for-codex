import CodexCompanionCore
import Foundation
import Observation
import Synchronization
import Testing

@Suite
@MainActor
struct AttentionConsoleTests {
    @Test
    func exposesWhetherAnAvailableTaskIsActuallyOnTheConsole() async {
        let historical = "historical"
        let task = codexTask(historical, title: "Historical", status: .inactive)
        let storage = TestVisibilityStorage(
            ledger: VisibilityLedger(
                isBootstrapped: true,
                knownTaskIDs: [historical],
                monitoredTaskIDs: [],
                hiddenTaskIDs: []
            )
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: storage,
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()

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
    func titleRenameCanAlsoUpdateCodex() async {
        let task = codexTask(
            "task",
            title: "Generated title",
            status: .inactive
        )
        let renamer = TestTaskRenamer()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            renamer: renamer
        )
        await console.refresh()

        let didRename = await console.setTitle("  Shared title  ", for: task.id, syncsToCodex: true)
        let renames = await renamer.renames

        #expect(didRename)
        #expect(console.allTasks.first?.title == "Shared title")
        #expect(renames == [.init(taskID: task.id, title: "Shared title")])
    }

    @Test
    func failedCodexRenameKeepsTheLocalTitleAndShowsTheError() async {
        let task = codexTask(
            "task",
            title: "Generated title",
            status: .inactive
        )
        let renamer = TestTaskRenamer(error: TestRenameError())
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            renamer: renamer
        )
        await console.refresh()

        let didRename = await console.setTitle("Local fallback", for: task.id, syncsToCodex: true)

        #expect(!didRename)
        #expect(console.allTasks.first?.title == "Local fallback")
        #expect(console.errorMessage == "Codex rename failed")
    }

    @Test
    func taskFlagsPersistAndNoFlagRemovesTheOverride() async {
        let task = codexTask(
            "task",
            title: "Production-ready task",
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

        console.setPriority(.blue, for: task.id)
        #expect(console.allTasks.first?.priority == .blue)
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

        #expect(relaunched.allTasks.first?.priority == .blue)

        relaunched.setPriority(.none, for: task.id)
        #expect(relaunched.allTasks.first?.priority == TaskPriority.none)
        #expect(priorities.load().isEmpty)
    }

    @Test
    func projectAppearanceAndDisplayNamePersistAndCanReturnToTheSuggestedDefault() {
        let appearances = TestProjectAppearanceStorage()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: []),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            projectAppearanceStorage: appearances
        )
        let appearance = ProjectAppearance(
            iconName: "terminal",
            colorID: ProjectAppearance.noBackgroundColorID,
            displayName: "Command Line Tools"
        )

        let appearanceChangeWasObserved = Mutex(false)
        withObservationTracking {
            _ = console.projectAppearance(for: "/code/cli")
        } onChange: {
            appearanceChangeWasObserved.withLock { $0 = true }
        }

        console.setProjectAppearance(appearance, for: "/code/cli")
        #expect(console.projectAppearance(for: "/code/cli") == appearance)
        #expect(appearanceChangeWasObserved.withLock { $0 })
        #expect(appearances.load() == ["/code/cli": appearance])

        let relaunched = AttentionConsole(
            loader: StaticTaskLoader(tasks: []),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage(),
            projectAppearanceStorage: appearances
        )
        #expect(relaunched.projectAppearance(for: "/code/cli") == appearance)

        relaunched.setProjectAppearance(nil, for: "/code/cli")
        #expect(relaunched.projectAppearance(for: "/code/cli") == nil)
        #expect(appearances.load().isEmpty)
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
            activity: activity,
            modelName: "gpt-5.6-sol",
            thinkingEffort: "high"
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
        #expect(console.allTasks.first?.modelName == "gpt-5.6-sol")
        #expect(console.allTasks.first?.thinkingEffort == "high")
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
        console.enable(task.id)

        #expect(await console.setArchived(true, for: task.id) == .completed)
        #expect(console.allTasks.isEmpty)
        #expect(!console.isMonitored(task.id))
        #expect(await archiver.isArchived(task.id))

        #expect(await console.setArchived(false, for: task.id) == .completed)
        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(console.isMonitored(task.id))
        #expect(await !archiver.isArchived(task.id))
    }

    @Test
    func archiveAndUndoPreserveAnUnmonitoredTask() async {
        let task = codexTask(
            "task",
            title: "Unmonitored task",
            status: .inactive
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
        #expect(!console.isMonitored(task.id))

        #expect(await console.setArchived(true, for: task.id) == .completed)
        #expect(console.allTasks.isEmpty)

        #expect(await console.setArchived(false, for: task.id) == .completed)
        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(!console.isMonitored(task.id))
    }

    @Test
    func deferredArchiveRemovesTheTaskFromTheConsoleAndCanBeCancelled() async {
        let task = codexTask(
            "task",
            title: "Task owned by Codex",
            status: .inactive
        )
        let archiver = DeferredTestTaskArchiver()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: archiver,
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()
        console.enable(task.id)

        #expect(await console.setArchived(true, for: task.id) == .deferred)
        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(console.monitoredTasks.isEmpty)
        #expect(!console.isMonitored(task.id))
        #expect(console.pendingArchiveTaskIDs == [task.id])
        #expect(console.errorMessage == nil)

        #expect(await console.setArchived(false, for: task.id) == .completed)
        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(console.monitoredTasks.map(\.id) == [task.id])
        #expect(console.isMonitored(task.id))
        #expect(console.pendingArchiveTaskIDs.isEmpty)
        #expect(console.errorMessage == nil)
    }

    @Test
    func failedArchiveKeepsTheTaskVisibleWithoutCreatingPendingState() async {
        let task = codexTask(
            "task",
            title: "Task with an archive failure",
            status: .inactive
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: FailingTestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()
        console.enable(task.id)

        #expect(await console.setArchived(true, for: task.id) == nil)
        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(console.monitoredTasks.map(\.id) == [task.id])
        #expect(console.isMonitored(task.id))
        #expect(console.pendingArchiveTaskIDs.isEmpty)
        #expect(console.errorMessage == "Codex archive failed")
    }

    @Test
    func cancellingADeferredArchivePreservesAnUnmonitoredTask() async {
        let task = codexTask(
            "task",
            title: "Unmonitored queued task",
            status: .inactive
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: DeferredTestTaskArchiver(),
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()
        #expect(!console.isMonitored(task.id))

        #expect(await console.setArchived(true, for: task.id) == .deferred)
        #expect(!console.isMonitored(task.id))

        #expect(await console.setArchived(false, for: task.id) == .completed)
        #expect(!console.isMonitored(task.id))
        #expect(console.pendingArchiveTaskIDs.isEmpty)
    }

    @Test
    func refreshRestoresPersistedPendingArchiveState() async {
        let task = codexTask(
            "task",
            title: "Queued before relaunch",
            status: .inactive
        )
        let visibility = TestVisibilityStorage(
            ledger: VisibilityLedger(
                isBootstrapped: true,
                knownTaskIDs: [task.id],
                monitoredTaskIDs: [task.id]
            )
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: DeferredTestTaskArchiver(pendingTaskIDs: [task.id]),
            storage: visibility,
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()

        #expect(console.allTasks.map(\.id) == [task.id])
        #expect(console.monitoredTasks.isEmpty)
        #expect(!console.isMonitored(task.id))
        #expect(console.pendingArchiveTaskIDs == [task.id])
    }

    @Test
    func pendingArchiveIsCancelledAndTaskRestoredWhenItStartsWorkingAgain() async {
        let inactiveTask = codexTask(
            "task",
            title: "Queued task",
            status: .inactive
        )
        let workingTask = codexTask(
            inactiveTask.id,
            title: inactiveTask.title,
            status: .working
        )
        let archiver = DeferredTestTaskArchiver(pendingTaskIDs: [inactiveTask.id])
        let console = AttentionConsole(
            loader: SequenceTaskLoader(taskSets: [[inactiveTask], [workingTask]]),
            archiver: archiver,
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()
        #expect(console.monitoredTasks.isEmpty)
        #expect(console.pendingArchiveTaskIDs == [inactiveTask.id])

        await console.refresh()

        #expect(console.monitoredTasks.map(\.id) == [workingTask.id])
        #expect(console.isMonitored(workingTask.id))
        #expect(console.pendingArchiveTaskIDs.isEmpty)
        #expect(await archiver.pendingArchiveTaskIDs().isEmpty)
    }

    @Test
    func pendingArchiveRemainsQueuedWhenTheTaskWasAlreadyActive() async {
        let task = codexTask(
            "task",
            title: "Already active task",
            status: .working
        )
        let archiver = DeferredTestTaskArchiver()
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: archiver,
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )
        await console.refresh()
        #expect(console.isMonitored(task.id))

        #expect(await console.setArchived(true, for: task.id) == .deferred)
        #expect(await archiver.pendingArchiveTaskIDs() == [task.id])
        await console.refresh()

        #expect(console.pendingArchiveTaskIDs == [task.id])
        #expect(await archiver.pendingArchiveTaskIDs() == [task.id])
        #expect(console.monitoredTasks.isEmpty)
    }

    @Test
    func successfulRetryImmediatelyClearsPendingStateAndReloadsTasks() async {
        let task = codexTask(
            "task",
            title: "Task archived by retry",
            status: .inactive
        )
        let archiver = RetryCompletingTaskArchiver(pendingTaskIDs: [task.id])
        let console = AttentionConsole(
            loader: SequenceTaskLoader(taskSets: [[task], []]),
            archiver: archiver,
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()

        #expect(console.pendingArchiveTaskIDs.isEmpty)
        #expect(console.allTasks.isEmpty)
        #expect(await archiver.pendingArchiveTaskIDs().isEmpty)
    }

    @Test
    func pendingArchiveIsCancelledWhenAnExcludedTaskKindStartsWorking() async {
        let task = codexTask(
            "agent",
            title: "Queued agent",
            kind: .agent,
            status: .working
        )
        let archiver = DeferredTestTaskArchiver(pendingTaskIDs: [task.id])
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [task]),
            archiver: archiver,
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()

        #expect(console.allTasks.isEmpty)
        #expect(console.pendingArchiveTaskIDs.isEmpty)
        #expect(await archiver.pendingArchiveTaskIDs().isEmpty)
    }

    @Test
    func failedRefreshDoesNotRetryPendingArchives() async {
        let archiver = RetryRecordingTaskArchiver()
        let console = AttentionConsole(
            loader: FailingTaskLoader(),
            archiver: archiver,
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()

        #expect(await archiver.retryAttempts == 0)
        #expect(console.errorMessage == "Could not reload tasks")
    }

    @Test
    func retryFailureIsShownAfterASuccessfulRefresh() async {
        let archiver = RetryRecordingTaskArchiver(error: TestArchiveRetryError())
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: []),
            archiver: archiver,
            storage: TestVisibilityStorage(),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()

        #expect(await archiver.retryAttempts == 1)
        #expect(console.errorMessage == "Could not retry queued archive")
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

        #expect(await console.setArchived(false, for: "task") == .completed)
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
    func hiddenAgentTasksDoNotAffectAutomaticProjectOrder() async {
        let now = Date()
        let alphaRegular = codexTask(
            "alpha-regular",
            title: "Alpha regular",
            projectKey: "alpha",
            projectName: "Alpha",
            projectPath: "/code/alpha",
            status: .inactive,
            updatedAt: now.addingTimeInterval(-30),
            createdAt: now.addingTimeInterval(-30)
        )
        let bravoRegular = codexTask(
            "bravo-regular",
            title: "Bravo regular",
            projectKey: "bravo",
            projectName: "Bravo",
            projectPath: "/code/bravo",
            status: .inactive,
            updatedAt: now.addingTimeInterval(-20),
            createdAt: now.addingTimeInterval(-20)
        )
        let alphaAgent = codexTask(
            "alpha-agent",
            title: "Alpha agent",
            projectKey: "alpha",
            projectName: "Alpha",
            projectPath: "/code/alpha",
            kind: .agent,
            status: .inactive,
            updatedAt: now,
            createdAt: now
        )
        let console = AttentionConsole(
            loader: StaticTaskLoader(tasks: [alphaRegular, bravoRegular, alphaAgent]),
            archiver: TestTaskArchiver(),
            storage: TestVisibilityStorage(ledger: VisibilityLedger(isBootstrapped: true)),
            titleStorage: TestTaskTitleStorage(),
            priorityStorage: TestTaskPriorityStorage(),
            projectOrderStorage: TestProjectOrderStorage()
        )

        await console.refresh()
        let sectionsBefore = TaskGrouping.sections(from: console.allTasks)
        #expect(ProjectOrdering.sortingAutomatically(
            sectionsBefore,
            using: console.allTasks
        ).map(\.id) == ["bravo", "alpha"])

        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible.union([.agent]))
        await console.refresh()

        let sectionsAfter = TaskGrouping.sections(from: console.allTasks)
        #expect(ProjectOrdering.sortingAutomatically(
            sectionsAfter,
            using: console.allTasks
        ).map(\.id) == ["alpha", "bravo"])
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
        snapshot(
            for: tasks.filter { kinds.contains($0.kind) },
            allTasks: tasks
        )
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
        let tasks = taskSets.count > 1 ? taskSets.removeFirst() : taskSets.first ?? []
        return snapshot(
            for: tasks.filter { kinds.contains($0.kind) },
            allTasks: tasks
        )
    }
}

private actor TestTaskArchiver: CodexTaskArchiving {
    private var archivedTaskIDs: Set<String> = []

    func setArchived(
        _ archived: Bool,
        taskID: String
    ) async throws -> CodexTaskArchiveResult {
        if archived {
            archivedTaskIDs.insert(taskID)
        } else {
            archivedTaskIDs.remove(taskID)
        }
        return .completed
    }

    func isArchived(_ taskID: String) -> Bool {
        archivedTaskIDs.contains(taskID)
    }
}

private actor DeferredTestTaskArchiver: CodexTaskArchiving {
    private var pendingTaskIDs: Set<String>

    init(pendingTaskIDs: Set<String> = []) {
        self.pendingTaskIDs = pendingTaskIDs
    }

    func setArchived(
        _ archived: Bool,
        taskID: String
    ) -> CodexTaskArchiveResult {
        if archived {
            pendingTaskIDs.insert(taskID)
            return .deferred
        }
        pendingTaskIDs.remove(taskID)
        return .completed
    }

    func pendingArchiveTaskIDs() async -> Set<String> {
        pendingTaskIDs
    }
}

private actor FailingTestTaskArchiver: CodexTaskArchiving {
    func setArchived(
        _ archived: Bool,
        taskID: String
    ) throws -> CodexTaskArchiveResult {
        throw TestArchiveError()
    }
}

private struct TestArchiveError: LocalizedError {
    var errorDescription: String? { "Codex archive failed" }
}

private actor RetryRecordingTaskArchiver: CodexTaskArchiving {
    private(set) var retryAttempts = 0
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func setArchived(
        _ archived: Bool,
        taskID: String
    ) -> CodexTaskArchiveResult {
        .completed
    }

    func retryPendingArchives() throws {
        retryAttempts += 1
        if let error { throw error }
    }
}

private actor RetryCompletingTaskArchiver: CodexTaskArchiving {
    private var pendingTaskIDs: Set<String>

    init(pendingTaskIDs: Set<String>) {
        self.pendingTaskIDs = pendingTaskIDs
    }

    func setArchived(
        _ archived: Bool,
        taskID: String
    ) -> CodexTaskArchiveResult {
        if archived {
            pendingTaskIDs.insert(taskID)
            return .deferred
        }
        pendingTaskIDs.remove(taskID)
        return .completed
    }

    func retryPendingArchives() {
        pendingTaskIDs.removeAll()
    }

    func pendingArchiveTaskIDs() async -> Set<String> {
        pendingTaskIDs
    }
}

private struct TestArchiveRetryError: LocalizedError {
    var errorDescription: String? { "Could not retry queued archive" }
}

private actor TestTaskRenamer: CodexTaskRenaming {
    struct Rename: Equatable {
        let taskID: String
        let title: String
    }

    private(set) var renames: [Rename] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func setTitle(_ title: String, taskID: String) async throws {
        if let error { throw error }
        renames.append(Rename(taskID: taskID, title: title))
    }
}

private struct TestRenameError: LocalizedError {
    var errorDescription: String? { "Codex rename failed" }
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
    modelName: String? = nil,
    thinkingEffort: String? = nil,
    updatedAt: Date = .now,
    workingSince: Date? = nil,
    finishedAt: Date? = nil,
    createdAt: Date = .distantPast
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
        modelName: modelName,
        thinkingEffort: thinkingEffort,
        activity: activity,
        updatedAt: updatedAt,
        workingSince: workingSince,
        finishedAt: finishedAt,
        createdAt: createdAt
    )
}

private func snapshot(
    for tasks: [CodexTask],
    allTasks: [CodexTask]? = nil
) -> CodexTaskSnapshot {
    let completeTasks = allTasks ?? tasks
    var seen: Set<String> = []
    let projects = completeTasks.compactMap { task -> ProjectIdentity? in
        guard seen.insert(task.projectKey).inserted else { return nil }
        return ProjectIdentity(
            key: task.projectKey,
            name: task.projectName,
            path: task.projectPath,
            isChat: task.isChat
        )
    }
    return CodexTaskSnapshot(
        tasks: tasks,
        projects: projects
    )
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

@MainActor
private final class TestProjectAppearanceStorage: ProjectAppearanceStoring {
    private var appearances: [String: ProjectAppearance]

    init(appearances: [String: ProjectAppearance] = [:]) {
        self.appearances = appearances
    }

    func load() -> [String: ProjectAppearance] { appearances }
    func save(_ appearances: [String: ProjectAppearance]) { self.appearances = appearances }
}
