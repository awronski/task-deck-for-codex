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
    func groupingStaysProjectFirstAndPrioritizesAttentionInsideAProject() {
        let now = Date()
        let tasks = [
            task("inactive", project: "client", status: .inactive, date: now),
            task("working", project: "client", status: .working, date: now.addingTimeInterval(-1)),
            task("input", project: "client", status: .waitingForInput, date: now.addingTimeInterval(-2)),
            task("other", project: "server", status: .inactive, date: now.addingTimeInterval(-3))
        ]

        let sections = TaskGrouping.sections(from: tasks)
        #expect(sections.map(\.name) == ["client", "server"])
        #expect(sections[0].tasks.map(\.id) == ["input", "working", "inactive"])
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
    func automaticProjectOrderKeepsEveryNonInactiveStatusInTheRecentActivityGroup() {
        let now = Date()
        let sections = TaskGrouping.sections(from: [
            task("zebra-inactive", project: "zebra", status: .inactive, date: now),
            task("bravo-finished", project: "bravo", status: .finished, date: now.addingTimeInterval(-1)),
            task("alpha-working", project: "alpha", status: .working, date: now.addingTimeInterval(-2)),
            task("delta-waiting", project: "delta", status: .waitingForInput, date: now.addingTimeInterval(-3)),
            task("echo-permission", project: "echo", status: .waitingForPermission, date: now.addingTimeInterval(-4)),
            task("foxtrot-error", project: "foxtrot", status: .error, date: now.addingTimeInterval(-5)),
            task("charlie-inactive", project: "charlie", status: .inactive, date: now.addingTimeInterval(-6))
        ])

        let ordered = ProjectOrdering.sortingAutomatically(sections)

        #expect(ordered.map(\.name) == ["alpha", "bravo", "delta", "echo", "foxtrot", "charlie", "zebra"])
    }

    @Test
    func automaticProjectOrderPlacesActiveChatsAfterActiveProjects() {
        let now = Date()
        let sections = TaskGrouping.sections(from: [
            task("inactive", project: "client", status: .inactive, date: now),
            task("project-working", project: "server", status: .working, date: now.addingTimeInterval(-1)),
            task("chat-working", project: "Chats", status: .working, date: now.addingTimeInterval(-2), isChat: true)
        ])

        let ordered = ProjectOrdering.sortingAutomatically(sections)

        #expect(ordered.map(\.name) == ["server", "Chats", "client"])
    }

    @Test
    func automaticProjectOrderKeepsTaskOrderAndInactiveChatsLast() {
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

        let ordered = ProjectOrdering.sortingAutomatically(sections)

        #expect(ordered.map(\.name) == ["client", "Chats"])
        #expect(ordered[0].tasks.map(\.id) == ["working", "finished", "inactive"])
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
            updatedAt: date
        )
    }
}
