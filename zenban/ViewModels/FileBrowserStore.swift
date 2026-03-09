import Foundation
import SwiftUI
import AppKit
import Observation

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let isHidden: Bool

    init(name: String, path: String, isDirectory: Bool, isHidden: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isHidden = isHidden
    }
}

nonisolated struct OpenFileInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
    var content: String
    var hasUnsavedChanges: Bool

    init(id: UUID = UUID(), name: String, path: String, content: String, hasUnsavedChanges: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.content = content
        self.hasUnsavedChanges = hasUnsavedChanges
    }

    static func == (lhs: OpenFileInfo, rhs: OpenFileInfo) -> Bool {
        lhs.id == rhs.id
    }
}

nonisolated struct FileBrowserAlert: Identifiable, Sendable {
    let id = UUID()
    let message: String
}

@MainActor
@Observable
final class FileBrowserStore {
    let rootPath: String
    var currentPath: String
    var expandedPaths: Set<String>
    var openFiles: [OpenFileInfo] = []
    var selectedFileId: UUID?
    var directoryItems: [String: [FileItem]] = [:]
    var loadingPaths: Set<String> = []
    var alert: FileBrowserAlert?

    @ObservationIgnored private let fileService = FileService()
    @ObservationIgnored private let maxOpenFileBytes = 5 * 1024 * 1024
    @ObservationIgnored private let onSessionUpdate: (FileBrowserSessionState) -> Void

    // LRU cache eviction for directory items
    @ObservationIgnored private var directoryAccessOrder: [String] = []
    @ObservationIgnored private let maxCachedDirectories = 50

    init(
        rootPath: String,
        session: FileBrowserSessionState?,
        onSessionUpdate: @escaping (FileBrowserSessionState) -> Void
    ) {
        self.rootPath = rootPath
        self.currentPath = session?.currentPath ?? rootPath
        self.expandedPaths = Set(session?.expandedPaths ?? [])
        self.onSessionUpdate = onSessionUpdate

        loadDirectory(path: self.currentPath)
        for path in expandedPaths {
            loadDirectory(path: path)
        }

        if let session {
            Task { await restoreSession(session) }
        } else {
            persistSession()
        }
    }

    func items(for path: String) -> [FileItem] {
        touchDirectoryCache(path)
        return directoryItems[path] ?? []
    }

    // MARK: - LRU Cache Management

    private func touchDirectoryCache(_ path: String) {
        directoryAccessOrder.removeAll { $0 == path }
        directoryAccessOrder.append(path)
    }

    private func evictDirectoryCacheIfNeeded() {
        guard directoryItems.count > maxCachedDirectories else { return }

        // Find evictable paths (not expanded, not root, not current)
        let evictable = directoryAccessOrder.filter { path in
            !expandedPaths.contains(path) && path != rootPath && path != currentPath
        }

        // Evict oldest evictable entries
        for path in evictable.prefix(directoryItems.count - maxCachedDirectories) {
            directoryItems.removeValue(forKey: path)
            directoryAccessOrder.removeAll { $0 == path }
        }
    }

    func isExpanded(path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func toggleExpanded(path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            loadDirectory(path: path)
        }
        persistSession()
    }

    func loadDirectory(path: String) {
        guard !path.isEmpty else { return }
        guard !loadingPaths.contains(path) else { return }

        loadingPaths.insert(path)
        Task.detached(priority: .utility) {
            do {
                let url = URL(fileURLWithPath: path)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: []
                )

                let items: [FileItem] = contents.compactMap { fileURL in
                    let name = fileURL.lastPathComponent
                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                    let isHidden = resourceValues?.isHidden ?? name.hasPrefix(".")
                    let isDirectory = resourceValues?.isDirectory ?? false

                    return FileItem(
                        name: name,
                        path: fileURL.path,
                        isDirectory: isDirectory,
                        isHidden: isHidden
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

                await MainActor.run {
                    self.directoryItems[path] = items
                    self.touchDirectoryCache(path)
                    self.evictDirectoryCacheIfNeeded()
                    self.loadingPaths.remove(path)
                }
            } catch {
                await MainActor.run {
                    self.directoryItems[path] = []
                    self.touchDirectoryCache(path)
                    self.loadingPaths.remove(path)
                    self.present(error)
                }
            }
        }
    }

    func openFile(path: String, updateSession: Bool = true) async {
        if let existing = openFiles.first(where: { $0.path == path }) {
            selectedFileId = existing.id
            return
        }

        do {
            let size = try await fileService.fileSize(path: path)
            if size > maxOpenFileBytes {
                showAlert(FileServiceError.fileTooLarge(size).localizedDescription)
                return
            }

            let content = try await fileService.readFile(path: path)
            let fileURL = URL(fileURLWithPath: path)
            let fileInfo = OpenFileInfo(
                name: fileURL.lastPathComponent,
                path: path,
                content: content
            )

            openFiles.append(fileInfo)
            selectedFileId = fileInfo.id

            if updateSession {
                persistSession()
            }
        } catch {
            present(error)
        }
    }

    func closeFile(id: UUID) {
        let closingIndex = openFiles.firstIndex(where: { $0.id == id })
        let wasSelected = selectedFileId == id
        openFiles.removeAll { $0.id == id }

        if wasSelected {
            if let closingIndex, !openFiles.isEmpty {
                let nextIndex = min(closingIndex, openFiles.count - 1)
                selectedFileId = openFiles[nextIndex].id
            } else {
                selectedFileId = openFiles.last?.id
            }
        }
        persistSession()
    }

    func updateFileContent(id: UUID, content: String) {
        guard let index = openFiles.firstIndex(where: { $0.id == id }) else { return }
        openFiles[index].content = content
        openFiles[index].hasUnsavedChanges = true
    }

    func saveFile(id: UUID) async {
        guard let index = openFiles.firstIndex(where: { $0.id == id }) else { return }
        let file = openFiles[index]

        do {
            try await fileService.saveFile(path: file.path, content: file.content)
            openFiles[index].hasUnsavedChanges = false
        } catch {
            present(error)
        }
    }

    func revertFile(id: UUID) async {
        guard let index = openFiles.firstIndex(where: { $0.id == id }) else { return }
        let file = openFiles[index]

        do {
            let content = try await fileService.readFile(path: file.path)
            openFiles[index].content = content
            openFiles[index].hasUnsavedChanges = false
        } catch {
            present(error)
        }
    }

    func createNewFile(parentPath: String, name: String) async {
        let filePath = (parentPath as NSString).appendingPathComponent(name)

        do {
            try await fileService.createFile(at: filePath)
            refreshDirectory(path: parentPath)
            await openFile(path: filePath)
        } catch {
            present(error)
        }
    }

    func createNewFolder(parentPath: String, name: String) async {
        let folderPath = (parentPath as NSString).appendingPathComponent(name)

        do {
            try await fileService.createDirectory(at: folderPath)
            expandedPaths.insert(folderPath)
            refreshDirectoryTree(parentPath: parentPath, expandedPath: folderPath)
        } catch {
            present(error)
        }
    }

    func renameItem(oldPath: String, newName: String) async {
        let parentPath = (oldPath as NSString).deletingLastPathComponent
        let newPath = (parentPath as NSString).appendingPathComponent(newName)

        do {
            try await fileService.renameItem(from: oldPath, to: newPath)

            if let index = openFiles.firstIndex(where: { $0.path == oldPath }) {
                let fileInfo = openFiles[index]
                openFiles[index] = OpenFileInfo(
                    id: fileInfo.id,
                    name: newName,
                    path: newPath,
                    content: fileInfo.content,
                    hasUnsavedChanges: fileInfo.hasUnsavedChanges
                )
            }

            if expandedPaths.contains(oldPath) {
                expandedPaths.remove(oldPath)
                expandedPaths.insert(newPath)
            }

            refreshDirectoryTree(parentPath: parentPath)
        } catch {
            present(error)
        }
    }

    func deleteItem(path: String) async {
        do {
            try await fileService.deleteItem(at: path)

            let removedFiles = openFiles.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
            for file in removedFiles {
                closeFile(id: file.id)
            }

            expandedPaths.remove(path)
            let parentPath = (path as NSString).deletingLastPathComponent
            refreshDirectoryTree(parentPath: parentPath)
        } catch {
            present(error)
        }
    }

    func copyPath(_ path: String) {
        Clipboard.copy(path)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func refreshDirectory(path: String) {
        directoryItems[path] = nil
        loadDirectory(path: path)
    }

    private func refreshDirectoryTree(parentPath: String, expandedPath: String? = nil) {
        refreshDirectory(path: parentPath)
        if let expandedPath {
            loadDirectory(path: expandedPath)
        }
        persistSession()
    }

    private func restoreSession(_ session: FileBrowserSessionState) async {
        for path in session.openFilePaths {
            await openFile(path: path, updateSession: false)
        }

        if let selectedPath = session.selectedFilePath,
           let selectedFile = openFiles.first(where: { $0.path == selectedPath }) {
            selectedFileId = selectedFile.id
        }

        persistSession()
    }

    private func persistSession() {
        onSessionUpdate(
            FileBrowserSessionState(
                currentPath: currentPath,
                expandedPaths: Array(expandedPaths).sorted(),
                openFilePaths: openFiles.map(\.path),
                selectedFilePath: openFiles.first(where: { $0.id == selectedFileId })?.path
            )
        )
    }

    private func showAlert(_ message: String?) {
        guard let message else { return }
        alert = FileBrowserAlert(message: message)
    }

    private func present(_ error: Error) {
        showAlert((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}
