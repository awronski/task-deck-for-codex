import Foundation

public struct VisibilityLedger: Codable, Equatable, Sendable {
    public private(set) var isBootstrapped: Bool
    public private(set) var knownTaskIDs: Set<String>
    public private(set) var monitoredTaskIDs: Set<String>
    public private(set) var hiddenTaskIDs: Set<String>
    public private(set) var acknowledgedFinishedTaskIDs: Set<String>
    public private(set) var activeTaskIDs: Set<String>

    public init(
        isBootstrapped: Bool = false,
        knownTaskIDs: Set<String> = [],
        monitoredTaskIDs: Set<String> = [],
        hiddenTaskIDs: Set<String> = [],
        acknowledgedFinishedTaskIDs: Set<String> = [],
        activeTaskIDs: Set<String> = []
    ) {
        self.isBootstrapped = isBootstrapped
        self.knownTaskIDs = knownTaskIDs
        self.monitoredTaskIDs = monitoredTaskIDs
        self.hiddenTaskIDs = hiddenTaskIDs
        self.acknowledgedFinishedTaskIDs = acknowledgedFinishedTaskIDs
        self.activeTaskIDs = activeTaskIDs
    }

    public mutating func reconcile(with tasks: [CodexTask]) {
        reconcileFinishedStates(with: tasks)
        reconcileMembership(with: tasks)
    }

    public mutating func reconcileFinishedStates(with tasks: [CodexTask]) {
        acknowledgedFinishedTaskIDs.subtract(
            tasks.lazy.filter { $0.status != .finished }.map(\.id)
        )
    }

    public mutating func reconcileMembership(
        with tasks: [CodexTask],
        observing observedTasks: [CodexTask]? = nil
    ) {
        let availableIDs = Set(tasks.map(\.id))
        let currentActiveIDs = Set(tasks.lazy.filter(\.status.isActive).map(\.id))
        let observedActiveIDs = Set(
            (observedTasks ?? tasks).lazy.filter(\.status.isActive).map(\.id)
        )

        if !isBootstrapped {
            knownTaskIDs.formUnion(availableIDs)
            monitoredTaskIDs.formUnion(currentActiveIDs.subtracting(hiddenTaskIDs))
            activeTaskIDs = observedActiveIDs
            isBootstrapped = true
            return
        }

        let newTaskIDs = availableIDs.subtracting(knownTaskIDs)
        monitoredTaskIDs.formUnion(newTaskIDs.subtracting(hiddenTaskIDs))
        knownTaskIDs.formUnion(availableIDs)

        let reactivatedTaskIDs = currentActiveIDs.subtracting(activeTaskIDs)
        hiddenTaskIDs.subtract(reactivatedTaskIDs)
        monitoredTaskIDs.formUnion(reactivatedTaskIDs)
        activeTaskIDs = observedActiveIDs
    }

    public mutating func hide(taskID: String) {
        knownTaskIDs.insert(taskID)
        monitoredTaskIDs.remove(taskID)
        hiddenTaskIDs.insert(taskID)
    }

    public mutating func enable(taskID: String) {
        knownTaskIDs.insert(taskID)
        hiddenTaskIDs.remove(taskID)
        monitoredTaskIDs.insert(taskID)
    }

    public func isMonitored(_ taskID: String) -> Bool {
        monitoredTaskIDs.contains(taskID) && !hiddenTaskIDs.contains(taskID)
    }

    public mutating func acknowledgeFinished(taskID: String) {
        acknowledgedFinishedTaskIDs.insert(taskID)
    }

    public func isFinishedAcknowledged(_ taskID: String) -> Bool {
        acknowledgedFinishedTaskIDs.contains(taskID)
    }

    private enum CodingKeys: String, CodingKey {
        case isBootstrapped
        case knownTaskIDs
        case monitoredTaskIDs
        case hiddenTaskIDs
        case acknowledgedFinishedTaskIDs
        case activeTaskIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isBootstrapped = try container.decodeIfPresent(Bool.self, forKey: .isBootstrapped) ?? false
        knownTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .knownTaskIDs) ?? []
        monitoredTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .monitoredTaskIDs) ?? []
        hiddenTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenTaskIDs) ?? []
        acknowledgedFinishedTaskIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .acknowledgedFinishedTaskIDs
        ) ?? []
        activeTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .activeTaskIDs) ?? []
    }

}
