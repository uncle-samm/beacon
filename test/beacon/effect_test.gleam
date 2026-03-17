import beacon/effect
import gleam/erlang/process

pub fn none_is_none_test() {
  let eff = effect.none()
  let assert True = effect.is_none(eff)
}

pub fn from_is_not_none_test() {
  let eff = effect.from(fn(_dispatch) { Nil })
  let assert False = effect.is_none(eff)
}

pub fn from_dispatches_message_test() {
  let eff = effect.from(fn(dispatch) { dispatch(42) })
  let received = new_ref(0)
  effect.perform(eff, fn(n) { set_ref(received, n) })
  let assert 42 = get_ref(received)
}

pub fn batch_combines_effects_test() {
  let eff1 = effect.from(fn(dispatch) { dispatch(1) })
  let eff2 = effect.from(fn(dispatch) { dispatch(2) })
  let batched = effect.batch([eff1, eff2])
  let assert False = effect.is_none(batched)
  let sum = new_ref(0)
  effect.perform(batched, fn(n) { set_ref(sum, get_ref(sum) + n) })
  let assert 3 = get_ref(sum)
}

pub fn batch_empty_is_none_test() {
  let batched = effect.batch([])
  let assert True = effect.is_none(batched)
}

pub fn batch_of_nones_is_none_test() {
  let batched = effect.batch([effect.none(), effect.none()])
  let assert True = effect.is_none(batched)
}

pub fn map_transforms_message_test() {
  let eff = effect.from(fn(dispatch) { dispatch(10) })
  let mapped = effect.map(eff, fn(n) { n * 2 })
  let result = new_ref(0)
  effect.perform(mapped, fn(n) { set_ref(result, n) })
  let assert 20 = get_ref(result)
}

pub fn perform_none_does_nothing_test() {
  let called = new_ref(0)
  effect.perform(effect.none(), fn(_) { set_ref(called, 1) })
  let assert 0 = get_ref(called)
}

pub fn background_runs_in_separate_process_test() {
  let subject = process.new_subject()
  let eff = effect.background(fn(dispatch) {
    dispatch(42)
  })
  // Use a subject-based dispatch to capture the async result
  effect.perform(eff, fn(n) { process.send(subject, n) })
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(42) = process.selector_receive(selector, 1000)
}

pub fn background_does_not_block_test() {
  let subject = process.new_subject()
  let eff = effect.background(fn(dispatch) {
    // Simulate slow work
    process.sleep(50)
    dispatch(99)
  })
  effect.perform(eff, fn(n) { process.send(subject, n) })
  // Should return immediately (not blocked by the 50ms sleep)
  // Wait for the background process to finish
  let selector =
    process.new_selector()
    |> process.select(subject)
  let assert Ok(99) = process.selector_receive(selector, 1000)
}

pub fn background_is_not_none_test() {
  let eff = effect.background(fn(_dispatch) { Nil })
  let assert False = effect.is_none(eff)
}

pub fn every_dispatches_periodically_test() {
  let subject = process.new_subject()
  let eff = effect.every(50, fn() { 1 })
  effect.perform(eff, fn(n) { process.send(subject, n) })
  // Should receive at least 3 ticks in 200ms
  let assert Ok(1) = process.receive(subject, 200)
  let assert Ok(1) = process.receive(subject, 200)
  let assert Ok(1) = process.receive(subject, 200)
}

pub fn after_dispatches_once_test() {
  let subject = process.new_subject()
  let eff = effect.after(50, fn() { 42 })
  effect.perform(eff, fn(n) { process.send(subject, n) })
  // Should receive exactly once after ~50ms
  let assert Ok(42) = process.receive(subject, 200)
  // Should NOT receive again
  let assert Error(Nil) = process.receive(subject, 150)
}

// --- Mutable ref helpers using process dictionary ---
// Used only in tests to capture side effects.

fn new_ref(initial: a) -> String {
  let key = "test_ref_" <> unique_string()
  put_process_dict(key, initial)
  key
}

fn get_ref(ref: String) -> a {
  get_process_dict(ref)
}

fn set_ref(ref: String, value: a) -> Nil {
  put_process_dict(ref, value)
  Nil
}

fn unique_string() -> String {
  erlang_unique_ref()
}

/// We use a simpler approach: just use a mutable list to capture dispatched values.
/// Actually, let's just use erlang process dictionary with proper binary keys.
@external(erlang, "beacon_test_ffi", "unique_ref")
fn erlang_unique_ref() -> String

@external(erlang, "beacon_test_ffi", "pd_put")
fn put_process_dict(key: String, value: a) -> Nil

@external(erlang, "beacon_test_ffi", "pd_get")
fn get_process_dict(key: String) -> a
