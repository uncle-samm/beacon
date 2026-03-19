/// Triple Counter — three counters in one app demonstrating all three state layers:
///
/// 1. SHARED counter — all users see the same count, synced via store+PubSub
/// 2. SERVER counter — per-user, server-rendered, each tab has its own
/// 3. LOCAL counter  — per-user, client-only, zero server traffic
///
/// Open multiple tabs to see the difference.

import beacon
import beacon/html
import beacon/store
import gleam/int

/// Server state — per-connection (each tab gets its own via per-connection runtime).
/// The shared_count is pulled from the shared store on every render.
pub type Model {
  Model(
    /// Per-user server counter (each tab independent)
    my_count: Int,
    /// Shared counter (read from store, same for everyone)
    shared_count: Int,
  )
}

/// Client state — instant, never touches the server.
pub type Local {
  Local(
    /// Per-user local counter (instant, zero traffic)
    local_count: Int,
  )
}

pub type Msg {
  // Shared — writes to store, all users see the update
  SharedIncrement
  SharedDecrement
  SharedUpdated
  // Server — per-user, server-rendered
  MyIncrement
  MyDecrement
  // Local — instant, zero server traffic
  LocalIncrement
  LocalDecrement
}

pub fn make_init(shared: store.Store(Int)) -> fn() -> Model {
  fn() {
    let shared_count = case store.get(shared, "count") {
      Ok(n) -> n
      Error(Nil) -> 0
    }
    Model(my_count: 0, shared_count: shared_count)
  }
}

pub fn init_local(_model: Model) -> Local {
  Local(local_count: 0)
}

pub fn make_update(
  shared: store.Store(Int),
) -> fn(Model, Local, Msg) -> #(Model, Local) {
  fn(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
    case msg {
      // === SHARED: write to store, broadcast to all ===
      SharedIncrement -> {
        let current = case store.get(shared, "count") {
          Ok(n) -> n
          Error(Nil) -> 0
        }
        store.put(shared, "count", current + 1)
        #(Model(..model, shared_count: current + 1), local)
      }
      SharedDecrement -> {
        let current = case store.get(shared, "count") {
          Ok(n) -> n
          Error(Nil) -> 0
        }
        store.put(shared, "count", int.max(0, current - 1))
        #(Model(..model, shared_count: int.max(0, current - 1)), local)
      }
      SharedUpdated -> {
        // Another user changed the shared count — refresh from store
        let current = case store.get(shared, "count") {
          Ok(n) -> n
          Error(Nil) -> 0
        }
        #(Model(..model, shared_count: current), local)
      }

      // === SERVER: per-user, each tab independent ===
      MyIncrement -> #(Model(..model, my_count: model.my_count + 1), local)
      MyDecrement -> #(Model(..model, my_count: model.my_count - 1), local)

      // === LOCAL: instant, zero server traffic ===
      LocalIncrement -> #(model, Local(local_count: local.local_count + 1))
      LocalDecrement -> #(model, Local(local_count: local.local_count - 1))
    }
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div([html.style("font-family:system-ui;max-width:600px;margin:2rem auto")], [
    html.h1([], [html.text("Triple Counter")]),
    html.p([html.style("color:#666")], [
      html.text("Open multiple tabs to see the difference!"),
    ]),
    // === SHARED COUNTER ===
    html.div(
      [html.style("background:#e8f5e9;padding:1rem;margin:1rem 0;border-radius:8px")],
      [
        html.h2([], [html.text("Shared Counter")]),
        html.p([html.style("color:#2e7d32")], [
          html.text("All tabs see the same number. Click in one tab → updates everywhere."),
        ]),
        html.div([html.style("font-size:2rem;text-align:center")], [
          html.button([beacon.on_click(SharedDecrement)], [html.text(" - ")]),
          html.strong([], [
            html.text(" " <> int.to_string(model.shared_count) <> " "),
          ]),
          html.button([beacon.on_click(SharedIncrement)], [html.text(" + ")]),
        ]),
      ],
    ),
    // === SERVER COUNTER ===
    html.div(
      [html.style("background:#e3f2fd;padding:1rem;margin:1rem 0;border-radius:8px")],
      [
        html.h2([], [html.text("Server Counter (per-tab)")]),
        html.p([html.style("color:#1565c0")], [
          html.text("Each tab has its own count. Server-rendered, per-connection."),
        ]),
        html.div([html.style("font-size:2rem;text-align:center")], [
          html.button([beacon.on_click(MyDecrement)], [html.text(" - ")]),
          html.strong([], [
            html.text(" " <> int.to_string(model.my_count) <> " "),
          ]),
          html.button([beacon.on_click(MyIncrement)], [html.text(" + ")]),
        ]),
      ],
    ),
    // === LOCAL COUNTER ===
    html.div(
      [html.style("background:#fce4ec;padding:1rem;margin:1rem 0;border-radius:8px")],
      [
        html.h2([], [html.text("Local Counter (instant)")]),
        html.p([html.style("color:#c62828")], [
          html.text("Instant updates. Zero server traffic. Per-tab, client-only."),
        ]),
        html.div([html.style("font-size:2rem;text-align:center")], [
          html.button([beacon.on_click(LocalDecrement)], [html.text(" - ")]),
          html.strong([], [
            html.text(" " <> int.to_string(local.local_count) <> " "),
          ]),
          html.button([beacon.on_click(LocalIncrement)], [html.text(" + ")]),
        ]),
      ],
    ),
  ])
}

pub fn main() {
  start()
}

pub fn start() {
  let shared = store.new("shared_counter")
  store.put(shared, "count", 0)

  beacon.app_with_local(make_init(shared), init_local, make_update(shared), view)
  |> beacon.title("Triple Counter")
  |> beacon.subscriptions(fn(_model) { ["store:shared_counter"] })
  |> beacon.on_notify(fn(_topic) { SharedUpdated })
  |> beacon.start(8080)
}
