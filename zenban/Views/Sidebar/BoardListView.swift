import SwiftUI

struct BoardListView: View {
    @Environment(BoardStore.self) private var store
    @State private var isAddingBoard = false

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedBoardID) {
            ForEach(store.boards) { board in
                BoardRowView(board: board)
                    .tag(board.id)
            }
            .onDelete(perform: deleteBoards)
        }
        .listStyle(.sidebar)
        .navigationTitle("Boards")
        .toolbar {
            ToolbarItem {
                Button(action: { isAddingBoard = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingBoard) {
            AddBoardSheet(isPresented: $isAddingBoard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBoard)) { _ in
            isAddingBoard = true
        }
    }

    private func deleteBoards(at offsets: IndexSet) {
        for index in offsets {
            store.deleteBoard(store.boards[index])
        }
    }
}

struct AddBoardSheet: View {
    @Binding var isPresented: Bool
    @Environment(BoardStore.self) private var store
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("New Board")
                .font(.headline)

            TextField("Board name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(createBoard)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create", action: createBoard)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            isFocused = true
        }
    }

    private func createBoard() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        store.createBoard(name: trimmedName)
        isPresented = false
    }
}
