import SwiftUI
import AppKit

extension Color {
    static let boardBackground = Color(nsColor: .windowBackgroundColor)
    static let columnBackground = Color(white: 0.18).opacity(0.3)
    static let columnHeaderBackground = Color(white: 0.18).opacity(0.5)
    static let cardBackground = Color(white: 0.18)
    static let countBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.3)

    /// Muted green used for confirmation/action buttons
    static let buttonGreen = Color(red: 0.35, green: 0.65, blue: 0.35)

    // MARK: - Semantic Backgrounds

    /// Subtle section background (e.g., branch info bar, diff header)
    static let secondaryBackground = Color.secondary.opacity(0.05)

    /// Form field / input background
    static let inputBackground = Color.secondary.opacity(0.1)

    /// Faint overlay for code/output areas
    static let codeBackground = Color.black.opacity(0.05)

    /// Separator line color
    static let separator = Color(nsColor: .separatorColor)

    /// Pill / segmented control background
    static let pillBackground = Color.secondary.opacity(0.08)
}
