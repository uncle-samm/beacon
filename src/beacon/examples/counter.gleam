/// Counter — the simplest Beacon app.
/// Demonstrates: app builder, html helpers, on_click, no decode_event.

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
  html.div([html.class("counter")], [
    html.h1([], [html.text("Beacon Counter")]),
    html.p([], [html.text("Count: " <> int.to_string(model.count))]),
    html.button([beacon.on_click(Decrement)], [html.text("-")]),
    html.button([beacon.on_click(Increment)], [html.text("+")]),
  ])
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.title("Beacon Counter")
  |> beacon.start(8080)
}
