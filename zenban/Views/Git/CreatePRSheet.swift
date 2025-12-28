import SwiftUI
import AppKit

struct CreatePRSheet: View {
    let card: Card
    let worktreePath: String
    let baseBranch: String
    @Binding var isPresented: Bool

    @State private var config: PRConfig
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var availableBranches: [BranchInfo] = []
    @State private var isGeneratingDescription = false
    @State private var createdPRUrl: String?

    init(card: Card, worktreePath: String, baseBranch: String, isPresented: Binding<Bool>) {
        self.card = card
        self.worktreePath = worktreePath
        self.baseBranch = baseBranch
        self._isPresented = isPresented
        self._config = State(initialValue: PRConfig(cardTitle: card.title, baseBranch: baseBranch))
    }

    var body: some View {
        VStack(spacing: 20) {
            headerSection

            if let prUrl = createdPRUrl {
                successView(prUrl)
            } else {
                formContent
            }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear { loadBranches() }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Pull Request")
                    .font(.title3)
                    .fontWeight(.semibold)

                if createdPRUrl == nil {
                    Text("Create a pull request for this task")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var formContent: some View {
        VStack(spacing: 16) {
            // Title field
            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("PR Title", text: $config.title)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Description field
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: generateDescription) {
                        HStack(spacing: 4) {
                            if isGeneratingDescription {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text("Auto-generate")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(isGeneratingDescription)
                }

                TextEditor(text: $config.description)
                    .font(.body)
                    .frame(height: 120)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .scrollContentBackground(.hidden)
            }

            // Base branch picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Base Branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Base Branch", selection: $config.baseBranch) {
                    ForEach(availableBranches.filter { !$0.isCurrent }) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Draft toggle
            Toggle("Create as draft", isOn: $config.isDraft)
                .font(.body)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: createPR) {
                    HStack(spacing: 4) {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Create PR")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(config.title.isEmpty ? Color.accentColor.opacity(0.5) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(config.title.isEmpty || isCreating)
            }
        }
    }

    private func successView(_ prUrl: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Pull Request Created")
                .font(.headline)

            Text(prUrl)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prUrl, forType: .string)
                }

                Button("Open in Browser") {
                    if let url = URL(string: prUrl) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Done") {
                isPresented = false
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Actions

    private func loadBranches() {
        Task {
            guard let branches = try? await GitService.listBranches(repositoryPath: worktreePath) else { return }
            availableBranches = branches
        }
    }

    private func generateDescription() {
        isGeneratingDescription = true

        Task {
            config.description = (try? await GitService.generatePRDescription(worktreePath: worktreePath)) ?? ""
            isGeneratingDescription = false
        }
    }

    private func createPR() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let result = try await GitService.createPR(worktreePath: worktreePath, config: config)
                createdPRUrl = result.url
                isCreating = false
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
