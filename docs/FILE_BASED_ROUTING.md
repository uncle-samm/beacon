# File-Based Routing

Beacon supports file-based routing where each `.gleam` file in `src/routes/` becomes a URL route. The scanner parses files with Glance and the codegen generates type-safe route matching and dispatching.

## Directory Structure

| File path | URL |
|-----------|-----|
| `src/routes/index.gleam` | `/` |
| `src/routes/about.gleam` | `/about` |
| `src/routes/blog/index.gleam` | `/blog` |
| `src/routes/blog/[slug].gleam` | `/blog/:slug` |

The `index.gleam` file maps to the root of its directory. Bracket-wrapped filenames like `[slug].gleam` become dynamic parameters.

## Route File Requirements

Every route file must export a public `view` function. The scanner also detects optional exports:

- `Model` custom type -- the route's state
- `Msg` custom type -- the route's messages
- `init()` -- returns initial `Model` (may take a `Dict(String, String)` params argument for dynamic routes)
- `update(model, msg)` -- returns updated `Model`
- `view(model)` -- returns `Node(Msg)` (required)

## Example Route File

```gleam
import beacon
import beacon/html
import gleam/int

pub type Model { Model(count: Int) }
pub type Msg { Increment  Decrement }
pub fn init() -> Model { Model(count: 0) }
pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
    Decrement -> Model(count: model.count - 1)
  }
}
pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([], [
    html.button([beacon.on_click(Increment)], [html.text("+")]),
    html.a([html.href("/about")], [html.text("About")]),
  ])
}
```

## Using the Router Builder

In `main.gleam`, use `beacon.router()` instead of `beacon.app()`:

```gleam
import beacon

pub fn main() {
  beacon.router()
  |> beacon.router_title("My App")
  |> beacon.router_static_dir("priv/static")
  |> beacon.start_router(8080)
}
```

Configuration functions: `router_title`, `router_secret_key`, `router_middleware`, `router_static_dir`, `router_routes_dir` (defaults to `"src/routes"`), `router_security_limits`.

## Code Generation

On `start_router`, Beacon automatically:

1. Scans `src/routes/` for `.gleam` files
2. Generates `src/generated/routes.gleam` (Route type, `match_route`, `to_path`)
3. Generates `src/generated/route_dispatcher.gleam` (`start_for_route`, `ssr_for_route`)
4. Compiles and hot-loads the dispatcher

Run codegen manually with `gleam run -m beacon/router/codegen` or use `check` mode in CI.

## Navigation

Use standard `<a href="...">` links. The client JS intercepts same-origin navigation and the route manager swaps runtimes while preserving the WebSocket connection.
