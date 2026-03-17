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
import beacon/route
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
  /// A batch of events to process atomically (all updates, one render).
  /// Used when LOCAL events are replayed before a MODEL event.
  ClientEventBatchReceived(
    conn_id: transport.ConnectionId,
    events: List(#(String, String, String, String, Int)),
  )
  /// A client navigated to a new URL path.
  ClientNavigated(conn_id: transport.ConnectionId, path: String)
  /// A client called a server function.
  ClientCalledServerFn(
    conn_id: transport.ConnectionId,
    name: String,
    args: String,
    call_id: String,
  )
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
    /// Route patterns for URL matching.
    route_patterns: List(route.RoutePattern),
    /// Called when URL changes — produces a Msg for the update loop.
    on_route_change: option.Option(fn(route.Route) -> msg),
    /// Registered server functions.
    server_fns: Dict(String, fn(String) -> Result(String, String)),
    /// Subject for sending commands to the PubSub listener process.
    listener_subject: Option(Subject(ListenerCommand)),
    /// Current set of dynamic subscriptions (for diffing).
    current_subscriptions: List(String),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
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
    /// Registered server functions: name → handler(args) → Result(result, error).
    server_fns: Dict(String, fn(String) -> Result(String, String)),
    /// Dynamic subscription function: given the current model, returns
    /// the set of topics this runtime should be subscribed to.
    /// Called after every update. The framework diffs against current subscriptions.
    dynamic_subscriptions: option.Option(fn(model) -> List(String)),
    /// Called when a PubSub notification arrives on a dynamically subscribed topic.
    /// Receives the topic string so the handler can distinguish between sources.
    on_notify: option.Option(fn(String) -> msg),
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
          serialize_model: case config.serialize_model {
            Some(f) -> Some(f)
            None -> discover_model_encoder()
          },
          deserialize_model: config.deserialize_model,
          secret_key: "",
          route_patterns: config.route_patterns,
          on_route_change: config.on_route_change,
          server_fns: config.server_fns,
          listener_subject: None,
          current_subscriptions: [],
          dynamic_subscriptions: config.dynamic_subscriptions,
          on_notify: config.on_notify,
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
          let new_state = run_update_for(RuntimeState(..state, event_clock: clock), msg, option.Some(conn_id))
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
          let #(event_name, handler_id, event_data, _target_path, clock) = evt
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
                // Last event: full update + render + broadcast patch
                True -> #(
                  run_update_for(new_state, msg, option.Some(conn_id)),
                  idx + 1,
                )
                // Intermediate: update only, no render
                False -> #(
                  run_update_only(new_state, msg, option.Some(conn_id)),
                  idx + 1,
                )
              }
            }
            Error(_) -> #(acc_state, idx + 1)
          }
        })
      let _ = processed
      send_model_sync(final_state, conn_id)
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

    ClientCalledServerFn(conn_id, name, args, call_id) -> {
      log.info("beacon.runtime", "Server fn: " <> name <> " [" <> call_id <> "]")
      case dict.get(state.server_fns, name) {
        Ok(handler) -> {
          let #(result, ok) = case handler(args) {
            Ok(r) -> #(r, True)
            Error(e) -> #(e, False)
          }
          case dict.get(state.connections, conn_id) {
            Ok(subject) ->
              process.send(
                subject,
                transport.SendServerFnResult(
                  call_id: call_id,
                  result: result,
                  ok: ok,
                ),
              )
            Error(Nil) -> Nil
          }
        }
        Error(Nil) -> {
          case dict.get(state.connections, conn_id) {
            Ok(subject) ->
              process.send(
                subject,
                transport.SendServerFnResult(
                  call_id: call_id,
                  result: "Unknown server function: " <> name,
                  ok: False,
                ),
              )
            Error(Nil) -> Nil
          }
        }
      }
      actor.continue(state)
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
      let new_state = run_update(state, msg)
      // Send model_sync to ALL connected clients so their client-side
      // models stay in sync (e.g., PubSub watcher updates like StrokesUpdated)
      broadcast_model_sync(new_state)
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
fn run_update_for(
  state: RuntimeState(model, msg),
  msg: msg,
  conn_id: option.Option(transport.ConnectionId),
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

  // Execute effects — pass connection context for targeted sends
  run_effects_with_context(effects, state.self, conn_id, state.connections)

  // Return updated state with new Rendered and handler registry cached
  let new_state =
    RuntimeState(
      ..state,
      model: new_model,
      previous_rendered: new_rendered,
      handler_registry: new_registry,
    )
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
    Error(_) -> None
  }
}

@external(erlang, "beacon_runtime_ffi", "try_load_codec_encoder")
fn try_load_codec_encoder() -> Result(fn(model) -> String, Nil)

/// Send authoritative model state to ALL connected clients.
/// Used after PubSub/watcher updates where no specific conn_id triggered the change.
fn broadcast_model_sync(state: RuntimeState(model, msg)) -> Nil {
  case state.serialize_model {
    Some(serialize) -> {
      let model_json = serialize(state.model)
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
    None -> Nil
  }
}

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
            Error(Nil) -> Nil
          }
        }
        option.None -> Nil
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
        transport.ClientNavigate(path) -> {
          process.send(
            runtime,
            ClientNavigated(conn_id: conn_id, path: path),
          )
        }
        transport.ClientServerFn(name, args, call_id) -> {
          process.send(
            runtime,
            ClientCalledServerFn(
              conn_id: conn_id,
              name: name,
              args: args,
              call_id: call_id,
            ),
          )
        }
        transport.ClientEventBatch(events) -> {
          // Atomic batch: all events processed, single render at end.
          let event_tuples =
            list.filter_map(events, fn(evt) {
              case evt {
                transport.ClientEvent(name, handler_id, data, target_path, clock) ->
                  Ok(#(name, handler_id, data, target_path, clock))
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
              transport.ClientNavigate(path) ->
                process.send(
                  runtime_subject,
                  ClientNavigated(conn_id: conn_id, path: path),
                )
              transport.ClientServerFn(name, args, call_id) ->
                process.send(
                  runtime_subject,
                  ClientCalledServerFn(
                    conn_id: conn_id,
                    name: name,
                    args: args,
                    call_id: call_id,
                  ),
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
                      ) ->
                        Ok(#(name, handler_id, data, target_path, clock))
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
    ws_auth: option.None,
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
  // Wait for the listener to send us its command subject
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
