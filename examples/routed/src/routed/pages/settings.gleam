import beacon
import beacon/html
import beacon/route

pub fn page(
  on_enter: fn(route.Route) -> msg,
  render: fn(model, route.Route) -> beacon.Node(msg),
) -> route.Page(model, msg) {
  route.page("/settings", on_enter, render)
}

pub fn view(name: String, on_input: fn(String) -> msg) -> beacon.Node(msg) {
  html.section([], [
    html.h1([], [html.text("Settings")]),
    html.label([], [
      html.text("Display name"),
      html.input([
        html.type_("text"),
        html.value(name),
        beacon.on_input(on_input),
        html.attribute("data-testid", "name-input"),
      ]),
    ]),
    html.p([html.attribute("data-testid", "saved-name")], [
      html.text("Name: " <> name),
    ]),
  ])
}
