import AppKit

struct TerminalConfiguration {
    let fontName = "SF Mono"
    let fontSize: CGFloat = 12
    let backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    let foregroundColor = NSColor.white
    let cursorColor = NSColor.green

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}
