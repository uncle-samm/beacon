# Spreadsheet

Editable grid (10x5) with click-to-select, click-to-edit, and multi-user sync.

## Features

- 50-cell grid with column/row headers (A-E, 1-10)
- Local editing state (selection and edit buffer are client-side)
- Enter to confirm, Escape to cancel edits
- Multi-user: edits in one tab sync to others via shared store

## Run

```bash
cd examples/spreadsheet
gleam run
```

Open http://localhost:8080 -- click a cell to select, click again to edit, press Enter to save.
