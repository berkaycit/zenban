import Foundation

enum FileServiceError: LocalizedError {
    case invalidPath
    case writePermissionDenied
    case writeFailed(String)
    case fileNotFound
    case fileAlreadyExists
    case createFailed(String)
    case deleteFailed(String)
    case renameFailed(String)
    case fileTooLarge(Int)
    case invalidTextEncoding

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Invalid file path"
        case .writePermissionDenied:
            return "Permission denied. Cannot write to this file"
        case .writeFailed(let details):
            return "Failed to save file: \(details)"
        case .fileNotFound:
            return "File not found"
        case .fileAlreadyExists:
            return "File or folder already exists"
        case .createFailed(let details):
            return "Failed to create: \(details)"
        case .deleteFailed(let details):
            return "Failed to delete: \(details)"
        case .renameFailed(let details):
            return "Failed to rename: \(details)"
        case .fileTooLarge(let bytes):
            let mb = Double(bytes) / 1024.0 / 1024.0
            return String(format: "File too large to open (%.1f MB).", mb)
        case .invalidTextEncoding:
            return "File is not a valid UTF-8 text file"
        }
    }
}

actor FileService {
    private let fileManager = FileManager.default

    func fileSize(path: String) throws -> Int {
        guard !path.isEmpty else { throw FileServiceError.invalidPath }
        guard fileManager.fileExists(atPath: path) else { throw FileServiceError.fileNotFound }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return attributes[.size] as? Int ?? 0
    }

    func readFile(path: String) throws -> String {
        guard !path.isEmpty else { throw FileServiceError.invalidPath }
        guard fileManager.fileExists(atPath: path) else { throw FileServiceError.fileNotFound }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let content = String(data: data, encoding: .utf8) else {
            throw FileServiceError.invalidTextEncoding
        }
        return content
    }

    func saveFile(path: String, content: String) throws {
        guard !path.isEmpty else { throw FileServiceError.invalidPath }
        guard fileManager.fileExists(atPath: path) else { throw FileServiceError.fileNotFound }
        guard fileManager.isWritableFile(atPath: path) else { throw FileServiceError.writePermissionDenied }

        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            try content.write(to: tempURL, atomically: false, encoding: .utf8)

            if let permissions = attributes[.posixPermissions] as? NSNumber {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
            }

            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            throw FileServiceError.writeFailed(error.localizedDescription)
        }
    }

    func createFile(at path: String, content: String = "") throws {
        guard !path.isEmpty else { throw FileServiceError.invalidPath }
        guard !fileManager.fileExists(atPath: path) else { throw FileServiceError.fileAlreadyExists }

        do {
            try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        } catch {
            throw FileServiceError.createFailed(error.localizedDescription)
        }
    }

    func createDirectory(at path: String) throws {
        guard !path.isEmpty else { throw FileServiceError.invalidPath }
        guard !fileManager.fileExists(atPath: path) else { throw FileServiceError.fileAlreadyExists }

        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: nil)
        } catch {
            throw FileServiceError.createFailed(error.localizedDescription)
        }
    }

    func renameItem(from fromPath: String, to toPath: String) throws {
        guard !fromPath.isEmpty, !toPath.isEmpty else { throw FileServiceError.invalidPath }
        guard fileManager.fileExists(atPath: fromPath) else { throw FileServiceError.fileNotFound }
        guard !fileManager.fileExists(atPath: toPath) else { throw FileServiceError.fileAlreadyExists }

        do {
            try fileManager.moveItem(atPath: fromPath, toPath: toPath)
        } catch {
            throw FileServiceError.renameFailed(error.localizedDescription)
        }
    }

    func deleteItem(at path: String) throws {
        guard !path.isEmpty else { throw FileServiceError.invalidPath }
        guard fileManager.fileExists(atPath: path) else { throw FileServiceError.fileNotFound }

        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw FileServiceError.deleteFailed(error.localizedDescription)
        }
    }
}
