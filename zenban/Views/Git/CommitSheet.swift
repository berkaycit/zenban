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

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            formContent
        }
        .padding(24)
        .frame(width: 450)
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
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Description field (optional)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: generateMessage) {
                        HStack(spacing: 4) {
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.5)
                            }
                            Text("Auto-generate")
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
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .scrollContentBackground(.hidden)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: commit) {
                    HStack(spacing: 4) {
                        if isCommitting {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text("Commit")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(summary.trimmingCharacters(in: .whitespaces).isEmpty ? Color.accentColor.opacity(0.5) : Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty || isCommitting)
            }
        }
    }

    // MARK: - Actions

    private func generateMessage() {
        isGenerating = true

        Task {
            guard let diffStats = try? await GitService.getDiffStats(worktreePath: worktreePath) else {
                isGenerating = false
                return
            }

            let fileCount = diffStats.count
            let additions = diffStats.reduce(0) { $0 + $1.additions }
            let deletions = diffStats.reduce(0) { $0 + $1.deletions }
            let fileNames = diffStats.map { $0.path }.joined(separator: "\n- ")

            if summary.isEmpty {
                summary = "Update \(fileCount) file\(fileCount == 1 ? "" : "s") (+\(additions) -\(deletions))"
            }
            if !fileNames.isEmpty {
                description = "Changed files:\n- \(fileNames)"
            }
            isGenerating = false
        }
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
