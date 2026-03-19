# Counter with Local State

Counter demonstrating the Model + Local state split.

## Features

- `Model.count` is server state (synced across the wire)
- `Local.input` and `Local.menu_open` are client state (instant, per-tab)
- `beacon.app_with_local` builder for dual-state apps
- Toggle menu and text input update without server round-trips

## Run

```bash
cd examples/counter_local
gleam run
```

Open http://localhost:8080 -- increment the counter (server) and type/toggle menu (local).
