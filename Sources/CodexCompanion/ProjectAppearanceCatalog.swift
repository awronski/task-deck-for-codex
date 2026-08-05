import CodexCompanionCore
import SwiftUI

struct ProjectIconChoice: Identifiable, Sendable {
    let id: String
    let title: String
}

struct ProjectColorChoice: Identifiable, Sendable {
    let id: String
    let title: String
    let rgb: UInt32

    var color: Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    var luminanceIsLight: Bool {
        let red = Double((rgb >> 16) & 0xFF) / 255
        let green = Double((rgb >> 8) & 0xFF) / 255
        let blue = Double(rgb & 0xFF) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.64
    }
}

enum ProjectAppearanceCatalog {
    static let icons = [
        ProjectIconChoice(id: "folder", title: "Folder"),
        ProjectIconChoice(id: "terminal", title: "Terminal"),
        ProjectIconChoice(id: "chart.bar", title: "Analytics"),
        ProjectIconChoice(id: "server.rack", title: "Server"),
        ProjectIconChoice(id: "chevron.left.forwardslash.chevron.right", title: "Code"),
        ProjectIconChoice(id: "app", title: "Application"),
        ProjectIconChoice(id: "globe", title: "Website"),
        ProjectIconChoice(id: "network", title: "Network"),
        ProjectIconChoice(id: "doc.text", title: "Documents"),
        ProjectIconChoice(id: "shippingbox", title: "Package"),
        ProjectIconChoice(id: "hammer", title: "Build"),
        ProjectIconChoice(id: "wrench.and.screwdriver", title: "Tools"),
        ProjectIconChoice(id: "gearshape", title: "Service"),
        ProjectIconChoice(id: "magnifyingglass", title: "Search"),
        ProjectIconChoice(id: "lock.shield", title: "Security"),
        ProjectIconChoice(id: "testtube.2", title: "Experiments"),
        ProjectIconChoice(id: "person.2", title: "Team"),
        ProjectIconChoice(id: "bubble.left", title: "Chat"),
        ProjectIconChoice(id: "bolt", title: "Automation"),
        ProjectIconChoice(id: "command", title: "Command")
    ]

    static let colorRows = [
        [
            color("matrix-red-darkest", "Darkest red", 0x68282B),
            color("matrix-orange-darkest", "Darkest orange", 0x783D1F),
            color("matrix-gold-darkest", "Darkest gold", 0x7B5815),
            color("matrix-lime-darkest", "Darkest lime", 0x676024),
            color("matrix-green-darkest", "Darkest green", 0x4A6133),
            color("matrix-teal-darkest", "Darkest teal", 0x325858),
            color("matrix-purple-darkest", "Darkest purple", 0x563C72)
        ],
        [
            color("matrix-red-dark", "Dark red", 0x9E3A40),
            color("matrix-orange-dark", "Dark orange", 0xB05924),
            color("matrix-gold-dark", "Dark gold", 0xA67B13),
            color("matrix-lime-dark", "Dark lime", 0x838334),
            color("matrix-green-dark", "Dark green", 0x4D784B),
            color("matrix-teal-dark", "Dark teal", 0x407278),
            color("matrix-purple-dark", "Dark purple", 0x75509F)
        ],
        [
            color("matrix-red-deep", "Deep red", 0xCC5258),
            color("matrix-orange-deep", "Deep orange", 0xDE722E),
            color("matrix-gold-deep", "Deep gold", 0xD7A11E),
            color("matrix-lime-deep", "Deep lime", 0x9FA84D),
            color("matrix-green-deep", "Deep green", 0x5D9766),
            color("matrix-teal-deep", "Deep teal", 0x529595),
            color("matrix-purple-deep", "Deep purple", 0x8B65B2)
        ],
        [
            color("matrix-red-medium", "Medium red", 0xE96972),
            color("matrix-orange-medium", "Medium orange", 0xEB8947),
            color("matrix-gold-medium", "Medium gold", 0xEBB838),
            color("matrix-lime-medium", "Medium lime", 0xB5C36A),
            color("matrix-green-medium", "Medium green", 0x70AB8E),
            color("matrix-teal-medium", "Medium teal", 0x4598A1),
            color("matrix-purple-medium", "Medium purple", 0x9B75C1)
        ],
        [
            color("matrix-red-soft", "Soft red", 0xEC828B),
            color("matrix-orange-soft", "Soft orange", 0xF2A065),
            color("matrix-gold-soft", "Soft gold", 0xF4CA5D),
            color("matrix-lime-soft", "Soft lime", 0xC5D28B),
            color("matrix-green-soft", "Soft green", 0x8BBFAE),
            color("matrix-teal-soft", "Soft teal", 0x7DB9C6),
            color("matrix-purple-soft", "Soft purple", 0xAD8AD1)
        ],
        [
            color("matrix-red-light", "Light red", 0xF0A2A7),
            color("matrix-orange-light", "Light orange", 0xF8BC8F),
            color("matrix-gold-light", "Light gold", 0xF9DF8E),
            color("matrix-lime-light", "Light lime", 0xD8E1AC),
            color("matrix-green-light", "Light green", 0xAED6CE),
            color("matrix-teal-light", "Light teal", 0xA5D1E1),
            color("matrix-purple-light", "Light purple", 0xCAAEE3)
        ],
        [
            color("matrix-red-pale", "Pale red", 0xF4C2C6),
            color("matrix-orange-pale", "Pale orange", 0xFAD5B4),
            color("matrix-gold-pale", "Pale gold", 0xFBECB2),
            color("matrix-lime-pale", "Pale lime", 0xE6EBCD),
            color("matrix-green-pale", "Pale green", 0xD1E8E6),
            color("matrix-teal-pale", "Pale teal", 0xCAE6F3),
            color("matrix-purple-pale", "Pale purple", 0xE2D4F0)
        ]
    ]

    private static let colorsByID = Dictionary(
        uniqueKeysWithValues: colorRows.flatMap { $0 }.map { ($0.id, $0) }
    )
    private static let iconIDs = Set(icons.map(\.id))

    static func color(for colorID: String) -> Color {
        colorsByID[colorID]?.color ?? ConsoleTheme.blue
    }

    static func resolved(_ stored: ProjectAppearance?, for section: ProjectSection) -> ProjectAppearance {
        let suggested = suggested(for: section)
        guard let stored else { return suggested }
        return ProjectAppearance(
            iconName: iconIDs.contains(stored.iconName) ? stored.iconName : suggested.iconName,
            colorID: stored.usesBackgroundColor && colorsByID[stored.colorID] == nil
                ? suggested.colorID
                : stored.colorID
        )
    }

    static func suggested(for section: ProjectSection) -> ProjectAppearance {
        let nameParts = Set(
            section.name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )
        let iconName: String

        if !nameParts.isDisjoint(with: ["admin", "dashboard"]) {
            iconName = "chart.bar"
        } else if !nameParts.isDisjoint(with: ["cli", "terminal"]) {
            iconName = "terminal"
        } else if !nameParts.isDisjoint(with: ["server", "api"]) {
            iconName = "server.rack"
        } else if !nameParts.isDisjoint(with: ["app", "companion"]) {
            iconName = "chevron.left.forwardslash.chevron.right"
        } else {
            iconName = "folder"
        }

        return ProjectAppearance(
            iconName: iconName,
            colorID: ProjectAppearance.noBackgroundColorID
        )
    }

    private static func color(_ id: String, _ title: String, _ rgb: UInt32) -> ProjectColorChoice {
        ProjectColorChoice(id: id, title: title, rgb: rgb)
    }
}
