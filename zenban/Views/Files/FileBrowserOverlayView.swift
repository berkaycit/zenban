import SwiftUI

struct FileBrowserOverlayView: View {
    let card: Card
    let boardID: UUID

    @Environment(BoardStore.self) private var boardStore
    @State private var store: FileBrowserStore?

    var body: some View {
        Group {
            if let worktreePath = card.worktreePath {
                if let store {
                    HSplitView {
                        VStack(spacing: 0) {
                            headerView(path: store.currentPath)

                            ScrollView {
                                FileTreeView(path: store.currentPath, store: store)
                                    .padding(.vertical, 4)
                            }
                        }
                        .frame(minWidth: 180, idealWidth: 260, maxWidth: 420)

                        FileContentTabView(store: store)
                            .frame(minWidth: 360)
                    }
                    .alert(item: Binding(
                        get: { store.alert },
                        set: { _ in store.alert = nil }
                    )) { alert in
                        Alert(
                            title: Text("File Browser"),
                            message: Text(alert.message),
                            dismissButton: .default(Text("OK"))
                        )
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                EmptyStateView(
                    icon: "folder",
                    title: "No Worktree Available",
                    subtitle: "Connect a repository to browse files."
                )
            }
        }
        .onAppear {
            guard store == nil, let worktreePath = card.worktreePath else { return }
            store = FileBrowserStore(
                rootPath: worktreePath,
                session: card.fileBrowserSession
            ) { session in
                boardStore.updateFileBrowserSession(card.id, in: boardID, session: session)
            }
        }
    }

    private func headerView(path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)

            Button {
                Clipboard.copy(path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Copy Path")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}
