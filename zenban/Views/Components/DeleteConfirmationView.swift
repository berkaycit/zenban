import AppKit
import SwiftUI

struct DeleteConfirmationView: View {
    let cardTitle: String
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "trash")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text("Delete Card?")
                .font(.headline)

            VStack(spacing: 4) {
                Text("Are you sure you want to delete")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\"\(cardTitle)\"?")
                    .font(.body.weight(.medium))
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel deletion")

                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Delete card")
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
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
