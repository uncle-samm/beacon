import beacon_client

pub type TestMsg {
  TestMsg
}

pub fn main() -> Nil {
  keydown_forces_server_send_test()
  click_local_only_remains_local_test()
  model_changes_still_send_test()
  Nil
}

pub fn keydown_forces_server_send_test() {
  let assert True =
    beacon_client.should_send_to_server("keydown", fn(_msg) { False }, TestMsg)
}

pub fn click_local_only_remains_local_test() {
  let assert False =
    beacon_client.should_send_to_server("click", fn(_msg) { False }, TestMsg)
}

pub fn model_changes_still_send_test() {
  let assert True =
    beacon_client.should_send_to_server("click", fn(_msg) { True }, TestMsg)
}
