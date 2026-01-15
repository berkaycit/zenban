import SwiftUI

struct FileContentTabView: View {
    @Bindable var store: FileBrowserStore

    private func selectPreviousTab() {
        guard let currentId = store.selectedFileId,
              let currentIndex = store.openFiles.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        store.selectedFileId = store.openFiles[currentIndex - 1].id
    }

    private func selectNextTab() {
        guard let currentId = store.selectedFileId,
              let currentIndex = store.openFiles.firstIndex(where: { $0.id == currentId }),
              currentIndex < store.openFiles.count - 1 else { return }
        store.selectedFileId = store.openFiles[currentIndex + 1].id
    }

    private func canCloseToLeft(of fileId: UUID) -> Bool {
        guard let index = store.openFiles.firstIndex(where: { $0.id == fileId }) else { return false }
        return index > 0
    }

    private func canCloseToRight(of fileId: UUID) -> Bool {
        guard let index = store.openFiles.firstIndex(where: { $0.id == fileId }) else { return false }
        return index < store.openFiles.count - 1
    }

    private func closeAllToLeft(of fileId: UUID) {
        guard let index = store.openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        for i in (0..<index).reversed() {
            store.closeFile(id: store.openFiles[i].id)
        }
    }

    private func closeAllToRight(of fileId: UUID) {
        guard let index = store.openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        for i in ((index + 1)..<store.openFiles.count).reversed() {
            store.closeFile(id: store.openFiles[i].id)
        }
    }

    private func closeOtherTabs(except fileId: UUID) {
        for file in store.openFiles where file.id != fileId {
            store.closeFile(id: file.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.openFiles.isEmpty {
                EmptyStateView(
                    icon: "doc.text",
                    title: "No files open",
                    subtitle: "Select a file from the tree to open"
                )
            } else {
                HStack(spacing: 0) {
                    Button(action: selectPreviousTab) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 24, height: 36)
                    .disabled(store.openFiles.count <= 1)

                    Button(action: selectNextTab) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 24, height: 36)
                    .disabled(store.openFiles.count <= 1)

                    Divider()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(store.openFiles) { file in
                                FileTab(
                                    file: file,
                                    isSelected: store.selectedFileId == file.id,
                                    onSelect: { store.selectedFileId = file.id },
                                    onClose: { store.closeFile(id: file.id) }
                                )
                                .contextMenu {
                                    Button("Close") {
                                        store.closeFile(id: file.id)
                                    }

                                    Divider()

                                    Button("Close All to the Left") {
                                        closeAllToLeft(of: file.id)
                                    }
                                    .disabled(!canCloseToLeft(of: file.id))

                                    Button("Close All to the Right") {
                                        closeAllToRight(of: file.id)
                                    }
                                    .disabled(!canCloseToRight(of: file.id))

                                    Divider()

                                    Button("Close Other Tabs") {
                                        closeOtherTabs(except: file.id)
                                    }
                                    .disabled(store.openFiles.count <= 1)
                                }
                            }
                        }
                    }
                }
                .frame(height: 36)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1),
                    alignment: .top
                )

                Divider()

                if let selectedFile = store.openFiles.first(where: { $0.id == store.selectedFileId }) {
                    FileContentView(
                        file: selectedFile,
                        onContentChange: { newContent in
                            store.updateFileContent(id: selectedFile.id, content: newContent)
                        },
                        onSave: {
                            Task { await store.saveFile(id: selectedFile.id) }
                        },
                        onRevert: {
                            Task { await store.revertFile(id: selectedFile.id) }
                        }
                    )
                }
            }
        }
    }
}

struct FileTab: View {
    let file: OpenFileInfo
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(path: file.path, size: 12)
            Text(file.name)
                .font(.system(size: 12))
                .lineLimit(1)

            if file.hasUnsavedChanges {
                Circle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 6, height: 6)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.secondary.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
