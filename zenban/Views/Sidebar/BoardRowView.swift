import SwiftUI
import AppKit

struct BoardRowView: View {
    let board: Board
    @Environment(BoardStore.self) private var store
    @State private var isRenaming = false
    @State private var newName = ""
    @FocusState private var isTextFieldFocused: Bool

    private let titleFont = Font.system(size: 13, weight: .semibold)

    private var isSelected: Bool {
        store.selectedBoardID == board.id
    }

    private var selectionColor: Color {
        if !isSelected { return .clear }
        return store.focusRegion == .sidebar
            ? Color.accentColor.opacity(0.75)
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    TextField("Board name", text: $newName, onCommit: saveRename)
                        .textFieldStyle(.plain)
                        .font(titleFont)
                        .focused($isTextFieldFocused)
                        .onExitCommand { isRenaming = false }
                        .onAppear { isTextFieldFocused = true }
                } else {
                    Text(board.name)
                        .font(titleFont)
                        .lineLimit(1)
                }

                Text(board.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if board.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectionColor)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedBoardID = board.id
            store.focusRegion = .sidebar
        }
        .contextMenu {
            Button {
                store.togglePin(board)
            } label: {
                Label(board.isPinned ? "Unpin" : "Pin", systemImage: board.isPinned ? "pin.slash" : "pin")
            }

            Button("Rename") {
                newName = board.name
                isRenaming = true
            }

            Button {
                revealFolder()
            } label: {
                Label("Reveal Folder", systemImage: "folder")
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

    private func revealFolder() {
        guard let path = board.repositoryPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
