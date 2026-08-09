import Foundation

public enum AttentionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case waitingForInput
    case waitingForPermission
    case error
    case working
    case finished
    case inactive

    public var isActive: Bool {
        switch self {
        case .waitingForInput, .waitingForPermission, .error, .working: true
        case .finished, .inactive: false
        }
    }

    public var sortOrder: Int {
        switch self {
        case .error: 0
        case .waitingForInput: 1
        case .waitingForPermission: 2
        case .working: 3
        case .finished: 4
        case .inactive: 5
        }
    }
}

public enum CodexTaskKind: String, CaseIterable, Hashable, Sendable {
    case regular
    case delegated
    case automation
    case agent
    case batch
    case unassigned

    public static let defaultVisible: Set<CodexTaskKind> = [.regular, .delegated, .automation]
}

public enum TaskPriority: String, CaseIterable, Hashable, Sendable {
    case none
    case blue
    case green
    case yellow
    case orange
    case red

    public var title: String {
        switch self {
        case .none: "No flag"
        case .blue: "Work in progress"
        case .green: "Ready"
        case .yellow: "Needs attention"
        case .orange: "Important issue"
        case .red: "Critical issue"
        }
    }
}

public enum ReminderOffsetUnit: String, CaseIterable, Hashable, Sendable {
    case minutes
    case hours
    case days

    public func date(after date: Date, value: Int, calendar: Calendar = .current) -> Date? {
        guard value > 0 else { return nil }
        let component: Calendar.Component = switch self {
        case .minutes: .minute
        case .hours: .hour
        case .days: .day
        }
        return calendar.date(byAdding: component, value: value, to: date)
    }
}

public struct TaskReminder: Codable, Equatable, Identifiable, Sendable {
    public let taskID: String
    public let title: String
    public let dueAt: Date

    public var id: String { taskID }

    public init(taskID: String, title: String, dueAt: Date) {
        self.taskID = taskID
        self.title = title
        self.dueAt = dueAt
    }
}

public struct TaskActivityEvent: Equatable, Sendable {
    public let title: String
    public let occurredAt: Date?

    public init(title: String, occurredAt: Date? = nil) {
        self.title = title
        self.occurredAt = occurredAt
    }
}

public struct TaskActivityPreview: Equatable, Sendable {
    public let headline: String
    public let detail: String?
    public let recentEvents: [TaskActivityEvent]

    public init(
        headline: String,
        detail: String? = nil,
        recentEvents: [TaskActivityEvent] = []
    ) {
        self.headline = headline
        self.detail = detail
        self.recentEvents = recentEvents
    }
}

public struct CodexTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let projectKey: String
    public let projectName: String
    public let projectPath: String
    public let isChat: Bool
    public let kind: CodexTaskKind
    public let priority: TaskPriority
    public let status: AttentionStatus
    public let modelName: String?
    public let thinkingEffort: String?
    public let activity: TaskActivityPreview?
    public let updatedAt: Date
    public let workingSince: Date?
    public let finishedAt: Date?
    public let createdAt: Date

    public init(
        id: String,
        title: String,
        projectKey: String,
        projectName: String,
        projectPath: String,
        isChat: Bool,
        kind: CodexTaskKind = .regular,
        priority: TaskPriority = .none,
        status: AttentionStatus,
        modelName: String? = nil,
        thinkingEffort: String? = nil,
        activity: TaskActivityPreview? = nil,
        updatedAt: Date,
        workingSince: Date? = nil,
        finishedAt: Date? = nil,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.projectKey = projectKey
        self.projectName = projectName
        self.projectPath = projectPath
        self.isChat = isChat
        self.kind = kind
        self.priority = priority
        self.status = status
        self.modelName = modelName
        self.thinkingEffort = thinkingEffort
        self.activity = activity
        self.updatedAt = updatedAt
        self.workingSince = workingSince
        self.finishedAt = finishedAt
        self.createdAt = createdAt
    }
}

public enum TaskTimer {
    public static func compactElapsed(from startedAt: Date, to currentDate: Date) -> String {
        let totalSeconds = max(0, Int(currentDate.timeIntervalSince(startedAt)))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

public enum TaskAge {
    public static func relativeDescription(from createdAt: Date, to currentDate: Date) -> String {
        let totalSeconds = max(0, Int(currentDate.timeIntervalSince(createdAt)))

        if totalSeconds < 60 {
            return description(totalSeconds, unit: "second")
        }

        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return description(totalMinutes, unit: "minute")
        }

        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            return description(totalHours, unit: "hour")
        }

        let totalDays = totalHours / 24
        if totalDays < 30 {
            return description(totalDays, unit: "day")
        }

        if totalDays < 365 {
            return description(totalDays / 30, unit: "month")
        }

        return description(totalDays / 365, unit: "year")
    }

    public static func refreshInterval(from createdAt: Date, to currentDate: Date) -> TimeInterval {
        let age = max(0, currentDate.timeIntervalSince(createdAt))
        if age < 60 { return 1 }
        if age < 3_600 { return 60 }
        if age < 86_400 { return 3_600 }
        return 86_400
    }

    private static func description(_ value: Int, unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }
}

public struct ProjectSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let isChat: Bool
    public let tasks: [CodexTask]

    public init(id: String, name: String, path: String, isChat: Bool, tasks: [CodexTask]) {
        self.id = id
        self.name = name
        self.path = path
        self.isChat = isChat
        self.tasks = tasks
    }

    public var highestPriorityStatus: AttentionStatus {
        tasks.min(by: { $0.status.sortOrder < $1.status.sortOrder })?.status ?? .inactive
    }

    public var mostRecentUpdate: Date {
        tasks.map(\.updatedAt).max() ?? .distantPast
    }
}

public enum TaskGrouping {
    public static func sections(
        from tasks: [CodexTask],
        includingEmptyProjects emptyProjects: [ProjectIdentity] = [],
        matching query: String = "",
        projectDisplayNames: [String: String] = [:],
        projectIDs: Set<String> = [],
        statuses: Set<AttentionStatus> = []
    ) -> [ProjectSection] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = tasks.filter { task in
            let matchesProject = projectIDs.isEmpty || projectIDs.contains(task.projectKey)
            let matchesStatus = statuses.isEmpty || statuses.contains(task.status)
            let matchesSearch = normalizedQuery.isEmpty
                || task.title.localizedCaseInsensitiveContains(normalizedQuery)
                || task.projectName.localizedCaseInsensitiveContains(normalizedQuery)
                || projectDisplayNames[task.projectKey]?.localizedCaseInsensitiveContains(normalizedQuery) == true
            return matchesProject && matchesStatus && matchesSearch
        }

        var sections: [ProjectSection] = Dictionary(grouping: filtered, by: \.projectKey)
            .compactMap { key, projectTasks in
                guard let first = projectTasks.first else { return nil }
                let sortedTasks = projectTasks.sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.id < $1.id
                }
                return ProjectSection(
                    id: key,
                    name: first.projectName,
                    path: first.projectPath,
                    isChat: first.isChat,
                    tasks: sortedTasks
                )
            }

        if statuses.isEmpty {
            let visibleProjectIDs = Set(sections.map(\.id))
            let emptySections: [ProjectSection] = emptyProjects.compactMap { project in
                let matchesProject = projectIDs.isEmpty || projectIDs.contains(project.key)
                let matchesSearch = normalizedQuery.isEmpty
                    || project.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || projectDisplayNames[project.key]?.localizedCaseInsensitiveContains(normalizedQuery) == true
                guard !visibleProjectIDs.contains(project.key), matchesProject, matchesSearch else {
                    return nil
                }
                return ProjectSection(
                    id: project.key,
                    name: project.name,
                    path: project.path,
                    isChat: project.isChat,
                    tasks: []
                )
            }
            sections.append(contentsOf: emptySections)
        }

        return sections.sorted {
            if $0.mostRecentUpdate != $1.mostRecentUpdate {
                return $0.mostRecentUpdate > $1.mostRecentUpdate
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public enum ProjectOrdering {
    public static func applying(_ preferredOrder: [String], to sections: [ProjectSection]) -> [ProjectSection] {
        var ranks: [String: Int] = [:]
        for projectID in preferredOrder where ranks[projectID] == nil {
            ranks[projectID] = ranks.count
        }

        return sections.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isChat != rhs.element.isChat {
                    return !lhs.element.isChat
                }
                let lhsRank = ranks[lhs.element.id] ?? ranks.count + lhs.offset
                let rhsRank = ranks[rhs.element.id] ?? ranks.count + rhs.offset
                return lhsRank < rhsRank
            }
            .map(\.element)
    }

    public static func sortingAutomatically(
        _ sections: [ProjectSection],
        using allTasks: [CodexTask]
    ) -> [ProjectSection] {
        let newestTaskCreationDates = allTasks.reduce(into: [String: Date]()) { dates, task in
            dates[task.projectKey] = max(dates[task.projectKey] ?? .distantPast, task.createdAt)
        }

        return sortingAutomatically(sections, using: newestTaskCreationDates)
    }

    public static func sortingAutomatically(
        _ sections: [ProjectSection],
        using newestTaskCreationDates: [String: Date]
    ) -> [ProjectSection] {
        return sections.sorted { lhs, rhs in
            if lhs.isChat != rhs.isChat {
                return !lhs.isChat
            }

            let lhsCreationDate = newestTaskCreationDates[lhs.id]
            let rhsCreationDate = newestTaskCreationDates[rhs.id]
            switch (lhsCreationDate, rhsCreationDate) {
            case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    public static func moving(
        _ sourceID: String,
        relativeTo targetID: String,
        insertAfter: Bool,
        in currentOrder: [String]
    ) -> [String] {
        guard sourceID != targetID,
              let sourceIndex = currentOrder.firstIndex(of: sourceID),
              currentOrder.contains(targetID)
        else {
            return currentOrder
        }

        var reordered = currentOrder
        reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(of: targetID) else { return currentOrder }
        reordered.insert(sourceID, at: targetIndex + (insertAfter ? 1 : 0))
        return reordered
    }
}

public struct ProjectIdentity: Identifiable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let path: String
    public let isChat: Bool

    public var id: String { key }

    public init(key: String, name: String, path: String, isChat: Bool) {
        self.key = key
        self.name = name
        self.path = path
        self.isChat = isChat
    }
}

public struct CodexTaskSnapshot: Equatable, Sendable {
    public let tasks: [CodexTask]
    public let projects: [ProjectIdentity]
    public let newestTaskCreationDatesByProjectID: [String: Date]

    public init(
        tasks: [CodexTask],
        projects: [ProjectIdentity],
        newestTaskCreationDatesByProjectID: [String: Date]? = nil
    ) {
        self.tasks = tasks
        self.projects = projects
        self.newestTaskCreationDatesByProjectID = newestTaskCreationDatesByProjectID
            ?? tasks.reduce(into: [:]) { dates, task in
                dates[task.projectKey] = max(dates[task.projectKey] ?? .distantPast, task.createdAt)
            }
    }
}

public enum ProjectResolver {
    public static func resolve(path rawPath: String, homeDirectory: String = NSHomeDirectory()) -> ProjectIdentity? {
        guard rawPath.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        let chatsRoot = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Documents/Codex", isDirectory: true)
            .standardizedFileURL.path
        if path == chatsRoot {
            return ProjectIdentity(key: "chats", name: "Chats", path: chatsRoot, isChat: true)
        }
        let prefix = chatsRoot + "/"

        if path.hasPrefix(prefix) {
            let components = String(path.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: true)
            if components.count == 2,
               components[0].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            {
                return ProjectIdentity(key: "chats", name: "Chats", path: chatsRoot, isChat: true)
            }
            return nil
        }

        let name = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "/" else { return nil }
        return ProjectIdentity(key: path, name: name, path: path, isChat: false)
    }
}

public enum TaskText {
    public static func cleanTitle(_ rawTitle: String, fallbackID: String) -> String {
        var title = rawTitle
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        if title.hasPrefix("/goal ") {
            title.removeFirst("/goal ".count)
        }

        if title.isEmpty {
            return "Task \(fallbackID.prefix(8))"
        }

        let limit = 96
        if title.count > limit {
            title = String(title.prefix(limit - 1)) + "…"
        }
        return title
    }
}
