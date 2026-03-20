/// Privacy Demo — exercises all Milestone 83 features:
/// - server_ prefix constants (never leaked to client)
/// - Server type (private server-side state, excluded from client bundle)
/// - Computed fields (pub fn(Model) -> T, server-derived values in model_sync)

import beacon
import beacon/effect
import beacon/html
import gleam/int
import gleam/float
import gleam/list

// === Server-only constants — server_ prefix, never in client JS bundle ===

const server_api_key = "sk_live_secret_do_not_leak_this"

const server_db_url = "postgres://user:pass@localhost/db"

// === Client-safe constant — referenced by view, WILL be in bundle ===

const app_title = "Privacy Demo"

// === Unreferenced constant — will NOT be in bundle (not used by any extracted fn) ===

const unused_config = 42

// === Types ===

pub type Model {
  Model(
    items: List(Item),
    tax_rate: Float,
  )
}

pub type Item {
  Item(name: String, price: Int, qty: Int)
}

pub type Server {
  Server(
    api_key: String,
    db_url: String,
    request_count: Int,
  )
}

pub type Msg {
  AddItem
  ClearItems
}

// === Init ===

pub fn init() -> Model {
  Model(
    items: [
      Item(name: "Widget", price: 1000, qty: 2),
      Item(name: "Gadget", price: 2500, qty: 1),
    ],
    tax_rate: 0.08,
  )
}

pub fn init_server() -> Server {
  Server(
    api_key: server_api_key,
    db_url: server_db_url,
    request_count: 0,
  )
}

// === Computed fields — pub fn(Model) -> T, auto-detected by signature ===

pub fn subtotal(model: Model) -> Int {
  list.fold(model.items, 0, fn(sum, item) { sum + item.price * item.qty })
}

pub fn total(model: Model) -> Int {
  let sub = subtotal(model)
  sub + float.round(int.to_float(sub) *. model.tax_rate)
}

pub fn item_count(model: Model) -> Int {
  list.length(model.items)
}

// === Update ===

pub fn update(model: Model, server: Server, msg: Msg) -> #(Model, Server, effect.Effect(Msg)) {
  case msg {
    AddItem -> {
      let new_item = Item(name: "New Item", price: 500, qty: 1)
      let new_server = Server(..server, request_count: server.request_count + 1)
      #(Model(..model, items: [new_item, ..model.items]), new_server, effect.none())
    }
    ClearItems -> {
      #(Model(..model, items: []), server, effect.none())
    }
  }
}

// === View — can only access Model, NOT Server (compiler enforces this) ===

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([], [
    html.h1([], [html.text(app_title)]),
    html.p([], [html.text("Items: " <> int.to_string(list.length(model.items)))]),
    html.p([], [html.text("Tax rate: " <> float.to_string(model.tax_rate))]),
    html.button([beacon.on_click(AddItem)], [html.text("Add Item")]),
    html.button([beacon.on_click(ClearItems)], [html.text("Clear")]),
  ])
}

pub fn main() {
  beacon.app_with_server(init, init_server, update, view)
  |> beacon.title("Privacy Demo")
  |> beacon.start(8080)
}
