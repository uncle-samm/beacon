import beacon
import beacon/effect
import beacon/html
import beacon/route
import gleam/int
import route_server_workspace/pages/accounts
import route_server_workspace/pages/settings

pub type Model {
  Model(
    path: String,
    accounts: accounts.Model,
    settings: settings.Model,
    visits: Int,
  )
}

pub type Server {
  Server(accounts: accounts.Server, settings: settings.Server)
}

pub type Msg {
  RouteChanged(String)
  Accounts(accounts.Msg)
  Settings(settings.Msg)
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      path: "/",
      accounts: accounts.init(),
      settings: settings.init(),
      visits: 0,
    ),
    effect.none(),
  )
}

pub fn init_server() -> Server {
  Server(accounts: accounts.init_server(), settings: settings.init_server())
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

    Accounts(child_msg) -> {
      let #(model, server) =
        route.update_server_model(
          model,
          server,
          child_msg,
          fn(model: Model) { model.accounts },
          fn(model: Model, accounts: accounts.Model) {
            Model(..model, accounts: accounts)
          },
          fn(server: Server) { server.accounts },
          fn(server: Server, accounts_server: accounts.Server) {
            Server(..server, accounts: accounts_server)
          },
          accounts.update_server,
        )
      #(model, Nil, server)
    }

    Settings(child_msg) -> {
      let #(model, server) =
        route.update_server_model(
          model,
          server,
          child_msg,
          fn(model: Model) { model.settings },
          fn(model: Model, settings: settings.Model) {
            Model(..model, settings: settings)
          },
          fn(server: Server) { server.settings },
          fn(server: Server, settings_server: settings.Server) {
            Server(..server, settings: settings_server)
          },
          settings.update_server,
        )
      #(model, Nil, server)
    }
  }
}

pub fn view(model: Model, _local: Nil) -> beacon.Node(Msg) {
  // Invariant: route_pages validates paths before `RouteChanged` is dispatched.
  let assert Ok(page) = route.dispatch_view(pages(), model, model.path)
  html.main(
    [
      html.style(
        "font-family:system-ui;max-width:820px;margin:32px auto;padding:0 16px;",
      ),
    ],
    [
      html.nav([html.style("display:flex;gap:12px;margin-bottom:24px;")], [
        html.a([html.href("/")], [html.text("Accounts")]),
        html.a([html.href("/settings")], [html.text("Settings")]),
      ]),
      html.p([html.attribute("data-testid", "route-visits")], [
        html.text("Route visits: " <> int_to_string(model.visits)),
      ]),
      page,
    ],
  )
}

fn pages() -> List(route.Page(Model, Msg)) {
  [
    accounts.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(model: Model) { model.accounts },
      Accounts,
    ),
    settings.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(model: Model) { model.settings },
      Settings,
    ),
  ]
}

fn server_pages() -> List(route.Page(#(Model, Nil, Server), Msg)) {
  [
    accounts.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Nil, Server)) {
        let #(model, _local, _server) = state
        model.accounts
      },
      Accounts,
    ),
    settings.page(
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Nil, Server)) {
        let #(model, _local, _server) = state
        model.settings
      },
      Settings,
    ),
  ]
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}

pub fn main() {
  beacon.app(init, beacon.no_local, init_server, update, view)
  |> beacon.title("Route Server Workspace")
  |> beacon.route_pages(server_pages())
  |> beacon.start(8080)
}
