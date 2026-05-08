import beacon
import beacon/html
import beacon/route
import gleam/int
import gleam/list

const server_settings_key = "route_settings_private_key_must_not_ship"

pub type Model {
  Model(email: String, saved: Int, last_saved: String)
}

pub type Server {
  Server(private_key: String, audit_entries: List(String))
}

pub type Msg {
  SetEmail(String)
  SaveSettings
}

pub fn init() -> Model {
  Model(email: "ada@example.test", saved: 0, last_saved: "Not saved yet")
}

pub fn init_server() -> Server {
  Server(private_key: server_settings_key, audit_entries: [])
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SetEmail(email) -> Model(..model, email: email)
    SaveSettings ->
      Model(
        ..model,
        saved: model.saved + 1,
        last_saved: "Saved " <> model.email,
      )
  }
}

pub fn update_server(model: Model, server: Server, msg: Msg) -> #(Model, Server) {
  let model = update(model, msg)
  case msg {
    SetEmail(_) -> #(model, server)
    SaveSettings -> #(
      model,
      Server(..server, audit_entries: [
        "save-" <> int.to_string(list.length(server.audit_entries) + 1),
        ..server.audit_entries
      ]),
    )
  }
}

pub fn page(
  on_enter: fn(route.Route) -> msg,
  select: fn(model) -> Model,
  wrap: fn(Msg) -> msg,
) -> route.Page(model, msg) {
  route.page_model("/settings", on_enter, select, fn(model, _route) {
    view(model, wrap)
  })
}

pub fn view(model: Model, wrap: fn(Msg) -> msg) -> beacon.Node(msg) {
  html.section([], [
    html.h1([], [html.text("Settings")]),
    html.p([], [
      html.text("The audit log and signing key are route-local server state."),
    ]),
    html.label([], [
      html.text("Email"),
      html.input([
        html.attribute("data-testid", "settings-email"),
        html.type_("email"),
        html.value(model.email),
        beacon.on_input(fn(value) { wrap(SetEmail(value)) }),
      ]),
    ]),
    html.button([beacon.on_click(wrap(SaveSettings))], [
      html.text("Save settings"),
    ]),
    html.p([html.attribute("data-testid", "settings-last-saved")], [
      html.text(model.last_saved),
    ]),
    html.p([html.attribute("data-testid", "settings-save-count")], [
      html.text("Saves: " <> int.to_string(model.saved)),
    ]),
  ])
}
