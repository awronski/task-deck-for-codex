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

private struct ActionTooltipModifier: ViewModifier {
    let text: String
    let width: CGFloat?
    let lineLimit: Int
    let isEnabled: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isEnabled && isHovered {
                    Text(text)
                        .consoleFont(size: 11.5, weight: .medium)
                        .foregroundStyle(ConsoleTheme.primaryText)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(width: width, alignment: .leading)
                        .fixedSize(horizontal: width == nil, vertical: true)
                        .background(ConsoleTheme.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.14))
                        )
                        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                        .offset(y: -31)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onHover { isHovered = $0 }
            .zIndex(isEnabled && isHovered ? 1 : 0)
    }
}

private extension View {
    func actionTooltip(
        _ text: String,
        width: CGFloat? = nil,
        lineLimit: Int = 1,
        isEnabled: Bool
    ) -> some View {
        modifier(ActionTooltipModifier(
            text: text,
            width: width,
            lineLimit: lineLimit,
            isEnabled: isEnabled
        ))
    }
}

struct ReminderBanner: View {
    let reminder: TaskReminder
    let onOpen: () -> Void
    let onSnooze: (Date) -> Bool
    let onDismiss: () -> Void

    @State private var isSnoozePresented = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock")
                .consoleFont(size: 18, weight: .medium)
                .foregroundStyle(ConsoleTheme.blue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("REMINDER")
                    .consoleFont(size: 10, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.blue)
                    .tracking(0.35)
                Text(reminder.title)
                    .consoleFont(size: 14.5, weight: .medium)
                    .foregroundStyle(ConsoleTheme.primaryText)
                    .lineLimit(2)
                Text("Due \(reminder.dueAt.formatted(date: .omitted, time: .shortened))")
                    .consoleFont(size: 11.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)

                HStack(spacing: 8) {
                    Button("Open task", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button("Snooze…") {
                        isSnoozePresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $isSnoozePresented, arrowEdge: .top) {
                        ReminderScheduleEditor(
                            title: "Snooze reminder",
                            scheduledAt: nil,
                            actionTitle: "Snooze",
                            onSchedule: { date in
                                let didSnooze = onSnooze(date)
                                if didSnooze { isSnoozePresented = false }
                                return didSnooze
                            }
                        )
                    }

                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(ConsoleTheme.secondaryText)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .consoleFont(size: 11, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Dismiss reminder")
            .accessibilityLabel("Dismiss reminder for \(reminder.title)")
        }
        .padding(12)
        .background(ConsoleTheme.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ConsoleTheme.blue.opacity(0.32)))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

struct MissedRemindersView: View {
    let reminders: [TaskReminder]
    let onOpen: (TaskReminder) -> Void
    let onSnooze: (TaskReminder, Date) -> Bool
    let onDismiss: (TaskReminder) -> Void
    let onDismissAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missed reminders")
                        .consoleFont(size: 19, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.primaryText)
                    Text("These reminders became due while Task Deck was closed.")
                        .consoleFont(size: 12.5)
                        .foregroundStyle(ConsoleTheme.secondaryText)
                }
                Spacer(minLength: 12)
                Text("\(reminders.count)")
                    .consoleFont(size: 11, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.blue)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(ConsoleTheme.blue.opacity(0.12), in: Capsule())

                Button(action: onDismissAll) {
                    Image(systemName: "xmark")
                        .consoleFont(size: 11, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(ConsoleTheme.divider.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss all reminders")
            }
            .padding(18)

            Rectangle().fill(ConsoleTheme.divider).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(reminders) { reminder in
                        MissedReminderRow(
                            reminder: reminder,
                            onOpen: { onOpen(reminder) },
                            onSnooze: { onSnooze(reminder, $0) },
                            onDismiss: { onDismiss(reminder) }
                        )
                        if reminder.id != reminders.last?.id {
                            Rectangle()
                                .fill(ConsoleTheme.divider)
                                .frame(height: 1)
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(reminders.count) * 64, 420))

            Rectangle().fill(ConsoleTheme.divider).frame(height: 1)

            HStack {
                Spacer()
                Button("Dismiss all", action: onDismissAll)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let first = reminders.first {
                    Button("Open first task") { onOpen(first) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 330, idealWidth: 430, maxWidth: 430)
        .background(ConsoleTheme.background)
    }
}

private struct MissedReminderRow: View {
    let reminder: TaskReminder
    let onOpen: () -> Void
    let onSnooze: (Date) -> Bool
    let onDismiss: () -> Void

    @State private var isSnoozePresented = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock")
                .consoleFont(size: 16, weight: .medium)
                .foregroundStyle(ConsoleTheme.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .consoleFont(size: 13.5, weight: .medium)
                    .foregroundStyle(ConsoleTheme.primaryText)
                    .lineLimit(2)
                Text(reminder.dueAt.formatted(date: .abbreviated, time: .shortened))
                    .consoleFont(size: 11.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }

            Spacer(minLength: 8)

            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Snooze…") {
                isSnoozePresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isSnoozePresented, arrowEdge: .top) {
                ReminderScheduleEditor(
                    title: "Snooze reminder",
                    scheduledAt: nil,
                    actionTitle: "Snooze",
                    onSchedule: { date in
                        let didSnooze = onSnooze(date)
                        if didSnooze { isSnoozePresented = false }
                        return didSnooze
                    }
                )
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .consoleFont(size: 10, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Dismiss reminder")
            .accessibilityLabel("Dismiss reminder for \(reminder.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private enum ReminderScheduleMode: Equatable {
    case relative
    case exact
}

struct ReminderScheduleEditor: View {
    let title: String
    let scheduledAt: Date?
    let actionTitle: String
    let onSchedule: (Date) -> Bool
    var onRemove: (() -> Void)?

    @State private var relativeValue = 5
    @State private var relativeUnit = ReminderOffsetUnit.minutes
    @State private var exactDate = Date.now.addingTimeInterval(3_600)
    @State private var minimumDate = Date.now
    @State private var validationMessage: String?
    @State private var scheduleMode = ReminderScheduleMode.relative

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .consoleFont(size: 17, weight: .semibold)
                .foregroundStyle(ConsoleTheme.primaryText)

            if let scheduledAt {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CURRENT REMINDER")
                        .consoleFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.secondaryText)

                    HStack(spacing: 12) {
                        Label(
                            scheduledAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "clock"
                        )
                        .consoleFont(size: 14, weight: .medium)
                        .foregroundStyle(ConsoleTheme.blue)

                        Spacer(minLength: 8)

                        if let onRemove {
                            Button(action: onRemove) {
                                Image(systemName: "trash")
                                    .consoleFont(size: 13, weight: .medium)
                                    .foregroundStyle(ConsoleTheme.secondaryText)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        ConsoleTheme.raisedSurface,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(ConsoleTheme.divider)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Remove reminder")
                            .accessibilityLabel("Remove reminder")
                        }
                    }
                }

                Rectangle()
                    .fill(ConsoleTheme.divider)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(scheduleSectionTitle)
                    .consoleFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                Text(scheduleSectionDescription)
                    .consoleFont(size: 12)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }

            relativeScheduleCard
            exactScheduleCard

            if let validationMessage {
                Text(validationMessage)
                    .consoleFont(size: 11)
                    .foregroundStyle(ConsoleTheme.red)
            }

            Button(action: scheduleSelected) {
                Text(primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ConsoleTheme.blue)
            .disabled(scheduleMode == .relative && relativeValue < 1)
        }
        .padding(18)
        .frame(width: 430)
        .background(ConsoleTheme.surface)
        .onAppear {
            minimumDate = Date.now.addingTimeInterval(1)
            exactDate = max(scheduledAt ?? Date.now.addingTimeInterval(3_600), minimumDate)
        }
        .onChange(of: relativeValue) { _, value in
            relativeValue = min(max(value, 1), 99_999)
        }
    }

    private var scheduleSectionTitle: String {
        if scheduledAt != nil { return "REPLACE WITH" }
        if actionTitle == "Snooze" { return "SNOOZE UNTIL" }
        return "SET FOR"
    }

    private var scheduleSectionDescription: String {
        scheduledAt == nil
            ? "Choose one way to schedule this reminder."
            : "Choose one way to set the new reminder."
    }

    private var primaryActionTitle: String {
        "\(actionTitle) reminder"
    }

    private var relativeScheduleCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            scheduleModeLabel(
                mode: .relative,
                title: "After a delay",
                subtitle: "Relative to now"
            )

            HStack(spacing: 10) {
                TextField("Amount", value: $relativeValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)
                    .accessibilityLabel("Reminder amount")

                Picker("Unit", selection: $relativeUnit) {
                    Text("Minutes").tag(ReminderOffsetUnit.minutes)
                    Text("Hours").tag(ReminderOffsetUnit.hours)
                    Text("Days").tag(ReminderOffsetUnit.days)
                }
                .labelsHidden()
                .frame(width: 132)

                Spacer(minLength: 0)
            }
            .padding(.leading, 30)
            .allowsHitTesting(scheduleMode == .relative)
        }
        .padding(14)
        .background(cardBackground(for: .relative))
        .overlay(cardBorder(for: .relative))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { select(.relative) }
    }

    private var exactScheduleCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            scheduleModeLabel(
                mode: .exact,
                title: "On a date",
                subtitle: "Exact date and time"
            )

            DatePicker(
                "",
                selection: $exactDate,
                in: minimumDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)
            .allowsHitTesting(scheduleMode == .exact)
        }
        .padding(14)
        .background(cardBackground(for: .exact))
        .overlay(cardBorder(for: .exact))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { select(.exact) }
    }

    private func scheduleModeLabel(
        mode: ReminderScheduleMode,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button { select(mode) } label: {
                Image(systemName: scheduleMode == mode ? "record.circle" : "circle")
                    .consoleFont(size: 18, weight: .medium)
                    .foregroundStyle(
                        scheduleMode == mode ? ConsoleTheme.blue : ConsoleTheme.secondaryText
                    )
                    .frame(width: 19, height: 19)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(title.lowercased())")
            .accessibilityValue(scheduleMode == mode ? "Selected" : "Not selected")

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .consoleFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.primaryText)
                Text(subtitle)
                    .consoleFont(size: 11.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }
        }
    }

    private func cardBackground(for mode: ReminderScheduleMode) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                scheduleMode == mode
                    ? ConsoleTheme.blue.opacity(0.045)
                    : ConsoleTheme.raisedSurface
            )
    }

    private func cardBorder(for mode: ReminderScheduleMode) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(
                scheduleMode == mode ? ConsoleTheme.blue : ConsoleTheme.divider,
                lineWidth: scheduleMode == mode ? 1.5 : 1
            )
    }

    private func select(_ mode: ReminderScheduleMode) {
        scheduleMode = mode
        validationMessage = nil
    }

    private func scheduleSelected() {
        switch scheduleMode {
        case .relative:
            scheduleRelative()
        case .exact:
            scheduleExact()
        }
    }

    private func scheduleRelative() {
        guard let date = relativeUnit.date(after: .now, value: relativeValue),
              onSchedule(date)
        else {
            validationMessage = "Choose a future time."
            return
        }
        validationMessage = nil
    }

    private func scheduleExact() {
        guard onSchedule(exactDate) else {
            validationMessage = "Choose a future time."
            return
        }
        validationMessage = nil
    }
}

struct ProjectSectionView: View {
    let section: ProjectSection
    let appearance: ProjectAppearance
    let isCollapsed: Bool
    let expandedTaskIDs: Set<String>
    let allowsProjectReordering: Bool
    let isTaskMonitored: (String) -> Bool
    let isArchivePending: (String) -> Bool
    let onToggle: () -> Void
    let onOpen: (CodexTask) -> Void
    let onHide: (CodexTask) -> Void
    let onEnable: (CodexTask) -> Void
    let onArchive: (CodexTask) -> Void
    let onNewTask: () -> Void
    let onMoveProject: (String, String, Bool) -> Bool
    let onRename: (String, String) -> Void
    let onSetPriority: (String, TaskPriority) -> Void
    let noteForTask: (String) -> String
    let onSetNote: (String, String) -> Void
    let reminderForTask: (String) -> TaskReminder?
    let onSetReminder: (String, String, Date) -> Bool
    let onRemoveReminder: (String) -> Void
    let onTogglePreview: (String) -> Void
    let onSetAppearance: (ProjectAppearance) -> Void

    @State private var isDropTarget = false
    @State private var isShowingAppearancePicker = false

    private var accent: Color {
        section.isChat ? ConsoleTheme.teal : ConsoleTheme.color(for: section.highestPriorityStatus)
    }

    private var identityColor: Color {
        section.isChat ? ConsoleTheme.teal : ProjectAppearanceCatalog.color(for: appearance.colorID)
    }

    private var displayedProjectName: String {
        appearance.displayName ?? section.name
    }

    private var identityIconTile: some View {
        ZStack {
            if appearance.usesBackgroundColor {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [identityColor.opacity(0.78), identityColor.opacity(0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(appearance.usesBackgroundColor ? Color.white.opacity(0.18) : ConsoleTheme.divider)

            Image(systemName: appearance.iconName)
                .consoleFont(size: 15, weight: .medium)
                .foregroundStyle(
                    appearance.usesBackgroundColor
                        ? Color.white
                        : ConsoleTheme.primaryText.opacity(0.82)
                )
        }
        .frame(width: 32, height: 32)
    }

    private var headerBackground: some View {
        ZStack {
            if !section.isChat, appearance.usesBackgroundColor {
                LinearGradient(
                    stops: [
                        .init(color: identityColor.opacity(0.30), location: 0),
                        .init(color: identityColor.opacity(0.14), location: 0.34),
                        .init(color: .clear, location: 0.82)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }

            if isDropTarget {
                ConsoleTheme.blue.opacity(0.10)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 2, height: 22)
                    .padding(.leading, 16)
                    .padding(.trailing, 10)

                if section.isChat {
                    Image(systemName: "bubble.left")
                        .consoleFont(size: 15, weight: .medium)
                        .foregroundStyle(ConsoleTheme.teal)
                        .frame(width: 32, height: 32)
                } else {
                    Button {
                        isShowingAppearancePicker = true
                    } label: {
                        identityIconTile
                    }
                    .buttonStyle(.plain)
                    .help("Customize \(displayedProjectName)")
                    .accessibilityLabel("Customize \(displayedProjectName) name, icon, and color")
                    .popover(isPresented: $isShowingAppearancePicker, arrowEdge: .leading) {
                        ProjectAppearancePicker(
                            projectName: section.name,
                            appearance: appearance,
                            onChange: onSetAppearance
                        )
                    }
                }

                Button(action: onToggle) {
                    HStack(spacing: 0) {
                        Text(displayedProjectName)
                            .consoleFont(size: 17.5, weight: .medium)
                            .foregroundStyle(ConsoleTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 10)

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
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(displayedProjectName), \(section.tasks.count) tasks")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

                Button(action: onNewTask) {
                    Image(systemName: "plus")
                        .consoleFont(size: 12, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.secondaryText)
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.isChat ? "Start a new chat" : "Start a new task in \(displayedProjectName)")
                .accessibilityLabel(section.isChat ? "New chat" : "New task in \(displayedProjectName)")

                if section.isChat || !allowsProjectReordering {
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
                        .accessibilityLabel("Drag \(displayedProjectName) to reorder projects")
                        .draggable(section.id) {
                            Label(displayedProjectName, systemImage: appearance.iconName)
                                .consoleFont(size: 13.5, weight: .medium)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .foregroundStyle(ConsoleTheme.primaryText)
                                .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .frame(height: 44)
            .background(headerBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        section.isChat || !appearance.usesBackgroundColor
                            ? ConsoleTheme.divider
                            : identityColor.opacity(0.76)
                    )
                    .frame(height: 1)
            }
            .dropDestination(for: String.self) { projectIDs, location in
                guard allowsProjectReordering, let sourceID = projectIDs.first else { return false }
                return onMoveProject(sourceID, section.id, location.y > 22)
            } isTargeted: { isTargeted in
                isDropTarget = allowsProjectReordering && isTargeted
            }

            if !isCollapsed, !section.tasks.isEmpty {
                ForEach(section.tasks) { task in
                    TaskRow(
                        task: task,
                        isPreviewExpanded: expandedTaskIDs.contains(task.id),
                        isMonitored: isTaskMonitored(task.id),
                        isArchivePending: isArchivePending(task.id),
                        onOpen: { onOpen(task) },
                        onHide: { onHide(task) },
                        onEnable: { onEnable(task) },
                        onArchive: { onArchive(task) },
                        onRename: { onRename(task.id, $0) },
                        onSetPriority: { onSetPriority(task.id, $0) },
                        note: noteForTask(task.id),
                        onSetNote: { onSetNote(task.id, $0) },
                        reminder: reminderForTask(task.id),
                        onSetReminder: { onSetReminder(task.id, task.title, $0) },
                        onRemoveReminder: { onRemoveReminder(task.id) },
                        onTogglePreview: { onTogglePreview(task.id) }
                    )

                    if task.id != section.tasks.last?.id {
                        Rectangle()
                            .fill(ConsoleTheme.divider)
                            .frame(height: 1)
                            .padding(.leading, 62)
                            .padding(.trailing, 16)
                    }
                }
            }
        }
        .background(
            ConsoleTheme.raisedSurface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12))
        )
    }
}

private struct TaskRow: View {
    let task: CodexTask
    let isPreviewExpanded: Bool
    let isMonitored: Bool
    let isArchivePending: Bool
    let onOpen: () -> Void
    let onHide: () -> Void
    let onEnable: () -> Void
    let onArchive: () -> Void
    let onRename: (String) -> Void
    let onSetPriority: (TaskPriority) -> Void
    let note: String
    let onSetNote: (String) -> Void
    let reminder: TaskReminder?
    let onSetReminder: (Date) -> Bool
    let onRemoveReminder: () -> Void
    let onTogglePreview: () -> Void

    @AppStorage("showTaskModelDetails") private var showTaskModelDetails = false
    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var isTitleHovered = false
    @State private var isFlagPickerPresented = false
    @State private var isNoteEditorPresented = false
    @State private var isReminderEditorPresented = false
    @State private var draftTitle = ""
    @State private var draftNote = ""
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isNoteFocused: Bool

    private var canPreview: Bool {
        task.status != .inactive && task.activity != nil
    }

    private var modelDetails: String? {
        guard showTaskModelDetails else { return nil }
        let values = [task.modelName, task.thinkingEffort].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            rowHeader

            if isPreviewExpanded, let activity = task.activity {
                ActivityPreviewPanel(task: task, activity: activity, onOpen: onOpen)
                    .padding(.leading, 72)
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(rowStroke)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var rowHeader: some View {
        HStack(spacing: 0) {
            membershipButton

            Rectangle()
                .fill(ConsoleTheme.divider)
                .frame(width: 1, height: 76)

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

            VStack(alignment: .leading, spacing: 2) {
                titleControl
                    .frame(height: 28)
                    .padding(.trailing, 16)

                HStack(spacing: 8) {
                    TaskAgeLabel(createdAt: task.createdAt)

                    if task.status != .inactive {
                        StatusChip(status: task.status, workingSince: task.workingSince)
                            .fixedSize()
                    }

                    if let modelDetails {
                        Text(modelDetails)
                            .consoleFont(size: 11.5, weight: .medium)
                            .foregroundStyle(ConsoleTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(modelDetails)
                            .accessibilityLabel("Model and thinking effort: \(modelDetails)")
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        previewDisclosureButton

                        if isEditingTitle {
                            Color.clear.frame(width: 75, height: 26)
                        } else {
                            reminderButton
                            editButton
                            flagPickerButton
                        }

                        noteButton
                        archiveButton
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 36)
                    .background(
                        ConsoleTheme.surface,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.14))
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 36)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 76)
    }

    private var rowFill: Color {
        if isPreviewExpanded { return ConsoleTheme.color(for: task.status).opacity(0.055) }
        if isHovered { return Color.white.opacity(0.025) }
        return .clear
    }

    private var rowStroke: Color {
        if isPreviewExpanded { return ConsoleTheme.color(for: task.status).opacity(0.20) }
        return .clear
    }

    private var previewDisclosureButton: some View {
        Group {
            if canPreview {
                Button(action: onTogglePreview) {
                    Image(systemName: "chevron.right")
                        .consoleFont(size: 10, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.secondaryText)
                        .rotationEffect(isPreviewExpanded ? .degrees(90) : .zero)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPreviewExpanded ? "Hide activity" : "Show activity")
                .accessibilityLabel(
                    "\(isPreviewExpanded ? "Hide" : "Show") activity for \(task.title)"
                )
                .accessibilityValue(isPreviewExpanded ? "Expanded" : "Collapsed")
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var titleControl: some View {
        Group {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var archiveButton: some View {
        Button(action: onArchive) {
            Image(systemName: isArchivePending ? "clock" : "archivebox")
                .consoleFont(size: 13.5, weight: .medium)
                .foregroundStyle(isArchivePending ? ConsoleTheme.blue : ConsoleTheme.secondaryText)
                .frame(width: 27, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .help(isArchivePending ? "Cancel queued archive" : "Archive task")
        .accessibilityLabel(
            isArchivePending ? "Cancel queued archive of \(task.title)" : "Archive \(task.title)"
        )
    }

    private var flagPickerButton: some View {
        Button {
            isFlagPickerPresented.toggle()
        } label: {
            flagIcon(for: task.priority)
                .frame(width: 25, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isFlagPickerPresented, arrowEdge: .bottom) {
            HStack(spacing: 4) {
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    Button {
                        onSetPriority(priority)
                        isFlagPickerPresented = false
                    } label: {
                        flagIcon(for: priority)
                            .frame(width: 30, height: 30)
                            .background(
                                task.priority == priority
                                    ? ConsoleTheme.blue.opacity(0.12)
                                    : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(priority.title)
                    .accessibilityLabel(priority.title)
                }
            }
            .padding(8)
        }
        .help(task.priority.title)
        .accessibilityLabel("Set flag for \(task.title)")
        .accessibilityValue(task.priority.title)
    }

    private var reminderButton: some View {
        Button {
            isReminderEditorPresented = true
        } label: {
            Image(systemName: "clock")
                .consoleFont(size: 14, weight: .medium)
                .foregroundStyle(
                    reminder == nil
                        ? ConsoleTheme.secondaryText.opacity(isHovered ? 1 : 0.55)
                        : ConsoleTheme.blue
                )
                .frame(width: 25, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isReminderEditorPresented, arrowEdge: .bottom) {
            ReminderScheduleEditor(
                title: reminder == nil ? "Set reminder" : "Change reminder",
                scheduledAt: reminder?.dueAt,
                actionTitle: reminder == nil ? "Set" : "Replace",
                onSchedule: { date in
                    let didSchedule = onSetReminder(date)
                    if didSchedule { isReminderEditorPresented = false }
                    return didSchedule
                },
                onRemove: reminder.map { _ in
                    {
                        onRemoveReminder()
                        isReminderEditorPresented = false
                    }
                }
            )
        }
        .actionTooltip(reminderHelp, isEnabled: !isReminderEditorPresented)
        .frame(width: 25, height: 26)
        .accessibilityLabel(
            reminder == nil
                ? "Set reminder for \(task.title)"
                : "Change reminder for \(task.title)"
        )
        .accessibilityValue(
            reminder.map { $0.dueAt.formatted(date: .abbreviated, time: .shortened) }
                ?? "No reminder"
        )
    }

    private var reminderHelp: String {
        guard let reminder else { return "Set reminder" }
        return "Reminder \(reminder.dueAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var noteButton: some View {
        Button {
            draftNote = note
            isNoteEditorPresented = true
        } label: {
            Image(systemName: "note.text")
                .consoleFont(size: 15, weight: .medium)
                .foregroundStyle(
                    note.isEmpty
                        ? ConsoleTheme.secondaryText.opacity(isHovered ? 1 : 0.55)
                        : ConsoleTheme.blue
                )
                .frame(width: 25, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isNoteEditorPresented, arrowEdge: .bottom) {
            noteEditor
        }
        .actionTooltip(
            note.isEmpty ? "Add note" : note,
            width: note.isEmpty ? nil : 260,
            lineLimit: note.isEmpty ? 1 : 3,
            isEnabled: !isNoteEditorPresented
        )
        .frame(width: 25, height: 26)
        .accessibilityLabel("\(noteActionTitle) note for \(task.title)")
        .accessibilityValue(note.isEmpty ? "No note" : "Note added")
    }

    private var noteActionTitle: String {
        note.isEmpty ? "Add" : "Edit"
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Task note")
                    .consoleFont(size: 14.5, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.primaryText)
                Text(task.title)
                    .consoleFont(size: 11.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                    .lineLimit(1)
            }

            TextEditor(text: $draftNote)
                .consoleFont(size: 13)
                .foregroundStyle(ConsoleTheme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(width: 292, height: 104)
                .background(ConsoleTheme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(ConsoleTheme.divider)
                )
                .overlay(alignment: .topLeading) {
                    if draftNote.isEmpty {
                        Text("What should you remember before continuing?")
                            .consoleFont(size: 13)
                            .foregroundStyle(ConsoleTheme.secondaryText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isNoteFocused)
                .accessibilityLabel("Note for \(task.title)")
                .onChange(of: draftNote) { _, newValue in
                    if newValue.count > 2_000 {
                        draftNote = String(newValue.prefix(2_000))
                    } else {
                        onSetNote(newValue)
                    }
                }

            HStack {
                Button("Clear") {
                    draftNote = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(draftNote.isEmpty ? ConsoleTheme.secondaryText : ConsoleTheme.red)
                .disabled(draftNote.isEmpty)

                Spacer()

                Button("Done") {
                    isNoteEditorPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(ConsoleTheme.surface)
        .onAppear {
            draftNote = note
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard isNoteEditorPresented else { return }
                isNoteFocused = true
            }
        }
    }

    private var editButton: some View {
        Button(action: beginEditing) {
            Image(systemName: "pencil")
                .consoleFont(size: 13, weight: .medium)
                .foregroundStyle(ConsoleTheme.secondaryText.opacity(isHovered ? 1 : 0.45))
                .frame(width: 25, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename task")
        .accessibilityLabel("Rename \(task.title)")
    }

    private func flagIcon(for priority: TaskPriority) -> some View {
        Image(systemName: priority == .none ? "flag" : "flag.fill")
            .consoleFont(size: 13.5, weight: .medium)
            .foregroundStyle(priority.color)
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

private struct ActivityPreviewPanel: View {
    let task: CodexTask
    let activity: TaskActivityPreview
    let onOpen: () -> Void

    private var color: Color {
        ConsoleTheme.color(for: task.status)
    }

    private var heading: String {
        switch task.status {
        case .working: "Current activity"
        case .waitingForInput: "Input needed"
        case .waitingForPermission: "Permission request"
        case .finished: "Completed"
        case .error: "Error"
        case .inactive: "Activity"
        }
    }

    private var actionTitle: String {
        switch task.status {
        case .waitingForInput: "Reply in Codex"
        case .waitingForPermission: "Review in Codex"
        case .working, .finished, .error, .inactive: "Open in Codex"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(ConsoleTheme.divider)
                .frame(height: 1)

            Text(heading.uppercased())
                .consoleFont(size: 10.5, weight: .semibold)
                .foregroundStyle(color)
                .tracking(0.35)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 10) {
                statusGraphic
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text(activity.headline)
                        .consoleFont(size: 13.5)
                        .foregroundStyle(ConsoleTheme.primaryText)
                        .lineLimit(task.status == .finished ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = activity.detail, !detail.isEmpty {
                        Text(detail)
                            .consoleFont(size: 11.5)
                            .foregroundStyle(ConsoleTheme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    timingLabel
                }
            }
            .padding(.top, 8)

            if !activity.recentEvents.isEmpty {
                Rectangle()
                    .fill(ConsoleTheme.divider)
                    .frame(height: 1)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(activity.recentEvents.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: eventSymbol)
                                .consoleFont(size: 8, weight: .semibold)
                                .foregroundStyle(color)
                                .frame(width: 12)
                            Text(event.title)
                                .consoleFont(size: 11.5)
                                .foregroundStyle(ConsoleTheme.primaryText.opacity(0.88))
                                .lineLimit(1)
                        }
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                            .consoleFont(size: 10.5, weight: .semibold)
                        Text(actionTitle)
                    }
                    .consoleFont(size: 11.5, weight: .medium)
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(color.opacity(0.24))
                    )
                }
                .buttonStyle(.plain)
                .help("\(actionTitle) — activity is read-only in Task Deck")
                .accessibilityLabel("\(actionTitle) for \(task.title); activity is read-only in Task Deck")
            }
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var statusGraphic: some View {
        if task.status == .working {
            ProgressView()
                .controlSize(.small)
                .tint(color)
        } else {
            Image(systemName: statusSymbol)
                .consoleFont(size: 13, weight: .semibold)
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var timingLabel: some View {
        switch task.status {
        case .working:
            if let workingSince = task.workingSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Active for \(TaskTimer.compactElapsed(from: workingSince, to: context.date))")
                }
                .consoleFont(size: 10.5)
                .foregroundStyle(ConsoleTheme.secondaryText)
            }
        case .waitingForInput:
            Text("Reply in Codex to continue.")
                .consoleFont(size: 10.5)
                .foregroundStyle(ConsoleTheme.secondaryText)
        case .waitingForPermission:
            Text("Review this request in Codex.")
                .consoleFont(size: 10.5)
                .foregroundStyle(ConsoleTheme.secondaryText)
        case .finished:
            if let finishedAt = task.finishedAt {
                TimelineView(
                    .periodic(
                        from: .now,
                        by: TaskAge.refreshInterval(from: finishedAt, to: .now)
                    )
                ) { context in
                    Text("Finished \(TaskAge.relativeDescription(from: finishedAt, to: context.date))")
                }
                .consoleFont(size: 10.5)
                .foregroundStyle(ConsoleTheme.secondaryText)
            }
        case .error:
            Text("Open Codex for full details.")
                .consoleFont(size: 10.5)
                .foregroundStyle(ConsoleTheme.secondaryText)
        case .inactive:
            EmptyView()
        }
    }

    private var statusSymbol: String {
        switch task.status {
        case .waitingForInput, .waitingForPermission: "exclamationmark.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .working: "circle"
        case .inactive: "circle"
        }
    }

    private var eventSymbol: String {
        switch task.status {
        case .finished: "checkmark.circle"
        case .error: "exclamationmark.circle"
        case .working, .waitingForInput, .waitingForPermission, .inactive: "circle.fill"
        }
    }
}

private extension TaskPriority {
    var color: Color {
        switch self {
        case .none: ConsoleTheme.secondaryText
        case .blue: ConsoleTheme.blue
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: ConsoleTheme.red
        }
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
