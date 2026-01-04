import SwiftUI

struct FileContentView: View {
    let file: OpenFileInfo
    let onContentChange: (String) -> Void
    let onSave: () -> Void
    let onRevert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    let pathComponents = file.path.split(separator: "/").map(String.init)
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        Text(component)
                            .font(.system(size: 11))
                            .foregroundColor(index == pathComponents.count - 1 ? .primary : .secondary)
                    }
                }
                .textSelection(.enabled)

                Button {
                    Clipboard.copy(file.path)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy Path")

                Spacer()

                if file.hasUnsavedChanges {
                    Button("Revert", action: onRevert)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .keyboardShortcut("r", modifiers: [.command])

                    Button("Save", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut("s", modifiers: [.command])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            CodeEditorView(
                content: file.content,
                language: LanguageDetection.codeLanguage(for: file.path),
                isEditable: true,
                onContentChange: onContentChange
            )
            .id(file.id)
        }
        .id(file.id)
    }
}
