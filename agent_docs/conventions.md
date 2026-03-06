# Conventions

## State Management

- Use `@Observable` macro for observable classes
- Inject state via `.environment()` in App, access with `@Environment`
- Use `@Bindable var store = store` pattern for bindings in body

## SwiftUI Patterns

- Prefer `LazyVStack` for lists with many items
- Use `.onReceive()` for NotificationCenter integration
- Drag-drop: `.draggable()` with String, `.dropDestination(for: String.self)`

## Persistence

- Debounce saves with 500ms delay to minimize I/O
- Use atomic writes: `data.write(to:options:.atomic)`
- Store in `~/Library/Application Support/com.berkaycit.zenban/`

## Naming

- Views: `*View.swift` (e.g., `BoardView`, `CardView`)
- Models: Singular nouns (e.g., `Board`, `Card`)
- Store: `*Store.swift` for state managers

## Performance

- Avoid unnecessary re-renders with targeted @Observable properties
- Use computed properties for derived data (e.g., `cards(in:)`)
- Keep view bodies simple and focused

## Ghostty Terminal

- Wrap Metal layer property mutations in `CATransaction.begin/commit` with `setDisableActions(true)` to suppress implicit Core Animation
- Call `ghostty_surface_set_display_id` after surface creation and on focus/window changes for proper CVDisplayLink vsync
- Cache color scheme state to avoid redundant `ghostty_surface_set_color_scheme` calls
- Ctrl-modified keys should bypass `interpretKeyEvents` (IME) since they're always handled by Ghostty
- Terminal config comes from user's `~/.config/ghostty/config` -- no custom settings UI
- Shell integration files stored without dots in bundle (Xcode strips dotfiles); runtime symlinks created in temp ZDOTDIR
