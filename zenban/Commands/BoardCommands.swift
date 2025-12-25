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
            .keyboardShortcut("n", modifiers: .command)
            .disabled(store.selectedBoard == nil)
        }
    }
}

extension Notification.Name {
    static let newBoard = Notification.Name("newBoard")
    static let newCard = Notification.Name("newCard")
}
