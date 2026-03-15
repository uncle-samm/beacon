import beacon/stress

pub fn stress_100_processes_test() {
  let config =
    stress.StressConfig(
      connections: 100,
      host: "localhost",
      port: 0,
      hold_duration_ms: 500,
    )
  let result = stress.run(config)
  let assert 100 = result.attempted
  let assert 100 = result.succeeded
  let assert 0 = result.failed
  // Process count during should be higher than before (100 spawned processes)
  let assert True = result.processes_during > result.processes_before
}

pub fn stress_processes_cleaned_up_test() {
  let config =
    stress.StressConfig(
      connections: 50,
      host: "localhost",
      port: 0,
      hold_duration_ms: 200,
    )
  let result = stress.run(config)
  // All 50 should succeed
  let assert 50 = result.succeeded
  // After cleanup, process count should not have leaked 50 processes
  // Allow generous variance for test runner processes
  let assert True = result.processes_after < result.processes_before + 30
}
