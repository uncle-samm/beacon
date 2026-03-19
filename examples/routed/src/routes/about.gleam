/// About page route — /about
/// Demonstrates: static page with no server state.

import beacon
import beacon/html

pub type Model {
  Model
}

pub type Msg {
  NoOp
}

pub fn init() -> Model {
  Model
}

pub fn update(model: Model, _msg: Msg) -> Model {
  model
}

pub fn view(_model: Model) -> beacon.Node(Msg) {
  html.div([], [
    html.h1([], [html.text("About")]),
    html.p([], [html.text("This is a file-based routed Beacon app.")]),
    html.p([], [
      html.text("Each route is a separate .gleam file in src/routes/."),
    ]),
    html.hr(),
    html.nav([], [
      html.a([html.href("/")], [html.text("Home")]),
      html.text(" | "),
      html.a([html.href("/settings")], [html.text("Settings")]),
      html.text(" | "),
      html.a([html.href("/stats")], [html.text("Stats")]),
    ]),
  ])
}
