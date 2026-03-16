/// Beacon client-side runtime — runs update+view in the browser.
/// Compiled from Gleam to JavaScript.
///
/// Flow:
/// 1. Boot: init() → Model, init_local(Model) → Local
/// 2. Connect WebSocket, receive mount (authoritative Model)
/// 3. On event: run update locally → instant DOM update
/// 4. If Model changed: send to server, await model_sync
/// 5. If only Local changed: done, no server traffic

import beacon_client/handler
import gleam/int

/// Client state.
pub type ClientState(model, local, msg) {
  ClientState(
    model: model,
    local: local,
    update: fn(model, local, msg) -> #(model, local),
    view: fn(model, local) -> String,
    handler_registry: handler.HandlerRegistry(msg),
    model_version: Int,
    event_clock: Int,
    msg_affects_model: fn(msg) -> Bool,
  )
}

/// Initialize the client runtime.
pub fn init(
  model: model,
  local: local,
  update: fn(model, local, msg) -> #(model, local),
  view: fn(model, local) -> String,
  msg_affects_model: fn(msg) -> Bool,
) -> ClientState(model, local, msg) {
  // Initial render
  handler.start_render()
  let html = view(model, local)
  let registry = handler.finish_render()

  // Mount to DOM
  morph_app_root(html)
  let _ = attach_events()

  // Connect WebSocket
  let ws_url = get_ws_url()
  connect_ws(ws_url)

  ClientState(
    model: model,
    local: local,
    update: update,
    view: view,
    handler_registry: registry,
    model_version: 0,
    event_clock: 0,
    msg_affects_model: msg_affects_model,
  )
}

/// Handle an event from the DOM.
pub fn handle_event(
  state: ClientState(model, local, msg),
  handler_id: String,
  event_data: String,
) -> ClientState(model, local, msg) {
  case handler.resolve(state.handler_registry, handler_id, event_data) {
    Ok(msg) -> {
      // Run update locally — instant
      let #(new_model, new_local) = state.update(state.model, state.local, msg)

      // Re-render
      handler.start_render()
      let html = state.view(new_model, new_local)
      let new_registry = handler.finish_render()
      morph_app_root(html)
      let _ = attach_events()

      // Check if Model changed — if so, sync with server
      let new_clock = state.event_clock + 1
      case state.msg_affects_model(msg) {
        True -> {
          // Send to server for authoritative processing
          send_model_update(handler_id, event_data, new_clock)
          log("Event " <> handler_id <> " → server (model changed)")
        }
        False -> {
          log("Event " <> handler_id <> " → local only")
        }
      }

      ClientState(
        ..state,
        model: new_model,
        local: new_local,
        handler_registry: new_registry,
        event_clock: new_clock,
      )
    }
    Error(reason) -> {
      log("Handler error: " <> reason)
      state
    }
  }
}

/// Handle authoritative Model from server.
pub fn handle_model_sync(
  state: ClientState(model, local, msg),
  new_model: model,
  version: Int,
) -> ClientState(model, local, msg) {
  // Take server's Model, keep our Local
  handler.start_render()
  let html = state.view(new_model, state.local)
  let new_registry = handler.finish_render()
  morph_app_root(html)
  let _ = attach_events()

  log("Model sync v" <> int.to_string(version))

  ClientState(
    ..state,
    model: new_model,
    handler_registry: new_registry,
    model_version: version,
  )
}

// === FFI calls ===

@external(javascript, "./beacon_client_ffi.mjs", "morph_html")
fn morph_app_root_ffi(container: a, html: String) -> Nil

fn morph_app_root(html: String) -> Nil {
  case query_selector("#beacon-app") {
    Ok(el) -> morph_app_root_ffi(el, html)
    Error(_) -> Nil
  }
}

@external(javascript, "./beacon_client_ffi.mjs", "query_selector")
fn query_selector(selector: String) -> Result(a, Nil)

@external(javascript, "./beacon_client_ffi.mjs", "ws_send")
fn ws_send(data: String) -> Nil

@external(javascript, "./beacon_client_ffi.mjs", "ws_connect")
fn connect_ws(url: String) -> Nil

@external(javascript, "./beacon_client_ffi.mjs", "log")
fn log(msg: String) -> Nil

fn attach_events() -> Nil {
  // Event delegation handled by the FFI layer
  // The JS FFI attaches click/input listeners on #beacon-app
  Nil
}

fn get_ws_url() -> String {
  // In browser: ws://host/ws or wss://host/ws
  "ws://localhost:8080/ws"
}

fn send_model_update(handler_id: String, data: String, clock: Int) -> Nil {
  let msg =
    "{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\""
    <> handler_id
    <> "\",\"data\":"
    <> data
    <> ",\"target_path\":\"0\",\"clock\":"
    <> int.to_string(clock)
    <> "}"
  ws_send(msg)
}
