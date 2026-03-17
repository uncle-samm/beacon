/// Example runner — start any example app.
/// Usage:
///   gleam run -m beacon/examples/run          (starts chat)
///   gleam run -m beacon/examples/run -- chat   (multi-room chat)
///   gleam run -m beacon/examples/run -- counter (counter)
///   gleam run -m beacon/examples/run -- ai     (AI chat demo)
///   gleam run -m beacon/examples/run -- pong   (Pong game)

import beacon
import beacon/examples/ai_chat
import beacon/examples/chat
import beacon/examples/counter
import beacon/examples/counter_local
import beacon/examples/pong
import beacon/examples/snake
import beacon/examples/triple_counter
import gleam/io

pub fn main() {
  let args = get_args()
  case args {
    ["chat", ..] -> chat.start()
    ["counter", ..] -> counter.main()
    ["local", ..] -> counter_local.main()
    ["triple", ..] -> triple_counter.start()
    ["ai", ..] -> start_ai_chat()
    ["pong", ..] -> start_pong()
    ["snake", ..] -> snake.start()
    _ -> {
      io.println("Beacon Examples — run with: gleam run -m beacon/examples/run -- [chat|counter|ai|pong]")
      io.println("Starting chat by default...")
      chat.start()
    }
  }
}

fn start_ai_chat() {
  beacon.app_with_effects(ai_chat.init, ai_chat.update, ai_chat.view)
  |> beacon.title("Beacon AI Chat")
  |> beacon.start(8080)
}

fn start_pong() {
  beacon.app_with_effects(pong.init, pong.update, pong.view)
  |> beacon.title("Beacon Pong")
  |> beacon.start(8080)
}

@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)
