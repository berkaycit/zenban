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

struct Card: Identifiable, Codable, Hashable, Transferable {
    let id: UUID
    var title: String
    var column: Column
    var createdAt: Date
    var orderIndex: Int

    init(id: UUID = UUID(), title: String, column: Column = .todo, orderIndex: Int = 0) {
        self.id = id
        self.title = title
        self.column = column
        self.createdAt = Date()
        self.orderIndex = orderIndex
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

    init(id: UUID = UUID(), name: String, cards: [Card] = [], isPinned: Bool = false, repositoryPath: String? = nil) {
        self.id = id
        self.name = name
        self.cards = cards
        self.createdAt = Date()
        self.isPinned = isPinned
        self.repositoryPath = repositoryPath
    }

    func cards(in column: Column) -> [Card] {
        cards.filter { $0.column == column }
             .sorted { $0.orderIndex < $1.orderIndex }
    }

    var nextOrderIndex: Int {
        (cards.map(\.orderIndex).min() ?? 1) - 1
    }
}
