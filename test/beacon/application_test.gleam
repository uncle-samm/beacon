import beacon/application
import beacon/effect
import beacon/element
import beacon/error
import beacon/middleware as beacon_middleware
import gleam/dict
import gleam/erlang/process
import gleam/int

pub type TestModel {
  TestModel(count: Int)
}

pub type TestMsg {
  Inc
}

fn test_config(port: Int) -> application.AppConfig(TestModel, TestMsg) {
  application.AppConfig(
    port: port,
    init: fn() { #(TestModel(count: 0), effect.none()) },
    update: fn(model, _msg) {
      #(TestModel(count: model.count + 1), effect.none())
    },
    view: fn(model: TestModel) {
      element.el("div", [], [
        element.text(int.to_string(model.count)),
      ])
    },
    decode_event: option.Some(fn(_name, handler_id, _data, _path) {
      case handler_id {
        "inc" -> Ok(Inc)
        _ -> Error(error.RuntimeError(reason: "unknown"))
      }
    }),
    secret_key: "test-secret-key-must-be-long-enough!!",
    title: "Test App",
    serialize_model: option.None,
    deserialize_model: option.None,
    middlewares: [],
    static_dir: option.None,
    route_patterns: [],
    on_route_change: option.None,
    server_fns: dict.new(), dynamic_subscriptions: option.None, on_notify: option.None,
  )
}

import gleam/option

pub fn application_starts_test() {
  // Use a unique port to avoid conflicts
  let port = 9100 + unique_port_offset()
  let assert Ok(_app) = application.start(test_config(port))
  process.sleep(50)
}

pub fn application_supervised_starts_test() {
  let port = 9200 + unique_port_offset()
  let assert Ok(_app) = application.start_supervised(test_config(port))
  process.sleep(50)
}

pub fn application_returns_supervisor_pid_test() {
  let port = 9300 + unique_port_offset()
  let assert Ok(app) = application.start(test_config(port))
  // PID should be valid
  let assert True = is_process_alive(app.supervisor_pid)
}

fn unique_port_offset() -> Int {
  erlang_unique_pos() % 100
}

pub fn application_with_middleware_starts_test() {
  let port = 9400 + unique_port_offset()
  let config =
    application.AppConfig(
      ..test_config(port),
      middlewares: [beacon_middleware.secure_headers()],
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(50)
}

pub fn application_with_static_dir_starts_test() {
  let port = 9500 + unique_port_offset()
  let config =
    application.AppConfig(
      ..test_config(port),
      static_dir: option.Some("priv/static"),
    )
  let assert Ok(_app) = application.start(config)
  process.sleep(50)
}

fn erlang_unique_pos() -> Int {
  do_unique_pos()
}

@external(erlang, "erlang", "unique_integer")
fn do_unique_pos() -> Int

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: process.Pid) -> Bool
