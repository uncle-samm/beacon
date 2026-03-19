# Getting Started with Beacon

Beacon is a full-stack Gleam web framework that runs on BEAM with client-side local execution.

## Quick Start

### 1. Create a new Gleam project

```bash
gleam new my_app
cd my_app
```

### 2. Add Beacon as a dependency

```bash
gleam add beacon
```

### 3. Write your app

```gleam
// src/my_app.gleam
import beacon
import beacon/html

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
  Decrement
}

pub fn init() -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([], [
    html.h1([], [html.text("Counter")]),
    html.button([beacon.on_click(Decrement)], [html.text("-")]),
    html.text(" " <> int.to_string(model.count) <> " "),
    html.button([beacon.on_click(Increment)], [html.text("+")]),
  ])
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.title("My Counter")
  |> beacon.start(8080)
}
```

### 4. Run it

```bash
gleam run
```

Open http://localhost:8080 in your browser.

## Key Concepts

### Model-View-Update (MVU)

Beacon uses the MVU architecture:
- **Model** — your app's state
- **View** — renders the Model to HTML
- **Update** — handles messages and returns new Model

### Three State Layers

1. **Shared state** (via `store`) — all users see the same data
2. **Server state** (Model) — per-tab, server-rendered
3. **Local state** (Local) — per-tab, client-only, zero server traffic

### Local State (Zero Traffic)

```gleam
pub type Model { Model(count: Int) }
pub type Local { Local(input: String) }
pub type Msg {
  Increment        // → changes Model → syncs with server
  SetInput(String) // → changes Local → instant, zero traffic
}

beacon.app_with_local(init, init_local, update, view)
```

### Routing

```gleam
beacon.app(init, update, view)
|> beacon.routes(["/", "/about", "/blog/:slug"])
|> beacon.on_route_change(OnRouteChange)
|> beacon.start(8080)
```

### Shared State (Stores)

```gleam
let shared = store.new("counter")
store.put(shared, "count", 0)

beacon.app_with_local(init, init_local, update, view)
|> beacon.subscriptions(fn(_model) { [store.topic(shared)] })
|> beacon.on_notify(fn(_topic) { CounterUpdated })
|> beacon.start(8080)
```

## Production Deployment

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8080 | Server port |
| `SECRET_KEY` | dev default | Session signing key |
| `BEACON_ENV` | development | Set to `production` for prod |

### Docker

```bash
docker build -t my_app .
docker run -p 8080:8080 -e SECRET_KEY=your-secret my_app
```

### Health Check

`GET /health` returns `{"status":"ok"}` with 200.

## Build Tool

Compile user code to JavaScript for client-side execution:

```bash
gleam run -m beacon/build
```

This creates `priv/static/beacon_client.js` — local events run in the browser with zero server traffic.
