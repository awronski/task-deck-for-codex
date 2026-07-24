import Foundation

public protocol CodexTaskLoading: Sendable {
    func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot
}

public protocol CodexTaskArchiving: Sendable {
    func setArchived(_ archived: Bool, taskID: String) async throws
}

public enum CodexRepositoryError: LocalizedError, Equatable {
    case databaseMissing(String)
    case projectCatalogMissing(String)
    case sqliteFailed(String)
    case codexExecutableMissing
    case codexCommandFailed(String)
    case invalidDatabaseResponse
    case invalidProjectCatalog
    case invalidTaskID(String)

    public var errorDescription: String? {
        switch self {
        case let .databaseMissing(path): "Codex state database was not found at \(path)."
        case let .projectCatalogMissing(path): "Codex project catalog was not found at \(path)."
        case let .sqliteFailed(message): "Could not access Codex tasks: \(message)"
        case .codexExecutableMissing: "Codex could not be found. Reinstall or update the Codex app."
        case let .codexCommandFailed(message): "Codex could not update the task's archive state: \(message)"
        case .invalidDatabaseResponse: "Codex returned an unreadable task list."
        case .invalidProjectCatalog: "Codex returned an unreadable project list."
        case let .invalidTaskID(taskID): "\(taskID) is not a valid Codex task ID."
        }
    }
}

public actor CodexTaskRepository: CodexTaskLoading, CodexTaskArchiving {
    private struct SQLiteFailure: Error {
        let status: Int32?
        let message: String
    }

    private struct ThreadRow: Decodable {
        let id: String
        let title: String?
        let cwd: String?
        let rolloutPath: String?
        let source: String
        let threadSource: String
        let agentRole: String
        let agentNickname: String
        let agentPath: String
        let parentThreadID: String?
        let recencyAtMilliseconds: Int64
        let createdAtMilliseconds: Int64

        enum CodingKeys: String, CodingKey {
            case id, title, cwd
            case rolloutPath = "rollout_path"
            case source
            case threadSource = "thread_source"
            case agentRole = "agent_role"
            case agentNickname = "agent_nickname"
            case agentPath = "agent_path"
            case parentThreadID = "parent_thread_id"
            case recencyAtMilliseconds = "recency_at_ms"
            case createdAtMilliseconds = "created_at_ms"
        }
    }

    private struct SessionIndexEntry: Decodable {
        let id: String
        let threadName: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }

    private struct RolloutCursor: Sendable {
        var offset: UInt64 = 0
        var pending = Data()
        var reducer = RolloutEventReducer()
    }

    private static let initialRecoveryWindow: UInt64 = 65_536

    private let databaseURL: URL
    private let codexHomeURL: URL
    private let codexExecutableURL: URL?
    private let sessionsURL: URL
    private let sessionIndexURL: URL
    private let projectCatalogURL: URL
    private let homeDirectory: String
    private var cursors: [String: RolloutCursor] = [:]
    private var lastProjectCatalog: CodexProjectCatalog?

    public init(
        codexHome: URL? = nil,
        homeDirectory: String = NSHomeDirectory(),
        projectCatalogURL: URL? = nil,
        codexExecutableURL: URL? = nil
    ) {
        let resolvedCodexHome = codexHome
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex", isDirectory: true)
        self.codexHomeURL = resolvedCodexHome
        self.databaseURL = resolvedCodexHome.appendingPathComponent("state_5.sqlite")
        self.codexExecutableURL = codexExecutableURL
            ?? Self.findCodexExecutable(homeDirectory: homeDirectory)
        self.sessionsURL = resolvedCodexHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        self.sessionIndexURL = resolvedCodexHome.appendingPathComponent("session_index.jsonl")
        self.projectCatalogURL = projectCatalogURL
            ?? resolvedCodexHome.appendingPathComponent(".codex-global-state.json")
        self.homeDirectory = homeDirectory
    }

    public func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot {
        let rows = try queryThreadRows(including: kinds)
        let projectCatalog = try loadProjectCatalog()
        let sessionTitles = loadSessionTitles()
        var tasks: [CodexTask] = []
        tasks.reserveCapacity(rows.count)

        for row in rows {
            guard UUID(uuidString: row.id) != nil else { continue }

            let project = projectCatalog.resolve(
                taskID: row.id,
                path: row.cwd ?? "",
                homeDirectory: homeDirectory
            ) ?? row.parentThreadID.flatMap {
                projectCatalog.resolve(
                    taskID: $0,
                    path: row.cwd ?? "",
                    homeDirectory: homeDirectory
                )
            }
            if project == nil, kinds.isDisjoint(with: [.unassigned, .agent, .batch]) {
                continue
            }
            if project != nil, kinds.isDisjoint(with: [.regular, .automation, .agent, .batch]) {
                continue
            }

            let reducer = rolloutState(path: row.rolloutPath, expectedTaskID: row.id)
            let kind = taskKind(for: row, reducer: reducer, hasProject: project != nil)
            guard kinds.contains(kind) else { continue }
            let status = reducer?.status ?? .inactive

            let resolvedProject = project ?? ProjectIdentity(
                key: "unassigned",
                name: "Unassigned",
                path: "",
                isChat: false
            )

            let updatedAt = Date(timeIntervalSince1970: Double(row.recencyAtMilliseconds) / 1_000)
            let createdAt = row.createdAtMilliseconds > 0
                ? Date(timeIntervalSince1970: Double(row.createdAtMilliseconds) / 1_000)
                : updatedAt

            tasks.append(
                CodexTask(
                    id: row.id,
                    title: TaskText.cleanTitle(
                        sessionTitles[row.id] ?? row.title ?? "",
                        fallbackID: row.id
                    ),
                    projectKey: resolvedProject.key,
                    projectName: resolvedProject.name,
                    projectPath: resolvedProject.path,
                    isChat: resolvedProject.isChat,
                    kind: kind,
                    status: status,
                    activity: reducer?.activity,
                    updatedAt: updatedAt,
                    workingSince: status == .working ? reducer?.workingSince : nil,
                    finishedAt: reducer?.finishedAt,
                    createdAt: createdAt
                )
            )
        }

        return CodexTaskSnapshot(
            tasks: tasks,
            projects: projectCatalog.identities(homeDirectory: homeDirectory)
        )
    }

    private func loadSessionTitles() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionIndexURL) else { return [:] }

        let decoder = JSONDecoder()
        var titles: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let entry = try? decoder.decode(SessionIndexEntry.self, from: line),
                  !entry.threadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            titles[entry.id] = entry.threadName
        }
        return titles
    }

    public func setArchived(_ archived: Bool, taskID: String) async throws {
        guard UUID(uuidString: taskID) != nil else {
            throw CodexRepositoryError.invalidTaskID(taskID)
        }
        guard let codexExecutableURL,
              FileManager.default.isExecutableFile(atPath: codexExecutableURL.path)
        else {
            throw CodexRepositoryError.codexExecutableMissing
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = codexExecutableURL
        process.arguments = [archived ? "archive" : "unarchive", taskID]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CODEX_HOME": codexHomeURL.path
        ]) { _, codexHome in codexHome }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw CodexRepositoryError.codexCommandFailed(error.localizedDescription)
        }

        let commandOutput = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: commandOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "codex exited with code \(process.terminationStatus)"
            throw CodexRepositoryError.codexCommandFailed(message.isEmpty ? fallback : message)
        }

        CodexDesktopNotifier(codexHome: codexHomeURL)
            .notify(archived: archived, taskID: taskID)
    }

    private static func findCodexExecutable(homeDirectory: String) -> URL? {
        var candidates: [URL] = []
        if let configuredPath = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"] {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
            }
        }
        candidates.append(
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".local/bin/codex")
        )
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func loadProjectCatalog() throws -> CodexProjectCatalog {
        var foundFile = false
        for url in [projectCatalogURL, projectCatalogURL.appendingPathExtension("bak")] {
            guard let data = try? Data(contentsOf: url) else { continue }
            foundFile = true
            guard let catalog = try? CodexProjectCatalog(data: data) else { continue }
            lastProjectCatalog = catalog
            return catalog
        }

        if let lastProjectCatalog {
            return lastProjectCatalog
        }
        if foundFile {
            throw CodexRepositoryError.invalidProjectCatalog
        }
        throw CodexRepositoryError.projectCatalogMissing(projectCatalogURL.path)
    }

    private func queryThreadRows(including kinds: Set<CodexTaskKind>) throws -> [ThreadRow] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CodexRepositoryError.databaseMissing(databaseURL.path)
        }

        guard !kinds.isEmpty else { return [] }

        let agentPredicate = """
        (COALESCE(source, '') LIKE '%subagent%'
          OR COALESCE(thread_source, '') LIKE '%subagent%'
          OR COALESCE(agent_role, '') <> ''
          OR COALESCE(agent_nickname, '') <> ''
          OR COALESCE(agent_path, '') <> ''
          OR EXISTS (SELECT 1 FROM thread_spawn_edges WHERE child_thread_id = threads.id))
        """
        var kindPredicates = [
            "(source IN ('vscode', 'cli', 'appServer') AND NOT \(agentPredicate))"
        ]
        if kinds.contains(.agent) {
            kindPredicates.append(agentPredicate)
        }
        if kinds.contains(.batch) {
            kindPredicates.append("COALESCE(source, '') = 'exec'")
        }
        let kindPredicate = kindPredicates.map { "(\($0))" }.joined(separator: " OR ")

        let query = """
        SELECT
            id,
            COALESCE(NULLIF(title, ''), NULLIF(first_user_message, ''), NULLIF(preview, ''), '') AS title,
            cwd,
            rollout_path,
            COALESCE(source, '') AS source,
            COALESCE(thread_source, '') AS thread_source,
            COALESCE(agent_role, '') AS agent_role,
            COALESCE(agent_nickname, '') AS agent_nickname,
            COALESCE(agent_path, '') AS agent_path,
            (SELECT parent_thread_id
             FROM thread_spawn_edges
             WHERE child_thread_id = threads.id
             LIMIT 1) AS parent_thread_id,
            COALESCE(created_at_ms, created_at * 1000, 0) AS created_at_ms,
            COALESCE(recency_at_ms, updated_at * 1000, 0) AS recency_at_ms
        FROM threads
        WHERE archived = 0
          AND (\(kindPredicate))
          AND (TRIM(title) <> '' OR TRIM(first_user_message) <> '' OR TRIM(preview) <> '')
        ORDER BY recency_at_ms DESC
        """

        let output: Data
        do {
            output = try runSQLite(arguments: ["-json", "-readonly", databaseURL.path, query])
        } catch let failure as SQLiteFailure {
            // sqlite3 returns SQLITE_CANTOPEN as process status 14.
            guard failure.status == 14 else {
                throw CodexRepositoryError.sqliteFailed(failure.message)
            }

            // Codex uses WAL mode, but SQLite removes its sidecars when the last
            // connection closes. Reopen the existing database read-write only so
            // SQLite can recreate those files; query_only keeps the SQL read-only.
            do {
                output = try runSQLite(arguments: [
                    "-json",
                    "-cmd", "PRAGMA query_only=ON",
                    databaseURL.absoluteString + "?mode=rw",
                    query
                ])
            } catch let fallbackFailure as SQLiteFailure {
                throw CodexRepositoryError.sqliteFailed(fallbackFailure.message)
            }
        }

        guard !output.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([ThreadRow].self, from: output)
        } catch {
            throw CodexRepositoryError.invalidDatabaseResponse
        }
    }

    private func runSQLite(arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SQLiteFailure(status: nil, message: error.localizedDescription)
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = "sqlite3 exited with code \(process.terminationStatus)"
            throw SQLiteFailure(
                status: process.terminationStatus,
                message: message.isEmpty ? fallback : message
            )
        }
        return output
    }

    private func taskKind(
        for row: ThreadRow,
        reducer: RolloutEventReducer?,
        hasProject: Bool
    ) -> CodexTaskKind {
        let isAgent = row.source.localizedCaseInsensitiveContains("subagent")
            || row.threadSource.localizedCaseInsensitiveContains("subagent")
            || !row.agentRole.isEmpty
            || !row.agentNickname.isEmpty
            || !row.agentPath.isEmpty
            || row.parentThreadID != nil
            || reducer?.isAgent == true
        if isAgent { return .agent }

        if row.source.caseInsensitiveCompare("exec") == .orderedSame || reducer?.isBatch == true {
            return .batch
        }
        if !hasProject { return .unassigned }
        if row.threadSource.caseInsensitiveCompare("automation") == .orderedSame {
            return .automation
        }
        return .regular
    }

    private func rolloutState(path: String?, expectedTaskID: String) -> RolloutEventReducer? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let sessionsPrefix = sessionsURL.path + "/"
        guard url.path.hasPrefix(sessionsPrefix),
              url.lastPathComponent.hasSuffix("\(expectedTaskID).jsonl")
        else {
            return nil
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            return nil
        }

        var cursor: RolloutCursor
        if let existingCursor = cursors[url.path], fileSize >= existingCursor.offset {
            cursor = existingCursor
        } else {
            guard let recoveredCursor = recoverInitialCursor(at: url, fileSize: fileSize) else {
                return nil
            }
            cursor = recoveredCursor
        }
        guard fileSize > cursor.offset else {
            cursors[url.path] = cursor
            return cursor.reducer
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: cursor.offset)

            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                cursor.offset += UInt64(chunk.count)
                consume(chunk: chunk, into: &cursor)
            }
        } catch {
            return cursors[url.path]?.reducer
        }

        cursors[url.path] = cursor
        return cursor.reducer
    }

    private func recoverInitialCursor(at url: URL, fileSize: UInt64) -> RolloutCursor? {
        guard fileSize > 0 else { return RolloutCursor() }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var metadataReducer = RolloutEventReducer()
            let metadataLength = min(fileSize, Self.initialRecoveryWindow)
            if let metadata = try read(handle: handle, from: 0, length: metadataLength) {
                consumeMetadataLines(in: metadata, into: &metadataReducer)
            }

            var window = min(fileSize, Self.initialRecoveryWindow)
            while true {
                let start = fileSize - window
                guard let data = try read(handle: handle, from: start, length: window) else {
                    return nil
                }

                var reducer = metadataReducer
                let pending = consumeRecoveryData(
                    data,
                    startsAtFileBeginning: start == 0,
                    into: &reducer
                )
                if reducer.hasLifecycleEvent || start == 0 {
                    return RolloutCursor(offset: fileSize, pending: pending, reducer: reducer)
                }

                window = min(fileSize, window * 2)
            }
        } catch {
            return nil
        }
    }

    private func read(handle: FileHandle, from offset: UInt64, length: UInt64) throws -> Data? {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(length))
    }

    private func consumeMetadataLines(in data: Data, into reducer: inout RolloutEventReducer) {
        var lineStart = data.startIndex
        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A)
        {
            let lineData = data[lineStart..<newline]
            if let line = String(data: lineData, encoding: .utf8), line.contains("\"session_meta\"") {
                reducer.consume(line: line)
            }
            lineStart = data.index(after: newline)
        }
    }

    private func consumeRecoveryData(
        _ data: Data,
        startsAtFileBeginning: Bool,
        into reducer: inout RolloutEventReducer
    ) -> Data {
        var lineStart = data.startIndex
        if !startsAtFileBeginning {
            guard let firstNewline = data.firstIndex(of: 0x0A) else { return data }
            lineStart = data.index(after: firstNewline)
        }

        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A)
        {
            if let line = String(data: data[lineStart..<newline], encoding: .utf8) {
                reducer.consume(line: line)
            }
            lineStart = data.index(after: newline)
        }

        return lineStart < data.endIndex ? Data(data[lineStart...]) : Data()
    }

    private func consume(chunk: Data, into cursor: inout RolloutCursor) {
        cursor.pending.append(chunk)
        let data = cursor.pending
        var lineStart = data.startIndex

        while lineStart < data.endIndex,
              let newline = data[lineStart...].firstIndex(of: 0x0A)
        {
            let lineData = data[lineStart..<newline]
            if let line = String(data: lineData, encoding: .utf8) {
                cursor.reducer.consume(line: line)
            }
            lineStart = data.index(after: newline)
        }

        cursor.pending = lineStart < data.endIndex ? Data(data[lineStart...]) : Data()
    }
}
