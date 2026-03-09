import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

struct CodeEditorView: View {
    let content: String
    let language: CodeLanguage
    var isEditable: Bool = false
    var onContentChange: ((String) -> Void)?

    @State private var text: String
    @State private var editorState = SourceEditorState()
    @Environment(\.colorScheme) private var colorScheme

    init(
        content: String,
        language: CodeLanguage,
        isEditable: Bool = false,
        onContentChange: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.language = language
        self.isEditable = isEditable
        self.onContentChange = onContentChange
        _text = State(initialValue: content)
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: editorTheme,
                    font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: true
                ),
                behavior: .init(
                    indentOption: .spaces(count: 4)
                ),
                peripherals: .init(
                    showGutter: true,
                    showMinimap: false
                )
            ),
            state: $editorState
        )
        .disabled(!isEditable)
        .clipped()
        .onChange(of: content) {
            if text != content {
                text = content
            }
        }
        .onChange(of: text) {
            guard isEditable else { return }
            onContentChange?(text)
        }
    }

    private var editorTheme: EditorTheme {
        if colorScheme == .dark {
            let bg = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
            let fg = NSColor(calibratedWhite: 0.9, alpha: 1.0)
            return EditorTheme(
                text: .init(color: fg),
                insertionPoint: fg,
                invisibles: .init(color: .systemGray),
                background: bg,
                lineHighlight: bg.withAlphaComponent(0.2),
                selection: .selectedTextBackgroundColor,
                keywords: .init(color: .systemPurple),
                commands: .init(color: .systemBlue),
                types: .init(color: .systemYellow),
                attributes: .init(color: .systemRed),
                variables: .init(color: .systemBlue),
                values: .init(color: .systemOrange),
                numbers: .init(color: .systemOrange),
                strings: .init(color: .systemGreen),
                characters: .init(color: .systemGreen),
                comments: .init(color: .systemGray)
            )
        }

        let bg = NSColor.textBackgroundColor
        let fg = NSColor.labelColor
        return EditorTheme(
            text: .init(color: fg),
            insertionPoint: fg,
            invisibles: .init(color: .systemGray),
            background: bg,
            lineHighlight: bg.withAlphaComponent(0.06),
            selection: .selectedTextBackgroundColor,
            keywords: .init(color: .systemPurple),
            commands: .init(color: .systemBlue),
            types: .init(color: .systemOrange),
            attributes: .init(color: .systemRed),
            variables: .init(color: .systemBlue),
            values: .init(color: .systemOrange),
            numbers: .init(color: .systemOrange),
            strings: .init(color: .systemGreen),
            characters: .init(color: .systemGreen),
            comments: .init(color: .systemGray)
        )
    }
}
