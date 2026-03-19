# Routed

File-based routing with `beacon.router()` -- each route is a separate Gleam module.

## Features

- Four routes: `/` (counter), `/about` (static), `/settings` (form), `/stats` (state isolation)
- Each route defined in `src/routes/*.gleam` with its own Model/Msg/view
- `beacon.router()` + `beacon.start_router()` auto-discovers route files
- Per-route state isolation

## Run

```bash
cd examples/routed
gleam run
```

Open http://localhost:8080 -- navigate between /, /about, /settings, and /stats.
