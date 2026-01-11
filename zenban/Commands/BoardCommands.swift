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
                store.requestDeleteSelectedCard()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)

            Button("Toggle Dev Server") {
                store.toggleDevServer()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)

            Button("Reload Dev Server") {
                NotificationCenter.default.post(name: .reloadDevServer, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!store.showDevServer)

            Button("Toggle Git Changes") {
                store.toggleGitChanges()
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)

            Button("Toggle File Browser") {
                store.toggleFileBrowser()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)
        }
    }
}
