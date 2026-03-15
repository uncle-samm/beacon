import beacon/examples/counter
import beacon/log
import gleam/erlang/process

pub fn main() -> Nil {
  log.configure()
  case counter.start(8080) {
    Ok(Nil) -> {
      log.info("beacon", "Server running at http://localhost:8080")
      // Keep the main process alive so the server stays running
      process.sleep_forever()
    }
    Error(_err) -> {
      log.error("beacon", "Failed to start server")
      Nil
    }
  }
}
