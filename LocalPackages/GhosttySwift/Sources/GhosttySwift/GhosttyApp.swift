import Foundation
import AppKit
import GhosttyKit

/// Singleton that manages the global Ghostty application context.
public final class GhosttyApp: @unchecked Sendable {
    public static let shared = GhosttyApp()

    public private(set) var app: ghostty_app_t?
    public private(set) var config: ghostty_config_t?
    public private(set) var isReady = false

    private init() {
        initialize()
    }

    private func initialize() {
        // Initialize Ghostty global state first
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initResult != GHOSTTY_SUCCESS {
            Ghostty.logger.error("ghostty_init failed")
            return
        }

        // Create and configure ghostty config
        let config = ghostty_config_new()
        self.config = config

        // Load default configuration files
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        // Create runtime configuration with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true

        // Set up required callbacks
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata = userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                app.tick()
            }
        }

        runtimeConfig.action_cb = { appPtr, target, action in
            // Route surface-targeted actions to the appropriate GhosttyTerminalView
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface) else {
                return false
            }

            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()

            // Notify shell ready on any action (shell integration is active)
            DispatchQueue.main.async {
                view.handleShellReady()
            }

            switch action.tag {
            case GHOSTTY_ACTION_COMMAND_FINISHED:
                DispatchQueue.main.async {
                    view.handleCommandFinished()
                }
                return true
            default:
                return false
            }
        }

        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            GhosttyApp.handleReadClipboard(userdata: userdata, location: location, state: state)
        }

        runtimeConfig.write_clipboard_cb = { userdata, location, contentPtr, len, confirm in
            guard let contentPtr = contentPtr else { return }
            // Content is a pointer to ghostty_clipboard_content_s
            let content = contentPtr.pointee
            if let dataPtr = content.data {
                let str = String(cString: dataPtr)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(str, forType: .string)
            }
        }

        runtimeConfig.close_surface_cb = { userdata, processAlive in
            // Handle surface close - can notify delegates
        }

        // Create the Ghostty app
        let app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            Ghostty.logger.error("Failed to create ghostty app")
            ghostty_config_free(config)
            self.config = nil
            return
        }

        self.app = app
        self.isReady = true
        Ghostty.logger.info("Ghostty app initialized successfully")
    }

    deinit {
        if let app = app {
            ghostty_app_free(app)
        }
        if let config = config {
            ghostty_config_free(config)
        }
    }

    // MARK: - Public Methods

    public func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }

    public func setFocus(_ focused: Bool) {
        guard let app = app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: - Clipboard Handlers

    private static func handleReadClipboard(userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
        let pasteboard = NSPasteboard.general
        let content = pasteboard.string(forType: .string) ?? ""
        // Note: Full implementation would complete the async clipboard request
        Ghostty.logger.debug("Clipboard read requested")
    }

}
