import Darwin
import Foundation

public protocol CodexTaskLoading: Sendable {
    func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot
}

public enum CodexTaskArchiveResult: Equatable, Sendable {
    case completed
    case deferred
}

public protocol CodexTaskArchiving: Sendable {
    func setArchived(_ archived: Bool, taskID: String) async throws -> CodexTaskArchiveResult
    func retryPendingArchives() async throws
    func pendingArchiveTaskIDs() async -> Set<String>
}

public protocol CodexTaskArchiveStateReading: Sendable {
    func isTaskUnarchived(_ taskID: String) async throws -> Bool
}

public extension CodexTaskArchiving {
    func retryPendingArchives() async throws {}
    func pendingArchiveTaskIDs() async -> Set<String> { [] }
}

public protocol CodexTaskRenaming: Sendable {
    func setTitle(_ title: String, taskID: String) async throws
}

public enum CodexRepositoryError: LocalizedError, Equatable {
    case databaseMissing(String)
    case projectCatalogMissing(String)
    case sqliteFailed(String)
    case codexExecutableMissing
    case codexCommandFailed(String)
    case codexTaskHasActiveWriter
    case codexTitleUpdateFailed(String)
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
        case .codexTaskHasActiveWriter: "Another Codex client currently owns this task."
        case let .codexTitleUpdateFailed(message): "Codex could not rename the task: \(message)"
        case .invalidDatabaseResponse: "Codex returned an unreadable task list."
        case .invalidProjectCatalog: "Codex returned an unreadable project list."
        case let .invalidTaskID(taskID): "\(taskID) is not a valid Codex task ID."
        }
    }
}

public actor CodexTaskRepository:
    CodexTaskLoading,
    CodexTaskArchiving,
    CodexTaskArchiveStateReading,
    CodexTaskRenaming
{
    private struct AppServerError: Decodable {
        let message: String
    }

    private struct AppServerResponse: Decodable {
        let id: Int?
        let error: AppServerError?
    }

    private struct UnarchivedTaskRow: Decodable {
        let id: String
    }

    private struct SQLiteFailure: Error {
        let status: Int32?
        let message: String
    }

    private enum ArchiveCommandFailure: Error, Sendable {
        case launch(String)
        case exited(String)
        case timedOut
        case outputReadFailed
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
        let modelName: String?
        let thinkingEffort: String?
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
            case modelName = "model"
            case thinkingEffort = "reasoning_effort"
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

    private struct SQLiteSchemaRow: Decodable {
        let schemaVersion: Int
        let columnsJSON: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case columnsJSON = "columns_json"
        }
    }

    private struct SQLiteSchemaVersionRow: Decodable {
        let schemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    private struct VersionedQueryOutput {
        let schemaVersion: Int
        let rows: Data
    }

    private struct DatabaseIdentity: Equatable {
        let deviceNumber: UInt64?
        let fileNumber: UInt64?
        let creationDate: Date?
    }

    private struct ThreadSchema {
        let version: Int
        let columns: Set<String>
        let databaseIdentity: DatabaseIdentity
    }

    private struct RolloutCursor: Sendable {
        var offset: UInt64 = 0
        var pending = Data()
        var reducer = RolloutEventReducer()
    }

    private static let initialRecoveryWindow: UInt64 = 65_536
    private static let processPollIntervalMilliseconds: Int32 = 50
    private static let maximumDiagnosticBytes = 16_384

    private let databaseURL: URL
    private let codexHomeURL: URL
    private let codexExecutableURL: URL?
    private let sessionsURL: URL
    private let sessionIndexURL: URL
    private let projectCatalogURL: URL
    private let homeDirectory: String
    private let titleUpdateTimeout: TimeInterval
    private let archiveUpdateTimeout: TimeInterval
    private var cursors: [String: RolloutCursor] = [:]
    private var lastProjectCatalog: CodexProjectCatalog?
    private var threadSchema: ThreadSchema?

    public init(
        codexHome: URL? = nil,
        homeDirectory: String = NSHomeDirectory(),
        projectCatalogURL: URL? = nil,
        codexExecutableURL: URL? = nil,
        titleUpdateTimeout: TimeInterval = 5,
        archiveUpdateTimeout: TimeInterval = 5
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
        self.titleUpdateTimeout = max(0.1, titleUpdateTimeout)
        self.archiveUpdateTimeout = max(0.1, archiveUpdateTimeout)
    }

    public func loadSnapshot(including kinds: Set<CodexTaskKind>) async throws -> CodexTaskSnapshot {
        let rows = try queryThreadRows(including: kinds)
        let projectCatalog = try loadProjectCatalog()
        let sessionTitles = loadSessionTitles()
        var tasks: [CodexTask] = []
        tasks.reserveCapacity(rows.count)

        for row in rows {
            guard UUID(uuidString: row.id) != nil else { continue }
            let rawTitle = sessionTitles[row.id] ?? row.title ?? ""
            guard !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let project = resolveProject(for: row, using: projectCatalog)
            if project == nil, kinds.isDisjoint(with: [.delegated, .unassigned, .agent, .batch]) {
                continue
            }
            if project != nil, kinds.isDisjoint(with: [.regular, .delegated, .automation, .agent, .batch]) {
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
                        rawTitle,
                        fallbackID: row.id
                    ),
                    projectKey: resolvedProject.key,
                    projectName: resolvedProject.name,
                    projectPath: resolvedProject.path,
                    isChat: resolvedProject.isChat,
                    kind: kind,
                    status: status,
                    modelName: row.modelName,
                    thinkingEffort: row.thinkingEffort,
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

    private func resolveProject(
        for row: ThreadRow,
        using projectCatalog: CodexProjectCatalog
    ) -> ProjectIdentity? {
        projectCatalog.resolve(
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

    public func setTitle(_ title: String, taskID: String) async throws {
        guard UUID(uuidString: taskID) != nil else {
            throw CodexRepositoryError.invalidTaskID(taskID)
        }
        guard let codexExecutableURL,
              FileManager.default.isExecutableFile(atPath: codexExecutableURL.path)
        else {
            throw CodexRepositoryError.codexExecutableMissing
        }

        let codexHomeURL = self.codexHomeURL
        let titleUpdateTimeout = self.titleUpdateTimeout
        let operation = Task.detached(priority: .userInitiated) {
            try Self.performTitleUpdate(
                title,
                taskID: taskID,
                codexExecutableURL: codexExecutableURL,
                codexHomeURL: codexHomeURL,
                timeout: titleUpdateTimeout
            )
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private nonisolated static func performTitleUpdate(
        _ title: String,
        taskID: String,
        codexExecutableURL: URL,
        codexHomeURL: URL,
        timeout: TimeInterval
    ) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = codexExecutableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CODEX_HOME": codexHomeURL.path
        ]) { _, codexHome in codexHome }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw CodexRepositoryError.codexTitleUpdateFailed(error.localizedDescription)
        }

        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                stop(process)
            }
        }

        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var responseBuffer = Data()
        var diagnostics = Data()
        do {
            try writeAppServerMessage([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "task-deck-for-codex",
                        "title": "Task Deck for Codex",
                        "version": "1"
                    ]
                ]
            ], to: input.fileHandleForWriting)
            try readAppServerResponse(
                requestID: 1,
                from: output.fileHandleForReading,
                buffer: &responseBuffer,
                diagnostics: &diagnostics,
                deadline: deadline
            )

            try writeAppServerMessage(
                ["method": "initialized"],
                to: input.fileHandleForWriting
            )
            try writeAppServerMessage([
                "id": 2,
                "method": "thread/name/set",
                "params": [
                    "threadId": taskID,
                    "name": title
                ]
            ], to: input.fileHandleForWriting)
            try readAppServerResponse(
                requestID: 2,
                from: output.fileHandleForReading,
                buffer: &responseBuffer,
                diagnostics: &diagnostics,
                deadline: deadline
            )
        } catch let error as CodexRepositoryError {
            throw error
        } catch {
            throw CodexRepositoryError.codexTitleUpdateFailed(error.localizedDescription)
        }

        try? input.fileHandleForWriting.close()
        try waitForProcessExit(
            process,
            output: output.fileHandleForReading,
            diagnostics: &diagnostics,
            deadline: deadline
        )
        guard process.terminationStatus == 0 else {
            let message = String(decoding: diagnostics, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "codex app-server exited with code \(process.terminationStatus)"
            throw CodexRepositoryError.codexTitleUpdateFailed(message.isEmpty ? fallback : message)
        }
    }

    private nonisolated static func writeAppServerMessage(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        var message = try JSONSerialization.data(withJSONObject: object)
        message.append(0x0A)
        try handle.write(contentsOf: message)
    }

    private nonisolated static func readAppServerResponse(
        requestID: Int,
        from handle: FileHandle,
        buffer: inout Data,
        diagnostics: inout Data,
        deadline: UInt64
    ) throws {
        while let line = try readAppServerLine(from: handle, buffer: &buffer, deadline: deadline) {
            guard let response = try? JSONDecoder().decode(AppServerResponse.self, from: line) else {
                appendDiagnostic(line, to: &diagnostics)
                continue
            }
            guard response.id == requestID else { continue }

            if let error = response.error {
                throw CodexRepositoryError.codexTitleUpdateFailed(error.message)
            }
            return
        }
        throw CodexRepositoryError.codexTitleUpdateFailed(
            "Codex app server closed before confirming the rename."
        )
    }

    private nonisolated static func readAppServerLine(
        from handle: FileHandle,
        buffer: inout Data,
        deadline: UInt64
    ) throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            try waitForReadableData(on: handle, deadline: deadline)
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk)
        }
    }

    private nonisolated static func waitForReadableData(
        on handle: FileHandle,
        deadline: UInt64
    ) throws {
        while true {
            try checkTitleUpdateDeadline(deadline)
            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(
                &descriptor,
                1,
                pollInterval(until: deadline)
            )
            if result > 0 { return }
            if result == 0 { continue }
            if errno == EINTR { continue }
            throw CodexRepositoryError.codexTitleUpdateFailed(
                "Codex app server output could not be read."
            )
        }
    }

    private nonisolated static func waitForProcessExit(
        _ process: Process,
        output: FileHandle,
        diagnostics: inout Data,
        deadline: UInt64
    ) throws {
        while process.isRunning {
            try checkTitleUpdateDeadline(deadline)
            var descriptor = pollfd(
                fd: output.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(
                &descriptor,
                1,
                pollInterval(until: deadline)
            )
            if result > 0 {
                let chunk = output.availableData
                if chunk.isEmpty {
                    Thread.sleep(forTimeInterval: 0.005)
                } else {
                    appendDiagnostic(chunk, to: &diagnostics)
                }
            } else if result < 0, errno != EINTR {
                throw CodexRepositoryError.codexTitleUpdateFailed(
                    "Codex app server output could not be read."
                )
            }
        }
        process.waitUntilExit()
    }

    private nonisolated static func checkTitleUpdateDeadline(_ deadline: UInt64) throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw CodexRepositoryError.codexTitleUpdateFailed(
                "Codex app server timed out while renaming the task."
            )
        }
    }

    private nonisolated static func pollInterval(until deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        let remainingMilliseconds = (deadline - now + 999_999) / 1_000_000
        return min(Int32(clamping: remainingMilliseconds), processPollIntervalMilliseconds)
    }

    private nonisolated static func appendDiagnostic(_ data: Data, to diagnostics: inout Data) {
        diagnostics.append(data)
        if diagnostics.count > maximumDiagnosticBytes {
            diagnostics = diagnostics.suffix(maximumDiagnosticBytes)
        }
    }

    private nonisolated static func stop(_ process: Process) {
        let processIdentifier = process.processIdentifier
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    public func setArchived(
        _ archived: Bool,
        taskID: String
    ) async throws -> CodexTaskArchiveResult {
        guard UUID(uuidString: taskID) != nil else {
            throw CodexRepositoryError.invalidTaskID(taskID)
        }
        guard let codexExecutableURL,
              FileManager.default.isExecutableFile(atPath: codexExecutableURL.path)
        else {
            throw CodexRepositoryError.codexExecutableMissing
        }

        let codexHomeURL = self.codexHomeURL
        let socketURL = sharedAppServerSocketURL()
        let archiveUpdateTimeout = self.archiveUpdateTimeout
        let operation = Task.detached(priority: .userInitiated) {
            try Self.performArchiveUpdate(
                archived,
                taskID: taskID,
                codexExecutableURL: codexExecutableURL,
                codexHomeURL: codexHomeURL,
                socketURL: socketURL,
                timeout: archiveUpdateTimeout
            )
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }

        CodexDesktopNotifier(codexHome: codexHomeURL)
            .notify(archived: archived, taskID: taskID)
        return .completed
    }

    public func isTaskUnarchived(_ taskID: String) async throws -> Bool {
        guard UUID(uuidString: taskID) != nil else {
            throw CodexRepositoryError.invalidTaskID(taskID)
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CodexRepositoryError.databaseMissing(databaseURL.path)
        }

        let output: Data
        do {
            output = try runDatabaseQuery(
                "SELECT id FROM threads WHERE id = '\(taskID)' AND archived = 0 LIMIT 1"
            )
        } catch let failure as SQLiteFailure {
            throw CodexRepositoryError.sqliteFailed(failure.message)
        }
        guard !output.isEmpty else { return false }
        guard let rows = try? JSONDecoder().decode([UnarchivedTaskRow].self, from: output) else {
            throw CodexRepositoryError.invalidDatabaseResponse
        }
        return !rows.isEmpty
    }

    private nonisolated static func performArchiveUpdate(
        _ archived: Bool,
        taskID: String,
        codexExecutableURL: URL,
        codexHomeURL: URL,
        socketURL: URL?,
        timeout: TimeInterval
    ) throws {
        let command = archived ? "archive" : "unarchive"
        let directArguments = [command, taskID]
        let arguments = socketURL.map {
            [command, "--remote", "unix://\($0.path)", taskID]
        } ?? directArguments

        do {
            try runArchiveCommand(
                arguments: arguments,
                codexExecutableURL: codexExecutableURL,
                codexHomeURL: codexHomeURL,
                timeout: timeout
            )
        } catch ArchiveCommandFailure.exited(_)
            where socketURL.map({ !isReachableUnixSocket($0) }) == true
        {
            do {
                try runArchiveCommand(
                    arguments: directArguments,
                    codexExecutableURL: codexExecutableURL,
                    codexHomeURL: codexHomeURL,
                    timeout: timeout
                )
            } catch let failure as ArchiveCommandFailure {
                throw archiveRepositoryError(for: failure)
            }
        } catch let failure as ArchiveCommandFailure {
            throw archiveRepositoryError(for: failure)
        }
    }

    private nonisolated static func runArchiveCommand(
        arguments: [String],
        codexExecutableURL: URL,
        codexHomeURL: URL,
        timeout: TimeInterval
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = codexExecutableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CODEX_HOME": codexHomeURL.path
        ]) { _, codexHome in codexHome }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw ArchiveCommandFailure.launch(error.localizedDescription)
        }

        defer {
            if process.isRunning {
                stop(process)
            }
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard descriptorFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0
        else {
            throw ArchiveCommandFailure.outputReadFailed
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        var diagnostics = Data()
        while process.isRunning {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw ArchiveCommandFailure.timedOut
            }

            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(
                &pollDescriptor,
                1,
                pollInterval(until: deadline)
            )
            if result > 0 {
                try drainArchiveOutput(from: descriptor, into: &diagnostics)
            } else if result < 0, errno != EINTR {
                throw ArchiveCommandFailure.outputReadFailed
            }
        }

        process.waitUntilExit()
        try drainArchiveOutput(from: descriptor, into: &diagnostics)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: diagnostics, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "codex exited with code \(process.terminationStatus)"
            throw ArchiveCommandFailure.exited(message.isEmpty ? fallback : message)
        }
    }

    private nonisolated static func drainArchiveOutput(
        from descriptor: Int32,
        into diagnostics: inout Data
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                appendDiagnostic(Data(buffer.prefix(count)), to: &diagnostics)
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                throw ArchiveCommandFailure.outputReadFailed
            }
        }
    }

    private nonisolated static func archiveRepositoryError(
        for failure: ArchiveCommandFailure
    ) -> CodexRepositoryError {
        switch failure {
        case let .exited(message) where message.localizedCaseInsensitiveContains(
            "already has an active writer"
        ):
            .codexTaskHasActiveWriter
        case let .launch(message), let .exited(message):
            .codexCommandFailed(message)
        case .timedOut:
            .codexCommandFailed("Codex command timed out while updating the task.")
        case .outputReadFailed:
            .codexCommandFailed("Codex command output could not be read.")
        }
    }

    private func sharedAppServerSocketURL() -> URL? {
        let socketURL = codexHomeURL
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock")
        var fileStatus = stat()
        guard lstat(socketURL.path, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFSOCK,
              Self.isReachableUnixSocket(socketURL)
        else { return nil }
        return socketURL
    }

    private nonisolated static func isReachableUnixSocket(_ socketURL: URL) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else { return false }

        let pathBytes = Array(socketURL.path.utf8CString)
        var address = sockaddr_un()
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 0
        let addressLength = pathOffset + pathBytes.count
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              addressLength <= Int(UInt8.max)
        else { return false }

        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let connectionResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(addressLength))
            }
        }
        if connectionResult == 0 || errno == EISCONN {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        var pollResult: Int32
        repeat {
            pollResult = Darwin.poll(&pollDescriptor, 1, 200)
        } while pollResult < 0 && errno == EINTR
        guard pollResult > 0 else { return false }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else { return false }
        return socketError == 0
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

    private func queryThreadRows(
        including kinds: Set<CodexTaskKind>,
        allowsSchemaRetry: Bool = true
    ) throws -> [ThreadRow] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CodexRepositoryError.databaseMissing(databaseURL.path)
        }

        guard !kinds.isEmpty else { return [] }

        let delegatedPredicate = """
        (COALESCE(source, '') IN ('vscode', 'cli', 'appServer')
          AND COALESCE(thread_source, '') = 'subagent'
          AND COALESCE(agent_role, '') = ''
          AND COALESCE(agent_nickname, '') = ''
          AND COALESCE(agent_path, '') = ''
          AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges WHERE child_thread_id = threads.id))
        """
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
        if kinds.contains(.delegated) {
            kindPredicates.append(delegatedPredicate)
        }
        if kinds.contains(.agent) {
            kindPredicates.append(agentPredicate)
        }
        if kinds.contains(.batch) {
            kindPredicates.append("COALESCE(source, '') = 'exec'")
        }
        let kindPredicate = kindPredicates.map { "(\($0))" }.joined(separator: " OR ")
        let schema = try loadThreadSchema()
        let modelSelection = schema.columns.contains("model") ? "model" : "NULL AS model"
        let effortSelection = schema.columns.contains("reasoning_effort")
            ? "reasoning_effort"
            : "NULL AS reasoning_effort"

        let query = """
        SELECT
            id,
            COALESCE(
                NULLIF(TRIM(title), ''),
                NULLIF(TRIM(first_user_message), ''),
                NULLIF(TRIM(preview), ''),
                ''
            ) AS title,
            cwd,
            rollout_path,
            COALESCE(source, '') AS source,
            COALESCE(thread_source, '') AS thread_source,
            COALESCE(agent_role, '') AS agent_role,
            COALESCE(agent_nickname, '') AS agent_nickname,
            COALESCE(agent_path, '') AS agent_path,
            \(modelSelection),
            \(effortSelection),
            (SELECT parent_thread_id
             FROM thread_spawn_edges
             WHERE child_thread_id = threads.id
             LIMIT 1) AS parent_thread_id,
            COALESCE(created_at_ms, created_at * 1000, 0) AS created_at_ms,
            COALESCE(recency_at_ms, updated_at * 1000, 0) AS recency_at_ms
        FROM threads
        WHERE archived = 0
          AND (\(kindPredicate))
        ORDER BY recency_at_ms DESC
        """

        let output: VersionedQueryOutput
        do {
            output = try runVersionedDatabaseQuery(query)
        } catch let failure as SQLiteFailure {
            if allowsSchemaRetry, failure.message.localizedCaseInsensitiveContains("no such column") {
                threadSchema = nil
                return try queryThreadRows(including: kinds, allowsSchemaRetry: false)
            }
            throw CodexRepositoryError.sqliteFailed(failure.message)
        }

        let databaseWasReplaced = databaseIdentity() != schema.databaseIdentity
        let schemaVersionChanged = output.schemaVersion != schema.version
        if allowsSchemaRetry, databaseWasReplaced || schemaVersionChanged {
            threadSchema = nil
            return try queryThreadRows(including: kinds, allowsSchemaRetry: false)
        }

        guard !output.rows.isEmpty else { return [] }
        let rows: [ThreadRow]
        do {
            rows = try JSONDecoder().decode([ThreadRow].self, from: output.rows)
        } catch {
            throw CodexRepositoryError.invalidDatabaseResponse
        }
        return rows
    }

    private func loadThreadSchema() throws -> ThreadSchema {
        let identity = databaseIdentity()
        if let threadSchema, threadSchema.databaseIdentity == identity {
            return threadSchema
        }

        let output: Data
        do {
            output = try runDatabaseQuery(
                """
                SELECT
                    (SELECT schema_version FROM pragma_schema_version) AS schema_version,
                    json_group_array(name) AS columns_json
                FROM pragma_table_info('threads')
                """
            )
        } catch let failure as SQLiteFailure {
            throw CodexRepositoryError.sqliteFailed(failure.message)
        }

        guard let row = try? JSONDecoder().decode([SQLiteSchemaRow].self, from: output).first,
              let columnsData = row.columnsJSON.data(using: .utf8),
              let columns = try? JSONDecoder().decode([String].self, from: columnsData)
        else {
            throw CodexRepositoryError.invalidDatabaseResponse
        }
        let schema = ThreadSchema(
            version: row.schemaVersion,
            columns: Set(columns),
            databaseIdentity: identity
        )
        threadSchema = schema
        return schema
    }

    private func databaseIdentity() -> DatabaseIdentity {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return DatabaseIdentity(
            deviceNumber: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            creationDate: attributes?[.creationDate] as? Date
        )
    }

    private func runDatabaseQuery(_ query: String) throws -> Data {
        do {
            return try runSQLite(arguments: ["-json", "-readonly", databaseURL.path, query])
        } catch let failure as SQLiteFailure {
            // sqlite3 returns SQLITE_CANTOPEN as process status 14.
            guard failure.status == 14 else { throw failure }

            // Codex uses WAL mode, but SQLite removes its sidecars when the last
            // connection closes. Reopen the existing database read-write only so
            // SQLite can recreate those files; query_only keeps the SQL read-only.
            return try runSQLite(arguments: [
                "-json",
                "-cmd", "PRAGMA query_only=ON",
                databaseURL.absoluteString + "?mode=rw",
                query
            ])
        }
    }

    private func runVersionedDatabaseQuery(_ query: String) throws -> VersionedQueryOutput {
        let output = try runDatabaseQuery(
            """
            SELECT schema_version FROM pragma_schema_version;
            \(query)
            """
        )
        let separatorIndex = output.firstIndex(of: 0x0A)
        let versionData = separatorIndex.map { Data(output[..<$0]) } ?? output
        let rows = separatorIndex.map { index in
            Data(output[output.index(after: index)...].drop { byte in
                byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09
            })
        } ?? Data()
        guard !versionData.isEmpty,
              let version = try? JSONDecoder().decode(
                  [SQLiteSchemaVersionRow].self,
                  from: versionData
              ).first?.schemaVersion
        else {
            throw CodexRepositoryError.invalidDatabaseResponse
        }
        return VersionedQueryOutput(
            schemaVersion: version,
            rows: rows
        )
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
        let isDelegated = ["vscode", "cli", "appServer"].contains {
            row.source.caseInsensitiveCompare($0) == .orderedSame
        }
            && row.threadSource.caseInsensitiveCompare("subagent") == .orderedSame
            && row.agentRole.isEmpty
            && row.agentNickname.isEmpty
            && row.agentPath.isEmpty
            && row.parentThreadID == nil
        if isDelegated { return .delegated }

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
