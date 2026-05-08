# Explicit Routing

Beacon no longer supports filesystem route discovery. Route files are ordinary
Gleam modules that you import yourself, and every app starts through the same
`beacon.app(...) |> beacon.start(...)` path.

## Route-Aware Apps

Use `beacon.route_pages` to declare accepted URL patterns, the message sent when
each page is entered, and the typed page render function.

```gleam
import beacon
import beacon/html
import beacon/route

pub type Model {
  Model(path: String, project_id: String)
}

pub type Msg {
  RouteChanged(route.Route)
}

pub fn init() -> Model {
  Model(path: "/", project_id: "")
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    RouteChanged(r) -> {
      let project_id = case route.param(r, "id") {
        Ok(id) -> id
        Error(Nil) -> ""
      }
      Model(..model, path: r.path, project_id: project_id)
    }
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  let assert Ok(page) = route.dispatch_view(pages(), model, model.path)
  page
}

fn pages() -> List(route.Page(Model, Msg)) {
  [
    route.page("/", RouteChanged, fn(_model, _route) { html.text("Home") }),
    route.page("/settings", RouteChanged, fn(_model, _route) {
      html.text("Settings")
    }),
    route.page("/projects/:id", RouteChanged, fn(model, _route) {
      html.text("Project " <> model.project_id)
    }),
  ]
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.route_pages(pages())
  |> beacon.start(8080)
}
```

The first request is still rendered on the server for SSR. After hydration,
route changes and UI events use the same generated client renderer and
server-authoritative state sync/patch protocol as every other Beacon app.

## Organizing Route Code

You can split pages into modules for clarity, but the imports are explicit.
Each module can expose a `page` constructor and normal view helpers. Keep the
root app's public `Model` and `Msg` in the app module. Beacon does not discover
route files, generate a separate dispatcher module, or start a separate router
runtime.

```gleam
import beacon/route
import pages/dashboard
import pages/settings

pub fn view(model: Model) -> beacon.Node(Msg) {
  let assert Ok(page) = route.dispatch_view(pages(), model, model.path)
  page
}

fn pages() -> List(route.Page(Model, Msg)) {
  [
    dashboard.page(RouteChanged, fn(model, _route) {
      dashboard.view(model.count, Decrement, Increment)
    }),
    settings.page(RouteChanged, fn(model, _route) {
      settings.view(model.name, SetName)
    }),
  ]
}

beacon.app(init, update, view)
|> beacon.route_pages(pages())
|> beacon.start(8080)
```

## Route Mini-Apps

For larger pages, put the page's own `Model`, `Msg`, `update`, and `view` in the
route module. The root app embeds that model and wraps route messages into the
root `Msg`; there is still one Beacon app and one rendering path.

```gleam
// pages/counter.gleam
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

pub fn page(
  on_enter: fn(route.Route) -> parent_msg,
  select: fn(root_model) -> Model,
  wrap: fn(Msg) -> parent_msg,
) -> route.Page(root_model, parent_msg) {
  route.page_model("/", on_enter, select, fn(model, _route) {
    html.button([beacon.on_click(wrap(Increment))], [
      html.text(int.to_string(model.count)),
    ])
  })
}
```

```gleam
// main.gleam
pub type Model {
  Model(path: String, counter: counter.Model)
}

pub type Msg {
  RouteChanged(String)
  Counter(counter.Msg)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    RouteChanged(path) -> Model(..model, path: path)
    Counter(child_msg) ->
      route.update_model(
        model,
        child_msg,
        fn(model) { model.counter },
        fn(model, counter) { Model(..model, counter: counter) },
        counter.update,
      )
  }
}

fn pages() -> List(route.Page(Model, Msg)) {
  [
    counter.page(
      fn(r) { RouteChanged(r.path) },
      fn(model) { model.counter },
      Counter,
    ),
  ]
}
```

For `app_with_local`, use the same pattern with `route.Page(#(Model, Local), Msg)`
and select the route-local value from the tuple.

For `app_with_server`, the root app embeds route server state in its own
`Server` and uses `route.update_server_model` to update the child model and
child server value together. The route module may define `pub type Server`,
`init_server`, and `update_server`, but the generated client bundle strips those
declarations and any `server_` constants before JS compilation. Route render
functions receive only the model value that your app's `view` receives, so pages
cannot accidentally render `Server`.

## Why

Beacon has one rendering model: SSR for first paint, then client rendering from
Beacon state. Removing filesystem route discovery keeps routing predictable,
makes imports visible to Gleam and the build analyzer, and avoids a second app
startup path with different behavior.
