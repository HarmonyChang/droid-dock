import SwiftUI

/// 四套「儒雅彩色」主题方案。
enum ElegantPalette: String, CaseIterable, Identifiable, Sendable {
    case bambooPaper
    case songIndigo
    case pineTea
    case morningMist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bambooPaper: return "竹青宣纸"
        case .songIndigo: return "黛蓝宋锦"
        case .pineTea: return "松烟茶白"
        case .morningMist: return "晨雾晴岚"
        }
    }

    var subtitle: String {
        switch self {
        case .bambooPaper: return "宣纸暖白 · 竹青点缀"
        case .songIndigo: return "云母米白 · 霁蓝书卷"
        case .pineTea: return "茶白浅褐 · 苍苔禅意"
        case .morningMist: return "晨雾晴白 · 晴岚清透"
        }
    }

    var sidebarBackground: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xF4F1EA)
        case .songIndigo: return Color(hex: 0xF2EFE9)
        case .pineTea: return Color(hex: 0xF3EFE7)
        case .morningMist: return Color(hex: 0xEEF2F7)
        }
    }

    var contentBackground: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xFAF8F3)
        case .songIndigo: return Color(hex: 0xFBF9F5)
        case .pineTea: return Color(hex: 0xFAF8F2)
        case .morningMist: return Color(hex: 0xF9FBFD)
        }
    }

    var toolbarBackground: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xF7F4ED)
        case .songIndigo: return Color(hex: 0xF6F3ED)
        case .pineTea: return Color(hex: 0xF6F2EA)
        case .morningMist: return Color(hex: 0xF4F7FB)
        }
    }

    var cardBackground: Color { Color.white }

    var surfaceSoft: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xEFECE3)
        case .songIndigo: return Color(hex: 0xEAE6DD)
        case .pineTea: return Color(hex: 0xEBE4D8)
        case .morningMist: return Color(hex: 0xE3E9F2)
        }
    }

    var dividerColor: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xE4DFD3)
        case .songIndigo: return Color(hex: 0xE2DDD3)
        case .pineTea: return Color(hex: 0xE1D9CB)
        case .morningMist: return Color(hex: 0xDCE3ED)
        }
    }

    var accent: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0x2E6F65)
        case .songIndigo: return Color(hex: 0x355C7D)
        case .pineTea: return Color(hex: 0x4A6B53)
        case .morningMist: return Color(hex: 0x3B66B0)
        }
    }

    var accentSoft: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xE0ECE9)
        case .songIndigo: return Color(hex: 0xE2E9F0)
        case .pineTea: return Color(hex: 0xE3EBE5)
        case .morningMist: return Color(hex: 0xE1EAF7)
        }
    }

    var primaryText: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0x1E2421)
        case .songIndigo: return Color(hex: 0x1D2228)
        case .pineTea: return Color(hex: 0x23221E)
        case .morningMist: return Color(hex: 0x1C222B)
        }
    }

    var secondaryText: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0x626C66)
        case .songIndigo: return Color(hex: 0x616873)
        case .pineTea: return Color(hex: 0x6E685F)
        case .morningMist: return Color(hex: 0x5E6877)
        }
    }

    var successColor: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0x2C7A4B)
        case .songIndigo: return Color(hex: 0x2B7A58)
        case .pineTea: return Color(hex: 0x3C7A4B)
        case .morningMist: return Color(hex: 0x267B5A)
        }
    }

    var warningColor: Color {
        switch self {
        case .bambooPaper: return Color(hex: 0xC27D2C)
        case .songIndigo: return Color(hex: 0xC6812A)
        case .pineTea: return Color(hex: 0xBC7630)
        case .morningMist: return Color(hex: 0xC57B27)
        }
    }

    func sidebarBadgeColors(for section: SidebarSection) -> (fg: Color, bg: Color) {
        switch section {
        case .photos:
            return (Color(hex: 0x356E9E), Color(hex: 0xE2ECF5))
        case .videos:
            return (Color(hex: 0x7C5A8C), Color(hex: 0xEDE6F2))
        case .screenshots:
            return (Color(hex: 0x2E7D6F), Color(hex: 0xDFF0EC))
        case .internalStorage:
            return (Color(hex: 0xC27834), Color(hex: 0xF6E9DC))
        case .downloads:
            return (Color(hex: 0x3A7A58), Color(hex: 0xE1F0E8))
        case .documents:
            return (Color(hex: 0xB85D43), Color(hex: 0xF5E5E0))
        case .transfers:
            return (Color(hex: 0x5B679A), Color(hex: 0xE5E8F4))
        }
    }

    func nodeBadgeColors(for node: RemoteNode) -> (fg: Color, bg: Color) {
        if node.isDirectory {
            return (Color(hex: 0xB87732), Color(hex: 0xF5EAD9))
        }
        switch node.kind {
        case .photo:
            return (Color(hex: 0x356E9E), Color(hex: 0xE5EEF6))
        case .video:
            return (Color(hex: 0x7C5A8C), Color(hex: 0xEFE8F4))
        case .audio:
            return (Color(hex: 0xB85D6F), Color(hex: 0xF6E6EB))
        case .document:
            return (Color(hex: 0xB85D43), Color(hex: 0xF6E8E3))
        case .other:
            return (Color(hex: 0x5C736D), Color(hex: 0xE6ECEA))
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
