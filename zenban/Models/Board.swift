import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let card = UTType(exportedAs: "com.berkaycit.zenban.card")
}

enum Column: String, Codable, CaseIterable, Identifiable {
    case todo = "To Do"
    case inProgress = "In Review"
    case done = "Done"

    var id: String { rawValue }

    var accentColor: Color {
        switch self {
        case .todo: .blue
        case .inProgress: .orange
        case .done: .green
        }
    }
}

enum Agent: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"
    case gemini = "Gemini"

    var id: String { rawValue }

    var launchCommand: String {
        switch self {
        case .claude: "claude --dangerously-skip-permissions"
        case .codex: "codex --yolo"
        case .gemini: "gemini --yolo"
        }
    }

    var autoNamePrefix: String {
        switch self {
        case .claude: "cc"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }
}

struct DevServerConfig: Codable, Hashable {
    var setupCommand: String?
    var devCommand: String
    var skipSetup: Bool

    init(setupCommand: String?, devCommand: String, skipSetup: Bool = false) {
        self.setupCommand = setupCommand
        self.devCommand = devCommand
        self.skipSetup = skipSetup
    }
}

struct Card: Identifiable, Codable, Hashable, Transferable {
    let id: UUID
    var title: String
    var column: Column
    var createdAt: Date
    var orderIndex: Int
    var agent: Agent?
    var worktreePath: String?
    var fileBrowserSession: FileBrowserSessionState?

    init(
        id: UUID = UUID(),
        title: String,
        column: Column = .todo,
        orderIndex: Int = 0,
        agent: Agent? = nil,
        worktreePath: String? = nil,
        fileBrowserSession: FileBrowserSessionState? = nil
    ) {
        self.id = id
        self.title = title
        self.column = column
        self.createdAt = Date()
        self.orderIndex = orderIndex
        self.agent = agent
        self.worktreePath = worktreePath
        self.fileBrowserSession = fileBrowserSession
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .card)
    }
}

struct Board: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var cards: [Card]
    var createdAt: Date
    var isPinned: Bool
    var repositoryPath: String?
    var agent: Agent
    var devServerConfig: DevServerConfig?
    var agentCounters: [String: Int] = [:]

    init(id: UUID = UUID(), name: String, cards: [Card] = [], isPinned: Bool = false, repositoryPath: String? = nil, agent: Agent = .claude, devServerConfig: DevServerConfig? = nil, agentCounters: [String: Int] = [:]) {
        self.id = id
        self.name = name
        self.cards = cards
        self.createdAt = Date()
        self.isPinned = isPinned
        self.repositoryPath = repositoryPath
        self.agent = agent
        self.devServerConfig = devServerConfig
        self.agentCounters = agentCounters
    }

    func cards(in column: Column) -> [Card] {
        cards.filter { $0.column == column }
             .sorted { $0.orderIndex < $1.orderIndex }
    }

    var nextOrderIndex: Int {
        (cards.map(\.orderIndex).min() ?? 1) - 1
    }

    mutating func nextAutoName(for agent: Agent) -> String {
        let prefix = agent.autoNamePrefix
        let counter = (agentCounters[prefix] ?? 0) + 1
        agentCounters[prefix] = counter
        return "\(prefix)-\(counter)"
    }
}
