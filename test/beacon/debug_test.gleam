import beacon/debug
import gleam/erlang/process

pub fn stats_returns_valid_data_test() {
  let s = debug.stats()
  let assert True = s.process_count > 0
  let assert True = s.memory_bytes > 0
  let assert True = s.uptime_seconds >= 0
}

pub fn is_alive_test() {
  let pid = process.self()
  let assert True = debug.is_alive(pid)
}

pub fn log_stats_does_not_crash_test() {
  debug.log_stats()
}
