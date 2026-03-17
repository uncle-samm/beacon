/// Beacon — the simple API for building full-stack Gleam web apps.
///
/// ```gleam
/// import beacon
/// import beacon/html
///
/// pub fn main() {
///   beacon.app(init, update, view)
///   |> beacon.title("My App")
///   |> beacon.start(8080)
/// }
/// ```

import beacon/application
import beacon/effect
import beacon/element.{type Attr}
import beacon/error
import beacon/handler

/// A node in the virtual DOM tree. Re-exported from `beacon/element`.
pub type Node(msg) =
  element.Node(msg)
import beacon/log
import beacon/middleware
import beacon/pubsub
import beacon/route
import beacon/runtime
import beacon/transport
import gleam/erlang/process
import gleam/dict
import gleam/list
import gleam/int
import gleam/option.{type Option, None, Some}

// ===== Event Helpers =====
// These register handlers in the per-render registry.
// No decode_event needed — the runtime resolves automatically.

/// Attach a click handler that sends the given message.
/// ```gleam
/// html.button([beacon.on_click(Increment)], [html.text("+")])
/// ```
pub fn on_click(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "click", handler_id: id)
}

/// Attach an input handler that extracts the value and passes it to your callback.
/// ```gleam
/// html.input([beacon.on_input(fn(text) { SetName(text) })])
/// ```
pub fn on_input(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "input", handler_id: id)
}

/// Attach a submit handler.
pub fn on_submit(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "submit", handler_id: id)
}

/// Attach a change handler with value extraction.
pub fn on_change(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "change", handler_id: id)
}

/// Attach a mousedown handler that receives x,y coordinates as "x,y".
pub fn on_mousedown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "mousedown", handler_id: id)
}

/// Attach a mouseup handler.
pub fn on_mouseup(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "mouseup", handler_id: id)
}

/// Attach a mousemove handler that receives x,y coordinates as "x,y".
pub fn on_mousemove(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "mousemove", handler_id: id)
}

/// Attach a keydown handler that receives the key name (e.g., "ArrowUp", "Enter", "a").
pub fn on_keydown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "keydown", handler_id: id)
}

/// Attach a dragstart handler. The callback receives the element's `data-drag-id` value.
/// Use with `html.attribute("draggable", "true")` and `html.attribute("data-drag-id", id)`.
pub fn on_dragstart(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "dragstart", handler_id: id)
}

/// Attach a dragover handler. Automatically calls preventDefault to allow drops.
pub fn on_dragover(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: "dragover", handler_id: id)
}

/// Attach a drop handler. The callback receives the dragged element's `data-drag-id`.
pub fn on_drop(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: "drop", handler_id: id)
}

/// Broadcast a PubSub notification to a topic.
/// All runtimes subscribed to this topic will receive their `on_pubsub` message.
pub fn broadcast(topic: String) -> Nil {
  pubsub.broadcast(topic, Nil)
}

// ===== App Builder =====

/// An app being configured. Use `app()` to create, then pipe through
/// configuration functions, then call `start()`.
pub opaque type AppBuilder(model, msg) {
  AppBuilder(
    init_simple: Option(fn() -> model),
    init_effect: Option(fn() -> #(model, effect.Effect(msg))),
    update_simple: Option(fn(model, msg) -> model),
    update_effect: Option(fn(model, msg) -> #(model, effect.Effect(msg))),
    view: fn(model) -> Node(msg),
    title: String,
    secret_key: String,
    middlewares: List(middleware.Middleware),
    static_dir: Option(String),
    serialize_model: Option(fn(model) -> String),
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// For app_with_local: wraps model+local into a combined model type.
    /// When set, the "model" in the builder is actually #(Model, Local).
    has_local: Bool,
    /// Route patterns for URL matching (e.g., ["/", "/blog/:slug"]).
    route_patterns: List(route.RoutePattern),
    /// Called when the URL changes — produces a Msg for the update loop.
    on_route_change: Option(fn(route.Route) -> msg),
    /// Registered server functions: name → handler(args) → Result(result, error).
    server_fns: dict.Dict(String, fn(String) -> Result(String, String)),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
  )
}

/// Create an app with simple init/update (no effects needed).
/// `init` returns just a Model. `update` returns just a Model.
/// ```gleam
/// beacon.app(init, update, view) |> beacon.start(8080)
/// ```
pub fn app(
  init: fn() -> model,
  update: fn(model, msg) -> model,
  view: fn(model) -> Node(msg),
) -> AppBuilder(model, msg) {
  AppBuilder(
    init_simple: Some(init),
    init_effect: None,
    update_simple: Some(update),
    update_effect: None,
    view: view,
    title: "Beacon",
    secret_key: generate_secret(),
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    serialize_model: None,
    deserialize_model: None,
    has_local: False,
    route_patterns: [],
    on_route_change: None,
    server_fns: dict.new(),
    dynamic_subscriptions: None,
    on_notify: None,
  )
}

/// Create an app with effect-returning init/update.
/// Use this when you need server functions, async work, or other effects.
pub fn app_with_effects(
  init: fn() -> #(model, effect.Effect(msg)),
  update: fn(model, msg) -> #(model, effect.Effect(msg)),
  view: fn(model) -> Node(msg),
) -> AppBuilder(model, msg) {
  AppBuilder(
    init_simple: None,
    init_effect: Some(init),
    update_simple: None,
    update_effect: Some(update),
    view: view,
    title: "Beacon",
    secret_key: generate_secret(),
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    serialize_model: None,
    deserialize_model: None,
    has_local: False,
    route_patterns: [],
    on_route_change: None,
    server_fns: dict.new(),
    dynamic_subscriptions: None,
    on_notify: None,
  )
}

/// Create an app with separate Model (server/shared) and Local (client/instant) state.
/// `init` returns the server Model. `init_local` derives initial Local from Model.
/// `update` takes both and returns both — framework auto-infers what needs the server.
///
/// ```gleam
/// beacon.app_with_local(init, init_local, update, view) |> beacon.start(8080)
/// ```
pub fn app_with_local(
  init: fn() -> model,
  init_local: fn(model) -> local,
  update: fn(model, local, msg) -> #(model, local),
  view: fn(model, local) -> Node(msg),
) -> AppBuilder(#(model, local), msg) {
  // Wrap into a combined model: #(model, local)
  let combined_init = fn() {
    let model = init()
    let local = init_local(model)
    #(model, local)
  }
  let combined_update = fn(combined: #(model, local), msg: msg) {
    let #(model, local) = combined
    let #(new_model, new_local) = update(model, local, msg)
    #(new_model, new_local)
  }
  let combined_view = fn(combined: #(model, local)) {
    let #(model, local) = combined
    view(model, local)
  }
  AppBuilder(
    init_simple: Some(combined_init),
    init_effect: None,
    update_simple: Some(combined_update),
    update_effect: None,
    view: combined_view,
    title: "Beacon",
    secret_key: generate_secret(),
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    serialize_model: None,
    deserialize_model: None,
    has_local: True,
    route_patterns: [],
    on_route_change: None,
    server_fns: dict.new(),
    dynamic_subscriptions: None,
    on_notify: None,
  )
}

/// Set the page title.
pub fn title(
  builder: AppBuilder(model, msg),
  t: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, title: t)
}

/// Set a model encoder for model_sync.
/// The encoder serializes the Model to JSON so the server can send
/// authoritative state to the client after model-affecting events.
/// For app_with_local, the encoder receives the full #(model, local)
/// but should only serialize the model part.
pub fn model_encoder(
  builder: AppBuilder(model, msg),
  encoder: fn(model) -> String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, serialize_model: option.Some(encoder))
}

/// Register URL route patterns for the app.
/// Patterns can include dynamic segments with `:param`.
/// ```gleam
/// beacon.app(init, update, view)
/// |> beacon.routes(["/", "/blog", "/blog/:slug"])
/// |> beacon.on_route_change(OnRouteChange)
/// |> beacon.start(8080)
/// ```
pub fn routes(
  builder: AppBuilder(model, msg),
  patterns: List(String),
) -> AppBuilder(model, msg) {
  AppBuilder(
    ..builder,
    route_patterns: list.map(patterns, route.pattern),
  )
}

/// Set the callback that produces a Msg when the URL route changes.
/// This is called on initial page load and on client-side navigation.
pub fn on_route_change(
  builder: AppBuilder(model, msg),
  handler: fn(route.Route) -> msg,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_route_change: Some(handler))
}

/// Create a redirect effect — navigates the client to a new URL.
/// Use this in update to redirect after login, logout, etc.
/// The effect sends a ServerNavigate message to ONLY the triggering client
/// (not broadcast to all connections).
pub fn redirect(path: String) -> effect.Effect(msg) {
  effect.from(fn(_dispatch) {
    // Send redirect to the specific connection that triggered this effect
    case runtime.get_redirect_target() {
      option.Some(subject) ->
        process.send(
          subject,
          transport.SendNavigate(path: path),
        )
      option.None -> Nil
    }
  })
}

/// Set dynamic subscriptions derived from the model.
/// Called after every update. The framework diffs the result against
/// the current subscription set and subscribes/unsubscribes as needed.
/// ```gleam
/// beacon.app(init, update, view)
/// |> beacon.subscriptions(fn(model) { ["room:" <> model.current_room] })
/// |> beacon.on_notify(fn(topic) { RoomUpdated(topic) })
/// |> beacon.start(8080)
/// ```
pub fn subscriptions(
  builder: AppBuilder(model, msg),
  compute: fn(model) -> List(String),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, dynamic_subscriptions: Some(compute))
}

/// Set the handler for notifications on dynamically subscribed topics.
/// Receives the topic string so you can distinguish between sources.
pub fn on_notify(
  builder: AppBuilder(model, msg),
  handler: fn(String) -> msg,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_notify: Some(handler))
}

/// Register a server function callable from the client.
/// Server functions execute on the server and return results via WebSocket.
/// ```gleam
/// beacon.app(init, update, view)
/// |> beacon.server_fn("get_posts", fn(args) {
///   Ok(json.to_string(encode_posts(db.get_posts())))
/// })
/// ```
pub fn server_fn(
  builder: AppBuilder(model, msg),
  name: String,
  handler: fn(String) -> Result(String, String),
) -> AppBuilder(model, msg) {
  AppBuilder(
    ..builder,
    server_fns: dict.insert(builder.server_fns, name, handler),
  )
}

/// Set the secret key for session tokens.
pub fn secret_key(
  builder: AppBuilder(model, msg),
  key: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, secret_key: key)
}

/// Add a middleware to the pipeline.
pub fn with_middleware(
  builder: AppBuilder(model, msg),
  mw: middleware.Middleware,
) -> AppBuilder(model, msg) {
  AppBuilder(
    ..builder,
    middlewares: list_append(builder.middlewares, [mw]),
  )
}

/// Enable static file serving from a directory.
pub fn static_dir(
  builder: AppBuilder(model, msg),
  dir: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, static_dir: Some(dir))
}


/// Enable state recovery on WebSocket reconnect.
pub fn with_state_recovery(
  builder: AppBuilder(model, msg),
  serialize: fn(model) -> String,
  deserialize: fn(String) -> Result(model, String),
) -> AppBuilder(model, msg) {
  AppBuilder(
    ..builder,
    serialize_model: Some(serialize),
    deserialize_model: Some(deserialize),
  )
}

/// Start the app on the given port. Blocks forever.
pub fn start(
  builder: AppBuilder(model, msg),
  port: Int,
) -> Result(Nil, error.BeaconError) {
  log.configure()
  // Wrap simple init/update into effect-returning versions
  let wrapped_init = case builder.init_effect {
    Some(init_fn) -> init_fn
    None ->
      case builder.init_simple {
        Some(init_fn) -> fn() { #(init_fn(), effect.none()) }
        None -> fn() { panic as "No init function provided" }
      }
  }
  let wrapped_update = case builder.update_effect {
    Some(update_fn) -> update_fn
    None ->
      case builder.update_simple {
        Some(update_fn) -> fn(model, msg) {
          #(update_fn(model, msg), effect.none())
        }
        None -> fn(_, _) { panic as "No update function provided" }
      }
  }
  let config =
    application.AppConfig(
      port: port,
      init: wrapped_init,
      update: wrapped_update,
      view: builder.view,
      decode_event: None,
      secret_key: builder.secret_key,
      title: builder.title,
      serialize_model: builder.serialize_model,
      deserialize_model: builder.deserialize_model,
      middlewares: builder.middlewares,
      static_dir: builder.static_dir,
      route_patterns: builder.route_patterns,
      on_route_change: builder.on_route_change,
      server_fns: builder.server_fns,
      dynamic_subscriptions: builder.dynamic_subscriptions,
      on_notify: builder.on_notify,
    )
  case application.start(config) {
    Ok(_app) -> {
      log.info("beacon", "Running at http://localhost:" <> int.to_string(port))
      application.wait_forever()
      Ok(Nil)
    }
    Error(err) -> Error(err)
  }
}

// === Internal ===

fn generate_secret() -> String {
  "beacon_" <> int.to_string(erlang_unique()) <> "_secret"
}

fn list_append(a: List(x), b: List(x)) -> List(x) {
  do_list_append(a, b)
}

@external(erlang, "lists", "append")
fn do_list_append(a: List(x), b: List(x)) -> List(x)

@external(erlang, "erlang", "unique_integer")
fn erlang_unique() -> Int
