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
    }

    private func task(_ id: String, status: AttentionStatus) -> CodexTask {
        CodexTask(
            id: id,
            title: id,
            projectKey: "/code/project",
            projectName: "project",
            projectPath: "/code/project",
            isChat: false,
            status: status,
            updatedAt: .now
        )
    }
}
