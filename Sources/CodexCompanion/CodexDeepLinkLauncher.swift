import AppKit
import CodexCompanionCore
import Foundation

@MainActor
struct CodexDeepLinkLauncher {
    func openTask(id: String) -> Bool {
        guard let url = CodexDeepLink.task(id: id) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func startTask(projectPath: String) {
        guard let url = CodexDeepLink.newTask(projectPath: projectPath) else { return }
        NSWorkspace.shared.open(url)
    }
}
