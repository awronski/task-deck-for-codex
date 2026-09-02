import Darwin
import CodexCompanionCore
import Foundation
import Testing

@Suite
struct CodexTaskRepositoryTests {
    @Test
    func missingDatabaseProducesAnActionableFailure() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCompanionTests")
            .appendingPathComponent(UUID().uuidString)
        let repository = CodexTaskRepository(codexHome: root, homeDirectory: "/Users/test")

        do {
            _ = try await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)
            Issue.record("Expected the missing database to fail")
        } catch let error as CodexRepositoryError {
            #expect(error == .databaseMissing(root.appendingPathComponent("state_5.sqlite").path))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func loadsWALDatabaseWhenSidecarFilesAreMissing() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "Checkpointed task",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])
        try fixture.convertDatabaseToWALWithoutSidecars()

        let snapshot = try await fixture.repository().loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(snapshot.tasks.map(\.id) == [taskID])
    }

    @Test
    func loadsTasksWhenOptionalModelMetadataColumnsAreMissing() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "Legacy schema task",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])

        let snapshot = try await fixture.repository().loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(snapshot.tasks.map(\.id) == [taskID])
        #expect(snapshot.tasks.first?.modelName == nil)
        #expect(snapshot.tasks.first?.thinkingEffort == nil)
    }

    @Test
    func refreshesOptionalMetadataWhenTheDatabaseSchemaChanges() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "Migrated schema task",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])
        let repository = fixture.repository()

        let legacySnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )
        #expect(legacySnapshot.tasks.first?.modelName == nil)
        #expect(legacySnapshot.tasks.first?.thinkingEffort == nil)

        try fixture.addModelMetadataColumns()
        try fixture.setModelMetadata(
            taskID: taskID,
            modelName: "gpt-5.6-sol",
            thinkingEffort: "high"
        )
        let migratedSnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(migratedSnapshot.tasks.first?.modelName == "gpt-5.6-sol")
        #expect(migratedSnapshot.tasks.first?.thinkingEffort == "high")
    }

    @Test
    func refreshesTheSchemaWhenNoTasksMatchDuringMigration() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [])
        let repository = fixture.repository()

        let legacySnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )
        #expect(legacySnapshot.tasks.isEmpty)

        try fixture.addModelMetadataColumns()
        let emptyMigratedSnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )
        #expect(emptyMigratedSnapshot.tasks.isEmpty)

        try fixture.insertDatabaseRow(
            .init(
                id: taskID,
                title: "Post-migration task",
                cwd: "/Users/test/code/project",
                rolloutPath: nil,
                modelName: "gpt-5.6-sol",
                thinkingEffort: "high"
            ),
            includesModelMetadataColumns: true
        )
        let populatedSnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(populatedSnapshot.tasks.first?.modelName == "gpt-5.6-sol")
        #expect(populatedSnapshot.tasks.first?.thinkingEffort == "high")
    }

    @Test
    func refreshesOptionalMetadataWhenTheDatabaseIsReplaced() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        let row = DatabaseRow(
            id: taskID,
            title: "Replaced database task",
            cwd: "/Users/test/code/project",
            rolloutPath: nil,
            modelName: "gpt-5.6-sol",
            thinkingEffort: "high"
        )
        try fixture.writeDatabase(rows: [row], includesModelMetadataColumns: true)
        let repository = fixture.repository()

        let currentSnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )
        #expect(currentSnapshot.tasks.first?.modelName == "gpt-5.6-sol")

        try fixture.replaceDatabase(rows: [
            .init(
                id: taskID,
                title: "Replaced database task",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])
        let replacementSnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(replacementSnapshot.tasks.map(\.id) == [taskID])
        #expect(replacementSnapshot.tasks.first?.modelName == nil)
        #expect(replacementSnapshot.tasks.first?.thinkingEffort == nil)

        try fixture.replaceDatabase(rows: [row], includesModelMetadataColumns: true)
        let restoredSnapshot = try await repository.loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(restoredSnapshot.tasks.first?.modelName == "gpt-5.6-sol")
        #expect(restoredSnapshot.tasks.first?.thinkingEffort == "high")
    }

    @Test
    func usesCodexCommandToArchiveAndRestoreTaskWithoutSharedAppServer() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "Archive me",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])
        let commandLog = fixture.root.appendingPathComponent("codex-command.log")
        let codexExecutable = try fixture.writeCodexExecutable(commandLog: commandLog)
        let repository = fixture.repository(codexExecutableURL: codexExecutable)

        #expect(try await repository.setArchived(true, taskID: taskID) == .completed)
        #expect(try String(contentsOf: commandLog, encoding: .utf8) == "\(fixture.root.path)\narchive\n\(taskID)\n")

        #expect(try await repository.setArchived(false, taskID: taskID) == .completed)
        #expect(try String(contentsOf: commandLog, encoding: .utf8) == "\(fixture.root.path)\nunarchive\n\(taskID)\n")
    }

    @Test
    func identifiesAnActiveWriterConflict() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let codexExecutable = try fixture.writeFailingArchiveExecutable(
            message: "Error: failed to archive session: thread \(taskID) already has an active writer"
        )
        let repository = fixture.repository(codexExecutableURL: codexExecutable)

        do {
            _ = try await repository.setArchived(true, taskID: taskID)
            Issue.record("Expected the owner conflict")
        } catch let error as CodexRepositoryError {
            #expect(error == .codexTaskHasActiveWriter)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func preservesGenericArchiveFailuresInsteadOfTreatingThemAsOwnerConflicts() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let message = "Error: failed to archive session"
        let codexExecutable = try fixture.writeFailingArchiveExecutable(message: message)
        let repository = fixture.repository(codexExecutableURL: codexExecutable)

        do {
            _ = try await repository.setArchived(true, taskID: taskID)
            Issue.record("Expected the archive failure")
        } catch let error as CodexRepositoryError {
            #expect(error == .codexCommandFailed(message))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func readsWhetherATaskStillNeedsArchiving() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "Archive state",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])
        let repository = fixture.repository()

        #expect(try await repository.isTaskUnarchived(taskID))

        try fixture.setDatabaseArchived(true, taskID: taskID)

        #expect(try await !repository.isTaskUnarchived(taskID))
    }

    @Test
    func usesSharedAppServerToArchiveAndRestoreTask() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let commandLog = fixture.root.appendingPathComponent("codex-command.log")
        let codexExecutable = try fixture.writeCodexExecutable(commandLog: commandLog)
        let socket = try fixture.createAppServerControlSocket()
        defer { Darwin.close(socket.descriptor) }
        let repository = fixture.repository(codexExecutableURL: codexExecutable)

        #expect(try await repository.setArchived(true, taskID: taskID) == .completed)
        #expect(
            try String(contentsOf: commandLog, encoding: .utf8) == """
            \(fixture.root.path)
            archive
            --remote
            unix://\(socket.url.path)
            \(taskID)

            """
        )

        #expect(try await repository.setArchived(false, taskID: taskID) == .completed)
        #expect(
            try String(contentsOf: commandLog, encoding: .utf8) == """
            \(fixture.root.path)
            unarchive
            --remote
            unix://\(socket.url.path)
            \(taskID)

            """
        )
    }

    @Test
    func staleAppServerSocketFallsBackToDirectArchiveCommand() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let commandLog = fixture.root.appendingPathComponent("codex-command.log")
        let codexExecutable = try fixture.writeCodexExecutable(commandLog: commandLog)
        let socket = try fixture.createAppServerControlSocket(isListening: false)
        Darwin.close(socket.descriptor)
        let repository = fixture.repository(codexExecutableURL: codexExecutable)

        #expect(try await repository.setArchived(true, taskID: taskID) == .completed)

        #expect(
            try String(contentsOf: commandLog, encoding: .utf8)
                == "\(fixture.root.path)\narchive\n\(taskID)\n"
        )
    }

    @Test
    func archiveCommandTimesOutInsteadOfHanging() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let codexExecutable = try fixture.writeUnresponsiveArchiveExecutable()
        let repository = fixture.repository(
            codexExecutableURL: codexExecutable,
            archiveUpdateTimeout: 0.1
        )

        do {
            _ = try await repository.setArchived(true, taskID: taskID)
            Issue.record("Expected the archive command to time out")
        } catch let error as CodexRepositoryError {
            #expect(error == .codexCommandFailed("Codex command timed out while updating the task."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func usesCodexAppServerToRenameTask() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let requestLog = fixture.root.appendingPathComponent("codex-app-server.log")
        let codexExecutable = try fixture.writeCodexAppServerExecutable(requestLog: requestLog)
        let repository = fixture.repository(codexExecutableURL: codexExecutable)

        try await repository.setTitle("Ready \"now\"", taskID: taskID)

        let lines = try String(contentsOf: requestLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(Array(lines.prefix(4)) == [
            fixture.root.path,
            "app-server",
            "--listen",
            "stdio://"
        ])

        try #require(lines.count >= 7)
        let initialize = try #require(lines[4].data(using: .utf8))
        let initialized = try #require(lines[5].data(using: .utf8))
        let rename = try #require(lines[6].data(using: .utf8))
        let initializeObject = try #require(
            JSONSerialization.jsonObject(with: initialize) as? [String: Any]
        )
        let initializedObject = try #require(
            JSONSerialization.jsonObject(with: initialized) as? [String: Any]
        )
        let renameObject = try #require(
            JSONSerialization.jsonObject(with: rename) as? [String: Any]
        )

        #expect(initializeObject["method"] as? String == "initialize")
        #expect(initializedObject["method"] as? String == "initialized")
        #expect(renameObject["method"] as? String == "thread/name/set")
        let params = try #require(renameObject["params"] as? [String: String])
        #expect(params == ["threadId": taskID, "name": "Ready \"now\""])
    }

    @Test
    func unresponsiveCodexAppServerTimesOutWithoutBlockingTaskLoading() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "Rename me",
                cwd: "/Users/test/code/project",
                rolloutPath: nil
            )
        ])
        let startedMarker = fixture.root.appendingPathComponent("codex-app-server-started")
        let codexExecutable = try fixture.writeUnresponsiveCodexAppServerExecutable(
            startedMarker: startedMarker
        )
        let repository = fixture.repository(
            codexExecutableURL: codexExecutable,
            titleUpdateTimeout: 2
        )

        let rename = Task {
            try await repository.setTitle("New title", taskID: taskID)
        }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: startedMarker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: startedMarker.path))

        let snapshotLoadedPromptly = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)) != nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(400))
                return false
            }
            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
        #expect(snapshotLoadedPromptly)

        do {
            try await rename.value
            Issue.record("Expected the unresponsive Codex app server to time out")
        } catch let error as CodexRepositoryError {
            #expect(
                error == .codexTitleUpdateFailed(
                    "Codex app server timed out while renaming the task."
                )
            )
        }
    }

    @Test
    func loadsCatalogTasksAndClassifiesTaskKinds() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let regularID = UUID().uuidString
        let delegatedID = UUID().uuidString
        let automationID = UUID().uuidString
        let unassignedID = UUID().uuidString
        let agentID = UUID().uuidString
        let batchID = UUID().uuidString
        let automationFinishedAt = Date(timeIntervalSince1970: 1_784_715_636.379)
        let regularRollout = try fixture.writeRollout(
            taskID: regularID,
            lines: [
                event("session_meta", ["source": "vscode", "thread_source": "user"]),
                event("event_msg", ["type": "task_started", "started_at": 1_784_648_776]),
                event("event_msg", [
                    "type": "agent_message",
                    "phase": "commentary",
                    "message": "Reviewing the project structure."
                ])
            ]
        )
        let automationRollout = try fixture.writeRollout(
            taskID: automationID,
            lines: [
                event("session_meta", ["source": "vscode", "thread_source": "automation"]),
                event(
                    "event_msg",
                    [
                        "type": "task_complete",
                        "started_at": 1_784_648_776,
                        "completed_at": 1_784_715_636,
                        "last_agent_message": "Automation finished successfully."
                    ],
                    timestamp: "2026-07-22T10:20:36.379Z"
                )
            ]
        )
        let delegatedRollout = try fixture.writeRollout(
            taskID: delegatedID,
            lines: [
                event("session_meta", ["source": "vscode", "thread_source": "subagent"]),
                event("event_msg", ["type": "task_started"])
            ]
        )
        let agentRollout = try fixture.writeRollout(
            taskID: agentID,
            lines: [
                event("session_meta", [
                    "source": ["subagent": ["thread_spawn": ["parent_thread_id": regularID]]],
                    "thread_source": "subagent"
                ]),
                event("event_msg", ["type": "task_started"])
            ]
        )
        let batchRollout = try fixture.writeRollout(
            taskID: batchID,
            lines: [
                event("session_meta", ["source": "exec", "originator": "codex_exec"]),
                event("event_msg", ["type": "task_started"])
            ]
        )

        try fixture.writeCatalog(
            projects: [
                (id: "one", name: "Project One", path: "/Users/test/code/one"),
                (id: "two", name: "Project Two", path: "/Users/test/code/two")
            ],
            assignments: [
                regularID: "one",
                delegatedID: "one",
                automationID: "one",
                agentID: "one",
                batchID: "one"
            ],
            projectlessTaskIDs: [unassignedID]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: regularID,
                title: "Regular task",
                cwd: "/Users/test/code/one",
                rolloutPath: regularRollout.path,
                modelName: "gpt-5.6-sol",
                thinkingEffort: "high"
            ),
            .init(
                id: automationID,
                title: "Automation task",
                cwd: "/Users/test/code/one",
                rolloutPath: automationRollout.path,
                threadSource: "automation"
            ),
            .init(
                id: delegatedID,
                title: "Task created by another task",
                cwd: "/Users/test/code/one",
                rolloutPath: delegatedRollout.path,
                threadSource: "subagent"
            ),
            .init(id: unassignedID, title: "Legacy task", cwd: "/Users/test/code/one", rolloutPath: nil),
            .init(id: agentID, title: "Internal agent", cwd: "/Users/test/code/one", rolloutPath: agentRollout.path),
            .init(id: batchID, title: "Batch task", cwd: "/Users/test/code/one", rolloutPath: batchRollout.path, source: "exec")
        ], includesModelMetadataColumns: true)

        let repository = fixture.repository()
        let defaultSnapshot = try await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)

        #expect(defaultSnapshot.tasks.map(\.id) == [regularID, automationID, delegatedID])
        #expect(defaultSnapshot.tasks.map(\.kind) == [.regular, .automation, .delegated])
        #expect(defaultSnapshot.tasks.map(\.status) == [.working, .finished, .working])
        #expect(defaultSnapshot.tasks.first?.modelName == "gpt-5.6-sol")
        #expect(defaultSnapshot.tasks.first?.thinkingEffort == "high")
        #expect(defaultSnapshot.tasks.last?.modelName == nil)
        #expect(defaultSnapshot.tasks.last?.thinkingEffort == nil)
        #expect(defaultSnapshot.tasks.first?.workingSince == Date(timeIntervalSince1970: 1_784_648_776))
        #expect(defaultSnapshot.tasks.first?.activity?.headline == "Reviewing the project structure.")
        let automationTask = defaultSnapshot.tasks.first { $0.id == automationID }
        #expect(automationTask?.finishedAt == automationFinishedAt)
        #expect(automationTask?.activity?.headline == "Automation finished successfully.")
        #expect(defaultSnapshot.projects.map(\.name) == ["Project One", "Project Two", "Chats"])
        #expect(defaultSnapshot.projects.last?.isChat == true)

        let completeSnapshot = try await repository.loadSnapshot(including: Set(CodexTaskKind.allCases))
        let kindsByID = Dictionary(uniqueKeysWithValues: completeSnapshot.tasks.map { ($0.id, $0.kind) })
        #expect(kindsByID[regularID] == .regular)
        #expect(kindsByID[delegatedID] == .delegated)
        #expect(kindsByID[automationID] == .automation)
        #expect(kindsByID[unassignedID] == .unassigned)
        #expect(kindsByID[agentID] == .agent)
        #expect(kindsByID[batchID] == .batch)
        #expect(completeSnapshot.tasks.first(where: { $0.id == unassignedID })?.projectKey == "unassigned")

        let agentOnly = try await repository.loadSnapshot(including: [.agent])
        #expect(agentOnly.tasks.map(\.id) == [agentID])
        let delegatedOnly = try await repository.loadSnapshot(including: [.delegated])
        #expect(delegatedOnly.tasks.map(\.id) == [delegatedID])
        let batchOnly = try await repository.loadSnapshot(including: [.batch])
        #expect(batchOnly.tasks.map(\.id) == [batchID])
    }

    @Test
    func guardianSubagentsRemainBehindTheAgentsFilter() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let guardianID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "one", name: "Project One", path: "/Users/test/code/one")],
            assignments: [guardianID: "one"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: guardianID,
                title: "Internal guardian",
                cwd: "/Users/test/code/one",
                rolloutPath: nil,
                source: #"{"subagent":{"other":"guardian"}}"#,
                threadSource: "subagent"
            )
        ])

        let repository = fixture.repository()
        let defaultSnapshot = try await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)
        let agentSnapshot = try await repository.loadSnapshot(including: [.agent])

        #expect(defaultSnapshot.tasks.isEmpty)
        #expect(agentSnapshot.tasks.map(\.id) == [guardianID])
        #expect(agentSnapshot.tasks.first?.kind == .agent)
    }

    @Test
    func usesCodexSessionIndexTitleInsteadOfRawDatabaseTitle() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "cli", name: "cli", path: "/Users/test/code/cli")],
            assignments: [taskID: "cli"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "<codex_delegation><source_thread_id>parent</source_thread_id>",
                cwd: "/Users/test/code/cli",
                rolloutPath: nil
            )
        ])
        try fixture.writeSessionIndex(entries: [
            (id: taskID, title: "Trace check-aniadb-replica SSH job")
        ])

        let snapshot = try await fixture.repository().loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(snapshot.tasks.first?.title == "Trace check-aniadb-replica SSH job")
    }

    @Test
    func loadsAutomationNamedOnlyInSessionIndexAndSkipsUnnamedTask() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let automationID = UUID().uuidString
        let unnamedID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "cli", name: "cli", path: "/Users/test/code/cli")],
            assignments: [automationID: "cli", unnamedID: "cli"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: automationID,
                title: "",
                cwd: "/Users/test/code/cli",
                rolloutPath: nil,
                threadSource: "automation"
            ),
            .init(
                id: unnamedID,
                title: "",
                cwd: "/Users/test/code/cli",
                rolloutPath: nil,
                threadSource: "automation"
            )
        ])
        try fixture.writeSessionIndex(entries: [
            (id: automationID, title: "Weekly AdSense earnings diagnostic")
        ])

        let snapshot = try await fixture.repository().loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(snapshot.tasks.map(\.id) == [automationID])
        #expect(snapshot.tasks.first?.title == "Weekly AdSense earnings diagnostic")
        #expect(snapshot.tasks.first?.kind == .automation)
    }

    @Test
    func blankTitlesFallBackToTheNextMeaningfulSource() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let blankIndexID = UUID().uuidString
        let whitespaceDatabaseID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "cli", name: "cli", path: "/Users/test/code/cli")],
            assignments: [blankIndexID: "cli", whitespaceDatabaseID: "cli"]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: blankIndexID,
                title: "Database title",
                cwd: "/Users/test/code/cli",
                rolloutPath: nil
            ),
            .init(
                id: whitespaceDatabaseID,
                title: "   ",
                cwd: "/Users/test/code/cli",
                rolloutPath: nil
            )
        ])
        try fixture.setDatabaseFallbackTitle(
            "First user message",
            taskID: whitespaceDatabaseID
        )
        try fixture.writeSessionIndex(entries: [
            (id: blankIndexID, title: "  \n ")
        ])

        let snapshot = try await fixture.repository().loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )
        let titlesByID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0.title) })

        #expect(titlesByID[blankIndexID] == "Database title")
        #expect(titlesByID[whitespaceDatabaseID] == "First user message")
    }

    @Test
    func loadsRegularTaskFromItsCatalogWorkspaceWithoutAnExplicitAssignment() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        try fixture.writeCatalog(
            projects: [(id: "client", name: "client", path: "/Users/test/code/client")],
            assignments: [:]
        )
        try fixture.writeDatabase(rows: [
            .init(
                id: taskID,
                title: "TypeScript adoption",
                cwd: "/Users/test/code/client",
                rolloutPath: nil
            )
        ])

        let snapshot = try await fixture.repository().loadSnapshot(
            including: CodexTaskKind.defaultVisible
        )

        #expect(snapshot.tasks.map(\.id) == [taskID])
        #expect(snapshot.tasks.first?.projectName == "client")
        #expect(snapshot.tasks.first?.kind == .regular)
    }

    @Test
    func largeOldRolloutRestoresWaitingStateThenConsumesOnlyCompletedAppend() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let taskID = UUID().uuidString
        let output = event("response_item", [
            "type": "function_call_output",
            "call_id": "input-1"
        ])
        let outputSplit = output.index(output.startIndex, offsetBy: output.count / 2)
        let originalLines = [
            event("session_meta", ["source": "vscode", "thread_source": "user"]),
            event("event_msg", ["type": "task_started"]),
            event("response_item", [
                "type": "message",
                "text": String(repeating: "x", count: 70_000)
            ]),
            event("response_item", [
                "type": "function_call",
                "name": "request_user_input",
                "call_id": "input-1"
            ])
        ]
        let partialOutput = String(output[..<outputSplit])
        let rollout = try fixture.writeRollout(
            taskID: taskID,
            rawContents: originalLines.joined(separator: "\n") + "\n" + partialOutput
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -72 * 60 * 60)],
            ofItemAtPath: rollout.path
        )
        try fixture.writeCatalog(
            projects: [(id: "project", name: "Project", path: "/Users/test/code/project")],
            assignments: [taskID: "project"]
        )
        try fixture.writeDatabase(rows: [
            .init(id: taskID, title: "Old waiting task", cwd: "/Users/test/code/project", rolloutPath: rollout.path)
        ])

        let repository = fixture.repository()
        let initial = try await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)
        #expect(initial.tasks.first?.status == .waitingForInput)

        var rewritten = try String(contentsOf: rollout, encoding: .utf8)
        rewritten = rewritten.replacingOccurrences(of: "task_started", with: "task_ignored")
        #expect(rewritten.utf8.count == (try Data(contentsOf: rollout)).count)
        try Data(rewritten.utf8).write(to: rollout)

        let completedOutput = String(output[outputSplit...]) + "\n"
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completedOutput.utf8))
        try handle.close()

        let afterAppend = try await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)
        #expect(afterAppend.tasks.first?.status == .working)
    }
}

private struct DatabaseRow {
    let id: String
    let title: String
    let cwd: String
    let rolloutPath: String?
    let source: String
    let threadSource: String
    let modelName: String?
    let thinkingEffort: String?

    init(
        id: String,
        title: String,
        cwd: String,
        rolloutPath: String?,
        source: String = "vscode",
        threadSource: String = "user",
        modelName: String? = nil,
        thinkingEffort: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.rolloutPath = rolloutPath
        self.source = source
        self.threadSource = threadSource
        self.modelName = modelName
        self.thinkingEffort = thinkingEffort
    }
}

private struct RepositoryFixture {
    let root: URL
    let sessions: URL

    init() throws {
        root = URL(
            fileURLWithPath: "/tmp/td-\(UUID().uuidString)",
            isDirectory: true
        )
        sessions = root.appendingPathComponent("sessions/2026/07/22", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    func repository(
        codexExecutableURL: URL? = nil,
        titleUpdateTimeout: TimeInterval = 5,
        archiveUpdateTimeout: TimeInterval = 5
    ) -> CodexTaskRepository {
        CodexTaskRepository(
            codexHome: root,
            homeDirectory: "/Users/test",
            codexExecutableURL: codexExecutableURL,
            titleUpdateTimeout: titleUpdateTimeout,
            archiveUpdateTimeout: archiveUpdateTimeout
        )
    }

    func writeCodexExecutable(commandLog: URL) throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let escapedLogPath = commandLog.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$CODEX_HOME" "$@" > '\(escapedLogPath)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func writeUnresponsiveArchiveExecutable() throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        exec /bin/sleep 60
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func writeFailingArchiveExecutable(message: String) throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let escapedMessage = message.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s\n' '\(escapedMessage)' >&2
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func createAppServerControlSocket(
        isListening: Bool = true
    ) throws -> (url: URL, descriptor: Int32) {
        let directory = root.appendingPathComponent("app-server-control", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketURL = directory.appendingPathComponent("app-server-control.sock")
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixtureError.socket(errno) }

        let pathBytes = Array(socketURL.path.utf8CString)
        var address = sockaddr_un()
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 0
        let addressLength = pathOffset + pathBytes.count
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              addressLength <= Int(UInt8.max)
        else {
            Darwin.close(descriptor)
            throw FixtureError.socketPathTooLong
        }

        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(addressLength))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw FixtureError.socket(errno)
        }
        if isListening {
            guard Darwin.listen(descriptor, 8) == 0 else {
                Darwin.close(descriptor)
                throw FixtureError.socket(errno)
            }
        }
        return (socketURL, descriptor)
    }

    func writeCodexAppServerExecutable(requestLog: URL) throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let escapedLogPath = requestLog.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        IFS= read -r initialize_request
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized_notification
        IFS= read -r rename_request
        printf '%s\n' "$CODEX_HOME" "$@" "$initialize_request" "$initialized_notification" "$rename_request" > '\(escapedLogPath)'
        printf '%s\n' '{"id":2,"result":{}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func writeUnresponsiveCodexAppServerExecutable(startedMarker: URL) throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let escapedMarkerPath = startedMarker.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        IFS= read -r initialize_request
        printf 'started\n' > '\(escapedMarkerPath)'
        IFS= read -r never_sent
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeRollout(taskID: String, lines: [String]) throws -> URL {
        try writeRollout(taskID: taskID, rawContents: lines.joined(separator: "\n") + "\n")
    }

    func writeRollout(taskID: String, rawContents: String) throws -> URL {
        let url = sessions.appendingPathComponent("rollout-\(taskID).jsonl")
        try Data(rawContents.utf8).write(to: url)
        return url
    }

    func writeCatalog(
        projects: [(id: String, name: String, path: String)],
        assignments: [String: String],
        projectlessTaskIDs: [String] = []
    ) throws {
        let projectValues = Dictionary(uniqueKeysWithValues: projects.map { project in
            (project.id, [
                "id": project.id,
                "name": project.name,
                "rootPaths": [project.path]
            ] as [String: Any])
        })
        let assignmentValues = assignments.mapValues { ["projectId": $0] }
        let data = try JSONSerialization.data(withJSONObject: [
            "local-projects": projectValues,
            "thread-project-assignments": assignmentValues,
            "projectless-thread-ids": projectlessTaskIDs
        ])
        try data.write(to: root.appendingPathComponent(".codex-global-state.json"))
    }

    func writeDatabase(
        rows: [DatabaseRow],
        includesModelMetadataColumns: Bool = false
    ) throws {
        let metadataColumnDefinitions = includesModelMetadataColumns
            ? "model TEXT,\n                reasoning_effort TEXT,\n                "
            : ""
        var statements = [
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                first_user_message TEXT,
                preview TEXT,
                cwd TEXT,
                rollout_path TEXT,
                source TEXT,
                thread_source TEXT,
                agent_role TEXT,
                agent_nickname TEXT,
                agent_path TEXT,
                \(metadataColumnDefinitions)created_at_ms INTEGER,
                created_at INTEGER,
                recency_at_ms INTEGER,
                updated_at INTEGER,
                archived INTEGER,
                archived_at INTEGER
            )
            """,
            "CREATE TABLE thread_spawn_edges (child_thread_id TEXT, parent_thread_id TEXT)"
        ]
        statements += rows.enumerated().map { index, row in
            let rollout = row.rolloutPath.map { "'\(sql($0))'" } ?? "NULL"
            let modelName = row.modelName.map { "'\(sql($0))'" } ?? "NULL"
            let thinkingEffort = row.thinkingEffort.map { "'\(sql($0))'" } ?? "NULL"
            let metadataValues = includesModelMetadataColumns
                ? "\(modelName), \(thinkingEffort), "
                : ""
            return """
            INSERT INTO threads VALUES (
                '\(sql(row.id))', '\(sql(row.title))', '', '', '\(sql(row.cwd))', \(rollout),
                '\(sql(row.source))', '\(sql(row.threadSource))', '', '', '',
                \(metadataValues)\(1_700_000_000_000 + index), 0, \(1_800_000_000_000 - index), 0, 0, NULL
            )
            """
        }

        try executeSQL(statements.joined(separator: ";"))
    }

    func writeSessionIndex(entries: [(id: String, title: String)]) throws {
        let lines = try entries.map { entry in
            let data = try JSONSerialization.data(withJSONObject: [
                "id": entry.id,
                "thread_name": entry.title
            ])
            return String(decoding: data, as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))
    }

    func addModelMetadataColumns() throws {
        try executeSQL(
            """
            ALTER TABLE threads ADD COLUMN model TEXT;
            ALTER TABLE threads ADD COLUMN reasoning_effort TEXT
            """
        )
    }

    func setModelMetadata(
        taskID: String,
        modelName: String,
        thinkingEffort: String
    ) throws {
        try executeSQL(
            """
            UPDATE threads
            SET model = '\(sql(modelName))', reasoning_effort = '\(sql(thinkingEffort))'
            WHERE id = '\(sql(taskID))'
            """
        )
    }

    func setDatabaseArchived(_ archived: Bool, taskID: String) throws {
        try executeSQL(
            "UPDATE threads SET archived = \(archived ? 1 : 0) WHERE id = '\(sql(taskID))'"
        )
    }

    func setDatabaseFallbackTitle(_ title: String, taskID: String) throws {
        try executeSQL(
            "UPDATE threads SET first_user_message = '\(sql(title))' WHERE id = '\(sql(taskID))'"
        )
    }

    func insertDatabaseRow(
        _ row: DatabaseRow,
        includesModelMetadataColumns: Bool = false
    ) throws {
        let rollout = row.rolloutPath.map { "'\(sql($0))'" } ?? "NULL"
        let modelName = row.modelName.map { "'\(sql($0))'" } ?? "NULL"
        let thinkingEffort = row.thinkingEffort.map { "'\(sql($0))'" } ?? "NULL"
        let metadataValues = includesModelMetadataColumns
            ? "\(modelName), \(thinkingEffort), "
            : ""
        let metadataColumns = includesModelMetadataColumns
            ? "model, reasoning_effort, "
            : ""
        try executeSQL(
            """
            INSERT INTO threads (
                id, title, first_user_message, preview, cwd, rollout_path,
                source, thread_source, agent_role, agent_nickname, agent_path,
                \(metadataColumns)created_at_ms, created_at, recency_at_ms, updated_at,
                archived, archived_at
            ) VALUES (
                '\(sql(row.id))', '\(sql(row.title))', '', '', '\(sql(row.cwd))', \(rollout),
                '\(sql(row.source))', '\(sql(row.threadSource))', '', '', '',
                \(metadataValues)1700000000000, 0, 1800000000000, 0, 0, NULL
            )
            """
        )
    }

    func replaceDatabase(
        rows: [DatabaseRow],
        includesModelMetadataColumns: Bool = false
    ) throws {
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("state_5.sqlite")
        )
        try writeDatabase(
            rows: rows,
            includesModelMetadataColumns: includesModelMetadataColumns
        )
    }

    func convertDatabaseToWALWithoutSidecars() throws {
        try executeSQL("PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE)")

        let databasePath = root.appendingPathComponent("state_5.sqlite").path
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databasePath + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    private func executeSQL(_ sql: String) throws {
        let database = root.appendingPathComponent("state_5.sqlite")
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw FixtureError.sqlite(message)
        }
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private enum FixtureError: Error {
    case sqlite(String)
    case socket(Int32)
    case socketPathTooLong
}

private func event(_ type: String, _ payload: [String: Any], timestamp: String? = nil) -> String {
    var envelope: [String: Any] = ["type": type, "payload": payload]
    if let timestamp {
        envelope["timestamp"] = timestamp
    }
    let data = try! JSONSerialization.data(withJSONObject: envelope)
    return String(decoding: data, as: UTF8.self)
}
