import CodexCompanionCore
import Foundation
import Testing

@Suite
struct CodexDeepLinkTests {
    @Test
    func existingTaskUsesItsCanonicalThreadLink() {
        let id = "019f8540-5c11-7323-a445-69da0a2be57f"
        #expect(CodexDeepLink.task(id: id)?.absoluteString == "codex://threads/\(id)")
        #expect(CodexDeepLink.task(id: "not-a-thread") == nil)
    }

    @Test
    func newProjectTaskEncodesTheAbsoluteWorkspacePath() {
        let link = CodexDeepLink.newTask(projectPath: "/Users/test/My Project/#client")
        let components = link.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }

        #expect(components?.scheme == "codex")
        #expect(components?.host == "threads")
        #expect(components?.path == "/new")
        #expect(components?.queryItems?.first?.value == "/Users/test/My Project/#client")
        #expect(CodexDeepLink.newTask(projectPath: "relative/path") == nil)
    }

}
