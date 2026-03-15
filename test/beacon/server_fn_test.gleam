import beacon/effect
import beacon/server_fn
import gleam/erlang/process

pub type TestMsg {
  GotValue(Int)
  GotError(String)
  StreamValue(Int)
}

pub fn call_dispatches_result_test() {
  let eff = server_fn.call(fn() { 42 }, GotValue)
  let result = capture_dispatch(eff)
  let assert GotValue(42) = result
}

pub fn call_with_computation_test() {
  let eff = server_fn.call(fn() { 10 + 20 + 12 }, GotValue)
  let result = capture_dispatch(eff)
  let assert GotValue(42) = result
}

pub fn try_call_success_test() {
  let eff =
    server_fn.try_call(fn() { Ok(42) }, GotValue, fn(e) { GotError(e) })
  let result = capture_dispatch(eff)
  let assert GotValue(42) = result
}

pub fn try_call_error_test() {
  let eff =
    server_fn.try_call(
      fn() { Error("oops") },
      GotValue,
      fn(e) { GotError(e) },
    )
  let result = capture_dispatch(eff)
  let assert GotError("oops") = result
}

pub fn call_async_dispatches_result_test() {
  let subject = process.new_subject()
  let eff = server_fn.call_async(fn() { 99 }, GotValue)
  effect.perform(eff, fn(msg) { process.send(subject, msg) })
  // Wait for the async process to complete
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(GotValue(99)) = process.selector_receive(selector, 1000)
}

pub fn stream_dispatches_multiple_test() {
  let subject = process.new_subject()
  let eff =
    server_fn.stream(fn(dispatch) {
      dispatch(StreamValue(1))
      dispatch(StreamValue(2))
      dispatch(StreamValue(3))
    })
  effect.perform(eff, fn(msg) { process.send(subject, msg) })
  // Wait for stream messages
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(StreamValue(1)) = process.selector_receive(selector, 1000)
  let assert Ok(StreamValue(2)) = process.selector_receive(selector, 1000)
  let assert Ok(StreamValue(3)) = process.selector_receive(selector, 1000)
}

// --- Helper ---

/// Execute an effect synchronously and capture the dispatched message.
fn capture_dispatch(eff: effect.Effect(msg)) -> msg {
  let subject = process.new_subject()
  effect.perform(eff, fn(msg) { process.send(subject, msg) })
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(msg) = process.selector_receive(selector, 1000)
  msg
}
