import AppKit
import CueCore
import SwiftUI

/// Color tokens from spec §14, resolved for the current appearance.
enum Palette {
    static let ink = dynamic(light: 0x231E1A, dark: 0xF2ECE6)
    static let ink2 = dynamic(light: 0x655B53, dark: 0xB5AAA0)
    static let ok = dynamic(light: 0x2E8A57, dark: 0x55C68A)
    static let warn = dynamic(light: 0xB9740F, dark: 0xE5A445)
    static let err = dynamic(light: 0xC8392F, dark: 0xF06A60)
    static let unknown = dynamic(light: 0x8A8079, dark: 0x8F857C)
    static let accent = dynamic(light: 0x6B4FBB, dark: 0x6B4FBB)
    static let accentText = dynamic(light: 0x6B4FBB, dark: 0xB7A2F2)

    static func tile(_ tint: Tint) -> Color {
        switch tint {
        case .sky: dynamic(light: 0xDCEAF2, dark: 0x1E3440)
        case .rose: dynamic(light: 0xF4DEE3, dark: 0x41252D)
        case .amber: dynamic(light: 0xF4E5CB, dark: 0x3E3020)
        case .sage: dynamic(light: 0xDDE9DE, dark: 0x22342A)
        case .plum: dynamic(light: 0xE6DFF4, dark: 0x2F2745)
        case .sand: dynamic(light: 0xECE3D8, dark: 0x38312A)
        }
    }

    static func symbol(_ tint: Tint) -> Color {
        switch tint {
        case .sky: dynamic(light: 0x2C6A88, dark: 0x8DC3DC)
        case .rose: dynamic(light: 0x9C4059, dark: 0xE79AAE)
        case .amber: dynamic(light: 0x8C5C15, dark: 0xE2B66C)
        case .sage: dynamic(light: 0x3B6E4B, dark: 0x92C7A0)
        case .plum: dynamic(light: 0x5B44A0, dark: 0xBAA7EF)
        case .sand: dynamic(light: 0x6A5A4A, dark: 0xCBB9A4)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

/// Sizes from spec §14.
enum Metrics {
    static let searchHeight: CGFloat = 48
    static let rowHeight: CGFloat = 48
    static let listInset: CGFloat = 6
    static let selectionRadius: CGFloat = 9
    static let tileSize: CGFloat = 26
    static let tileRadius: CGFloat = 7
    static let tileSymbol: CGFloat = 15
    static let accessorySize: CGFloat = 30
    static let glyphSize: CGFloat = 16
    static let footerHeight: CGFloat = 40
    static let maxVisibleRows = 9
    static let toastDuration: Duration = .milliseconds(2800)
    static let staleAfter: TimeInterval = 30
}
