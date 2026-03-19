/// Home page route — /
/// Demonstrates: server-side counter with navigation links to all routes.

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
    html.h1([], [html.text("Home")]),
    html.p([], [html.text("Count: " <> int.to_string(model.count))]),
    html.button([beacon.on_click(Decrement)], [html.text("-")]),
    html.button([beacon.on_click(Increment)], [html.text("+")]),
    html.hr(),
    html.nav([], [
      html.a([html.href("/about")], [html.text("About")]),
      html.text(" | "),
      html.a([html.href("/settings")], [html.text("Settings")]),
      html.text(" | "),
      html.a([html.href("/stats")], [html.text("Stats")]),
    ]),
  ])
}
