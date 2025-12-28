import SwiftUI

struct BoardListView: View {
    @Environment(BoardStore.self) private var store
    @State private var isAddingBoard = false

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedBoardID) {
            ForEach(store.sortedBoards) { board in
                BoardRowView(board: board)
                    .tag(board.id)
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .navigationTitle(" ")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { isAddingBoard = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .controlSize(.large)
                .help("New Board")

                Button(action: { NotificationCenter.default.post(name: .newCard, object: nil) }) {
                    Image(systemName: "square.and.pencil")
                }
                .controlSize(.large)
                .help("New Task")
            }
        }
        .sheet(isPresented: $isAddingBoard) {
            AddBoardSheet(isPresented: $isAddingBoard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBoard)) { _ in
            isAddingBoard = true
        }
    }
}

private enum BoardCreationStep: Equatable {
    case selectType
    case enterName(repositoryPath: String?)
    case createRepository
}

struct AddBoardSheet: View {
    @Binding var isPresented: Bool
    @Environment(BoardStore.self) private var store
    @State private var step: BoardCreationStep = .selectType
    @State private var name = ""
    @State private var parentPath = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 16) {
            switch step {
            case .selectType:
                typeSelectionView
            case .enterName(let repoPath):
                nameEntryView(repositoryPath: repoPath)
            case .createRepository:
                createRepositoryView
            }
        }
        .padding(20)
        .frame(width: 350)
    }

    private var typeSelectionView: some View {
        VStack(spacing: 16) {
            Text("New Board")
                .font(.headline)

            Text("Select or create a repository for your project")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                optionButton(icon: "folder", title: "From Existing Directory", subtitle: "Select an existing folder from your system") {
                    DirectoryPicker.selectDirectory(title: "Select Directory") { url in
                        guard let url else { return }
                        name = url.lastPathComponent
                        step = .enterName(repositoryPath: url.path)
                    }
                }
                optionButton(icon: "plus.rectangle.on.folder", title: "Create New Repository", subtitle: "Initialize a new git repository") {
                    step = .createRepository
                }
                optionButton(icon: "doc", title: "Empty", subtitle: "Create a board without a directory") {
                    step = .enterName(repositoryPath: nil)
                }
            }

            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func optionButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func nameEntryView(repositoryPath: String?) -> some View {
        VStack(spacing: 16) {
            Text("Board Name").font(.headline)

            if let path = repositoryPath {
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            TextField("Board name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { finishCreation(repositoryPath: repositoryPath) }

            buttonRow(createDisabled: trimmedName.isEmpty) {
                finishCreation(repositoryPath: repositoryPath)
            }
        }
        .onAppear { isFocused = true }
    }

    private var createRepositoryView: some View {
        VStack(spacing: 16) {
            Text("Create Repository").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Repository Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-project", text: $name).textFieldStyle(.roundedBorder).focused($isFocused)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Parent Directory").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(parentPath.isEmpty ? "Select folder..." : (parentPath as NSString).lastPathComponent)
                        .foregroundStyle(parentPath.isEmpty ? .tertiary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Browse...") {
                        DirectoryPicker.selectDirectory(title: "Select Parent Folder") { url in
                            guard let url else { return }
                            parentPath = url.path
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                if !parentPath.isEmpty {
                    Text(parentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            buttonRow(createDisabled: trimmedName.isEmpty || parentPath.isEmpty) {
                createNewRepository()
            }
        }
        .onAppear { isFocused = true }
    }

    private func buttonRow(createDisabled: Bool, onCreate: @escaping () -> Void) -> some View {
        HStack {
            Button("Back") { resetToTypeSelection() }
            Spacer()
            Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            Button("Create", action: onCreate).keyboardShortcut(.defaultAction).disabled(createDisabled)
        }
    }

    private func resetToTypeSelection() {
        step = .selectType
        name = ""
        parentPath = ""
        errorMessage = nil
    }

    private func finishCreation(repositoryPath: String?) {
        guard !trimmedName.isEmpty else { return }
        store.createBoard(name: trimmedName, repositoryPath: repositoryPath)
        isPresented = false
    }

    private func createNewRepository() {
        guard !trimmedName.isEmpty, !parentPath.isEmpty else { return }
        Task {
            do {
                let repoPath = try await GitService.createRepository(name: trimmedName, parentPath: parentPath)
                store.createBoard(name: trimmedName, repositoryPath: repoPath)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
