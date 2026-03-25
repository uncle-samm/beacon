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
import beacon/patch
import beacon/pubsub
import beacon/route
import beacon/transport
import beacon/transport/server
import gleam/http/request

/// Cached serialized state for diffing.
/// When substates are detected, each is tracked independently to skip unchanged diffs.
pub type CachedModelState {
  /// No substates detected — fall back to full-model diffing (backward compat).
  FullModelCache(json: Option(String))
  /// Substates detected — per-substate caches + flat field cache.
  SubstateCache(
    /// Full model JSON (needed for model_sync on join).
    full_json: Option(String),
    /// Per-substate cached JSON strings: field_name → JSON string.
    substate_jsons: Dict(String, String),
    /// Cached flat fields JSON (non-substate primitives).
    flat_fields_json: Option(String),
  )
}
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
  /// Includes session token for potential state recovery and the
  /// URL path the client connected from (for initial route dispatch).
  ClientJoined(conn_id: transport.ConnectionId, token: String, path: String)
  /// A client event was received — decode to user message and run update.
  ClientEventReceived(
    conn_id: transport.ConnectionId,
    event_name: String,
    handler_id: String,
    event_data: String,
    target_path: String,
    clock: Int,
    /// JSON-encoded patch ops from client. Empty string means no ops.
    ops: String,
  )
  /// A batch of events to process atomically (all updates, one render).
  /// Used when LOCAL events are replayed before a MODEL event.
  ClientEventBatchReceived(
    conn_id: transport.ConnectionId,
    events: List(#(String, String, String, String, Int, String)),
  )
  /// A client navigated to a new URL path.
  ClientNavigated(conn_id: transport.ConnectionId, path: String)
  /// Set the listener subject for dynamic subscription management.
  SetListenerSubject(
    listener: Subject(ListenerCommand),
    initial_subs: List(String),
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
    /// Current event clock value — monotonically increasing.
    /// Used for event ordering and optimistic update acknowledgment.
    event_clock: Int,
    /// Serialize model to string for state recovery.
    serialize_model: Option(fn(model) -> String),
    /// Deserialize model from string for state recovery.
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// Secret key for session tokens.
    secret_key: String,
    /// Route patterns for URL matching.
    route_patterns: List(route.RoutePattern),
    /// Called when URL changes — produces a Msg for the update loop.
    on_route_change: option.Option(fn(route.Route) -> msg),
    /// Subject for sending commands to the PubSub listener process.
    listener_subject: Option(Subject(ListenerCommand)),
    /// Current set of dynamic subscriptions (for diffing).
    current_subscriptions: List(String),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
    /// Cached serialized model state for diffing.
    /// Tracks per-substate JSON when available, or full model JSON as fallback.
    cached_model: CachedModelState,
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
    /// Route patterns for URL matching.
    route_patterns: List(route.RoutePattern),
    /// Called when URL changes — produces a Msg for the update loop.
    on_route_change: option.Option(fn(route.Route) -> msg),
    /// Dynamic subscription function: given the current model, returns
    /// the set of topics this runtime should be subscribed to.
    /// Called after every update. The framework diffs against current subscriptions.
    dynamic_subscriptions: option.Option(fn(model) -> List(String)),
    /// Called when a PubSub notification arrives on a dynamically subscribed topic.
    /// Receives the topic string so the handler can distinguish between sources.
    on_notify: option.Option(fn(String) -> msg),
    /// Optional: request-aware init — replaces `init` when the HTTP request is available.
    /// Used by ws_init to pass cookies/headers into server state initialization.
    /// If set and a request is provided, this is used instead of `init`.
    init_from_request: option.Option(
      fn(request.Request(server.Connection)) -> #(model, Effect(msg)),
    ),
    /// Secret key for session token HMAC verification.
    /// Threaded from AppConfig — must not be empty when state recovery is enabled.
    secret_key: String,
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
          event_clock: 0,
          serialize_model: case config.serialize_model {
            Some(f) -> Some(f)
            None -> discover_model_encoder()
          },
          deserialize_model: config.deserialize_model,
          secret_key: config.secret_key,
          route_patterns: config.route_patterns,
          on_route_change: config.on_route_change,
          listener_subject: None,
          current_subscriptions: [],
          dynamic_subscriptions: config.dynamic_subscriptions,
          on_notify: config.on_notify,
          cached_model: FullModelCache(json: None),
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
      // Start dynamic PubSub listener if subscriptions are configured
      log.info(
        "beacon.runtime",
        "Dynamic subs: "
          <> case config.dynamic_subscriptions {
          Some(_) -> "YES"
          None -> "NO"
        }
          <> ", on_notify: "
          <> case config.on_notify {
          Some(_) -> "YES"
          None -> "NO"
        },
      )
      case config.dynamic_subscriptions, config.on_notify {
        Some(compute), Some(notify) -> {
          let initial_topics = compute(initial_model)
          let listener =
            start_pubsub_listener(subject, notify, initial_topics)
          process.send(
            subject,
            SetListenerSubject(
              listener: listener,
              initial_subs: initial_topics,
            ),
          )
        }
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

    ClientJoined(conn_id, token, path) -> {
      log.info("beacon.runtime", "Client joined: " <> conn_id <> " path: " <> path)
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
          case
            recover_model_from_token(
              token,
              state.secret_key,
              deserialize,
              default_token_max_age_seconds,
            )
          {
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
      // Apply initial route change so the mount reflects the URL the client is on.
      // Without this, all clients would see the default init() model (e.g. Home)
      // regardless of which URL they connected from.
      let model_to_use = case state.on_route_change, path {
        option.Some(make_msg), p if p != "" -> {
          let matched_route = case route.match_path(state.route_patterns, p) {
            option.Some(r) -> r
            option.None -> route.from_path(p)
          }
          let msg = make_msg(matched_route)
          let #(new_model, _effects) = state.update(model_to_use, msg)
          new_model
        }
        _, _ -> model_to_use
      }
      // Render view to plain HTML for initial mount (SSR hydration)
      handler.start_render()
      let current_vdom = model_to_use |> state.view
      let view_registry = handler.finish_render()
      log.debug(
        "beacon.runtime",
        "Mount render registry: "
          <> int.to_string(handler.registry_size(view_registry))
          <> " handlers",
      )
      let mount_html = element.to_string(current_vdom)
      case dict.get(state.connections, conn_id) {
        Ok(subject) -> {
          // Send SSR HTML for immediate display
          process.send(subject, transport.SendMount(payload: mount_html))
          // Send model JSON — client takes over rendering from here
          let mount_serializer = case discover_model_encoder() {
            Some(f) -> Some(f)
            None -> state.serialize_model
          }
          case mount_serializer {
            Some(serialize) -> {
              let model_json = serialize(model_to_use)
              // Check model size before sending to client
              case check_model_size(model_json, "join_model_sync") {
                True -> {
                  process.send(
                    subject,
                    transport.SendModelSync(
                      model_json: model_json,
                      version: state.event_clock,
                      ack_clock: state.event_clock,
                    ),
                  )
                  // Cache the sent model JSON for future patch diffing
                  log.debug("beacon.runtime", "Sent mount + model_sync to " <> conn_id)
                }
                False -> {
                  log.error(
                    "beacon.runtime",
                    "Model too large to send on join for " <> conn_id
                      <> " — client will not receive model_sync",
                  )
                }
              }
              // Update model state, cache handler registry, store last_model_json
              // (cache even if too large — needed for future patch diffing)
              actor.continue(
                RuntimeState(
                  ..state,
                  model: model_to_use,
                  handler_registry: Some(view_registry),
                  cached_model: FullModelCache(json: Some(model_json)),
                ),
              )
            }
            None -> {
              log.warning(
                "beacon.runtime",
                "No model encoder available during mount — client won't receive model_sync. "
                  <> "Ensure beacon_codec.gleam is generated and compiled.",
              )
              actor.continue(
                RuntimeState(
                  ..state,
                  model: model_to_use,
                  handler_registry: Some(view_registry),
                ),
              )
            }
          }
        }
        Error(Nil) -> {
          log.warning(
            "beacon.runtime",
            "Client " <> conn_id <> " not found in connections for join",
          )
          actor.continue(
            RuntimeState(
              ..state,
              model: model_to_use,
              handler_registry: Some(view_registry),
            ),
          )
        }
      }
    }

    ClientEventReceived(conn_id, event_name, handler_id, event_data, target_path, clock, ops) -> {
      log.debug(
        "beacon.runtime",
        "Event from "
          <> conn_id
          <> ": "
          <> event_name
          <> " ["
          <> handler_id
          <> "] clock="
          <> int.to_string(clock)
          <> case ops {
            "" -> ""
            _ -> " +ops"
          },
      )
      // If client sent patch ops, apply them directly to the model
      // (client already ran update locally and knows the correct result).
      case ops {
        "" -> {
          // No ops — run update on server as normal
          let resolve_result = case state.handler_registry {
            Some(registry) -> {
              log.debug(
                "beacon.runtime",
                "Resolving "
                  <> handler_id
                  <> " in registry with "
                  <> int.to_string(handler.registry_size(registry))
                  <> " handlers",
              )
              handler.resolve(registry, handler_id, event_data)
            }
            None -> Error(error.RuntimeError(reason: "No handler registry"))
          }
          let resolve_result = case resolve_result {
            Ok(msg) -> Ok(msg)
            Error(_) -> {
              case state.decode_event {
                Some(decode_fn) ->
                  decode_fn(event_name, handler_id, event_data, target_path)
                None -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
              }
            }
          }
          case resolve_result {
            Ok(msg) -> {
              // run_update_for broadcasts to all clients internally
              let new_state = run_update_for(RuntimeState(..state, event_clock: clock), msg, option.Some(conn_id))
              actor.continue(new_state)
            }
            Error(err) -> {
              let err_str = error.to_string(err)
              log.warning(
                "beacon.runtime",
                "Failed to decode event from "
                  <> conn_id
                  <> ": "
                  <> err_str,
              )
              // Send error back to the client — no silent failures
              case dict.get(state.connections, conn_id) {
                Ok(transport_subject) ->
                  process.send(transport_subject, transport.SendError(reason: err_str))
                Error(Nil) -> Nil
              }
              actor.continue(state)
            }
          }
        }
        _ -> {
          // Client sent patch ops — apply to server model.
          // Also resolve the handler and run effects (for on_update side effects
          // like store writes). The update function's MODEL result is ignored
          // (the ops are authoritative), but its EFFECTS are executed.
          let resolve_result = case state.handler_registry {
            Some(registry) -> handler.resolve(registry, handler_id, event_data)
            None -> Error(error.RuntimeError(reason: "No handler registry"))
          }
          let resolve_result = case resolve_result {
            Ok(msg) -> Ok(msg)
            Error(_) -> {
              case state.decode_event {
                Some(decode_fn) ->
                  decode_fn(event_name, handler_id, event_data, target_path)
                None -> Error(error.RuntimeError(reason: "Unknown handler: " <> handler_id))
              }
            }
          }
          // Apply ops to get the correct model state FIRST
          let new_state = apply_client_ops(
            RuntimeState(..state, event_clock: clock),
            ops,
            conn_id,
          )
          // Run update with POST-ops model to get effects (store writes, etc.)
          // The update's model result is ignored — the ops are authoritative.
          // But on_update callbacks see the correct model.strokes, etc.
          case resolve_result {
            Ok(msg) -> {
              let #(_model_ignored, effects) = new_state.update(new_state.model, msg)
              run_effects_with_context(effects, new_state.self, option.Some(conn_id), new_state.connections)
            }
            Error(err) -> {
              log.warning(
                "beacon.runtime",
                "Client ops path: failed to resolve handler from "
                  <> conn_id
                  <> ": "
                  <> error.to_string(err)
                  <> " — ops applied but effects skipped",
              )
            }
          }
          actor.continue(new_state)
        }
      }
    }

    ClientEventBatchReceived(conn_id, events) -> {
      let count = list.length(events)
      log.info(
        "beacon.runtime",
        "Atomic batch from "
          <> conn_id
          <> ": "
          <> int.to_string(count)
          <> " events",
      )
      // Process events atomically: update-only for all, render once at the end.
      let #(final_state, processed) =
        list.fold(events, #(state, 0), fn(acc, evt) {
          let #(acc_state, idx) = acc
          let #(event_name, handler_id, event_data, _target_path, clock, evt_ops) = evt
          // If the last event has ops, apply them directly
          case evt_ops, idx == count - 1 {
            ops, True if ops != "" -> {
              let new_state = apply_client_ops(
                RuntimeState(..acc_state, event_clock: clock),
                ops,
                conn_id,
              )
              #(new_state, idx + 1)
            }
            _, _ -> {
              let resolve_result = case acc_state.handler_registry {
                Some(registry) ->
                  handler.resolve(registry, handler_id, event_data)
                None ->
                  Error(error.RuntimeError(reason: "No handler registry"))
              }
              let resolve_result = case resolve_result {
                Ok(msg) -> Ok(msg)
                Error(_) ->
                  case acc_state.decode_event {
                    Some(decode_fn) ->
                      decode_fn(event_name, handler_id, event_data, "")
                    None ->
                      Error(error.RuntimeError(
                        reason: "Unknown handler: " <> handler_id,
                      ))
                  }
              }
              case resolve_result {
                Ok(msg) -> {
                  let new_state =
                    RuntimeState(..acc_state, event_clock: clock)
                  case idx == count - 1 {
                    True -> #(
                      run_update_for(new_state, msg, option.Some(conn_id)),
                      idx + 1,
                    )
                    False -> #(
                      run_update_only(new_state, msg, option.Some(conn_id)),
                      idx + 1,
                    )
                  }
                }
                Error(err) -> {
                  log.warning(
                    "beacon.runtime",
                    "Event skipped in batch (idx "
                      <> int.to_string(idx)
                      <> "/"
                      <> int.to_string(count)
                      <> ", handler="
                      <> handler_id
                      <> "): "
                      <> error.to_string(err),
                  )
                  #(acc_state, idx + 1)
                }
              }
            }
          }
        })
      log.debug(
        "beacon.runtime",
        "Batch processed " <> int.to_string(processed) <> " events",
      )
      // Batch's last event already triggered broadcast via run_update_for
      actor.continue(final_state)
    }

    ClientNavigated(conn_id, path) -> {
      log.info("beacon.runtime", "Navigation: " <> conn_id <> " → " <> path)
      case state.on_route_change {
        option.Some(make_msg) -> {
          let matched_route = case route.match_path(state.route_patterns, path) {
            option.Some(r) -> r
            option.None -> route.from_path(path)
          }
          let msg = make_msg(matched_route)
          let new_state = run_update(state, msg)
          actor.continue(new_state)
        }
        option.None -> actor.continue(state)
      }
    }

    SetListenerSubject(listener, initial_subs) -> {
      log.debug("beacon.runtime", "Listener subject registered")
      actor.continue(RuntimeState(
        ..state,
        listener_subject: Some(listener),
        current_subscriptions: initial_subs,
      ))
    }

    EffectDispatched(msg) -> {
      log.info("beacon.runtime", "Effect dispatched (PubSub notification received)")
      // run_update internally broadcasts to all clients (via run_update_for)
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
  run_update_for(state, msg, option.None)
}

/// Run update with a specific connection context (for targeted effects).
/// State-over-the-wire: sends model JSON to clients. No server-side view rendering.
fn run_update_for(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: option.Option(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  // Run update function
  let #(new_model, effects) = state.update(state.model, msg)
  log.debug("beacon.runtime", "Model updated")

  // Render view to populate handler registry (needed for event resolution).
  // We don't send the HTML — client renders from model JSON.
  handler.start_render()
  let new_registry = case rescue(fn() { new_model |> state.view }) {
    Ok(_vdom) -> handler.finish_render()
    Error(reason) -> {
      log.error("beacon.runtime", "View rendering failed: " <> reason)
      let _ = handler.finish_render()
      // Keep old registry if view crashes
      case state.handler_registry {
        Some(r) -> r
        None -> handler.finish_render()
      }
    }
  }

  // State-over-the-wire: send model JSON to all clients (as patches when possible).
  // Try per-substate diffing first (only diffs changed substates).
  // Falls back to full-model diff if no substate encoders available.
  let serializer = case discover_model_encoder() {
    Some(f) -> Some(f)
    None -> state.serialize_model
  }
  let new_model_json = case serializer {
    Some(serialize) -> {
      let json = serialize(new_model)
      // Check model size bounds before broadcasting
      case check_model_size(json, "run_update") {
        True -> Some(json)
        False -> None
      }
    }
    None -> None
  }
  let broadcast_state =
    RuntimeState(
      ..state,
      model: new_model,
      handler_registry: Some(new_registry),
    )
  // Attempt per-substate broadcast, fall back to full-model broadcast
  let new_cached =
    broadcast_with_substates(broadcast_state, new_model, new_model_json)
  let new_state =
    RuntimeState(
      ..broadcast_state,
      cached_model: new_cached,
    )

  // Execute effects — pass connection context for targeted sends
  run_effects_with_context(effects, state.self, conn_id, state.connections)

  // Diff dynamic subscriptions after model change
  update_dynamic_subscriptions(new_state)
}

/// After an update, diff dynamic subscriptions and apply changes.
fn update_dynamic_subscriptions(
  state: RuntimeState(model, msg),
) -> RuntimeState(model, msg) {
  case state.dynamic_subscriptions, state.listener_subject {
    Some(compute_subs), Some(listener) -> {
      let new_subs = compute_subs(state.model)
      // Find topics to subscribe/unsubscribe
      let to_subscribe =
        list.filter(new_subs, fn(t) {
          !list.contains(state.current_subscriptions, t)
        })
      let to_unsubscribe =
        list.filter(state.current_subscriptions, fn(t) {
          !list.contains(new_subs, t)
        })
      // Apply changes
      list.each(to_subscribe, fn(t) {
        process.send(listener, SubscribeTo(t))
      })
      list.each(to_unsubscribe, fn(t) {
        process.send(listener, UnsubscribeFrom(t))
      })
      case list.length(to_subscribe) + list.length(to_unsubscribe) > 0 {
        True ->
          log.info(
            "beacon.subscription",
            "Subscriptions updated: +"
              <> int.to_string(list.length(to_subscribe))
              <> " -"
              <> int.to_string(list.length(to_unsubscribe)),
          )
        False -> Nil
      }
      RuntimeState(..state, current_subscriptions: new_subs)
    }
    _, _ -> state
  }
}

/// Run update WITHOUT rendering — for atomic batch processing.
/// Only updates the model and executes effects. Rendering happens once after the batch.
fn run_update_only(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: option.Option(transport.ConnectionId),
) -> RuntimeState(model, msg) {
  let #(new_model, effects) = state.update(state.model, msg)
  run_effects_with_context(effects, state.self, conn_id, state.connections)
  RuntimeState(..state, model: new_model)
}

/// Safely execute a function, catching crashes.
@external(erlang, "beacon_runtime_ffi", "rescue")
fn rescue(f: fn() -> a) -> Result(a, String)

/// Auto-discover a model encoder from the beacon_codec module.
/// The build tool generates beacon_codec.gleam with encode_model/1.
/// If the module exists, returns Some(encoder). Otherwise None.
fn discover_model_encoder() -> Option(fn(model) -> String) {
  case try_load_codec_encoder() {
    Ok(encoder) -> {
      log.info(
        "beacon.runtime",
        "Auto-discovered model encoder from beacon_codec",
      )
      Some(encoder)
    }
    Error(_) -> {
      log.debug("beacon.runtime", "No beacon_codec encoder available")
      None
    }
  }
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_encoder")
fn try_load_codec_encoder() -> Result(fn(model) -> String, Nil)

/// Try per-substate broadcast, fall back to full-model.
/// Returns the new CachedModelState to store for future diffs.
fn broadcast_with_substates(
  state: RuntimeState(model, msg),
  new_model: model,
  new_model_json: Option(String),
) -> CachedModelState {
  // Try to load substate names — if available, use per-substate diffing
  case try_load_substate_names() {
    Ok(names) if names != [] -> {
      // Load flat fields encoder
      let flat_encoder = case try_load_flat_encoder() {
        Ok(f) -> Some(f)
        Error(_) -> None
      }
      // Build per-substate JSON map
      let new_substate_jsons =
        list.fold(names, dict.new(), fn(acc, name) {
          case try_load_substate_encoder(name) {
            Ok(encoder) -> {
              let json = encoder(new_model)
              dict.insert(acc, name, json)
            }
            Error(_) -> acc
          }
        })
      // Build flat fields JSON
      let new_flat_json = case flat_encoder {
        Some(f) -> Some(f(new_model))
        None -> None
      }
      // Get old cached substates
      let #(old_substates, old_flat) = case state.cached_model {
        SubstateCache(substate_jsons: old_s, flat_fields_json: old_f, ..) ->
          #(old_s, old_f)
        _ -> #(dict.new(), None)
      }
      // Diff each substate independently — skip unchanged ones
      let substate_ops =
        list.flat_map(names, fn(name) {
          let new_json = case dict.get(new_substate_jsons, name) {
            Ok(j) -> j
            Error(_) -> "null"
          }
          case dict.get(old_substates, name) {
            Ok(old_json) if old_json == new_json -> {
              // UNCHANGED — skip diff entirely (the optimization!)
              []
            }
            Ok(old_json) -> {
              // Changed — diff just this substate (wrap in object for path context)
              let old_wrapped = "{\"" <> name <> "\":" <> old_json <> "}"
              let new_wrapped = "{\"" <> name <> "\":" <> new_json <> "}"
              let ops = patch.diff(old_wrapped, new_wrapped)
              case patch.is_empty(ops) {
                True -> []
                False -> [ops]
              }
            }
            Error(_) -> {
              // First time for this substate — include as replace
              let old_wrapped = "{\"" <> name <> "\":null}"
              let new_wrapped = "{\"" <> name <> "\":" <> new_json <> "}"
              let ops = patch.diff(old_wrapped, new_wrapped)
              case patch.is_empty(ops) {
                True -> []
                False -> [ops]
              }
            }
          }
        })
      // Diff flat fields
      let flat_ops = case new_flat_json, old_flat {
        Some(new_f), Some(old_f) if new_f == old_f -> []
        Some(new_f), Some(old_f) -> {
          let ops = patch.diff(old_f, new_f)
          case patch.is_empty(ops) {
            True -> []
            False -> [ops]
          }
        }
        Some(new_f), None -> {
          let ops = patch.diff("{}", new_f)
          case patch.is_empty(ops) {
            True -> []
            False -> [ops]
          }
        }
        _, _ -> []
      }
      // Merge all ops and broadcast
      let all_op_strings = list.append(substate_ops, flat_ops)
      case all_op_strings {
        [] -> {
          log.debug("beacon.runtime", "Substates: all unchanged, skipping broadcast")
          Nil
        }
        _ -> {
          // Merge multiple ops JSON arrays into one
          let merged = merge_ops_json(all_op_strings)
          log.debug("beacon.runtime", "Substates: broadcasting merged patch")
          dict.each(state.connections, fn(_conn_id, subject) {
            process.send(
              subject,
              transport.SendPatch(
                ops_json: merged,
                version: state.event_clock,
                ack_clock: state.event_clock,
              ),
            )
          })
        }
      }
      // Return SubstateCache for next diff
      SubstateCache(
        full_json: new_model_json,
        substate_jsons: new_substate_jsons,
        flat_fields_json: new_flat_json,
      )
    }
    _ -> {
      // No substates — fall back to full-model diff
      broadcast_model_sync_with_json(state, new_model_json)
      case new_model_json {
        Some(json) -> FullModelCache(json: Some(json))
        None -> state.cached_model
      }
    }
  }
}

/// Merge multiple JSON ops arrays into a single array.
/// Each input is a JSON string like "[{...}, {...}]".
/// Output is a single merged array.
fn merge_ops_json(ops_list: List(String)) -> String {
  case ops_list {
    [] -> "[]"
    [single] -> single
    _ -> {
      // Use the Erlang FFI to merge JSON arrays
      merge_ops_json_ffi(ops_list)
    }
  }
}

@external(erlang, "beacon_patch_ffi", "merge_ops_json")
fn merge_ops_json_ffi(ops_list: List(String)) -> String

/// Model JSON size warning threshold: 1MB.
const model_size_warn_bytes = 1_048_576

/// Model JSON size hard limit: 5MB. Broadcasts are skipped above this.
const model_size_max_bytes = 5_242_880

/// Check model JSON size. Warn at 1MB, reject at 5MB.
/// Returns True if the model is within bounds and safe to broadcast,
/// False if it exceeds the hard limit and should be skipped.
fn check_model_size(model_json: String, context: String) -> Bool {
  let size = string.byte_size(model_json)
  case size > model_size_max_bytes {
    True -> {
      log.error(
        "beacon.runtime",
        "Model JSON exceeds 5MB ("
          <> int.to_string(size)
          <> " bytes) in "
          <> context
          <> " — broadcast skipped to prevent OOM",
      )
      False
    }
    False -> {
      case size > model_size_warn_bytes {
        True -> {
          log.warning(
            "beacon.runtime",
            "Model JSON is large ("
              <> int.to_string(size)
              <> " bytes) in "
              <> context
              <> " — consider reducing model size",
          )
          True
        }
        False -> True
      }
    }
  }
}

/// Broadcast model state with a pre-serialized JSON string.
/// Diffs against cached_model to send patches when possible.
fn broadcast_model_sync_with_json(
  state: RuntimeState(model, msg),
  new_model_json: Option(String),
) -> Nil {
  case new_model_json {
    Some(model_json) -> {
      // Check model size before broadcasting
      case check_model_size(model_json, "broadcast_model_sync") {
        False -> Nil
        True -> {
          // Extract the old JSON from the cached model state
          let old_json = case state.cached_model {
            FullModelCache(json: j) -> j
            SubstateCache(full_json: j, ..) -> j
          }
          case old_json {
            Some(old_json) -> {
              let ops_json = patch.diff(old_json, model_json)
              case patch.is_empty(ops_json) {
                True -> {
                  log.debug("beacon.runtime", "Model unchanged, skipping broadcast")
                  Nil
                }
                False -> {
                  log.debug("beacon.runtime", "Broadcasting patch to all clients")
                  dict.each(state.connections, fn(_conn_id, subject) {
                    process.send(
                      subject,
                      transport.SendPatch(
                        ops_json: ops_json,
                        version: state.event_clock,
                        ack_clock: state.event_clock,
                      ),
                    )
                  })
                }
              }
            }
            None -> {
              log.debug("beacon.runtime", "No previous model, sending full model_sync")
              dict.each(state.connections, fn(_conn_id, subject) {
                process.send(
                  subject,
                  transport.SendModelSync(
                    model_json: model_json,
                    version: state.event_clock,
                    ack_clock: state.event_clock,
                  ),
                )
              })
            }
          }
        }
      }
    }
    None -> {
      // No model encoder — re-render view and send HTML mount to all clients.
      // This is the server-rendering mode used by routed apps without per-route codecs.
      log.debug(
        "beacon.runtime",
        "No model encoder — broadcasting HTML mount to all clients",
      )
      handler.start_render()
      case rescue(fn() { state.model |> state.view }) {
        Ok(vdom) -> {
          let _ = handler.finish_render()
          let mount_html = element.to_string(vdom)
          dict.each(state.connections, fn(_conn_id, subject) {
            process.send(
              subject,
              transport.SendMount(payload: mount_html),
            )
          })
        }
        Error(reason) -> {
          let _ = handler.finish_render()
          log.error("beacon.runtime", "View rendering failed in mount broadcast: " <> reason)
          Nil
        }
      }
    }
  }
}

/// Maximum number of patch operations allowed in a single client message.
/// Prevents clients from sending unbounded arrays that consume server memory.
const max_ops_per_message = 1000

/// Apply client-sent patch operations to the server model.
/// The client already ran the update locally and sends the diff.
/// Server applies the ops to stay in sync without re-running update.
fn apply_client_ops(
  state: RuntimeState(model, msg),
  ops_json: String,
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  // Enforce ops count limit to prevent memory exhaustion from malicious clients
  let ops_count = patch.count_ops(ops_json)
  case ops_count > max_ops_per_message {
    True -> {
      log.warning(
        "beacon.runtime",
        "Rejecting patch with " <> int.to_string(ops_count)
        <> " ops from " <> conn_id
        <> " (max " <> int.to_string(max_ops_per_message) <> ")",
      )
      state
    }
    False -> apply_client_ops_inner(state, ops_json, conn_id)
  }
}

/// Inner implementation of apply_client_ops, after ops count validation.
fn apply_client_ops_inner(
  state: RuntimeState(model, msg),
  ops_json: String,
  conn_id: transport.ConnectionId,
) -> RuntimeState(model, msg) {
  log.info("beacon.runtime", "Applying client ops from " <> conn_id)
  // Serialize current model to JSON
  let serializer = case discover_model_encoder() {
    Some(f) -> Some(f)
    None -> state.serialize_model
  }
  case serializer {
    Some(serialize) -> {
      let old_json = serialize(state.model)
      // Apply the client's patch ops to produce new model JSON
      case patch.apply_ops(old_json, ops_json) {
        Ok(new_json) -> {
          // Decode new model from the patched JSON
          case discover_model_decoder() {
            Some(decode_fn) -> {
              case decode_fn(new_json) {
                Ok(new_model) -> {
                  log.info("beacon.runtime", "Client ops applied successfully")
                  // Re-render view to keep handler registry fresh
                  handler.start_render()
                  let new_registry = case rescue(fn() { new_model |> state.view }) {
                    Ok(_vdom) -> handler.finish_render()
                    Error(reason) -> {
                      log.error("beacon.runtime", "View rendering failed after ops: " <> reason)
                      let _ = handler.finish_render()
                      case state.handler_registry {
                        Some(r) -> r
                        None -> handler.finish_render()
                      }
                    }
                  }
                  let new_state = RuntimeState(
                    ..state,
                    model: new_model,
                    handler_registry: Some(new_registry),
                    cached_model: FullModelCache(json: Some(new_json)),
                  )
                  // Broadcast the same ops to other clients
                  let _ = broadcast_ops_to_others(new_state, ops_json, conn_id)
                  // Update dynamic subscriptions after model change
                  update_dynamic_subscriptions(new_state)
                }
                Error(reason) -> {
                  log.error(
                    "beacon.runtime",
                    "Failed to decode model after applying ops: " <> reason,
                  )
                  state
                }
              }
            }
            None -> {
              log.warning(
                "beacon.runtime",
                "No model decoder — cannot apply client ops. Falling back to event processing.",
              )
              state
            }
          }
        }
        Error(reason) -> {
          log.error(
            "beacon.runtime",
            "Failed to apply client ops: " <> reason,
          )
          state
        }
      }
    }
    None -> {
      log.warning(
        "beacon.runtime",
        "No serializer — cannot apply client ops",
      )
      state
    }
  }
}

/// Send patch ops to all clients EXCEPT the one that sent them.
/// The sending client already applied the ops locally (optimistic update).
fn broadcast_ops_to_others(
  state: RuntimeState(model, msg),
  ops_json: String,
  exclude_conn_id: transport.ConnectionId,
) -> Nil {
  dict.each(state.connections, fn(conn_id, subject) {
    case conn_id == exclude_conn_id {
      True -> Nil
      False ->
        process.send(
          subject,
          transport.SendPatch(
            ops_json: ops_json,
            version: state.event_clock,
            ack_clock: state.event_clock,
          ),
        )
    }
  })
}

/// Auto-discover a model decoder from the beacon_codec module.
/// The build tool generates beacon_codec.gleam with decode_model/1.
fn discover_model_decoder() -> Option(fn(String) -> Result(model, String)) {
  case try_load_codec_decoder() {
    Ok(decoder) -> {
      log.debug(
        "beacon.runtime",
        "Auto-discovered model decoder from beacon_codec",
      )
      Some(decoder)
    }
    Error(_) -> {
      log.debug("beacon.runtime", "No beacon_codec decoder available")
      None
    }
  }
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_decoder")
fn try_load_codec_decoder() -> Result(fn(String) -> Result(model, String), Nil)

/// Discover substate names from beacon_codec.
@external(erlang, "beacon_runtime_ffi", "try_load_substate_names")
fn try_load_substate_names() -> Result(List(String), Nil)

/// Discover a per-substate encoder from beacon_codec.
@external(erlang, "beacon_runtime_ffi", "try_load_substate_encoder")
fn try_load_substate_encoder(
  name: String,
) -> Result(fn(model) -> String, Nil)

/// Discover the flat fields encoder from beacon_codec.
@external(erlang, "beacon_runtime_ffi", "try_load_flat_encoder")
fn try_load_flat_encoder() -> Result(fn(model) -> String, Nil)

/// Execute effects by providing a dispatch function that sends messages
/// back to the runtime actor.
fn run_effects(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
) -> Nil {
  run_effects_with_context(effects, self, option.None, dict.new())
}

/// Execute effects with connection context for targeted sends (redirects).
fn run_effects_with_context(
  effects: Effect(msg),
  self: Subject(RuntimeMessage(msg)),
  conn_id: option.Option(transport.ConnectionId),
  connections: Dict(transport.ConnectionId, Subject(transport.InternalMessage)),
) -> Nil {
  case effect.is_none(effects) {
    True -> Nil
    False -> {
      log.debug("beacon.runtime", "Executing effects")
      // Store connection context so redirect can target the right client
      case conn_id {
        option.Some(cid) -> {
          case dict.get(connections, cid) {
            Ok(subject) ->
              store_redirect_target(subject)
            Error(Nil) -> {
              log.debug(
                "beacon.runtime",
                "Connection " <> cid <> " not found for redirect target storage",
              )
              Nil
            }
          }
        }
        option.None -> {
          log.debug(
            "beacon.runtime",
            "No connection context for effects (broadcast or init)",
          )
          Nil
        }
      }
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
        transport.ClientEvent(name, handler_id, data, target_path, clock, ops) -> {
          process.send(
            runtime,
            ClientEventReceived(
              conn_id: conn_id,
              event_name: name,
              handler_id: handler_id,
              event_data: data,
              target_path: target_path,
              clock: clock,
              ops: ops,
            ),
          )
        }
        transport.ClientJoin(token, path) -> {
          process.send(
            runtime,
            ClientJoined(conn_id: conn_id, token: token, path: path),
          )
        }
        transport.ClientNavigate(path) -> {
          process.send(
            runtime,
            ClientNavigated(conn_id: conn_id, path: path),
          )
        }
        transport.ClientEventBatch(events) -> {
          // Atomic batch: all events processed, single render at end.
          let event_tuples =
            list.filter_map(events, fn(evt) {
              case evt {
                transport.ClientEvent(name, handler_id, data, target_path, clock, ops) ->
                  Ok(#(name, handler_id, data, target_path, clock, ops))
                _ -> Error(Nil)
              }
            })
          process.send(
            runtime,
            ClientEventBatchReceived(
              conn_id: conn_id,
              events: event_tuples,
            ),
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
    ws_auth: option.None,
    ssr_factory: option.None,
    security_limits: transport.default_security_limits(),
    api_handler: option.None,
  )
}

/// Start a runtime for a specific connection and return type-erased handler closures.
/// This is the core helper used by both single-app and file-based routing modes.
/// Each call spawns a new runtime actor, registers the connection, and returns:
/// - on_event: forwards ClientMessages to the runtime
/// - shutdown: kills the runtime process
///
/// Types are erased at the function boundary — the returned closures work
/// with untyped ConnectionId + ClientMessage regardless of Model/Msg types.
pub fn start_and_connect(
  config: RuntimeConfig(model, msg),
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
) -> Result(
  #(
    fn(transport.ConnectionId, transport.ClientMessage) -> Nil,
    fn() -> Nil,
  ),
  error.BeaconError,
) {
  start_and_connect_with_request(config, conn_id, transport_subject, option.None)
}

/// Start a per-connection runtime with access to the HTTP request.
/// When `req` is Some and `config.init_from_request` is set, uses the
/// request-aware init instead of the static init function.
pub fn start_and_connect_with_request(
  config: RuntimeConfig(model, msg),
  conn_id: transport.ConnectionId,
  transport_subject: process.Subject(transport.InternalMessage),
  req: option.Option(request.Request(server.Connection)),
) -> Result(
  #(
    fn(transport.ConnectionId, transport.ClientMessage) -> Nil,
    fn() -> Nil,
  ),
  error.BeaconError,
) {
  log.info(
    "beacon.runtime",
    "Spawning runtime for " <> conn_id,
  )
  // Use init_from_request if both the request and the callback are available
  let effective_config = case req, config.init_from_request {
    Some(r), Some(init_fn) -> {
      log.debug("beacon.runtime", "Using request-aware init for " <> conn_id)
      RuntimeConfig(..config, init: fn() { init_fn(r) })
    }
    _, _ -> config
  }
  case start(effective_config) {
    Ok(runtime_subject) -> {
      // Register this connection with the new runtime
      process.send(
        runtime_subject,
        ClientConnected(conn_id: conn_id, subject: transport_subject),
      )
      // Return per-connection event and shutdown handlers
      let on_event = fn(_cid: transport.ConnectionId, client_msg) {
        forward_client_message(runtime_subject, conn_id, client_msg)
      }
      let shutdown = fn() {
        log.info("beacon.runtime", "Shutting down runtime for " <> conn_id)
        process.send(runtime_subject, Shutdown)
      }
      Ok(#(on_event, shutdown))
    }
    Error(err) -> {
      log.error(
        "beacon.runtime",
        "Failed to spawn runtime for " <> conn_id <> ": " <> error.to_string(err),
      )
      Error(err)
    }
  }
}

/// Forward a client message to a runtime actor.
/// Translates transport.ClientMessage variants into RuntimeMessage variants.
fn forward_client_message(
  runtime_subject: Subject(RuntimeMessage(msg)),
  conn_id: transport.ConnectionId,
  client_msg: transport.ClientMessage,
) -> Nil {
  case client_msg {
    transport.ClientEvent(name, handler_id, data, target_path, clock, ops) ->
      process.send(
        runtime_subject,
        ClientEventReceived(
          conn_id: conn_id,
          event_name: name,
          handler_id: handler_id,
          event_data: data,
          target_path: target_path,
          clock: clock,
          ops: ops,
        ),
      )
    transport.ClientJoin(token, path) ->
      process.send(
        runtime_subject,
        ClientJoined(conn_id: conn_id, token: token, path: path),
      )
    transport.ClientNavigate(path) ->
      process.send(
        runtime_subject,
        ClientNavigated(conn_id: conn_id, path: path),
      )
    transport.ClientEventBatch(events) -> {
      let event_tuples =
        list.filter_map(events, fn(evt) {
          case evt {
            transport.ClientEvent(
              name,
              handler_id,
              data,
              target_path,
              clock,
              ops,
            ) ->
              Ok(#(name, handler_id, data, target_path, clock, ops))
            _ -> Error(Nil)
          }
        })
      process.send(
        runtime_subject,
        ClientEventBatchReceived(
          conn_id: conn_id,
          events: event_tuples,
        ),
      )
    }
    transport.ClientHeartbeat -> Nil
  }
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
      req: request.Request(server.Connection),
    ) {
      case start_and_connect_with_request(config, conn_id, transport_subject, option.Some(req)) {
        Ok(#(on_event, shutdown)) -> {
          let on_disconnect = fn(_cid: transport.ConnectionId) {
            shutdown()
          }
          #(on_event, on_disconnect)
        }
        Error(err) -> {
          log.error("beacon.runtime", "Failed to start per-connection runtime: " <> error.to_string(err))
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
    ws_auth: option.None,
    ssr_factory: option.None,
    security_limits: transport.default_security_limits(),
    api_handler: option.None,
  )
}

/// Commands sent to the PubSub listener process.
pub type ListenerCommand {
  /// Subscribe to a new PubSub topic.
  SubscribeTo(topic: String)
  /// Unsubscribe from a PubSub topic.
  UnsubscribeFrom(topic: String)
  /// Shut down the listener process.
  ShutdownListener
}

/// Result from the listener's receive FFI.
type ListenerReceiveResult {
  /// A command was received from the runtime.
  CommandReceived(command: ListenerCommand)
  /// A PubSub notification was received on a topic.
  NotificationReceived(topic: String)
  /// Timeout — no message within the window.
  ReceiveTimeout
}

/// Start the PubSub listener — spawns a process that handles
/// dynamic subscription commands and forwards notifications.
/// Returns a Subject for sending commands to the listener.
fn start_pubsub_listener(
  runtime_subject: Subject(RuntimeMessage(msg)),
  on_notify: fn(String) -> msg,
  topics: List(String),
) -> Subject(ListenerCommand) {
  // Use a subject on the CALLER to receive the listener's command subject
  let reply_subject = process.new_subject()
  let _ =
    process.spawn(fn() {
      // Create the command subject HERE — inside the spawned process —
      // so it's owned by this process and receives messages correctly.
      let command_subject = process.new_subject()
      // Send it back to the caller
      process.send(reply_subject, command_subject)

      log.info("beacon.subscription", "Listener process spawned")
      list.each(topics, fn(t) {
        log.info("beacon.subscription", "Subscribing to: " <> t)
        pubsub.subscribe(t)
      })
      log.info(
        "beacon.subscription",
        "Listener started with "
          <> int.to_string(list.length(topics))
          <> " initial topics",
      )
      listener_loop(runtime_subject, command_subject, on_notify)
    })
  // INVARIANT: The listener process was just spawned and MUST send its
  // command_subject back immediately. If this times out (5s), the listener
  // failed to start — a fatal configuration error. Crash is intentional:
  // the runtime cannot function without its PubSub listener.
  let assert Ok(command_subject) =
    process.receive(reply_subject, 5000)
  command_subject
}

/// Listener receive loop — handles commands and PubSub notifications.
fn listener_loop(
  runtime_subject: Subject(RuntimeMessage(msg)),
  command_subject: Subject(ListenerCommand),
  on_notify: fn(String) -> msg,
) -> Nil {
  case receive_with_commands(command_subject, 60_000) {
    CommandReceived(SubscribeTo(topic)) -> {
      pubsub.subscribe(topic)
      log.debug("beacon.subscription", "Subscribed to: " <> topic)
      listener_loop(runtime_subject, command_subject, on_notify)
    }
    CommandReceived(UnsubscribeFrom(topic)) -> {
      pubsub.unsubscribe(topic)
      log.debug("beacon.subscription", "Unsubscribed from: " <> topic)
      listener_loop(runtime_subject, command_subject, on_notify)
    }
    CommandReceived(ShutdownListener) -> {
      log.info("beacon.subscription", "Listener shutting down")
      Nil
    }
    NotificationReceived(topic) -> {
      let msg = on_notify(topic)
      process.send(runtime_subject, EffectDispatched(message: msg))
      listener_loop(runtime_subject, command_subject, on_notify)
    }
    ReceiveTimeout -> {
      listener_loop(runtime_subject, command_subject, on_notify)
    }
  }
}

@external(erlang, "beacon_subscription_ffi", "receive_with_commands")
fn receive_with_commands(
  subject: Subject(ListenerCommand),
  timeout: Int,
) -> ListenerReceiveResult

@external(erlang, "beacon_runtime_ffi", "store_redirect_target")
fn store_redirect_target(subject: process.Subject(transport.InternalMessage)) -> Nil

@external(erlang, "beacon_runtime_ffi", "get_redirect_target")
pub fn get_redirect_target() -> option.Option(process.Subject(transport.InternalMessage))

/// Attempt to recover model state from a session token.
/// Token payload contains serialized model data.
/// Validates both HMAC signature and token age (max_age_seconds).
fn recover_model_from_token(
  token: String,
  secret_key: String,
  deserialize: fn(String) -> Result(model, String),
  max_age_seconds: Int,
) -> Result(model, String) {
  let secret = bit_array.from_string(secret_key)
  case crypto.verify_signed_message(token, secret) {
    Ok(payload_bits) -> {
      case bit_array.to_string(payload_bits) {
        Ok(payload_str) -> {
          // Validate token age before deserializing model data
          case validate_token_age(payload_str, max_age_seconds) {
            Error(reason) -> {
              log.warning(
                "beacon.runtime",
                "Token age validation failed: " <> reason,
              )
              Error(reason)
            }
            Ok(Nil) -> {
              // Payload is JSON: {"ts":..., "v":1, "model":"..."}
              // Extract the "model" field
              case extract_model_data(payload_str) {
                Ok(model_data) -> deserialize(model_data)
                Error(reason) -> Error(reason)
              }
            }
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

/// Default maximum age for state recovery tokens: 24 hours.
const default_token_max_age_seconds = 86_400

/// Validate that a token payload has not expired.
/// Checks the "ts" field against the current time and max_age_seconds.
fn validate_token_age(
  payload: String,
  max_age_seconds: Int,
) -> Result(Nil, String) {
  case
    json.parse(payload, {
      use ts <- decode.optional_field("ts", 0, decode.int)
      decode.success(ts)
    })
  {
    Ok(0) -> Error("No timestamp in token")
    Ok(ts) -> {
      let now = system_time_seconds()
      let age = now - ts
      case age > max_age_seconds {
        True ->
          Error(
            "State token expired (age: "
            <> int.to_string(age)
            <> "s, max: "
            <> int.to_string(max_age_seconds)
            <> "s)",
          )
        False -> Ok(Nil)
      }
    }
    Error(_) -> Error("Failed to parse token timestamp")
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
import gleam/string
