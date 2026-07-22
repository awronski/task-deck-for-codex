import SwiftUI

struct TypographySettingsView: View {
    @AppStorage("consoleFontFamily") private var fontFamily = ConsoleFontFamily.system.rawValue
    @AppStorage("consoleFontSize") private var fontSize = ConsoleFontSize.standard.rawValue

    private var typography: ConsoleTypography {
        ConsoleTypography(
            family: ConsoleFontFamily(rawValue: fontFamily) ?? .system,
            baseSize: fontSize
        )
    }

    var body: some View {
        Form {
            Picker("Font", selection: $fontFamily) {
                ForEach(ConsoleFontFamily.allCases) { family in
                    Text(family.title).tag(family.rawValue)
                }
            }

            Picker("Font size", selection: $fontSize) {
                ForEach(ConsoleFontSize.allCases) { size in
                    Text(size.title).tag(size.rawValue)
                }
            }

            Text("The quick brown fox jumps over the lazy dog.")
                .font(typography.font(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
