# Counter

The simplest Beacon app -- a server-rendered counter.

## Features

- Minimal Model-View-Update (MVU) pattern
- `beacon.on_click` event handling
- `beacon.app` builder with no effects or local state

## Run

```bash
cd examples/counter
gleam run
```

Open http://localhost:8080 -- click + and - to change the count.
