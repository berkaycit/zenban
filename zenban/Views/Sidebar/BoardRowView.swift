import SwiftUI

struct BoardRowView: View {
    let board: Board
    @Environment(BoardStore.self) private var store
    @State private var isRenaming = false
    @State private var newName = ""

    var body: some View {
        HStack {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Board name", text: $newName, onCommit: saveRename)
                    .textFieldStyle(.plain)
            } else {
                Text(board.name)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(board.cards.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Rename") {
                newName = board.name
                isRenaming = true
            }

            Divider()

            Button("Delete", role: .destructive) {
                store.deleteBoard(board)
            }
        }
    }

    private func saveRename() {
        let trimmedName = newName.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            store.renameBoard(board, to: trimmedName)
        }
        isRenaming = false
    }
}
