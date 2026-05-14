import beacon
import beacon/html
import beacon/route

pub fn page(
  on_enter: fn(route.Route) -> msg,
  render: fn(model, route.Route) -> beacon.Node(msg),
) -> route.Page(model, msg) {
  route.page("/about", on_enter, render)
}

pub fn view() -> beacon.Node(msg) {
  html.section([], [
    html.h1([], [html.text("About")]),
    html.p([], [
      html.text(
        "This page is imported explicitly from routed/pages/about. Beacon does not scan the filesystem for routes.",
      ),
    ]),
  ])
}
