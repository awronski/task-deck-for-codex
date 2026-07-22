import SwiftUI

enum ConsoleFontFamily: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum ConsoleFontSize: Double, CaseIterable, Identifiable {
    case small = 12
    case standard = 14
    case large = 16
    case extraLarge = 18

    var id: Self { self }
    var title: String { "\(Int(rawValue)) pt" }
}

struct ConsoleTypography {
    static let defaultBaseSize = ConsoleFontSize.standard.rawValue

    let family: ConsoleFontFamily
    let baseSize: Double

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        .system(
            size: size * baseSize / Self.defaultBaseSize,
            weight: weight,
            design: family.design
        )
    }
}

private struct ConsoleTypographyKey: EnvironmentKey {
    static let defaultValue = ConsoleTypography(family: .system, baseSize: ConsoleTypography.defaultBaseSize)
}

extension EnvironmentValues {
    var consoleTypography: ConsoleTypography {
        get { self[ConsoleTypographyKey.self] }
        set { self[ConsoleTypographyKey.self] = newValue }
    }
}

private struct ConsoleFontModifier: ViewModifier {
    @Environment(\.consoleTypography) private var typography

    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(typography.font(size: size, weight: weight))
    }
}

extension View {
    func consoleFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ConsoleFontModifier(size: size, weight: weight))
    }
}
