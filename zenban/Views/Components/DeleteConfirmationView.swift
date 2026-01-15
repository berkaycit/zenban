import SwiftUI

struct DeleteConfirmationView: View {
    let cardTitle: String
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var selectedOption: Option = .delete
    @FocusState private var isFocused: Bool

    private enum Option {
        case delete, cancel
    }

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
                Button(action: onDelete) {
                    Text("Delete")
                        .frame(width: 80)
                }
                .buttonStyle(ConfirmationButtonStyle(
                    isSelected: selectedOption == .delete,
                    isDestructive: true
                ))

                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(width: 80)
                }
                .buttonStyle(ConfirmationButtonStyle(
                    isSelected: selectedOption == .cancel,
                    isDestructive: false
                ))
            }
        }
        .padding(24)
        .frame(width: 320)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            selectedOption = .delete
            return .handled
        }
        .onKeyPress(.rightArrow) {
            selectedOption = .cancel
            return .handled
        }
        .onKeyPress(.return) {
            selectedOption == .delete ? onDelete() : onCancel()
            return .handled
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
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
