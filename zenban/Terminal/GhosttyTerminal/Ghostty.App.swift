//
//  Ghostty.App.swift
//  aizen
//
//  Minimal Ghostty app wrapper - Phase 1: Basic lifecycle
//

import Foundation
import AppKit
import Combine
import OSLog
import SwiftUI

// MARK: - Ghostty Namespace

enum Ghostty {
    static let logger = Logger(subsystem: "com.berkaycit.zenban", category: "GhosttyApp")

    /// Wrapper to hold reference to a surface for tracking
    /// Note: ghostty_surface_t is an opaque pointer, so we store it directly
    /// The surface is freed when the GhosttyTerminalView is deallocated
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
}

// MARK: - Ghostty.App

extension Ghostty {
    /// Minimal wrapper for ghostty_app_t lifecycle management
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

        // MARK: - Published Properties

        /// The ghostty app instance
        @Published var app: ghostty_app_t? = nil

        /// Readiness state
        @Published var readiness: Readiness = .loading

        /// Track active surfaces for config propagation
        private var activeSurfaces: [Ghostty.SurfaceReference] = []

        /// Registry of valid terminal view pointers (for callback safety)
        /// Protected by lock since C callbacks may run on non-main threads
        private nonisolated(unsafe) static var validTerminalViews: Set<UnsafeRawPointer> = []
        private static let validTerminalViewsLock = NSLock()

        /// Track last known appearance to detect changes
        private var lastKnownAppearance: NSAppearance.Name?

        /// Track last known theme to detect changes
        private var lastKnownTheme: String?

        /// Observer for in-app appearance setting changes
        private var appearanceSettingObserver: NSObjectProtocol?

        // MARK: - Terminal Settings

        @AppStorage("terminalFontName") private var terminalFontName = "Menlo"
        @AppStorage("terminalFontSize") private var terminalFontSize = 14.0
        @AppStorage("terminalThemeName") private var terminalThemeName = "Apple System Colors"
        @AppStorage("terminalThemeNameLight") private var terminalThemeNameLight = "Builtin Light"
        @AppStorage("terminalUsePerAppearanceTheme") private var usePerAppearanceTheme = false

        private var effectiveThemeName: String {
            guard usePerAppearanceTheme else { return terminalThemeName }

            let isDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? terminalThemeName : terminalThemeNameLight
        }

        // MARK: - Initialization

        init() {
            // CRITICAL: Initialize libghostty first
            let initResult = ghostty_init(0, nil)
            if initResult != GHOSTTY_SUCCESS {
                Ghostty.logger.critical("ghostty_init failed with code: \(initResult)")
                readiness = .error
                return
            }

            // Create runtime config with callbacks
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

            // Create config and load Aizen terminal settings
            guard let config = ghostty_config_new() else {
                Ghostty.logger.critical("ghostty_config_new failed")
                readiness = .error
                return
            }

            // Load config from settings
            loadConfigIntoGhostty(config)

            // Finalize config (required before use)
            ghostty_config_finalize(config)

            // Create the ghostty app
            guard let app = ghostty_app_new(&runtime_cfg, config) else {
                Ghostty.logger.critical("ghostty_app_new failed")
                ghostty_config_free(config)
                readiness = .error
                return
            }

            // Free config after app creation (app clones it)
            ghostty_config_free(config)

            // CRITICAL: Unset XDG_CONFIG_HOME after app creation
            // If left set, fish will look for config.fish in the temp directory instead of ~/.config
            unsetenv("XDG_CONFIG_HOME")

            self.app = app
            self.readiness = .ready

            // Store initial appearance and theme
            // Use NSApplication.shared instead of NSApp to avoid implicitly unwrapped optional crash
            lastKnownAppearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            lastKnownTheme = effectiveThemeName

            // Observe system appearance changes via DistributedNotificationCenter
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(systemAppearanceDidChange),
                name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil
            )

            // Observe in-app appearance setting changes
            appearanceSettingObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAppearanceSettingChange()
                }
            }

            Ghostty.logger.info("Ghostty app initialized successfully")
        }

        @objc private func systemAppearanceDidChange(_ notification: Notification) {
            handleAppearanceChange()
        }

        private func handleAppearanceChange() {
            guard usePerAppearanceTheme else { return }

            let currentAppearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            guard currentAppearance != lastKnownAppearance else { return }

            lastKnownAppearance = currentAppearance
            reloadIfThemeChanged()
        }

        private func checkAppearanceSettingChange() {
            guard usePerAppearanceTheme else { return }
            reloadIfThemeChanged()
        }

        private func reloadIfThemeChanged() {
            let newTheme = effectiveThemeName
            guard newTheme != lastKnownTheme else { return }

            lastKnownTheme = newTheme
            Ghostty.logger.info("Theme changed, reloading terminal config with theme: \(newTheme)")
            reloadConfig()
        }

        deinit {
            // Note: Cannot access @MainActor isolated properties in deinit
            // The app will be freed when the instance is deallocated
            // For proper cleanup, call a cleanup method before deinitialization
        }

        // MARK: - App Operations

        /// Clean up the ghostty app resources
        func cleanup() {
            DistributedNotificationCenter.default().removeObserver(self)

            if let observer = appearanceSettingObserver {
                NotificationCenter.default.removeObserver(observer)
                appearanceSettingObserver = nil
            }

            if let app = self.app {
                ghostty_app_free(app)
                self.app = nil
            }
        }

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        /// Register a surface for config update tracking
        /// Returns the surface reference that should be stored by the view
        @discardableResult
        func registerSurface(_ surface: ghostty_surface_t) -> Ghostty.SurfaceReference {
            let ref = Ghostty.SurfaceReference(surface)
            activeSurfaces.append(ref)
            // Clean up invalid surfaces
            activeSurfaces = activeSurfaces.filter { $0.isValid }
            return ref
        }

        /// Unregister a surface when it's being deallocated
        func unregisterSurface(_ ref: Ghostty.SurfaceReference) {
            ref.invalidate()
            activeSurfaces = activeSurfaces.filter { $0.isValid }
        }

        /// Register a terminal view as valid for callback safety
        nonisolated static func registerTerminalView(_ view: GhosttyTerminalView) {
            let ptr = Unmanaged.passUnretained(view).toOpaque()
            validTerminalViewsLock.lock()
            validTerminalViews.insert(UnsafeRawPointer(ptr))
            validTerminalViewsLock.unlock()
        }

        /// Unregister a terminal view (call before deallocation)
        nonisolated static func unregisterTerminalView(_ view: GhosttyTerminalView) {
            let ptr = Unmanaged.passUnretained(view).toOpaque()
            validTerminalViewsLock.lock()
            validTerminalViews.remove(UnsafeRawPointer(ptr))
            validTerminalViewsLock.unlock()
        }

        /// Safely get a terminal view from userdata, returning nil if invalid
        nonisolated static func terminalView(from userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
            guard let userdata = userdata else { return nil }
            validTerminalViewsLock.lock()
            let isValid = validTerminalViews.contains(UnsafeRawPointer(userdata))
            validTerminalViewsLock.unlock()
            guard isValid else { return nil }
            return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        }

        /// Reload configuration (call when settings change)
        func reloadConfig() {
            guard let app = self.app else { return }

            // Create new config with updated settings
            guard let config = ghostty_config_new() else {
                Ghostty.logger.error("ghostty_config_new failed during reload")
                return
            }

            // Load config from settings
            loadConfigIntoGhostty(config)

            // Finalize config (required before use)
            ghostty_config_finalize(config)

            // Update the app config
            ghostty_app_update_config(app, config)

            // Propagate config to all existing surfaces
            for surfaceRef in activeSurfaces where surfaceRef.isValid {
                ghostty_surface_update_config(surfaceRef.surface, config)
            }

            // Clean up invalid surfaces
            activeSurfaces = activeSurfaces.filter { $0.isValid }

            ghostty_config_free(config)

            // Unset XDG_CONFIG_HOME so it doesn't affect fish/shell config loading
            unsetenv("XDG_CONFIG_HOME")

            Ghostty.logger.info("Configuration reloaded and propagated to \(self.activeSurfaces.count) surfaces")
        }

        // MARK: - Private Helpers

        /// Generate and load config content into a ghostty_config_t
        private func loadConfigIntoGhostty(_ config: ghostty_config_t) {
            // Create temp config directory
            let tempDir = NSTemporaryDirectory()
            let ghosttyConfigDir = (tempDir as NSString).appendingPathComponent(".config/ghostty")
            let configFilePath = (ghosttyConfigDir as NSString).appendingPathComponent("config")

            do {
                try FileManager.default.createDirectory(atPath: ghosttyConfigDir, withIntermediateDirectories: true)

                // Detect shell for integration
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let shellName = (shell as NSString).lastPathComponent

                // Load theme colors from bundle
                let themeColors = loadThemeColors(named: effectiveThemeName)

                // Create config with font settings, shell integration, and theme colors
                var configContent = """
                font-family = \(terminalFontName)
                font-size = \(Int(terminalFontSize))
                window-inherit-font-size = false
                window-padding-balance = true
                window-padding-x = 0
                window-padding-y = 0
                window-padding-color = extend-always

                # Enable shell integration (resources dir auto-detected from app bundle)
                shell-integration = \(shellName)
                shell-integration-features = no-cursor,sudo,title

                # Cursor
                cursor-style-blink = true

                # Disable audible bell
                audible-bell = false

                # Custom keybinds
                keybind = shift+enter=text:\\n

                """

                // Append theme colors directly to config
                if !themeColors.isEmpty {
                    configContent += "\n# Theme: \(effectiveThemeName)\n"
                    configContent += themeColors
                }

                Ghostty.logger.info("Loading Ghostty theme: \(self.effectiveThemeName)")

                try configContent.write(toFile: configFilePath, atomically: true, encoding: .utf8)

                // Set XDG_CONFIG_HOME to our temp directory
                setenv("XDG_CONFIG_HOME", (tempDir as NSString).appendingPathComponent(".config"), 1)

                // Load default files - will load our XDG config
                ghostty_config_load_default_files(config)

                Ghostty.logger.info("Loaded Zenban terminal settings - Font: \(self.terminalFontName) \(Int(self.terminalFontSize))pt, Theme: \(self.effectiveThemeName)")
            } catch {
                Ghostty.logger.warning("Failed to write config: \(error)")
            }
        }

        /// Load theme colors from bundle Resources
        private func loadThemeColors(named themeName: String) -> String {
            // Themes are copied directly to Resources/ by Xcode
            guard let resourcePath = Bundle.main.resourcePath else {
                Ghostty.logger.warning("Could not get bundle resource path")
                return ""
            }

            let themePath = (resourcePath as NSString).appendingPathComponent(themeName)

            guard FileManager.default.fileExists(atPath: themePath) else {
                Ghostty.logger.warning("Theme file not found: \(themePath)")
                return ""
            }

            do {
                let themeContent = try String(contentsOfFile: themePath, encoding: .utf8)
                return themeContent
            } catch {
                Ghostty.logger.warning("Failed to read theme file: \(error)")
                return ""
            }
        }

        // MARK: - Callbacks (macOS)

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata = userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()

            // Schedule tick on main thread
            DispatchQueue.main.async {
                state.appTick()
            }
        }

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Get the terminal view from surface userdata if target is a surface
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
                // Window/tab title change
                if let titlePtr = action.action.set_title.title {
                    let title = String(cString: titlePtr)
                    Ghostty.logger.info("Title changed: \(title)")

                    // Propagate to terminal view callback
                    DispatchQueue.main.async {
                        terminalView?.onTitleChange?(title)
                    }
                }
                return true

            case GHOSTTY_ACTION_PWD:
                // Working directory change
                if let pwdPtr = action.action.pwd.pwd {
                    let pwd = String(cString: pwdPtr)
                    Ghostty.logger.info("PWD changed: \(pwd)")
                }
                return true

            case GHOSTTY_ACTION_PROMPT_TITLE:
                // Prompt title update (for shell integration)
                Ghostty.logger.debug("Prompt title action received")
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
                // Cell size update - used for row-to-pixel conversion in scrollbar
                let cellSize = action.action.cell_size
                let backingSize = NSSize(width: Double(cellSize.width), height: Double(cellSize.height))
                DispatchQueue.main.async {
                    guard let terminalView = terminalView else { return }
                    // Convert from backing (pixel) coordinates to points
                    terminalView.cellSize = terminalView.convertFromBacking(backingSize)
                }
                return true

            case GHOSTTY_ACTION_SCROLLBAR:
                // Scrollbar state update - post notification for scroll view
                let scrollbar = Ghostty.Action.Scrollbar(c: action.action.scrollbar)
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateScrollbar,
                    object: terminalView,
                    userInfo: [Notification.Name.ScrollbarKey: scrollbar]
                )
                return true

            default:
                // Log unhandled actions
                Ghostty.logger.debug("Action received: \(action.tag.rawValue) on target: \(target.tag.rawValue)")
                return false
            }
        }

        static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
            guard let terminalView = terminalView(from: userdata),
                  let surface = terminalView.surface?.unsafeCValue else { return }

            // Read from macOS clipboard
            let clipboardString = Clipboard.readString() ?? ""

            // Complete the clipboard request by providing data to Ghostty
            clipboardString.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }

            Ghostty.logger.debug("Read clipboard: \(clipboardString.prefix(50))...")
        }

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            // Clipboard read confirmation
            // For security, apps can confirm before allowing clipboard access
            // For now, just log it
            Ghostty.logger.debug("Clipboard read confirmation requested")
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            contents: UnsafePointer<ghostty_clipboard_content_s>?,
            count: Int,
            confirm: Bool
        ) {
            guard let contents = contents, count > 0 else { return }

            // The runtime passes an array of clipboard entries; prefer the first
            // textual entry. The API does not supply a byte length, so we treat
            // the data as a null-terminated UTF-8 C string.
            for idx in 0..<count {
                let entry = contents.advanced(by: idx).pointee
                guard let dataPtr = entry.data else { continue }

                let string = String(cString: dataPtr)
                if !string.isEmpty {
                    Clipboard.copy(string)
                    Ghostty.logger.debug("Wrote to clipboard: \(string.prefix(50))...")
                    return
                }
            }
        }

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            guard let terminalView = terminalView(from: userdata) else { return }
            Ghostty.logger.info("Close surface: processAlive=\(processAlive)")

            // Trigger process exit callback on main thread
            DispatchQueue.main.async {
                terminalView.onProcessExit?()
            }
        }
    }
}
