import Foundation

public enum CodexDeepLink {
    public static func task(id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    public static func newChat(homeDirectory: String = NSHomeDirectory()) -> URL {
        let chatsPath = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Documents/Codex", isDirectory: true)
            .standardizedFileURL.path
        return newTask(projectPath: chatsPath)!
    }

    public static func newTask(projectPath: String) -> URL? {
        guard projectPath.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "path", value: projectPath)]
        return components.url
    }
}
