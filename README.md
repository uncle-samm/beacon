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
import beacon/html
import gleam/int

pub type Model {
  Model(count: Int)
}

pub type Msg {
  Increment
}

pub fn init() -> Model {
  Model(count: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(count: model.count + 1)
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.button([beacon.on_click(Increment)], [
    html.text("Count: " <> int.to_string(model.count)),
  ])
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.start(8080)
}
```

## Recommended APIs

- Use `beacon.app(init, update, view)` for model-only apps.
- Use `beacon.app_with_local(init, init_local, update, view)` when you define
  per-tab `Local` state.
- Use `beacon.app_with_server(init, init_server, update, view)` when you need
  private server state that must not ship to the browser.
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
