/// Stats page route — /stats
/// Demonstrates: state isolation — each route has its own process.
/// Navigate away and come back: clicks reset to 0 (process was killed).

import beacon
import beacon/html
import gleam/int

pub type Model {
  Model(clicks: Int)
}

pub type Msg {
  Click
}

pub fn init() -> Model {
  Model(clicks: 0)
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Click -> Model(clicks: model.clicks + 1)
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([], [
    html.h1([], [html.text("Stats")]),
    html.p([], [
      html.text("Clicks this session: " <> int.to_string(model.clicks)),
    ]),
    html.p([], [
      html.text("Navigate away and come back — clicks reset to 0!"),
    ]),
    html.button([beacon.on_click(Click)], [html.text("Click me")]),
    html.hr(),
    html.nav([], [
      html.a([html.href("/")], [html.text("Home")]),
      html.text(" | "),
      html.a([html.href("/about")], [html.text("About")]),
      html.text(" | "),
      html.a([html.href("/settings")], [html.text("Settings")]),
    ]),
  ])
}
