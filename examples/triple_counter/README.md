# Triple Counter

Three counters demonstrating all three Beacon state layers side by side.

## Features

- Shared counter: all tabs see the same value (store + PubSub)
- Server counter: per-tab, server-rendered (each connection independent)
- Local counter: instant, zero server traffic (client-only)
- Open multiple tabs to see the difference between state layers

## Run

```bash
cd examples/triple_counter
gleam run
```

Open http://localhost:8080 in multiple tabs -- shared syncs everywhere, server and local are per-tab.
