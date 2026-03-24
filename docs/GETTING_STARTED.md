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

This creates a content-hashed file like `priv/static/beacon_client_HASH.js` — local events run in the browser with zero server traffic.

## Development Mode

For a fast feedback loop during development:

```bash
gleam run -m beacon/dev
```

This starts your app with file watching and hot module reload:

- Watches `.gleam` files for changes, auto-rebuilds server + client
- Hot-swaps BEAM modules without restarting — no lost WebSocket connections
- Notifies connected browsers to reload automatically
- Uses native file watchers (`fswatch` on macOS, `inotifywait` on Linux) with polling fallback

For production, use `gleam run` directly — no file watcher, no HMR overhead.

## Server Privacy

The build system automatically strips server-only code from the client JS bundle. Three mechanisms keep secrets server-side:

1. **`server_` prefix** on constants — excluded from the client bundle
2. **`pub type Server`** — private server-side state that never reaches the client
3. **Server-module references** — code referencing `store`, `effect`, `pubsub`, `process` is automatically excluded

Code referencing server-only modules (`store`, `effect`, `pubsub`, `process`) is automatically detected and excluded.

```gleam
const server_api_key = "sk_live_secret_key"   // stripped from client JS
const app_title = "My App"                     // included — used by view
```

The `Server` type is available in `update` but not `view`, so the compiler itself prevents accidental leaks.
