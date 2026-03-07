import Darwin
import Foundation

@MainActor
final class TerminalController {
    private final class CommandResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "ERR\n"

        func store(_ value: String) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> String {
            lock.lock()
            let value = self.value
            lock.unlock()
            return value
        }
    }

    static let shared = TerminalController()

    private weak var activeTabManager: TabManager?
    private nonisolated(unsafe) let listenerQueue = DispatchQueue(label: "com.zenban.cmux.socket.listener", qos: .utility)
    private nonisolated(unsafe) let workerQueue = DispatchQueue(label: "com.zenban.cmux.socket.worker", qos: .utility, attributes: .concurrent)
    private var acceptSource: DispatchSourceRead?
    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var currentSocketPath = ""

    private init() {
        configurePortScanner()
    }

    deinit {}

    func startIfNeeded() {
        let storedMode = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            .map(SocketControlSettings.migrateMode)
            ?? SocketControlSettings.defaultMode
        let accessMode = SocketControlSettings.effectiveMode(userMode: storedMode)
        guard accessMode != .off else {
            stop()
            return
        }

        let socketPath = SocketControlSettings.socketPath()
        guard !socketPath.isEmpty else { return }
        if serverSocket >= 0, currentSocketPath == socketPath {
            return
        }

        stop()

        guard let listeningSocket = Self.makeListeningSocket(
            path: socketPath,
            permissions: accessMode.socketFilePermissions
        ) else {
            return
        }

        currentSocketPath = socketPath
        serverSocket = listeningSocket

        let source = DispatchSource.makeReadSource(fileDescriptor: listeningSocket, queue: listenerQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingClients()
        }
        source.setCancelHandler { [listeningSocket, socketPath] in
            close(listeningSocket)
            unlink(socketPath)
        }
        acceptSource = source
        source.resume()
    }

    func stop() {
        let source = acceptSource
        acceptSource = nil
        let socketToClose = serverSocket
        serverSocket = -1
        let socketPath = currentSocketPath
        currentSocketPath = ""

        source?.cancel()
        if source == nil, socketToClose >= 0 {
            close(socketToClose)
        }
        if !socketPath.isEmpty {
            unlink(socketPath)
        }
    }

    func setActiveTabManager(_ tabManager: TabManager?) {
        activeTabManager = tabManager
    }

    func readTerminalTextForSnapshot(
        terminalPanel: TerminalPanel,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        _ = terminalPanel
        _ = includeScrollback
        _ = lineLimit
        return nil
    }

    static func socketCommandAllowsInAppFocusMutations() -> Bool {
        true
    }

    static func shouldSuppressSocketCommandActivation() -> Bool {
        false
    }

    nonisolated static func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    nonisolated static func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    private func configurePortScanner() {
        PortScanner.shared.onPortsUpdated = { workspaceId, panelId, ports in
            Task { @MainActor in
                guard let app = AppDelegate.shared,
                      let tabManager = app.tabManagerFor(tabId: workspaceId),
                      let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                    return
                }
                workspace.surfaceListeningPorts[panelId] = ports
                workspace.recomputeListeningPorts()
            }
        }
    }

    private nonisolated func acceptPendingClients() {
        while true {
            let client = accept(serverSocket, nil, nil)
            if client == -1 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    return
                }
                return
            }
            workerQueue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private nonisolated func handleClient(_ client: Int32) {
        defer {
            shutdown(client, SHUT_RDWR)
            close(client)
        }

        guard let request = Self.readRequest(from: client), !request.isEmpty else {
            return
        }

        let response = dispatchCommandSynchronously(request)
        guard !response.isEmpty, let data = response.data(using: .utf8) else {
            return
        }

        _ = data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return write(client, base, buffer.count)
        }
    }

    private nonisolated func dispatchCommandSynchronously(_ request: String) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = CommandResponseBox()

        Task { @MainActor [weak self] in
            responseBox.store(self?.handleCommand(request) ?? "ERR\n")
            semaphore.signal()
        }

        semaphore.wait()
        return responseBox.load()
    }

    private func handleCommand(_ request: String) -> String {
        let parsed = parseCommand(request)
        switch parsed.command {
        case "ping", "system.ping":
            return "PONG\n"
        case "notify_target":
            return handleNotifyTarget(parsed)
        case "clear_notifications":
            return handleClearNotifications(parsed)
        case "set_status":
            return handleSetStatus(parsed)
        case "clear_status":
            return handleClearStatus(parsed)
        case "list_status":
            return handleListStatus(parsed)
        case "log":
            return handleLog(parsed)
        case "clear_log":
            return handleClearLog(parsed)
        case "list_log":
            return handleListLog(parsed)
        case "set_progress":
            return handleSetProgress(parsed)
        case "clear_progress":
            return handleClearProgress(parsed)
        case "report_pwd":
            return handleReportPWD(parsed)
        case "report_tty":
            return handleReportTTY(parsed)
        case "ports_kick":
            return handlePortsKick(parsed)
        case "report_git_branch":
            return handleReportGitBranch(parsed)
        case "clear_git_branch":
            return handleClearGitBranch(parsed)
        case "report_pr":
            return handleReportPR(parsed)
        case "clear_pr":
            return handleClearPR(parsed)
        case "open_url":
            return handleOpenURL(parsed)
        case "claude_hook":
            return handleClaudeHook(parsed)
        default:
            return "ERR unknown_command\n"
        }
    }

    private func handleReportPWD(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId,
              let directory = parsed.positional.first,
              let workspace = workspace(tabId: tabId) else {
            return "ERR invalid_args\n"
        }
        workspace.updatePanelDirectory(panelId: panelId, directory: directory)
        (workspace.panels[panelId] as? TerminalPanel)?.updateDirectory(directory)
        return "OK\n"
    }

    private func handleReportTTY(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId,
              let ttyName = parsed.positional.first,
              !ttyName.isEmpty else {
            return "ERR invalid_args\n"
        }
        if let workspace = workspace(tabId: tabId) {
            workspace.surfaceTTYNames[panelId] = ttyName
        }
        PortScanner.shared.registerTTY(workspaceId: tabId, panelId: panelId, ttyName: ttyName)
        return "OK\n"
    }

    private func handlePortsKick(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId else {
            return "ERR invalid_args\n"
        }
        PortScanner.shared.kick(workspaceId: tabId, panelId: panelId)
        return "OK\n"
    }

    private func handleReportGitBranch(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId,
              let branch = parsed.positional.first,
              let workspace = workspace(tabId: tabId) else {
            return "ERR invalid_args\n"
        }
        let isDirty = parsed.options["status"] == "dirty"
        workspace.updatePanelGitBranch(panelId: panelId, branch: branch, isDirty: isDirty)
        return "OK\n"
    }

    private func handleClearGitBranch(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId,
              let workspace = workspace(tabId: tabId) else {
            return "ERR invalid_args\n"
        }
        workspace.clearPanelGitBranch(panelId: panelId)
        return "OK\n"
    }

    private func handleReportPR(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId,
              let workspace = workspace(tabId: tabId),
              parsed.positional.count >= 2,
              let number = Int(parsed.positional[0]),
              let url = URL(string: parsed.positional[1]) else {
            return "ERR invalid_args\n"
        }

        let status = SidebarPullRequestStatus(rawValue: parsed.options["status"] ?? "open") ?? .open
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: number,
            label: "PR #\(number)",
            url: url,
            status: status
        )
        return "OK\n"
    }

    private func handleClearPR(_ parsed: ParsedCommand) -> String {
        guard let tabId = parsed.tabId,
              let panelId = parsed.panelId,
              let workspace = workspace(tabId: tabId) else {
            return "ERR invalid_args\n"
        }
        workspace.clearPanelPullRequest(panelId: panelId)
        TerminalNotificationStore.shared.clearNotifications(forTabId: tabId, surfaceId: panelId)
        return "OK\n"
    }

    private func handleNotifyTarget(_ parsed: ParsedCommand) -> String {
        guard parsed.positional.count >= 2,
              let workspaceId = UUID(uuidString: parsed.positional[0]),
              let panelId = UUID(uuidString: parsed.positional[1]),
              let workspace = workspace(tabId: workspaceId),
              workspace.panels[panelId] != nil else {
            return "ERR invalid_args\n"
        }

        let payload = parsed.positional.dropFirst(2).joined(separator: " ")
        let (title, subtitle, body) = Self.parseNotificationPayload(payload)
        TerminalNotificationStore.shared.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return "OK\n"
    }

    private func handleClearNotifications(_ parsed: ParsedCommand) -> String {
        if let tabId = parsed.tabId {
            if let panelId = parsed.panelId {
                TerminalNotificationStore.shared.clearNotifications(forTabId: tabId, surfaceId: panelId)
            } else {
                TerminalNotificationStore.shared.clearNotifications(forTabId: tabId)
            }
            return "OK\n"
        }

        TerminalNotificationStore.shared.clearAll()
        return "OK\n"
    }

    private func handleSetStatus(_ parsed: ParsedCommand) -> String {
        guard parsed.positional.count >= 2,
              let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        let key = parsed.positional[0]
        let value = parsed.positional.dropFirst().joined(separator: " ")
        let icon = Self.normalizedOptionValue(parsed.options["icon"])
        let color = Self.normalizedOptionValue(parsed.options["color"])

        let formatRaw = Self.normalizedOptionValue(parsed.options["format"]) ?? SidebarMetadataFormat.plain.rawValue
        guard let format = SidebarMetadataFormat(rawValue: formatRaw.lowercased()) else {
            return "ERR invalid_format\n"
        }

        let priority = Int(Self.normalizedOptionValue(parsed.options["priority"]) ?? "") ?? 0
        let url: URL?
        if let rawURL = Self.normalizedOptionValue(parsed.options["url"] ?? parsed.options["link"]) {
            guard let parsedURL = URL(string: rawURL) else {
                return "ERR invalid_url\n"
            }
            url = parsedURL
        } else {
            url = nil
        }

        guard Self.shouldReplaceStatusEntry(
            current: workspace.statusEntries[key],
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: url,
            priority: priority,
            format: format
        ) else {
            return "OK\n"
        }

        workspace.statusEntries[key] = SidebarStatusEntry(
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: url,
            priority: priority,
            format: format,
            timestamp: Date()
        )
        return "OK\n"
    }

    private func handleClearStatus(_ parsed: ParsedCommand) -> String {
        guard let key = parsed.positional.first,
              let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        _ = workspace.statusEntries.removeValue(forKey: key)
        return "OK\n"
    }

    private func handleListStatus(_ parsed: ParsedCommand) -> String {
        guard let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        let lines = workspace.sidebarStatusEntriesInDisplayOrder().map { entry in
            Self.sidebarMetadataLine(entry)
        }
        return lines.isEmpty ? "No status entries\n" : lines.joined(separator: "\n") + "\n"
    }

    private func handleLog(_ parsed: ParsedCommand) -> String {
        guard !parsed.positional.isEmpty,
              let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        let message = parsed.positional.joined(separator: " ")
        let levelRaw = Self.normalizedOptionValue(parsed.options["level"]) ?? SidebarLogLevel.info.rawValue
        guard let level = SidebarLogLevel(rawValue: levelRaw.lowercased()) else {
            return "ERR invalid_level\n"
        }

        workspace.logEntries.append(
            SidebarLogEntry(
                message: message,
                level: level,
                source: Self.normalizedOptionValue(parsed.options["source"]),
                timestamp: Date()
            )
        )
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if workspace.logEntries.count > limit {
            workspace.logEntries.removeFirst(workspace.logEntries.count - limit)
        }
        return "OK\n"
    }

    private func handleClearLog(_ parsed: ParsedCommand) -> String {
        guard let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        workspace.logEntries.removeAll()
        return "OK\n"
    }

    private func handleListLog(_ parsed: ParsedCommand) -> String {
        guard let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        let limit = Int(Self.normalizedOptionValue(parsed.options["limit"]) ?? "")
        let entries: [SidebarLogEntry]
        if let limit, limit >= 0 {
            entries = Array(workspace.logEntries.suffix(limit))
        } else {
            entries = workspace.logEntries
        }

        guard !entries.isEmpty else {
            return "No log entries\n"
        }

        let lines = entries.map { entry in
            if let source = entry.source, !source.isEmpty {
                return "[\(source)] [\(entry.level.rawValue)] \(entry.message)"
            }
            return "[\(entry.level.rawValue)] \(entry.message)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func handleSetProgress(_ parsed: ParsedCommand) -> String {
        guard let valueRaw = parsed.positional.first,
              let value = Double(valueRaw),
              let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        let clamped = min(1.0, max(0.0, value))
        let label = Self.normalizedOptionValue(parsed.options["label"])
        guard Self.shouldReplaceProgress(current: workspace.progress, value: clamped, label: label) else {
            return "OK\n"
        }

        workspace.progress = SidebarProgressState(value: clamped, label: label)
        return "OK\n"
    }

    private func handleClearProgress(_ parsed: ParsedCommand) -> String {
        guard let workspace = workspace(parsed: parsed) else {
            return "ERR invalid_args\n"
        }

        workspace.progress = nil
        return "OK\n"
    }

    private func handleOpenURL(_ parsed: ParsedCommand) -> String {
        guard let urlString = parsed.positional.first,
              let url = URL(string: urlString) else {
            return "ERR invalid_args\n"
        }

        if let tabId = parsed.tabId,
           let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) {
            _ = tabManager.openBrowser(
                inWorkspace: tabId,
                url: url,
                preferSplitRight: true,
                insertAtEnd: false
            )
            return "OK\n"
        }

        guard let tabManager = activeTabManager else {
            return "ERR no_active_workspace\n"
        }
        _ = tabManager.openBrowser(url: url)
        return "OK\n"
    }

    private func handleClaudeHook(_ parsed: ParsedCommand) -> String {
        guard let subcommand = parsed.positional.first?.lowercased(),
              let tabId = parsed.tabId else {
            return "ERR invalid_args\n"
        }

        let panelId = parsed.panelId
        switch subcommand {
        case "notification", "notify":
            let payload = parsed.positional.dropFirst().first.flatMap(Self.decodeBase64Payload)
            let summary = Self.claudeHookSummary(from: payload)
            TerminalNotificationStore.shared.addNotification(
                tabId: tabId,
                surfaceId: panelId,
                title: "Claude",
                subtitle: summary.subtitle,
                body: summary.body
            )
        case "stop", "idle":
            TerminalNotificationStore.shared.clearNotifications(forTabId: tabId, surfaceId: panelId)
        case "session-start", "active", "prompt-submit":
            break
        default:
            break
        }

        return "OK\n"
    }

    private func workspace(parsed: ParsedCommand) -> Workspace? {
        if let tabId = parsed.tabId {
            return workspace(tabId: tabId)
        }
        return activeWorkspace()
    }

    private func workspace(tabId: UUID) -> Workspace? {
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) else {
            return nil
        }
        return tabManager.tabs.first(where: { $0.id == tabId })
    }

    private func activeWorkspace() -> Workspace? {
        guard let tabManager = activeTabManager else { return nil }
        if let selectedTabId = tabManager.selectedTabId,
           let workspace = tabManager.tabs.first(where: { $0.id == selectedTabId }) {
            return workspace
        }
        return tabManager.tabs.first
    }

    private struct ParsedCommand {
        let command: String
        let rawArguments: String
        let positional: [String]
        let options: [String: String]

        var tabId: UUID? { options["tab"].flatMap(UUID.init(uuidString:)) }
        var panelId: UUID? {
            (options["panel"] ?? options["surface"]).flatMap(UUID.init(uuidString:))
        }
    }

    private func parseCommand(_ request: String) -> ParsedCommand {
        let split = Self.splitCommand(request)
        guard !split.command.isEmpty else {
            return ParsedCommand(command: "", rawArguments: "", positional: [], options: [:])
        }

        let tokens = Self.tokenizeArgs(split.rawArguments)

        var positional: [String] = []
        var options: [String: String] = [:]
        var index = 0
        var stopParsingOptions = false
        while index < tokens.count {
            let token = tokens[index]
            if stopParsingOptions {
                positional.append(token)
                index += 1
                continue
            }

            if token == "--" {
                stopParsingOptions = true
                index += 1
                continue
            }

            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                        options[key] = tokens[index + 1]
                        index += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            index += 1
        }

        return ParsedCommand(command: split.command, rawArguments: split.rawArguments, positional: positional, options: options)
    }

    private nonisolated static func splitCommand(_ request: String) -> (command: String, rawArguments: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmed.firstIndex(where: \.isWhitespace) else {
            return (trimmed, "")
        }

        let command = String(trimmed[..<spaceIndex])
        let rawArguments = String(trimmed[spaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, rawArguments)
    }

    private nonisolated static func tokenizeArgs(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private nonisolated static func readRequest(from socket: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let readCount = recv(socket, &buffer, buffer.count, 0)
            if readCount > 0 {
                data.append(buffer, count: readCount)
                continue
            }
            if readCount == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            return nil
        }

        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func makeListeningSocket(path: String, permissions: UInt16) -> Int32? {
        unlink(path)

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }

        var currentFlags = fcntl(socketFD, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var value: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout.size(ofValue: value)))

        guard var address = unixSocketAddress(path: path) else {
            close(socketFD)
            return nil
        }

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            unlink(path)
            return nil
        }

        _ = chmod(path, mode_t(permissions))

        guard listen(socketFD, SOMAXCONN) == 0 else {
            close(socketFD)
            unlink(path)
            return nil
        }

        currentFlags = fcntl(socketFD, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK)
        }

        return socketFD
    }

    private nonisolated static func unixSocketAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8CString)
        let maxCount = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= maxCount else { return nil }

        bytes.withUnsafeBytes { sourceBuffer in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                _ = memset(destination, 0, maxCount)
                if let sourceBase = sourceBuffer.baseAddress {
                    _ = memcpy(destination, sourceBase, bytes.count)
                }
            }
        }

        return address
    }

    private nonisolated static func decodeBase64Payload(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func normalizedOptionValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func parseNotificationPayload(_ payload: String) -> (String, String, String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "") }

        let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let title = parts.indices.contains(0) ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let subtitle = parts.indices.contains(1) && parts.count > 2
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.indices.contains(1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    private nonisolated static func sidebarMetadataLine(_ entry: SidebarStatusEntry) -> String {
        var line = "\(entry.key)=\(entry.value)"
        if let icon = entry.icon { line += " icon=\(icon)" }
        if let color = entry.color { line += " color=\(color)" }
        if let url = entry.url { line += " url=\(url.absoluteString)" }
        if entry.priority != 0 { line += " priority=\(entry.priority)" }
        if entry.format != .plain { line += " format=\(entry.format.rawValue)" }
        return line
    }

    private nonisolated static func claudeHookSummary(from payload: String?) -> (subtitle: String, body: String) {
        guard let payload, !payload.isEmpty else {
            return ("Notification", "Claude requires attention.")
        }

        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let subtitle = (object["event"] as? String)
                ?? (object["hook_event_name"] as? String)
                ?? "Notification"
            let body = (object["message"] as? String)
                ?? (object["content"] as? String)
                ?? (object["summary"] as? String)
                ?? payload
            return (subtitle, body)
        }

        return ("Notification", payload)
    }
}
