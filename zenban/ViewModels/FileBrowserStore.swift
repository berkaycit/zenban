import Foundation
import SwiftUI
import AppKit
import Observation

struct FileItem: Identifiable, Hashable {
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

struct OpenFileInfo: Identifiable, Equatable {
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

struct FileBrowserAlert: Identifiable {
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
        directoryItems[path] ?? []
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
        Task.detached {
            do {
                let url = URL(fileURLWithPath: path)
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                    options: []
                )

                let items: [FileItem] = contents.compactMap { fileURL in
                    let name = fileURL.lastPathComponent
                    let isHidden = name.hasPrefix(".")
                    let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

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
                    self.loadingPaths.remove(path)
                }
            } catch {
                await MainActor.run {
                    self.directoryItems[path] = []
                    self.loadingPaths.remove(path)
                    self.alert = FileBrowserAlert(message: error.localizedDescription)
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
                alert = FileBrowserAlert(message: FileServiceError.fileTooLarge(size).localizedDescription)
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
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func closeFile(id: UUID) {
        openFiles.removeAll { $0.id == id }
        if selectedFileId == id {
            selectedFileId = openFiles.last?.id
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
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func createNewFile(parentPath: String, name: String) async {
        let filePath = (parentPath as NSString).appendingPathComponent(name)

        do {
            try await fileService.createFile(at: filePath)
            refreshDirectory(path: parentPath)
            await openFile(path: filePath)
        } catch {
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func createNewFolder(parentPath: String, name: String) async {
        let folderPath = (parentPath as NSString).appendingPathComponent(name)

        do {
            try await fileService.createDirectory(at: folderPath)
            expandedPaths.insert(folderPath)
            refreshDirectory(path: parentPath)
            loadDirectory(path: folderPath)
            persistSession()
        } catch {
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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

            refreshDirectory(path: parentPath)
            persistSession()
        } catch {
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
            refreshDirectory(path: parentPath)
            persistSession()
        } catch {
            alert = FileBrowserAlert(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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
}
