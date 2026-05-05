import AppKit
import Combine
import Foundation
import UserNotifications
import Bonsplit

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.cmuxterm.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}

enum NotificationSoundSettings {
    static let key = "notificationSound"
    static let defaultValue = "default"
    static let customFileValue = "custom_file"
    static let customFilePathKey = "notificationSoundCustomFilePath"
    static let defaultCustomFilePath = ""
    private static let stagedCustomSoundBaseName = "cmux-custom-notification-sound"
    private static let customSoundPreparationQueue = DispatchQueue(
        label: "com.cmuxterm.notification-sound-preparation",
        qos: .utility
    )
    private static let pendingCustomSoundPreparationLock = NSLock()
    private static var pendingCustomSoundPreparationPaths: Set<String> = []
    private static let activePlaybackSoundsLock = NSLock()
    private static var activePlaybackSounds: [ObjectIdentifier: NSSound] = [:]
    private static let activePlaybackSoundDelegate = ActivePlaybackSoundDelegate()
    private static let notificationSoundSupportedExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    private final class ActivePlaybackSoundDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
            NotificationSoundSettings.releaseActivePlaybackSound(sound)
        }
    }

    private struct CustomSoundSourceMetadata: Codable, Equatable {
        let sourcePath: String
        let sourceSize: UInt64
        let sourceModificationTime: Double
        let sourceFileIdentifier: UInt64?
    }

    enum CustomSoundPreparationIssue: Error {
        case emptyPath
        case missingFile(path: String)
        case missingFileExtension(path: String)
        case stagingFailed(path: String, details: String)

        var logMessage: String {
            switch self {
            case .emptyPath:
                return "Notification custom sound path is empty"
            case .missingFile(let path):
                return "Notification custom sound file does not exist: \(path)"
            case .missingFileExtension(let path):
                return "Notification custom sound requires a file extension: \(path)"
            case .stagingFailed(let path, let details):
                return "Failed to stage custom notification sound from \(path): \(details)"
            }
        }
    }
    static let customCommandKey = "notificationCustomCommand"
    static let defaultCustomCommand = ""

    static let systemSounds: [(label: String, value: String)] = [
        ("Default", "default"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        ("Custom File...", customFileValue),
        ("None", "none"),
    ]

    static func sound(defaults: UserDefaults = .standard) -> UNNotificationSound? {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "default":
            return .default
        case "none":
            return nil
        case customFileValue:
            guard let customSoundName = stagedCustomSoundName(defaults: defaults) else {
                return nil
            }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: customSoundName))
        default:
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: value))
        }
    }

    static func usesSystemSound(defaults: UserDefaults = .standard) -> Bool {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "none":
            return false
        case customFileValue:
            return customFileURL(defaults: defaults) != nil
        default:
            return true
        }
    }

    static func isSilent(defaults: UserDefaults = .standard) -> Bool {
        return (defaults.string(forKey: key) ?? defaultValue) == "none"
    }

    static func isCustomFileSelected(defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: key) ?? defaultValue) == customFileValue
    }

    static func stagedCustomSoundName(defaults: UserDefaults = .standard) -> String? {
        let rawPath = defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath
        guard let normalizedPath = normalizedCustomFilePath(rawPath) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.emptyPath.logMessage)")
            return nil
        }

        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.missingFileExtension(path: sourceURL.path).logMessage)")
            return nil
        }

        let destinationExtension = stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)
        let stagedFileName = stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = stagedSoundDirectoryURL().appendingPathComponent(stagedFileName, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.missingFile(path: sourceURL.path).logMessage)")
            return nil
        }

        if fileManager.fileExists(atPath: stagedURL.path) {
            if let sourceMetadata = currentSourceMetadata(for: sourceURL, fileManager: fileManager),
               let stagedMetadata = loadStagedSourceMetadata(for: stagedURL),
               stagedMetadata == sourceMetadata {
                return stagedFileName
            }
        }

        if destinationExtension == sourceExtension {
            switch prepareCustomFileForNotifications(path: normalizedPath) {
            case .success(let preparedName):
                return preparedName
            case .failure(let issue):
                NSLog("Notification custom sound unavailable: \(issue.logMessage)")
                return nil
            }
        }

        queueCustomSoundPreparation(path: normalizedPath)
        NSLog("Notification custom sound not ready yet, staging in background: \(sourceURL.path)")
        return nil
    }

    static func prepareCustomFileForNotifications(path: String) -> Result<String, CustomSoundPreparationIssue> {
        guard let normalizedPath = normalizedCustomFilePath(path) else {
            return .failure(.emptyPath)
        }
        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        return prepareCustomSound(from: sourceURL)
    }

    private static func prepareCustomSound(from sourceURL: URL) -> Result<String, CustomSoundPreparationIssue> {
        let sourcePath = sourceURL.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else {
            return .failure(.missingFile(path: sourcePath))
        }
        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceExtension.isEmpty else {
            return .failure(.missingFileExtension(path: sourcePath))
        }
        let destinationExtension = stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)

        let destinationDirectory = stagedSoundDirectoryURL()
        let destinationFileName = stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
        let sourceMetadata = currentSourceMetadata(for: sourceURL, fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                let stagedMetadata = loadStagedSourceMetadata(for: destinationURL)
                if stagedMetadata != sourceMetadata {
                    try? fileManager.removeItem(at: destinationURL)
                }
            }
            if destinationExtension == sourceExtension.lowercased() {
                try copyStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            } else {
                try transcodeStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            }
            if let sourceMetadata {
                try saveStagedSourceMetadata(sourceMetadata, for: destinationURL)
            }
            try cleanupStaleStagedSoundFiles(
                in: destinationDirectory,
                keeping: destinationFileName,
                preservingSourceURL: sourceURL,
                fileManager: fileManager
            )
            return .success(destinationFileName)
        } catch {
            return .failure(.stagingFailed(path: sourcePath, details: error.localizedDescription))
        }
    }

    static func customFileURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = normalizedCustomFilePath(defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func playCustomFileSound(defaults: UserDefaults = .standard) {
        guard let url = customFileURL(defaults: defaults) else { return }
        playSoundFile(at: url)
    }

    static func playCustomFileSound(path: String) {
        guard let normalizedPath = normalizedCustomFilePath(path) else { return }
        let url = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        playSoundFile(at: url)
    }

    static func playSelectedSound(defaults: UserDefaults = .standard) {
        let value = defaults.string(forKey: key) ?? defaultValue
        playSound(value: value, defaults: defaults)
    }

    static func previewSound(value: String, defaults: UserDefaults = .standard) {
        playSound(value: value, defaults: defaults)
    }

    private static func playSound(value: String, defaults: UserDefaults) {
        switch value {
        case "default":
            NSSound.beep()
        case "none":
            break
        case customFileValue:
            playCustomFileSound(defaults: defaults)
        default:
            NSSound(named: NSSound.Name(value))?.play()
        }
    }

    static func stagedCustomSoundFileExtension(forSourceExtension sourceExtension: String) -> String {
        let normalized = sourceExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "caf" }
        if notificationSoundSupportedExtensions.contains(normalized) {
            return normalized
        }
        return "caf"
    }

    static func stagedCustomSoundFileName(forSourceURL sourceURL: URL, destinationExtension: String) -> String {
        let normalizedExtension = destinationExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = normalizedExtension.isEmpty ? "caf" : normalizedExtension
        let signature = stagedCustomSoundSourceSignature(for: sourceURL)
        return "\(stagedCustomSoundBaseName)-\(signature).\(ext)"
    }

    private static func normalizedCustomFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func stagedSoundDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private static func queueCustomSoundPreparation(path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        pendingCustomSoundPreparationLock.lock()
        if pendingCustomSoundPreparationPaths.contains(expandedPath) {
            pendingCustomSoundPreparationLock.unlock()
            return
        }
        pendingCustomSoundPreparationPaths.insert(expandedPath)
        pendingCustomSoundPreparationLock.unlock()

        customSoundPreparationQueue.async {
            defer {
                pendingCustomSoundPreparationLock.lock()
                pendingCustomSoundPreparationPaths.remove(expandedPath)
                pendingCustomSoundPreparationLock.unlock()
            }
            _ = prepareCustomFileForNotifications(path: expandedPath)
        }
    }

    private static func playSoundFile(at url: URL) {
        DispatchQueue.main.async {
            guard let sound = NSSound(contentsOf: url, byReference: false) else {
                NSLog("Notification custom sound failed to load from path: \(url.path)")
                return
            }
            retainActivePlaybackSound(sound)
            sound.delegate = activePlaybackSoundDelegate
            if !sound.play() {
                releaseActivePlaybackSound(sound)
            }
        }
    }

    private static func retainActivePlaybackSound(_ sound: NSSound) {
        activePlaybackSoundsLock.lock()
        activePlaybackSounds[ObjectIdentifier(sound)] = sound
        activePlaybackSoundsLock.unlock()
    }

    private static func releaseActivePlaybackSound(_ sound: NSSound) {
        activePlaybackSoundsLock.lock()
        activePlaybackSounds.removeValue(forKey: ObjectIdentifier(sound))
        activePlaybackSoundsLock.unlock()
    }

    private static func cleanupStaleStagedSoundFiles(
        in directoryURL: URL,
        keeping fileName: String,
        preservingSourceURL: URL,
        fileManager: FileManager
    ) throws {
        let legacyPrefix = "\(stagedCustomSoundBaseName)."
        let hashedPrefix = "\(stagedCustomSoundBaseName)-"
        let normalizedSource = preservingSourceURL.standardizedFileURL
        let keptStagedURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let keptMetadataFileName = stagedSourceMetadataURL(for: keptStagedURL).lastPathComponent
        for fileNameCandidate in try fileManager.contentsOfDirectory(atPath: directoryURL.path) {
            let isManagedName = fileNameCandidate.hasPrefix(legacyPrefix) || fileNameCandidate.hasPrefix(hashedPrefix)
            let isKeptManagedFile = fileNameCandidate == fileName || fileNameCandidate == keptMetadataFileName
            guard isManagedName, !isKeptManagedFile else { continue }
            let staleURL = directoryURL.appendingPathComponent(fileNameCandidate, isDirectory: false)
            if staleURL.standardizedFileURL == normalizedSource {
                continue
            }
            try? fileManager.removeItem(at: staleURL)
            try? fileManager.removeItem(at: stagedSourceMetadataURL(for: staleURL))
        }
    }

    private static func copyStagedSoundIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceSize = sourceAttributes[.size] as? NSNumber
            let destinationSize = destinationAttributes[.size] as? NSNumber
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if sourceSize == destinationSize && sourceDate == destinationDate {
                return
            }
            try fileManager.removeItem(at: normalizedDestination)
        }

        try fileManager.copyItem(at: normalizedSource, to: normalizedDestination)
    }

    private static func transcodeStagedSoundIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if let sourceDate, let destinationDate, destinationDate >= sourceDate {
                return
            }
            try fileManager.removeItem(at: normalizedDestination)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "caff",
            "-d", "LEI16",
            normalizedSource.path,
            normalizedDestination.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fileManager.fileExists(atPath: normalizedDestination.path) {
                try? fileManager.removeItem(at: normalizedDestination)
            }
            let description: String
            if let errorOutput, !errorOutput.isEmpty {
                description = errorOutput
            } else {
                description = "afconvert failed with exit code \(process.terminationStatus)"
            }
            throw NSError(
                domain: "NotificationSoundSettings",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: description,
                ]
            )
        }
    }

    private static func stagedCustomSoundSourceSignature(for sourceURL: URL) -> String {
        let normalizedPath = sourceURL.standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalizedPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func stagedSourceMetadataURL(for stagedURL: URL) -> URL {
        stagedURL.appendingPathExtension("source-metadata")
    }

    private static func currentSourceMetadata(for sourceURL: URL, fileManager: FileManager) -> CustomSoundSourceMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path) else {
            return nil
        }
        guard let sourceSizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }
        let sourceDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return CustomSoundSourceMetadata(
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceSize: sourceSizeNumber.uint64Value,
            sourceModificationTime: sourceDate.timeIntervalSinceReferenceDate,
            sourceFileIdentifier: fileIdentifier
        )
    }

    private static func loadStagedSourceMetadata(for stagedURL: URL) -> CustomSoundSourceMetadata? {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CustomSoundSourceMetadata.self, from: data)
    }

    private static func saveStagedSourceMetadata(_ metadata: CustomSoundSourceMetadata, for stagedURL: URL) throws {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private static let customCommandQueue = DispatchQueue(
        label: "com.cmuxterm.notification-custom-command",
        qos: .utility
    )

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        customCommandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["CMUX_NOTIFICATION_TITLE"] = title
            env["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            env["CMUX_NOTIFICATION_BODY"] = body
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}

enum NotificationBadgeSettings {
    static let dockBadgeEnabledKey = "notificationDockBadgeEnabled"
    static let defaultDockBadgeEnabled = true

    static func isDockBadgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dockBadgeEnabledKey) == nil {
            return defaultDockBadgeEnabled
        }
        return defaults.bool(forKey: dockBadgeEnabledKey)
    }
}

enum NotificationPaneRingSettings {
    static let enabledKey = "notificationPaneRingEnabled"
    static let defaultEnabled = true
}

enum NotificationPaneFlashSettings {
    static let enabledKey = "notificationPaneFlashEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func showsNotificationFlash(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        userPreferenceEnabled: Bool
    ) -> Bool {
        guard userPreferenceEnabled else { return false }
        return !SocketControlSettings.isZenbanBundleIdentifier(bundleIdentifier)
    }
}

enum TaggedRunBadgeSettings {
    static let environmentKey = "CMUX_TAG"
    private static let maxTagLength = 10

    static func normalizedTag(from env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        normalizedTag(env[environmentKey])
    }

    static func normalizedTag(_ rawTag: String?) -> String? {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > maxTagLength {
            tag = String(tag.prefix(maxTagLength))
        }
        return tag
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}

@MainActor
protocol TerminalNotificationStoreObserver: AnyObject {
    func terminalNotificationStore(
        _ store: TerminalNotificationStore,
        didAdd notification: TerminalNotification
    )
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    private struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    private struct NotificationContentSignature: Hashable {
        let title: String
        let subtitle: String
        let body: String
    }

    private static let maxReadContentSignaturesPerTab = 64

    private struct NotificationIndexes {
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore()

    static let categoryIdentifier = "com.cmuxterm.app.userNotification"
    static let actionShowIdentifier = "com.cmuxterm.app.userNotification.show"
    private enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            indexes = Self.buildIndexes(for: notifications)
            refreshDockBadge()
        }
    }
    @Published private(set) var focusedReadIndicatorByTabId: [UUID: UUID] = [:]
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private var userDefaultsObserver: NSObjectProtocol?
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    weak var observer: (any TerminalNotificationStoreObserver)?
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.scheduleUserNotification(notification)
    }
    private var suppressedNotificationFeedbackHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.playSuppressedNotificationFeedback(for: notification)
    }
    private var lastNotificationDateByCooldownKey: [String: Date] = [:]
    private var readContentSignaturesByTabId: [UUID: [NotificationContentSignature]] = [:]
    private var indexes = NotificationIndexes()

    private init() {
        indexes = Self.buildIndexes(for: notifications)
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDockBadge()
        }
        refreshDockBadge()
        refreshAuthorizationStatus()
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    static func dockBadgeLabel(unreadCount: Int, isEnabled: Bool, runTag: String? = nil) -> String? {
        let unreadLabel: String? = {
            guard isEnabled, unreadCount > 0 else { return nil }
            if unreadCount > 99 {
                return "99+"
            }
            return String(unreadCount)
        }()

        if let tag = TaggedRunBadgeSettings.normalizedTag(runTag) {
            if let unreadLabel {
                return "\(tag):\(unreadLabel)"
            }
            return tag
        }

        return unreadLabel
    }

    var unreadCount: Int {
        indexes.unreadCount
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        dlog("notification.auth \(message)")
#endif
        NSLog("notification.auth %@", message)
    }

    private static func authorizationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel)"
                )
            }
        }
    }

    func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _ in }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
    }

    func sendSettingsTestNotification() {
        logAuthorization("settings test tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsTest) { [weak self] authorized in
            guard let self, authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Zenban test notification"
            content.body = "Desktop notifications are enabled."
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "cmux.settings.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule test notification: \(error)")
                    self.logAuthorization("settings test schedule failed error=\(error.localizedDescription)")
                } else {
                    self.logAuthorization("settings test schedule succeeded")
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    func unreadCount(forTabId tabId: UUID) -> Int {
        indexes.unreadCountByTabId[tabId] ?? 0
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        let hasUnread = indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
        if hasUnread {
            let latest = indexes.latestUnreadByTabId[tabId] ?? indexes.latestByTabId[tabId]
            NSLog(
                "agent.notification.trace event=store_has_unread_true workspace=%@ surface=%@ unreadCount=%d latestId=%@ latestRead=%d latestSurface=%@ latestBodyLength=%d",
                tabId.uuidString,
                surfaceId?.uuidString ?? "nil",
                indexes.unreadCountByTabId[tabId] ?? 0,
                latest?.id.uuidString ?? "nil",
                latest?.isRead == true ? 1 : 0,
                latest?.surfaceId?.uuidString ?? "nil",
                latest?.body.count ?? 0
            )
        }
        return hasUnread
    }

    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) ||
            focusedReadIndicatorByTabId[tabId] == surfaceId
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestUnreadByTabId[tabId] ?? indexes.latestByTabId[tabId]
    }

    func focusedReadIndicatorSurfaceId(forTabId tabId: UUID) -> UUID? {
        focusedReadIndicatorByTabId[tabId]
    }

    func addNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        cooldownKey: String? = nil,
        cooldownInterval: TimeInterval? = nil
    ) {
        let now = Date()
        let resolvedCooldownInterval: TimeInterval?
        if let cooldownInterval, cooldownInterval.isFinite, cooldownInterval > 0 {
            resolvedCooldownInterval = cooldownInterval
        } else {
            resolvedCooldownInterval = nil
        }
        if let cooldownKey,
           let resolvedCooldownInterval,
           let lastNotificationDate = lastNotificationDateByCooldownKey[cooldownKey],
           now.timeIntervalSince(lastNotificationDate) < resolvedCooldownInterval {
            return
        }

        let resolvedTitle = AppDelegate.shared?.tabTitle(for: tabId) ?? title
        let nextSignature = NotificationContentSignature(
            title: resolvedTitle,
            subtitle: subtitle,
            body: body
        )
        if let existing = notifications.first(where: {
            $0.tabId == tabId &&
                Self.contentSignature(for: $0) == nextSignature
        }) {
            NSLog(
                "agent.notification.trace event=add_duplicate_same_content_suppressed workspace=%@ surface=%@ existingId=%@ existingRead=%d existingSurface=%@ bodyLength=%d",
                tabId.uuidString,
                surfaceId?.uuidString ?? "nil",
                existing.id.uuidString,
                existing.isRead ? 1 : 0,
                existing.surfaceId?.uuidString ?? "nil",
                body.count
            )
            return
        }
        if hasReadContentSignature(forTabId: tabId, signature: nextSignature) {
            NSLog(
                "agent.notification.trace event=add_read_content_suppressed workspace=%@ surface=%@ bodyLength=%d",
                tabId.uuidString,
                surfaceId?.uuidString ?? "nil",
                body.count
            )
            return
        }
        if let existing = notifications.first(where: {
            $0.tabId == tabId &&
                $0.surfaceId == surfaceId &&
                Self.shouldSuppressGenericWaitingReplacement(
                    existing: $0,
                    incomingSubtitle: subtitle,
                    incomingBody: body
                )
        }) {
            NSLog(
                "agent.notification.trace event=add_generic_waiting_replacement_suppressed workspace=%@ surface=%@ existingId=%@ existingRead=%d existingSubtitle=%@ bodyLength=%d",
                tabId.uuidString,
                surfaceId?.uuidString ?? "nil",
                existing.id.uuidString,
                existing.isRead ? 1 : 0,
                existing.subtitle,
                body.count
            )
            return
        }

        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }
        if !idsToClear.isEmpty {
            NSLog(
                "agent.notification.trace event=add_replacing_existing workspace=%@ surface=%@ removedCount=%d removedIds=%@",
                tabId.uuidString,
                surfaceId?.uuidString ?? "nil",
                idsToClear.count,
                idsToClear.joined(separator: ",")
            )
        }

        if let existingIndicatorSurfaceId = focusedReadIndicatorByTabId[tabId],
           existingIndicatorSurfaceId != surfaceId {
            focusedReadIndicatorByTabId.removeValue(forKey: tabId)
            NSLog(
                "agent.notification.trace event=focused_indicator_clear reason=surface_changed workspace=%@ oldSurface=%@ newSurface=%@",
                tabId.uuidString,
                existingIndicatorSurfaceId.uuidString,
                surfaceId?.uuidString ?? "nil"
            )
        }

        let shouldSuppressExternalDelivery =
            AppDelegate.shared?.shouldSuppressExternalNotification(tabId: tabId, surfaceId: surfaceId) ?? false
        if shouldSuppressExternalDelivery {
            setFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManager?.moveTabToTopForNotification(tabId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: resolvedTitle,
            subtitle: subtitle,
            body: body,
            createdAt: now,
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated
        if let cooldownKey, resolvedCooldownInterval != nil {
            lastNotificationDateByCooldownKey[cooldownKey] = now
        }
        NSLog(
            "agent.notification.store added id=%@ workspace=%@ surface=%@ delivery=%@ title=%@ subtitle=%@ bodyLength=%d",
            notification.id.uuidString,
            tabId.uuidString,
            surfaceId?.uuidString ?? "nil",
            shouldSuppressExternalDelivery ? "suppressed" : "scheduled",
            resolvedTitle,
            subtitle,
            body.count
        )
        observer?.terminalNotificationStore(self, didAdd: notification)
        if !idsToClear.isEmpty {
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        if shouldSuppressExternalDelivery {
            suppressedNotificationFeedbackHandler(self, notification)
        } else {
            notificationDeliveryHandler(self, notification)
        }
    }

    func markRead(id: UUID, source: String = "unknown") {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            NSLog(
                "agent.notification.trace event=mark_read_missing_id source=%@ id=%@ activeCount=%d",
                source,
                id.uuidString,
                notifications.count
            )
            return
        }
        guard !updated[index].isRead else {
            rememberReadContentSignature(for: updated[index])
            clearFocusedReadIndicator(forTabId: updated[index].tabId, surfaceId: updated[index].surfaceId)
            NSLog(
                "agent.notification.trace event=mark_read_noop_already_read source=%@ id=%@ workspace=%@ surface=%@ bodyLength=%d",
                source,
                id.uuidString,
                updated[index].tabId.uuidString,
                updated[index].surfaceId?.uuidString ?? "nil",
                updated[index].body.count
            )
            return
        }
        NSLog(
            "agent.notification.trace event=mark_read_id source=%@ id=%@ workspace=%@ surface=%@ unreadBefore=%d bodyLength=%d",
            source,
            id.uuidString,
            updated[index].tabId.uuidString,
            updated[index].surfaceId?.uuidString ?? "nil",
            indexes.unreadCountByTabId[updated[index].tabId] ?? 0,
            updated[index].body.count
        )
        clearFocusedReadIndicator(forTabId: updated[index].tabId, surfaceId: updated[index].surfaceId)
        rememberReadContentSignature(for: updated[index])
        updated[index].isRead = true
        notifications = updated
        TerminalMutationBus.shared.discardPendingNotifications(
            forTabId: updated[index].tabId,
            surfaceId: updated[index].surfaceId
        )
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
        center.removePendingNotificationRequestsOffMain(withIdentifiers: [id.uuidString])
    }

    func markRead(forTabId tabId: UUID, source: String = "unknown") {
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId)
        var updated = notifications
        var idsToClear: [String] = []
        let unreadBefore = indexes.unreadCountByTabId[tabId] ?? 0
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                rememberReadContentSignature(for: updated[index])
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        clearFocusedReadIndicator(forTabId: tabId)
        NSLog(
            "agent.notification.trace event=mark_read_tab source=%@ workspace=%@ unreadBefore=%d markedCount=%d markedIds=%@",
            source,
            tabId.uuidString,
            unreadBefore,
            idsToClear.count,
            idsToClear.joined(separator: ",")
        )
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?, source: String = "unknown") {
        TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId, surfaceId: surfaceId)
        var updated = notifications
        var idsToClear: [String] = []
        let unreadBefore = indexes.unreadCountByTabId[tabId] ?? 0
        for index in updated.indices {
            if updated[index].tabId == tabId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                rememberReadContentSignature(for: updated[index])
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        NSLog(
            "agent.notification.trace event=mark_read_surface source=%@ workspace=%@ surface=%@ unreadBefore=%d markedCount=%d markedIds=%@",
            source,
            tabId.uuidString,
            surfaceId?.uuidString ?? "nil",
            unreadBefore,
            idsToClear.count,
            idsToClear.joined(separator: ",")
        )
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        var updated = notifications
        var didChange = false
        var changedIds: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId, updated[index].isRead {
                updated[index].isRead = false
                forgetReadContentSignature(for: updated[index])
                changedIds.append(updated[index].id.uuidString)
                didChange = true
            }
        }
        NSLog(
            "agent.notification.trace event=mark_unread_tab workspace=%@ changedCount=%d changedIds=%@",
            tabId.uuidString,
            changedIds.count,
            changedIds.joined(separator: ",")
        )
        if didChange {
            notifications = updated
        }
    }

    func setFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let surfaceId else { return }
        guard focusedReadIndicatorByTabId[tabId] != surfaceId else { return }
        focusedReadIndicatorByTabId[tabId] = surfaceId
        NSLog(
            "agent.notification.trace event=focused_indicator_set workspace=%@ surface=%@",
            tabId.uuidString,
            surfaceId.uuidString
        )
    }

    func clearFocusedReadIndicator(forTabId tabId: UUID, surfaceId: UUID? = nil) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard surfaceId == nil || existingSurfaceId == surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
        NSLog(
            "agent.notification.trace event=focused_indicator_clear reason=explicit workspace=%@ surface=%@",
            tabId.uuidString,
            existingSurfaceId.uuidString
        )
    }

    func clearFocusedReadIndicatorIfSurfaceChanged(forTabId tabId: UUID, surfaceId: UUID?) {
        guard let existingSurfaceId = focusedReadIndicatorByTabId[tabId] else { return }
        guard existingSurfaceId != surfaceId else { return }
        focusedReadIndicatorByTabId.removeValue(forKey: tabId)
        NSLog(
            "agent.notification.trace event=focused_indicator_clear reason=surface_changed workspace=%@ oldSurface=%@ newSurface=%@",
            tabId.uuidString,
            existingSurfaceId.uuidString,
            surfaceId?.uuidString ?? "nil"
        )
    }

    func markAllRead() {
        TerminalMutationBus.shared.discardPendingNotifications()
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if !updated[index].isRead {
                rememberReadContentSignature(for: updated[index])
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        focusedReadIndicatorByTabId.removeAll()
        if !idsToClear.isEmpty {
            notifications = updated
            center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let removedNotifications = updated.filter { $0.id == id }
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        NSLog(
            "agent.notification.trace event=remove_notification id=%@ removedCount=%d wasRead=%d workspace=%@ surface=%@ bodyLength=%d",
            id.uuidString,
            removedNotifications.count,
            removedNotifications.first?.isRead == true ? 1 : 0,
            removedNotifications.first?.tabId.uuidString ?? "nil",
            removedNotifications.first?.surfaceId?.uuidString ?? "nil",
            removedNotifications.first?.body.count ?? 0
        )
        if let removed = removedNotifications.first {
            rememberReadContentSignature(for: removed)
            clearFocusedReadIndicator(forTabId: removed.tabId, surfaceId: removed.surfaceId)
        }
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
        center.removePendingNotificationRequestsOffMain(withIdentifiers: [id.uuidString])
    }

    func clearAll(discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotifications()
        }
        guard !notifications.isEmpty || !focusedReadIndicatorByTabId.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        for notification in notifications {
            rememberReadContentSignature(for: notification)
        }
        NSLog(
            "agent.notification.trace event=clear_all_notifications discardQueued=%d clearedCount=%d clearedIds=%@",
            discardQueuedNotifications ? 1 : 0,
            ids.count,
            ids.joined(separator: ",")
        )
        notifications.removeAll()
        focusedReadIndicatorByTabId.removeAll()
        center.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID?,
        discardQueuedNotifications: Bool = true
    ) {
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId, surfaceId: surfaceId)
        }
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId, notification.surfaceId == surfaceId {
                rememberReadContentSignature(for: notification)
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        clearFocusedReadIndicator(forTabId: tabId, surfaceId: surfaceId)
        NSLog(
            "agent.notification.trace event=clear_notifications_surface workspace=%@ surface=%@ discardQueued=%d clearedCount=%d clearedIds=%@",
            tabId.uuidString,
            surfaceId?.uuidString ?? "nil",
            discardQueuedNotifications ? 1 : 0,
            idsToClear.count,
            idsToClear.joined(separator: ",")
        )
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    func clearNotifications(forTabId tabId: UUID, discardQueuedNotifications: Bool = true) {
        if discardQueuedNotifications {
            TerminalMutationBus.shared.discardPendingNotifications(forTabId: tabId)
        }
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                rememberReadContentSignature(for: notification)
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        clearFocusedReadIndicator(forTabId: tabId)
        NSLog(
            "agent.notification.trace event=clear_notifications_tab workspace=%@ discardQueued=%d clearedCount=%d clearedIds=%@",
            tabId.uuidString,
            discardQueuedNotifications ? 1 : 0,
            idsToClear.count,
            idsToClear.joined(separator: ",")
        )
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                NSLog(
                    "agent.notification.deliver blocked reason=authorization state=%@ id=%@ workspace=%@ surface=%@",
                    self.authorizationState.statusLabel,
                    notification.id.uuidString,
                    notification.tabId.uuidString,
                    notification.surfaceId?.uuidString ?? "nil"
                )
                return
            }

            let content = UNMutableNotificationContent()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "Zenban"
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }

            let request = UNNotificationRequest(
                identifier: notification.id.uuidString,
                content: content,
                trigger: nil
            )

            self.center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                } else {
                    NSLog(
                        "agent.notification.deliver scheduled id=%@ workspace=%@ surface=%@",
                        notification.id.uuidString,
                        notification.tabId.uuidString,
                        notification.surfaceId?.uuidString ?? "nil"
                    )
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    private func resolvedNotificationTitle(for notification: TerminalNotification) -> String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Zenban"
        return notification.title.isEmpty ? appName : notification.title
    }

    private func playSuppressedNotificationFeedback(for notification: TerminalNotification) {
        NotificationSoundSettings.playSelectedSound()
        NotificationSoundSettings.runCustomCommand(
            title: resolvedNotificationTitle(for: notification),
            subtitle: notification.subtitle,
            body: notification.body
        )
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        if origin == .notificationDelivery,
           let cachedDecision = Self.cachedDeliveryAuthorizationDecision(
               for: authorizationState,
               isAppActive: AppFocusState.isAppActive()
           ) {
            if !cachedDecision, authorizationState == .notDetermined {
                hasDeferredAuthorizationRequest = true
            }
            completion(cachedDecision)
            return
        }

        logAuthorization("ensure start origin=\(origin.rawValue)")
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
                )
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .denied:
                    if origin != .notificationDelivery {
                        self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                        self.promptToEnableNotifications()
                    }
                    completion(false)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ) else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                self.logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=\(error?.localizedDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                )
                completion(granted)
            }
        }
    }

    private func promptToEnableNotifications() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasPromptedForSettings else { return }
            self.logAuthorization("prompt settings shown")
            self.hasPromptedForSettings = true
            self.presentNotificationSettingsPrompt(attempt: 0)
        }
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for Zenban")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are disabled for Zenban. Enable them in System Settings to see alerts.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

    private static func buildIndexes(for notifications: [TerminalNotification]) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

    private static func contentSignature(for notification: TerminalNotification) -> NotificationContentSignature {
        NotificationContentSignature(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body
        )
    }

    private static func shouldSuppressGenericWaitingReplacement(
        existing: TerminalNotification,
        incomingSubtitle: String,
        incomingBody: String
    ) -> Bool {
        guard isGenericWaitingNotification(subtitle: incomingSubtitle, body: incomingBody) else {
            return false
        }
        return !isGenericWaitingNotification(subtitle: existing.subtitle, body: existing.body)
    }

    private static func isGenericWaitingNotification(subtitle: String, body: String) -> Bool {
        let normalizedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedSubtitle == "waiting" else { return false }
        let normalizedBody = body
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedBody == "claude is waiting for your input" ||
            normalizedBody == "waiting for input" ||
            normalizedBody == "claude needs your input"
    }

    private func hasReadContentSignature(
        forTabId tabId: UUID,
        signature: NotificationContentSignature
    ) -> Bool {
        readContentSignaturesByTabId[tabId]?.contains(signature) == true
    }

    private func rememberReadContentSignature(for notification: TerminalNotification) {
        let signature = Self.contentSignature(for: notification)
        var signatures = readContentSignaturesByTabId[notification.tabId] ?? []
        signatures.removeAll { $0 == signature }
        signatures.insert(signature, at: 0)
        if signatures.count > Self.maxReadContentSignaturesPerTab {
            signatures.removeLast(signatures.count - Self.maxReadContentSignaturesPerTab)
        }
        readContentSignaturesByTabId[notification.tabId] = signatures
    }

    private func forgetReadContentSignature(for notification: TerminalNotification) {
        let signature = Self.contentSignature(for: notification)
        guard var signatures = readContentSignaturesByTabId[notification.tabId] else { return }
        signatures.removeAll { $0 == signature }
        readContentSignaturesByTabId[notification.tabId] = signatures.isEmpty ? nil : signatures
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification in
            store.scheduleUserNotification(notification)
        }
    }

    func configureSuppressedNotificationFeedbackHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        suppressedNotificationFeedbackHandler = handler
    }

    func resetSuppressedNotificationFeedbackHandlerForTesting() {
        suppressedNotificationFeedbackHandler = { store, notification in
            store.playSuppressedNotificationFeedback(for: notification)
        }
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        TerminalMutationBus.shared.discardPendingNotifications()
        self.notifications = notifications
        focusedReadIndicatorByTabId.removeAll()
        readContentSignaturesByTabId.removeAll()
    }
#endif

    private func refreshDockBadge() {
        let label = Self.dockBadgeLabel(
            unreadCount: unreadCount,
            isEnabled: NotificationBadgeSettings.isDockBadgeEnabled(),
            runTag: TaggedRunBadgeSettings.normalizedTag()
        )
        NSApp?.dockTile.badgeLabel = label
    }
}
