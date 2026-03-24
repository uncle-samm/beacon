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
import beacon/build
import beacon/effect
import beacon/element.{type Attr}
import beacon/error
import beacon/handler
import beacon/router/codegen as router_codegen
import beacon/router/manager as route_manager
import beacon/router/scanner as router_scanner
import beacon/static
import beacon/transport/server.{type Connection, type ResponseBody}

/// A node in the virtual DOM tree. Re-exported from `beacon/element`.
pub type Node(msg) =
  element.Node(msg)
import beacon/log
import beacon/middleware
import beacon/pubsub
import beacon/route
import beacon/runtime
import beacon/ssr
import beacon/transport
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

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

// ===== Cookie Helpers =====
// Convenience re-exports from beacon/cookie for common use in ws_auth and api_routes.

import beacon/cookie

/// Get a cookie value from a request by name.
/// Shorthand for `beacon/cookie.get(req, name)`.
pub fn get_cookie(
  req: request.Request(body),
  name: String,
) -> Result(String, Nil) {
  cookie.get(req, name)
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
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
    /// Server-side effect handler — runs AFTER update on the server.
    /// Used to separate pure update logic (compiles to JS) from side effects (server only).
    on_update_effect: Option(fn(model, msg) -> effect.Effect(msg)),
    /// Configurable security limits for the transport layer.
    security_limits: transport.SecurityLimits,
    /// Optional: extra HTML to inject into `<head>` (stylesheets, meta tags, etc.).
    head_html: Option(String),
    /// Optional: API route handler — runs BEFORE SSR/static file routing.
    /// If it returns Some(response), that response is sent immediately.
    /// If it returns None, the request falls through to SSR/static serving.
    api_handler: Option(
      fn(request.Request(Connection)) ->
        Option(response.Response(ResponseBody)),
    ),
    /// Optional: WebSocket authentication function.
    /// Runs before WS upgrade — Ok allows, Error(reason) rejects with 401.
    ws_auth: Option(fn(request.Request(Connection)) -> Result(Nil, String)),
    /// Optional: request-aware server state initializer.
    /// Replaces init_server with a function that receives the HTTP request,
    /// so it can read cookies, headers, etc. to populate server state.
    ws_init: Option(
      fn(request.Request(Connection)) -> model,
    ),
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
    dynamic_subscriptions: None,
    on_notify: None,
    on_update_effect: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: None,
    ws_auth: None,
    ws_init: None,
  )
}

/// Create an app with effect-returning init/update.
/// Use this when you need effects, async work, or other side effects.
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
    dynamic_subscriptions: None,
    on_notify: None,
    on_update_effect: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: None,
    ws_auth: None,
    ws_init: None,
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
    dynamic_subscriptions: None,
    on_notify: None,
    on_update_effect: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: None,
    ws_auth: None,
    ws_init: None,
  )
}

/// Create an app with private server-side state.
/// `init` returns the shared Model. `init_server` returns server-only state.
/// `update` receives both Model and Server, returns both plus effects.
/// `view` receives only Model — Server is never accessible in the view.
///
/// Server state is NEVER serialized, NEVER sent to client, NEVER in the JS bundle.
/// Gleam's type system enforces this at compile time.
///
/// ```gleam
/// beacon.app_with_server(init, init_server, update, view) |> beacon.start(8080)
/// ```
pub fn app_with_server(
  init: fn() -> model,
  init_server: fn() -> server,
  update: fn(model, server, msg) -> #(model, server, effect.Effect(msg)),
  view: fn(model) -> Node(msg),
) -> AppBuilder(#(model, server), msg) {
  // Wrap into a combined model: #(model, server)
  // The runtime sees #(model, server) as a single "model" but only the
  // model part is serialized/sent to client (via model_encoder wrapping).
  let combined_init = fn() {
    let model = init()
    let server = init_server()
    #(model, server)
  }
  let combined_update = fn(combined: #(model, server), msg: msg) {
    let #(model, server) = combined
    let #(new_model, new_server, effects) = update(model, server, msg)
    #(#(new_model, new_server), effects)
  }
  let combined_view = fn(combined: #(model, server)) {
    let #(model, _server) = combined
    view(model)
  }
  AppBuilder(
    init_simple: None,
    init_effect: Some(fn() { #(combined_init(), effect.none()) }),
    update_simple: None,
    update_effect: Some(combined_update),
    view: combined_view,
    title: "Beacon",
    secret_key: generate_secret(),
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    serialize_model: None,
    deserialize_model: None,
    has_local: False,
    route_patterns: [],
    on_route_change: None,
    dynamic_subscriptions: None,
    on_notify: None,
    on_update_effect: None,
    security_limits: transport.default_security_limits(),
    head_html: None,
    api_handler: None,
    ws_auth: None,
    ws_init: None,
  )
}

/// Set the page title.
pub fn title(
  builder: AppBuilder(model, msg),
  t: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, title: t)
}

/// Inject custom HTML into the `<head>` of the SSR page.
/// Use this for stylesheets, meta tags, fonts, or other head content.
///
/// ```gleam
/// beacon.app(init, update, view)
/// |> beacon.head_html("<link rel=\"stylesheet\" href=\"/static/styles.css\">")
/// |> beacon.start(8080)
/// ```
pub fn head_html(
  builder: AppBuilder(model, msg),
  html: String,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, head_html: Some(html))
}

/// Register an API route handler.
/// The handler runs BEFORE SSR/static file routing on every HTTP request.
/// Return `Some(response)` to handle the request, `None` to fall through.
///
/// Use `beacon/transport/http.read_body(req, max_bytes)` to read POST bodies.
///
/// ```gleam
/// import gleam/http
/// import gleam/http/request
/// import gleam/http/response
/// import gleam/option.{None, Some}
/// import beacon/transport/server.{type Connection, type ResponseBody, Bytes}
///
/// beacon.app(init, update, view)
/// |> beacon.api_routes(fn(req) {
///   case req.method, request.path_segments(req) {
///     http.Post, ["api", "login"] -> Some(handle_login(req))
///     http.Get, ["api", "status"] -> Some(json_ok())
///     _, _ -> None
///   }
/// })
/// |> beacon.start(8080)
/// ```
pub fn api_routes(
  builder: AppBuilder(model, msg),
  handler: fn(request.Request(Connection)) ->
    Option(response.Response(ResponseBody)),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, api_handler: Some(handler))
}

/// Set WebSocket authentication.
/// Runs before the WebSocket upgrade handshake — can read cookies, headers, etc.
/// Return `Ok(Nil)` to allow the connection, `Error(reason)` to reject with 401.
///
/// ```gleam
/// beacon.app(init, update, view)
/// |> beacon.ws_auth(fn(req) {
///   case beacon.get_cookie(req, "session_token") {
///     Ok(token) -> validate_session(token)
///     Error(Nil) -> Error("No session cookie")
///   }
/// })
/// |> beacon.start(8080)
/// ```
pub fn ws_auth(
  builder: AppBuilder(model, msg),
  auth_fn: fn(request.Request(Connection)) -> Result(Nil, String),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, ws_auth: Some(auth_fn))
}

/// Set a request-aware server state initializer.
/// Replaces both `init` and `init_server` with a function that receives the HTTP request
/// from the WebSocket upgrade, so it can read cookies, headers, query params, etc.
///
/// Use with `app_with_server` to populate server state from session cookies:
///
/// ```gleam
/// beacon.app_with_server(init, init_server, update, view)
/// |> beacon.ws_init(fn(req) {
///   case beacon.get_cookie(req, "session_token") {
///     Ok(token) -> #(Model, ServerState(user_id: validate(token), ..))
///     Error(Nil) -> #(Model, ServerState(user_id: None, ..))
///   }
/// })
/// |> beacon.start(8080)
/// ```
///
/// When set, `ws_init` replaces the default init entirely.
pub fn ws_init(
  builder: AppBuilder(model, msg),
  init_fn: fn(request.Request(Connection)) -> model,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, ws_init: Some(init_fn))
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

/// Create a redirect effect — navigates the client to a new URL via pushState.
/// Use this in update to redirect after login, logout, etc.
/// The effect sends a ServerNavigate message to ONLY the triggering client
/// (not broadcast to all connections).
/// Must be called within an effect context (inside update).
/// SECURITY: Only use with validated paths. Never pass raw user input.
pub fn redirect(path: String) -> effect.Effect(msg) {
  effect.from(fn(_dispatch) {
    case runtime.get_redirect_target() {
      option.Some(subject) ->
        process.send(
          subject,
          transport.SendNavigate(path: path),
        )
      option.None -> {
        log.debug(
          "beacon",
          "No redirect target available (effect ran outside connection context)",
        )
        Nil
      }
    }
  })
}

/// Create a hard redirect effect — navigates via window.location.href (full page reload).
/// Unlike `redirect` (which uses pushState), this triggers a real HTTP request.
/// Use when the browser needs to receive HTTP headers (e.g., Set-Cookie after login).
/// SECURITY: Only relative paths (starting with /) are allowed by the client.
///
/// ```gleam
/// fn update(model, server, msg) {
///   case msg {
///     LoginSuccess(token) ->
///       #(model, server, beacon.hard_redirect("/api/auth/session/" <> token))
///     _ -> #(model, server, effect.none())
///   }
/// }
/// ```
pub fn hard_redirect(path: String) -> effect.Effect(msg) {
  effect.from(fn(_dispatch) {
    case runtime.get_redirect_target() {
      option.Some(subject) ->
        process.send(
          subject,
          transport.SendHardNavigate(path: path),
        )
      option.None -> {
        log.debug(
          "beacon",
          "No hard_redirect target available (effect ran outside connection context)",
        )
        Nil
      }
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

/// Register a server-side effect handler.
/// Runs AFTER update on the server — use for stores, PubSub, BEAM operations.
/// This keeps update() pure (compilable to JS for LOCAL events).
/// ```gleam
/// beacon.app_with_local(init, init_local, update, view)
/// |> beacon.on_update(fn(model, msg) {
///   case msg {
///     AddCard -> effect.from(fn(_) { store.put(store, "v", ...) })
///     _ -> effect.none()
///   }
/// })
/// |> beacon.start(8080)
/// ```
pub fn on_update(
  builder: AppBuilder(model, msg),
  handler: fn(model, msg) -> effect.Effect(msg),
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, on_update_effect: Some(handler))
}

/// Override security limits for the app.
/// Use `transport.default_security_limits()` as a starting point and modify fields.
///
/// Example:
/// ```gleam
/// beacon.app(init, update, view)
/// |> beacon.security_limits(transport.SecurityLimits(
///   ..transport.default_security_limits(),
///   max_connections: 5000,
///   max_events_per_second: 100,
/// ))
/// |> beacon.start(8080)
/// ```
pub fn security_limits(
  builder: AppBuilder(model, msg),
  limits: transport.SecurityLimits,
) -> AppBuilder(model, msg) {
  AppBuilder(..builder, security_limits: limits)
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
  // Validate required functions before doing any work.
  // Both init and update must be provided (either simple or effect variant).
  let wrapped_init = case builder.init_effect {
    Some(init_fn) -> Ok(init_fn)
    None ->
      case builder.init_simple {
        Some(init_fn) -> Ok(fn() { #(init_fn(), effect.none()) })
        None -> Error(error.ConfigError(reason: "No init function provided — use beacon.app() or beacon.app_with_effects()"))
      }
  }
  let base_update = case builder.update_effect {
    Some(update_fn) -> Ok(update_fn)
    None ->
      case builder.update_simple {
        Some(update_fn) -> Ok(fn(model, msg) {
          #(update_fn(model, msg), effect.none())
        })
        None -> Error(error.ConfigError(reason: "No update function provided — use beacon.app() or beacon.app_with_effects()"))
      }
  }
  // Return early if validation failed
  case wrapped_init, base_update {
    Error(err), _ -> {
      log.error("beacon", "Configuration error: " <> error.to_string(err))
      Error(err)
    }
    _, Error(err) -> {
      log.error("beacon", "Configuration error: " <> error.to_string(err))
      Error(err)
    }
    Ok(init_fn), Ok(update_fn) -> start_validated(builder, port, init_fn, update_fn)
  }
}

/// Internal: start the app after validation passes.
fn start_validated(
  builder: AppBuilder(model, msg),
  port: Int,
  wrapped_init: fn() -> #(model, effect.Effect(msg)),
  base_update: fn(model, msg) -> #(model, effect.Effect(msg)),
) -> Result(Nil, error.BeaconError) {
  // Auto-build client JS if not already built
  auto_build_client_js()
  // If on_update_effect is set, chain it after the base update
  let wrapped_update = case builder.on_update_effect {
    None -> base_update
    Some(on_update_fn) -> fn(model, msg) {
      let #(new_model, base_effect) = base_update(model, msg)
      let extra_effect = on_update_fn(new_model, msg)
      #(new_model, effect.batch([base_effect, extra_effect]))
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
      dynamic_subscriptions: builder.dynamic_subscriptions,
      on_notify: builder.on_notify,
      security_limits: builder.security_limits,
      head_html: builder.head_html,
      api_handler: builder.api_handler,
      ws_auth: builder.ws_auth,
      init_from_request: case builder.ws_init {
        Some(ws_init_fn) ->
          Some(fn(req) { #(ws_init_fn(req), effect.none()) })
        None -> None
      },
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

// ===== Router Builder (File-Based Routing) =====

/// A router being configured. Use `router()` to create, then pipe through
/// configuration functions, then call `start_router()`.
///
/// Unlike AppBuilder, there is no init/update/view — those come from route files.
/// ```gleam
/// beacon.router()
/// |> beacon.router_title("My App")
/// |> beacon.start_router(8080)
/// ```
pub opaque type RouterBuilder {
  RouterBuilder(
    title: String,
    secret_key: String,
    middlewares: List(middleware.Middleware),
    static_dir: Option(String),
    routes_dir: String,
    security_limits: transport.SecurityLimits,
  )
}

/// Create a new router builder for file-based routing.
/// Route files are loaded from `src/routes/` by default.
pub fn router() -> RouterBuilder {
  RouterBuilder(
    title: "Beacon",
    secret_key: generate_secret(),
    middlewares: [middleware.secure_headers()],
    static_dir: None,
    routes_dir: "src/routes",
    security_limits: transport.default_security_limits(),
  )
}

/// Set the page title for the router.
pub fn router_title(
  builder: RouterBuilder,
  t: String,
) -> RouterBuilder {
  RouterBuilder(..builder, title: t)
}

/// Set the secret key for the router.
pub fn router_secret_key(
  builder: RouterBuilder,
  key: String,
) -> RouterBuilder {
  RouterBuilder(..builder, secret_key: key)
}

/// Add a middleware to the router pipeline.
pub fn router_middleware(
  builder: RouterBuilder,
  mw: middleware.Middleware,
) -> RouterBuilder {
  RouterBuilder(
    ..builder,
    middlewares: list_append(builder.middlewares, [mw]),
  )
}

/// Enable static file serving for the router.
pub fn router_static_dir(
  builder: RouterBuilder,
  dir: String,
) -> RouterBuilder {
  RouterBuilder(..builder, static_dir: Some(dir))
}

/// Set the routes directory (defaults to "src/routes").
pub fn router_routes_dir(
  builder: RouterBuilder,
  dir: String,
) -> RouterBuilder {
  RouterBuilder(..builder, routes_dir: dir)
}

/// Override security limits for the router.
/// Use `transport.default_security_limits()` as a starting point and modify fields.
pub fn router_security_limits(
  builder: RouterBuilder,
  limits: transport.SecurityLimits,
) -> RouterBuilder {
  RouterBuilder(..builder, security_limits: limits)
}

/// Start the file-based router on the given port. Blocks forever.
///
/// This:
/// 1. Auto-runs route scanner + codegen (generates dispatcher)
/// 2. Loads the generated route_dispatcher module
/// 3. Creates a transport with a route manager per connection
/// 4. Starts the server
pub fn start_router(
  builder: RouterBuilder,
  port: Int,
) -> Result(Nil, error.BeaconError) {
  log.configure()
  log.info("beacon", "Starting file-based router on port " <> int.to_string(port))

  // Step 1: Auto-run route scanner + codegen
  auto_generate_routes(builder.routes_dir)

  // Step 2: Purge any stale beacon_codec module.
  // Routed apps have different Model/Msg per route — a global codec would be wrong.
  // The runtime will use mount (HTML) instead of model_sync (JSON).
  purge_stale_codec()

  // Step 3: Build base client JS if not already built.
  // For routed apps, we build ONLY the base runtime (WS, morphing, event delegation)
  // WITHOUT app-specific codecs, since each route has different Model/Msg types.
  auto_build_base_client_js()

  // Step 3: Start PubSub
  pubsub.start()

  // Step 4: Create the dispatcher function via Erlang FFI
  let dispatcher = fn(
    conn_id: transport.ConnectionId,
    transport_subject: process.Subject(transport.InternalMessage),
    path: String,
  ) {
    call_start_for_route(conn_id, transport_subject, path)
  }

  // Step 5: Create SSR factory
  let ssr_factory = fn(path: String) -> String {
    case call_ssr_for_route(path, builder.title, builder.secret_key) {
      Ok(page) -> page.html
      Error(err) -> {
        log.error(
          "beacon",
          "SSR render failed for path " <> path <> ": " <> error.to_string(err),
        )
        "<!DOCTYPE html><html><body><h1>500 Internal Server Error</h1><p>SSR render failed: "
          <> error.to_string(err)
          <> "</p></body></html>"
      }
    }
  }

  // Step 6: Create transport config with route manager factory
  let static_cfg = case builder.static_dir {
    Some(dir) ->
      Some(static.StaticConfig(
        directory: dir,
        prefix: "/static",
        max_age: 3600,
      ))
    None -> None
  }

  let transport_config =
    transport.TransportConfig(
      port: port,
      page_html: None,
      middlewares: builder.middlewares,
      static_config: static_cfg,
      runtime_factory: Some(fn(
        conn_id: transport.ConnectionId,
        transport_subject: process.Subject(transport.InternalMessage),
        _req: request.Request(Connection),
      ) {
        route_manager.start(conn_id, transport_subject, dispatcher)
      }),
      on_connect: fn(_, _) { Nil },
      on_event: fn(_, _) { Nil },
      on_disconnect: fn(_) { Nil },
      ws_auth: None,
      ssr_factory: Some(ssr_factory),
      security_limits: builder.security_limits,
      api_handler: None,
    )

  case transport.start(transport_config) {
    Ok(_pid) -> {
      log.info(
        "beacon",
        "Router running at http://localhost:" <> int.to_string(port),
      )
      application.wait_forever()
      Ok(Nil)
    }
    Error(err) -> Error(err)
  }
}

/// Auto-generate routes from src/routes/ directory.
fn auto_generate_routes(routes_dir: String) -> Nil {
  log.info("beacon", "Auto-generating routes from " <> routes_dir)
  case simplifile.is_directory(routes_dir) {
    Ok(True) -> {
      case simplifile.create_directory_all("src/generated") {
        Ok(Nil) -> Nil
        Error(err) -> {
          log.error(
            "beacon",
            "Failed to create src/generated: " <> string.inspect(err),
          )
          Nil
        }
      }
      case router_scanner.scan_routes(routes_dir) {
        Ok(routes) -> {
          case router_codegen.generate(routes, "src/generated/routes.gleam") {
            Ok(Nil) -> Nil
            Error(err) -> {
              log.error(
                "beacon",
                "Routes generation failed: " <> error.to_string(err),
              )
              Nil
            }
          }
          case router_codegen.generate_dispatcher(routes, "src/generated/route_dispatcher.gleam") {
            Ok(Nil) -> {
              // Compile the generated files
              let _ = build.run_gleam_build()
              hot_reload_dispatcher()
              log.info("beacon", "Route dispatcher generated and loaded")
              Nil
            }
            Error(err) -> {
              log.error(
                "beacon",
                "Dispatcher generation failed: " <> error.to_string(err),
              )
              Nil
            }
          }
        }
        Error(err) -> {
          log.error(
            "beacon",
            "Route scanning failed: " <> error.to_string(err),
          )
          Nil
        }
      }
    }
    _ -> {
      log.warning(
        "beacon",
        "No routes directory found at " <> routes_dir
          <> " — no routes to generate",
      )
    }
  }
}

// === Internal ===

fn generate_secret() -> String {
  let secret = do_generate_strong_secret()
  log.warning(
    "beacon",
    "Using auto-generated secret_key — tokens will be invalid after restart. Set explicit secret_key() for production.",
  )
  secret
}

@external(erlang, "beacon_application_ffi", "generate_strong_secret")
fn do_generate_strong_secret() -> String

fn list_append(a: List(x), b: List(x)) -> List(x) {
  do_list_append(a, b)
}

@external(erlang, "lists", "append")
fn do_list_append(a: List(x), b: List(x)) -> List(x)

/// Hot-reload the beacon_codec module after auto-build generates it.
@external(erlang, "beacon_auto_build_ffi", "hot_reload_codec")
fn hot_reload_codec() -> Nil

/// Build client JS if not already built or if source changed.
///
/// Two modes based on app structure:
/// 1. Apps with Model/Msg/update/view in one file → builds codec + runtime (local events work)
/// 2. Apps with split files or app_with_server → builds runtime only (server-rendered)
///
/// Both modes produce the same runtime (WS, morphing, events, navigation).
/// The only difference is whether client-side model encoding is available.
fn auto_build_client_js() -> Nil {
  case client_js_is_fresh() {
    True -> {
      log.info("beacon", "Client JS up to date")
      Nil
    }
    False -> {
      log.info("beacon", "Building client JS...")
      // Try codec build first (single-file apps with Model/Msg)
      build.auto_build()
      case simplifile.is_file("priv/static/beacon_client.manifest") {
        Ok(True) -> {
          let _ = build.run_gleam_build()
          hot_reload_codec()
          Nil
        }
        _ -> {
          // No scannable app module (multi-file, app_with_server, etc.)
          log.info(
            "beacon",
            "No single-file Model/Msg found — building runtime-only client JS",
          )
          build.build_base_client()
          Nil
        }
      }
    }
  }
}

/// Check if the client JS bundle is fresh (manifest exists and is newer than source).
fn client_js_is_fresh() -> Bool {
  case simplifile.is_file("priv/static/beacon_client.manifest") {
    Ok(True) -> {
      // Manifest exists — check if beacon source has been updated since last build.
      // Compare manifest mtime against beacon_client_ffi.mjs mtime.
      case is_source_newer_than_manifest() {
        True -> {
          log.info("beacon", "Client JS source changed — rebuilding")
          False
        }
        False -> True
      }
    }
    _ -> False
  }
}

/// Check if the beacon client FFI source is newer than the manifest.
/// Uses Erlang file:read_file_info to compare modification times.
@external(erlang, "beacon_build_ffi", "is_source_newer_than_manifest")
fn is_source_newer_than_manifest() -> Bool

/// Build the base client JS for routed apps.
/// Unlike auto_build_client_js, this builds ONLY the base runtime
/// (WebSocket, morphing, event delegation) WITHOUT app-specific codecs.
/// Each route has different Model/Msg types, so a global codec would be wrong.
fn auto_build_base_client_js() -> Nil {
  case client_js_is_fresh() {
    True -> {
      log.info("beacon", "Client JS already built")
      Nil
    }
    False -> {
      log.info("beacon", "Building base client JS for router...")
      build.build_base_client()
      Nil
    }
  }
}

/// Dynamically call the generated route dispatcher's start_for_route.
@external(erlang, "beacon_router_ffi", "call_start_for_route")
fn call_start_for_route(
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
  path: String,
) -> Result(
  #(
    fn(transport.ConnectionId, transport.ClientMessage) -> Nil,
    fn() -> Nil,
  ),
  error.BeaconError,
)

/// Dynamically call the generated route dispatcher's ssr_for_route.
@external(erlang, "beacon_router_ffi", "call_ssr_for_route")
fn call_ssr_for_route(
  path: String,
  title: String,
  secret_key: String,
) -> Result(ssr.RenderedPage, error.BeaconError)

/// Hot-reload the generated route dispatcher module.
@external(erlang, "beacon_router_ffi", "hot_reload_dispatcher")
fn hot_reload_dispatcher() -> Nil

/// Purge any stale beacon_codec module from the BEAM.
/// For routed apps, a global codec is wrong (each route has different types).
@external(erlang, "beacon_router_ffi", "purge_stale_codec")
fn purge_stale_codec() -> Nil
