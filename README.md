# Beacon

Beacon is an alpha full-stack Gleam framework for building MVU web apps on the
BEAM.

The intended model is:

- SSR renders the first page.
- The browser hydrates a generated client bundle.
- Server-authoritative `Model` changes sync as JSON state updates.
- Optional `Local` state handles per-tab interactions such as dropdowns and
  form drafts without server round trips.
- Optional private `Server` state stays on the BEAM and is never passed to the
  client view.

## Quick Start

```sh
gleam build
gleam test
gleam run
```

Minimal app:

```gleam
import beacon
import beacon/effect
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(Model(count: 0), effect.none())
}

pub fn update(model: Model, _local: Nil, _server: Nil, msg: Msg) -> #(Model, Nil, Nil) {
  case msg {
    Increment -> #(Model(count: model.count + 1), Nil, Nil)
  }
}

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
  html.button([beacon.on_click(Increment)], [
    html.text("Count: " <> int.to_string(model.count)),
  ])
}

pub fn main() {
  beacon.app(init, beacon.no_local, beacon.no_server, update, view)
  |> beacon.start(8080)
}
```

## Recommended APIs

- Use one constructor: `beacon.app(init, init_local, init_server, update, view)`.
- Use `beacon.no_local` when the app has no per-tab `Local` state.
- Use `beacon.no_server` when the app has no private `Server` state.
- Use `beacon.route_pages([...])` for routed apps.
- Use `beacon/api.routes`, `api.json_value`, `api.read_text`, and
  `api.read_form` for API routes.
- Use `beacon/auth.session_routes`, `auth.protect_ws`, and
  `auth.init_from_session` for the standard session-cookie auth path.

## Project Docs

- [Getting Started](docs/GETTING_STARTED.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Routing](docs/ROUTING.md)
- [Security](docs/SECURITY.md)
- [Testing](docs/TESTING.md)
- [Current Progress](docs/PROGRESS.md)

## Development

```sh
gleam build
gleam test
gleam run -m beacon/lint
```

All three must pass before a change is considered done.
