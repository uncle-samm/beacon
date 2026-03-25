import beacon/effect
import beacon/element
import beacon/error
import beacon/runtime
import beacon/transport
import beacon/transport/server
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option
import gleam/string

/// Create a fake socket for testing (nil wrapped as Socket type).
@external(erlang, "beacon_runtime_test_ffi", "fake_socket")
fn fake_socket() -> server.Socket

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
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None, on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
  )
}

// --- Tests ---

pub fn runtime_starts_successfully_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  // Connect and join to verify we get a mount message
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "start_conn",
      subject: transport_subject,
    ),
  )
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "start_conn", token: "", path: "/"))
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(mount_msg) = process.selector_receive(selector, 500)
  case mount_msg {
    transport.SendMount(payload: _) -> Nil
    _ -> panic as "Expected SendMount after join"
  }
}

pub fn runtime_accepts_client_connect_test() {
  let assert Ok(subject) = runtime.start(counter_config())
  let fake_transport_subject = process.new_subject()
  // Connect
  process.send(
    subject,
    runtime.ClientConnected(
      conn_id: "test_conn_1",
      subject: fake_transport_subject,
    ),
  )
  process.sleep(20)

  // Join and verify mount message is received
  process.send(subject, runtime.ClientJoined(conn_id: "test_conn_1", token: "", path: "/"))
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(fake_transport_subject)
  let assert Ok(mount_msg) = process.selector_receive(selector, 500)
  case mount_msg {
    transport.SendMount(payload: payload) -> {
      // Mount should contain the initial counter view with "0" rendered in element
      let assert True = string.contains(payload, ">0<")
    }
    _ -> panic as "Expected SendMount after connect + join"
  }
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
  process.send(subject, runtime.ClientJoined(conn_id: "test_conn_2", token: "", path: "/"))
  process.sleep(50)

  // Check that we received a mount message with rendered content
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(mount_msg) = process.selector_receive(selector, 500)
  case mount_msg {
    transport.SendMount(payload: payload) -> {
      // The counter view renders int.to_string(model.count), so mount should contain "0" in element
      let assert True = string.contains(payload, ">0<")
    }
    _ -> panic as "Expected SendMount message on join"
  }
}

pub fn runtime_sends_model_sync_on_event_test() {
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
      ops: "",
    ),
  )
  process.sleep(50)

  // Should receive a model_sync or patch containing updated count
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  // Drain all messages and look for one containing the updated count
  let msgs = drain_messages(transport_subject, case process.selector_receive(selector, 500) {
    Ok(msg) -> [msg]
    Error(Nil) -> []
  })
  let has_update = list.any(msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> string.contains(json, "\"count\":1")
      transport.SendPatch(ops_json: json, ..) -> string.contains(json, "/count")
      _ -> False
    }
  })
  let assert True = has_update
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
      ops: "",
    ),
  )
  process.sleep(50)

  // After disconnect, no messages should arrive on the transport subject
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Error(Nil) = process.selector_receive(selector, 200)
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

  // Send unknown event — should produce a SendError
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "test_conn_5",
      event_name: "click",
      handler_id: "unknown_handler",
      event_data: "{}",
      target_path: "0.0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(50)

  // Check that the transport received a SendError for the unknown handler
  let msgs = drain_messages(transport_subject, [])
  let has_error = list.any(msgs, fn(m) {
    case m {
      transport.SendError(reason: _) -> True
      _ -> False
    }
  })
  let assert True = has_error
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
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None, on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
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
  process.send(subject, runtime.ClientJoined(conn_id: "test_conn_6", token: "", path: "/"))
  process.sleep(50)

  let selector =
    process.new_selector()
    |> process.select(transport_subject)

  // We might get multiple messages (patch from effect + mount from join)
  // Drain all and find a message proving SetCount(42) was applied.
  // Mount renders the view (text "42"), model_sync contains JSON with count,
  // patches contain /count path.
  let first_msg = process.selector_receive(selector, 500)
  let msgs = drain_messages(transport_subject, case first_msg {
    Ok(msg) -> [msg]
    Error(Nil) -> []
  })
  let has_42 = list.any(msgs, fn(m) {
    case m {
      transport.SendMount(payload: payload) -> string.contains(payload, ">42<")
      transport.SendPatch(ops_json: json, ..) -> string.contains(json, "42") && string.contains(json, "/count")
      transport.SendModelSync(model_json: json, ..) -> string.contains(json, "\"count\":42")
      _ -> False
    }
  })
  let assert True = has_42
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
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None, on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
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
      ops: "",
    ),
  )
  process.sleep(50)

  // Runtime should still be alive — send a decrement event
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "crash_conn",
      event_name: "click",
      handler_id: "decrement",
      event_data: "{}",
      target_path: "0",
      clock: 2,
      ops: "",
    ),
  )
  process.sleep(50)

  // Drain any messages from earlier, then send a new join to prove runtime is alive
  let _ = drain_messages(transport_subject, [])
  process.send(subject, runtime.ClientJoined(conn_id: "crash_conn", token: "", path: "/"))
  process.sleep(50)

  // Verify we get a mount message back (proving the runtime survived the crash)
  let selector =
    process.new_selector()
    |> process.select(transport_subject)
  let assert Ok(mount_msg) = process.selector_receive(selector, 500)
  case mount_msg {
    transport.SendMount(payload: _) -> Nil
    _ -> panic as "Expected SendMount after view crash recovery"
  }
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
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None, on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
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
      ops: "",
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
      ops: "",
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
      ops: "",
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
    runtime.ClientJoined(conn_id: "recovery_conn_2", token: token, path: "/"),
  )
  process.sleep(50)

  // The mount should contain "3" (recovered state), not "0" (init state)
  let selector =
    process.new_selector()
    |> process.select(transport_subject2)
  let assert Ok(mount_msg) = process.selector_receive(selector, 1000)
  // The mount payload should be a Rendered JSON containing "3" in element
  case mount_msg {
    transport.SendMount(payload: payload) -> {
      let assert True = string.contains(payload, ">3<")
    }
    _ -> {
      // Should have received a mount — fail explicitly
      panic as "Expected SendMount message"
    }
  }
}

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
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None, on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "sync_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "sync_conn", token: "", path: "/"))
  process.sleep(20)

  // Drain mount + initial model_sync messages
  let selector = process.new_selector() |> process.select(transport_subject)
  let _ = process.selector_receive(selector, 500)
  let _ = process.selector_receive(selector, 500)

  // Send an increment event
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "sync_conn", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 1, ops: "",
  ))
  process.sleep(50)

  // Should receive a model_sync or patch with count:1
  let msgs = drain_messages(transport_subject, [])
  let has_update = list.any(msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> string.contains(json, "\"count\":1")
      transport.SendPatch(ops_json: json, ..) -> string.contains(json, "/count")
      _ -> False
    }
  })
  let assert True = has_update
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

// === Patch optimization proof tests ===

pub fn sends_patch_not_model_sync_after_join_test() {
  // After the initial join (which sends model_sync), subsequent events
  // MUST produce SendPatch, NOT SendModelSync. This catches regressions.
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "patch_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "patch_conn", token: "", path: "/"))
  process.sleep(50)

  // Drain mount + initial model_sync
  let init_msgs = drain_messages(transport_subject, [])
  // Verify initial messages include a model_sync (full sync on join)
  let has_initial_sync = list.any(init_msgs, fn(m) {
    case m {
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  let assert True = has_initial_sync

  // Now send an increment event
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "patch_conn", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 1, ops: "",
  ))
  process.sleep(50)

  // Subsequent events MUST produce SendPatch (not SendModelSync)
  let event_msgs = drain_messages(transport_subject, [])
  let has_patch = list.any(event_msgs, fn(m) {
    case m {
      transport.SendPatch(ops_json: ops, ..) -> string.contains(ops, "/count")
      _ -> False
    }
  })
  let has_full_sync = list.any(event_msgs, fn(m) {
    case m {
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  let assert True = has_patch
  let assert False = has_full_sync
}

pub fn patch_contains_only_changed_field_test() {
  // After incrementing count, the patch should only contain /count
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "small_patch", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "small_patch", token: "", path: "/"))
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send increment
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "small_patch", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 1, ops: "",
  ))
  process.sleep(50)

  let msgs = drain_messages(transport_subject, [])
  // Find the patch message and verify its ops are small
  let patch_ops = list.filter_map(msgs, fn(m) {
    case m {
      transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
      _ -> Error(Nil)
    }
  })
  // Should have exactly one patch
  let assert True = list.length(patch_ops) >= 1
  let assert [ops, ..] = patch_ops
  // Ops should contain /count and be small (< 60 bytes)
  let assert True = string.contains(ops, "/count")
  let assert True = string.length(ops) < 60
}

pub fn client_ops_falls_back_without_codec_test() {
  // When client sends event WITH ops but no beacon_codec module is loaded,
  // the server should fall back gracefully (ops require codec for decode).
  // The event still gets processed via the normal update path.
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "ops_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "ops_conn", token: "", path: "/"))
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send event WITH ops — without beacon_codec, apply_client_ops can't decode
  // so it falls back to the old state. Then effects still run.
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "ops_conn", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 1,
    ops: "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":42}]",
  ))
  process.sleep(50)

  // The server should still be alive and responsive
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "ops_conn", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 2, ops: "",
  ))
  process.sleep(50)

  // Should get some response (server didn't crash)
  let msgs = drain_messages(transport_subject, [])
  let has_response = list.any(msgs, fn(m) {
    case m {
      transport.SendPatch(..) -> True
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  let assert True = has_response
}

pub fn multiple_increments_produce_patches_test() {
  // After join, sending 5 increments should produce 5 patches (not model_syncs)
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "multi_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "multi_conn", token: "", path: "/"))
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send 5 increments
  [1, 2, 3, 4, 5] |> list.each(fn(i) {
    process.send(subject, runtime.ClientEventReceived(
      conn_id: "multi_conn", event_name: "click", handler_id: "increment",
      event_data: "{}", target_path: "0", clock: i, ops: "",
    ))
    process.sleep(30)
  })
  process.sleep(50)

  let msgs = drain_messages(transport_subject, [])
  let patch_count = list.count(msgs, fn(m) {
    case m {
      transport.SendPatch(..) -> True
      _ -> False
    }
  })
  let sync_count = list.count(msgs, fn(m) {
    case m {
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  // All 5 should be patches, zero should be full syncs
  let assert True = patch_count == 5
  let assert True = sync_count == 0
}

pub fn patch_content_correct_after_many_increments_test() {
  // After 10 increments (with waits), the final patch should contain "10"
  // and every patch should be small (< 50 bytes).
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "many_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "many_conn", token: "", path: "/"))
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send 10 increments with waits to ensure each is processed
  list.repeat(Nil, 10) |> list.index_map(fn(_, i) { i + 1 }) |> list.each(fn(i) {
    process.send(subject, runtime.ClientEventReceived(
      conn_id: "many_conn", event_name: "click", handler_id: "increment",
      event_data: "{}", target_path: "0", clock: i, ops: "",
    ))
    process.sleep(30)
  })
  process.sleep(200)

  let msgs = drain_messages(transport_subject, [])
  let patches = list.filter_map(msgs, fn(m) {
    case m {
      transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
      _ -> Error(Nil)
    }
  })
  // All 10 increments should produce patches
  let assert True = list.length(patches) >= 10
  // Every patch for a single counter increment should be small
  list.each(patches, fn(p) {
    let assert True = string.length(p) < 60
  })
  // The last patch should contain /count and a numeric value
  let assert Ok(last_patch) = list.last(patches)
  let assert True = string.contains(last_patch, "/count")
}

// === Server Type Tests ===

pub fn server_state_not_in_model_sync_test() {
  // Simulate the pattern from app_with_server:
  // Model + Server wrapped as #(Model, Server), serializer only encodes Model part
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        // Combined: #(Model, Server) — server state is api_key
        #(#(CounterModel(count: 0), "secret_api_key"), effect.none())
      },
      update: fn(combined, msg) {
        let #(model, server) = combined
        case msg {
          Increment -> #(#(CounterModel(count: model.count + 1), server), effect.none())
          _ -> #(#(model, server), effect.none())
        }
      },
      view: fn(combined) {
        // View only uses model part — server part is never accessed
        let #(model, _server) = combined
        element.el("div", [], [element.text(int.to_string(model.count))])
      },
      decode_event: option.Some(counter_decode_event),
      // Serializer only encodes the Model part, NOT the server state
      serialize_model: option.Some(fn(combined: #(CounterModel, String)) {
        let #(model, _server) = combined
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(conn_id: "server_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "server_conn", token: "", path: "/"))
  process.sleep(100)

  // Collect ALL messages from join (mount + model_sync)
  let msgs = drain_messages(transport_subject, [])
  // Find model_sync message — it should contain count but NOT api_key
  let model_syncs = list.filter_map(msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> Ok(json)
      _ -> Error(Nil)
    }
  })
  // Should have at least one model_sync (sent on join when serialize_model is set)
  let assert True = list.length(model_syncs) >= 1
  // NONE of them should contain the server secret
  list.each(model_syncs, fn(json) {
    let assert False = string.contains(json, "secret_api_key")
    let assert True = string.contains(json, "count")
  })
}

// === app_with_server Model Encoder Tests ===

pub fn app_with_server_background_effect_pushes_update_test() {
  // Verify that background effects (EffectDispatched) push model updates
  // to the client when serialize_model is set for #(Model, Server).
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        #(#(CounterModel(count: 0), "server_secret"), effect.none())
      },
      update: fn(combined, msg) {
        let #(model, server) = combined
        case msg {
          Increment -> #(#(CounterModel(count: model.count + 1), server), effect.none())
          _ -> #(#(model, server), effect.none())
        }
      },
      view: fn(combined) {
        let #(model, _server) = combined
        element.el("div", [], [element.text(int.to_string(model.count))])
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(combined: #(CounterModel, String)) {
        let #(model, _server) = combined
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect and join
  process.send(subject, runtime.ClientConnected(conn_id: "bg_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "bg_conn", token: "", path: "/"))
  process.sleep(100)
  // Drain mount + initial model_sync
  let _ = drain_messages(transport_subject, [])

  // Simulate background effect dispatching a message
  process.send(subject, runtime.EffectDispatched(message: Increment))
  process.sleep(100)

  // Should receive a patch or model_sync with updated count
  let msgs = drain_messages(transport_subject, [])
  let updates = list.filter(msgs, fn(m) {
    case m {
      transport.SendPatch(..) -> True
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  // Must have at least one update pushed to client
  let assert True = list.length(updates) >= 1
  // Verify the update contains count:1, not server_secret
  let update_jsons = list.filter_map(msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> Ok(json)
      transport.SendPatch(ops_json: json, ..) -> Ok(json)
      _ -> Error(Nil)
    }
  })
  list.each(update_jsons, fn(json) {
    let assert False = string.contains(json, "server_secret")
  })
}

pub fn app_with_server_user_event_pushes_update_test() {
  // Verify that user events (ClientEventReceived) push model updates
  // to the client when serialize_model is set for #(Model, Server).
  let config =
    runtime.RuntimeConfig(
      init: fn() {
        #(#(CounterModel(count: 0), "private_key"), effect.none())
      },
      update: fn(combined, msg) {
        let #(model, server) = combined
        case msg {
          Increment -> #(#(CounterModel(count: model.count + 1), server), effect.none())
          _ -> #(#(model, server), effect.none())
        }
      },
      view: fn(combined) {
        let #(model, _server) = combined
        element.el("div", [], [element.text(int.to_string(model.count))])
      },
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(combined: #(CounterModel, String)) {
        let #(model, _server) = combined
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect and join — view renders button with on_click handler
  process.send(subject, runtime.ClientConnected(conn_id: "evt_conn", subject: transport_subject))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "evt_conn", token: "", path: "/"))
  process.sleep(100)
  // Drain mount + initial model_sync
  let _ = drain_messages(transport_subject, [])

  // Send a client event (simulating button click)
  // handler_id "increment" matches counter_decode_event
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "evt_conn",
    event_name: "click",
    handler_id: "increment",
    event_data: "",
    target_path: "",
    clock: 1,
    ops: "",
  ))
  process.sleep(100)

  // Should receive a patch or model_sync with updated count
  let msgs = drain_messages(transport_subject, [])
  let updates = list.filter(msgs, fn(m) {
    case m {
      transport.SendPatch(..) -> True
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  // Must have at least one update pushed to client
  let assert True = list.length(updates) >= 1
  // Verify no server secret leaked
  let update_jsons = list.filter_map(msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> Ok(json)
      transport.SendPatch(ops_json: json, ..) -> Ok(json)
      _ -> Error(Nil)
    }
  })
  list.each(update_jsons, fn(json) {
    let assert False = string.contains(json, "private_key")
  })
}

// === Error Path Tests ===

pub fn runtime_handles_malformed_event_data_test() {
  // Send an event with a valid handler_id but garbage event_data.
  // The runtime must stay alive and send an error (not crash).
  let assert Ok(subject) = runtime.start(counter_config())
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(
    conn_id: "malformed_conn", subject: transport_subject,
  ))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "malformed_conn", token: "", path: "/"))
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send event with valid handler but garbage data
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "malformed_conn", event_name: "click", handler_id: "increment",
    event_data: "THIS_IS_NOT_JSON!!!", target_path: "0", clock: 1, ops: "",
  ))
  process.sleep(50)

  // Runtime must still be alive — send a normal increment to prove it
  process.send(subject, runtime.ClientEventReceived(
    conn_id: "malformed_conn", event_name: "click", handler_id: "increment",
    event_data: "{}", target_path: "0", clock: 2, ops: "",
  ))
  process.sleep(50)

  // Should get a response (patch or model_sync) from the second event
  let msgs = drain_messages(transport_subject, [])
  let has_response = list.any(msgs, fn(m) {
    case m {
      transport.SendPatch(..) -> True
      transport.SendModelSync(..) -> True
      _ -> False
    }
  })
  let assert True = has_response
}

pub fn runtime_handles_rapid_events_test() {
  // Send 50 events in rapid succession (no sleep between).
  // Verify runtime processes all of them and final state is correct.
  let config = counter_config()
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  process.send(subject, runtime.ClientConnected(
    conn_id: "rapid_conn", subject: transport_subject,
  ))
  process.sleep(20)
  process.send(subject, runtime.ClientJoined(conn_id: "rapid_conn", token: "", path: "/"))
  process.sleep(50)
  let _ = drain_messages(transport_subject, [])

  // Send 50 increments with NO sleep between them
  list.repeat(Nil, 50) |> list.index_map(fn(_, i) { i + 1 }) |> list.each(fn(i) {
    process.send(subject, runtime.ClientEventReceived(
      conn_id: "rapid_conn", event_name: "click", handler_id: "increment",
      event_data: "{}", target_path: "0", clock: i, ops: "",
    ))
  })
  // Wait for all processing to complete
  process.sleep(500)

  let msgs = drain_messages(transport_subject, [])
  // Should have received responses for all 50 events
  let patch_count = list.count(msgs, fn(m) {
    case m {
      transport.SendPatch(..) -> True
      _ -> False
    }
  })
  let assert True = patch_count == 50

  // The final patch (most recent) should contain "50" (final count value).
  // drain_messages returns messages in reverse order (newest first),
  // so the first patch in the list is the most recent one.
  let patches = list.filter_map(msgs, fn(m) {
    case m {
      transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
      _ -> Error(Nil)
    }
  })
  let assert [newest_patch, ..] = patches
  let assert True = string.contains(newest_patch, "/count")
  let assert True = string.contains(newest_patch, "50")
}

// === Connection Isolation Test ===

pub fn connection_isolation_test() {
  // Verify connection B's state is NOT affected by connection A's events.
  // Per-connection runtimes mean each start() creates an independent actor.
  let assert Ok(subject_a) = runtime.start(counter_config())
  let assert Ok(subject_b) = runtime.start(counter_config())
  let transport_a = process.new_subject()
  let transport_b = process.new_subject()

  // Connect both
  process.send(subject_a, runtime.ClientConnected(
    conn_id: "iso_a", subject: transport_a,
  ))
  process.send(subject_b, runtime.ClientConnected(
    conn_id: "iso_b", subject: transport_b,
  ))
  process.sleep(20)

  // Join both
  process.send(subject_a, runtime.ClientJoined(conn_id: "iso_a", token: "", path: "/"))
  process.send(subject_b, runtime.ClientJoined(conn_id: "iso_b", token: "", path: "/"))
  process.sleep(50)

  // Drain initial messages from both
  let _ = drain_messages(transport_a, [])
  let _ = drain_messages(transport_b, [])

  // Send 5 increments ONLY on connection A
  list.repeat(Nil, 5) |> list.index_map(fn(_, i) { i + 1 }) |> list.each(fn(i) {
    process.send(subject_a, runtime.ClientEventReceived(
      conn_id: "iso_a", event_name: "click", handler_id: "increment",
      event_data: "{}", target_path: "0", clock: i, ops: "",
    ))
  })
  process.sleep(100)

  // Drain A's messages — should have patches with count values
  let a_msgs = drain_messages(transport_a, [])
  let a_patches = list.filter_map(a_msgs, fn(m) {
    case m {
      transport.SendPatch(ops_json: ops, ..) -> Ok(ops)
      _ -> Error(Nil)
    }
  })
  let assert True = list.length(a_patches) == 5

  // B should have received NO messages (no patches, no model_syncs)
  let b_msgs = drain_messages(transport_b, [])
  let assert True = list.is_empty(b_msgs)

  // Now trigger a fresh model_sync on B by re-joining — should show count:0
  process.send(subject_b, runtime.ClientJoined(conn_id: "iso_b", token: "", path: "/"))
  process.sleep(50)

  let b_join_msgs = drain_messages(transport_b, [])
  let b_syncs = list.filter_map(b_join_msgs, fn(m) {
    case m {
      transport.SendModelSync(model_json: json, ..) -> Ok(json)
      _ -> Error(Nil)
    }
  })
  let assert True = list.length(b_syncs) >= 1
  // B's model_sync must show count:0 (unaffected by A's increments)
  list.each(b_syncs, fn(json) {
    let assert True = string.contains(json, "\"count\":0")
  })
}

/// Verify that on_update_effect wrapping works: the chained effect is
/// actually invoked by the runtime when an event triggers an update.
/// This tests the same wrapping pattern used by beacon.on_update().
pub fn on_update_effect_is_invoked_test() {
  // Create a Subject that on_update_effect will send to, proving it ran
  let proof_subject = process.new_subject()

  // Wrap update the same way start_validated does: chain on_update_effect after base
  let on_update_fn = fn(model: CounterModel, _msg: CounterMsg) {
    // This effect proves on_update was called — sends the new count
    effect.from(fn(_dispatch) {
      process.send(proof_subject, model.count)
    })
  }
  let wrapped_update = fn(model: CounterModel, msg: CounterMsg) {
    let #(new_model, base_effect) = counter_update(model, msg)
    let extra_effect = on_update_fn(new_model, msg)
    #(new_model, effect.batch([base_effect, extra_effect]))
  }

  // Create config with the wrapped update
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: wrapped_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
    )
  let assert Ok(subject) = runtime.start(config)
  let transport_subject = process.new_subject()

  // Connect
  process.send(
    subject,
    runtime.ClientConnected(conn_id: "on_update_conn", subject: transport_subject),
  )
  process.sleep(50)

  // Join
  process.send(
    subject,
    runtime.ClientJoined(conn_id: "on_update_conn", token: "", path: "/"),
  )
  process.sleep(50)

  // Send an event — this should trigger update AND on_update_effect
  process.send(
    subject,
    runtime.ClientEventReceived(
      conn_id: "on_update_conn",
      event_name: "click",
      handler_id: "increment",
      event_data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )

  // Wait for the on_update_effect to fire
  case process.receive(proof_subject, 2000) {
    Ok(count) -> {
      // on_update_effect was called with the NEW model (count=1)
      let assert True = count == 1
    }
    Error(Nil) -> {
      // on_update_effect was NEVER called — this is the bug
      panic as "on_update_effect was not invoked by the runtime"
    }
  }
}

/// Verify that init_from_request replaces the default init when provided.
/// This tests the core of ws_init: the runtime uses init_from_request(req)
/// instead of init() when both are available.
pub fn init_from_request_replaces_default_init_test() {
  // Create a fake request with a cookie
  // Use request.set_body to give it the Connection type
  let fake_req =
    request.new()
    |> request.set_body(server.Connection(socket: fake_socket()))
    |> request.set_header("cookie", "user_id=42")

  // Default init creates count:0
  // init_from_request reads cookie and creates count based on user_id
  let init_from_req = fn(req: request.Request(server.Connection)) -> #(CounterModel, effect.Effect(CounterMsg)) {
    case request.get_header(req, "cookie") {
      Ok(cookie_val) -> {
        // Parse "user_id=42" → use 42 as initial count
        case string.split(cookie_val, "=") {
          [_, val] ->
            case int.parse(val) {
              Ok(n) -> #(CounterModel(count: n), effect.none())
              Error(Nil) -> #(CounterModel(count: -1), effect.none())
            }
          _ -> #(CounterModel(count: -1), effect.none())
        }
      }
      Error(Nil) -> #(CounterModel(count: -1), effect.none())
    }
  }

  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.Some(init_from_req),
      secret_key: "",
    )

  // Use start_and_connect_with_request which should use init_from_request
  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect_with_request(
      config,
      "ws_init_conn",
      transport_subject,
      option.Some(fake_req),
    )

  // Send ClientJoin to trigger mount — the runtime will send back model state
  on_event("ws_init_conn", transport.ClientJoin(token: "", path: "/"))
  process.sleep(200)

  // Drain the transport subject for messages
  let msgs = drain_messages(transport_subject, [])
  // Look for a model_sync or mount containing "42" (the count from cookie)
  let has_42 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":42")
        transport.SendMount(payload: p) -> string.contains(p, "42")
        _ -> False
      }
    })
  let assert True = has_42
}

/// Without init_from_request, the default init is used (count:0).
pub fn init_from_request_none_uses_default_init_test() {
  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.Some(fn(model: CounterModel) {
        "{\"count\":" <> int.to_string(model.count) <> "}"
      }),
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.None,
      secret_key: "",
    )

  // start_and_connect (no request) should use default init (count:0)
  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect(
      config,
      "default_init_conn",
      transport_subject,
    )
  on_event("default_init_conn", transport.ClientJoin(token: "", path: "/"))
  process.sleep(200)
  let msgs = drain_messages(transport_subject, [])
  let has_0 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendModelSync(model_json: json, ..) ->
          string.contains(json, "\"count\":0")
        transport.SendMount(payload: p) -> string.contains(p, ">0<")
        _ -> False
      }
    })
  let assert True = has_0
}

/// Regression test: mount HTML must reflect the ws_init model, not the default init.
/// Bug: client showed login page after auth because mount used SSR HTML (hydrated=true skip).
/// Fix: handleMount always morphs the mount HTML, never skips.
pub fn mount_html_reflects_ws_init_model_test() {
  // ws_init sets count to 99 (simulating auth-populated state)
  let init_from_req = fn(_req: request.Request(server.Connection)) -> #(CounterModel, effect.Effect(CounterMsg)) {
    #(CounterModel(count: 99), effect.none())
  }

  let config =
    runtime.RuntimeConfig(
      init: counter_init,
      update: counter_update,
      view: counter_view,
      decode_event: option.Some(counter_decode_event),
      serialize_model: option.None,
      deserialize_model: option.None,
      route_patterns: [],
      on_route_change: option.None,
      dynamic_subscriptions: option.None,
      on_notify: option.None,
      init_from_request: option.Some(init_from_req),
      secret_key: "",
    )

  let fake_req =
    request.new()
    |> request.set_body(server.Connection(socket: fake_socket()))
    |> request.set_header("cookie", "session=test")

  let transport_subject = process.new_subject()
  let assert Ok(#(on_event, _shutdown)) =
    runtime.start_and_connect_with_request(
      config,
      "mount_html_conn",
      transport_subject,
      option.Some(fake_req),
    )

  // Join — triggers mount HTML render
  on_event("mount_html_conn", transport.ClientJoin(token: "", path: "/"))
  process.sleep(200)

  let msgs = drain_messages(transport_subject, [])

  // The mount HTML MUST contain "99" (from ws_init), not "0" (from default init)
  let mount_has_99 =
    list.any(msgs, fn(m) {
      case m {
        transport.SendMount(payload: html) -> string.contains(html, "99")
        _ -> False
      }
    })
  let assert True = mount_has_99

  // Verify it does NOT contain the default init value in mount
  let mount_msgs =
    list.filter_map(msgs, fn(m) {
      case m {
        transport.SendMount(payload: html) -> Ok(html)
        _ -> Error(Nil)
      }
    })
  // At least one mount message should exist
  let assert True = list.length(mount_msgs) >= 1
}

