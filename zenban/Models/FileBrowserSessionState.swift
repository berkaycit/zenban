import Foundation

nonisolated struct FileBrowserSessionState: Codable, Hashable, Sendable {
    var currentPath: String?
    var expandedPaths: [String]
    var openFilePaths: [String]
    var selectedFilePath: String?

    init(
        currentPath: String? = nil,
        expandedPaths: [String] = [],
        openFilePaths: [String] = [],
        selectedFilePath: String? = nil
    ) {
        self.currentPath = currentPath
        self.expandedPaths = expandedPaths
        self.openFilePaths = openFilePaths
        self.selectedFilePath = selectedFilePath
    }
}
