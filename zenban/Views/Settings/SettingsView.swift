import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case terminal = "Terminal"
    case devServer = "Dev Server"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .devServer: return "server.rack"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "App info"
        case .terminal: return "Font, theme, sessions"
        case .devServer: return "Setup and dev commands"
        }
    }
}

struct SettingsView: View {
    @Environment(BoardStore.self) private var store
    @State private var selectedCategory: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                sidebarRow(for: category)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedCategory.rawValue)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(selectedCategory.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider()

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 650, minHeight: 400)
    }

    private func sidebarRow(for category: SettingsCategory) -> some View {
        let isSelected = selectedCategory == category
        return HStack(spacing: 12) {
            Image(systemName: category.icon)
                .frame(width: 20)
                .foregroundStyle(isSelected ? .white : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(category.subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.vertical, 4)
        .tag(category)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsView()
        case .terminal:
            TerminalSettingsView()
        case .devServer:
            DevServerSettingsView(boardID: store.selectedBoardID)
        }
    }
}
