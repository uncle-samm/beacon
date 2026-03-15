/// Counter example — demonstrates the full Beacon stack.
/// A simple counter that increments/decrements via button clicks.
/// Server owns all state; client is a thin rendering layer.

import beacon/effect
import beacon/element
import beacon/error
import beacon/log
import beacon/runtime
import beacon/ssr
import beacon/transport
import gleam/int
import gleam/option

/// The model — just a count.
pub type Model {
  Model(count: Int)
}

/// Messages the counter can receive.
pub type Msg {
  Increment
  Decrement
}

/// Initialize the counter with count = 0, no effects.
pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(Model(count: 0), effect.none())
}

/// Update the model based on the message.
pub fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    Increment -> {
      log.info("counter", "Incrementing: " <> int.to_string(model.count + 1))
      #(Model(count: model.count + 1), effect.none())
    }
    Decrement -> {
      log.info("counter", "Decrementing: " <> int.to_string(model.count - 1))
      #(Model(count: model.count - 1), effect.none())
    }
  }
}

/// Render the counter view.
pub fn view(model: Model) -> element.Node(Msg) {
  element.el("div", [element.attr("class", "counter")], [
    element.el("h1", [], [element.text("Beacon Counter")]),
    element.el("p", [], [
      element.text("Count: " <> int.to_string(model.count)),
    ]),
    element.el(
      "button",
      [element.on("click", "decrement")],
      [element.text("-")],
    ),
    element.el(
      "button",
      [element.on("click", "increment")],
      [element.text("+")],
    ),
  ])
}

/// Decode client events into counter messages.
/// Uses handler_id (from data-beacon-event-* attribute value) to identify
/// which action to take. This is the proper approach — no fragile path routing.
pub fn decode_event(
  name: String,
  handler_id: String,
  _data: String,
  _target_path: String,
) -> Result(Msg, error.BeaconError) {
  log.debug(
    "counter",
    "Decoding event: " <> name <> " handler: " <> handler_id,
  )
  case handler_id {
    "increment" -> Ok(Increment)
    "decrement" -> Ok(Decrement)
    _ -> {
      log.warning(
        "counter",
        "Unknown handler_id: " <> handler_id <> " for event: " <> name,
      )
      Error(error.RuntimeError(
        reason: "Unknown handler: " <> handler_id,
      ))
    }
  }
}

/// Start the counter application.
pub fn start(port: Int) -> Result(Nil, error.BeaconError) {
  log.configure()
  log.info("counter", "Starting counter example on port " <> int.to_string(port))

  // Start the runtime
  let config =
    runtime.RuntimeConfig(
      init: init,
      update: update,
      view: view,
      decode_event: decode_event,
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
    )
  case runtime.start(config) {
    Ok(runtime_subject) -> {
      // SSR: render the initial page
      let ssr_config =
        ssr.SsrConfig(
          init: init,
          view: view,
          secret_key: "beacon-counter-secret-key-change-in-prod!!",
          title: "Beacon Counter",
        )
      let page = ssr.render_page(ssr_config)
      log.info("counter", "SSR page rendered with token: " <> page.session_token)

      // Wire transport to runtime with SSR-rendered HTML
      let transport_config =
        runtime.connect_transport_with_ssr(
          runtime_subject,
          port,
          option.Some(page.html),
        )
      case transport.start(transport_config) {
        Ok(_pid) -> {
          log.info("counter", "Counter example running on port " <> int.to_string(port))
          Ok(Nil)
        }
        Error(err) -> {
          log.error("counter", "Failed to start transport: " <> error.to_string(err))
          Error(err)
        }
      }
    }
    Error(err) -> {
      log.error("counter", "Failed to start runtime: " <> error.to_string(err))
      Error(err)
    }
  }
}
