import Foundation

struct CodexProjectCatalog: Sendable {
    struct Project: Equatable, Sendable {
        let id: String
        let name: String
        let rootPaths: [String]

        func identity(matching path: String) -> ProjectIdentity {
            let projectPath = rootPaths
                .filter { Self.contains(path: path, root: $0) }
                .max(by: { $0.count < $1.count })
                ?? rootPaths[0]

            return ProjectIdentity(
                key: "project:\(id)",
                name: name,
                path: projectPath,
                isChat: false
            )
        }

        fileprivate static func contains(path: String, root: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }
    }

    private struct PersistedState: Decodable {
        let localProjects: [String: PersistedProject?]
        let taskAssignments: [String: PersistedAssignment?]
        let projectlessTaskIDs: [String]

        enum CodingKeys: String, CodingKey {
            case localProjects = "local-projects"
            case taskAssignments = "thread-project-assignments"
            case projectlessTaskIDs = "projectless-thread-ids"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localProjects = try container.decode([String: PersistedProject?].self, forKey: .localProjects)
            taskAssignments = try container.decodeIfPresent(
                [String: PersistedAssignment?].self,
                forKey: .taskAssignments
            ) ?? [:]
            projectlessTaskIDs = try container.decodeIfPresent(
                [String].self,
                forKey: .projectlessTaskIDs
            ) ?? []
        }
    }

    private struct PersistedProject: Decodable {
        let id: String?
        let name: String?
        let rootPaths: [String]?
    }

    private struct PersistedAssignment: Decodable {
        let projectId: String?
    }

    private let projectsByID: [String: Project]
    private let taskProjectIDs: [String: String]
    private let projectlessTaskIDs: Set<String>

    init(data: Data) throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: data)

        var projects: [String: Project] = [:]
        for (key, value) in state.localProjects {
            guard let value,
                  let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                continue
            }

            let roots = (value.rootPaths ?? [])
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                .filter { $0 != "/" }
            guard !roots.isEmpty else { continue }

            let id = value.id.flatMap { $0.isEmpty ? nil : $0 } ?? key
            projects[id] = Project(id: id, name: name, rootPaths: roots)
        }
        projectsByID = projects

        taskProjectIDs = Dictionary(uniqueKeysWithValues: state.taskAssignments.compactMap { taskID, value in
            guard let projectID = value?.projectId, !projectID.isEmpty else { return nil }
            return (taskID, projectID)
        })
        projectlessTaskIDs = Set(state.projectlessTaskIDs)
    }

    init(
        projects: [Project],
        taskProjectIDs: [String: String] = [:],
        projectlessTaskIDs: Set<String> = []
    ) {
        self.projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        self.taskProjectIDs = taskProjectIDs
        self.projectlessTaskIDs = projectlessTaskIDs
    }

    func identities(homeDirectory: String) -> [ProjectIdentity] {
        let projects = projectsByID.values
            .map { $0.identity(matching: $0.rootPaths[0]) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
            }
        let chatsRoot = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Documents/Codex", isDirectory: true)
            .standardizedFileURL.path
        return projects + [
            ProjectIdentity(key: "chats", name: "Chats", path: chatsRoot, isChat: true)
        ]
    }

    func resolve(taskID: String, path rawPath: String, homeDirectory: String) -> ProjectIdentity? {
        guard rawPath.hasPrefix("/") else { return nil }

        if let chat = ProjectResolver.resolve(path: rawPath, homeDirectory: homeDirectory), chat.isChat {
            return chat
        }

        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        if let projectID = taskProjectIDs[taskID] {
            return projectsByID[projectID]?.identity(matching: path)
        }
        guard !projectlessTaskIDs.contains(taskID) else {
            return nil
        }

        return projectsByID.values
            .compactMap { project in
                project.rootPaths
                    .filter { Project.contains(path: path, root: $0) }
                    .map { (project: project, rootLength: $0.count) }
                    .max(by: { $0.rootLength < $1.rootLength })
            }
            .max(by: { $0.rootLength < $1.rootLength })?
            .project
            .identity(matching: path)
    }
}
