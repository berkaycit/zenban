import AppKit
import SwiftUI
import SwiftTerm

struct TerminalConfiguration {
    // MARK: - Font

    static let fontName = "SF Mono"
    static let fontSize: CGFloat = 14

    static var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: - Colors

    // Modern dark background - softer than pure black
    // Contrast ratio with foreground: ~9:1 (WCAG AAA compliant)
    static let backgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.118, alpha: 1.0)  // #1A1A1E
    static let backgroundSwiftUIColor = SwiftUI.Color(red: 0.102, green: 0.102, blue: 0.118)

    // Soft white foreground - easier on the eyes than pure white
    static let foregroundColor = NSColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)  // #D9D9DE

    // Modern teal cursor
    static let cursorColor = NSColor(red: 0.37, green: 0.79, blue: 0.89, alpha: 1.0)  // #5FC9E3

    // Selection highlight
    static let selectionColor = NSColor(red: 0.20, green: 0.35, blue: 0.50, alpha: 1.0)  // #335980

    // MARK: - ANSI Color Palette

    // Helper to create Color from 8-bit RGB values
    private static func color(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    // Modern, softer ANSI colors for better readability
    static let ansiColors: [SwiftTerm.Color] = [
        // Dark colors (0-7)
        color(0x67, 0x67, 0x67),  // Black - lighter for dark backgrounds
        color(0xE0, 0x6C, 0x75),  // Red - muted rose
        color(0x98, 0xC3, 0x79),  // Green - soft sage
        color(0xE5, 0xC0, 0x7B),  // Yellow - warm amber
        color(0x61, 0xAF, 0xEF),  // Blue - sky blue
        color(0xC6, 0x78, 0xDD),  // Magenta - soft purple
        color(0x56, 0xB6, 0xC2),  // Cyan - teal
        color(0xAB, 0xB2, 0xBF),  // White - warm gray

        // Bright colors (8-15) - lighter for bold/bright distinction
        color(0x5C, 0x63, 0x70),  // Bright black - comment gray
        color(0xF0, 0x80, 0x89),  // Bright red - lighter rose
        color(0xAC, 0xD7, 0x8D),  // Bright green - lighter sage
        color(0xF9, 0xD4, 0x8F),  // Bright yellow - lighter amber
        color(0x75, 0xC3, 0xFF),  // Bright blue - lighter sky
        color(0xDA, 0x8C, 0xF1),  // Bright magenta - lighter purple
        color(0x6A, 0xCA, 0xD6),  // Bright cyan - lighter teal
        color(0xE8, 0xE8, 0xED),  // Bright white
    ]
}
