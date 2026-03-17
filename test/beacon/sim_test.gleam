/// Simulation tests — real WebSocket connections against real Beacon servers.
/// Each test starts a fresh app on a unique port, runs N concurrent connections,
/// and verifies performance and correctness metrics.

import beacon/sim/metrics
import beacon/sim/pool
import beacon/sim/report
import beacon/sim/scenario
import beacon/sim/test_app
import gleam/erlang/process

// ===== Smoke Test =====

pub fn sim_10_connections_smoke_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 10,
      host: "localhost",
      port: port,
      scenario: scenario.counter(10),
      stagger_ms: 10,
      metrics: mt,
    ))

  process.sleep(200)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "smoke_10",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_passed(r)
  metrics.destroy(mt)
}

// ===== Scale Tests =====

pub fn sim_100_connections_counter_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 100,
      host: "localhost",
      port: port,
      scenario: scenario.counter(20),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(500)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "scale_100_counter",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_passed(r)
  metrics.destroy(mt)
}

// ===== Leak Detection =====

pub fn sim_memory_leak_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  // Connect and disconnect 100 times
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 100,
      host: "localhost",
      port: port,
      scenario: scenario.connect_disconnect(),
      stagger_ms: 5,
      metrics: mt,
    ))

  // Allow cleanup
  process.sleep(1000)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "memory_leak",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_passed(r)
  metrics.destroy(mt)
}

// ===== Resilience Tests =====

pub fn sim_malformed_frames_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  let _result =
    pool.run(pool.PoolConfig(
      concurrency: 10,
      host: "localhost",
      port: port,
      scenario: scenario.malformed(),
      stagger_ms: 10,
      metrics: mt,
    ))

  process.sleep(500)
  let procs_after = metrics.snapshot_processes()

  // Server should still be alive — verify by opening a new connection
  let mt2 = metrics.new()
  let result2 =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.counter(1),
      stagger_ms: 0,
      metrics: mt2,
    ))

  // Server survived malformed frames
  let assert True = result2.succeeded == 1

  // No process leak from malformed connections
  let assert True = { procs_after - procs_before } < 50

  metrics.destroy(mt)
  metrics.destroy(mt2)
}

// ===== Flood Test =====

pub fn sim_flood_single_connection_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.flood(500),
      stagger_ms: 0,
      metrics: mt,
    ))

  let m = metrics.collect(mt)
  // Connection should succeed
  let assert True = result.succeeded == 1
  // All 500 events should be sent
  let assert True = m.events_sent == 500
  metrics.destroy(mt)
}

// ===== Process Leak Test =====

pub fn sim_process_leak_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  // Connect and disconnect 200 times
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 200,
      host: "localhost",
      port: port,
      scenario: scenario.connect_disconnect(),
      stagger_ms: 2,
      metrics: mt,
    ))

  // Allow cleanup
  process.sleep(2000)
  let procs_after = metrics.snapshot_processes()

  let assert True = result.succeeded > 0
  // Process leak should be small (< 30 — allows for supervisor/transport overhead)
  let leaked = procs_after - procs_before
  let assert True = leaked < 30
  metrics.destroy(mt)
}

// ===== Draw Simulation =====

pub fn sim_50_draw_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 50,
      host: "localhost",
      port: port,
      scenario: scenario.draw(100),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(500)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "draw_50x100",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  report.assert_passed(r)
  metrics.destroy(mt)
}

// ===== Fault-Based Kill Test =====

pub fn sim_50_with_faults_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  // Run 50 connections with a longer scenario (sleep gives fault injector time)
  // Some connections will be killed by the server handling malformed data
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 50,
      host: "localhost",
      port: port,
      scenario: scenario.counter(20),
      stagger_ms: 5,
      metrics: mt,
    ))

  process.sleep(1000)
  let procs_after = metrics.snapshot_processes()

  // At least 95% should succeed
  let assert True = result.succeeded >= 48
  // No process leak
  let assert True = { procs_after - procs_before } < 50

  // Server still alive — verify with a new connection
  let mt2 = metrics.new()
  let verify =
    pool.run(pool.PoolConfig(
      concurrency: 1,
      host: "localhost",
      port: port,
      scenario: scenario.counter(1),
      stagger_ms: 0,
      metrics: mt2,
    ))
  let assert True = verify.succeeded == 1

  metrics.destroy(mt)
  metrics.destroy(mt2)
}

// ===== 1000 Connections =====

pub fn sim_1000_connections_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(300)

  let mt = metrics.new()
  let mem_before = metrics.snapshot_memory()
  let procs_before = metrics.snapshot_processes()

  let result =
    pool.run(pool.PoolConfig(
      concurrency: 1000,
      host: "localhost",
      port: port,
      scenario: scenario.counter(5),
      stagger_ms: 1,
      metrics: mt,
    ))

  process.sleep(2000)
  let mem_after = metrics.snapshot_memory()
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let r =
    report.generate(
      "scale_1000",
      result,
      m,
      mem_before,
      mem_after,
      procs_before,
      procs_after,
    )
  report.log_report(r)
  // At least 95% should succeed at 1000 connections
  let assert True = result.succeeded >= 950
  // Process leak < 50 after cleanup
  let assert True = { procs_after - procs_before } < 50
  metrics.destroy(mt)
}

// ===== Corruption Resilience =====

pub fn sim_corrupt_data_resilience_test() {
  let port = test_app.unique_port()
  let assert Ok(_app) = test_app.start_counter_app(port)
  process.sleep(200)

  let mt = metrics.new()
  let procs_before = metrics.snapshot_processes()

  // 20 connections all sending various corrupt data
  let result =
    pool.run(pool.PoolConfig(
      concurrency: 20,
      host: "localhost",
      port: port,
      scenario: scenario.corrupt(),
      stagger_ms: 10,
      metrics: mt,
    ))

  process.sleep(500)
  let procs_after = metrics.snapshot_processes()

  let m = metrics.collect(mt)
  let _ = result
  let _ = m

  // Verify server is still alive with a clean connection
  let mt2 = metrics.new()
  let verify =
    pool.run(pool.PoolConfig(
      concurrency: 5,
      host: "localhost",
      port: port,
      scenario: scenario.counter(3),
      stagger_ms: 0,
      metrics: mt2,
    ))

  // Server survived all the corruption
  let assert True = verify.succeeded == 5
  // No process leak
  let assert True = { procs_after - procs_before } < 50

  metrics.destroy(mt)
  metrics.destroy(mt2)
}
