#if DEBUG
import Foundation
import os

/// Unified ring-buffer event log for key, mouse, focus, and split events.
/// Writes every entry to a debug log path so `tail -f` works in real time.
///
/// Uses `os_unfair_lock` instead of `DispatchQueue.async` to avoid deadlocking
/// with Xcode's `libBacktraceRecording` dispatch introspection hooks during
/// view hierarchy mutations (e.g. `addSubview` -> `becomeFirstResponder` -> `dlog`).
public final class DebugEventLog: @unchecked Sendable {
    public static let shared = DebugEventLog()

    private var entries: [String] = []
    private let capacity = 500
    private var lock = os_unfair_lock()
    private var fileHandle: FileHandle?
    private static let logPath = resolveLogPath()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        openLogFile()
    }

    deinit {
        fileHandle?.closeFile()
    }

    private func openLogFile() {
        if !FileManager.default.fileExists(atPath: Self.logPath) {
            FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: Self.logPath)
        fileHandle?.seekToEndOfFile()
    }

    private static func sanitizePathToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let unicode = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(unicode).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return sanitized.isEmpty ? "debug" : sanitized
    }

    private static func resolveLogPath() -> String {
        let env = ProcessInfo.processInfo.environment

        if let explicit = env["CMUX_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        if let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return "/tmp/cmux-debug-\(sanitizePathToken(tag)).log"
        }

        if let socketPath = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketBase = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
            if socketBase.hasPrefix("cmux-debug-") {
                return "/tmp/\(socketBase).log"
            }
        }

        if let bundleId = Bundle.main.bundleIdentifier,
           bundleId != "com.cmuxterm.app.debug" {
            return "/tmp/cmux-debug-\(sanitizePathToken(bundleId)).log"
        }

        return "/tmp/cmux-debug.log"
    }

    public func log(_ msg: String) {
        let ts = Self.formatter.string(from: Date())
        let entry = "\(ts) \(msg)"
        os_unfair_lock_lock(&lock)
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(entry)
        let line = entry + "\n"
        if let data = line.data(using: .utf8) {
            if fileHandle == nil { openLogFile() }
            fileHandle?.seekToEndOfFile()
            fileHandle?.write(data)
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Write all buffered entries to the log file (full dump, replacing contents).
    public func dump() {
        os_unfair_lock_lock(&lock)
        let content = entries.joined(separator: "\n") + "\n"
        os_unfair_lock_unlock(&lock)
        try? content.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
    }
}

/// Convenience free function. Logs the message and appends to the configured debug log path.
public func dlog(_ msg: String) {
    DebugEventLog.shared.log(msg)
}
#endif
