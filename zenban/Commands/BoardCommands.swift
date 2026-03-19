import Foundation
import SwiftUI

struct BoardCommands: Commands {
    let store: BoardStore
    let cmuxHost: CmuxHostStore

    private var refreshPreviewCard: Card? {
        guard let card = store.devServerCard,
              cmuxHost.browserSurface(for: card.id) != nil else {
            return nil
        }
        return card
    }

    var body: some Commands {
        let refreshPreviewCard = refreshPreviewCard

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
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)

            Button("Toggle Dev Server") {
                store.toggleDevServer()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(store.selectedCardID == nil)

            Button("Refresh Dev Server Preview") {
                guard let card = refreshPreviewCard else { return }
                _ = cmuxHost.reloadBrowserSurface(for: card.id)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(refreshPreviewCard == nil)

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

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                store.showKeyboardShortcuts = true
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}
