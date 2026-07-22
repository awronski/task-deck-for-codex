import AppKit
import SwiftUI

private final class ConfiguringView: NSView {
    var configuredTitle = "Task Deck for Codex"

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        window.title = configuredTitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.075, green: 0.086, blue: 0.094, alpha: 1)
        window.minSize = NSSize(width: 390, height: 380)
        window.setFrameAutosaveName("TaskDeckForCodex.mainWindow")

        let defaultsKey = "task-deck-for-codex.did-set-initial-window-size.v1"
        if !UserDefaults.standard.bool(forKey: defaultsKey) {
            Task { @MainActor [weak window] in
                guard let window else { return }
                window.setContentSize(NSSize(width: 447, height: 879))
                window.center()
                UserDefaults.standard.set(true, forKey: defaultsKey)
            }
        }
    }
}

struct WindowConfiguration: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.configuredTitle = title
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = title
    }
}
