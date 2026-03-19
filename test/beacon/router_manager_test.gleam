/// Tests for the route manager — per-connection actor that coordinates route lifecycle.
/// Tests verify: join starts route, navigate kills old + starts new, disconnect cleans up,
/// dispatcher failure is reported, duplicate navigation is skipped, events are forwarded.

import beacon/error
import beacon/router/manager
import beacon/transport
import gleam/erlang/process
import gleam/string

// --- Test helpers ---

/// A mock dispatcher that records calls and returns controllable closures.
/// Events received are forwarded to the provided subject.
fn mock_dispatcher(
  call_log: process.Subject(String),
  event_log: process.Subject(#(String, transport.ClientMessage)),
) -> manager.RouteDispatcher {
  fn(_conn_id, _transport_subject, path) {
    // Log the dispatch call
    process.send(call_log, "dispatch:" <> path)

    let on_event = fn(cid: transport.ConnectionId, msg: transport.ClientMessage) {
      process.send(event_log, #(cid, msg))
    }
    let shutdown = fn() {
      process.send(call_log, "shutdown:" <> path)
    }
    Ok(#(on_event, shutdown))
  }
}

/// A dispatcher that always fails for a specific path.
fn failing_dispatcher(
  fail_path: String,
  call_log: process.Subject(String),
  event_log: process.Subject(#(String, transport.ClientMessage)),
) -> manager.RouteDispatcher {
  fn(_conn_id, _transport_subject, path) {
    process.send(call_log, "dispatch:" <> path)
    case path == fail_path {
      True -> Error(error.RuntimeError(reason: "Route not found: " <> path))
      False -> {
        let on_event = fn(cid: transport.ConnectionId, msg: transport.ClientMessage) {
          process.send(event_log, #(cid, msg))
        }
        let shutdown = fn() {
          process.send(call_log, "shutdown:" <> path)
        }
        Ok(#(on_event, shutdown))
      }
    }
  }
}

fn drain_strings(subject, acc) {
  let selector = process.new_selector() |> process.select(subject)
  case process.selector_receive(selector, 100) {
    Ok(msg) -> drain_strings(subject, [msg, ..acc])
    Error(Nil) -> acc
  }
}

fn drain_events(subject, acc) {
  let selector = process.new_selector() |> process.select(subject)
  case process.selector_receive(selector, 100) {
    Ok(msg) -> drain_events(subject, [msg, ..acc])
    Error(Nil) -> acc
  }
}

fn drain_internal(subject, acc) {
  let selector = process.new_selector() |> process.select(subject)
  case process.selector_receive(selector, 100) {
    Ok(msg) -> drain_internal(subject, [msg, ..acc])
    Error(Nil) -> acc
  }
}

// --- Tests ---

pub fn join_starts_route_runtime_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_1", transport_subject, dispatcher)

  // Send join for /
  on_event("conn_1", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)

  // Dispatcher should have been called with "/"
  let calls = drain_strings(call_log, [])
  let assert True =
    has_string(calls, "dispatch:/")

  // Join should have been forwarded to the route runtime
  let events = drain_events(event_log, [])
  let assert True = has_event_of_type(events, "join")
}

pub fn join_with_path_starts_correct_route_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_2", transport_subject, dispatcher)

  // Join with explicit path
  on_event("conn_2", transport.ClientJoin(token: "", path: "/about"))
  process.sleep(100)

  let calls = drain_strings(call_log, [])
  let assert True = has_string(calls, "dispatch:/about")
}

pub fn navigate_kills_old_and_starts_new_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_3", transport_subject, dispatcher)

  // First join at /
  on_event("conn_3", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)
  let _ = drain_strings(call_log, [])
  let _ = drain_events(event_log, [])

  // Navigate to /about
  on_event("conn_3", transport.ClientNavigate(path: "/about"))
  process.sleep(100)

  let calls = drain_strings(call_log, [])
  // Should have shut down / and dispatched /about
  let assert True = has_string(calls, "shutdown:/")
  let assert True = has_string(calls, "dispatch:/about")

  // Navigate should synthesize a join to the new runtime
  let events = drain_events(event_log, [])
  let assert True = has_event_of_type(events, "join")
}

pub fn duplicate_navigation_skipped_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_4", transport_subject, dispatcher)

  // Join at /settings
  on_event("conn_4", transport.ClientJoin(token: "", path: "/settings"))
  process.sleep(100)
  let _ = drain_strings(call_log, [])
  let _ = drain_events(event_log, [])

  // Navigate to /settings again — should be skipped
  on_event("conn_4", transport.ClientNavigate(path: "/settings"))
  process.sleep(100)

  let calls = drain_strings(call_log, [])
  // No dispatch or shutdown should have happened
  let assert True = calls == []
}

pub fn events_forwarded_to_current_runtime_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_5", transport_subject, dispatcher)

  // Join to initialize route
  on_event("conn_5", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)
  let _ = drain_events(event_log, [])

  // Send a click event
  on_event(
    "conn_5",
    transport.ClientEvent(
      name: "click",
      handler_id: "increment",
      data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(100)

  let events = drain_events(event_log, [])
  let assert True =
    has_event(events, fn(e) {
      case e {
        #(_, transport.ClientEvent(name: "click", handler_id: "increment", ..)) ->
          True
        _ -> False
      }
    })
}

pub fn disconnect_shuts_down_runtime_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, on_disconnect) =
    manager.start("conn_6", transport_subject, dispatcher)

  // Join to initialize route
  on_event("conn_6", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)
  let _ = drain_strings(call_log, [])

  // Disconnect
  on_disconnect("conn_6")
  process.sleep(100)

  let calls = drain_strings(call_log, [])
  // Shutdown should have been called for /
  let assert True = has_string(calls, "shutdown:/")
}

pub fn dispatcher_failure_sends_error_to_client_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = failing_dispatcher("/bad", call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_7", transport_subject, dispatcher)

  // Join at failing path
  on_event("conn_7", transport.ClientJoin(token: "", path: "/bad"))
  process.sleep(100)

  // Transport should have received a SendError
  let msgs = drain_internal(transport_subject, [])
  let assert True =
    has_internal(msgs, fn(m) {
      case m {
        transport.SendError(reason: r) -> string.contains(r, "Failed to start route")
        _ -> False
      }
    })
}

pub fn navigate_failure_sends_error_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = failing_dispatcher("/404", call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_8", transport_subject, dispatcher)

  // First join at / (succeeds)
  on_event("conn_8", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)
  let _ = drain_internal(transport_subject, [])

  // Navigate to failing path
  on_event("conn_8", transport.ClientNavigate(path: "/404"))
  process.sleep(100)

  // Transport should have received a SendError
  let msgs = drain_internal(transport_subject, [])
  let assert True =
    has_internal(msgs, fn(m) {
      case m {
        transport.SendError(reason: r) -> string.contains(r, "Route not found")
        _ -> False
      }
    })
}

pub fn event_before_join_does_not_crash_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = mock_dispatcher(call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_9", transport_subject, dispatcher)

  // Send event BEFORE join — should not crash, just log warning
  on_event(
    "conn_9",
    transport.ClientEvent(
      name: "click",
      handler_id: "inc",
      data: "{}",
      target_path: "0",
      clock: 1,
      ops: "",
    ),
  )
  process.sleep(100)

  // No events should have been forwarded (no runtime yet)
  let events = drain_events(event_log, [])
  let assert True = events == []

  // Manager should still be alive — send join and verify it works
  on_event("conn_9", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)

  let calls = drain_strings(call_log, [])
  let assert True = has_string(calls, "dispatch:/")
}

pub fn navigate_after_failed_route_works_test() {
  let call_log = process.new_subject()
  let event_log = process.new_subject()
  let transport_subject = process.new_subject()
  let dispatcher = failing_dispatcher("/bad", call_log, event_log)

  let #(on_event, _on_disconnect) =
    manager.start("conn_10", transport_subject, dispatcher)

  // Join at / (succeeds)
  on_event("conn_10", transport.ClientJoin(token: "", path: "/"))
  process.sleep(100)
  let _ = drain_strings(call_log, [])
  let _ = drain_internal(transport_subject, [])

  // Navigate to /bad (fails)
  on_event("conn_10", transport.ClientNavigate(path: "/bad"))
  process.sleep(100)
  let _ = drain_strings(call_log, [])
  let _ = drain_internal(transport_subject, [])

  // Navigate to / again (should work — manager recovers from failure)
  on_event("conn_10", transport.ClientNavigate(path: "/"))
  process.sleep(100)

  let calls = drain_strings(call_log, [])
  let assert True = has_string(calls, "dispatch:/")
}

// --- Assertion helpers ---

fn has_string(list: List(String), target: String) -> Bool {
  case list {
    [] -> False
    [first, ..rest] ->
      case first == target {
        True -> True
        False -> has_string(rest, target)
      }
  }
}

fn has_event_of_type(
  events: List(#(String, transport.ClientMessage)),
  msg_type: String,
) -> Bool {
  has_event(events, fn(e) {
    case msg_type {
      "join" ->
        case e {
          #(_, transport.ClientJoin(..)) -> True
          _ -> False
        }
      "event" ->
        case e {
          #(_, transport.ClientEvent(..)) -> True
          _ -> False
        }
      _ -> False
    }
  })
}

fn has_event(
  events: List(#(String, transport.ClientMessage)),
  predicate: fn(#(String, transport.ClientMessage)) -> Bool,
) -> Bool {
  case events {
    [] -> False
    [first, ..rest] ->
      case predicate(first) {
        True -> True
        False -> has_event(rest, predicate)
      }
  }
}

fn has_internal(
  msgs: List(transport.InternalMessage),
  predicate: fn(transport.InternalMessage) -> Bool,
) -> Bool {
  case msgs {
    [] -> False
    [first, ..rest] ->
      case predicate(first) {
        True -> True
        False -> has_internal(rest, predicate)
      }
  }
}
