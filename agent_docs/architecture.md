# Architecture

## Directory Structure

```
zenban/
├── Models/          # Data models (Board, Card, Column)
├── Storage/         # JSON persistence layer
├── ViewModels/      # @Observable state management
├── Views/
│   ├── Sidebar/     # Board list navigation
│   ├── Board/       # Kanban board layout
│   ├── Card/        # Card display and editing
│   └── Components/  # Reusable UI components
├── Terminal/        # Embedded terminal per card (SwiftTerm + tmux)
├── Commands/        # Menu keyboard shortcuts
└── Extensions/      # Color theme extensions
```

## Data Flow

1. `BoardStore` (@Observable) holds all state
2. `BoardStorage` handles JSON file I/O with debounced saves
3. Views read from `BoardStore` via `@Environment`
4. User actions call `BoardStore` methods which update state and trigger save

## Key Components

| Component | Purpose |
|-----------|---------|
| `BoardStore` | Central state manager, injected via environment |
| `BoardStorage` | JSON persistence to Application Support |
| `Column` | Enum with display name and accent color |
| `HSplitView` | Three-column layout: sidebar, board, card detail (enforces min widths) |
| `ColumnView` | Handles drag-drop with `.onDrag` and `.dropDestination()` |
| `CardDetailView` | Right panel for viewing and editing selected card |
| `TerminalManager` | Manages tmux sessions and terminal views per card |
| `TmuxSessionController` | Actor for tmux process communication |
