/// Simulation report — aggregates metrics, computes percentiles,
/// detects leaks, generates pass/fail assertions.

import beacon/log
import beacon/sim/metrics.{type SimMetrics}
import beacon/sim/pool.{type PoolResult}
import gleam/float
import gleam/int

/// Simulation report with computed statistics.
pub type SimReport {
  SimReport(
    scenario_name: String,
    total_connections: Int,
    succeeded: Int,
    failed: Int,
    success_rate: Float,
    events_sent: Int,
    events_acked: Int,
    event_loss_rate: Float,
    p50_latency_us: Int,
    p99_latency_us: Int,
    max_latency_us: Int,
    memory_before: Int,
    memory_after: Int,
    memory_delta_kb: Int,
    processes_before: Int,
    processes_after: Int,
    processes_leaked: Int,
    duration_ms: Int,
    /// Wire efficiency metrics
    bytes_sent: Int,
    bytes_received: Int,
    patches_received: Int,
    model_syncs_received: Int,
    mounts_received: Int,
  )
}

/// Generate a report from pool results and collected metrics.
pub fn generate(
  name: String,
  pool: PoolResult,
  m: SimMetrics,
  mem_before: Int,
  mem_after: Int,
  procs_before: Int,
  procs_after: Int,
) -> SimReport {
  let success_rate = case pool.total > 0 {
    True -> int.to_float(pool.succeeded) /. int.to_float(pool.total)
    False -> 0.0
  }
  let event_loss_rate = case m.events_sent > 0 {
    True ->
      int.to_float(m.events_failed)
      /. int.to_float(m.events_sent)
    False -> 0.0
  }

  SimReport(
    scenario_name: name,
    total_connections: pool.total,
    succeeded: pool.succeeded,
    failed: pool.failed,
    success_rate: success_rate,
    events_sent: m.events_sent,
    events_acked: m.events_acked,
    event_loss_rate: event_loss_rate,
    p50_latency_us: metrics.percentile(m.latencies_us, 0.5),
    p99_latency_us: metrics.percentile(m.latencies_us, 0.99),
    max_latency_us: metrics.percentile(m.latencies_us, 1.0),
    memory_before: mem_before,
    memory_after: mem_after,
    memory_delta_kb: { mem_after - mem_before } / 1024,
    processes_before: procs_before,
    processes_after: procs_after,
    processes_leaked: procs_after - procs_before,
    duration_ms: pool.duration_ms,
    bytes_sent: m.bytes_sent,
    bytes_received: m.bytes_received,
    patches_received: m.patches_received,
    model_syncs_received: m.model_syncs_received,
    mounts_received: m.mounts_received,
  )
}

/// Log the report.
pub fn log_report(r: SimReport) -> Nil {
  log.info("beacon.sim", "=== Simulation Report: " <> r.scenario_name <> " ===")
  log.info(
    "beacon.sim",
    "Connections: "
      <> int.to_string(r.succeeded)
      <> "/"
      <> int.to_string(r.total_connections)
      <> " succeeded ("
      <> float.to_string(r.success_rate *. 100.0)
      <> "%)",
  )
  log.info(
    "beacon.sim",
    "Events: "
      <> int.to_string(r.events_sent)
      <> " sent, "
      <> int.to_string(r.events_acked)
      <> " acked, "
      <> int.to_string(r.events_sent - r.events_acked)
      <> " unacked",
  )
  log.info(
    "beacon.sim",
    "Latency: p50="
      <> int.to_string(r.p50_latency_us)
      <> "us p99="
      <> int.to_string(r.p99_latency_us)
      <> "us max="
      <> int.to_string(r.max_latency_us)
      <> "us",
  )
  log.info(
    "beacon.sim",
    "Memory: delta="
      <> int.to_string(r.memory_delta_kb)
      <> "KB, Processes: delta="
      <> int.to_string(r.processes_leaked),
  )
  log.info(
    "beacon.sim",
    "Duration: " <> int.to_string(r.duration_ms) <> "ms",
  )
  log.info(
    "beacon.sim",
    "Wire: "
      <> int.to_string(r.bytes_sent)
      <> "B sent, "
      <> int.to_string(r.bytes_received)
      <> "B recv, "
      <> int.to_string(r.patches_received)
      <> " patches, "
      <> int.to_string(r.model_syncs_received)
      <> " syncs, "
      <> int.to_string(r.mounts_received)
      <> " mounts",
  )
}

/// Assert the report passes standard thresholds.
pub fn assert_passed(r: SimReport) -> Nil {
  // Success rate >= 90%
  let assert True = r.success_rate >=. 0.9
  // Process leak < 50
  let assert True = r.processes_leaked < 50
  Nil
}

/// Assert strict pass criteria for non-fault scenarios.
pub fn assert_strict(r: SimReport) -> Nil {
  // Success rate >= 99%
  let assert True = r.success_rate >=. 0.99
  // Process leak < 20
  let assert True = r.processes_leaked < 20
  Nil
}

/// Assert the report passes strict thresholds for clean (non-fault) scenarios.
pub fn assert_clean_passed(r: SimReport) -> Nil {
  // Clean scenarios should have 100% success rate (or very close)
  let assert True = r.success_rate >=. 0.98
  // Process leak < 20
  let assert True = r.processes_leaked < 20
  Nil
}

/// Assert wire efficiency: if patches were received, they must outnumber
/// model_syncs. This proves the patch optimization is working — after the
/// initial model_sync on join, subsequent updates use smaller patches.
pub fn assert_patch_efficiency(r: SimReport) -> Nil {
  case r.patches_received > 0 {
    True -> {
      let assert True = r.patches_received > r.model_syncs_received
      Nil
    }
    // No patches means no events were sent — nothing to assert
    False -> Nil
  }
}
