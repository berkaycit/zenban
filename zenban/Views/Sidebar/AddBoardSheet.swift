import SwiftUI

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
    @State private var selectedAgent: Agent = .claude
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .selectType:
                typeSelectionView
            case .enterName(let repoPath):
                nameEntryView(repositoryPath: repoPath)
            case .createRepository:
                createRepositoryView
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var typeSelectionView: some View {
        VStack(spacing: 20) {
            Text("New Board")
                .font(.title3).fontWeight(.semibold)

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
                .controlSize(.large)
        }
    }

    private func optionButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color.inputBackground)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func nameEntryView(repositoryPath: String?) -> some View {
        VStack(spacing: 20) {
            Text("Board Name").font(.title3).fontWeight(.semibold)

            if let path = repositoryPath {
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            TextField("Board name", text: $name)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { finishCreation(repositoryPath: repositoryPath) }
                .padding(10)
                .background(Color.inputBackground)
                .cornerRadius(10)

            agentPicker

            buttonRow(createDisabled: trimmedName.isEmpty) {
                finishCreation(repositoryPath: repositoryPath)
            }
        }
        .onAppear { isFocused = true }
    }

    private var createRepositoryView: some View {
        VStack(spacing: 20) {
            Text("Create Repository").font(.title3).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Repository Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-project", text: $name)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .padding(10)
                    .background(Color.inputBackground)
                    .cornerRadius(10)
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
                .padding(10)
                .background(Color.inputBackground)
                .cornerRadius(10)

                if !parentPath.isEmpty {
                    Text(parentPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            agentPicker

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            buttonRow(createDisabled: trimmedName.isEmpty || parentPath.isEmpty) {
                createNewRepository()
            }
        }
        .onAppear { isFocused = true }
    }

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent").font(.caption).foregroundStyle(.secondary)
            Picker("Agent", selection: $selectedAgent) {
                ForEach(Agent.allCases) { agent in
                    Text(agent.rawValue).tag(agent)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .background(Color.inputBackground)
            .cornerRadius(10)
        }
    }

    private func buttonRow(createDisabled: Bool, onCreate: @escaping () -> Void) -> some View {
        HStack {
            Button("Back") { resetToTypeSelection() }
                .controlSize(.large)
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Create", action: onCreate)
                .keyboardShortcut(.defaultAction)
                .disabled(createDisabled)
                .controlSize(.large)
        }
    }

    private func resetToTypeSelection() {
        step = .selectType
        name = ""
        parentPath = ""
        selectedAgent = .claude
        errorMessage = nil
    }

    private func finishCreation(repositoryPath: String?) {
        guard !trimmedName.isEmpty else { return }
        store.createBoard(name: trimmedName, repositoryPath: repositoryPath, agent: selectedAgent)
        isPresented = false
    }

    private func createNewRepository() {
        guard !trimmedName.isEmpty, !parentPath.isEmpty else { return }
        Task {
            do {
                let repoPath = try await GitService.createRepository(name: trimmedName, parentPath: parentPath)
                store.createBoard(name: trimmedName, repositoryPath: repoPath, agent: selectedAgent)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
