import Foundation

extension Notification.Name {
    // Board commands
    static let newBoard = Notification.Name("newBoard")
    static let newCard = Notification.Name("newCard")

    // File browser
    static let closeFileBrowserTab = Notification.Name("closeFileBrowserTab")

    // Dev server
    static let reloadDevServer = Notification.Name("reloadDevServer")

    // Ghostty terminal
    static let ghosttyDidUpdateScrollbar = Notification.Name("win.aizen.app.ghostty.didUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("win.aizen.app.ghostty.didUpdateCellSize")
    static let ghosttyDidSetTitle = Notification.Name("win.aizen.app.ghostty.didSetTitle")
    static let ghosttyConfigDidReload = Notification.Name("win.aizen.app.ghostty.configDidReload")
    static let ScrollbarKey = ghosttyDidUpdateScrollbar.rawValue + ".scrollbar"
    static let CellSizeKey = ghosttyDidUpdateCellSize.rawValue + ".cellSize"
    static let TitleKey = ghosttyDidSetTitle.rawValue + ".title"
}
