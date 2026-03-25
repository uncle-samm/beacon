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
import gleam/int

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
  |> beacon.head_html("<link rel='stylesheet' href='/styles.css'>")
  |> beacon.start(8080)
}
```

`beacon.head_html(html_string)` injects custom content into the `<head>` of the SSR page -- use it for stylesheets, meta tags, fonts, or any other head content your app needs.

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

### API Routes

```gleam
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import beacon/transport/server.{Bytes}
import gleam/bytes_tree

beacon.app(init, update, view)
|> beacon.api_routes(fn(req) {
  case req.method, request.path_segments(req) {
    http.Get, ["api", "status"] ->
      Some(
        response.new(200)
        |> response.set_header("content-type", "application/json")
        |> response.set_body(Bytes(bytes_tree.from_string("{\"ok\":true}")))
      )
    http.Post, ["api", "webhook"] -> Some(handle_webhook(req))
    _, _ -> None
  }
})
|> beacon.start(8080)
```

The handler runs **before** SSR/static file routing. Return `Some(response)` to handle, `None` to fall through to normal page rendering.

Use `beacon/transport/http.read_body(req, max_bytes)` to read POST bodies.

### Cookies

```gleam
import beacon/cookie

// Read cookies from a request
let token = cookie.get(req, "session_token")

// Set a cookie on a response (secure defaults: HttpOnly, Secure, SameSite=Lax)
response.new(200)
|> cookie.set_default("session", token)

// Set with custom options
response.new(200)
|> cookie.set("session", token, cookie.CookieOptions(
  max_age: Some(86400),
  path: "/",
  http_only: True,
  secure: False,  // False for local development
  same_site: "Lax",
))

// Delete a cookie
response.new(200)
|> cookie.delete("session")
```

Shorthand: `beacon.get_cookie(req, "name")` is available on the main module.

### WebSocket Authentication

```gleam
beacon.app(init, update, view)
|> beacon.ws_auth(fn(req) {
  case beacon.get_cookie(req, "session_token") {
    Ok(token) -> validate_session(token)
    Error(Nil) -> Error("No session cookie")
  }
})
|> beacon.start(8080)
```

Runs before the WebSocket upgrade handshake. Return `Ok(Nil)` to allow, `Error(reason)` to reject with 401.

### Request-Aware Server Init (ws_init)

With `app_with_server`, the `init_server` function takes no arguments. Use `ws_init` to replace it with a function that receives the HTTP request -- so you can read cookies, headers, and query params to populate server state:

```gleam
beacon.app_with_server(init, init_server, update, view)
|> beacon.ws_auth(fn(req) {
  case beacon.get_cookie(req, "session") {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error("No session")
  }
})
|> beacon.ws_init(fn(req) {
  let user_id = case beacon.get_cookie(req, "session") {
    Ok(token) -> validate_and_get_user_id(token)
    Error(Nil) -> None
  }
  #(Model(count: 0), ServerState(user_id: user_id, db_pool: get_pool()))
})
|> beacon.start(8080)
```

When `ws_init` is set, it replaces both `init` and `init_server` -- it returns the full combined state `#(Model, Server)`. Without `ws_init`, the original `init` + `init_server` functions are used (backwards compatible).

### Effects and Async

For apps that need side effects (HTTP calls, database queries, timers):

```gleam
beacon.app_with_effects(init, update, view)
|> beacon.start(8080)
```

Where `init` returns `#(model, Effect(msg))` and `update` returns `#(model, Effect(msg))`.

Available effects:
- `effect.from(fn(dispatch) { ... })` -- run async work, dispatch messages back
- `effect.background(fn(dispatch) { ... })` -- spawned process, won't block
- `effect.every(ms, fn() { msg })` -- recurring timer
- `effect.batch([effect1, effect2])` -- run multiple effects
- `effect.none()` -- no side effect

### Server-Only State

Private state that never reaches the client:

```gleam
beacon.app_with_server(init, init_server, update, view)
|> beacon.start(8080)
```

- `init_server` returns server-only state (DB pools, API keys, etc.)
- `update` receives both `model` and `server`, returns `#(model, server, Effect(msg))`
- `view` receives only `model` -- server state is invisible to the view
- Server state is never serialized, never sent to client, never in JS bundle
- Model updates ARE automatically pushed to the client via an auto-generated codec -- the build system generates `beacon_codec.gleam` for `app_with_server` apps too, encoding only Model fields (never Server)

### Redirects

Navigate the client to a new URL from the server:

```gleam
fn update(model, msg) {
  case msg {
    LoginSuccess -> #(model, beacon.redirect("/dashboard"))
    Logout -> #(model, beacon.redirect("/login"))
    _ -> #(model, effect.none())
  }
}
```

`beacon.hard_redirect(path)` triggers a full page reload via `window.location.href` instead of pushState. Use when the browser needs to make a real HTTP request (e.g., to receive a `Set-Cookie` header after login):

```gleam
fn update(model, server, msg) {
  case msg {
    LoginSuccess(token) ->
      #(model, server, beacon.hard_redirect("/api/auth/session/" <> token))
    _ -> #(model, server, effect.none())
  }
}
```

### Form Submission

```gleam
html.form([beacon.on_submit(FormSubmitted)], [
  html.input([html.type_("text"), beacon.on_input(SetName)]),
  html.button([html.type_("submit")], [html.text("Submit")]),
])
```

`on_submit` prevents the default form submission and sends the message to the server.

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
