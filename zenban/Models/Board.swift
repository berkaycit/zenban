import SwiftUI

enum Column: String, Codable, CaseIterable, Identifiable {
    case todo = "To Do"
    case inProgress = "In Progress"
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

struct Card: Identifiable, Codable, Hashable {
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
}

struct Board: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var cards: [Card]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, cards: [Card] = []) {
        self.id = id
        self.name = name
        self.cards = cards
        self.createdAt = Date()
    }

    func cards(in column: Column) -> [Card] {
        cards.filter { $0.column == column }
             .sorted { $0.orderIndex < $1.orderIndex }
    }

    var nextOrderIndex: Int {
        (cards.map(\.orderIndex).max() ?? -1) + 1
    }
}
