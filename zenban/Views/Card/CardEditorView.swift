import SwiftUI

struct CardEditorView: View {
    let boardID: UUID
    var card: Card?
    @Binding var isPresented: Bool
    @Environment(BoardStore.self) private var store
    @State private var title: String = ""
    @FocusState private var isFocused: Bool

    private var isEditing: Bool { card != nil }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "Edit Card" : "New Card")
                .font(.headline)

            TextField("Card title", text: $title, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isFocused)
                .onSubmit(save)

            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        if let card = card {
                            store.deleteCard(card.id, from: boardID)
                        }
                        isPresented = false
                    }
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            title = card?.title ?? ""
            isFocused = true
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        if let card = card {
            store.updateCard(card.id, title: trimmedTitle, in: boardID)
        } else {
            store.addCard(title: trimmedTitle, to: boardID)
        }
        isPresented = false
    }
}
