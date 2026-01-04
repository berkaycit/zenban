import SwiftUI

enum FileInputDialogType {
    case newFile
    case newFolder
    case rename

    var title: String {
        switch self {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        }
    }

    var placeholder: String {
        switch self {
        case .newFile: return "filename.txt"
        case .newFolder: return "folder"
        case .rename: return "new name"
        }
    }
}

struct FileInputDialog: View {
    let type: FileInputDialogType
    let initialValue: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var inputText: String
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(
        type: FileInputDialogType,
        initialValue: String = "",
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.type = type
        self.initialValue = initialValue
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _inputText = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(type.title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                TextField(type.placeholder, text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(validateAndSubmit)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(type == .rename ? "Rename" : "Create", action: validateAndSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            isFocused = true
        }
    }

    private func validateAndSubmit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            errorMessage = "Name cannot be empty"
            return
        }

        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        if trimmed.rangeOfCharacter(from: invalidChars) != nil {
            errorMessage = "Name contains invalid characters"
            return
        }

        if trimmed == "." || trimmed == ".." {
            errorMessage = "Invalid name"
            return
        }

        errorMessage = nil
        onSubmit(trimmed)
    }
}

extension FileInputDialogType: Identifiable {
    var id: String {
        switch self {
        case .newFile: return "newFile"
        case .newFolder: return "newFolder"
        case .rename: return "rename"
        }
    }
}
