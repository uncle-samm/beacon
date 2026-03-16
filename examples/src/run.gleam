/// Example runner — start any example app.
/// Usage (from examples/ directory):
///   gleam run -m run               (lists examples)
///   gleam run -m run -- counter     (simple counter)
///   gleam run -m run -- local       (counter with local state)
///   gleam run -m run -- triple      (triple counter - shared/server/local)
///   gleam run -m run -- chat        (multi-room chat)
///   gleam run -m run -- canvas      (multi-user drawing canvas)

import canvas
import chat
import counter
import counter_local
import triple_counter
import gleam/io

pub fn main() {
  let args = get_args()
  case args {
    ["counter", ..] -> counter.main()
    ["local", ..] -> counter_local.main()
    ["triple", ..] -> triple_counter.start()
    ["chat", ..] -> chat.start()
    ["canvas", ..] -> canvas.main()
    _ -> {
      io.println("Beacon Examples")
      io.println("===============")
      io.println("Run with: gleam run -m run -- <example>")
      io.println("")
      io.println("Available examples:")
      io.println("  counter   — Simple counter (server-rendered)")
      io.println("  local     — Counter with local state (zero WS traffic)")
      io.println("  triple    — Triple counter (shared + server + local)")
      io.println("  chat      — Multi-room chat with shared state")
      io.println("  canvas    — Multi-user drawing canvas")
      io.println("")
      io.println("Starting counter by default...")
      counter.main()
    }
  }
}

@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)
