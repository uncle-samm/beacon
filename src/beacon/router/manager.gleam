/// Route manager — per-connection actor that coordinates route lifecycle.
/// Sits between the transport and the per-route runtime:
///
///   Transport → RouteManager → Current Route Runtime
///                   ↕ (on navigate: kill old, spawn new)
///
/// Reference: Phoenix LiveView's mount/handle_params lifecycle.

import beacon/error
import beacon/log
import beacon/transport
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

/// Type alias for the dispatcher function.
/// Given a conn_id, transport subject, and path, starts a route runtime
/// and returns type-erased handler closures.
pub type RouteDispatcher =
  fn(transport.ConnectionId, Subject(transport.InternalMessage), String) ->
    Result(
      #(
        fn(transport.ConnectionId, transport.ClientMessage) -> Nil,
        fn() -> Nil,
      ),
      error.BeaconError,
    )

/// Messages the route manager can receive.
pub type RouteManagerMessage {
  /// A client message needs to be routed.
  RouteEvent(conn_id: transport.ConnectionId, msg: transport.ClientMessage)
  /// The connection closed — clean up.
  RouteDisconnect(conn_id: transport.ConnectionId)
}

/// Internal state of the route manager.
type RouteManagerState {
  RouteManagerState(
    /// Connection ID this manager serves.
    conn_id: transport.ConnectionId,
    /// Transport subject for sending messages to the client.
    transport_subject: Subject(transport.InternalMessage),
    /// Current route's event handler (None before first join).
    current_on_event: Option(
      fn(transport.ConnectionId, transport.ClientMessage) -> Nil,
    ),
    /// Current route's shutdown function.
    current_shutdown: fn() -> Nil,
    /// The dispatcher function — starts a route runtime for a given path.
    dispatcher: RouteDispatcher,
    /// Current path (for logging and deduplication).
    current_path: String,
  )
}

/// Start a route manager for a connection.
/// Returns a runtime_factory-compatible pair of closures (on_event, on_disconnect).
pub fn start(
  conn_id: transport.ConnectionId,
  transport_subject: Subject(transport.InternalMessage),
  dispatcher: RouteDispatcher,
) -> #(
  fn(transport.ConnectionId, transport.ClientMessage) -> Nil,
  fn(transport.ConnectionId) -> Nil,
) {
  log.info(
    "beacon.router.manager",
    "Starting route manager for " <> conn_id,
  )

  let initial_state =
    RouteManagerState(
      conn_id: conn_id,
      transport_subject: transport_subject,
      current_on_event: None,
      current_shutdown: fn() { Nil },
      dispatcher: dispatcher,
      current_path: "",
    )

  // Safety: actor.start only fails if the actor init callback fails,
  // but we provide a plain state value (no init callback that can error),
  // so start is guaranteed to succeed.
  let assert Ok(started) =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start

  let manager_subject = started.data

  // Return closures that forward to the manager
  let on_event = fn(cid: transport.ConnectionId, msg: transport.ClientMessage) {
    process.send(manager_subject, RouteEvent(conn_id: cid, msg: msg))
  }
  let on_disconnect = fn(cid: transport.ConnectionId) {
    process.send(manager_subject, RouteDisconnect(conn_id: cid))
  }

  #(on_event, on_disconnect)
}

/// Handle messages for the route manager actor.
fn handle_message(
  state: RouteManagerState,
  msg: RouteManagerMessage,
) -> actor.Next(RouteManagerState, RouteManagerMessage) {
  case msg {
    RouteEvent(conn_id, client_msg) ->
      handle_route_event(conn_id, client_msg, state)
    RouteDisconnect(conn_id) ->
      handle_disconnect(conn_id, state)
  }
}

/// Handle a client event routed through the manager.
fn handle_route_event(
  conn_id: transport.ConnectionId,
  client_msg: transport.ClientMessage,
  state: RouteManagerState,
) -> actor.Next(RouteManagerState, RouteManagerMessage) {
  case client_msg {
    // Join — start the initial route runtime.
    transport.ClientJoin(_token, join_path) -> {
      case state.current_on_event {
        None -> {
          // Start runtime for the path from the join message
          let path = case join_path {
            "/" -> case state.current_path {
              "" -> "/"
              p -> p
            }
            p -> p
          }
          case start_route_runtime(state, path) {
            Ok(new_state) -> {
              // Forward the join to the new runtime
              case new_state.current_on_event {
                Some(on_event) -> on_event(conn_id, client_msg)
                None -> Nil
              }
              actor.continue(new_state)
            }
            Error(err) -> {
              log.error(
                "beacon.router.manager",
                "Failed to start initial route for " <> conn_id
                  <> ": " <> error.to_string(err),
              )
              process.send(
                state.transport_subject,
                transport.SendError(reason: "Failed to start route: " <> error.to_string(err)),
              )
              actor.continue(state)
            }
          }
        }
        Some(on_event) -> {
          // Runtime already exists — forward the join
          on_event(conn_id, client_msg)
          actor.continue(state)
        }
      }
    }

    // Navigate — kill old runtime, start new one.
    transport.ClientNavigate(path) -> {
      // Skip if already on this path
      case path == state.current_path {
        True -> {
          log.debug(
            "beacon.router.manager",
            "Already on path " <> path <> " — skipping navigate",
          )
          actor.continue(state)
        }
        False -> {
          log.info(
            "beacon.router.manager",
            "Navigating " <> conn_id <> " from " <> state.current_path
              <> " to " <> path,
          )
          // Kill old runtime
          state.current_shutdown()
          // Start new runtime for the new path
          case start_route_runtime(state, path) {
            Ok(new_state) -> {
              // Synthesize a join to trigger model_sync from the new runtime
              case new_state.current_on_event {
                Some(on_event) -> {
                  on_event(conn_id, transport.ClientJoin(token: "", path: path))
                }
                None -> Nil
              }
              actor.continue(new_state)
            }
            Error(err) -> {
              log.error(
                "beacon.router.manager",
                "Failed to start route for " <> path
                  <> ": " <> error.to_string(err),
              )
              process.send(
                state.transport_subject,
                transport.SendError(reason: "Route not found: " <> path),
              )
              actor.continue(
                RouteManagerState(
                  ..state,
                  current_on_event: None,
                  current_shutdown: fn() { Nil },
                  current_path: path,
                ),
              )
            }
          }
        }
      }
    }

    // All other messages — forward to current runtime.
    _ -> {
      case state.current_on_event {
        Some(on_event) -> on_event(conn_id, client_msg)
        None ->
          log.warning(
            "beacon.router.manager",
            "Event received before route initialized for " <> conn_id,
          )
      }
      actor.continue(state)
    }
  }
}

/// Handle disconnect — shut down the current runtime and stop the manager.
fn handle_disconnect(
  conn_id: transport.ConnectionId,
  state: RouteManagerState,
) -> actor.Next(RouteManagerState, RouteManagerMessage) {
  log.info(
    "beacon.router.manager",
    "Disconnecting route manager for " <> conn_id,
  )
  // Kill current runtime
  state.current_shutdown()
  actor.stop()
}

/// Start a route runtime for the given path.
/// Updates the state with the new handlers.
fn start_route_runtime(
  state: RouteManagerState,
  path: String,
) -> Result(RouteManagerState, error.BeaconError) {
  log.info(
    "beacon.router.manager",
    "Starting route runtime for path: " <> path
      <> " (conn: " <> state.conn_id <> ")",
  )
  case state.dispatcher(state.conn_id, state.transport_subject, path) {
    Ok(#(on_event, shutdown)) -> {
      Ok(RouteManagerState(
        ..state,
        current_on_event: Some(on_event),
        current_shutdown: shutdown,
        current_path: path,
      ))
    }
    Error(err) -> Error(err)
  }
}
