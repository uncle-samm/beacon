import beacon
import beacon/html
import beacon/route
import gleam/int

pub fn page(
  on_enter: fn(route.Route) -> msg,
  render: fn(model, route.Route) -> beacon.Node(msg),
) -> route.Page(model, msg) {
  route.page("/stats", on_enter, render)
}

pub fn view(visits: Int) -> beacon.Node(msg) {
  html.section([], [
    html.h1([], [html.text("Stats")]),
    html.p([html.attribute("data-testid", "visits")], [
      html.text("Route changes observed: " <> int.to_string(visits)),
    ]),
  ])
}
