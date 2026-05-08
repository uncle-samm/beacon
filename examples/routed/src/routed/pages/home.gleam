import beacon
import beacon/html
import beacon/route
import gleam/int

const server_audit_key = "home_route_private_audit_key_must_not_ship"

pub type Model {
  Model(count: Int, server_updates: Int)
}

pub type Server {
  Server(audit_key: String, writes: Int)
}

pub type Msg {
  Increment
  Decrement
}

pub fn init() -> Model {
  Model(count: 0, server_updates: 0)
}

pub fn init_server() -> Server {
  Server(audit_key: server_audit_key, writes: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Increment -> Model(..model, count: model.count + 1)
    Decrement -> Model(..model, count: model.count - 1)
  }
}

pub fn update_server(model: Model, server: Server, msg: Msg) -> #(Model, Server) {
  let updated = update(model, msg)
  case msg {
    Increment | Decrement -> #(
      Model(..updated, server_updates: updated.server_updates + 1),
      Server(..server, writes: server.writes + 1),
    )
  }
}

pub fn page(
  on_enter: fn(route.Route) -> msg,
  select: fn(model) -> Model,
  wrap: fn(Msg) -> msg,
) -> route.Page(model, msg) {
  route.page_model("/", on_enter, select, fn(model, _route) {
    view(model, wrap)
  })
}

pub fn view(model: Model, wrap: fn(Msg) -> msg) -> beacon.Node(msg) {
  html.section([], [
    html.h1([], [html.text("Routed")]),
    html.p([], [
      html.text("Home owns a route-local Model and Msg inside one Beacon app."),
    ]),
    html.div([html.style("display:flex;gap:8px;align-items:center;")], [
      html.button([beacon.on_click(wrap(Decrement))], [html.text("-")]),
      html.strong([html.attribute("data-testid", "count")], [
        html.text(int.to_string(model.count)),
      ]),
      html.button([beacon.on_click(wrap(Increment))], [html.text("+")]),
    ]),
    html.p([html.attribute("data-testid", "server-updates")], [
      html.text(
        "Server-authoritative updates: " <> int.to_string(model.server_updates),
      ),
    ]),
  ])
}
