import CodexCompanionCore
import Foundation
import Testing

@Suite
@MainActor
struct FocusModeTests {
    @Test
    func manualModePinsNewAndResumedTasksWithoutEnteringFocus() async {
        let backend = FocusBackend(tasks: [focusTask("chosen"), focusTask("dormant", status: .inactive)])
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["chosen"])

        await backend.replaceTasks([
            focusTask("chosen"), focusTask("dormant"), focusTask("new", status: .inactive)
        ])
        await console.refresh()

        #expect(Set(console.monitoredTasks.map(\.id)) == ["chosen", "dormant", "new"])
        #expect(console.focusedTaskIDs == ["chosen"])
        #expect(console.focusedTasks.map(\.id) == ["chosen"])
    }

    @Test
    func automaticFocusAppendsNewAndResumedTasksWithoutChangingExistingOrder() async {
        let backend = FocusBackend(tasks: [focusTask("chosen"), focusTask("resumed", status: .inactive)])
        let console = makeConsole(backend: backend, automaticallyFocusStartedTasks: true)
        await console.refresh()
        #expect(console.focusedTaskIDs.isEmpty)
        console.setFocusedTasks(["chosen"])

        await backend.replaceTasks([
            focusTask("chosen"), focusTask("resumed"), focusTask("new"),
            focusTask("quick", status: .finished), focusTask("automation", kind: .automation)
        ])
        await console.refresh()
        #expect(console.focusedTaskIDs == ["chosen", "automation", "new", "quick", "resumed"])

        await console.refresh()
        #expect(console.focusedTaskIDs == ["chosen", "automation", "new", "quick", "resumed"])
        console.setFocusedTasks(["chosen"])
        await console.refresh()
        #expect(console.focusedTaskIDs == ["chosen"])
    }

    @Test
    func automaticFocusSettingChangesApplyToFutureStartsWithoutBackfilling() async {
        let backend = FocusBackend(tasks: [focusTask("existing")])
        let console = makeConsole(backend: backend)
        await console.refresh()
        await backend.replaceTasks([focusTask("existing"), focusTask("while-off")])
        await console.refresh()
        #expect(console.focusedTaskIDs.isEmpty)

        console.automaticallyFocusStartedTasks = true
        await console.refresh()
        #expect(console.focusedTaskIDs.isEmpty)
        await backend.replaceTasks([focusTask("existing"), focusTask("while-off"), focusTask("while-on")])
        await console.refresh()
        #expect(console.focusedTaskIDs == ["while-on"])

        console.automaticallyFocusStartedTasks = false
        await backend.replaceTasks([
            focusTask("existing"), focusTask("while-off"), focusTask("while-on"), focusTask("off-again")
        ])
        await console.refresh()
        #expect(console.focusedTaskIDs == ["while-on"])
    }

    @Test
    func automaticFocusDoesNotImportBacklogAfterRelaunch() async {
        let backend = FocusBackend(tasks: [focusTask("chosen"), focusTask("backlog")])
        let visibility = FocusVisibilityStorage()
        let console = makeConsole(backend: backend, visibility: visibility)
        await console.refresh()
        console.setFocusedTasks(["chosen"])

        await backend.replaceTasks([focusTask("chosen"), focusTask("backlog"), focusTask("while-closed")])
        let relaunched = makeConsole(
            backend: backend, visibility: visibility, automaticallyFocusStartedTasks: true
        )
        await relaunched.refresh()
        #expect(relaunched.focusedTaskIDs == ["chosen"])
        #expect(relaunched.isMonitored("while-closed"))

        await backend.replaceTasks([
            focusTask("chosen"), focusTask("backlog"), focusTask("while-closed"), focusTask("after-launch")
        ])
        await relaunched.refresh()
        #expect(relaunched.focusedTaskIDs == ["chosen", "after-launch"])
    }

    @Test
    func automaticFocusObservesFilteredStartsButDoesNotAddUnpinnedAgents() async throws {
        let backend = FocusBackend(tasks: [focusTask("chosen"), focusTask("agent", status: .inactive, kind: .agent)])
        let console = makeConsole(backend: backend, automaticallyFocusStartedTasks: true)
        await console.refresh()
        console.setFocusedTasks(["chosen"])
        console.setIncludedTaskKinds([.agent])
        try await waitUntil { console.allTasks.first?.id == "agent" }

        await backend.replaceTasks([
            focusTask("chosen"), focusTask("regular"), focusTask("agent", kind: .agent)
        ])
        await console.refresh()
        try await waitUntil { console.isMonitored("regular") }
        #expect(console.focusedTaskIDs == ["chosen", "regular"])
        #expect(!console.isMonitored("agent"))

        console.enable("agent")
        await console.refresh()
        #expect(console.focusedTaskIDs == ["chosen", "regular"])
        await backend.replaceTasks([
            focusTask("chosen"), focusTask("regular"), focusTask("agent", status: .inactive, kind: .agent)
        ])
        await console.refresh()
        try await waitUntil { console.allTasks.first?.status == .inactive }
        await backend.replaceTasks([focusTask("chosen"), focusTask("regular"), focusTask("agent", kind: .agent)])
        await console.refresh()
        try await waitUntil { console.allTasks.first?.status == .working }
        #expect(console.focusedTaskIDs == ["chosen", "regular", "agent"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test
    func completionSourceReorderingAndFlagsDoNotChangeFocusOrder() async {
        let backend = FocusBackend(tasks: [focusTask("first"), focusTask("second"), focusTask("outside")])
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["second", "first"])
        console.setPriority(.red, for: "first")
        console.setPriority(.green, for: "outside")

        await backend.replaceTasks([
            focusTask("outside", status: .error),
            focusTask("first", status: .finished, finishedAt: Date(timeIntervalSince1970: 1_001)),
            focusTask("second", status: .finished, finishedAt: Date(timeIntervalSince1970: 1_002))
        ])
        await console.refresh()
        #expect(console.focusedTasks.map(\.id) == ["second", "first"])
        #expect(console.focusedTasks.map(\.status) == [.finished, .finished])

        console.markInactiveAfterOpening("second")
        #expect(console.focusedTasks.map(\.id) == ["second", "first"])
        #expect(console.focusedTasks.first?.status == .inactive)
        console.setFocusedTasks(["first", "second"])
        #expect(console.focusedTasks.map(\.id) == ["first", "second"])
        #expect(console.focusCandidates.first(where: { $0.id == "first" })?.priority == .red)
        #expect(console.focusCandidates.first(where: { $0.id == "outside" })?.priority == .green)
    }

    @Test
    func excludedKindsAndRelaunchKeepPinnedAgentsAvailable() async throws {
        let backend = FocusBackend(tasks: [
            focusTask("regular"),
            focusTask("focused-agent", status: .inactive, kind: .agent),
            focusTask("candidate-agent", status: .inactive, kind: .agent)
        ])
        let visibility = FocusVisibilityStorage()
        let console = makeConsole(backend: backend, visibility: visibility)
        await console.refresh()
        console.setIncludedTaskKinds(Set(CodexTaskKind.allCases))
        await console.refresh()
        console.enable("focused-agent")
        console.enable("candidate-agent")
        console.setFocusedTasks(["focused-agent", "regular"])

        console.setIncludedTaskKinds([.automation])
        await console.refresh()
        #expect(console.allTasks.isEmpty)
        #expect(console.focusedTasks.map(\.id) == ["focused-agent", "regular"])
        #expect(Set(console.focusCandidates.map(\.id)) == ["regular", "focused-agent", "candidate-agent"])
        #expect(await backend.lastAlwaysIncludedIDs == ["regular", "focused-agent", "candidate-agent"])

        let data = try JSONEncoder().encode(visibility.load())
        let restoredStorage = FocusVisibilityStorage(ledger: try JSONDecoder().decode(VisibilityLedger.self, from: data))
        let relaunched = makeConsole(backend: backend, visibility: restoredStorage)
        await relaunched.refresh()
        #expect(!relaunched.includedTaskKinds.contains(.agent))
        #expect(relaunched.focusedTasks.map(\.id) == ["focused-agent", "regular"])
        #expect(Set(relaunched.focusCandidates.map(\.id)) == ["regular", "focused-agent", "candidate-agent"])
    }

    @Test
    func hideRemovesFocusAndEnableDoesNotRestoreIt() async {
        let backend = FocusBackend(tasks: [focusTask("first"), focusTask("second")])
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["first", "second"])

        console.hide("first")
        #expect(console.focusedTaskIDs == ["second"])
        #expect(console.focusCandidates.map(\.id) == ["second"])
        console.enable("first")
        #expect(Set(console.focusCandidates.map(\.id)) == ["first", "second"])
        #expect(console.focusedTaskIDs == ["second"])
    }

    @Test(arguments: FocusArchiveOutcome.allCases)
    func localArchiveRemovesFocusOnlyWhenAccepted(outcome: FocusArchiveOutcome) async {
        let backend = FocusBackend(tasks: [focusTask("archived"), focusTask("retained")], archiveOutcome: outcome)
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["archived", "retained"])

        let result = await console.setArchived(true, for: "archived")

        switch outcome {
        case .failed:
            #expect(result == nil)
            #expect(console.focusedTaskIDs == ["archived", "retained"])
            #expect(console.errorMessage == "Focus fixture archive failed")
        case .completed, .deferred:
            #expect(result == (outcome == .completed ? .completed : .deferred))
            #expect(console.focusedTaskIDs == ["retained"])
            #expect(console.focusCandidates.map(\.id) == ["retained"])
            console.setFocusedTasks(["retained", "archived"])
            #expect(console.focusedTaskIDs == ["retained"])
        }
    }

    @Test
    func confirmedExternalArchiveDeletionAndArchivedDescendantRemoveFocus() async {
        let backend = FocusBackend(tasks: [
            focusTask("retained"), focusTask("archived"), focusTask("deleted"), focusTask("descendant")
        ])
        let visibility = FocusVisibilityStorage()
        let console = makeConsole(backend: backend, visibility: visibility)
        await console.refresh()
        console.setFocusedTasks(["archived", "retained", "deleted", "descendant"])

        await backend.archiveExternally(["archived", "descendant"])
        await backend.deleteTasks(["deleted"])
        await console.refresh()

        #expect(await backend.checkedTaskIDs == ["archived", "deleted", "descendant"])
        #expect(console.focusedTaskIDs == ["retained"])
        #expect(console.focusedTasks.map(\.id) == ["retained"])
        #expect(visibility.load().focusedTaskIDs == ["retained"])
    }

    @Test(arguments: [false, true])
    func temporaryAbsenceOrStateReadFailurePreservesFocusAndRecoveryRestoresDisplay(readerFails: Bool) async {
        let backend = FocusBackend(tasks: [focusTask("missing"), focusTask("visible")])
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["missing", "visible"])

        await backend.omitTasks(["missing"], readerFails: readerFails)
        await console.refresh()
        #expect(console.focusedTaskIDs == ["missing", "visible"])
        #expect(console.focusedTasks.map(\.id) == ["visible"])
        #expect(console.errorMessage == (readerFails ? "Focus fixture state read failed" : nil))
        console.setFocusedTasks(["visible", "missing"])
        #expect(console.focusedTaskIDs == ["visible", "missing"])

        await backend.omitTasks([], readerFails: false)
        await console.refresh()
        #expect(console.focusedTasks.map(\.id) == ["visible", "missing"])
        #expect(console.errorMessage == nil)
    }

    @Test
    func dueReminderOutsideFocusStillFiresAndPinsItsTask() async {
        let backend = FocusBackend(tasks: [focusTask("chosen"), focusTask("reminder", status: .inactive)])
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["chosen"])
        let now = Date(timeIntervalSince1970: 2_000)
        let dueAt = now.addingTimeInterval(60)
        #expect(console.setReminder(for: "reminder", title: "Follow up", at: dueAt, now: now))

        console.processDueReminders(at: dueAt, groupingAsMissed: false)

        #expect(console.currentTriggeredReminder?.taskID == "reminder")
        #expect(console.reminderSoundSequence == 1)
        #expect(console.isMonitored("reminder"))
        #expect(console.focusedTaskIDs == ["chosen"])
    }

    @Test
    func outsideAttentionContainsOnlyPinnedNonpendingNonfocusedAttentionStates() async {
        let tasks = [
            focusTask("input", status: .waitingForInput),
            focusTask("permission", status: .waitingForPermission),
            focusTask("error", status: .error),
            focusTask("working"),
            focusTask("finished", status: .finished),
            focusTask("inactive", status: .inactive),
            focusTask("hidden", status: .waitingForInput),
            focusTask("focused", status: .error),
            focusTask("pending", status: .error)
        ]
        let backend = FocusBackend(tasks: tasks, archiveOutcome: .deferred)
        let console = makeConsole(backend: backend)
        await console.refresh()
        for task in tasks { console.enable(task.id) }
        console.hide("hidden")
        console.setFocusedTasks(["focused"])
        #expect(await console.setArchived(true, for: "pending") == .deferred)

        #expect(console.outsideFocusAttentionTasks.map(\.id) == ["input", "permission", "error"])
        #expect(console.focusedTaskIDs == ["focused"])
    }

    @Test
    func newSelectionRejectsStaleAndUnpinnedIDsAndDeduplicates() async {
        let backend = FocusBackend(tasks: [
            focusTask("focused"), focusTask("candidate"), focusTask("stale"), focusTask("unpinned", status: .inactive)
        ])
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["focused"])
        await backend.omitTasks(["stale"], readerFails: false)
        await console.refresh()

        console.setFocusedTasks(["candidate", "stale", "unpinned", "candidate", "focused"])

        #expect(console.focusedTaskIDs == ["candidate", "focused"])
        #expect(!console.isMonitored("unpinned"))
    }

    @Test(arguments: [true, false])
    func automaticFocusUndoPreservesPreviousSelectionAndOrder(previouslyFocused: Bool) async throws {
        let backend = FocusBackend(tasks: [focusTask("restored", status: .error), focusTask("keep")])
        let console = makeConsole(backend: backend, automaticallyFocusStartedTasks: true)
        await console.refresh()
        let previousFocus = previouslyFocused ? ["restored", "keep"] : ["keep"]
        console.setFocusedTasks(previousFocus)

        #expect(await console.setArchived(true, for: "restored") == .completed)
        await console.refresh()
        #expect(console.focusedTaskIDs == ["keep"])
        await backend.replaceTasks([
            focusTask("restored", status: .error), focusTask("keep"), focusTask("new")
        ])

        #expect(await console.undoArchive(for: "restored", restoringFocusFrom: previousFocus))
        #expect(console.focusedTaskIDs == previousFocus + ["new"])
        await console.refresh()
        #expect(console.focusedTaskIDs == previousFocus + ["new"])

        // Undo must not suppress a later, genuine start of the restored task.
        console.setFocusedTasks(["keep", "new"])
        await backend.replaceTasks([
            focusTask("restored", status: .inactive), focusTask("keep"), focusTask("new")
        ])
        await console.refresh()
        try await waitUntil { console.allTasks.first(where: { $0.id == "restored" })?.status == .inactive }
        await backend.replaceTasks([focusTask("restored"), focusTask("keep"), focusTask("new")])
        await console.refresh()
        try await waitUntil { console.focusedTaskIDs == ["keep", "new", "restored"] }
    }

    @Test(arguments: [true, false])
    func automaticFocusUndoSurvivesAnInFlightRefreshAndDelayedVisibility(previouslyFocused: Bool) async throws {
        let backend = FocusBackend(tasks: [focusTask("restored", status: .error), focusTask("missing")])
        let console = makeConsole(backend: backend, automaticallyFocusStartedTasks: true)
        await console.refresh()
        let previousFocus = previouslyFocused ? ["restored", "missing"] : ["missing"]
        console.setFocusedTasks(previousFocus)
        #expect(await console.setArchived(true, for: "restored") == .completed)
        await console.refresh()

        await backend.omitTasks(["restored", "missing"], readerFails: false)
        await backend.pauseNextStateRead(for: "missing")
        let staleRefresh = Task { await console.refresh() }
        await backend.waitForPausedStateRead()
        #expect(await console.undoArchive(for: "restored", restoringFocusFrom: previousFocus))
        #expect(console.focusedTaskIDs == previousFocus)
        await backend.resumeStateRead()
        await staleRefresh.value
        await console.refresh()
        try await waitUntil { console.allTasks.isEmpty }

        await backend.omitTasks([], readerFails: false)
        await console.refresh()
        try await waitUntil { console.allTasks.count == 2 }
        #expect(console.focusedTaskIDs == previousFocus)
    }

    @Test(arguments: [true, false])
    func automaticFocusWaitsForSubtreeUndoBeforeObservingRestoredTasks(previouslyFocused: Bool) async throws {
        let backend = FocusBackend(
            tasks: [focusTask("parent", status: .error), focusTask("child", status: .error), focusTask("keep")],
            archiveChildren: ["parent": ["child"]]
        )
        let console = makeConsole(backend: backend, automaticallyFocusStartedTasks: true)
        await console.refresh()
        let previousFocus = previouslyFocused ? ["child", "parent", "keep"] : ["keep"]
        console.setFocusedTasks(previousFocus)
        #expect(await console.setArchived(true, for: "parent") == .completed)
        await console.refresh()
        #expect(console.focusedTaskIDs == ["keep"])

        await backend.pauseNextUndoResponse()
        let undo = Task { await console.undoArchive(for: "parent", restoringFocusFrom: previousFocus) }
        await backend.waitForPausedUndoResponse()
        // The backend has restored the subtree, but has not returned the affected IDs yet.
        await console.refresh()
        #expect(console.focusedTaskIDs == ["keep"])
        await backend.resumeUndoResponse()
        #expect(await undo.value)
        try await waitUntil { console.allTasks.count == 3 }
        #expect(console.focusedTaskIDs == previousFocus)
    }

    @Test(arguments: [FocusArchiveOutcome.completed, .deferred])
    func undoDuringStateReadPreservesRestoredFocusWithOrWithoutCachedTask(outcome: FocusArchiveOutcome) async {
        let backend = FocusBackend(
            tasks: [focusTask("queued"), focusTask("missing")],
            archiveOutcome: outcome
        )
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["queued", "missing"])
        #expect(await console.setArchived(true, for: "queued") == (outcome == .completed ? .completed : .deferred))
        #expect(console.focusedTaskIDs == ["missing"])
        #expect(console.allTasks.contains(where: { $0.id == "queued" }) == (outcome == .deferred))

        await backend.omitTasks(["missing"], readerFails: false)
        await backend.pauseNextStateRead(for: "missing")
        let staleRefresh = Task { await console.refresh() }
        await backend.waitForPausedStateRead()

        #expect(await console.undoArchive(for: "queued", restoringFocusFrom: ["queued", "missing"]))
        #expect(console.focusedTaskIDs == ["queued", "missing"])
        await backend.resumeStateRead()
        await staleRefresh.value

        #expect(console.focusedTaskIDs == ["queued", "missing"])
        #expect(console.pendingArchiveTaskIDs.isEmpty)
        await console.refresh()
        #expect(console.focusedTaskIDs == ["queued", "missing"])
    }

    @Test
    func staleArchivedDescendantResultDoesNotEraseFocusAfterParentUndo() async {
        let backend = FocusBackend(
            tasks: [focusTask("parent"), focusTask("child")],
            archiveChildren: ["parent": ["child"]]
        )
        let console = makeConsole(backend: backend)
        await console.refresh()
        console.setFocusedTasks(["child"])
        #expect(await console.setArchived(true, for: "parent") == .completed)

        await backend.pauseNextStateRead(for: "child")
        let staleRefresh = Task { await console.refresh() }
        await backend.waitForPausedStateRead()
        #expect(await console.undoArchive(for: "parent", restoringFocusFrom: ["child"]))
        await backend.resumeStateRead()
        await staleRefresh.value

        #expect(console.focusedTaskIDs == ["child"])
        await console.refresh()
        #expect(console.focusedTasks.map(\.id) == ["child"])
    }

    @Test
    func undoFocusMergeKeepsInterveningEditsAndExcludesUnpinnedTasks() async {
        let backend = FocusBackend(tasks: [
            "left", "restored", "removed", "unpinned", "right", "new"
        ].map { focusTask($0) })
        let console = makeConsole(backend: backend)
        await console.refresh()
        let originalFocus = ["left", "restored", "removed", "unpinned", "right"]
        console.setFocusedTasks(originalFocus)
        #expect(await console.setArchived(true, for: "restored") == .completed)

        console.hide("unpinned")
        console.setFocusedTasks(["left", "new", "right"])
        console.restoreFocusedTasks(["restored", "unpinned"], from: originalFocus)

        #expect(console.focusedTaskIDs.filter { $0 != "restored" } == ["left", "new", "right"])
        #expect(console.focusedTaskIDs.filter { ["left", "restored", "right"].contains($0) }
            == ["left", "restored", "right"])
        #expect(!console.isMonitored("unpinned"))
    }

    private func makeConsole(
        backend: FocusBackend,
        visibility: FocusVisibilityStorage = FocusVisibilityStorage(),
        automaticallyFocusStartedTasks: Bool = false
    ) -> AttentionConsole {
        let console = AttentionConsole(
            loader: backend,
            archiver: backend,
            storage: visibility,
            titleStorage: FocusStringStorage(),
            priorityStorage: FocusPriorityStorage(),
            noteStorage: FocusStringStorage(),
            reminderStorage: FocusReminderStorage(),
            projectOrderStorage: FocusProjectOrderStorage(),
            launchedAt: Date(timeIntervalSince1970: 1_000),
            archiveStateReader: backend
        )
        console.automaticallyFocusStartedTasks = automaticallyFocusStartedTasks
        return console
    }
}

enum FocusArchiveOutcome: String, CaseIterable, Sendable {
    case completed, deferred, failed
}

private actor FocusBackend: CodexTaskLoading, CodexTaskArchiving, CodexTaskArchiveUndoing, CodexTaskArchiveStateReading {
    private var tasks: [CodexTask]
    private let archiveOutcome: FocusArchiveOutcome
    private let archiveChildren: [String: Set<String>]
    private var archivedTaskIDs: Set<String> = []
    private var pendingTaskIDs: Set<String> = []
    private var omittedTaskIDs: Set<String> = []
    private var readerFails = false
    private var nextPausedReadTaskID: String?
    private var pausedRead: CheckedContinuation<Void, Never>?
    private var pausedReadWaiter: CheckedContinuation<Void, Never>?
    private var shouldPauseUndoResponse = false
    private var pausedUndoResponse: CheckedContinuation<Void, Never>?
    private var pausedUndoWaiter: CheckedContinuation<Void, Never>?
    private(set) var lastAlwaysIncludedIDs: Set<String> = []
    private(set) var checkedTaskIDs: Set<String> = []

    init(
        tasks: [CodexTask],
        archiveOutcome: FocusArchiveOutcome = .completed,
        archiveChildren: [String: Set<String>] = [:]
    ) {
        self.tasks = tasks
        self.archiveOutcome = archiveOutcome
        self.archiveChildren = archiveChildren
    }

    func replaceTasks(_ tasks: [CodexTask]) { self.tasks = tasks }
    func archiveExternally(_ taskIDs: Set<String>) { archivedTaskIDs.formUnion(taskIDs) }
    func deleteTasks(_ taskIDs: Set<String>) { tasks.removeAll { taskIDs.contains($0.id) } }
    func omitTasks(_ taskIDs: Set<String>, readerFails: Bool) {
        omittedTaskIDs = taskIDs
        self.readerFails = readerFails
    }

    func pauseNextStateRead(for taskID: String) { nextPausedReadTaskID = taskID }

    func waitForPausedStateRead() async {
        guard pausedRead == nil else { return }
        await withCheckedContinuation { pausedReadWaiter = $0 }
    }

    func resumeStateRead() {
        pausedRead?.resume()
        pausedRead = nil
    }

    func pauseNextUndoResponse() { shouldPauseUndoResponse = true }

    func waitForPausedUndoResponse() async {
        guard pausedUndoResponse == nil else { return }
        await withCheckedContinuation { pausedUndoWaiter = $0 }
    }

    func resumeUndoResponse() {
        pausedUndoResponse?.resume()
        pausedUndoResponse = nil
    }

    func loadSnapshot(including kinds: Set<CodexTaskKind>, alwaysIncluding taskIDs: Set<String>) -> CodexTaskSnapshot {
        lastAlwaysIncludedIDs = taskIDs
        return CodexTaskSnapshot(tasks: tasks.filter {
            !archivedTaskIDs.contains($0.id) && !omittedTaskIDs.contains($0.id)
                && (kinds.contains($0.kind) || taskIDs.contains($0.id))
        }, projects: [])
    }

    func setArchived(_ archived: Bool, taskID: String) throws -> CodexTaskArchiveResult {
        guard archived else {
            archivedTaskIDs.remove(taskID)
            pendingTaskIDs.remove(taskID)
            return .completed
        }
        switch archiveOutcome {
        case .completed:
            archivedTaskIDs.insert(taskID)
            archivedTaskIDs.formUnion(archiveChildren[taskID] ?? [])
            return .completed
        case .deferred:
            pendingTaskIDs.insert(taskID)
            return .deferred
        case .failed:
            throw FocusFixtureError.archive
        }
    }

    func pendingArchiveTaskIDs() -> Set<String> { pendingTaskIDs }
    @discardableResult
    func undoArchive(taskID: String) async -> Set<String> {
        archivedTaskIDs.remove(taskID)
        archivedTaskIDs.subtract(archiveChildren[taskID] ?? [])
        pendingTaskIDs.remove(taskID)
        if shouldPauseUndoResponse {
            shouldPauseUndoResponse = false
            await withCheckedContinuation { continuation in
                pausedUndoResponse = continuation
                pausedUndoWaiter?.resume()
                pausedUndoWaiter = nil
            }
        }
        return Set([taskID]).union(archiveChildren[taskID] ?? [])
    }

    func isTaskUnarchived(_ taskID: String) async throws -> Bool {
        checkedTaskIDs.insert(taskID)
        if readerFails { throw FocusFixtureError.stateRead }
        let isUnarchived = tasks.contains { $0.id == taskID } && !archivedTaskIDs.contains(taskID)
        if nextPausedReadTaskID == taskID {
            nextPausedReadTaskID = nil
            await withCheckedContinuation { continuation in
                pausedRead = continuation
                pausedReadWaiter?.resume()
                pausedReadWaiter = nil
            }
        }
        return isUnarchived
    }

    func archiveStatesInSubtree(taskID: String) -> [String: Bool] {
        guard tasks.contains(where: { $0.id == taskID }) else { return [:] }
        return [taskID: archivedTaskIDs.contains(taskID)]
    }
}

private enum FocusFixtureError: LocalizedError {
    case archive, stateRead
    var errorDescription: String? {
        switch self {
        case .archive: "Focus fixture archive failed"
        case .stateRead: "Focus fixture state read failed"
        }
    }
}

private func focusTask(
    _ id: String,
    status: AttentionStatus = .working,
    kind: CodexTaskKind = .regular,
    finishedAt: Date? = nil
) -> CodexTask {
    CodexTask(
        id: id, title: id, projectKey: "project", projectName: "Project", projectPath: "/code/project",
        isChat: false, kind: kind, status: status,
        updatedAt: Date(timeIntervalSince1970: 2_000), finishedAt: finishedAt
    )
}

@MainActor
private final class FocusVisibilityStorage: VisibilityStoring {
    private var ledger: VisibilityLedger
    init(ledger: VisibilityLedger = VisibilityLedger()) { self.ledger = ledger }
    func load() -> VisibilityLedger { ledger }
    func save(_ ledger: VisibilityLedger) { self.ledger = ledger }
}

@MainActor
private final class FocusStringStorage: TaskTitleStoring, TaskNoteStoring {
    private var values: [String: String] = [:]
    func load() -> [String: String] { values }
    func save(_ values: [String: String]) { self.values = values }
}

@MainActor
private final class FocusPriorityStorage: TaskPriorityStoring {
    private var values: [String: TaskPriority] = [:]
    func load() -> [String: TaskPriority] { values }
    func save(_ values: [String: TaskPriority]) { self.values = values }
}

@MainActor
private final class FocusReminderStorage: TaskReminderStoring {
    private var values: [String: TaskReminder] = [:]
    func load() -> [String: TaskReminder] { values }
    func save(_ values: [String: TaskReminder]) { self.values = values }
}

@MainActor
private final class FocusProjectOrderStorage: ProjectOrderStoring {
    private var values: [String] = []
    func load() -> [String] { values }
    func save(_ values: [String]) { self.values = values }
}
