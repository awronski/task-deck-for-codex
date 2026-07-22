import CodexCompanionCore
import SwiftUI

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .consoleFont(size: 13, weight: .medium)
                .foregroundStyle(ConsoleTheme.secondaryText)
            TextField("Search tasks", text: $text)
                .textFieldStyle(.plain)
                .consoleFont(size: 14)
                .foregroundStyle(ConsoleTheme.primaryText)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ConsoleTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ConsoleTheme.divider))
    }
}

struct ErrorStrip: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(1)
            Spacer(minLength: 0)
        }
        .consoleFont(size: 12)
        .foregroundStyle(ConsoleTheme.red)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(ConsoleTheme.red.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}

struct ProjectSectionView: View {
    let section: ProjectSection
    let isCollapsed: Bool
    let selectedTaskID: String?
    let isTaskMonitored: (String) -> Bool
    let onToggle: () -> Void
    let onOpen: (CodexTask) -> Void
    let onHide: (CodexTask) -> Void
    let onEnable: (CodexTask) -> Void
    let onArchive: (CodexTask) -> Void
    let onNewTask: () -> Void
    let onMoveProject: (String, String, Bool) -> Bool
    let onRename: (String, String) -> Void

    @State private var isDropTarget = false

    private var accent: Color {
        section.isChat ? ConsoleTheme.teal : ConsoleTheme.color(for: section.highestPriorityStatus)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onToggle) {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(accent)
                            .frame(width: 2, height: 22)
                            .padding(.trailing, 10)

                        Image(systemName: section.isChat ? "bubble.left" : "folder")
                            .consoleFont(size: 15, weight: .medium)
                            .foregroundStyle(section.isChat ? ConsoleTheme.teal : ConsoleTheme.primaryText.opacity(0.92))
                            .frame(width: 22)

                        Text(section.name)
                            .consoleFont(size: 15.5, weight: .medium)
                            .foregroundStyle(ConsoleTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 8)

                        if section.tasks.count > 3 {
                            Text("\(section.tasks.count)")
                                .consoleFont(size: 11, weight: .semibold)
                                .foregroundStyle(ConsoleTheme.secondaryText)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(ConsoleTheme.raisedSurface, in: Capsule())
                                .padding(.leading, 7)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.down")
                            .consoleFont(size: 11, weight: .semibold)
                            .foregroundStyle(ConsoleTheme.secondaryText)
                            .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
                    }
                    .padding(.leading, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(section.name), \(section.tasks.count) tasks")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

                Button(action: onNewTask) {
                    Image(systemName: "plus")
                        .consoleFont(size: 12, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.secondaryText)
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.isChat ? "Start a new chat" : "Start a new task in \(section.name)")
                .accessibilityLabel(section.isChat ? "New chat" : "New task in \(section.name)")

                if section.isChat {
                    Color.clear
                        .frame(width: 42, height: 34)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .consoleFont(size: 11, weight: .medium)
                        .foregroundStyle(ConsoleTheme.secondaryText.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                        .padding(.trailing, 8)
                        .help("Drag to reorder projects")
                        .accessibilityLabel("Drag \(section.name) to reorder projects")
                        .draggable(section.id) {
                            Label(section.name, systemImage: "folder")
                                .consoleFont(size: 13.5, weight: .medium)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .foregroundStyle(ConsoleTheme.primaryText)
                                .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .frame(height: 44)
            .background(
                isDropTarget ? ConsoleTheme.blue.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .dropDestination(for: String.self) { projectIDs, location in
                guard let sourceID = projectIDs.first else { return false }
                return onMoveProject(sourceID, section.id, location.y > 22)
            } isTargeted: { isTargeted in
                isDropTarget = isTargeted
            }

            if !isCollapsed {
                ForEach(section.tasks) { task in
                    TaskRow(
                        task: task,
                        isSelected: selectedTaskID == task.id,
                        isMonitored: isTaskMonitored(task.id),
                        onOpen: { onOpen(task) },
                        onHide: { onHide(task) },
                        onEnable: { onEnable(task) },
                        onArchive: { onArchive(task) },
                        onRename: { onRename(task.id, $0) }
                    )
                }
            }

            Rectangle()
                .fill(ConsoleTheme.divider)
                .frame(height: 1)
                .padding(.leading, 16)
        }
    }
}

private struct TaskRow: View {
    let task: CodexTask
    let isSelected: Bool
    let isMonitored: Bool
    let onOpen: () -> Void
    let onHide: () -> Void
    let onEnable: () -> Void
    let onArchive: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var isTitleHovered = false
    @State private var draftTitle = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            membershipButton

            Group {
                if task.status == .inactive {
                    Color.clear
                } else {
                    StatusIcon(status: task.status)
                }
            }
            .frame(width: 36)
            .padding(.leading, 3)
            .accessibilityHidden(task.status == .inactive)

            titleControl
                .padding(.leading, 8)

            if task.status != .inactive {
                StatusChip(status: task.status, workingSince: task.workingSince)
                    .padding(.leading, 8)
            }

            Button(action: onArchive) {
                Image(systemName: "archivebox")
                    .consoleFont(size: 12, weight: .medium)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                    .frame(width: 27, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("Archive task")
            .accessibilityLabel("Archive \(task.title)")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? ConsoleTheme.selectedFill : (isHovered ? Color.white.opacity(0.025) : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? ConsoleTheme.blue.opacity(0.17) : .clear)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ConsoleTheme.divider)
                .frame(height: 1)
                .padding(.leading, 62)
                .padding(.trailing, 16)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var titleControl: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isEditingTitle {
                TextField("Task title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .consoleFont(size: 15.5, weight: .light)
                    .foregroundStyle(ConsoleTheme.primaryText)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ConsoleTheme.blue.opacity(0.45)))
                    .focused($isTitleFocused)
                    .onSubmit(commitEditing)
                    .onExitCommand(perform: cancelEditing)
                    .onChange(of: isTitleFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused && isEditingTitle {
                            commitEditing()
                        }
                    }
                    .onDisappear {
                        if isEditingTitle {
                            commitEditing()
                        }
                    }
                    .accessibilityLabel("Edit title for \(task.title)")
            } else {
                HStack(spacing: 3) {
                    Button(action: onOpen) {
                        Text(task.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .consoleFont(size: 15.5, weight: .light)
                            .foregroundStyle(
                                isTitleHovered
                                    ? ConsoleTheme.blue
                                    : (isMonitored ? ConsoleTheme.primaryText : ConsoleTheme.secondaryText)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Codex")
                    .accessibilityLabel("Open \(task.title) in Codex")
                    .onHover { isTitleHovered = $0 }

                    Button(action: beginEditing) {
                        Image(systemName: "pencil")
                            .consoleFont(size: 11, weight: .medium)
                            .foregroundStyle(ConsoleTheme.secondaryText.opacity(isHovered ? 1 : 0.45))
                            .frame(width: 25, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Rename task")
                    .accessibilityLabel("Rename \(task.title)")
                }
            }

            TaskAgeLabel(createdAt: task.createdAt)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var membershipButton: some View {
        Button(action: isMonitored ? onHide : onEnable) {
            Image(systemName: isMonitored ? "pin.fill" : "pin")
                .consoleFont(size: 13, weight: .medium)
                .foregroundStyle(isMonitored ? ConsoleTheme.blue : ConsoleTheme.secondaryText)
                .frame(width: 25, height: 28)
        }
        .buttonStyle(.plain)
        .help(isMonitored ? "Remove from Console" : "Add to Console")
        .accessibilityLabel(
            isMonitored
                ? "Remove \(task.title) from Console"
                : "Add \(task.title) to Console"
        )
    }

    private func beginEditing() {
        draftTitle = task.title
        isEditingTitle = true
        Task { @MainActor in
            isTitleFocused = true
        }
    }

    private func commitEditing() {
        guard isEditingTitle else { return }
        let title = draftTitle
        isEditingTitle = false
        isTitleFocused = false
        onRename(title)
    }

    private func cancelEditing() {
        guard isEditingTitle else { return }
        draftTitle = task.title
        isEditingTitle = false
        isTitleFocused = false
    }
}

private struct TaskAgeLabel: View {
    let createdAt: Date

    var body: some View {
        let now = Date()
        TimelineView(
            .periodic(
                from: createdAt,
                by: TaskAge.refreshInterval(from: createdAt, to: now)
            )
        ) { context in
            let description = TaskAge.relativeDescription(from: createdAt, to: context.date)
            Text(description)
                .accessibilityLabel("Created \(description)")
        }
        .consoleFont(size: 10.5)
        .foregroundStyle(ConsoleTheme.secondaryText.opacity(0.85))
        .lineLimit(1)
        .help("Created \(createdAt.formatted(date: .long, time: .shortened))")
    }
}

private struct StatusIcon: View {
    let status: AttentionStatus

    private var symbol: String {
        switch status {
        case .waitingForInput, .waitingForPermission: "exclamationmark"
        case .error: "xmark"
        case .working: "arrow.triangle.2.circlepath"
        case .finished: "checkmark"
        case .inactive: "clock"
        }
    }

    var body: some View {
        let color = ConsoleTheme.color(for: status)
        ZStack {
            Circle().stroke(color.opacity(0.82), lineWidth: 1.4)
            Image(systemName: symbol)
                .consoleFont(size: status == .working ? 12 : 11, weight: .semibold)
                .foregroundStyle(color)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct StatusChip: View {
    let status: AttentionStatus
    let workingSince: Date?

    private var label: String {
        switch status {
        case .waitingForInput: "INPUT"
        case .waitingForPermission: "PERMISSION"
        case .error: "ERROR"
        case .working: "WORKING"
        case .finished: "FINISHED"
        case .inactive: "INACTIVE"
        }
    }

    var body: some View {
        let color = ConsoleTheme.color(for: status)
        HStack(spacing: 5) {
            Text(label)
            if status == .working, let workingSince {
                TimelineView(.periodic(from: workingSince, by: 1)) { context in
                    Text(TaskTimer.compactElapsed(from: workingSince, to: context.date))
                        .monospacedDigit()
                }
            }
        }
        .consoleFont(size: 12, weight: .semibold)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 23)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }
}
