import beacon/substate
import gleam/erlang/process

pub type CountState {
  CountState(count: Int)
}

pub type CountMsg {
  Inc
  Dec
}

fn count_update(state: CountState, msg: CountMsg) -> CountState {
  case msg {
    Inc -> CountState(count: state.count + 1)
    Dec -> CountState(count: state.count - 1)
  }
}

fn count_config() -> substate.SubstateConfig(CountState, CountMsg) {
  substate.SubstateConfig(
    name: "counter",
    initial: CountState(count: 0),
    update: count_update,
  )
}

pub fn start_substate_test() {
  let assert Ok(_subject) = substate.start(count_config())
}

pub fn get_initial_state_test() {
  let assert Ok(subject) = substate.start(count_config())
  let state = substate.get(subject, 1000)
  let assert 0 = state.count
}

pub fn update_state_test() {
  let assert Ok(subject) = substate.start(count_config())
  substate.update(subject, Inc)
  process.sleep(20)
  let state = substate.get(subject, 1000)
  let assert 1 = state.count
}

pub fn multiple_updates_test() {
  let assert Ok(subject) = substate.start(count_config())
  substate.update(subject, Inc)
  substate.update(subject, Inc)
  substate.update(subject, Inc)
  substate.update(subject, Dec)
  process.sleep(20)
  let state = substate.get(subject, 1000)
  let assert 2 = state.count
}

pub fn set_state_test() {
  let assert Ok(subject) = substate.start(count_config())
  substate.set(subject, CountState(count: 42))
  process.sleep(20)
  let state = substate.get(subject, 1000)
  let assert 42 = state.count
}

pub fn shutdown_test() {
  let assert Ok(subject) = substate.start(count_config())
  substate.shutdown(subject)
  process.sleep(50)
  // After shutdown, the actor is gone — this is expected.
}

pub fn concurrent_substates_test() {
  // Multiple substates can run concurrently
  let assert Ok(s1) = substate.start(substate.SubstateConfig(
    name: "counter1",
    initial: CountState(count: 0),
    update: count_update,
  ))
  let assert Ok(s2) = substate.start(substate.SubstateConfig(
    name: "counter2",
    initial: CountState(count: 100),
    update: count_update,
  ))

  substate.update(s1, Inc)
  substate.update(s2, Dec)
  process.sleep(20)

  let state1 = substate.get(s1, 1000)
  let state2 = substate.get(s2, 1000)
  let assert 1 = state1.count
  let assert 99 = state2.count
}
