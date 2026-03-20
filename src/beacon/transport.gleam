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
    /// JSON-encoded patch operations from client-side model diff.
    /// When present, server applies these ops instead of running update.
    /// Empty string "" means no ops (server runs update as normal).
    /// Size is bounded by max_message_bytes in SecurityLimits (default 64KB).
    ops: String,
  )
  /// Client sends a heartbeat to keep the connection alive.
  ClientHeartbeat
  /// Client is requesting initial state after connecting.
  /// Includes an optional session token for state recovery
  /// and the current URL path for route-aware apps.
  ClientJoin(token: String, path: String)
  /// Client navigated to a new URL path (SPA navigation).
  ClientNavigate(path: String)
  /// Batch of events: LOCAL events replayed + MODEL event at the end.
  /// Sent when a MODEL event fires after LOCAL events accumulated state.
  ClientEventBatch(events: List(ClientMessage))
}

/// Messages sent from the server to the client (browser).
pub type ServerMessage {
  /// Initial mount: SSR HTML for first paint.
  ServerMount(payload: String)
  /// Server acknowledges a heartbeat.
  ServerHeartbeatAck
  /// Server-initiated error message.
  ServerError(reason: String)
  /// Authoritative Model state from server.
  /// Client renders the view locally from this state.
  ServerModelSync(model_json: String, version: Int, ack_clock: Int)
  /// Incremental model patch — only changed fields.
  /// Client applies ops to its cached model JSON instead of replacing entirely.
  ServerPatch(ops_json: String, version: Int, ack_clock: Int)
  /// Server-initiated navigation (redirect).
  ServerNavigate(path: String)
  /// Dev mode: tell browser to reload.
  ServerReload
}

/// Internal messages that the connection actor can receive.
/// These come either from the WebSocket (client) or from
/// other BEAM processes (e.g. the runtime pushing patches).
pub type InternalMessage {
  /// A mount payload needs to be sent to the client.
  SendMount(payload: String)
  /// An error needs to be sent to the client.
  SendError(reason: String)
  /// Send authoritative Model state to the client.
  SendModelSync(model_json: String, version: Int, ack_clock: Int)
  /// Send incremental model patch to the client.
  SendPatch(ops_json: String, version: Int, ack_clock: Int)
  /// Send navigation redirect to the client.
  SendNavigate(path: String)
}

/// Configurable security limits for the transport layer.
/// All fields have sensible defaults via `default_security_limits()`.
pub type SecurityLimits {
  SecurityLimits(
    /// Maximum WebSocket message size in bytes. Default: 65536 (64KB).
    max_message_bytes: Int,
    /// Maximum events per second per connection. Default: 50.
    max_events_per_second: Int,
    /// Maximum concurrent WebSocket connections globally. Default: 10000.
    max_connections: Int,
  )
}

/// Sensible default security limits.
pub fn default_security_limits() -> SecurityLimits {
  SecurityLimits(
    max_message_bytes: 65_536,
    max_events_per_second: 50,
    max_connections: 10_000,
  )
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
    /// Rate limiting: count of events in current 1-second window.
    event_count: Int,
    /// Rate limiting: start of current window (monotonic native time units).
    rate_window_start: Int,
    /// Security limits for this connection (copied from TransportConfig at init).
    security_limits: SecurityLimits,
    /// Heartbeat rate limiting: count in current 1-second window.
    heartbeat_count: Int,
    /// Heartbeat rate limiting: start of current window (monotonic native time units).
    heartbeat_window_start: Int,
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
    /// Optional: SSR factory for route-aware server-side rendering.
    /// Given a path, returns the HTML string for that route.
    /// When set, HTTP requests use this instead of page_html.
    ssr_factory: Option(fn(String) -> String),
    /// Configurable security limits (message size, rate limiting, max connections).
    /// Defaults to `default_security_limits()`.
    security_limits: SecurityLimits,
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

// --- Connection tracker FFI (global connection count via ETS) ---

@external(erlang, "beacon_connection_tracker_ffi", "init")
pub fn connection_tracker_init() -> Nil

@external(erlang, "beacon_connection_tracker_ffi", "increment")
fn connection_tracker_increment() -> Int

@external(erlang, "beacon_connection_tracker_ffi", "decrement")
fn connection_tracker_decrement() -> Int

@external(erlang, "beacon_connection_tracker_ffi", "count")
fn connection_tracker_count() -> Int

/// Encode a ServerMessage to JSON string for sending over the wire.
pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    ServerMount(payload) ->
      json.object([
        #("type", json.string("mount")),
        #("payload", json.string(payload)),
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
    ServerPatch(ops_json, version, ack_clock) ->
      // ops_json is already a JSON-encoded array string — embed it raw
      json.object([
        #("type", json.string("patch")),
        #("ops", json.string(ops_json)),
        #("version", json.int(version)),
        #("ack_clock", json.int(ack_clock)),
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
      use ops <- decode.optional_field("ops", "", decode.string)
      decode.success(ClientEvent(
        name: name,
        handler_id: handler_id,
        data: data,
        target_path: target_path,
        clock: clock,
        ops: ops,
      ))
    }
    "heartbeat" -> decode.success(ClientHeartbeat)
    "join" -> {
      use token <- decode.optional_field("token", "", decode.string)
      use path <- decode.optional_field("path", "/", decode.string)
      decode.success(ClientJoin(token: token, path: path))
    }
    "navigate" -> {
      use path <- decode.field("path", decode.string)
      decode.success(ClientNavigate(path: path))
    }
    "event_batch" -> {
      // Decode array of events — each follows the "event" format
      let event_decoder = {
        use name <- decode.field("name", decode.string)
        use handler_id <- decode.optional_field("handler_id", "", decode.string)
        use data <- decode.field("data", decode.string)
        use target_path <- decode.optional_field("target_path", "", decode.string)
        use clock <- decode.optional_field("clock", 0, decode.int)
        use ops <- decode.optional_field("ops", "", decode.string)
        decode.success(ClientEvent(
          name: name,
          handler_id: handler_id,
          data: data,
          target_path: target_path,
          clock: clock,
          ops: ops,
        ))
      }
      use events <- decode.field("events", decode.list(event_decoder))
      decode.success(ClientEventBatch(events: events))
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

/// Return the type name of a client message for safe logging.
/// Does not include payload data which may be sensitive.
/// NOTE: Debug-level logging elsewhere in the transport may include message
/// metadata (connection IDs, event names, paths). Ensure debug logging is
/// disabled in production to avoid leaking potentially sensitive data.
fn client_message_type(msg: ClientMessage) -> String {
  case msg {
    ClientEvent(name: name, ..) -> "event:" <> name
    ClientHeartbeat -> "heartbeat"
    ClientJoin(..) -> "join"
    ClientNavigate(path: path) -> "navigate:" <> path
    ClientEventBatch(..) -> "event_batch"
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

/// One second in native time units (nanoseconds on most BEAM VMs).
/// Used for rate limiting window calculations.
const one_second_native = 1_000_000_000

/// Maximum heartbeats per second. Heartbeats beyond this are silently dropped
/// (no ack sent) to prevent heartbeat flooding.
const max_heartbeats_per_second = 2

/// Check per-connection rate limit: max 50 events per 1-second window.
/// Returns the updated state and whether the event was rate limited.
fn check_rate_limit(state: ConnectionState) -> #(ConnectionState, Bool) {
  let now = erlang_monotonic_time()
  // If more than 1 second has passed, reset the window
  let #(count, window_start) = case
    now - state.rate_window_start > one_second_native
  {
    True -> #(0, now)
    False -> #(state.event_count, state.rate_window_start)
  }
  let new_count = count + 1
  let new_state =
    ConnectionState(
      ..state,
      event_count: new_count,
      rate_window_start: window_start,
    )
  case new_count > state.security_limits.max_events_per_second {
    True -> #(new_state, True)
    False -> #(new_state, False)
  }
}

/// Handle an incoming WebSocket text frame.
/// Rejects oversized messages, then decodes and dispatches to the appropriate handler.
fn handle_text_message(
  state: ConnectionState,
  text: String,
) -> mist.Next(ConnectionState, InternalMessage) {
  // Reject oversized messages to prevent resource exhaustion
  let size = string.byte_size(text)
  case size > state.security_limits.max_message_bytes {
    True -> {
      log.warning(
        "beacon.transport",
        "Oversized message from "
          <> state.id
          <> " ("
          <> int.to_string(size)
          <> " bytes) — rejected",
      )
      send_message(
        state.connection,
        state.id,
        ServerError(reason: "Message too large"),
      )
      mist.continue(state)
    }
    False -> handle_text_message_decode(state, text)
  }
}

/// Check heartbeat rate limit: max 2 per second.
/// Returns the updated state and whether the heartbeat was rate limited.
fn check_heartbeat_rate(state: ConnectionState) -> #(ConnectionState, Bool) {
  let now = erlang_monotonic_time()
  let #(count, window_start) = case
    now - state.heartbeat_window_start > one_second_native
  {
    True -> #(0, now)
    False -> #(state.heartbeat_count, state.heartbeat_window_start)
  }
  let new_count = count + 1
  let new_state =
    ConnectionState(
      ..state,
      heartbeat_count: new_count,
      heartbeat_window_start: window_start,
    )
  case new_count > max_heartbeats_per_second {
    True -> #(new_state, True)
    False -> #(new_state, False)
  }
}

/// Decode and dispatch a validated text message.
/// Applies per-connection rate limiting to non-heartbeat messages.
fn handle_text_message_decode(
  state: ConnectionState,
  text: String,
) -> mist.Next(ConnectionState, InternalMessage) {
  case decode_client_message(text) {
    Ok(ClientHeartbeat) -> {
      // Rate-limit heartbeats: max 2 per second to prevent flooding
      let #(new_state, hb_limited) = check_heartbeat_rate(state)
      case hb_limited {
        True -> {
          log.debug("beacon.transport", "Heartbeat rate limited for " <> state.id)
          mist.continue(new_state)
        }
        False -> {
          log.debug("beacon.transport", "Heartbeat from " <> state.id)
          send_message(new_state.connection, new_state.id, ServerHeartbeatAck)
          mist.continue(new_state)
        }
      }
    }
    Ok(msg) -> {
      // Check rate limit before dispatching
      let #(new_state, rate_limited) = check_rate_limit(state)
      case rate_limited {
        True -> {
          log.warning(
            "beacon.transport",
            "Rate limited connection "
              <> state.id
              <> " ("
              <> int.to_string(new_state.event_count)
              <> " events/sec)",
          )
          send_message(
            new_state.connection,
            new_state.id,
            ServerError(reason: "Rate limited"),
          )
          mist.continue(new_state)
        }
        False -> {
          log.debug(
            "beacon.transport",
            "Event from "
              <> new_state.id
              <> ": "
              <> client_message_type(msg),
          )
          new_state.on_event(new_state.id, msg)
          mist.continue(new_state)
        }
      }
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
      ["beacon_client.js"] -> serve_client_js()
      ["health"] -> {
        response.new(200)
        |> response.set_header("content-type", "application/json")
        |> response.set_body(
          mist.Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")),
        )
      }
      _ -> {
        // Check for hashed client JS file (beacon_client_HASH.js)
        let path = req.path
        case
          string.starts_with(path, "/beacon_client_")
          && string.ends_with(path, ".js")
        {
          True -> {
            let name = string.drop_start(path, 1)
            serve_hashed_client_js(name)
          }
          False -> {
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
                  Error(Nil) ->
                    serve_page_or_ssr(config.page_html, config.ssr_factory, req.path)
                }
              }
              None ->
                serve_page_or_ssr(config.page_html, config.ssr_factory, req.path)
            }
          }
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

/// Check that the Origin header (if present) matches the server's host.
/// This prevents cross-site WebSocket hijacking (CSWSH).
/// If no Origin header is present, the request is allowed (non-browser clients, same-origin).
///
/// SECURITY: Origin validation is the primary CSRF defense for WebSocket connections.
/// Unlike HTTP requests, WebSocket upgrades cannot use CSRF tokens because the browser
/// sends the upgrade request automatically. The same-origin policy combined with this
/// origin check is the standard defense (same approach as Phoenix LiveView).
fn check_origin(req: Request(mist.Connection)) -> Result(Nil, String) {
  case request.get_header(req, "origin") {
    // No origin header — allow (non-browser clients, same-origin)
    Error(Nil) -> Ok(Nil)
    Ok(origin) -> {
      let origin_host = extract_host_from_origin(origin)
      let request_host = case request.get_header(req, "host") {
        Ok(h) -> h
        Error(Nil) -> ""
      }
      // Compare: origin host must match request host.
      // An empty origin host is NOT allowed — it would bypass the check.
      case origin_host == request_host {
        True -> Ok(Nil)
        False -> {
          log.warning(
            "beacon.transport",
            "Origin mismatch: origin=" <> origin <> " host=" <> request_host,
          )
          Error("Origin mismatch")
        }
      }
    }
  }
}

/// Extract the host portion from an origin URL.
/// e.g. "http://localhost:8080" -> "localhost:8080"
/// e.g. "https://example.com" -> "example.com"
fn extract_host_from_origin(origin: String) -> String {
  // Strip protocol prefix (e.g. "http://", "https://")
  let without_protocol = case string.split(origin, "://") {
    [_, rest] -> rest
    _ -> origin
  }
  // Take everything before the first /
  case string.split(without_protocol, "/") {
    [host, ..] -> host
    _ -> without_protocol
  }
}

/// Handle a WebSocket upgrade request.
/// Checks global connection limit, then origin (CSWSH prevention), then auth, then upgrades.
fn handle_websocket(
  req: Request(mist.Connection),
  config: TransportConfig,
) -> response.Response(mist.ResponseData) {
  // Check global connection limit first — prevents process exhaustion
  let current_count = connection_tracker_count()
  case current_count >= config.security_limits.max_connections {
    True -> {
      log.warning(
        "beacon.transport",
        "Global connection limit reached ("
          <> int.to_string(current_count)
          <> "/"
          <> int.to_string(config.security_limits.max_connections)
          <> ") — rejecting new connection",
      )
      response.new(503)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Too many connections")),
      )
    }
    False -> {
      // Check origin — prevents cross-site WebSocket hijacking
      case check_origin(req) {
        Error(reason) -> {
          response.new(403)
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string("Forbidden: " <> reason)),
          )
        }
        Ok(Nil) -> {
          // Then check WebSocket auth if configured
          let auth_ok = case config.ws_auth {
            Some(auth_fn) -> auth_fn(req)
            None -> Ok(Nil)
          }
          case auth_ok {
            Error(reason) -> {
              log.warning("beacon.transport", "WS auth rejected: " <> reason)
              response.new(401)
              |> response.set_body(
                mist.Bytes(
                  bytes_tree.from_string("Unauthorized: " <> reason),
                ),
              )
            }
            Ok(Nil) -> handle_websocket_upgrade(req, config)
          }
        }
      }
    }
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
            SendPatch(ops_json, version, ack_clock) -> {
              send_message(
                state.connection,
                state.id,
                ServerPatch(
                  ops_json: ops_json,
                  version: version,
                  ack_clock: ack_clock,
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
      // Track global connection count
      let conn_count = connection_tracker_increment()
      log.debug(
        "beacon.transport",
        "Global connections: " <> int.to_string(conn_count),
      )
      let state =
        ConnectionState(
          id: conn_id,
          connection: conn,
          on_event: conn_on_event,
          on_close: conn_on_close,
          event_count: 0,
          rate_window_start: 0,
          security_limits: config.security_limits,
          heartbeat_count: 0,
          heartbeat_window_start: 0,
        )
      pubsub.subscribe("beacon:patches:" <> conn_id)
      #(state, Some(selector))
    },
    on_close: fn(state) {
      log.info("beacon.transport", "Connection closed (cleanup): " <> state.id)
      let conn_count = connection_tracker_decrement()
      log.debug(
        "beacon.transport",
        "Global connections after close: " <> int.to_string(conn_count),
      )
      pubsub.unsubscribe("beacon:patches:" <> state.id)
      state.on_close(state.id)
    },
  )
}

/// Serve the HTML page. Checks: ssr_factory (route-aware), page_html (static SSR),
/// then default page.
fn serve_page_or_ssr(
  page_html: option.Option(String),
  ssr_factory: option.Option(fn(String) -> String),
  path: String,
) -> response.Response(mist.ResponseData) {
  let html = case ssr_factory {
    option.Some(factory) -> factory(path)
    option.None -> case page_html {
      option.Some(rendered) -> rendered
      option.None -> default_page_html()
    }
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
  <> "<script src=\"/"
  <> get_client_js_filename()
  <> "\" data-beacon-auto></script>"
  <> "</body></html>"
}

fn get_client_js_filename() -> String {
  case simplifile.read("priv/static/beacon_client.manifest") {
    Ok(name) -> string.trim(name)
    Error(err) -> {
      log.error(
        "beacon.transport",
        "FATAL: No beacon_client.manifest found: "
          <> string.inspect(err)
          <> " — the client JS was not built. Run `gleam run -m beacon/build` first.",
      )
      // No fallback — return a name that will 404 with a clear error
      "MISSING_CLIENT_JS_RUN_BEACON_BUILD"
    }
  }
}

/// Serve the compiled Gleam-to-JS client runtime bundle.
fn serve_client_js() -> response.Response(mist.ResponseData) {
  case simplifile.read("priv/static/beacon_client.manifest") {
    Ok(name) -> serve_js_file("priv/static/" <> string.trim(name))
    Error(err) -> {
      log.error(
        "beacon.transport",
        "FATAL: No beacon_client.manifest: "
          <> string.inspect(err)
          <> " — client JS not built. Run `gleam run -m beacon/build`.",
      )
      response.new(500)
      |> response.set_body(
        mist.Bytes(
          bytes_tree.from_string(
            "Client JS not built. Run `gleam run -m beacon/build` first.",
          ),
        ),
      )
    }
  }
}

fn serve_hashed_client_js(
  name: String,
) -> response.Response(mist.ResponseData) {
  serve_js_file("priv/static/" <> name)
}

fn serve_js_file(path: String) -> response.Response(mist.ResponseData) {
  case simplifile.read(path) {
    Ok(contents) -> {
      response.new(200)
      |> response.set_header(
        "content-type",
        "application/javascript; charset=utf-8",
      )
      |> response.set_header(
        "cache-control",
        "public, max-age=31536000, immutable",
      )
      |> response.set_body(mist.Bytes(bytes_tree.from_string(contents)))
    }
    Error(err) -> {
      log.error(
        "beacon.transport",
        "Client JS not found: " <> string.inspect(err)
          <> " — run `gleam run -m beacon/build` to compile client JS",
      )
      response.new(500)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "// beacon.js not found. Run: gleam run -m beacon/build\n",
        )),
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
  // Warn if no WebSocket authentication is configured
  case config.ws_auth {
    None ->
      log.warning(
        "beacon.transport",
        "No ws_auth configured — WebSocket connections are unauthenticated. "
          <> "Set ws_auth in TransportConfig to require authentication on upgrade.",
      )
    Some(_) -> Nil
  }
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

