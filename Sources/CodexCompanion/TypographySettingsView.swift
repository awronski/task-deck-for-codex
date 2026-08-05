import SwiftUI

struct TypographySettingsView: View {
    @AppStorage("automaticallySortProjects") private var automaticallySortProjects = false
    @AppStorage("syncTaskTitlesToCodex") private var syncTaskTitlesToCodex = false
    @AppStorage("showTaskModelDetails") private var showTaskModelDetails = false
    @AppStorage("consoleFontFamily") private var fontFamily = ConsoleFontFamily.system.rawValue
    @AppStorage("consoleFontSize") private var fontSize = ConsoleFontSize.standard.rawValue

    private var typography: ConsoleTypography {
        ConsoleTypography(
            family: ConsoleFontFamily(rawValue: fontFamily) ?? .system,
            baseSize: fontSize
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                SettingsSection(
                    title: "Organization",
                    systemImage: "arrow.up.arrow.down"
                ) {
                    SettingsToggle(
                        title: "Automatically sort projects",
                        description: "Bring projects with working or newly finished tasks to the top, then alphabetize each group. Task order stays unchanged.",
                        isOn: $automaticallySortProjects
                    )
                }

                SettingsSection(
                    title: "Codex integration",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    SettingsToggle(
                        title: "Rename tasks in Codex",
                        description: "Also update Codex when you rename a task in Task Deck. Existing local titles are unchanged.",
                        isOn: $syncTaskTitlesToCodex
                    )
                }

                SettingsSection(
                    title: "Task details",
                    systemImage: "text.alignleft"
                ) {
                    SettingsToggle(
                        title: "Show model and thinking effort",
                        description: "Display the model and thinking effort beneath each task title.",
                        isOn: $showTaskModelDetails
                    )
                }

                SettingsSection(
                    title: "Appearance",
                    systemImage: "textformat"
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsPicker(
                            title: "Font family",
                            description: "Choose the typeface used throughout the console."
                        ) {
                            Picker("Font family", selection: $fontFamily) {
                                ForEach(ConsoleFontFamily.allCases) { family in
                                    Text(family.title).tag(family.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        Divider()

                        SettingsPicker(
                            title: "Text size",
                            description: "Adjust task titles, metadata, and controls together."
                        ) {
                            Picker("Text size", selection: $fontSize) {
                                ForEach(ConsoleFontSize.allCases) { size in
                                    Text(size.settingsTitle).tag(size.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        typographyPreview
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.never)
        .background(settingsBackground)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(ConsoleTheme.blue)
                .frame(width: 38, height: 38)
                .background(ConsoleTheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ConsoleTheme.blue.opacity(0.20))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ConsoleTheme.primaryText)
                Text("Customize how Task Deck organizes and presents your console.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var typographyPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREVIEW")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(ConsoleTheme.secondaryText)

            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ConsoleTheme.teal)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Polish the settings experience")
                        .font(typography.font(size: 14, weight: .medium))
                        .foregroundStyle(ConsoleTheme.primaryText)
                    Text(showTaskModelDetails ? "FINISHED  ·  gpt-5.6-sol  ·  high" : "FINISHED")
                        .font(typography.font(size: 10.5, weight: .semibold))
                        .foregroundStyle(ConsoleTheme.secondaryText)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(ConsoleTheme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ConsoleTheme.divider)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Typography preview")
    }

    private var settingsBackground: some View {
        ZStack {
            ConsoleTheme.background
            LinearGradient(
                colors: [Color.white.opacity(0.025), .clear, Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ConsoleTheme.secondaryText)

            content
        }
        .padding(16)
        .background(ConsoleTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ConsoleTheme.divider)
        )
    }
}

private struct SettingsToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(ConsoleTheme.primaryText)
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ConsoleTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct SettingsPicker<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(ConsoleTheme.primaryText)
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ConsoleTheme.secondaryText)
            }

            content
        }
    }
}

private extension ConsoleFontSize {
    var settingsTitle: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }
}
