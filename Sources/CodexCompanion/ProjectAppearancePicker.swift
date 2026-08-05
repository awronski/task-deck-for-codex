import CodexCompanionCore
import SwiftUI

struct ProjectAppearancePicker: View {
    let projectName: String
    let suggestedAppearance: ProjectAppearance
    let onChange: (ProjectAppearance) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: ProjectAppearance

    init(
        projectName: String,
        appearance: ProjectAppearance,
        suggestedAppearance: ProjectAppearance,
        onChange: @escaping (ProjectAppearance) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.suggestedAppearance = suggestedAppearance
        self.onChange = onChange
        self.onReset = onReset
        _selection = State(initialValue: appearance)
    }

    private let iconColumns = Array(repeating: GridItem(.fixed(38), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Customize project")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ConsoleTheme.primaryText)
                    Text(projectName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(ConsoleTheme.secondaryText)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(selection.usesBackgroundColor
                        ? ProjectAppearanceCatalog.color(for: selection.colorID)
                        : ConsoleTheme.blue)
            }

            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("ICON")

                LazyVGrid(columns: iconColumns, alignment: .leading, spacing: 8) {
                    ForEach(ProjectAppearanceCatalog.icons) { icon in
                        iconButton(icon)
                    }
                }
            }

            Divider().overlay(ConsoleTheme.divider)

            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("COLOR PALETTE")

                noBackgroundButton

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ProjectAppearanceCatalog.colorRows.indices, id: \.self) { rowIndex in
                        paletteRow(ProjectAppearanceCatalog.colorRows[rowIndex])
                    }
                }
            }

            HStack {
                Button("Reset to suggested") {
                    selection = suggestedAppearance
                    onReset()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ConsoleTheme.secondaryText)

                Spacer()

                Text("Changes are saved automatically")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ConsoleTheme.secondaryText.opacity(0.8))
            }
        }
        .padding(16)
        .frame(width: 344)
        .background(ConsoleTheme.background)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.45)
            .foregroundStyle(ConsoleTheme.secondaryText)
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
        let next = ProjectAppearance(iconName: iconName, colorID: colorID)
        guard next != selection else { return }
        selection = next
        onChange(next)
    }

    private func paletteColorName(_ choice: ProjectColorChoice) -> String {
        "Project color \(choice.title)"
    }
}
