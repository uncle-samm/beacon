/// Test application configurations for simulation testing.
/// Each function starts a real Beacon app on a given port.

import beacon/application
import beacon/effect
import beacon/element
import beacon/error
import beacon/middleware
import gleam/dict
import gleam/int
import gleam/option

/// Simple counter app — accepts "inc" events, renders "count:N".
pub type CounterModel {
  CounterModel(count: Int)
}

pub type CounterMsg {
  CounterInc
}

pub fn start_counter_app(
  port: Int,
) -> Result(application.App, error.BeaconError) {
  let config =
    application.AppConfig(
      port: port,
      init: fn() { #(CounterModel(count: 0), effect.none()) },
      update: fn(model: CounterModel, _msg) {
        #(CounterModel(count: model.count + 1), effect.none())
      },
      view: fn(model: CounterModel) {
        element.el("div", [element.attr("id", "app")], [
          element.text("count:" <> int.to_string(model.count)),
        ])
      },
      decode_event: option.Some(fn(_name, _handler_id, _data, _path) {
        // Accept ALL handler IDs — simulation tests send various IDs
        // (h0=mousedown, h1=mouseup, h2=mousemove, inc, etc.)
        Ok(CounterInc)
      }),
      secret_key: "sim-test-secret-key-long-enough-for-hmac!!",
      title: "Sim Counter",
      serialize_model: option.None,
      deserialize_model: option.None,
      middlewares: [middleware.secure_headers()],
      static_dir: option.None,
      route_patterns: [],
      on_route_change: option.None,
      server_fns: dict.new(),
      dynamic_subscriptions: option.None,
      on_notify: option.None,
    )
  application.start(config)
}

/// Generate a unique port in the 12000-12999 range for parallel test execution.
pub fn unique_port() -> Int {
  12_000 + { erlang_unique_pos() % 1000 }
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_pos() -> Int
