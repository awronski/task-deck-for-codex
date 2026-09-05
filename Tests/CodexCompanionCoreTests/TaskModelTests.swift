import CodexCompanionCore
import Foundation
import Testing

@Suite
struct TaskModelTests {
    @Test
    func tasksCreatedByOtherTasksAreVisibleByDefault() {
        #expect(CodexTaskKind.defaultVisible == [.regular, .delegated, .automation])
    }

    @Test
    func tasksDefaultToNoFlag() {
        #expect(task("task", project: "project", status: .inactive, date: .now).priority == .none)
    }

    @Test
    func flagLabelsDescribeTheWorkflowState() {
        #expect(TaskPriority.green.title == "Ready")
        #expect(TaskPriority.blue.title == "Work in progress")
        #expect(TaskPriority.yellow.title == "Needs attention")
        #expect(TaskPriority.orange.title == "Important issue")
        #expect(TaskPriority.red.title == "Critical issue")
    }

    @Test
    func generatedCodexFoldersAreGroupedAsChats() {
        let project = ProjectResolver.resolve(
            path: "/Users/test/Documents/Codex/2026-07-21/abc",
            homeDirectory: "/Users/test"
        )

        #expect(project == ProjectIdentity(
            key: "chats",
            name: "Chats",
            path: "/Users/test/Documents/Codex",
            isChat: true
        ))
    }

    @Test
    func chatsWorkspaceRootIsGroupedAsChats() {
        let project = ProjectResolver.resolve(
            path: "/Users/test/Documents/Codex",
            homeDirectory: "/Users/test"
        )

        #expect(project == ProjectIdentity(
            key: "chats",
            name: "Chats",
            path: "/Users/test/Documents/Codex",
            isChat: true
        ))
    }

    @Test
    func relativeProjectPathsAreRejected() {
        #expect(ProjectResolver.resolve(path: "relative/path", homeDirectory: "/Users/test") == nil)
    }

    @Test
    func unrecognizedCodexFoldersAreSkippedAsProjectless() {
        let nested = ProjectResolver.resolve(
            path: "/Users/test/Documents/Codex/2026-07-21/abc/nested",
            homeDirectory: "/Users/test"
        )
        let malformed = ProjectResolver.resolve(
            path: "/Users/test/Documents/Codex/today/abc",
            homeDirectory: "/Users/test"
        )

        #expect(nested == nil)
        #expect(malformed == nil)
    }

    @Test
    func groupingOrdersTasksByCreationDateRegardlessOfAttentionStatus() {
        let now = Date()
        let tasks = [
            task(
                "old-error",
                project: "client",
                status: .error,
                date: now,
                createdAt: now.addingTimeInterval(-3)
            ),
            task(
                "new-inactive",
                project: "client",
                status: .inactive,
                date: now.addingTimeInterval(-3),
                createdAt: now
            ),
            task(
                "middle-working",
                project: "client",
                status: .working,
                date: now.addingTimeInterval(-1),
                createdAt: now.addingTimeInterval(-2)
            ),
            task("other", project: "server", status: .inactive, date: now.addingTimeInterval(-4))
        ]

        let sections = TaskGrouping.sections(from: tasks)
        #expect(sections.map(\.name) == ["client", "server"])
        #expect(sections[0].tasks.map(\.id) == ["new-inactive", "middle-working", "old-error"])
    }

    @Test
    func taskOrderDoesNotChangeWhenStatusAndUpdateDateChange() {
        let now = Date()
        let newerCreation = now.addingTimeInterval(-1)
        let olderCreation = now.addingTimeInterval(-2)
        let before = TaskGrouping.sections(from: [
            task("newer", project: "client", status: .working, date: now, createdAt: newerCreation),
            task("older", project: "client", status: .inactive, date: now.addingTimeInterval(-1), createdAt: olderCreation)
        ])
        let after = TaskGrouping.sections(from: [
            task("newer", project: "client", status: .inactive, date: now.addingTimeInterval(-2), createdAt: newerCreation),
            task("older", project: "client", status: .error, date: now.addingTimeInterval(1), createdAt: olderCreation)
        ])

        #expect(before[0].tasks.map(\.id) == ["newer", "older"])
        #expect(after[0].tasks.map(\.id) == ["newer", "older"])
    }

    @Test
    func projectStatusAndSearchFiltersUseOrWithinSectionsAndAndBetweenThem() {
        let now = Date()
        let tasks = [
            task("client-working", project: "client", status: .working, date: now),
            task("client-inactive", project: "client", status: .inactive, date: now),
            task("server-error", project: "server", status: .error, date: now),
            task("notes-working", project: "notes", status: .working, date: now)
        ]

        let sections = TaskGrouping.sections(
            from: tasks,
            matching: "client",
            projectIDs: ["/code/client", "/code/server"],
            statuses: [.working, .error]
        )

        #expect(sections.map(\.name) == ["client"])
        #expect(sections[0].tasks.map(\.id) == ["client-working"])
    }

    @Test
    func projectSearchMatchesDisplayNameAndOriginalName() {
        let task = task(
            "client-task",
            project: "client",
            status: .inactive,
            date: .now
        )
        let displayNames = [task.projectKey: "Command Line Tools"]

        #expect(TaskGrouping.sections(
            from: [task],
            matching: "command line",
            projectDisplayNames: displayNames
        ).map(\.id) == [task.projectKey])
        #expect(TaskGrouping.sections(
            from: [task],
            matching: "client",
            projectDisplayNames: displayNames
        ).map(\.id) == [task.projectKey])
    }

    @Test
    func explicitlyIncludedEmptyChatsProjectRemainsVisible() {
        let chats = ProjectIdentity(
            key: "chats",
            name: "Chats",
            path: "/Users/test/Documents/Codex",
            isChat: true
        )

        let sections = TaskGrouping.sections(from: [], includingEmptyProjects: [chats])

        #expect(sections == [
            ProjectSection(
                id: chats.key,
                name: chats.name,
                path: chats.path,
                isChat: true,
                tasks: []
            )
        ])
    }

    @Test
    func emptyProjectsStillRespectSearchAndStatusFilters() {
        let chats = ProjectIdentity(
            key: "chats",
            name: "Chats",
            path: "/Users/test/Documents/Codex",
            isChat: true
        )

        #expect(TaskGrouping.sections(
            from: [],
            includingEmptyProjects: [chats],
            matching: "server"
        ).isEmpty)
        #expect(TaskGrouping.sections(
            from: [],
            includingEmptyProjects: [chats],
            statuses: [.working]
        ).isEmpty)
    }

    @Test
    func customProjectOrderIsAppliedAndKeepsNewProjectsAtTheEnd() {
        let now = Date()
        let sections = TaskGrouping.sections(from: [
            task("client", project: "client", status: .inactive, date: now),
            task("server", project: "server", status: .inactive, date: now.addingTimeInterval(-1)),
            task("notes", project: "notes", status: .inactive, date: now.addingTimeInterval(-2))
        ])

        let ordered = ProjectOrdering.applying(
            ["/code/server", "/code/client"],
            to: sections
        )

        #expect(ordered.map(\.name) == ["server", "client", "notes"])
    }

    @Test
    func chatsStayLastEvenWhenTheSavedOrderPlacesThemFirst() {
        let sections = [
            ProjectSection(
                id: "chats",
                name: "Chats",
                path: "/Documents/Codex",
                isChat: true,
                tasks: []
            ),
            ProjectSection(
                id: "/code/client",
                name: "client",
                path: "/code/client",
                isChat: false,
                tasks: []
            )
        ]

        let ordered = ProjectOrdering.applying(
            ["chats", "/code/client"],
            to: sections
        )

        #expect(ordered.map(\.name) == ["client", "Chats"])
    }

    @Test
    func automaticProjectOrderUsesActiveStateThenMostRecentInteraction() {
        let now = Date()
        let tasks = [
            task("zebra-error", project: "zebra", status: .error, date: now.addingTimeInterval(-30)),
            task("alpha-inactive", project: "alpha", status: .inactive, date: now),
            task("bravo-working", project: "bravo", status: .working, date: now.addingTimeInterval(-20)),
            task("chat-working", project: "Chats", status: .working, date: now.addingTimeInterval(-10), isChat: true)
        ]
        var sections = TaskGrouping.sections(from: tasks)
        sections.append(ProjectSection(
            id: "/code/empty",
            name: "empty",
            path: "/code/empty",
            isChat: false,
            tasks: []
        ))

        let ordered = ProjectOrdering.sortingAutomatically(sections, using: tasks)

        #expect(ordered.map(\.name) == ["Chats", "bravo", "zebra", "alpha", "empty"])
    }

    @Test
    func automaticProjectOrderUsesAllSuppliedTasksForProjectActivity() {
        let now = Date()
        let visibleTasks = [
            task("alpha-visible", project: "alpha", status: .inactive, date: now.addingTimeInterval(-30)),
            task("bravo-visible", project: "bravo", status: .working, date: now.addingTimeInterval(-20))
        ]
        let tasksIncludingHiddenChild = visibleTasks + [
            task("alpha-filtered-out", project: "alpha", status: .error, date: now, createdAt: now)
        ]
        let sections = TaskGrouping.sections(from: visibleTasks)

        let visibleOrder = ProjectOrdering.sortingAutomatically(sections, using: visibleTasks)
        let orderIncludingHiddenChild = ProjectOrdering.sortingAutomatically(
            sections,
            using: tasksIncludingHiddenChild
        )

        #expect(visibleOrder.map(\.name) == ["bravo", "alpha"])
        #expect(orderIncludingHiddenChild.map(\.name) == ["alpha", "bravo"])
    }

    @Test
    func automaticProjectOrderKeepsActiveTasksFirstThenMostRecentlyUpdated() {
        let now = Date()
        let projectTasks = [
            task("inactive", project: "client", status: .inactive, date: now),
            task("finished", project: "client", status: .finished, date: now.addingTimeInterval(-1)),
            task("working", project: "client", status: .working, date: now.addingTimeInterval(-2))
        ]
        let sections = TaskGrouping.sections(
            from: projectTasks,
            includingEmptyProjects: [
                ProjectIdentity(
                    key: "chats",
                    name: "Chats",
                    path: "/Documents/Codex",
                    isChat: true
                )
            ]
        )

        let ordered = ProjectOrdering.sortingAutomatically(sections, using: projectTasks)

        #expect(ordered.map(\.name) == ["client", "Chats"])
        #expect(ordered[0].tasks.map(\.id) == ["working", "inactive", "finished"])
    }

    @Test
    func projectCanMoveBeforeOrAfterADropTarget() {
        let order = ["client", "server", "notes"]

        #expect(
            ProjectOrdering.moving(
                "notes",
                relativeTo: "client",
                insertAfter: false,
                in: order
            ) == ["notes", "client", "server"]
        )
        #expect(
            ProjectOrdering.moving(
                "client",
                relativeTo: "notes",
                insertAfter: true,
                in: order
            ) == ["server", "notes", "client"]
        )
    }

    @Test
    func titleCleaningRemovesGoalPrefixAndControlWhitespace() {
        let title = TaskText.cleanTitle("/goal  Build\n\tthe app\u{0000}", fallbackID: "12345678-rest")
        #expect(title == "Build the app")
    }

    @Test
    func titleCleaningPreservesLongTitlesForEditing() {
        let title = String(repeating: "Preserve the complete task title. ", count: 8)
            + "Keep this final sentence."

        #expect(TaskText.cleanTitle(title, fallbackID: "12345678-rest") == title)
    }

    @Test
    func workingTimerUsesCompactMinuteAndHourFormats() {
        let startedAt = Date(timeIntervalSince1970: 1_000)

        #expect(TaskTimer.compactElapsed(from: startedAt, to: startedAt.addingTimeInterval(65)) == "1:05")
        #expect(TaskTimer.compactElapsed(from: startedAt, to: startedAt.addingTimeInterval(3_661)) == "1:01:01")
    }

    @Test
    func taskAgeUsesReadableRelativeUnits() {
        let createdAt = Date(timeIntervalSince1970: 1_000)

        #expect(TaskAge.relativeDescription(from: createdAt, to: createdAt.addingTimeInterval(5)) == "5 seconds ago")
        #expect(TaskAge.relativeDescription(from: createdAt, to: createdAt.addingTimeInterval(600)) == "10 minutes ago")
        #expect(TaskAge.relativeDescription(from: createdAt, to: createdAt.addingTimeInterval(3_600)) == "1 hour ago")
        #expect(TaskAge.relativeDescription(from: createdAt, to: createdAt.addingTimeInterval(86_400)) == "1 day ago")
        #expect(TaskAge.relativeDescription(from: createdAt, to: createdAt.addingTimeInterval(25 * 86_400)) == "25 days ago")
        #expect(TaskAge.relativeDescription(from: createdAt, to: createdAt.addingTimeInterval(30 * 86_400)) == "1 month ago")
    }

    private func task(
        _ id: String,
        project: String,
        status: AttentionStatus,
        date: Date,
        createdAt: Date? = nil,
        isChat: Bool = false
    ) -> CodexTask {
        CodexTask(
            id: id,
            title: id,
            projectKey: isChat ? "chats" : "/code/\(project)",
            projectName: project,
            projectPath: isChat ? "/Users/test/Documents/Codex" : "/code/\(project)",
            isChat: isChat,
            status: status,
            updatedAt: date,
            createdAt: createdAt ?? date
        )
    }
}
