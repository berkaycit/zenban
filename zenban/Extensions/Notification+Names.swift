import Foundation

extension Notification.Name {
    // Board commands
    static let newBoard = Notification.Name("newBoard")
    static let newCard = Notification.Name("newCard")

    // File browser
    static let closeFileBrowserTab = Notification.Name("closeFileBrowserTab")

    // Dev server
    static let reloadDevServer = Notification.Name("reloadDevServer")
}
