import AppKit
import MetalKit
import GhosttyKit

/// NSView subclass that hosts a Ghostty terminal surface with Metal rendering.
public class GhosttyTerminalView: NSView {
    // MARK: - Properties

    /// Unique identifier for this terminal
    public let id: UUID

    /// Card/board context for Zenban integration
    public var cardID: UUID?
    public var boardID: UUID?
    public var cardTitle: String = ""

    /// Working directory for the terminal
    private var workingDirectory: String?

    /// The underlying Ghostty surface
    private var surface: ghostty_surface_t?

    /// Whether the shell is ready to receive input
    public private(set) var isShellReady = false

    /// Command to send when shell becomes ready
    private var pendingCommand: String?

    /// Marked text for input methods
    private var markedText = NSMutableAttributedString()

    /// Whether terminal has been focused (prevents false positives on init)
    private var hasBeenFocused = false

    // MARK: - State Machine

    /// Terminal state for agent lifecycle tracking
    public enum TerminalState: Equatable {
        case shell           // Normal shell, agent not running
        case agentActive     // Agent is running
        case agentIdle       // Agent task completed, awaiting review
    }

    /// Events that trigger state transitions
    public enum TerminalEvent {
        case agentLaunched     // TerminalManager notified agent launch
        case commandFinished   // OSC 133 D received
        case newMessageSent    // User input while idle
        case agentExited       // Ctrl+C pressed
    }

    /// Current terminal state
    private var state: TerminalState = .shell

    /// Callback when agent task completes
    public var onTaskCompleted: ((UUID, UUID) -> Void)?

    /// Callback when agent resumes from idle
    public var onAgentResumed: ((UUID, UUID) -> Void)?

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        self.id = UUID()
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.id = UUID()
        super.init(coder: coder)
        commonInit()
    }

    /// Creates a terminal view with an optional working directory
    public init(frame frameRect: NSRect, workingDirectory: String?) {
        self.id = UUID()
        self.workingDirectory = workingDirectory
        super.init(frame: frameRect)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor

        createSurface()

        // Fallback: Mark shell as ready after a delay if shell integration doesn't respond
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.isShellReady else { return }
            Ghostty.logger.info("Shell readiness fallback triggered")
            self.handleShellReady()
        }
    }

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Surface Management

    private func createSurface() {
        guard let app = GhosttyApp.shared.app else {
            Ghostty.logger.error("GhosttyApp not initialized")
            return
        }

        // Create surface configuration
        var surfaceConfig = ghostty_surface_config_new()

        // Set userdata to self for callbacks
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        // Set platform to macOS
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))

        // Set scale factor
        surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        // Set working directory if provided
        if let workingDirectory = workingDirectory {
            workingDirectory.withCString { cString in
                surfaceConfig.working_directory = cString
                createSurfaceWithConfig(app: app, config: &surfaceConfig)
            }
        } else {
            createSurfaceWithConfig(app: app, config: &surfaceConfig)
        }
    }

    private func createSurfaceWithConfig(app: ghostty_app_t, config: inout ghostty_surface_config_s) {
        let surface = ghostty_surface_new(app, &config)
        if surface == nil {
            Ghostty.logger.error("Failed to create ghostty surface")
            return
        }

        self.surface = surface
        Ghostty.logger.info("Created ghostty surface")
    }

    // MARK: - NSView Overrides

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            hasBeenFocused = true
            if let surface = surface {
                ghostty_surface_set_focus(surface, true)
            }
        }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if let surface = surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentScale()
    }

    public override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    private func updateContentScale() {
        guard let surface = surface else { return }
        let scale = window?.backingScaleFactor ?? 1.0
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func updateSurfaceSize() {
        guard let surface = surface else { return }
        let size = bounds.size
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    // MARK: - Input Handling

    public override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            interpretKeyEvents([event])
            return
        }

        // Send key event to Ghostty
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let handled = sendKeyEvent(surface: surface, event: event, action: action)

        // If Ghostty didn't handle it (not a binding), use standard text input
        if !handled {
            interpretKeyEvents([event])
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        _ = sendKeyEvent(surface: surface, event: event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKeyEvent(surface: ghostty_surface_t, event: NSEvent, action: ghostty_input_action_e) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = ghosttyMods(from: event.modifierFlags)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.text = nil

        // For key press with text, provide the text
        if action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT {
            if let chars = event.characters, !chars.isEmpty {
                return chars.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
            }
        }

        return ghostty_surface_key(surface, keyEvent)
    }

    private func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouseButton(event, state: GHOSTTY_MOUSE_PRESS)
    }

    public override func mouseUp(with event: NSEvent) {
        handleMouseButton(event, state: GHOSTTY_MOUSE_RELEASE)
    }

    public override func mouseMoved(with event: NSEvent) {
        handleMouseMove(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        handleMouseMove(event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        // Build scroll mods
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            mods |= 1  // GHOSTTY_SCROLL_MOD_PRECISE
        }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    private func handleMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e) {
        guard let surface = surface else { return }
        let button: ghostty_input_mouse_button_e
        switch event.buttonNumber {
        case 0: button = GHOSTTY_MOUSE_LEFT
        case 1: button = GHOSTTY_MOUSE_RIGHT
        case 2: button = GHOSTTY_MOUSE_MIDDLE
        default: button = GHOSTTY_MOUSE_UNKNOWN
        }
        let mods = ghosttyMods(from: event.modifierFlags)
        ghostty_surface_mouse_button(surface, state, button, mods)
    }

    private func handleMouseMove(_ event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(from: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
    }

    // MARK: - Public Methods

    /// Send text to the terminal
    public func send(text: String) {
        guard let surface = surface else { return }

        // Check for Ctrl+C to detect agent exit
        if text.contains("\u{03}") {
            transition(event: .agentExited)
        }

        text.withCString { cString in
            ghostty_surface_text(surface, cString, UInt(text.utf8.count))
        }
    }

    /// Send text when the shell is ready
    public func sendWhenReady(_ command: String) {
        if isShellReady {
            send(text: command)
        } else {
            pendingCommand = command
        }
    }

    /// Request the surface to close
    public func terminate() {
        guard let surface = surface else { return }
        ghostty_surface_request_close(surface)
    }

    // MARK: - Signal Handlers (called from GhosttyApp)

    /// Called when shell integration reports command finished (OSC 133 D)
    public func handleCommandFinished() {
        guard state == .agentActive else { return }
        transition(event: .commandFinished)
    }

    /// Called when shell is ready (first action received from shell integration)
    public func handleShellReady() {
        guard !isShellReady else { return }
        isShellReady = true
        executePendingCommandIfNeeded()
    }

    // MARK: - Agent Notification (called from TerminalManager)

    /// Called by TerminalManager when an agent is launched
    public func notifyAgentLaunched() {
        transition(event: .agentLaunched)
    }

    /// Called by TerminalManager when user sends new message to idle agent
    public func notifyNewMessageSent() {
        transition(event: .newMessageSent)
    }

    // MARK: - State Machine

    private func transition(event: TerminalEvent) {
        let newState: TerminalState? = switch (state, event) {
        case (.shell, .agentLaunched): .agentActive
        case (.agentActive, .commandFinished): .agentIdle
        case (.agentActive, .agentExited): .shell
        case (.agentIdle, .newMessageSent): .agentActive
        case (.agentIdle, .agentExited): .shell
        default: nil
        }

        if let newState = newState, newState != state {
            let oldState = state
            state = newState
            handleStateChange(from: oldState, to: newState)
        }
    }

    private func handleStateChange(from oldState: TerminalState, to newState: TerminalState) {
        switch (oldState, newState) {
        case (.agentActive, .agentIdle):
            triggerTaskCompleted()
        case (.agentIdle, .agentActive):
            triggerAgentResumed()
        default:
            break
        }
    }

    // MARK: - Notification Integration

    private func triggerTaskCompleted() {
        guard hasBeenFocused else { return }
        guard let cardID = cardID, let boardID = boardID else { return }
        onTaskCompleted?(cardID, boardID)
    }

    private func triggerAgentResumed() {
        guard let cardID = cardID, let boardID = boardID else { return }
        onAgentResumed?(cardID, boardID)
    }

    private func executePendingCommandIfNeeded() {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        // Small delay to ensure shell is ready to receive input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.send(text: command)
        }
    }
}

// MARK: - NSTextInputClient

extension GhosttyTerminalView: NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String else { return }
        send(text: str)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        } else if let attrStr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attrStr)
        }
        // Handle preedit
        guard let surface = surface else { return }
        let str = markedText.string
        str.withCString { cString in
            ghostty_surface_preedit(surface, cString, UInt(str.utf8.count))
        }
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        guard let surface = surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    public func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return a rect for IME positioning
        guard let surface = surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        let viewPoint = NSPoint(x: x, y: bounds.height - y - h)
        let screenPoint = window?.convertPoint(toScreen: convert(viewPoint, to: nil)) ?? viewPoint
        return NSRect(x: screenPoint.x, y: screenPoint.y, width: w, height: h)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        return 0
    }
}
