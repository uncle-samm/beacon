/// Example runner — start any example app.
/// Usage:
///   gleam run -m beacon/examples/run          (shows menu)
///   gleam run -m beacon/examples/run -- chat   (start chat)
///   gleam run -m beacon/examples/run -- ai     (start AI chat)
///   gleam run -m beacon/examples/run -- pong   (start Pong)

import beacon/application
import examples/ai_chat
import examples/chat
import examples/pong
import beacon/log
import beacon/middleware
import gleam/io
import gleam/option

pub fn main() {
  log.configure()
  let args = get_args()
  case args {
    ["chat", ..] -> start_chat()
    ["ai", ..] -> start_ai_chat()
    ["pong", ..] -> start_pong()
    _ -> {
      io.println("Beacon Example Runner")
      io.println("=====================")
      io.println("")
      io.println("Usage:")
      io.println("  gleam run -m beacon/examples/run -- chat   Multi-room chat")
      io.println("  gleam run -m beacon/examples/run -- ai     AI chat demo")
      io.println("  gleam run -m beacon/examples/run -- pong   Pong game")
      io.println("")
      io.println("Starting chat by default...")
      io.println("")
      start_chat()
    }
  }
}

fn start_chat() {
  // Initialize shared message store (accessible by all per-connection runtimes)
  let store = chat.init_store("chat_main")
  let config =
    application.AppConfig(
      port: 8080,
      init: chat.init,
      update: chat.make_update(store),
      view: chat.view,
      decode_event: chat.decode_event,
      secret_key: "beacon-chat-secret-change-in-production!!",
      title: "Beacon Chat",
      serialize_model: option.None,
      deserialize_model: option.None,
      // Subscribe all runtimes to chat:messages — when any user sends,
      // all others get notified and refresh their message list
      subscriptions: ["chat:messages"],
      on_pubsub: option.Some(fn() { chat.NewMessageBroadcast }),
      middlewares: [middleware.logger(), middleware.secure_headers()],
      static_dir: option.None,
    )
  case application.start(config) {
    Ok(_) -> {
      log.info("examples", "Chat running at http://localhost:8080")
      application.wait_forever()
    }
    Error(_) -> log.error("examples", "Failed to start chat")
  }
}

fn start_ai_chat() {
  let config =
    application.AppConfig(
      port: 8080,
      init: ai_chat.init,
      update: ai_chat.update,
      view: ai_chat.view,
      decode_event: ai_chat.decode_event,
      secret_key: "beacon-ai-secret-change-in-production!!",
      title: "Beacon AI Chat",
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      middlewares: [middleware.logger(), middleware.secure_headers()],
      static_dir: option.None,
    )
  case application.start(config) {
    Ok(_) -> {
      log.info("examples", "AI Chat running at http://localhost:8080")
      application.wait_forever()
    }
    Error(_) -> log.error("examples", "Failed to start AI chat")
  }
}

fn start_pong() {
  let config =
    application.AppConfig(
      port: 8080,
      init: pong.init,
      update: pong.update,
      view: pong.view,
      decode_event: pong.decode_event,
      secret_key: "beacon-pong-secret-change-in-production!!",
      title: "Beacon Pong",
      serialize_model: option.None,
      deserialize_model: option.None,
      subscriptions: [],
      on_pubsub: option.None,
      middlewares: [middleware.logger(), middleware.secure_headers()],
      static_dir: option.None,
    )
  case application.start(config) {
    Ok(_) -> {
      log.info("examples", "Pong running at http://localhost:8080")
      application.wait_forever()
    }
    Error(_) -> log.error("examples", "Failed to start Pong")
  }
}

@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)
