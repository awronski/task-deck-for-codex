import CodexCompanionCore
import SwiftUI

enum ConsoleTheme {
    static let background = Color(red: 0.070, green: 0.079, blue: 0.086)
    static let surface = Color.white.opacity(0.035)
    static let raisedSurface = Color.white.opacity(0.055)
    static let divider = Color.white.opacity(0.075)
    static let primaryText = Color(red: 0.94, green: 0.95, blue: 0.96)
    static let secondaryText = Color(red: 0.60, green: 0.62, blue: 0.66)
    static let blue = Color(red: 0.27, green: 0.70, blue: 0.98)
    static let amber = Color(red: 1.00, green: 0.68, blue: 0.08)
    static let red = Color(red: 1.00, green: 0.34, blue: 0.36)
    static let teal = Color(red: 0.34, green: 0.82, blue: 0.79)
    static let inactive = Color(red: 0.57, green: 0.59, blue: 0.62)
    static func color(for status: AttentionStatus) -> Color {
        switch status {
        case .waitingForInput, .waitingForPermission: amber
        case .error: red
        case .working: blue
        case .finished: teal
        case .inactive: inactive
        }
    }
}
