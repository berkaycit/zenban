import SwiftUI
import AppKit

extension Color {
    static let boardBackground = Color(nsColor: .windowBackgroundColor)
    static let columnBackground = Color(nsColor: .controlBackgroundColor).opacity(0.5)
    static let columnHeaderBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let countBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.3)

    /// Muted green used for confirmation/action buttons
    static let buttonGreen = Color(red: 0.35, green: 0.65, blue: 0.35)
}
