import beacon
import beacon/effect
import beacon/html
import beacon/route
import routed/pages/about
import routed/pages/home
import routed/pages/settings
import routed/pages/stats

pub type Model {
  Model(path: String, home: home.Model, name: String, visits: Int)
}

pub type Server {
  Server(home: home.Server)
}

pub type Msg {
  RouteChanged(String)
  Home(home.Msg)
  SetName(String)
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(Model(path: "/", home: home.init(), name: "", visits: 0), effect.none())
}

pub fn init_server() -> Server {
  Server(home: home.init_server())
}

pub fn update(
  model: Model,
  _local: Nil,
  server: Server,
  msg: Msg,
) -> #(Model, Nil, Server) {
  case msg {
    RouteChanged(path) -> #(
      Model(..model, path: path, visits: model.visits + 1),
      Nil,
      server,
    )
    Home(child_msg) -> {
      let #(model, server) =
        route.update_server_model(
          model,
          server,
          child_msg,
          fn(model: Model) { model.home },
          fn(model: Model, home: home.Model) { Model(..model, home: home) },
          fn(server: Server) { server.home },
          fn(_server: Server, home_server: home.Server) {
            Server(home: home_server)
          },
          home.update_server,
        )
      #(model, Nil, server)
    }
    SetName(name) -> #(Model(..model, name: name), Nil, server)
  }
}

pub fn update_client(model: Model, msg: Msg) -> Model {
  case msg {
    RouteChanged(path) -> Model(..model, path: path, visits: model.visits + 1)
    Home(child_msg) ->
      route.update_model(
        model,
        child_msg,
        fn(model: Model) { model.home },
        fn(model: Model, home: home.Model) { Model(..model, home: home) },
        home.update,
      )
    SetName(name) -> Model(..model, name: name)
  }
}

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
  // Invariant: `model.path` is initialized to "/" and later updated only from
  // `route_pages()` entries through RouteChanged.
  let assert Ok(page) = route.dispatch_view(pages(), model, model.path)
  html.main(
    [
      html.style(
        "font-family:system-ui;max-width:780px;margin:32px auto;padding:0 16px;",
      ),
    ],
    [
      html.nav([html.style("display:flex;gap:12px;margin-bottom:24px;")], [
        html.a([html.href("/")], [html.text("Home")]),
        html.a([html.href("/about")], [html.text("About")]),
        html.a([html.href("/settings")], [html.text("Settings")]),
        html.a([html.href("/stats")], [html.text("Stats")]),
      ]),
      page,
    ],
  )
}

fn pages() -> List(route.Page(Model, Msg)) {
  [
    home.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(model: Model) { model.home },
      Home,
    ),
    about.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(_model: Model, _route) { about.view() },
    ),
    settings.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(model: Model, _route) { settings.view(model.name, SetName) },
    ),
    stats.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(model: Model, _route) { stats.view(model.visits) },
    ),
  ]
}

fn server_pages() -> List(route.Page(#(Model, Nil, Server), Msg)) {
  [
    home.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Nil, Server)) {
        let #(model, _local, _server) = state
        model.home
      },
      Home,
    ),
    about.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Nil, Server), _route) {
        let #(_model, _local, _server) = state
        about.view()
      },
    ),
    settings.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Nil, Server), _route) {
        let #(model, _local, _server) = state
        settings.view(model.name, SetName)
      },
    ),
    stats.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Nil, Server), _route) {
        let #(model, _local, _server) = state
        stats.view(model.visits)
      },
    ),
  ]
}

pub fn main() {
  beacon.app(init, beacon.no_local, init_server, update, view)
  |> beacon.title("Beacon Routed")
  |> beacon.route_pages(server_pages())
  |> beacon.start(8080)
}
