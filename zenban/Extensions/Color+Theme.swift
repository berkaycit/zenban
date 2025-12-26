import SwiftUI
import AppKit

extension Color {
    static let boardBackground = Color(nsColor: .windowBackgroundColor)
    static let columnBackground = Color(nsColor: .controlBackgroundColor).opacity(0.5)
    static let columnHeaderBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let countBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.3)

    // TEMP: For color picker
    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int(nsColor.redComponent * 255)
        let g = Int(nsColor.greenComponent * 255)
        let b = Int(nsColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
