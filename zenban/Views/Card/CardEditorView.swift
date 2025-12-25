import SwiftUI

struct CardEditorView: View {
    let boardID: UUID
    @Binding var isPresented: Bool
    @Environment(BoardStore.self) private var store
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("New Card")
                .font(.headline)

            TextField("Card title", text: $title, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isFocused)
                .onSubmit(save)

            HStack {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            isFocused = true
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        store.addCard(title: trimmedTitle, to: boardID)
        isPresented = false
    }
}
