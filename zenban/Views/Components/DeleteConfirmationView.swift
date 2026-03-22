import SwiftUI

struct DeleteConfirmationContent {
    let title: String
    let message: String
    let detail: String?
    let deleteAccessibilityLabel: String

    var informativeText: String {
        guard let detail,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return message
        }
        return "\(message) \(detail)"
    }
}

struct ConfirmationButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        let background: Color = {
            if configuration.isPressed {
                return isDestructive ? .red.opacity(0.8) : Color.buttonGreen.opacity(0.8)
            }
            if isSelected {
                return isDestructive ? .red : .buttonGreen
            }
            return .secondary.opacity(0.2)
        }()

        configuration.label
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(background)
            .foregroundStyle(isSelected ? .white : (isDestructive ? .red : .buttonGreen))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
