import CodexCompanionCore
import SwiftUI

struct FocusTaskPicker: View {
    let candidates: [CodexTask]
    let focusedTaskIDs: [String]
    let projectDisplayNames: [String: String]
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedTaskIDs: Set<String>

    init(
        candidates: [CodexTask],
        focusedTaskIDs: [String],
        projectDisplayNames: [String: String],
        onSave: @escaping ([String]) -> Void
    ) {
        self.candidates = candidates
        self.focusedTaskIDs = focusedTaskIDs
        self.projectDisplayNames = projectDisplayNames
        self.onSave = onSave
        _selectedTaskIDs = State(initialValue: Set(focusedTaskIDs))
    }

    private var orderedCandidates: [CodexTask] {
        candidates.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    private var visibleCandidates: [CodexTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedCandidates.filter { task in
            query.isEmpty
                || task.title.localizedCaseInsensitiveContains(query)
                || task.projectName.localizedCaseInsensitiveContains(query)
                || projectDisplayNames[task.projectKey]?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var selectableTaskIDs: Set<String> {
        Set(candidates.map(\.id)).union(focusedTaskIDs)
    }

    private var unavailableSelectionCount: Int {
        selectedTaskIDs.subtracting(candidates.map(\.id)).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose your focus")
                    .consoleFont(size: 20, weight: .semibold)
                Text("Choose from \(candidates.count) pinned tasks.")
                    .consoleFont(size: 12)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }

            SearchField(text: $searchText)

            if visibleCandidates.isEmpty {
                ContentUnavailableView {
                    Label(candidates.isEmpty ? "No pinned tasks" : "No matching tasks", systemImage: "pin")
                } description: {
                    Text(candidates.isEmpty ? "Pin tasks to make them available here." : "Try another search.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visibleCandidates) { task in
                            Toggle(isOn: Binding(
                                get: { selectedTaskIDs.contains(task.id) },
                                set: { selected in
                                    if selected {
                                        selectedTaskIDs.insert(task.id)
                                    } else {
                                        selectedTaskIDs.remove(task.id)
                                    }
                                }
                            )) {
                                FocusTaskLabel(task: task, projectDisplayNames: projectDisplayNames)
                            }
                            .toggleStyle(.checkbox)
                            .padding(10)
                            .background(selectedTaskIDs.contains(task.id) ? ConsoleTheme.blue.opacity(0.07) : .clear)

                            if task.id != visibleCandidates.last?.id {
                                Rectangle().fill(ConsoleTheme.divider).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if unavailableSelectionCount > 0 {
                Text("\(unavailableSelectionCount) selected \(unavailableSelectionCount == 1 ? "task is" : "tasks are") temporarily unavailable. Your selection will be kept.")
                    .consoleFont(size: 11.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }

            HStack {
                Text("\(selectedTaskIDs.count) selected")
                    .consoleFont(size: 12.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let retainedIDs = focusedTaskIDs.filter { selectedTaskIDs.contains($0) }
                    let retainedSet = Set(retainedIDs)
                    let addedIDs = orderedCandidates.map(\.id).filter {
                        selectedTaskIDs.contains($0) && !retainedSet.contains($0)
                    }
                    onSave(retainedIDs + addedIDs)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 550)
        .foregroundStyle(ConsoleTheme.primaryText)
        .background(ConsoleTheme.background)
        .onChange(of: selectableTaskIDs) { _, selectableIDs in
            selectedTaskIDs.formIntersection(selectableIDs)
        }
        .onChange(of: focusedTaskIDs) { previousIDs, currentIDs in
            selectedTaskIDs.formUnion(Set(currentIDs).subtracting(previousIDs))
        }
    }
}

struct OutsideFocusAttentionView: View {
    let tasks: [CodexTask]
    let projectDisplayNames: [String: String]
    let onOpen: (CodexTask) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Outside Focus")
                .consoleFont(size: 20, weight: .semibold)
            Text("These pinned tasks need your attention.")
                .consoleFont(size: 12)
                .foregroundStyle(ConsoleTheme.secondaryText)

            if tasks.isEmpty {
                ContentUnavailableView("No tasks need attention", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(tasks) { task in
                            VStack(alignment: .trailing, spacing: 9) {
                                FocusTaskLabel(task: task, projectDisplayNames: projectDisplayNames)
                                Button("Open in Codex") { onOpen(task) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .padding(12)
                            .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 400)
        .foregroundStyle(ConsoleTheme.primaryText)
        .background(ConsoleTheme.background)
    }
}

private struct FocusTaskLabel: View {
    let task: CodexTask
    let projectDisplayNames: [String: String]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .consoleFont(size: 14, weight: .medium)
                    .lineLimit(1)
                    .help(task.title)
                Text(projectDisplayNames[task.projectKey] ?? task.projectName)
                    .consoleFont(size: 11.5)
                    .foregroundStyle(ConsoleTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusChip(status: task.status, workingSince: nil)
                .fixedSize()
        }
    }
}
