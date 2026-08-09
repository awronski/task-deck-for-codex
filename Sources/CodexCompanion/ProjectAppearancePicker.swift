import CodexCompanionCore
import SwiftUI

struct ProjectAppearancePicker: View {
    let projectName: String
    let onChange: (ProjectAppearance) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: ProjectAppearance
    @State private var displayName: String

    init(
        projectName: String,
        appearance: ProjectAppearance,
        onChange: @escaping (ProjectAppearance) -> Void
    ) {
        self.projectName = projectName
        self.onChange = onChange
        _selection = State(initialValue: appearance)
        _displayName = State(initialValue: appearance.displayName ?? projectName)
    }

    private let iconColumns = Array(repeating: GridItem(.fixed(38), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Customize project")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ConsoleTheme.primaryText)

                    TextField("Project name", text: $displayName, prompt: Text(projectName))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .onChange(of: displayName) { _, nextName in
                            update(displayName: nextName)
                        }
                        .help("Change the project name shown in Task Deck")
                        .accessibilityLabel("Displayed project name")
                }

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(selection.usesBackgroundColor
                        ? ProjectAppearanceCatalog.color(for: selection.colorID)
                        : ConsoleTheme.blue)
            }

            LazyVGrid(columns: iconColumns, alignment: .leading, spacing: 8) {
                ForEach(ProjectAppearanceCatalog.icons) { icon in
                    iconButton(icon)
                }
            }

            Divider().overlay(ConsoleTheme.divider)

            noBackgroundButton

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ProjectAppearanceCatalog.colorRows.indices, id: \.self) { rowIndex in
                    paletteRow(ProjectAppearanceCatalog.colorRows[rowIndex])
                }
            }
        }
        .padding(16)
        .frame(width: 312)
        .background(ConsoleTheme.background)
    }

    private func iconButton(_ icon: ProjectIconChoice) -> some View {
        let isSelected = selection.iconName == icon.id
        let color = selection.usesBackgroundColor
            ? ProjectAppearanceCatalog.color(for: selection.colorID)
            : ConsoleTheme.blue
        return Button {
            update(iconName: icon.id, colorID: selection.colorID)
        } label: {
            Image(systemName: icon.id)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : ConsoleTheme.primaryText.opacity(0.82))
                .frame(width: 36, height: 36)
                .background(
                    isSelected ? color.opacity(0.36) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? color.opacity(0.95) : ConsoleTheme.divider)
                )
        }
        .buttonStyle(.plain)
        .help(icon.title)
        .accessibilityLabel(icon.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var noBackgroundButton: some View {
        let isSelected = !selection.usesBackgroundColor
        return Button {
            update(
                iconName: selection.iconName,
                colorID: ProjectAppearance.noBackgroundColorID
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 12, weight: .medium))

                Text("No background")
                    .font(.system(size: 11.5, weight: .medium))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? ConsoleTheme.primaryText : ConsoleTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                isSelected ? ConsoleTheme.blue.opacity(0.18) : Color.white.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? ConsoleTheme.blue.opacity(0.9) : ConsoleTheme.divider)
            )
        }
        .buttonStyle(.plain)
        .help("Remove the project header background color")
        .accessibilityLabel("No project background")
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private func paletteRow(_ colors: [ProjectColorChoice]) -> some View {
        HStack(spacing: 7) {
            ForEach(colors) { choice in
                colorButton(choice)
            }
        }
    }

    private func colorButton(_ choice: ProjectColorChoice) -> some View {
        let isSelected = selection.colorID == choice.id
        return Button {
            update(iconName: selection.iconName, colorID: choice.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(choice.color)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(choice.luminanceIsLight ? Color.black.opacity(0.78) : .white)
                }
            }
            .frame(width: 34, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.16), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel("\(paletteColorName(choice))")
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private func update(iconName: String, colorID: String) {
        let next = ProjectAppearance(
            iconName: iconName,
            colorID: colorID,
            displayName: selection.displayName
        )
        save(next)
    }

    private func update(displayName: String) {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = ProjectAppearance(
            iconName: selection.iconName,
            colorID: selection.colorID,
            displayName: trimmedDisplayName == projectName ? nil : trimmedDisplayName
        )
        save(next)
    }

    private func save(_ next: ProjectAppearance) {
        guard next != selection else { return }
        selection = next
        onChange(next)
    }

    private func paletteColorName(_ choice: ProjectColorChoice) -> String {
        "Project color \(choice.title)"
    }
}
