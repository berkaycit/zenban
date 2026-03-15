import SwiftUI

struct ColumnHeaderAction {
    let systemImage: String
    let isEnabled: Bool
    let helpText: String
    let accessibilityLabel: String
    let handler: () -> Void

    static func bulkDelete(in column: Column, isEnabled: Bool, handler: @escaping () -> Void) -> Self {
        Self(
            systemImage: "trash",
            isEnabled: isEnabled,
            helpText: String(
                localized: "Delete cards in column",
                defaultValue: "Delete cards in column"
            ),
            accessibilityLabel: column.bulkDeleteAccessibilityLabel,
            handler: handler
        )
    }
}

struct ColumnHeaderView: View {
    let column: Column
    let count: Int
    let action: ColumnHeaderAction?

    var body: some View {
        HStack {
            Circle()
                .fill(column.accentColor)
                .frame(width: 8, height: 8)

            Text(column.rawValue)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.countBackground)
                .clipShape(Capsule())
                .accessibilityLabel("\(count) cards")

            if let action {
                Button(action: action.handler) {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!action.isEnabled)
                .help(action.helpText)
                .accessibilityLabel(action.accessibilityLabel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.columnHeaderBackground)
    }
}
