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

## Testing

- For notification, hook, Claude, Codex, or terminal-agent verification, run test boards and card workdirs from a non-protected path such as `~/Library/Caches/Zenban/notification-test-workdir`
- Do not use Desktop, Documents, Downloads, Photos, Music, or other TCC-protected folders for unattended app verification; those prompts block Computer-driven tests
- If TCC prompts reappear during notification tests, check for stale app state such as `NSOSPLastRootDirectory` pointing at a protected folder and move the board/card workdirs back under `~/Library/Caches/Zenban/...`
- Confirm the launched agent environment uses the cache workdir for both `CMUX_AGENT_LAUNCH_CWD` and `PWD` before treating notification behavior as blocked

## Naming

- Views: `*View.swift` (e.g., `BoardView`, `CardView`)
- Models: Singular nouns (e.g., `Board`, `Card`)
- Store: `*Store.swift` for state managers

## Performance

- Avoid unnecessary re-renders with targeted @Observable properties
- Use computed properties for derived data (e.g., `cards(in:)`)
- Keep view bodies simple and focused
