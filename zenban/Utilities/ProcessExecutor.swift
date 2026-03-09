//
//  ProcessExecutor.swift
//  zenban
//
//  Non-blocking async process execution utility
//

import Foundation

/// Result of a process execution
nonisolated struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Error types for process execution
enum ProcessExecutorError: Error, LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "Process execution failed: \(message)"
        }
    }
}

/// Actor for non-blocking process execution
actor ProcessExecutor {
    static let shared = ProcessExecutor()

    /// Execute a process and capture output asynchronously (non-blocking)
    func executeWithOutput(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let env = environment {
            process.environment = env
        }

        if let workDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Use nonisolated data collection with locks
        let dataCollector = DataCollector()

        // Set up non-blocking output capture using readabilityHandler
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            dataCollector.appendStdout(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            dataCollector.appendStderr(data)
        }

        // Run process and wait asynchronously for termination
        return try await withCheckedThrowingContinuation { continuation in
            let resumeGuard = ResumeGuard()

            process.terminationHandler = { [dataCollector, resumeGuard] proc in
                resumeGuard.runOnce {
                    // Clean up handlers
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining data
                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    dataCollector.appendStdout(remainingStdout)
                    dataCollector.appendStderr(remainingStderr)

                    let result = ProcessResult(
                        exitCode: proc.terminationStatus,
                        stdout: dataCollector.stdoutString,
                        stderr: dataCollector.stderrString
                    )

                    // Close pipes to release file descriptors
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()

                    continuation.resume(returning: result)
                }
            }

            do {
                try process.run()
            } catch {
                resumeGuard.runOnce {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()

                    continuation.resume(throwing: ProcessExecutorError.executionFailed(error.localizedDescription))
                }
            }
        }
    }
}

nonisolated private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func runOnce(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        block()
    }
}

/// Thread-safe data collector for process output
nonisolated private final class DataCollector: @unchecked Sendable {
    private var stdoutData = Data()
    private var stderrData = Data()
    private let lock = NSLock()

    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdoutData.append(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrData.append(data)
    }

    var stdoutString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8) ?? ""
    }
}
