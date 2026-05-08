import beacon
import beacon/html
import beacon/route
import gleam/int

const server_accounts_key = "route_accounts_private_key_must_not_ship"

pub type Model {
  Model(balance: Int, approved: Int, denied: Int, last_event: String)
}

pub type Server {
  Server(private_key: String, approval_signatures: Int, denial_signatures: Int)
}

pub type Msg {
  ApproveTransfer
  DenyTransfer
}

pub fn init() -> Model {
  Model(
    balance: 1200,
    approved: 0,
    denied: 0,
    last_event: "Awaiting account review",
  )
}

pub fn init_server() -> Server {
  Server(
    private_key: server_accounts_key,
    approval_signatures: 0,
    denial_signatures: 0,
  )
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    ApproveTransfer ->
      Model(
        ..model,
        balance: model.balance - 25,
        approved: model.approved + 1,
        last_event: "Transfer approved",
      )
    DenyTransfer ->
      Model(..model, denied: model.denied + 1, last_event: "Transfer denied")
  }
}

pub fn update_server(model: Model, server: Server, msg: Msg) -> #(Model, Server) {
  let model = update(model, msg)
  case msg {
    ApproveTransfer -> #(
      model,
      Server(..server, approval_signatures: server.approval_signatures + 1),
    )
    DenyTransfer -> #(
      model,
      Server(..server, denial_signatures: server.denial_signatures + 1),
    )
  }
}

pub fn page(
  on_enter: fn(route.Route) -> msg,
  select: fn(model) -> Model,
  wrap: fn(Msg) -> msg,
) -> route.Page(model, msg) {
  route.page_model("/", on_enter, select, fn(model, _route) {
    view(model, wrap)
  })
}

pub fn view(model: Model, wrap: fn(Msg) -> msg) -> beacon.Node(msg) {
  html.section([], [
    html.h1([], [html.text("Accounts")]),
    html.p([], [
      html.text("This route owns public model state and private server state."),
    ]),
    html.p([html.attribute("data-testid", "account-balance")], [
      html.text("Balance: " <> int.to_string(model.balance)),
    ]),
    html.p([html.attribute("data-testid", "account-approved")], [
      html.text("Approved: " <> int.to_string(model.approved)),
    ]),
    html.p([html.attribute("data-testid", "account-denied")], [
      html.text("Denied: " <> int.to_string(model.denied)),
    ]),
    html.p([html.attribute("data-testid", "account-last-event")], [
      html.text(model.last_event),
    ]),
    html.div([html.style("display:flex;gap:8px;")], [
      html.button([beacon.on_click(wrap(ApproveTransfer))], [
        html.text("Approve transfer"),
      ]),
      html.button([beacon.on_click(wrap(DenyTransfer))], [
        html.text("Deny transfer"),
      ]),
    ]),
  ])
}
