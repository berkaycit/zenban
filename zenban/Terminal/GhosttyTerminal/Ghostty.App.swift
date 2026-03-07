//
//  Ghostty.App.swift
//  zenban
//
//  Ghostty app wrapper - loads user's standard ghostty config
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

    /// Configure environment variables for ghostty shell integration
    static func configureEnvironment() {
        if let resourcesDir = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty").path {
            setenv("GHOSTTY_RESOURCES_DIR", resourcesDir, 1)
        }
        setenv("TERM", "xterm-ghostty", 0)
        setenv("TERM_PROGRAM", "ghostty", 0)
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

            // Load user's standard ghostty config (from ~/.config/ghostty/config etc.)
            guard let config = ghostty_config_new() else {
                Ghostty.logger.critical("ghostty_config_new failed")
                readiness = .error
                return
            }

            ghostty_config_load_default_files(config)
            ghostty_config_finalize(config)

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
                Ghostty.logger.warning("Ghostty initialized with fallback config (user config had errors)")
                return
            }

            ghostty_config_free(config)
            self.app = app
            self.readiness = .ready

            lastKnownAppearance = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])

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
                self?.reloadConfig()
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

            ghostty_config_load_default_files(config)
            ghostty_config_finalize(config)

            ghostty_app_update_config(app, config)

            for surfaceRef in activeSurfaces where surfaceRef.isValid {
                ghostty_surface_update_config(surfaceRef.surface, config)
            }

            activeSurfaces = activeSurfaces.filter { $0.isValid }
            ghostty_config_free(config)

            Ghostty.logger.info("Configuration reloaded from user config files")
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
