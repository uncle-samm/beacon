/// Beacon's WebSocket transport layer.
/// Manages WebSocket connections using Mist, with one BEAM process per connection.
/// Follows LiveView's connection lifecycle: connect → init → handle messages → close.
///
/// Reference: Mist v5.0.4 WebSocket API, LiveView channel protocol.

import beacon/error
import beacon/log
import beacon/middleware
import beacon/pubsub
import beacon/static
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import mist
import simplifile

/// Unique identifier for a WebSocket connection.
/// Used for logging and session tracking.
pub type ConnectionId =
  String

/// Messages sent from the client (browser) to the server.
/// This is Beacon's wire protocol — not Lustre's internal format.
pub type ClientMessage {
  /// A DOM event was fired (click, input, submit, etc).
  ClientEvent(
    /// The event name (e.g. "click", "input").
    name: String,
    /// The handler identifier from the data-beacon-event-* attribute value.
    /// This is the semantic identifier set by the view (e.g. "increment", "decrement").
    handler_id: String,
    /// JSON-encoded event data.
    data: String,
    /// Path to the element in the VDOM tree that fired the event.
    target_path: String,
    /// Monotonic event clock value for ordering and acknowledgment.
    /// Reference: LiveView 1.1 event clocking.
    clock: Int,
  )
  /// Client sends a heartbeat to keep the connection alive.
  ClientHeartbeat
  /// Client is requesting initial state after connecting.
  /// Includes an optional session token for state recovery.
  ClientJoin(token: String)
  /// Client navigated to a new URL path (SPA navigation).
  ClientNavigate(path: String)
  /// Client calls a server function by name.
  ClientServerFn(name: String, args: String, call_id: String)
}

/// Messages sent from the server to the client (browser).
pub type ServerMessage {
  /// Initial mount: full rendered content sent on first connect.
  ServerMount(payload: String)
  /// Incremental update: only the changed parts (patches).
  /// Includes the clock value of the event that triggered this update,
  /// so the client can acknowledge and unlock DOM regions.
  ServerPatch(payload: String, clock: Int)
  /// Server acknowledges a heartbeat.
  ServerHeartbeatAck
  /// Server-initiated error message.
  ServerError(reason: String)
  /// Authoritative Model state from server.
  /// Client takes this as ground truth, keeps its Local state.
  ServerModelSync(model_json: String, version: Int, ack_clock: Int)
  /// Server function result.
  ServerFnResult(call_id: String, result: String, ok: Bool)
  /// Server-initiated navigation (redirect).
  ServerNavigate(path: String)
  /// Dev mode: tell browser to reload.
  ServerReload
}

/// Internal messages that the connection actor can receive.
/// These come either from the WebSocket (client) or from
/// other BEAM processes (e.g. the runtime pushing patches).
pub type InternalMessage {
  /// A patch needs to be sent to the client.
  /// Includes the event clock value for client acknowledgment.
  SendPatch(payload: String, clock: Int)
  /// A mount payload needs to be sent to the client.
  SendMount(payload: String)
  /// An error needs to be sent to the client.
  SendError(reason: String)
  /// Send authoritative Model state to the client.
  SendModelSync(model_json: String, version: Int, ack_clock: Int)
  /// Send server function result to the client.
  SendServerFnResult(call_id: String, result: String, ok: Bool)
  /// Send navigation redirect to the client.
  SendNavigate(path: String)
}

/// State held by each WebSocket connection actor.
pub type ConnectionState {
  ConnectionState(
    /// Unique ID for this connection, used in logging.
    id: ConnectionId,
    /// The WebSocket connection handle for sending frames.
    connection: mist.WebsocketConnection,
    /// Callback invoked when a client event is received (per-connection).
    on_event: fn(ConnectionId, ClientMessage) -> Nil,
    /// Callback invoked when this connection closes (per-connection).
    on_close: fn(ConnectionId) -> Nil,
  )
}

/// Configuration for the transport layer.
pub type TransportConfig {
  TransportConfig(
    /// Port to listen on.
    port: Int,
    /// Callback invoked when a new WebSocket connection is established.
    on_connect: fn(ConnectionId, process.Subject(InternalMessage)) -> Nil,
    /// Callback invoked when a client sends an event.
    on_event: fn(ConnectionId, ClientMessage) -> Nil,
    /// Callback invoked when a WebSocket connection closes.
    on_disconnect: fn(ConnectionId) -> Nil,
    /// Optional: pre-rendered HTML page for SSR.
    /// If provided, HTTP requests get this instead of the default page.
    page_html: Option(String),
    /// Optional: middleware pipeline applied to all HTTP requests.
    /// Middleware runs before routing (SSR, static files, WebSocket upgrade).
    middlewares: List(middleware.Middleware),
    /// Optional: static file serving configuration.
    static_config: Option(static.StaticConfig),
    /// Optional: factory that creates a per-connection runtime.
    /// If set, each WebSocket connection gets its OWN runtime (like LiveView).
    /// The factory returns callbacks for this specific connection's runtime.
    /// If None, uses the shared on_connect/on_event/on_disconnect callbacks.
    runtime_factory: Option(
      fn(ConnectionId, process.Subject(InternalMessage)) ->
        #(
          fn(ConnectionId, ClientMessage) -> Nil,
          fn(ConnectionId) -> Nil,
        ),
    ),
    /// Optional: WebSocket authentication function.
    /// If set, runs before upgrade — returns Ok to allow, Error to reject with 401.
    ws_auth: Option(fn(Request(mist.Connection)) -> Result(Nil, String)),
  )
}

/// Generate a unique connection ID.
/// Uses a combination of the current monotonic time and a unique integer.
fn generate_connection_id() -> ConnectionId {
  let time = erlang_monotonic_time()
  let unique = erlang_unique_integer()
  "conn_" <> int.to_string(time) <> "_" <> int.to_string(unique)
}

@external(erlang, "erlang", "monotonic_time")
fn erlang_monotonic_time() -> Int

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

/// Encode a ServerMessage to JSON string for sending over the wire.
pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    ServerMount(payload) ->
      json.object([
        #("type", json.string("mount")),
        #("payload", json.string(payload)),
      ])
      |> json.to_string
    ServerPatch(payload, clock) ->
      json.object([
        #("type", json.string("patch")),
        #("payload", json.string(payload)),
        #("clock", json.int(clock)),
      ])
      |> json.to_string
    ServerHeartbeatAck ->
      json.object([#("type", json.string("heartbeat_ack"))])
      |> json.to_string
    ServerError(reason) ->
      json.object([
        #("type", json.string("error")),
        #("reason", json.string(reason)),
      ])
      |> json.to_string
    ServerModelSync(model_json, version, ack_clock) ->
      json.object([
        #("type", json.string("model_sync")),
        #("model", json.string(model_json)),
        #("version", json.int(version)),
        #("ack_clock", json.int(ack_clock)),
      ])
      |> json.to_string
    ServerFnResult(call_id, result, ok) ->
      json.object([
        #("type", json.string("server_fn_result")),
        #("call_id", json.string(call_id)),
        #("result", json.string(result)),
        #("ok", json.bool(ok)),
      ])
      |> json.to_string
    ServerNavigate(path) ->
      json.object([
        #("type", json.string("navigate")),
        #("path", json.string(path)),
      ])
      |> json.to_string
    ServerReload ->
      json.object([#("type", json.string("reload"))])
      |> json.to_string
  }
}

/// Build a decoder for ClientMessage JSON.
/// Uses the "type" field to determine which variant to decode.
/// Follows Lustre's transport.server_message_decoder() pattern.
fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use msg_type <- decode.field("type", decode.string)
  case msg_type {
    "event" -> {
      use name <- decode.field("name", decode.string)
      use handler_id <- decode.optional_field("handler_id", "", decode.string)
      use data <- decode.field("data", decode.string)
      use target_path <- decode.field("target_path", decode.string)
      use clock <- decode.optional_field("clock", 0, decode.int)
      decode.success(ClientEvent(
        name: name,
        handler_id: handler_id,
        data: data,
        target_path: target_path,
        clock: clock,
      ))
    }
    "heartbeat" -> decode.success(ClientHeartbeat)
    "join" -> {
      use token <- decode.optional_field("token", "", decode.string)
      decode.success(ClientJoin(token: token))
    }
    "navigate" -> {
      use path <- decode.field("path", decode.string)
      decode.success(ClientNavigate(path: path))
    }
    "server_fn" -> {
      use name <- decode.field("name", decode.string)
      use args <- decode.optional_field("args", "{}", decode.string)
      use call_id <- decode.field("call_id", decode.string)
      decode.success(ClientServerFn(name: name, args: args, call_id: call_id))
    }
    _unknown -> decode.failure(ClientHeartbeat, "ClientMessage type")
  }
}

/// Decode a JSON string from the client into a ClientMessage.
pub fn decode_client_message(
  raw: String,
) -> Result(ClientMessage, error.BeaconError) {
  case json.parse(raw, client_message_decoder()) {
    Ok(msg) -> {
      log.debug("beacon.transport", "Decoded client message")
      Ok(msg)
    }
    Error(_json_err) -> {
      log.warning("beacon.transport", "Failed to decode client message")
      Error(error.CodecError(
        reason: "Failed to decode client message",
        raw: raw,
      ))
    }
  }
}

/// Send a ServerMessage over a WebSocket connection.
/// Logs errors but does not crash — the connection may have closed.
fn send_message(
  conn: mist.WebsocketConnection,
  conn_id: ConnectionId,
  msg: ServerMessage,
) -> Nil {
  let encoded = encode_server_message(msg)
  case mist.send_text_frame(conn, encoded) {
    Ok(Nil) -> {
      log.debug("beacon.transport", "Sent message to " <> conn_id)
      Nil
    }
    Error(_reason) -> {
      log.error(
        "beacon.transport",
        "Failed to send message to "
          <> conn_id
          <> ": send_text_frame failed",
      )
      Nil
    }
  }
}

/// Handle an incoming WebSocket text frame.
/// Decodes the message and dispatches to the appropriate handler.
fn handle_text_message(
  state: ConnectionState,
  text: String,
) -> mist.Next(ConnectionState, InternalMessage) {
  case decode_client_message(text) {
    Ok(ClientHeartbeat) -> {
      log.debug("beacon.transport", "Heartbeat from " <> state.id)
      send_message(state.connection, state.id, ServerHeartbeatAck)
      mist.continue(state)
    }
    Ok(msg) -> {
      log.debug(
        "beacon.transport",
        "Event from " <> state.id <> ": " <> string.inspect(msg),
      )
      state.on_event(state.id, msg)
      mist.continue(state)
    }
    Error(err) -> {
      let err_str = error.to_string(err)
      log.warning(
        "beacon.transport",
        "Decode error from " <> state.id <> ": " <> err_str,
      )
      send_message(
        state.connection,
        state.id,
        ServerError(reason: "Invalid message: " <> err_str),
      )
      mist.continue(state)
    }
  }
}

/// Create the HTTP handler that upgrades WebSocket connections
/// and serves a basic HTML page for non-WebSocket requests.
/// Applies middleware pipeline to all HTTP requests.
/// Checks static file serving before app routes.
pub fn create_handler(
  config: TransportConfig,
) -> fn(Request(mist.Connection)) -> response.Response(mist.ResponseData) {
  // The core handler (before middleware)
  let core_handler = fn(req: Request(mist.Connection)) {
    case request.path_segments(req) {
      ["ws"] -> handle_websocket(req, config)
      ["beacon.js"] | ["beacon_client.js"] -> serve_client_js()
      ["health"] -> {
        response.new(200)
        |> response.set_header("content-type", "application/json")
        |> response.set_body(
          mist.Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")),
        )
      }
      _ -> {
        // Try static files first
        case config.static_config {
          Some(static_cfg) -> {
            let if_none_match =
              case request.get_header(req, "if-none-match") {
                Ok(val) -> val
                Error(Nil) -> ""
              }
            case
              static.serve_with_etag_check(
                static_cfg,
                req.path,
                if_none_match,
              )
            {
              Ok(resp) -> resp
              Error(Nil) -> serve_page(config.page_html)
            }
          }
          None -> serve_page(config.page_html)
        }
      }
    }
  }
  // Wrap with middleware pipeline
  case config.middlewares {
    [] -> core_handler
    mws -> middleware.pipeline(mws, core_handler)
  }
}

/// Handle a WebSocket upgrade request.
fn handle_websocket(
  req: Request(mist.Connection),
  config: TransportConfig,
) -> response.Response(mist.ResponseData) {
  // Check WebSocket auth if configured
  let auth_ok = case config.ws_auth {
    Some(auth_fn) -> auth_fn(req)
    None -> Ok(Nil)
  }
  case auth_ok {
    Error(reason) -> {
      log.warning("beacon.transport", "WS auth rejected: " <> reason)
      response.new(401)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Unauthorized: " <> reason)),
      )
    }
    Ok(Nil) -> handle_websocket_upgrade(req, config)
  }
}

fn handle_websocket_upgrade(
  req: Request(mist.Connection),
  config: TransportConfig,
) -> response.Response(mist.ResponseData) {
  let on_event = config.on_event
  let on_connect = config.on_connect
  let on_disconnect = config.on_disconnect

  mist.websocket(
    request: req,
    handler: fn(state: ConnectionState, msg, _conn) {
      case msg {
        mist.Text(text) -> handle_text_message(state, text)
        mist.Binary(_data) -> {
          log.warning(
            "beacon.transport",
            "Unexpected binary frame from " <> state.id,
          )
          mist.continue(state)
        }
        mist.Closed -> {
          log.info("beacon.transport", "Connection closed: " <> state.id)
          mist.stop()
        }
        mist.Shutdown -> {
          log.info("beacon.transport", "Connection shutdown: " <> state.id)
          mist.stop()
        }
        mist.Custom(internal_msg) -> {
          case internal_msg {
            SendPatch(payload, clock) -> {
              send_message(
                state.connection,
                state.id,
                ServerPatch(payload: payload, clock: clock),
              )
              mist.continue(state)
            }
            SendMount(payload) -> {
              send_message(
                state.connection,
                state.id,
                ServerMount(payload: payload),
              )
              mist.continue(state)
            }
            SendError(reason) -> {
              send_message(
                state.connection,
                state.id,
                ServerError(reason: reason),
              )
              mist.continue(state)
            }
            SendModelSync(model_json, version, ack_clock) -> {
              send_message(
                state.connection,
                state.id,
                ServerModelSync(
                  model_json: model_json,
                  version: version,
                  ack_clock: ack_clock,
                ),
              )
              mist.continue(state)
            }
            SendServerFnResult(call_id, result, ok) -> {
              send_message(
                state.connection,
                state.id,
                ServerFnResult(
                  call_id: call_id,
                  result: result,
                  ok: ok,
                ),
              )
              mist.continue(state)
            }
            SendNavigate(path) -> {
              send_message(
                state.connection,
                state.id,
                ServerNavigate(path: path),
              )
              mist.continue(state)
            }
          }
        }
      }
    },
    on_init: fn(conn) {
      let conn_id = generate_connection_id()
      log.info("beacon.transport", "New connection: " <> conn_id)
      let subject = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(subject)
      // Use runtime_factory if available (per-connection runtimes)
      // Otherwise fall back to shared callbacks
      let #(conn_on_event, conn_on_close) =
        case config.runtime_factory {
          Some(factory) -> {
            // Factory creates a new runtime for this connection
            // Returns per-connection event and disconnect handlers
            let #(evt_handler, close_handler) = factory(conn_id, subject)
            #(evt_handler, close_handler)
          }
          None -> {
            // Shared runtime — use the global callbacks
            on_connect(conn_id, subject)
            #(on_event, on_disconnect)
          }
        }
      let state =
        ConnectionState(
          id: conn_id,
          connection: conn,
          on_event: conn_on_event,
          on_close: conn_on_close,
        )
      pubsub.subscribe("beacon:patches:" <> conn_id)
      #(state, Some(selector))
    },
    on_close: fn(state) {
      log.info("beacon.transport", "Connection closed (cleanup): " <> state.id)
      pubsub.unsubscribe("beacon:patches:" <> state.id)
      state.on_close(state.id)
    },
  )
}

/// Serve the HTML page. Uses SSR-rendered HTML if available,
/// otherwise falls back to a minimal page with empty app root.
fn serve_page(
  page_html: option.Option(String),
) -> response.Response(mist.ResponseData) {
  let html = case page_html {
    option.Some(rendered) -> rendered
    option.None -> default_page_html()
  }
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

/// Default page when no SSR is configured.
fn default_page_html() -> String {
  "<!DOCTYPE html>"
  <> "<html><head><meta charset=\"utf-8\"><title>Beacon</title>"
  <> "<style>"
  <> "body{font-family:system-ui,sans-serif;max-width:600px;margin:2rem auto}"
  <> "button{font-size:1.5rem;padding:.5rem 1.5rem;margin:.25rem;cursor:pointer}"
  <> ".counter{text-align:center}"
  <> "</style>"
  <> "</head><body>"
  <> "<div id=\"beacon-app\"></div>"
  <> "<script src=\"/beacon_client.js\" data-beacon-auto></script>"
  <> "</body></html>"
}

/// Serve the compiled Gleam-to-JS client runtime bundle.
/// Falls back to a "not built yet" message if the bundle doesn't exist.
fn serve_client_js() -> response.Response(mist.ResponseData) {
  case simplifile.read("priv/static/beacon_client.js") {
    Ok(contents) -> {
      response.new(200)
      |> response.set_header(
        "content-type",
        "application/javascript; charset=utf-8",
      )
      |> response.set_body(mist.Bytes(bytes_tree.from_string(contents)))
    }
    Error(_) -> {
      response.new(404)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(
          bytes_tree.from_string(
            "// beacon_client.js not found. Run: gleam run -m beacon/build",
          ),
        ),
      )
    }
  }
}

/// Start the transport layer — binds to the given port and begins
/// accepting connections. Returns the supervisor's Pid for monitoring.
pub fn start(
  config: TransportConfig,
) -> Result(process.Pid, error.BeaconError) {
  log.info(
    "beacon.transport",
    "Starting on port " <> int.to_string(config.port),
  )
  let handler = create_handler(config)
  let result =
    mist.new(handler)
    |> mist.port(config.port)
    |> mist.start
  case result {
    Ok(started) -> {
      log.info(
        "beacon.transport",
        "Listening on port " <> int.to_string(config.port),
      )
      Ok(started.pid)
    }
    Error(_start_error) -> {
      log.error(
        "beacon.transport",
        "Failed to start on port " <> int.to_string(config.port),
      )
      Error(error.TransportError(
        reason: "Failed to bind to port " <> int.to_string(config.port),
      ))
    }
  }
}
