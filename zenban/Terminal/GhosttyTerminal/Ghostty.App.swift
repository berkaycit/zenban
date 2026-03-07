//
//  Ghostty.App.swift
//  zenban
//
//  Ghostty app wrapper - loads user's standard Ghostty config
//

import Foundation
import AppKit
import Combine
import OSLog
import SwiftUI

// MARK: - Pasteboard Helper

private enum GhosttyPasteboardHelper {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let value = pasteboard.string(forType: .string) {
            return value
        }

        return pasteboard.string(forType: utf8PlainTextType)
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func escapeForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private static let maxClipboardImageSize = 10 * 1024 * 1024

    static func clipboardHasImageOnly() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let hasText = types.contains(.string) || types.contains(.html)
            || types.contains(.rtf) || types.contains(.rtfd)
        if hasText { return false }
        return types.contains(.tiff) || types.contains(.png)
    }

    static func saveClipboardImageIfNeeded() -> String? {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        let hasText = types.contains(.string) || types.contains(.html)
            || types.contains(.rtf) || types.contains(.rtfd)
        if hasText { return nil }

        guard types.contains(.tiff) || types.contains(.png) else { return nil }
        guard let image = NSImage(pasteboard: pb),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        guard pngData.count <= maxClipboardImageSize else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "clipboard-\(timestamp)-\(UUID().uuidString.prefix(8)).png"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)

        do {
            try pngData.write(to: URL(fileURLWithPath: path))
        } catch {
            return nil
        }

        return escapeForShell(path)
    }
}

// MARK: - Ghostty Namespace

enum Ghostty {
    static let logger = Logger(subsystem: "com.berkaycit.zenban", category: "GhosttyApp")

    class SurfaceReference {
        let surface: ghostty_surface_t
        var isValid: Bool = true

        init(_ surface: ghostty_surface_t) {
            self.surface = surface
        }

        func invalidate() {
            isValid = false
        }
    }

    /// Configure environment variables for bundled Ghostty resources.
    static func configureEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path
            let terminfoDir = resourcesParent.appendingPathComponent("terminfo").path

            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing("MANPATH", path: manDir)
            if getenv("TERMINFO") == nil, fileManager.fileExists(atPath: terminfoDir) {
                setenv("TERMINFO", terminfoDir, 1)
            }
        }

    }

    private static func appendEnvPathIfMissing(
        _ key: String,
        path: String,
        defaultValue: String? = nil
    ) {
        if path.isEmpty { return }

        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }

        let updated = current.isEmpty ? path : "\(current):\(path)"
        setenv(key, updated, 1)
    }
}

// MARK: - Ghostty.App

extension Ghostty {
    @MainActor
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        private static var _shared: App?
        static var shared: App? {
            if _shared == nil {
                _shared = App()
            }
            return _shared?.readiness == .ready ? _shared : nil
        }

        @Published var app: ghostty_app_t? = nil
        @Published var readiness: Readiness = .loading

        private var activeSurfaces: [Ghostty.SurfaceReference] = []

        private nonisolated(unsafe) static var validTerminalViews: Set<UnsafeRawPointer> = []
        private static let validTerminalViewsLock = NSLock()

        private var lastKnownAppearance: NSAppearance.Name?
        private var appearanceCoalesceWork: DispatchWorkItem?

        init() {
            // Configure environment before init
            Ghostty.configureEnvironment()

            let initResult = ghostty_init(0, nil)
            if initResult != GHOSTTY_SUCCESS {
                Ghostty.logger.critical("ghostty_init failed with code: \(initResult)")
                readiness = .error
                return
            }

            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in
                    guard let app = app else { return false }
                    return App.action(app, target: target, action: action)
                },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in App.confirmReadClipboard(userdata, string: str, state: state, request: request) },
                write_clipboard_cb: { userdata, loc, content, count, confirm in
                    App.writeClipboard(userdata, location: loc, contents: content, count: count, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            guard let config = ghostty_config_new() else {
                Ghostty.logger.critical("ghostty_config_new failed")
                readiness = .error
                return
            }

            Self.loadDefaultConfigFilesWithLegacyFallback(into: config)

            guard let app = ghostty_app_new(&runtime_cfg, config) else {
                Ghostty.logger.critical("ghostty_app_new failed - trying fallback config")
                ghostty_config_free(config)

                // Fallback: try with empty config
                guard let fallbackConfig = ghostty_config_new() else {
                    readiness = .error
                    return
                }
                ghostty_config_finalize(fallbackConfig)

                guard let fallbackApp = ghostty_app_new(&runtime_cfg, fallbackConfig) else {
                    Ghostty.logger.critical("ghostty_app_new failed even with fallback config")
                    ghostty_config_free(fallbackConfig)
                    readiness = .error
                    return
                }

                ghostty_config_free(fallbackConfig)
                self.app = fallbackApp
                self.readiness = .ready
                lastKnownAppearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                applyAppColorScheme()
                Ghostty.logger.warning("Ghostty initialized with fallback config (user config had errors)")
                return
            }

            ghostty_config_free(config)
            self.app = app
            self.readiness = .ready

            lastKnownAppearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            applyAppColorScheme()

            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(systemAppearanceDidChange),
                name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil
            )

            Ghostty.logger.info("Ghostty app initialized with user config")
        }

        @objc private func systemAppearanceDidChange(_ notification: Notification) {
            let currentAppearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            guard currentAppearance != lastKnownAppearance else { return }
            lastKnownAppearance = currentAppearance

            appearanceCoalesceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.applyAppColorScheme()
            }
            appearanceCoalesceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
        }

        deinit {}

        // MARK: - App Operations

        func cleanup() {
            DistributedNotificationCenter.default().removeObserver(self)

            if let app = self.app {
                ghostty_app_free(app)
                self.app = nil
            }
        }

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        private func applyAppColorScheme() {
            guard let app = self.app else { return }

            let appearance = NSApplication.shared.effectiveAppearance
            let scheme: ghostty_color_scheme_e = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? GHOSTTY_COLOR_SCHEME_DARK
                : GHOSTTY_COLOR_SCHEME_LIGHT

            ghostty_app_set_color_scheme(app, scheme)
            GhosttyConfig.invalidateLoadCache()
        }

        @discardableResult
        func registerSurface(_ surface: ghostty_surface_t) -> Ghostty.SurfaceReference {
            let ref = Ghostty.SurfaceReference(surface)
            activeSurfaces.append(ref)
            activeSurfaces = activeSurfaces.filter { $0.isValid }
            return ref
        }

        func unregisterSurface(_ ref: Ghostty.SurfaceReference) {
            ref.invalidate()
            activeSurfaces = activeSurfaces.filter { $0.isValid }
        }

        nonisolated static func registerTerminalView(_ view: GhosttyTerminalView) {
            let ptr = Unmanaged.passUnretained(view).toOpaque()
            validTerminalViewsLock.lock()
            validTerminalViews.insert(UnsafeRawPointer(ptr))
            validTerminalViewsLock.unlock()
        }

        nonisolated static func unregisterTerminalView(_ view: GhosttyTerminalView) {
            let ptr = Unmanaged.passUnretained(view).toOpaque()
            validTerminalViewsLock.lock()
            validTerminalViews.remove(UnsafeRawPointer(ptr))
            validTerminalViewsLock.unlock()
        }

        nonisolated static func terminalView(from userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
            guard let userdata = userdata else { return nil }
            validTerminalViewsLock.lock()
            let isValid = validTerminalViews.contains(UnsafeRawPointer(userdata))
            validTerminalViewsLock.unlock()
            guard isValid else { return nil }
            return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        }

        func reloadConfig() {
            guard let app = self.app else { return }

            guard let config = ghostty_config_new() else {
                Ghostty.logger.error("ghostty_config_new failed during reload")
                return
            }

            Self.loadDefaultConfigFilesWithLegacyFallback(into: config)

            ghostty_app_update_config(app, config)

            for surfaceRef in activeSurfaces where surfaceRef.isValid {
                ghostty_surface_update_config(surfaceRef.surface, config)
            }

            activeSurfaces = activeSurfaces.filter { $0.isValid }
            GhosttyConfig.invalidateLoadCache()
            ghostty_config_free(config)

            Ghostty.logger.info("Configuration reloaded from user config files")
        }

        private static func loadDefaultConfigFilesWithLegacyFallback(into config: ghostty_config_t) {
            ghostty_config_load_default_files(config)
            loadLegacyGhosttyConfigIfNeeded(config)
            ghostty_config_load_recursive_files(config)
            ghostty_config_finalize(config)
        }

        private static func shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: Int?,
            legacyConfigFileSize: Int?
        ) -> Bool {
            guard let newConfigFileSize, newConfigFileSize == 0 else { return false }
            guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
            return true
        }

        private static func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
            let fileManager = FileManager.default
            guard let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                return
            }

            let ghosttyDir = appSupport.appendingPathComponent(
                "com.mitchellh.ghostty",
                isDirectory: true
            )
            let configNew = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
            let configLegacy = ghosttyDir.appendingPathComponent("config", isDirectory: false)

            func fileSize(_ url: URL) -> Int? {
                guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? NSNumber else {
                    return nil
                }
                return size.intValue
            }

            guard shouldLoadLegacyGhosttyConfig(
                newConfigFileSize: fileSize(configNew),
                legacyConfigFileSize: fileSize(configLegacy)
            ) else {
                return
            }

            configLegacy.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }

        private static func doubleConfigValue(_ config: ghostty_config_t, key: String) -> Double? {
            var value: Double = 0
            guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
                return nil
            }
            return value
        }

        private static func colorConfigValue(_ config: ghostty_config_t, key: String) -> NSColor? {
            var value = ghostty_config_color_s()
            guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
                return nil
            }
            return NSColor(
                red: CGFloat(value.r) / 255.0,
                green: CGFloat(value.g) / 255.0,
                blue: CGFloat(value.b) / 255.0,
                alpha: 1.0
            )
        }

        // MARK: - Callbacks

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata = userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                state.appTick()
            }
        }

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            let terminalView: GhosttyTerminalView? = {
                guard target.tag == GHOSTTY_TARGET_SURFACE,
                      let surface: ghostty_surface_t = target.target.surface else { return nil }
                return self.terminalView(from: ghostty_surface_userdata(surface))
            }()

            if let terminalView = terminalView {
                DispatchQueue.main.async {
                    terminalView.handleShellReady()
                }
            }

            switch action.tag {
            case GHOSTTY_ACTION_COMMAND_FINISHED:
                DispatchQueue.main.async {
                    terminalView?.handleCommandFinished()
                }
                return true

            case GHOSTTY_ACTION_SET_TITLE:
                return true

            case GHOSTTY_ACTION_PWD:
                if let pwdPtr = action.action.pwd.pwd {
                    let pwd = String(cString: pwdPtr)
                    Ghostty.logger.info("PWD changed: \(pwd)")
                }
                return true

            case GHOSTTY_ACTION_PROMPT_TITLE:
                return true

            case GHOSTTY_ACTION_PROGRESS_REPORT:
                let report = action.action.progress_report
                let state = GhosttyProgressState(cState: report.state)
                let value = report.progress >= 0 ? Int(report.progress) : nil
                DispatchQueue.main.async {
                    terminalView?.onProgressReport?(state, value)
                }
                return true

            case GHOSTTY_ACTION_CELL_SIZE:
                let cellSize = action.action.cell_size
                let backingSize = NSSize(width: Double(cellSize.width), height: Double(cellSize.height))
                DispatchQueue.main.async {
                    guard let terminalView = terminalView else { return }
                    terminalView.cellSize = terminalView.convertFromBacking(backingSize)
                }
                return true

            case GHOSTTY_ACTION_SCROLLBAR:
                let scrollbar = Ghostty.Action.Scrollbar(c: action.action.scrollbar)
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateScrollbar,
                    object: terminalView,
                    userInfo: [Notification.Name.ScrollbarKey: scrollbar]
                )
                return true

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                let config = action.action.config_change.config
                let background = config.flatMap { colorConfigValue($0, key: "background") }
                let opacity = config.flatMap { doubleConfigValue($0, key: "background-opacity") }
                GhosttyConfig.invalidateLoadCache()
                DispatchQueue.main.async {
                    terminalView?.handleRuntimeConfigChange(
                        backgroundColor: background,
                        backgroundOpacity: opacity
                    )
                }
                return true

            case GHOSTTY_ACTION_COLOR_CHANGE:
                let change = action.action.color_change
                if change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                    let background = NSColor(
                        red: CGFloat(change.r) / 255.0,
                        green: CGFloat(change.g) / 255.0,
                        blue: CGFloat(change.b) / 255.0,
                        alpha: 1.0
                    )
                    DispatchQueue.main.async {
                        terminalView?.handleRuntimeColorChange(backgroundColor: background)
                    }
                }
                return true

            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                let notification = action.action.desktop_notification
                let title = notification.title.map { String(cString: $0) } ?? "Zenban"
                let body = notification.body.map { String(cString: $0) } ?? ""

                DispatchQueue.main.async {
                    guard let terminalView = terminalView,
                          let cardID = terminalView.cardID,
                          let boardID = terminalView.boardID else {
                        Ghostty.logger.warning("Desktop notification received but no card/board context")
                        return
                    }
                    NotificationService.shared.showNotification(
                        title: title,
                        body: body,
                        cardID: cardID,
                        boardID: boardID
                    )
                }
                return true

            default:
                Ghostty.logger.debug("Unhandled action: \(action.tag.rawValue)")
                return false
            }
        }

        static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
            guard let terminalView = terminalView(from: userdata),
                  let surface = terminalView.surface?.unsafeCValue else { return }

            guard let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location) else { return }

            // If clipboard has only an image, save it as a temp PNG and paste the path
            if GhosttyPasteboardHelper.clipboardHasImageOnly(),
               let imagePath = GhosttyPasteboardHelper.saveClipboardImageIfNeeded() {
                imagePath.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
                return
            }

            let clipboardString = GhosttyPasteboardHelper.stringContents(from: pasteboard) ?? ""
            clipboardString.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // Auto-confirm clipboard reads
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            contents: UnsafePointer<ghostty_clipboard_content_s>?,
            count: Int,
            confirm: Bool
        ) {
            guard let contents = contents, count > 0 else { return }

            for idx in 0..<count {
                let entry = contents.advanced(by: idx).pointee
                guard let dataPtr = entry.data else { continue }

                let string = String(cString: dataPtr)
                if !string.isEmpty {
                    GhosttyPasteboardHelper.writeString(string, to: location)
                    return
                }
            }
        }

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            guard let terminalView = terminalView(from: userdata) else { return }
            Ghostty.logger.info("Close surface: processAlive=\(processAlive)")
            DispatchQueue.main.async {
                terminalView.onProcessExit?()
            }
        }
    }
}
