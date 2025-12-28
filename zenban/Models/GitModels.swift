import Foundation

// MARK: - Git Status Models

struct GitStatus: Equatable {
    let branch: String
    let filesChanged: [FileChange]
    let totalAdditions: Int
    let totalDeletions: Int

    var isEmpty: Bool { filesChanged.isEmpty }
}

struct FileChange: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let status: FileStatus
    let additions: Int
    let deletions: Int
    var diffContent: String?

    enum FileStatus: String {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case untracked = "?"
    }
}

// MARK: - PR Configuration

struct PRConfig {
    var title: String
    var description: String
    var baseBranch: String
    var isDraft: Bool

    init(cardTitle: String, baseBranch: String = "main") {
        self.title = cardTitle
        self.description = ""
        self.baseBranch = baseBranch
        self.isDraft = false
    }
}

struct PRResult {
    let url: String
    let number: Int
}

// MARK: - Branch Info

struct BranchInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
    let isRemote: Bool
}
