import SwiftUI

struct FileTreeView: View {
    let path: String
    let level: Int
    @Bindable var store: FileBrowserStore

    init(path: String, level: Int = 0, store: FileBrowserStore) {
        self.path = path
        self.level = level
        self.store = store
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(store.items(for: path)) { item in
                FileTreeItem(item: item, level: level, store: store)
            }
        }
        .onAppear {
            store.loadDirectory(path: path)
        }
    }
}

struct FileTreeItem: View {
    let item: FileItem
    let level: Int
    @Bindable var store: FileBrowserStore

    @State private var isHovering = false
    @State private var showingDialog: FileInputDialogType?
    @State private var showingDeleteAlert = false

    private var isExpanded: Bool {
        store.isExpanded(path: item.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if level > 0 {
                    Color.clear
                        .frame(width: CGFloat(level * 16))
                }

                if item.isDirectory {
                    Button(action: { store.toggleExpanded(path: item.path) }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 12, height: 12)
                }

                FileIconView(path: item.path, size: 12)
                    .opacity(item.isHidden ? 0.6 : 1.0)

                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .opacity(item.isHidden ? 0.6 : 1.0)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isHovering ? Color.inputBackground : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if item.isDirectory {
                    store.toggleExpanded(path: item.path)
                } else {
                    Task { await store.openFile(path: item.path) }
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .contextMenu {
                if item.isDirectory {
                    Button("New File...") { showingDialog = .newFile }
                    Button("New Folder...") { showingDialog = .newFolder }
                    Divider()
                }

                Button("Rename...") { showingDialog = .rename }
                Button("Delete") { showingDeleteAlert = true }
                Divider()
                Button("Copy Path") { store.copyPath(item.path) }
                Button("Reveal in Finder") { store.revealInFinder(item.path) }
            }
            .alert("Delete \(item.name)?", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await store.deleteItem(path: item.path) }
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .sheet(item: $showingDialog) { dialogType in
                FileInputDialog(
                    type: dialogType,
                    initialValue: dialogType == .rename ? item.name : "",
                    onSubmit: { name in
                        Task {
                            switch dialogType {
                            case .newFile:
                                await store.createNewFile(parentPath: item.path, name: name)
                            case .newFolder:
                                await store.createNewFolder(parentPath: item.path, name: name)
                            case .rename:
                                await store.renameItem(oldPath: item.path, newName: name)
                            }
                        }
                        showingDialog = nil
                    },
                    onCancel: { showingDialog = nil }
                )
            }

            if item.isDirectory && isExpanded {
                FileTreeView(path: item.path, level: level + 1, store: store)
            }
        }
    }
}
