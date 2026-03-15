import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [(String, [(String, String)])] = [
        ("Navigation", [
            ("Cmd+Shift+Up/Down", "Navigate cards/boards"),
            ("Cmd+Shift+Left/Right", "Move between columns"),
        ]),
        ("Boards & Cards", [
            ("Cmd+Shift+N", "New board"),
            ("Cmd+Shift+A", "New card"),
            ("Cmd+Shift+E", "Delete card"),
        ]),
        ("Panels", [
            ("Cmd+Shift+F", "Toggle file browser"),
            ("Cmd+Shift+X", "Toggle git changes"),
            ("Cmd+Shift+S", "Toggle dev server"),
            ("Cmd+Shift+R", "Reload dev server"),
            ("Cmd+W", "Close file tab"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(shortcuts, id: \.0) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.0)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(section.1, id: \.0) { shortcut in
                        HStack {
                            Text(shortcut.0)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 180, alignment: .leading)
                            Text(shortcut.1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
