import SwiftUI

struct ColumnHeaderView: View {
    let column: Column
    let count: Int

    private var accentColor: Color {
        switch column {
        case .todo: return .blue
        case .inProgress: return .orange
        case .done: return .green
        }
    }

    var body: some View {
        HStack {
            Circle()
                .fill(accentColor)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.columnHeaderBackground)
    }
}
