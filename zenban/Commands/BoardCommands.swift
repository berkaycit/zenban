import SwiftUI

struct BoardCommands: Commands {
    let store: BoardStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Board") {
                NotificationCenter.default.post(name: .newBoard, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Card") {
                NotificationCenter.default.post(name: .newCard, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(store.selectedBoard == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button("Delete Card") {
                store.deleteSelectedCard()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)
        }
    }
}

extension Notification.Name {
    static let newBoard = Notification.Name("newBoard")
    static let newCard = Notification.Name("newCard")
}
