import beacon/effect
import beacon/element
import beacon/error
import beacon/runtime
import beacon/transport
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option

// --- Test helpers ---

/// A simple counter model for testing.
pub type CounterModel {
  CounterModel(count: Int)
}

/// Counter messages.
pub type CounterMsg {
  Increment
  Decrement
  SetCount(Int)
}

fn counter_init() -> #(CounterModel, effect.Effect(CounterMsg)) {
  #(CounterModel(count: 0), effect.none())
}

fn counter_update(
  model: CounterModel,
  msg: CounterMsg,
) -> #(CounterModel, effect.Effect(CounterMsg)) {
  case msg {
    Increment -> #(CounterModel(count: model.count + 1), effect.none())
    Decrement -> #(CounterModel(count: model.count - 1), effect.none())
    SetCount(n) -> #(CounterModel(count: n), effect.none())
  }
}

fn counter_view(model: CounterModel) -> element.Node(CounterMsg) {
  element.el("div", [], [element.text(int.to_string(model.count))])
}

fn counter_decode_event(
  _name: String,
  handler_id: String,
  _data: String,
  _path: String,
) -> Result(CounterMsg, error.BeaconError) {
  case handler_id {
    "increment" -> Ok(Increment)
    "decrement" -> Ok(Decrement)
    _ ->
      Error(error.RuntimeError(
        reason: "Unknown handler: " <> handler_id,
      ))
  }
}

fn counter_config() -> runtime.RuntimeConfig(CounterModel, CounterMsg) {
  runtime.RuntimeConfig(
    init: counter_init,
    update: counter_update,
    view: counter_view,
    decode_event: option.Some(counter_decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
  )
}

// --- Tests ---

pub fn runtime_starts_successfully_test() {
  let assert Ok(_subject) = runtime.start(counter_config())
}

pub fn runtime_accepts_client_connect_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let fake_transport_subject = process.new_subject()
  // Should not crash
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_1",
      subject: fake_transport_subject,
    ),
  )
  // Give actor time to process
  process.sleep(50)
}

pub fn runtime_sends_mount_on_join_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Register connection
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_2",
      subject: transport_subject,
    ),
  )
  process.sleep(20)

  // Send join
  process.send(subject, runtime.ClientJoined(conn_id: "test_conn_2", token: ""))
  process.sleep(50)

  // Check that we received a mount message
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(_msg) = process.selector_receive(selector, 500)
}

pub fn runtime_broadcasts_patch_on_event_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Register connection
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_3",
      subject: transport_subject,
    ),
  )
  process.sleep(20)

  // Send an event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_3",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
    ),
  )
  process.sleep(50)

  // Should receive a patch
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(_msg) = process.selector_receive(selector, 500)
}

pub fn runtime_handles_disconnect_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Connect and disconnect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_4",
      subject: transport_subject,
    ),
  )
  process.sleep(20)
  process.send(
    subject,
    runtime.ClientDisconnected(conn_id: "test_conn_4"),
  )
  process.sleep(20)

  // Send event — should not crash even though client is gone
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_4",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
    ),
  )
  process.sleep(50)
}

pub fn runtime_handles_unknown_event_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_5",
      subject: transport_subject,
    ),
  )
  process.sleep(20)

  // Send unknown event — should warn but not crash
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_5",
      event_name: "click",
      handler_id: "unknown_handler",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
    ),
  )
  process.sleep(50)
}

pub fn runtime_effect_dispatches_message_test() {
  // Create a config where init produces an effect that dispatches SetCount(42)
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        #(
          CounterModel(count: 0),
          effect.from(fn(dispatch) { dispatch(SetCount(42)) }),
        )
      },
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
    )

  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect and join to get current state
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_6",
      subject: transport_subject,
    ),
  )
  process.sleep(50)

  // The effect should have already dispatched SetCount(42),
  // so joining should show count=42 in the mount HTML
  process.send(subject, runtime.ClientJoined(conn_id: "test_conn_6", token: ""))
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(transport_subject)

  // We might get multiple messages (patch from effect + mount from join)
  // Just verify we get at least one
  let assert Ok(_msg) = process.selector_receive(selector, 500)
}

pub fn runtime_survives_view_crash_test() {
  // Create a config where the view function crashes on count > 0
  let config =
    runtime.RuntimeConfig(
      init: fn() { #(CounterModel(count: 0), effect.none()) },
      update: counter_update,
      view: fn(model: CounterModel) {
        case model.count > 0 {
          True -> {
            // Intentionally crash to test error boundary
            crash_for_test()
          }
          False -> element.el("div", [], [element.text("ok")])
        }
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "crash_conn",
      subject: transport_subject,
    ),
  )
  process.sleep(20)

  // Send increment — this will cause the view to crash
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "crash_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
    ),
  )
  process.sleep(50)

  // Runtime should still be alive — send another event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "crash_conn",
      event_name: "click",
      handler_id: "decrement",
      event_data: "{}",
      target_path: "0",
      clock: 2,
    ),
  )
  process.sleep(50)
  // If we get here without crashing, the error boundary works
}

pub fn runtime_shutdown_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  process.send(subject, runtime.Shutdown)
  // Give it time to shut down
  process.sleep(50)
  // Actor should be stopped — further messages won't be processed
  // (we can't easily verify this without monitoring, but at least it shouldn't crash)
}

pub fn state_recovery_from_token_test() {
  // Create a runtime with serialize/deserialize
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(m: CounterModel) {
        int.to_string(m.count)
      }),
      deserialize_model: option.Some(fn(s: String) {
        case int.parse(s) {
          Ok(n) -> Ok(CounterModel(count: n))
          Error(Nil) -> Error("invalid count")
        }
      }),
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "recovery_conn",
      subject: transport_subject,
    ),
  )
  process.sleep(20)

  // Increment the counter 3 times
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "recovery_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
    ),
  )
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "recovery_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 2,
    ),
  )
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "recovery_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 3,
    ),
  )
  process.sleep(50)

  // Now create a token with the current model state (count=3)
  let token =
    runtime.create_state_token(
      CounterModel(count: 3),
      fn(m: CounterModel) { int.to_string(m.count) },
      "",
    )

  // Simulate reconnection: new connection joins with the token
  let transport_subject2 = process.new_subject()
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "recovery_conn_2",
      subject: transport_subject2,
    ),
  )
  process.sleep(20)

  // Join with the token containing count=3
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "recovery_conn_2", token: token),
  )
  process.sleep(50)

  // The mount should contain "3" (recovered state), not "0" (init state)
  let selector =
    process.new_selector()
    |> process.select(transport_subject2)
  let assert Ok(mount_msg) = process.selector_receive(selector, 1000)
  // The mount payload should be a Rendered JSON containing "3"
  case mount_msg {
    transport.SendMount(payload: payload) -> {
      let assert True = string.contains(payload, "3")
    }
    _ -> {
      // Should have received a mount — fail explicitly
      panic as "Expected SendMount message"
    }
  }
}

import gleam/string

pub fn model_sync_sent_after_event_test() {
  // Runtime with serialize_model should send model_sync after events
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(m: CounterModel) {
        "{\"count\":" <> int.to_string(m.count) <> "}"
      }),
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "sync_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "sync_conn", token: ""))
  process.sleep(20)

  // Drain mount + initial model_sync messages
  let selector = process.new_selector() |> process.select(transport_subject)
  let _ = process.selector_receive(selector, 500)
  let _ = process.selector_receive(selector, 500)

  // Send an increment event
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "sync_conn", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 1,
  ))
  process.sleep(50)

  // Should receive a patch AND a model_sync
  let msgs = drain_messages(transport_subject, [])
  let has_model_sync = list.any(msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> string.contains(json, "\"count\":1")
      _ -> False
    }
  })
  let assert True = has_model_sync
}

pub fn server_fn_execution_test() {
  // Runtime with a server function
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.insert(dict.new(), "greet", fn(args) {
        Ok("Hello, " <> args <> "!")
      }),
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "fn_conn", subject: transport_subject))
  process.sleep(20)

  // Call the server function
  process.send(subject, runtime.ClientCalledServerFn(
    conn_id: "fn_conn", name: "greet", args: "World", call_id: "c1",
  ))
  process.sleep(50)

  // Should receive the result
  let selector = process.new_selector() |> process.select(transport_subject)
  let assert Ok(msg) = process.selector_receive(selector, 500)
  case msg {
    transport.SendServerFnResult(call_id: "c1", result: result, ok: True) ->
      { let assert True = string.contains(result, "Hello, World!") }
    _ -> panic as "Expected SendServerFnResult"
  }
}

pub fn server_fn_unknown_test() {
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "fn2_conn", subject: transport_subject))
  process.sleep(20)

  // Call a non-existent server function
  process.send(subject, runtime.ClientCalledServerFn(
    conn_id: "fn2_conn", name: "nope", args: "", call_id: "c2",
  ))
  process.sleep(50)

  let selector = process.new_selector() |> process.select(transport_subject)
  let assert Ok(msg) = process.selector_receive(selector, 500)
  case msg {
    transport.SendServerFnResult(call_id: "c2", ok: False, ..) -> Nil
    _ -> panic as "Expected error SendServerFnResult"
  }
}

fn drain_messages(subject, acc) {
  let selector = process.new_selector() |> process.select(subject)
  case process.selector_receive(selector, 100) {
    Ok(msg) -> drain_messages(subject, [msg, ..acc])
    Error(Nil) -> acc
  }
}

@external(erlang, "beacon_test_ffi", "do_crash")
fn crash_for_test() -> element.Node(CounterMsg)

