# Multi-File Todo

Todo app with TodoItem and Filter types defined in a separate domain module.

## Features

- External types from `domains/task.gleam` (TodoItem, Filter enum: All/Active/Completed)
- Local state for filter selection (zero server traffic)
- Add, toggle, delete, and clear completed todos
- Codec generation handles types imported from other modules

## Run

```bash
cd examples/multi_todo
gleam run
```

Open http://localhost:8080 -- manage todos with filter tabs. Types come from `src/domains/task.gleam`.
