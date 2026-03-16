/// Counter with Local state — demonstrates Model + Local architecture.
/// - Model.count is server state (shared, synced)
/// - Local.input and Local.menu_open are client state (instant, per-tab)

import beacon
import beacon/html
import gleam/int

/// Server state — shared across users, synced via server.
pub type Model {
  Model(count: Int)
}

/// Client state — instant, per-tab, never touches the server.
pub type Local {
  Local(input: String, menu_open: Bool)
}

pub type Msg {
  Increment
  Decrement
  SetInput(String)
  ToggleMenu
}

pub fn init() -> Model {
  Model(count: 0)
}

pub fn init_local(_model: Model) -> Local {
  Local(input: "", menu_open: False)
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    // These change Model → will sync with server when client-side execution is enabled
    Increment -> #(Model(count: model.count + 1), local)
    Decrement -> #(Model(count: model.count - 1), local)
    // These only change Local → instant, zero server traffic
    SetInput(text) -> #(model, Local(..local, input: text))
    ToggleMenu -> #(model, Local(..local, menu_open: !local.menu_open))
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div([html.class("counter-local")], [
    html.h1([], [html.text("Counter with Local State")]),
    // Server state
    html.div([html.class("server-state")], [
      html.p([], [html.text("Count (server): " <> int.to_string(model.count))]),
      html.button([beacon.on_click(Decrement)], [html.text("-")]),
      html.button([beacon.on_click(Increment)], [html.text("+")]),
    ]),
    // Local state — these would be instant with client-side execution
    html.div([html.class("local-state")], [
      html.p([], [html.text("Input (local): " <> local.input)]),
      html.input([
        html.type_("text"),
        html.placeholder("Type here (local state)..."),
        html.value(local.input),
        beacon.on_input(SetInput),
      ]),
      html.button([beacon.on_click(ToggleMenu)], [html.text("Toggle Menu")]),
      case local.menu_open {
        True ->
          html.div([html.class("dropdown")], [
            html.p([], [html.text("Menu is open! (local state)")]),
          ])
        False -> html.span([], [])
      },
    ]),
  ])
}

pub fn main() {
  beacon.app_with_local(init, init_local, update, view)
  |> beacon.title("Counter with Local State")
  |> beacon.start(8080)
}
