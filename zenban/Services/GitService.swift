import Foundation

enum GitError: Error, LocalizedError {
    case initFailed
    case directoryCreationFailed
    case directoryAlreadyExists

    var errorDescription: String? {
        switch self {
        case .initFailed:
            return "Failed to initialize git repository"
        case .directoryCreationFailed:
            return "Failed to create directory"
        case .directoryAlreadyExists:
            return "Directory already exists"
        }
    }
}

struct GitService {
    static func createRepository(name: String, parentPath: String) async throws -> String {
        let repoPath = (parentPath as NSString).appendingPathComponent(name)
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: repoPath) else {
            throw GitError.directoryAlreadyExists
        }

        do {
            try fileManager.createDirectory(atPath: repoPath, withIntermediateDirectories: false)
        } catch {
            throw GitError.directoryCreationFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["init"]
                process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: repoPath)
                    } else {
                        continuation.resume(throwing: GitError.initFailed)
                    }
                } catch {
                    continuation.resume(throwing: GitError.initFailed)
                }
            }
        }
    }
}
