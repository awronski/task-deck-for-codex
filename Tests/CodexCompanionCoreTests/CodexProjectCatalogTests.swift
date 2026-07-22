@testable import CodexCompanionCore
import Foundation
import Testing

@Suite
struct CodexProjectCatalogTests {
    @Test
    func explicitAssignmentsAndWorkspacePathsResolveCurrentCodexProjects() {
        let catalog = CodexProjectCatalog(
            projects: [
                .init(id: "workspace", name: "workspace", rootPaths: ["/Users/test/code"]),
                .init(id: "current", name: "client", rootPaths: ["/Users/test/code/client"])
            ],
            taskProjectIDs: ["current-task": "current"]
        )

        let current = catalog.resolve(
            taskID: "current-task",
            path: "/Users/test/code/client",
            homeDirectory: "/Users/test"
        )
        let pathMatched = catalog.resolve(
            taskID: "path-matched-task",
            path: "/Users/test/code/client/Sources",
            homeDirectory: "/Users/test"
        )

        #expect(current?.name == "client")
        #expect(current?.key == "project:current")
        #expect(pathMatched?.name == "client")
        #expect(pathMatched?.key == "project:current")
    }

    @Test
    func staleExplicitAssignmentDoesNotFallBackToAnotherProject() {
        let catalog = CodexProjectCatalog(
            projects: [
                .init(id: "current", name: "client", rootPaths: ["/Users/test/code/client"])
            ],
            taskProjectIDs: ["task": "removed"]
        )

        let project = catalog.resolve(
            taskID: "task",
            path: "/Users/test/code/client",
            homeDirectory: "/Users/test"
        )

        #expect(project == nil)
    }

    @Test
    func explicitlyProjectlessTasksAreSkippedEvenWhenTheirPathMatchesAProject() {
        let catalog = CodexProjectCatalog(
            projects: [
                .init(id: "client", name: "client", rootPaths: ["/Users/test/code/client"])
            ],
            projectlessTaskIDs: ["task"]
        )

        let project = catalog.resolve(
            taskID: "task",
            path: "/Users/test/code/client/Sources",
            homeDirectory: "/Users/test"
        )

        #expect(project == nil)
    }

    @Test
    func chatsRemainAvailableOutsideTheProjectCatalog() {
        let catalog = CodexProjectCatalog(projects: [])

        let project = catalog.resolve(
            taskID: "chat",
            path: "/Users/test/Documents/Codex/2026-07-21/abc",
            homeDirectory: "/Users/test"
        )

        #expect(project?.name == "Chats")
        #expect(project?.isChat == true)
    }

    @Test
    func persistedCatalogUsesCodexProjectNamesAndAssignments() throws {
        let data = Data(
            #"{"local-projects":{"project-id":{"id":"project-id","name":"backend","rootPaths":["/Users/test/code/server"]}},"thread-project-assignments":{"task-id":{"projectId":"project-id"}}}"#.utf8
        )
        let catalog = try CodexProjectCatalog(data: data)

        let project = catalog.resolve(
            taskID: "task-id",
            path: "/Users/test/code/server",
            homeDirectory: "/Users/test"
        )

        #expect(project?.name == "backend")
        #expect(project?.key == "project:project-id")
    }

    @Test
    func persistedCatalogIgnoresRelativeRoots() throws {
        let data = Data(
            #"{"local-projects":{"project-id":{"id":"project-id","name":"backend","rootPaths":["relative/path"]}}}"#.utf8
        )
        let catalog = try CodexProjectCatalog(data: data)

        #expect(catalog.identities(homeDirectory: "/Users/test").map(\.name) == ["Chats"])
    }

    @Test
    func persistedCatalogFallsBackToWorkspaceUnlessTaskIsExplicitlyProjectless() throws {
        let data = Data(
            #"{"local-projects":{"project-id":{"id":"project-id","name":"client","rootPaths":["/Users/test/code/client"]}},"thread-project-assignments":{},"projectless-thread-ids":["projectless-task"]}"#.utf8
        )
        let catalog = try CodexProjectCatalog(data: data)

        let matched = catalog.resolve(
            taskID: "workspace-task",
            path: "/Users/test/code/client",
            homeDirectory: "/Users/test"
        )
        let projectless = catalog.resolve(
            taskID: "projectless-task",
            path: "/Users/test/code/client",
            homeDirectory: "/Users/test"
        )

        #expect(matched?.name == "client")
        #expect(projectless == nil)
    }
}
