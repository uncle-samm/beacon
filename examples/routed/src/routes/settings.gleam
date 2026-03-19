/// Settings page route — /settings
/// Demonstrates: form with server state, text input handling.

import beacon
import beacon/html

pub type Model {
  Model(username: String, saved: Bool)
}

pub type Msg {
  SetUsername(String)
  Save
}

pub fn init() -> Model {
  Model(username: "gleam_user", saved: False)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SetUsername(name) -> Model(username: name, saved: False)
    Save -> Model(..model, saved: True)
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([], [
    html.h1([], [html.text("Settings")]),
    html.div([], [
      html.label([], [html.text("Username: ")]),
      html.input([
        html.attribute("type", "text"),
        html.attribute("value", model.username),
        beacon.on_input(SetUsername),
      ]),
    ]),
    html.button([beacon.on_click(Save)], [html.text("Save")]),
    case model.saved {
      True -> html.p([], [html.text("Saved: " <> model.username)])
      False -> html.p([], [html.text("Editing...")])
    },
    html.hr(),
    html.nav([], [
      html.a([html.href("/")], [html.text("Home")]),
      html.text(" | "),
      html.a([html.href("/about")], [html.text("About")]),
      html.text(" | "),
      html.a([html.href("/stats")], [html.text("Stats")]),
    ]),
  ])
}
