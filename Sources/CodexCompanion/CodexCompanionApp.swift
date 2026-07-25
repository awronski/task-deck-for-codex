import AppKit
import CodexCompanionCore
import SwiftUI

@main
@MainActor
struct TaskDeckForCodexApp: App {
    @State private var console: AttentionConsole
    @AppStorage("consoleFontFamily") private var fontFamily = ConsoleFontFamily.system.rawValue
    @AppStorage("consoleFontSize") private var fontSize = ConsoleFontSize.standard.rawValue

    init() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL)
        {
            NSApplication.shared.applicationIconImage = icon
        }

        let repository = CodexTaskRepository()
        let storage = UserDefaultsVisibilityStorage()
        let titleStorage = UserDefaultsTaskTitleStorage()
        let priorityStorage = UserDefaultsTaskPriorityStorage()
        let noteStorage = UserDefaultsTaskNoteStorage()
        let reminderStorage = UserDefaultsTaskReminderStorage()
        let projectOrderStorage = UserDefaultsProjectOrderStorage()
        _console = State(
            initialValue: AttentionConsole(
                loader: repository,
                archiver: repository,
                storage: storage,
                titleStorage: titleStorage,
                priorityStorage: priorityStorage,
                noteStorage: noteStorage,
                reminderStorage: reminderStorage,
                projectOrderStorage: projectOrderStorage
            )
        )
    }

    var body: some Scene {
        WindowGroup("Task Deck for Codex", id: "task-deck-for-codex") {
            AttentionConsoleView(console: console)
                .environment(
                    \.consoleTypography,
                    ConsoleTypography(
                        family: ConsoleFontFamily(rawValue: fontFamily) ?? .system,
                        baseSize: fontSize
                    )
                )
                .frame(minWidth: 595, minHeight: 380)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 595, height: 879)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            TypographySettingsView()
        }
    }
}
