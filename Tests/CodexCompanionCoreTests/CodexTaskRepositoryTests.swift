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
    func usesCodexCommandToArchiveAndRestoreTask() async throws {
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

        try await repository.setArchived(true, taskID: taskID)
        #expect(try String(contentsOf: commandLog, encoding: .utf8) == "\(fixture.root.path)\narchive\n\(taskID)\n")

        try await repository.setArchived(false, taskID: taskID)
        #expect(try String(contentsOf: commandLog, encoding: .utf8) == "\(fixture.root.path)\nunarchive\n\(taskID)\n")
    }

    @Test
    func loadsCatalogTasksAndClassifiesTaskKinds() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }

        let regularID = UUID().uuidString
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
                automationID: "one",
                agentID: "one",
                batchID: "one"
            ],
            projectlessTaskIDs: [unassignedID]
        )
        try fixture.writeDatabase(rows: [
            .init(id: regularID, title: "Regular task", cwd: "/Users/test/code/one", rolloutPath: regularRollout.path),
            .init(
                id: automationID,
                title: "Automation task",
                cwd: "/Users/test/code/one",
                rolloutPath: automationRollout.path,
                threadSource: "automation"
            ),
            .init(id: unassignedID, title: "Legacy task", cwd: "/Users/test/code/one", rolloutPath: nil),
            .init(id: agentID, title: "Internal agent", cwd: "/Users/test/code/one", rolloutPath: agentRollout.path),
            .init(id: batchID, title: "Batch task", cwd: "/Users/test/code/one", rolloutPath: batchRollout.path, source: "exec")
        ])

        let repository = fixture.repository()
        let defaultSnapshot = try await repository.loadSnapshot(including: CodexTaskKind.defaultVisible)

        #expect(defaultSnapshot.tasks.map(\.id) == [regularID, automationID])
        #expect(defaultSnapshot.tasks.map(\.kind) == [.regular, .automation])
        #expect(defaultSnapshot.tasks.map(\.status) == [.working, .finished])
        #expect(defaultSnapshot.tasks.first?.workingSince == Date(timeIntervalSince1970: 1_784_648_776))
        #expect(defaultSnapshot.tasks.first?.activity?.headline == "Reviewing the project structure.")
        #expect(defaultSnapshot.tasks.last?.finishedAt == automationFinishedAt)
        #expect(defaultSnapshot.tasks.last?.activity?.headline == "Automation finished successfully.")
        #expect(defaultSnapshot.projects.map(\.name) == ["Project One", "Project Two", "Chats"])
        #expect(defaultSnapshot.projects.last?.isChat == true)

        let completeSnapshot = try await repository.loadSnapshot(including: Set(CodexTaskKind.allCases))
        let kindsByID = Dictionary(uniqueKeysWithValues: completeSnapshot.tasks.map { ($0.id, $0.kind) })
        #expect(kindsByID[regularID] == .regular)
        #expect(kindsByID[automationID] == .automation)
        #expect(kindsByID[unassignedID] == .unassigned)
        #expect(kindsByID[agentID] == .agent)
        #expect(kindsByID[batchID] == .batch)
        #expect(completeSnapshot.tasks.first(where: { $0.id == unassignedID })?.projectKey == "unassigned")

        let agentOnly = try await repository.loadSnapshot(including: [.agent])
        #expect(agentOnly.tasks.map(\.id) == [agentID])
        let batchOnly = try await repository.loadSnapshot(including: [.batch])
        #expect(batchOnly.tasks.map(\.id) == [batchID])
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

    init(
        id: String,
        title: String,
        cwd: String,
        rolloutPath: String?,
        source: String = "vscode",
        threadSource: String = "user"
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.rolloutPath = rolloutPath
        self.source = source
        self.threadSource = threadSource
    }
}

private struct RepositoryFixture {
    let root: URL
    let sessions: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCompanionRepositoryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sessions = root.appendingPathComponent("sessions/2026/07/22", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    func repository(codexExecutableURL: URL? = nil) -> CodexTaskRepository {
        CodexTaskRepository(
            codexHome: root,
            homeDirectory: "/Users/test",
            codexExecutableURL: codexExecutableURL
        )
    }

    func writeCodexExecutable(commandLog: URL) throws -> URL {
        let executable = root.appendingPathComponent("codex")
        let escapedLogPath = commandLog.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s\\n%s\\n%s\\n' "$CODEX_HOME" "$1" "$2" > '\(escapedLogPath)'
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

    func writeDatabase(rows: [DatabaseRow]) throws {
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
                created_at_ms INTEGER,
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
            return """
            INSERT INTO threads VALUES (
                '\(sql(row.id))', '\(sql(row.title))', '', '', '\(sql(row.cwd))', \(rollout),
                '\(sql(row.source))', '\(sql(row.threadSource))', '', '', '',
                \(1_700_000_000_000 + index), 0, \(1_800_000_000_000 - index), 0, 0, NULL
            )
            """
        }

        try executeSQL(statements.joined(separator: ";"))
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
}

private func event(_ type: String, _ payload: [String: Any], timestamp: String? = nil) -> String {
    var envelope: [String: Any] = ["type": type, "payload": payload]
    if let timestamp {
        envelope["timestamp"] = timestamp
    }
    let data = try! JSONSerialization.data(withJSONObject: envelope)
    return String(decoding: data, as: UTF8.self)
}
