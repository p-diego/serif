import SwiftUI
import AppKit

/// Colour, type and size tokens from UI-APP.md (§1-§4), light/dark.
enum Theme {
    private static func hex(_ value: UInt32, alpha: Bool = false) -> NSColor {
        let a = alpha ? CGFloat(value & 0xFF) / 255 : 1
        let rgb = alpha ? value >> 8 : value
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }

    /// Adaptive colour from `RRGGBBAA` (or `RRGGBB` when `alpha` is false) light and dark values.
    private static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: Bool = true) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark, alpha: alpha) : hex(light, alpha: alpha)
        })
    }

    // Surfaces
    // Dark values of pane, sidebar, active and bot bubble are sampled from demo-1.png (the demo wins over UI-APP.md):
    // pane #30302F, sidebar #1B1B1A, selected row #343432, bot bubble #40403F, composer field #323232 / border #515151.
    // Light values are the tokens.
    static let pane = adaptive(0xFFFFFF, 0x30302F, alpha: false)
    static let chrome = adaptive(0xFCFCFC, 0x121212, alpha: false)
    static let sidebar = adaptive(0xF5F5F5, 0x1B1B1A, alpha: false)
    static let elevated = adaptive(0xFFFFFF, 0x1F1F1F, alpha: false)

    // Text
    static let text = adaptive(0x1C1C1CFF, 0xF5F5F5FF)
    static let textSecondary = adaptive(0x1C1C1CAD, 0xF5F5F5A8)
    static let textTertiary = adaptive(0x1C1C1C8F, 0xF5F5F58A)
    static let textQuaternary = adaptive(0x1C1C1C66, 0xF5F5F561)

    // Bubbles. Dark user bubble follows the demo (light opaque fill, dark text; sampled #EFEFEC from demo-1.png),
    // not the token (#F5F5F52E).
    static let botBubble = adaptive(0x1C1C1C0F, 0x40403FFF)
    static let userBubble = adaptive(0x1C1C1CFF, 0xEFEFECFF)
    static let userBubbleText = adaptive(0xFFFFFFFF, 0x1C1C1CFF)

    // Fills
    static let fillSecondary = adaptive(0x1C1C1C0F, 0xF5F5F50A)
    static let fillSecondaryHover = adaptive(0x1C1C1C1A, 0xF5F5F514)
    static let hover = adaptive(0x1C1C1C0F, 0xF5F5F50F)
    static let active = adaptive(0x1C1C1C14, 0x343432FF)

    // Code and output boxes inside bubbles and cards
    static let codeBackground = adaptive(0x1C1C1C0F, 0x0000002E)

    // Composer (message field), dark from the demo
    static let composerFill = adaptive(0xFFFFFFFF, 0x323232FF)
    static let composerBorder = adaptive(0x1C1C1C1F, 0x515151FF)

    // Borders
    static let border = adaptive(0x1C1C1C1F, 0xF5F5F51A)
    static let borderTertiary = adaptive(0x1C1C1C14, 0xF5F5F50F)
    static let borderQuaternary = adaptive(0x1C1C1C0F, 0xF5F5F50A)

    // Status colours: text, soft background, solid
    static let green = adaptive(0x00854AFF, 0x00BA69FF)
    static let greenTint = adaptive(0x14C16F17, 0x14C37012)
    static let greenSolid = adaptive(0x10AB61FF, 0x0E9F5AFF)
    static let red = adaptive(0xCD2834FF, 0xFF6463FF)
    static let redTint = adaptive(0xFB2B3E17, 0xFC2C3E12)
    static let redSolid = adaptive(0xE72E3BFF, 0xCF2B35FF)
    static let yellow = adaptive(0xAA6300FF, 0xE28600FF)
    static let yellowTint = adaptive(0xF5931217, 0xF6941212)
    static let yellowSolid = adaptive(0xDA830EFF, 0xC8770CFF)
    static let blue = adaptive(0x0B6DD3FF, 0x4D9BFFFF)
    static let blueTint = adaptive(0x1E86FC17, 0x1884FC12)
    static let blueSolid = adaptive(0x1680F3FF, 0x116DD2FF)

    // Type scale (system font)
    enum Size {
        static let body: CGFloat = 14
        static let small: CGFloat = 13
        static let label: CGFloat = 12
        static let caption: CGFloat = 11
        static let title: CGFloat = 17
    }

    // Radii
    enum Radius {
        static let bubble: CGFloat = 18
        static let row: CGFloat = 10
        static let card: CGFloat = 16
        static let composer: CGFloat = 24
    }

    static let sidebarWidth: CGFloat = 280
    static let panelWidth: CGFloat = 320
}
