import SwiftUI

struct CommitSheet: View {
    let worktreePath: String
    @Binding var isPresented: Bool
    let onCommit: () -> Void

    @State private var summary = ""
    @State private var description = ""
    @State private var isCommitting = false
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @FocusState private var isShortcutScopeFocused: Bool

    private var canCommit: Bool {
        !summary.trimmingCharacters(in: .whitespaces).isEmpty && !isCommitting
    }

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            formContent
        }
        .padding(24)
        .frame(width: 450)
        .focusable()
        .focused($isShortcutScopeFocused)
        .onAppear { isShortcutScopeFocused = true }
        .task {
            generateWithAI()
        }
        .backport.onKeyPress(KeyEquivalent("c"), action: handleCommitShortcut)
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Commit Changes")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Create a commit with your changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            // Summary field (required)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("(required)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                TextField("Brief description of changes", text: $summary)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .backport.onKeyPress(KeyEquivalent("c"), action: handleCommitShortcut)
            }

            // Description field (optional)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: generateWithAI) {
                        HStack(spacing: 4) {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text("Generate with AI")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(isGenerating)
                }

                TextEditor(text: $description)
                    .font(.body)
                    .frame(height: 100)
                    .padding(6)
                    .background(Color.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .scrollContentBackground(.hidden)
                    .backport.onKeyPress(KeyEquivalent("c"), action: handleCommitShortcut)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: { isPresented = false }) {
                    Text("Cancel")
                        .frame(width: 80)
                }
                .buttonStyle(ConfirmationButtonStyle(isSelected: true, isDestructive: true))
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: commit) {
                    HStack(spacing: 4) {
                        if isCommitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Commit")
                    }
                    .frame(width: 80)
                }
                .buttonStyle(ConfirmationButtonStyle(isSelected: true, isDestructive: false))
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
            }
        }
    }

    // MARK: - Actions

    private func generateWithAI() {
        isGenerating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let result = try await GitService.generateCommitMessage(worktreePath: worktreePath)
                summary = result.summary
                description = result.description
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func handleCommitShortcut(_ modifiers: EventModifiers) -> BackportKeyPressResult {
        guard modifiers == [.command, .shift] else { return .ignored }
        guard canCommit else { return .handled }
        commit()
        return .handled
    }

    private func commit() {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
        guard !trimmedSummary.isEmpty else { return }

        isCommitting = true
        errorMessage = nil

        // Build commit message
        var message = trimmedSummary
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            message += "\n\n\(trimmedDescription)"
        }

        Task {
            do {
                try await GitService.commitAll(worktreePath: worktreePath, message: message)
                isCommitting = false
                isPresented = false
                onCommit()
            } catch {
                errorMessage = error.localizedDescription
                isCommitting = false
            }
        }
    }
}
