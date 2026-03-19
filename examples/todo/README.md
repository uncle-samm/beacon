# Todo App

Full-featured todo list with filters, shared store, and local filter state.

## Features

- CRUD: add, toggle, delete, clear completed
- Local filter state (All/Active/Completed) with zero server traffic
- Derived "items left" counter computed in view, not stored in model
- Multi-user sync via shared store and PubSub

## Run

```bash
cd examples/todo
gleam run
```

Open http://localhost:8080 -- add todos, toggle them, filter by status, open multiple tabs.
