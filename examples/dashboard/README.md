# Live Dashboard

Auto-refreshing BEAM runtime metrics with sparkline charts.

## Features

- Server-push via `effect.every()` -- no client interaction needed
- Real BEAM metrics: process count, memory usage, uptime
- SVG sparkline rendering with rolling 30-sample history
- Updates every second automatically

## Run

```bash
cd examples/dashboard
gleam run
```

Open http://localhost:8080 -- watch process count, memory, and uptime update in real time.
