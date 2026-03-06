//
//  GhosttyRenderingSetup.swift
//  aizen
//
//  Handles Metal layer setup and rendering configuration for Ghostty terminal
//

import AppKit
import Metal
import OSLog

/// Manages Metal rendering setup and configuration for Ghostty terminal
@MainActor
class GhosttyRenderingSetup {
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "win.aizen.app", category: "GhosttyRendering")

    // MARK: - Display ID

    /// Set the display ID on a surface for proper CVDisplayLink vsync.
    /// Without this, the terminal can appear frozen after window moves or focus changes.
    static func setDisplayID(for surface: ghostty_surface_t, window: NSWindow?) {
        let screen = window?.screen ?? NSScreen.main
        guard let screen = screen else { return }
        ghostty_surface_set_display_id(surface, screen.displayID)
    }

    // MARK: - Layer Setup

    /// Configure the Metal-backed layer for terminal rendering
    ///
    /// CRITICAL: Must set layer property BEFORE setting wantsLayer = true
    /// This ensures Metal rendering works correctly
    func setupLayer(for view: NSView) {
        // Create Metal layer
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // IMPORTANT: Set layer before wantsLayer for proper Metal initialization
        view.layer = metalLayer
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .duringViewResize

        Self.logger.debug("Metal layer configured")
    }

    // MARK: - Surface Setup

    /// Create and configure the Ghostty surface
    func setupSurface(
        view: NSView,
        ghosttyApp: ghostty_app_t,
        worktreePath: String,
        initialBounds: NSRect,
        window: NSWindow?,
        paneId: String? = nil,
        command: String? = nil
    ) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()

        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = Double(window?.backingScaleFactor ?? 2.0)

        // Build environment variables
        var env: [String: String] = [:]
        env["ZENBAN_TERMINAL"] = "1"

        // Shell integration: inject ZDOTDIR wrapper for zsh shells
        if let resourcesDir = Bundle.main.resourceURL?.path {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh",
               let zdotdir = Self.prepareZdotdir(from: resourcesDir) {
                env["ZENBAN_SHELL_INTEGRATION"] = "1"
                env["ZENBAN_SHELL_INTEGRATION_DIR"] = zdotdir

                let candidateZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    if let ghosttyResources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = (candidateZdotdir == ghosttyZdotdir)
                    }
                    if !isGhosttyInjected {
                        env["ZENBAN_ZSH_ZDOTDIR"] = candidateZdotdir
                    }
                }

                env["ZDOTDIR"] = zdotdir
            }
        }

        // Convert env dict to ghostty_env_var_s array
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        envVars.reserveCapacity(env.count)
        envStorage.reserveCapacity(env.count)
        for (key, value) in env {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            envStorage.append((keyPtr, valuePtr))
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }

        var workingDirPtr: UnsafeMutablePointer<CChar>?
        var initialInputPtr: UnsafeMutablePointer<CChar>?

        if let workingDir = strdup(worktreePath) {
            workingDirPtr = workingDir
            surfaceConfig.working_directory = UnsafePointer(workingDir)
        }

        if let command = command, !command.isEmpty {
            let inputWithNewline = command + "\n"
            if let input = strdup(inputWithNewline) {
                initialInputPtr = input
                surfaceConfig.initial_input = UnsafePointer(input)
            }
        }

        let cSurface: ghostty_surface_t? = envVars.withUnsafeMutableBufferPointer { buffer in
            surfaceConfig.env_vars = buffer.baseAddress
            surfaceConfig.env_var_count = buffer.count
            return ghostty_surface_new(ghosttyApp, &surfaceConfig)
        }

        // Free all allocated strings
        for (keyPtr, valuePtr) in envStorage {
            free(keyPtr)
            free(valuePtr)
        }
        if let wd = workingDirPtr { free(wd) }
        if let input = initialInputPtr { free(input) }

        guard let cSurface else {
            Self.logger.error("ghostty_surface_new failed")
            return nil
        }

        let scaledSize = view.convertToBacking(initialBounds.size.width > 0 ? initialBounds.size : NSSize(width: 800, height: 600))
        ghostty_surface_set_size(cSurface, UInt32(scaledSize.width), UInt32(scaledSize.height))

        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_content_scale(cSurface, scale, scale)

        // Set display ID for CVDisplayLink vsync
        Self.setDisplayID(for: cSurface, window: window)

        Self.logger.info("Ghostty surface created at: \(worktreePath)")
        return cSurface
    }

    // MARK: - Shell Integration

    /// Cached ZDOTDIR path (created once, reused across surfaces)
    private static var cachedZdotdir: String?

    /// Create a temp directory with dotfile symlinks pointing to bundled shell integration files.
    /// Xcode strips dotfiles from bundles, so we store them without dots and symlink at runtime.
    static func prepareZdotdir(from resourcesDir: String) -> String? {
        if let cached = cachedZdotdir {
            return cached
        }

        let fm = FileManager.default
        let zdotdir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("zenban-zdotdir")

        try? fm.createDirectory(atPath: zdotdir, withIntermediateDirectories: true)

        // Symlink dotfiles (stored without dots in bundle)
        let dotMappings = [
            ("zshenv", ".zshenv"),
            ("zshrc", ".zshrc"),
            ("zprofile", ".zprofile"),
            ("zlogin", ".zlogin"),
        ]

        for (source, dotName) in dotMappings {
            let sourcePath = (resourcesDir as NSString).appendingPathComponent(source)
            let linkPath = (zdotdir as NSString).appendingPathComponent(dotName)
            guard fm.fileExists(atPath: sourcePath) else { continue }
            try? fm.removeItem(atPath: linkPath)
            try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: sourcePath)
        }

        // Also symlink the integration script so ZENBAN_SHELL_INTEGRATION_DIR can find it
        let integrationScript = "zenban-zsh-integration.zsh"
        let scriptSource = (resourcesDir as NSString).appendingPathComponent(integrationScript)
        let scriptLink = (zdotdir as NSString).appendingPathComponent(integrationScript)
        if fm.fileExists(atPath: scriptSource) {
            try? fm.removeItem(atPath: scriptLink)
            try? fm.createSymbolicLink(atPath: scriptLink, withDestinationPath: scriptSource)
        }

        cachedZdotdir = zdotdir
        return zdotdir
    }

    // MARK: - Appearance Observation

    /// Setup observation for system appearance changes (light/dark mode)
    /// Implementation copied from Ghostty's SurfaceView_AppKit.swift
    func setupAppearanceObservation(for view: NSView, surface: Ghostty.Surface?) -> NSKeyValueObservation? {
        var lastScheme: UInt32?
        return view.observe(\.effectiveAppearance, options: [.new, .initial]) { view, change in
            guard let appearance = change.newValue else { return }
            guard let surface = surface?.unsafeCValue else { return }

            let scheme: ghostty_color_scheme_e
            switch (appearance.name) {
            case .aqua, .vibrantLight:
                scheme = GHOSTTY_COLOR_SCHEME_LIGHT

            case .darkAqua, .vibrantDark:
                scheme = GHOSTTY_COLOR_SCHEME_DARK

            default:
                scheme = GHOSTTY_COLOR_SCHEME_DARK
            }

            // Skip redundant color scheme updates
            guard lastScheme != scheme.rawValue else { return }
            lastScheme = scheme.rawValue

            ghostty_surface_set_color_scheme(surface, scheme)
            Self.logger.debug("Color scheme updated to: \(scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light")")
        }
    }

    // MARK: - Scale and Size Updates

    /// Update Metal layer content scale and surface scale factors
    func updateBackingProperties(view: NSView, surface: ghostty_surface_t?, window: NSWindow?) {
        guard let surface = surface else { return }

        // Update Metal layer content scale
        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        // Update surface scale factors
        let fbFrame = view.convertToBacking(view.frame)
        let xScale = fbFrame.size.width / view.frame.size.width
        let yScale = fbFrame.size.height / view.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        // Update surface size (framebuffer dimensions changed)
        ghostty_surface_set_size(
            surface,
            UInt32(fbFrame.size.width),
            UInt32(fbFrame.size.height)
        )
    }

    /// Update Metal layer frame and Ghostty surface size
    func updateLayout(view: NSView, metalLayer: CAMetalLayer?, surface: ghostty_surface_t?, lastSize: inout CGSize) -> Bool {
        // Wrap all layer property mutations to suppress implicit Core Animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Update Metal layer frame to match view bounds
        if let metalLayer = metalLayer {
            metalLayer.frame = view.bounds
        }

        // Update Ghostty surface size during layout pass
        // Only update if backing pixel size actually changed to prevent flicker
        guard let surface = surface else { return false }
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return false }

        var scaledSize = view.convertToBacking(view.bounds.size)
        scaledSize = snapSizeToCell(surface: surface, scaledSize: scaledSize)

        // Only update if size changed by at least 1 pixel
        let widthChanged = abs(scaledSize.width - lastSize.width) >= 1.0
        let heightChanged = abs(scaledSize.height - lastSize.height) >= 1.0

        guard widthChanged || heightChanged else { return false }

        lastSize = scaledSize
        if let metalLayer = metalLayer {
            metalLayer.drawableSize = scaledSize
        }
        ghostty_surface_set_size(
            surface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )
        ghostty_surface_refresh(surface)

        return true
    }

    /// Snap the desired pixel size down to the nearest full terminal cell to avoid partial-cell artifacts.
    /// Snap size to whole pixels (scaledSize is already in pixel units).
    func snapSizeToCell(surface: ghostty_surface_t, scaledSize: CGSize) -> CGSize {
        CGSize(width: floor(scaledSize.width), height: floor(scaledSize.height))
    }
}

// MARK: - NSScreen Display ID

extension NSScreen {
    /// The CGDirectDisplayID for this screen, used for CVDisplayLink vsync.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
