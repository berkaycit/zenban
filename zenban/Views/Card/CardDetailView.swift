import SwiftUI

struct CardDetailView: View {
    let card: Card
    let boardID: UUID
    @Environment(BoardStore.self) private var store
    @Environment(TerminalManager.self) private var terminalManager
    @State private var editedTitle = ""
    @State private var isEditing = false
    @State private var showTerminal = true
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardInfoSection
                .frame(height: showTerminal && terminalManager.isTerminalAvailable ? 240 : nil)
                .frame(maxHeight: showTerminal && terminalManager.isTerminalAvailable ? 240 : .infinity)

            if terminalManager.isTerminalAvailable {
                Divider()
                terminalSection
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.cardBackground)
        .onAppear {
            editedTitle = card.title
        }
        .onChange(of: card.id) {
            editedTitle = card.title
            isEditing = false
        }
    }

    private var cardInfoSection: some View {
        ScrollView {
            cardInfoContent
                .padding(20)
        }
    }

    private var cardInfoContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(card.column.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(card.column.accentColor)
                    .clipShape(Capsule())

                Spacer()

                Button(action: deleteCard) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                TextField("Card title", text: $editedTitle, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .lineLimit(1...10)
                    .focused($isFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand(perform: cancelEdit)

                HStack {
                    Button("Cancel", action: cancelEdit)
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: saveTitle)
                        .keyboardShortcut(.defaultAction)
                        .disabled(editedTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text(card.title)
                    .font(.title2)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        startEditing()
                    }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Created \(card.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Move to")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(Column.allCases) { column in
                        Button(action: { moveToColumn(column) }) {
                            Text(column.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(card.column == column ? column.accentColor : Color.secondary.opacity(0.2))
                                .foregroundStyle(card.column == column ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(card.column == column)
                    }
                }
            }
        }
    }

    private var terminalSection: some View {
        VStack(spacing: 0) {
            terminalHeader
            if showTerminal {
                TerminalContainerView(cardID: card.id, boardID: boardID, cardTitle: card.title)
                    .id(card.id)
                    .frame(minHeight: 200)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var terminalHeader: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Terminal")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: { showTerminal.toggle() }) {
                Image(systemName: showTerminal ? "chevron.down" : "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
    }

    private func startEditing() {
        editedTitle = card.title
        isEditing = true
        isFocused = true
    }

    private func saveTitle() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.updateCard(card.id, title: trimmed, in: boardID)
        isEditing = false
    }

    private func cancelEdit() {
        editedTitle = card.title
        isEditing = false
    }

    private func moveToColumn(_ column: Column) {
        store.moveCard(card.id, to: column, in: boardID)
    }

    private func deleteCard() {
        store.deleteCard(card.id, from: boardID)
    }
}
