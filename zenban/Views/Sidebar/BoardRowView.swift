import SwiftUI

struct BoardRowView: View {
    let board: Board
    @Environment(BoardStore.self) private var store
    @State private var isRenaming = false
    @State private var newName = ""

    private let titleFont = Font.system(size: 13, weight: .semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isRenaming {
                TextField("Board name", text: $newName, onCommit: saveRename)
                    .textFieldStyle(.plain)
                    .font(titleFont)
            } else {
                Text(board.name)
                    .font(titleFont)
                    .lineLimit(1)
            }

            Text(board.createdAt.formatted(date: .numeric, time: .omitted))
                .font(.system(size: 11))
                .opacity(0.8)
        }
        .padding(.vertical, 4)
        .padding(.leading, 14)
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
