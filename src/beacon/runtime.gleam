/// Beacon's server-side MVU runtime.
/// Runs the Model-View-Update loop as an OTP actor, one per user session.
/// Follows Lustre's runtime/server/runtime.gleam pattern.
///
/// Reference: Lustre server runtime, LiveView process model, Reflex event chain.

import beacon/effect.{type Effect}
import beacon/element.{type Node}
import beacon/error
import beacon/handler.{type HandlerRegistry}
import beacon/log
import beacon/pubsub
import beacon/template/rendered.{type Rendered}
import beacon/transport
import beacon/view
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

/// Messages the runtime actor can receive.
pub type RuntimeMessage(msg) {
  /// A client connected — register their transport subject for pushing updates.
  ClientConnected(
    conn_id: transport.ConnectionId,
    subject: Subject(transport.InternalMessage),
  )
  /// A client disconnected — remove their transport subject.
  ClientDisconnected(conn_id: transport.ConnectionId)
  /// A client sent a join request — send them the initial mount.
  /// Includes session token for potential state recovery.
  ClientJoined(conn_id: transport.ConnectionId, token: String)
  /// A client event was received — decode to user message and run update.
  ClientEventReceived(
    conn_id: transport.ConnectionId,
    event_name: String,
    handler_id: String,
    event_data: String,
    target_path: String,
    clock: Int,
  )
  /// An effect dispatched a message back to the runtime.
  EffectDispatched(message: msg)
  /// Shutdown the runtime.
  Shutdown
}

/// The runtime's internal state.
pub type RuntimeState(model, msg) {
  RuntimeState(
    /// The application's current model.
    model: model,
    /// The update function: model + message → new model + effects.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// The view function: model → Node tree.
    view: fn(model) -> Node(msg),
    /// Function to decode client events into user messages.
    /// If None, the handler registry is used instead (automatic decoding).
    decode_event: Option(fn(String, String, String, String) -> Result(msg, error.BeaconError)),
    /// Handler registry from the last view render.
    /// Used for automatic event decoding when decode_event is None.
    handler_registry: Option(HandlerRegistry(msg)),
    /// Currently connected clients: conn_id → transport subject.
    connections: Dict(transport.ConnectionId, Subject(transport.InternalMessage)),
    /// The runtime's own subject for dispatching effect messages.
    self: Subject(RuntimeMessage(msg)),
    /// The previous Rendered struct, used for LiveView-style diffing.
    /// None on first render.
    previous_rendered: Option(Rendered),
    /// Current event clock value — monotonically increasing.
    /// Used for event ordering and optimistic update acknowledgment.
    event_clock: Int,
    /// Serialize model to string for state recovery.
    serialize_model: Option(fn(model) -> String),
    /// Deserialize model from string for state recovery.
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// Secret key for session tokens.
    secret_key: String,
  )
}

/// Configuration needed to start a runtime.
pub type RuntimeConfig(model, msg) {
  RuntimeConfig(
    /// Initial model and effects.
    init: fn() -> #(model, Effect(msg)),
    /// The update function.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// The view function.
    view: fn(model) -> Node(msg),
    /// Decode client events into user messages.
    /// If None, the handler registry (from on_click/on_input) is used automatically.
    decode_event: Option(fn(String, String, String, String) -> Result(msg, error.BeaconError)),
    /// Serialize model to a string for session token embedding.
    /// If None, state recovery is disabled (reconnect re-runs init).
    serialize_model: option.Option(fn(model) -> String),
    /// Deserialize model from a string (from session token).
    /// Returns Ok(model) if valid, Error if the serialized data is stale/invalid.
    deserialize_model: option.Option(fn(String) -> Result(model, String)),
    /// PubSub topics to subscribe to. When a notification arrives,
    /// `on_pubsub` is called to produce a Msg for the update loop.
    subscriptions: List(String),
    /// Called when a PubSub notification arrives on a subscribed topic.
    /// Returns the Msg to dispatch into the update loop.
    on_pubsub: option.Option(fn() -> msg),
  )
}

/// Start a runtime actor. Returns a Subject for sending RuntimeMessages.
pub fn start(
  config: RuntimeConfig(model, msg),
) -> Result(Subject(RuntimeMessage(msg)), error.BeaconError) {
  let #(initial_model, initial_effects) = config.init()

  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      let state =
        RuntimeState(
          model: initial_model,
          update: config.update,
          view: config.view,
          decode_event: config.decode_event,
          handler_registry: None,
          connections: dict.new(),
          self: subject,
          previous_rendered: None,
          event_clock: 0,
          serialize_model: config.serialize_model,
          deserialize_model: config.deserialize_model,
          secret_key: "",
        )
      log.info("beacon.runtime", "Runtime initialising")
      // Execute initial effects
      run_effects(initial_effects, subject)

      actor.initialised(state)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> {
      log.info("beacon.runtime", "Runtime actor started successfully")
      let subject = started.data
      // Subscribe to PubSub topics and forward notifications to the runtime
      case config.on_pubsub, config.subscriptions {
        Some(make_msg), [_, ..] ->
          start_pubsub_listener(subject, make_msg, config.subscriptions)
        _, _ -> Nil
      }
      Ok(subject)
    }
    Error(actor.InitTimeout) -> {
      log.error("beacon.runtime", "Failed to start runtime: init timed out")
      Error(error.RuntimeError(reason: "Runtime init timed out"))
    }
    Error(actor.InitFailed(reason)) -> {
      log.error(
        "beacon.runtime",
        "Failed to start runtime: " <> reason,
      )
      Error(error.RuntimeError(reason: "Runtime init failed: " <> reason))
    }
    Error(actor.InitExited(_reason)) -> {
      log.error("beacon.runtime", "Failed to start runtime: init process exited")
      Error(error.RuntimeError(reason: "Runtime init process exited"))
    }
  }
}

/// The main message loop for the runtime actor.
/// Follows Lustre's loop pattern: handle message → update state → return Next.
fn handle_message(
  state: RuntimeState(model, msg),
  message: RuntimeMessage(msg),
) -> actor.Next(RuntimeState(model, msg), RuntimeMessage(msg)) {
  case message {
    ClientConnected(conn_id, subject) -> {
      log.info("beacon.runtime", "Client connected: " <> conn_id)
      let new_connections = dict.insert(state.connections, conn_id, subject)
      actor.continue(RuntimeState(..state, connections: new_connections))
    }

    ClientDisconnected(conn_id) -> {
      log.info("beacon.runtime", "Client disconnected: " <> conn_id)
      let new_connections = dict.delete(state.connections, conn_id)
      actor.continue(RuntimeState(..state, connections: new_connections))
    }

    ClientJoined(conn_id, token) -> {
      log.info("beacon.runtime", "Client joined: " <> conn_id)
      // Attempt state recovery from token
      let model_to_use = case token, state.deserialize_model {
        "", _ -> {
          log.debug("beacon.runtime", "No token — using current model")
          state.model
        }
        _, None -> {
          log.debug("beacon.runtime", "No deserializer — using current model")
          state.model
        }
        _, Some(deserialize) -> {
          // Try to deserialize model state from token payload
          case recover_model_from_token(token, state.secret_key, deserialize) {
            Ok(recovered_model) -> {
              log.info(
                "beacon.runtime",
                "State recovered from token for " <> conn_id,
              )
              recovered_model
            }
            Error(reason) -> {
              log.warning(
                "beacon.runtime",
                "State recovery failed: " <> reason <> " — using current model",
              )
              state.model
            }
          }
        }
      }
      // Render view with the model (current or recovered)
      handler.start_render()
      let current_vdom = model_to_use |> state.view
      let view_registry = handler.finish_render()
      let current_rendered = view.render(current_vdom)
      let mount_json =
        rendered.to_mount_json(current_rendered)
        |> json.to_string
      case dict.get(state.connections, conn_id) {
        Ok(subject) -> {
          process.send(subject, transport.SendMount(payload: mount_json))
          // Also send model_sync so client has authoritative model state
          case state.serialize_model {
            Some(serialize) -> {
              let model_json = serialize(model_to_use)
              process.send(
                subject,
                transport.SendModelSync(
                  model_json: model_json,
                  version: state.event_clock,
                  ack_clock: state.event_clock,
                ),
              )
            }
            None -> Nil
          }
          log.debug("beacon.runtime", "Sent mount + model_sync to " <> conn_id)
        }
        Error(Nil) -> {
          log.warning(
            "beacon.runtime",
            "Client " <> conn_id <> " not found in connections for join",
          )
        }
      }
      // Cache the Rendered, handler registry, and update model
      actor.continue(
        RuntimeState(
          ..state,
          model: model_to_use,
          previous_rendered: Some(current_rendered),
          handler_registry: Some(view_registry),
        ),
      )
    }

    ClientEventReceived(conn_id, event_name, handler_id, event_data, target_path, clock) -> {
      log.debug(
        "beacon.runtime",
        "Event from "
          <> conn_id
          <> ": "
          <> event_name
          <> " ["
          <> handler_id
          <> "] clock="
          <> int.to_string(clock),
      )
      // Try handler registry first (automatic), then fall back to decode_event
      let resolve_result = case state.handler_registry {
        Some(registry) -> handler.resolve(registry, handler_id, event_data)
        None -> Error(error.RuntimeError(reason: "No handler registry"))
      }
      let resolve_result = case resolve_result {
        Ok(msg) -> Ok(msg)
        Error(_) -> {
          // Fall back to decode_event if provided
          case state.decode_event {
            Some(decode_fn) ->
              decode_fn(event_name, handler_id, event_data, target_path)
            None -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
          }
        }
      }
      case resolve_result {
        Ok(msg) -> {
          let new_state = run_update(RuntimeState(..state, event_clock: clock), msg)
          // Send model_sync to the triggering client
          send_model_sync(new_state, conn_id)
          actor.continue(new_state)
        }
        Error(err) -> {
          log.warning(
            "beacon.runtime",
            "Failed to decode event from "
              <> conn_id
              <> ": "
              <> error.to_string(err),
          )
          actor.continue(state)
        }
      }
    }

    EffectDispatched(msg) -> {
      log.debug("beacon.runtime", "Effect dispatched message")
      let new_state = run_update(state, msg)
      actor.continue(new_state)
    }

    Shutdown -> {
      log.info("beacon.runtime", "Runtime shutting down")
      actor.stop()
    }
  }
}

/// Run the update cycle: update model → render view → diff → broadcast patches.
/// Uses LiveView-style Rendered struct: on update, only changed dynamic
/// positions are sent over the wire.
fn run_update(
  state: RuntimeState(model, msg),
  msg: msg,
) -> RuntimeState(model, msg) {
  // Run update function
  let #(new_model, effects) = state.update(state.model, msg)
  log.debug("beacon.runtime", "Model updated")

  // Render new view — wrapped in error boundary + handler registry
  handler.start_render()
  let #(new_rendered, new_registry) = case rescue_view(state.view, new_model) {
    Ok(vdom) -> {
      let new_r = view.render(vdom)
      let view_registry = handler.finish_render()
      // Diff against previous Rendered and broadcast
      case state.previous_rendered {
        Some(old_r) -> {
          let diff = rendered.diff(old_r, new_r)
          let diff_json = rendered.diff_to_json_string(diff)
          broadcast_patch(
            RuntimeState(..state, model: new_model),
            diff_json,
          )
        }
        None -> {
          let mount_json =
            rendered.to_mount_json(new_r)
            |> json.to_string
          broadcast_patch(RuntimeState(..state, model: new_model), mount_json)
        }
      }
      #(Some(new_r), Some(view_registry))
    }
    Error(reason) -> {
      log.error(
        "beacon.runtime",
        "View rendering failed: " <> reason,
      )
      let _ = broadcast_error(state, "View rendering error: " <> reason)
      let _ = handler.finish_render()
      #(state.previous_rendered, state.handler_registry)
    }
  }

  // Execute effects
  run_effects(effects, state.self)

  // Return updated state with new Rendered and handler registry cached
  RuntimeState(
    ..state,
    model: new_model,
    previous_rendered: new_rendered,
    handler_registry: new_registry,
  )
}

/// Safely execute the view function, catching any crashes.
/// Returns Ok(Node) on success, Error(reason) on failure.
/// This is the error boundary — a view crash doesn't kill the runtime.
fn rescue_view(
  view_fn: fn(model) -> Node(msg),
  model: model,
) -> Result(Node(msg), String) {
  rescue(fn() { view_fn(model) })
}

@external(erlang, "beacon_runtime_ffi", "rescue")
fn rescue(f: fn() -> a) -> Result(a, String)

/// Broadcast an error message to all connected clients.
fn broadcast_error(
  state: RuntimeState(model, msg),
  reason: String,
) -> Nil {
  dict.each(state.connections, fn(_conn_id, subject) {
    process.send(subject, transport.SendError(reason: reason))
  })
}

/// Broadcast a patch to all connected clients.
/// Uses direct Subject sends for local connections (efficient single-node),
/// and also broadcasts via PubSub for distributed subscribers.
fn broadcast_patch(
  state: RuntimeState(model, msg),
  html: String,
) -> Nil {
  let conn_count = dict.size(state.connections)
  log.debug(
    "beacon.runtime",
    "Broadcasting to " <> int.to_string(conn_count) <> " client(s)",
  )
  let patch_msg = transport.SendPatch(payload: html, clock: state.event_clock)
  // Direct send to all local connections (fast path)
  let _ =
    dict.each(state.connections, fn(_conn_id, subject) {
      process.send(subject, patch_msg)
    })
  // Also broadcast via PubSub for distributed subscribers
  pubsub.broadcast("beacon:patches", patch_msg)
}

/// Send authoritative model state to a specific client connection.
/// Only sends if serialize_model is configured.
fn send_model_sync(
  state: RuntimeState(model, msg),
  conn_id: transport.ConnectionId,
) -> Nil {
  case state.serialize_model {
    Some(serialize) -> {
      case dict.get(state.connections, conn_id) {
        Ok(subject) -> {
          let model_json = serialize(state.model)
          process.send(
            subject,
            transport.SendModelSync(
              model_json: model_json,
              version: state.event_clock,
              ack_clock: state.event_clock,
            ),
          )
        }
        Error(Nil) -> Nil
      }
    }
    None -> Nil
  }
}

/// Execute effects by providing a dispatch function that sends messages
/// back to the runtime actor.
fn run_effects(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
) -> Nil {
  case effect.is_none(effects) {
    True -> Nil
    False -> {
      log.debug("beacon.runtime", "Executing effects")
      let dispatch = fn(msg) {
        process.send(self, EffectDispatched(message: msg))
      }
      effect.perform(effects, dispatch)
    }
  }
}

/// Create a TransportConfig that wires transport events to a runtime.
/// This is the glue between the transport and runtime layers.
pub fn connect_transport(
  runtime: Subject(RuntimeMessage(msg)),
  port: Int,
) -> transport.TransportConfig {
  log.info(
    "beacon.runtime",
    "Connecting transport on port " <> int.to_string(port),
  )
  connect_transport_with_ssr(runtime, port, option.None)
}

/// Create a TransportConfig with SSR-rendered HTML.
pub fn connect_transport_with_ssr(
  runtime: Subject(RuntimeMessage(msg)),
  port: Int,
  page_html: option.Option(String),
) -> transport.TransportConfig {
  log.info(
    "beacon.runtime",
    "Connecting transport on port " <> int.to_string(port),
  )
  transport.TransportConfig(
    port: port,
    page_html: page_html,
    middlewares: [],
    static_config: option.None,
    runtime_factory: option.None,
    on_connect: fn(conn_id, subject) {
      process.send(
        runtime,
        ClientConnected(conn_id: conn_id, subject: subject),
      )
    },
    on_event: fn(conn_id, client_msg) {
      case client_msg {
        transport.ClientEvent(name, handler_id, data, target_path, clock) -> {
          process.send(
            runtime,
            ClientEventReceived(
              conn_id: conn_id,
              event_name: name,
              handler_id: handler_id,
              event_data: data,
              target_path: target_path,
              clock: clock,
            ),
          )
        }
        transport.ClientJoin(token) -> {
          process.send(
            runtime,
            ClientJoined(conn_id: conn_id, token: token),
          )
        }
        transport.ClientHeartbeat -> {
          // Heartbeat is handled directly by transport, no runtime action needed.
          Nil
        }
      }
    },
    on_disconnect: fn(conn_id) {
      process.send(runtime, ClientDisconnected(conn_id: conn_id))
    },
  )
}

/// Create a TransportConfig that spawns a NEW runtime per WebSocket connection.
/// Each connection gets its own Model, its own MVU loop, its own BEAM process.
/// This is the LiveView-style architecture for multi-user apps.
pub fn connect_transport_per_connection(
  config: RuntimeConfig(model, msg),
  port: Int,
  page_html: option.Option(String),
) -> transport.TransportConfig {
  log.info(
    "beacon.runtime",
    "Connecting transport (per-connection mode) on port "
      <> int.to_string(port),
  )
  transport.TransportConfig(
    port: port,
    page_html: page_html,
    middlewares: [],
    static_config: option.None,
    runtime_factory: option.Some(fn(
      conn_id: transport.ConnectionId,
      transport_subject: process.Subject(transport.InternalMessage),
    ) {
      // Start a fresh runtime for this connection
      log.info(
        "beacon.runtime",
        "Spawning per-connection runtime for " <> conn_id,
      )
      case start(config) {
        Ok(runtime_subject) -> {
          // Register this connection with the new runtime
          process.send(
            runtime_subject,
            ClientConnected(conn_id: conn_id, subject: transport_subject),
          )
          // Return per-connection event and disconnect handlers
          let on_event = fn(_cid: transport.ConnectionId, client_msg) {
            case client_msg {
              transport.ClientEvent(name, handler_id, data, target_path, clock) ->
                process.send(
                  runtime_subject,
                  ClientEventReceived(
                    conn_id: conn_id,
                    event_name: name,
                    handler_id: handler_id,
                    event_data: data,
                    target_path: target_path,
                    clock: clock,
                  ),
                )
              transport.ClientJoin(token) ->
                process.send(
                  runtime_subject,
                  ClientJoined(conn_id: conn_id, token: token),
                )
              transport.ClientHeartbeat -> Nil
            }
          }
          let on_disconnect = fn(_cid: transport.ConnectionId) {
            process.send(runtime_subject, Shutdown)
          }
          #(on_event, on_disconnect)
        }
        Error(_err) -> {
          log.error(
            "beacon.runtime",
            "Failed to spawn runtime for " <> conn_id,
          )
          // Return no-op handlers
          #(fn(_: transport.ConnectionId, _: transport.ClientMessage) { Nil }, fn(
            _: transport.ConnectionId,
          ) { Nil })
        }
      }
    }),
    // These are unused when runtime_factory is set, but needed for the type
    on_connect: fn(_, _) { Nil },
    on_event: fn(_, _) { Nil },
    on_disconnect: fn(_) { Nil },
  )
}

/// PubSub listener — spawns a process that subscribes to PubSub topics
/// and forwards notifications to the runtime as EffectDispatched messages.
fn start_pubsub_listener(
  runtime_subject: Subject(RuntimeMessage(msg)),
  make_msg: fn() -> msg,
  topics: List(String),
) -> Nil {
  let _ =
    process.spawn(fn() {
      // Subscribe to all topics
      list.each(topics, pubsub.subscribe)
      // Loop forever, forwarding PubSub messages to runtime
      pubsub_receive_loop(runtime_subject, make_msg)
    })
  Nil
}

/// Receive loop using Erlang FFI to catch any message.
fn pubsub_receive_loop(
  runtime_subject: Subject(RuntimeMessage(msg)),
  make_msg: fn() -> msg,
) -> Nil {
  // Wait for any message (PubSub sends raw Erlang messages)
  erlang_receive_any(60_000)
  // Got something — dispatch to runtime
  let msg = make_msg()
  process.send(runtime_subject, EffectDispatched(message: msg))
  pubsub_receive_loop(runtime_subject, make_msg)
}

@external(erlang, "beacon_pubsub_listener_ffi", "receive_any")
fn erlang_receive_any(timeout: Int) -> Nil

/// Attempt to recover model state from a session token.
/// Token payload contains serialized model data.
fn recover_model_from_token(
  token: String,
  secret_key: String,
  deserialize: fn(String) -> Result(model, String),
) -> Result(model, String) {
  let secret = bit_array.from_string(secret_key)
  case crypto.verify_signed_message(token, secret) {
    Ok(payload_bits) -> {
      case bit_array.to_string(payload_bits) {
        Ok(payload_str) -> {
          // Payload is JSON: {"ts":..., "v":1, "model":"..."}
          // Extract the "model" field
          case extract_model_data(payload_str) {
            Ok(model_data) -> deserialize(model_data)
            Error(reason) -> Error(reason)
          }
        }
        Error(Nil) -> Error("Invalid token encoding")
      }
    }
    Error(Nil) -> Error("Invalid or tampered token")
  }
}

/// Extract model data from token payload JSON.
fn extract_model_data(payload: String) -> Result(String, String) {
  case
    json.parse(payload, {
      use model_data <- decode.optional_field("model", "", decode.string)
      decode.success(model_data)
    })
  {
    Ok("") -> Error("No model data in token")
    Ok(data) -> Ok(data)
    Error(_) -> Error("Failed to parse token payload")
  }
}

/// Create a session token containing serialized model state.
/// Called by the SSR module or externally to embed model in the page.
pub fn create_state_token(
  model: model,
  serialize: fn(model) -> String,
  secret_key: String,
) -> String {
  let model_data = serialize(model)
  let payload =
    json.object([
      #("ts", json.int(system_time_seconds())),
      #("v", json.int(1)),
      #("model", json.string(model_data)),
    ])
    |> json.to_string
  let secret = bit_array.from_string(secret_key)
  let message = bit_array.from_string(payload)
  crypto.sign_message(message, secret, crypto.Sha256)
}

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn system_time_seconds() -> Int

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
