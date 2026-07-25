import AppKit
import CodexCompanionCore
import SwiftUI

struct AttentionConsoleView: View {
    let console: AttentionConsole

    private enum UndoOperation: Equatable {
        case consoleRemoval
        case archive
    }

    private struct UndoNotice {
        let taskID: String
        let title: String
        let operation: UndoOperation
        let token: UUID
    }

    @State private var searchText = ""
    @State private var selectedProjectIDs: Set<String> = []
    @State private var selectedStatuses: Set<AttentionStatus> = []
    @State private var collapsedProjects: Set<String> = []
    @State private var expandedTaskIDs: Set<String> = []
    @State private var isShowingLibrary = false
    @State private var isShowingFilters = false
    @State private var undoNotice: UndoNotice?

    private let launcher = CodexDeepLinkLauncher()

    private var sourceTasks: [CodexTask] {
        isShowingLibrary ? console.allTasks : console.monitoredTasks
    }

    private var sections: [ProjectSection] {
        ProjectOrdering.applying(
            console.projectOrderIDs,
            to: TaskGrouping.sections(
                from: sourceTasks,
                includingEmptyProjects: console.projects.filter(\.isChat),
                matching: searchText,
                projectIDs: selectedProjectIDs,
                statuses: selectedStatuses
            )
        )
    }

    private var projectOptions: [ProjectIdentity] {
        console.projects.sorted {
            if $0.isChat != $1.isChat {
                return !$0.isChat
            }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }
    }

    private var availableProjectIDs: Set<String> {
        Set(console.projects.map(\.key))
    }

    private var visiblePreviewTaskIDs: Set<String> {
        Set(
            sections
                .filter { !collapsedProjects.contains($0.id) }
                .flatMap(\.tasks)
                .filter { $0.status != .inactive && $0.activity != nil }
                .map(\.id)
        )
    }

    private var availablePreviewTaskIDs: Set<String> {
        Set(
            console.allTasks
                .filter { $0.status != .inactive && $0.activity != nil }
                .map(\.id)
        )
    }

    private var areAllVisiblePreviewsExpanded: Bool {
        !visiblePreviewTaskIDs.isEmpty
            && visiblePreviewTaskIDs.isSubset(of: expandedTaskIDs)
    }

    /// The complete current project order, including projects whose tasks are hidden by
    /// the current mode or filters. Keeping this complete prevents a visible drag from
    /// silently deleting hidden or empty projects from the persisted order.
    private var completeProjectOrderIDs: [String] {
        let projectsByID = Dictionary(uniqueKeysWithValues: console.projects.map { ($0.key, $0) })
        var seen: Set<String> = []
        var orderedIDs = console.projectOrderIDs.filter {
            projectsByID[$0] != nil && seen.insert($0).inserted
        }

        for project in console.projects where seen.insert(project.key).inserted {
            orderedIDs.append(project.key)
        }

        let chatIDs = orderedIDs.filter { projectsByID[$0]?.isChat == true }
        orderedIDs.removeAll { projectsByID[$0]?.isChat == true }
        orderedIDs.append(contentsOf: chatIDs)
        return orderedIDs
    }

    private var activeFilterCount: Int {
        selectedProjectIDs.count
            + selectedStatuses.count
            + console.includedTaskKinds.symmetricDifference(CodexTaskKind.defaultVisible).count
    }

    private var hasFilterCriteria: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activeFilterCount > 0
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !selectedProjectIDs.isEmpty {
            parts.append("\(selectedProjectIDs.count) project\(selectedProjectIDs.count == 1 ? "" : "s")")
        }
        if !selectedStatuses.isEmpty {
            parts.append("\(selectedStatuses.count) status\(selectedStatuses.count == 1 ? "" : "es")")
        }
        if console.includedTaskKinds != CodexTaskKind.defaultVisible {
            parts.append("task types customized")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                controlRow(width: geometry.size.width)
                Rectangle().fill(ConsoleTheme.divider).frame(height: 1)

                if let error = console.errorMessage, !console.allTasks.isEmpty {
                    ErrorStrip(message: error)
                }

                if let reminder = console.currentTriggeredReminder {
                    ReminderBanner(
                        reminder: reminder,
                        onOpen: { open(reminder) },
                        onSnooze: { console.snooze(reminder, until: $0) },
                        onDismiss: { console.dismissReminder(reminder) }
                    )
                    Rectangle().fill(ConsoleTheme.divider).frame(height: 1)
                }

                taskContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle().fill(ConsoleTheme.divider).frame(height: 1)
                if let undoNotice {
                    undoBar(for: undoNotice)
                    Rectangle().fill(ConsoleTheme.divider).frame(height: 1)
                }
                consoleFooter
            }
            .background(background)
            .overlay(
                WindowConfiguration(title: "Task Deck for Codex")
                    .allowsHitTesting(false)
            )
        }
        .overlay {
            if !console.missedReminders.isEmpty {
                ZStack {
                    Color.black.opacity(0.62)
                        .ignoresSafeArea()

                    MissedRemindersView(
                        reminders: console.missedReminders,
                        onOpen: open,
                        onSnooze: { console.snooze($0, until: $1) },
                        onDismiss: console.dismissReminder,
                        onDismissAll: console.dismissAllMissedReminders
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(ConsoleTheme.divider)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    .padding(16)
                }
            }
        }
        .onAppear { console.start() }
        .onDisappear { console.stop() }
        .onChange(of: console.reminderSoundSequence) { _, _ in
            playReminderSound()
        }
        .onChange(of: availableProjectIDs) { _, availableIDs in
            selectedProjectIDs.formIntersection(availableIDs)
            pruneProjectOrder(to: availableIDs)
        }
        .onChange(of: availablePreviewTaskIDs) { _, availableTaskIDs in
            expandedTaskIDs.formIntersection(availableTaskIDs)
        }
    }

    private var background: some View {
        ZStack {
            ConsoleTheme.background
            LinearGradient(
                colors: [Color.white.opacity(0.035), .clear, Color.black.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func controlRow(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            SearchField(text: $searchText)
                .frame(maxWidth: .infinity)
            activityExpansionButton
            filterButton(showSummary: width >= 430)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ConsoleTheme.surface)
    }

    private func filterButton(showSummary: Bool) -> some View {
        Button {
            isShowingFilters.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(showSummary && activeFilterCount > 0 ? filterSummary : "Filters")
                    .lineLimit(1)
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .consoleFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(ConsoleTheme.blue)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(ConsoleTheme.blue.opacity(0.12), in: Capsule())
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.down")
                    .consoleFont(size: 10, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }
            .consoleFont(size: 14, weight: .medium)
            .foregroundStyle(ConsoleTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ConsoleTheme.divider))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(activeFilterCount == 0 ? "Filter tasks" : filterSummary)
        .accessibilityLabel("Filters")
        .accessibilityValue(activeFilterCount == 0 ? "No filters selected" : filterSummary)
        .popover(isPresented: $isShowingFilters, arrowEdge: .top) {
            filterPopover
        }
    }

    private var activityExpansionButton: some View {
        Button(action: toggleAllPreviews) {
            HStack(spacing: 6) {
                Image(systemName: areAllVisiblePreviewsExpanded ? "chevron.up.2" : "chevron.down.2")
                    .consoleFont(size: 9.5, weight: .semibold)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                Text(areAllVisiblePreviewsExpanded ? "Collapse all" : "Expand all")
                    .lineLimit(1)
            }
            .consoleFont(size: 12.5, weight: .medium)
            .foregroundStyle(ConsoleTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ConsoleTheme.divider))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(visiblePreviewTaskIDs.isEmpty)
        .opacity(visiblePreviewTaskIDs.isEmpty ? 0.5 : 1)
        .help(
            visiblePreviewTaskIDs.isEmpty
                ? "No visible activity previews"
                : (areAllVisiblePreviewsExpanded ? "Collapse all visible activity previews" : "Expand all visible activity previews")
        )
        .accessibilityLabel(
            areAllVisiblePreviewsExpanded
                ? "Collapse all visible activity previews"
                : "Expand all visible activity previews"
        )
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filters")
                    .consoleFont(size: 15, weight: .semibold)
                Spacer()
                Button("Clear filters", action: clearFilters)
                    .buttonStyle(.plain)
                    .foregroundStyle(activeFilterCount == 0 ? ConsoleTheme.secondaryText : ConsoleTheme.blue)
                    .disabled(activeFilterCount == 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            Rectangle().fill(ConsoleTheme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    filterSectionTitle("Task Types")
                    ForEach(CodexTaskKind.allCases, id: \.self) { kind in
                        Toggle(isOn: taskKindSelection(for: kind)) {
                            Label(taskKindTitle(kind), systemImage: taskKindSymbol(kind))
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 4)
                    }

                    Rectangle()
                        .fill(ConsoleTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 8)

                    filterSectionTitle("Projects")
                    ForEach(projectOptions) { project in
                        Toggle(isOn: projectSelection(for: project.key)) {
                            Label(
                                project.name,
                                systemImage: project.isChat ? "bubble.left" : "folder"
                            )
                            .lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 4)
                    }

                    Rectangle()
                        .fill(ConsoleTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 8)

                    filterSectionTitle("Status")
                    ForEach(filterStatuses, id: \.self) { status in
                        Toggle(isOn: statusSelection(for: status)) {
                            HStack(spacing: 7) {
                                Image(systemName: statusSymbol(status))
                                    .foregroundStyle(ConsoleTheme.color(for: status))
                                    .frame(width: 16)
                                Text(statusTitle(status))
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 520)

            Rectangle().fill(ConsoleTheme.divider).frame(height: 1)
            Text(activeFilterCount == 0 ? "Default task types · All projects · All statuses" : filterSummary)
                .consoleFont(size: 11.5)
                .foregroundStyle(ConsoleTheme.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 34)
        }
        .frame(width: 300)
        .background(ConsoleTheme.surface)
    }

    private func filterSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .consoleFont(size: 10.5, weight: .semibold)
            .foregroundStyle(ConsoleTheme.secondaryText)
            .padding(.top, 12)
            .padding(.bottom, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private var filterStatuses: [AttentionStatus] {
        [.working, .waitingForInput, .waitingForPermission, .error, .finished]
    }

    private func projectSelection(for id: String) -> Binding<Bool> {
        Binding {
            selectedProjectIDs.contains(id)
        } set: { isSelected in
            if isSelected {
                selectedProjectIDs.insert(id)
            } else {
                selectedProjectIDs.remove(id)
            }
        }
    }

    private func statusSelection(for status: AttentionStatus) -> Binding<Bool> {
        Binding {
            selectedStatuses.contains(status)
        } set: { isSelected in
            if isSelected {
                selectedStatuses.insert(status)
            } else {
                selectedStatuses.remove(status)
            }
        }
    }

    private func taskKindSelection(for kind: CodexTaskKind) -> Binding<Bool> {
        Binding {
            console.includedTaskKinds.contains(kind)
        } set: { isSelected in
            var includedTaskKinds = console.includedTaskKinds
            if isSelected {
                includedTaskKinds.insert(kind)
            } else {
                includedTaskKinds.remove(kind)
            }
            console.setIncludedTaskKinds(includedTaskKinds)
        }
    }

    private func clearFilters() {
        selectedProjectIDs.removeAll()
        selectedStatuses.removeAll()
        console.setIncludedTaskKinds(CodexTaskKind.defaultVisible)
    }

    private func taskKindTitle(_ kind: CodexTaskKind) -> String {
        switch kind {
        case .regular: "Regular tasks"
        case .automation: "Automations"
        case .agent: "Agents"
        case .batch: "Batch CLI tasks"
        case .unassigned: "Legacy unassigned"
        }
    }

    private func taskKindSymbol(_ kind: CodexTaskKind) -> String {
        switch kind {
        case .regular: "person"
        case .automation: "gearshape.2"
        case .agent: "person.2"
        case .batch: "terminal"
        case .unassigned: "questionmark.folder"
        }
    }

    private func statusTitle(_ status: AttentionStatus) -> String {
        switch status {
        case .working: "Working"
        case .waitingForInput: "Waiting for input"
        case .waitingForPermission: "Waiting for permission"
        case .error: "Error"
        case .finished: "Finished"
        case .inactive: "Inactive"
        }
    }

    private func statusSymbol(_ status: AttentionStatus) -> String {
        switch status {
        case .working: "arrow.triangle.2.circlepath"
        case .waitingForInput, .waitingForPermission: "exclamationmark.circle"
        case .error: "xmark.circle"
        case .finished: "checkmark.circle"
        case .inactive: "clock"
        }
    }

    private var newTaskMenu: some View {
        Menu {
            Button {
                launcher.startChat()
            } label: {
                Label("New Chat", systemImage: "bubble.left")
            }

            let projects = projectOptions.filter { !$0.isChat }
            if !projects.isEmpty {
                Divider()
                ForEach(projects) { project in
                    Button(project.name) {
                        launcher.startTask(projectPath: project.path)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .consoleFont(size: 17, weight: .medium)
                .foregroundStyle(ConsoleTheme.primaryText)
                .frame(width: 34, height: 34)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 34, height: 34)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.22)))
        .help("Start a new task")
        .accessibilityLabel("New task")
    }

    @ViewBuilder
    private var taskContent: some View {
        if console.isRefreshing && console.lastUpdated == nil {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Reading Codex tasks…")
                    .consoleFont(size: 13)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = console.errorMessage, console.allTasks.isEmpty {
            ContentUnavailableView {
                Label("Codex tasks unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await console.refresh() } }
            }
        } else if sections.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(sections) { section in
                        ProjectSectionView(
                            section: section,
                            isCollapsed: collapsedProjects.contains(section.id),
                            expandedTaskIDs: expandedTaskIDs,
                            isTaskMonitored: console.isMonitored,
                            onToggle: { toggle(section.id) },
                            onOpen: open,
                            onHide: removeFromConsole,
                            onEnable: addToConsole,
                            onArchive: archive,
                            onNewTask: { startTask(in: section) },
                            onMoveProject: moveProject,
                            onRename: { taskID, title in
                                console.setTitle(title, for: taskID)
                            },
                            onSetPriority: { taskID, priority in
                                console.setPriority(priority, for: taskID)
                            },
                            noteForTask: console.note,
                            onSetNote: { taskID, note in
                                console.setNote(note, for: taskID)
                            },
                            reminderForTask: console.reminder,
                            onSetReminder: { taskID, title, date in
                                console.setReminder(for: taskID, title: title, at: date)
                            },
                            onRemoveReminder: console.removeReminder,
                            onTogglePreview: togglePreview
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.visible)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                hasFilterCriteria
                    ? "No matching tasks"
                    : (isShowingLibrary ? "No Codex tasks" : "Your console is clear"),
                systemImage: hasFilterCriteria ? "line.3.horizontal.decrease.circle" : "checkmark.circle"
            )
        } description: {
            if !hasFilterCriteria && !isShowingLibrary {
                Text("New and resumed Codex tasks will appear here automatically.")
            } else if hasFilterCriteria {
                Text("Try another search or clear some filters.")
            }
        } actions: {
            if activeFilterCount > 0 {
                Button("Clear filters", action: clearFilters)
            }
        }
    }

    private func undoBar(for notice: UndoNotice) -> some View {
        let isArchive = notice.operation == .archive

        return HStack(spacing: 8) {
            Image(systemName: isArchive ? "archivebox" : "pin.slash")
                .foregroundStyle(ConsoleTheme.secondaryText)
                .accessibilityHidden(true)

            Text("\(isArchive ? "Archived" : "Removed") \(notice.title)")
                .foregroundStyle(ConsoleTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button("Undo") { undo(notice) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help(isArchive ? "Restore task" : "Add back to Console")
                .accessibilityLabel("Undo \(isArchive ? "archive" : "removal") of \(notice.title)")
        }
        .consoleFont(size: 12.5)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(ConsoleTheme.raisedSurface)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var consoleFooter: some View {
        HStack(spacing: 8) {
            Picker("Task list", selection: $isShowingLibrary) {
                Label("Console", systemImage: "pin.fill").tag(false)
                Label("All Tasks", systemImage: "tray.full").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Task list mode")

            newTaskMenu

            if console.errorMessage != nil {
                Button {
                    Task { await console.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .consoleFont(size: 14, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ConsoleTheme.secondaryText)
                .disabled(console.isRefreshing)
                .help("Retry refresh")
                .accessibilityLabel("Retry loading tasks")
            }
        }
        .consoleFont(size: 12.5)
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(ConsoleTheme.surface)
    }

    private func toggle(_ projectID: String) {
        if collapsedProjects.contains(projectID) {
            collapsedProjects.remove(projectID)
        } else {
            collapsedProjects.insert(projectID)
        }
    }

    private func togglePreview(_ taskID: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedTaskIDs.contains(taskID) {
                expandedTaskIDs.remove(taskID)
            } else {
                expandedTaskIDs.insert(taskID)
            }
        }
    }

    private func toggleAllPreviews() {
        withAnimation(.easeInOut(duration: 0.18)) {
            if areAllVisiblePreviewsExpanded {
                expandedTaskIDs.subtract(visiblePreviewTaskIDs)
            } else {
                expandedTaskIDs.formUnion(visiblePreviewTaskIDs)
            }
        }
    }

    private func removeFromConsole(_ task: CodexTask) {
        console.hide(task.id)
        showUndoNotice(UndoNotice(
            taskID: task.id,
            title: task.title,
            operation: .consoleRemoval,
            token: UUID()
        ))
    }

    private func addToConsole(_ task: CodexTask) {
        console.enable(task.id)
        guard let notice = undoNotice, notice.taskID == task.id else { return }
        clearUndoNotice(notice)
    }

    private func archive(_ task: CodexTask) {
        Task { @MainActor in
            guard await console.setArchived(true, for: task.id) else { return }
            showUndoNotice(UndoNotice(
                taskID: task.id,
                title: task.title,
                operation: .archive,
                token: UUID()
            ))
        }
    }

    private func undo(_ notice: UndoNotice) {
        switch notice.operation {
        case .consoleRemoval:
            console.enable(notice.taskID)
            clearUndoNotice(notice)
        case .archive:
            guard undoNotice?.token == notice.token else { return }
            let pendingNotice = UndoNotice(
                taskID: notice.taskID,
                title: notice.title,
                operation: notice.operation,
                token: UUID()
            )
            undoNotice = pendingNotice
            Task { @MainActor in
                guard await console.setArchived(false, for: notice.taskID) else { return }
                clearUndoNotice(pendingNotice)
            }
        }
    }

    private func showUndoNotice(_ notice: UndoNotice) {
        withAnimation(.easeOut(duration: 0.16)) {
            undoNotice = notice
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            clearUndoNotice(notice)
        }
    }

    private func clearUndoNotice(_ notice: UndoNotice) {
        guard undoNotice?.token == notice.token else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            undoNotice = nil
        }
    }

    private func moveProject(_ sourceID: String, _ targetID: String, _ insertAfter: Bool) -> Bool {
        let projectsByID = Dictionary(uniqueKeysWithValues: console.projects.map { ($0.key, $0) })
        guard let source = projectsByID[sourceID],
              projectsByID[targetID] != nil,
              !source.isChat
        else {
            return false
        }

        let currentOrder = completeProjectOrderIDs
        let targetIsChat = projectsByID[targetID]?.isChat == true
        let shouldInsertAfter = targetIsChat ? false : insertAfter
        let reordered = ProjectOrdering.moving(
            sourceID,
            relativeTo: targetID,
            insertAfter: shouldInsertAfter,
            in: currentOrder
        )
        guard reordered != currentOrder else { return false }
        console.setProjectOrder(reordered)
        return true
    }

    private func pruneProjectOrder(to availableIDs: Set<String>) {
        let pruned = console.projectOrderIDs.filter(availableIDs.contains)
        guard pruned != console.projectOrderIDs else { return }
        console.setProjectOrder(pruned)
    }

    private func open(_ task: CodexTask) {
        guard launcher.openTask(id: task.id) else { return }
        console.markInactiveAfterOpening(task.id)
    }

    private func open(_ reminder: TaskReminder) {
        guard launcher.openTask(id: reminder.taskID) else { return }
        console.markInactiveAfterOpening(reminder.taskID)
        console.dismissReminder(reminder)
    }

    private func playReminderSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func startTask(in section: ProjectSection) {
        if section.isChat {
            launcher.startChat()
        } else {
            launcher.startTask(projectPath: section.path)
        }
    }
}
