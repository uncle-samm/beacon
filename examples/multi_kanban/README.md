# Multi-File Kanban

Kanban board with Card and Column types defined in a separate domain module.

## Features

- External types from `domains/board.gleam` (Card, Column enum: Todo/Doing/Done)
- HTML5 drag-and-drop between columns
- Codec generation handles types imported from other modules
- Add and delete cards

## Run

```bash
cd examples/multi_kanban
gleam run
```

Open http://localhost:8080 -- drag cards between columns. Types come from `src/domains/board.gleam`.
