# Kanban Board

Drag-and-drop kanban board with multi-user sync.

## Features

- HTML5 Drag and Drop (dragstart, dragover, drop)
- Three columns: Todo, In Progress, Done
- Shared store with PubSub -- changes sync across tabs
- Add and delete cards with pure update + on_update pattern

## Run

```bash
cd examples/kanban
gleam run
```

Open http://localhost:8080 -- drag cards between columns, add new cards, open multiple tabs.
