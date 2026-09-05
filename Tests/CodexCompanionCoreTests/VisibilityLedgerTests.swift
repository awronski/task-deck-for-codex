import CodexCompanionCore
import Foundation
import Testing

@Suite
struct VisibilityLedgerTests {
    @Test
    func firstLaunchAddsOnlyTasksThatCurrentlyNeedMonitoring() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [
            task("working", status: .working),
            task("waiting", status: .waitingForInput),
            task("historical", status: .inactive)
        ])

        #expect(ledger.isMonitored("working"))
        #expect(ledger.isMonitored("waiting"))
        #expect(!ledger.isMonitored("historical"))
        #expect(ledger.knownTaskIDs == ["working", "waiting", "historical"])
        #expect(ledger.focusedTaskIDs.isEmpty)
    }

    @Test
    func everyNewTaskAppearsEvenIfItCompletedWhileTheAppWasClosed() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [task("existing", status: .inactive)])
        ledger.reconcile(with: [
            task("existing", status: .inactive),
            task("new-and-complete", status: .inactive)
        ])

        #expect(ledger.isMonitored("new-and-complete"))
    }

    @Test
    func hiddenActiveTaskReturnsOnlyAfterItStartsWorkingAgain() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [task("task", status: .working)])
        ledger.hide(taskID: "task")
        ledger.reconcile(with: [task("task", status: .working)])

        #expect(!ledger.isMonitored("task"))
        #expect(ledger.hiddenTaskIDs.contains("task"))

        ledger.reconcile(with: [task("task", status: .inactive)])
        #expect(!ledger.isMonitored("task"))

        ledger.reconcile(with: [task("task", status: .working)])
        #expect(ledger.isMonitored("task"))
        #expect(!ledger.hiddenTaskIDs.contains("task"))
    }

    @Test
    func hiddenInactiveTaskReturnsWhenItStartsWorking() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [task("task", status: .inactive)])
        ledger.hide(taskID: "task")

        ledger.reconcile(with: [task("task", status: .working)])

        #expect(ledger.isMonitored("task"))
        #expect(!ledger.hiddenTaskIDs.contains("task"))
    }

    @Test
    func visibleTaskRemainsAfterItBecomesInactive() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [task("task", status: .working)])
        ledger.reconcile(with: [task("task", status: .inactive)])

        #expect(ledger.isMonitored("task"))
    }

    @Test
    func manualEnableOverridesHiddenState() {
        var ledger = VisibilityLedger()
        ledger.hide(taskID: "task")
        ledger.enable(taskID: "task")

        #expect(ledger.isMonitored("task"))
        #expect(!ledger.hiddenTaskIDs.contains("task"))
    }

    @Test
    func finishedAcknowledgementResetsWhenTaskWorksAgain() {
        var ledger = VisibilityLedger(isBootstrapped: true)
        ledger.acknowledgeFinished(taskID: "task")
        ledger.reconcile(with: [task("task", status: .finished)])
        #expect(ledger.isFinishedAcknowledged("task"))

        ledger.reconcile(with: [task("task", status: .working)])
        #expect(!ledger.isFinishedAcknowledged("task"))
    }

    @Test
    func kindFilteredAbsenceDoesNotResetFinishedAcknowledgement() {
        var ledger = VisibilityLedger(isBootstrapped: true)
        ledger.acknowledgeFinished(taskID: "regular-task")

        ledger.reconcile(with: [task("optional-agent", status: .working)])
        #expect(ledger.isFinishedAcknowledged("regular-task"))

        ledger.reconcile(with: [task("regular-task", status: .finished)])
        #expect(ledger.isFinishedAcknowledged("regular-task"))
    }

    @Test
    func optionalObservedTaskCanResetAcknowledgementWithoutChangingMembership() {
        var ledger = VisibilityLedger(
            isBootstrapped: true,
            acknowledgedFinishedTaskIDs: ["agent"]
        )

        ledger.reconcileFinishedStates(with: [task("agent", status: .working)])
        ledger.reconcileMembership(with: [])

        #expect(!ledger.isFinishedAcknowledged("agent"))
        #expect(!ledger.isMonitored("agent"))
    }

    @Test
    func optionalObservedTaskContributesToActiveTransitionTrackingOnly() {
        var ledger = VisibilityLedger(isBootstrapped: true)
        let agent = task("agent", status: .working)

        ledger.reconcileMembership(with: [], observing: [agent])

        #expect(ledger.activeTaskIDs == [agent.id])
        #expect(!ledger.isMonitored(agent.id))
        #expect(!ledger.knownTaskIDs.contains(agent.id))
    }

    @Test
    func olderSavedLedgerDecodesWithoutFinishedAcknowledgements() throws {
        let data = Data(#"{"isBootstrapped":true,"knownTaskIDs":["task"],"monitoredTaskIDs":["task"],"hiddenTaskIDs":[]}"#.utf8)
        let ledger = try JSONDecoder().decode(VisibilityLedger.self, from: data)

        #expect(ledger.isMonitored("task"))
        #expect(!ledger.isFinishedAcknowledged("task"))
        #expect(ledger.activeTaskIDs.isEmpty)
        #expect(ledger.focusedTaskIDs.isEmpty)
    }

    @Test
    func focusOrderSurvivesPersistence() throws {
        var ledger = VisibilityLedger(monitoredTaskIDs: ["first", "second", "third"])
        ledger.setFocusedTasks(["second", "first"])

        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(VisibilityLedger.self, from: data)

        #expect(restored == ledger)
        #expect(restored.focusedTaskIDs == ["second", "first"])
    }

    @Test
    func focusSelectionKeepsOnlyUniqueMonitoredTasksInRequestedOrder() {
        var ledger = VisibilityLedger(
            monitoredTaskIDs: ["first", "second", "hidden"],
            hiddenTaskIDs: ["hidden"],
            focusedTaskIDs: ["missing", "first", "first", "hidden"]
        )
        #expect(ledger.focusedTaskIDs == ["first"])

        ledger.setFocusedTasks(["missing", "second", "hidden", "first", "second"])
        #expect(ledger.focusedTaskIDs == ["second", "first"])
        #expect(!ledger.isMonitored("missing"))

        ledger.setFocusedTasks([])
        #expect(ledger.focusedTaskIDs.isEmpty)
        #expect(ledger.isMonitored("first"))
    }

    @Test
    func statusChangesNewTasksAndTemporaryAbsenceDoNotChangeFocus() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [
            task("first", status: .working),
            task("second", status: .working)
        ])
        ledger.setFocusedTasks(["second", "first"])

        ledger.reconcile(with: [
            task("first", status: .finished),
            task("second", status: .error),
            task("new", status: .waitingForInput)
        ])
        #expect(ledger.focusedTaskIDs == ["second", "first"])
        #expect(ledger.isMonitored("new"))

        ledger.reconcile(with: [])
        #expect(ledger.focusedTaskIDs == ["second", "first"])
    }

    @Test
    func hidingRemovesFocusButEnableAndReactivationDoNotRestoreIt() {
        var ledger = VisibilityLedger()
        ledger.reconcile(with: [
            task("first", status: .working),
            task("second", status: .working),
            task("third", status: .working)
        ])
        ledger.setFocusedTasks(["second", "first", "third"])

        ledger.hide(taskID: "first")
        #expect(ledger.focusedTaskIDs == ["second", "third"])
        ledger.enable(taskID: "first")
        #expect(ledger.isMonitored("first"))
        #expect(ledger.focusedTaskIDs == ["second", "third"])

        ledger.hide(taskID: "second")
        ledger.reconcile(with: [task("second", status: .inactive)])
        ledger.reconcile(with: [task("second", status: .working)])
        #expect(ledger.isMonitored("second"))
        #expect(ledger.focusedTaskIDs == ["third"])
    }

    @Test
    func newerCompletionResetsAcknowledgementWithoutAnObservedWorkingState() {
        let firstFinish = Date(timeIntervalSince1970: 100)
        var ledger = VisibilityLedger(isBootstrapped: true)
        ledger.acknowledgeFinished(taskID: "task", finishedAt: firstFinish)
        ledger.reconcileFinishedStates(with: [
            task("task", status: .finished, finishedAt: firstFinish)
        ])
        #expect(ledger.isFinishedAcknowledged("task"))

        ledger.reconcileFinishedStates(with: [
            task("task", status: .finished, finishedAt: firstFinish.addingTimeInterval(1))
        ])
        #expect(!ledger.isFinishedAcknowledged("task"))
    }

    @Test
    func completionIdentitySurvivesPersistenceAndFilteredAbsence() throws {
        let firstFinish = Date(timeIntervalSince1970: 100)
        var original = VisibilityLedger(isBootstrapped: true)
        original.acknowledgeFinished(taskID: "task", finishedAt: firstFinish)
        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(VisibilityLedger.self, from: data)
        #expect(restored == original)

        restored.reconcileFinishedStates(with: [])
        #expect(restored.isFinishedAcknowledged("task"))
        restored.reconcileFinishedStates(with: [
            task("task", status: .finished, finishedAt: firstFinish.addingTimeInterval(1))
        ])
        #expect(!restored.isFinishedAcknowledged("task"))
    }

    @Test
    func legacyAcknowledgementAdoptsTheFirstKnownCompletion() throws {
        let data = Data(#"{"isBootstrapped":true,"acknowledgedFinishedTaskIDs":["task"]}"#.utf8)
        var ledger = try JSONDecoder().decode(VisibilityLedger.self, from: data)
        ledger.reconcileFinishedStates(with: [task("task", status: .finished)])
        #expect(ledger.isFinishedAcknowledged("task"))

        let firstKnownFinish = Date(timeIntervalSince1970: 100)
        ledger.reconcileFinishedStates(with: [
            task("task", status: .finished, finishedAt: firstKnownFinish)
        ])
        #expect(ledger.isFinishedAcknowledged("task"))

        ledger.reconcileFinishedStates(with: [
            task("task", status: .finished, finishedAt: firstKnownFinish.addingTimeInterval(1))
        ])
        #expect(!ledger.isFinishedAcknowledged("task"))
    }

    @Test
    func timestampLessCompletionRemainsAcknowledgedUntilWorkingIsObserved() {
        var ledger = VisibilityLedger(isBootstrapped: true)
        ledger.acknowledgeFinished(taskID: "task")
        ledger.reconcileFinishedStates(with: [task("task", status: .finished)])
        ledger.reconcileFinishedStates(with: [task("task", status: .finished)])
        #expect(ledger.isFinishedAcknowledged("task"))

        ledger.reconcileFinishedStates(with: [task("task", status: .working)])
        #expect(!ledger.isFinishedAcknowledged("task"))
    }

    private func task(_ id: String, status: AttentionStatus, finishedAt: Date? = nil) -> CodexTask {
        CodexTask(
            id: id,
            title: id,
            projectKey: "/code/project",
            projectName: "project",
            projectPath: "/code/project",
            isChat: false,
            status: status,
            updatedAt: .now,
            finishedAt: finishedAt
        )
    }
}
