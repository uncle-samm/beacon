/// Rate limiting using ETS counters.
/// Tracks request counts per key (typically IP address) within a time window.
///
/// Reference: Phoenix rate limiting, OWASP rate limiting guidelines.

import beacon/log
import gleam/int

/// Rate limit configuration.
pub type RateLimitConfig {
  RateLimitConfig(
    /// Maximum requests allowed per window.
    max_requests: Int,
    /// Window duration in seconds.
    window_seconds: Int,
  )
}

/// A rate limiter backed by ETS.
pub type RateLimiter {
  RateLimiter(table: EtsTable, config: RateLimitConfig)
}

/// Result of a rate limit check.
pub type RateLimitResult {
  /// Request is allowed.
  Allowed(remaining: Int)
  /// Request is rate limited.
  RateLimited
}

/// Opaque ETS table reference.
pub type EtsTable

/// Create a new rate limiter.
pub fn new(name: String, config: RateLimitConfig) -> RateLimiter {
  log.info(
    "beacon.rate_limit",
    "Creating rate limiter: "
      <> name
      <> " ("
      <> int.to_string(config.max_requests)
      <> " req/"
      <> int.to_string(config.window_seconds)
      <> "s)",
  )
  let table = ets_new(name)
  RateLimiter(table: table, config: config)
}

/// Check if a request from the given key is allowed.
/// Increments the counter and returns Allowed or RateLimited.
pub fn check(limiter: RateLimiter, key: String) -> RateLimitResult {
  let now = system_time_seconds()
  let window_key =
    key <> ":" <> int.to_string(now / limiter.config.window_seconds)
  let count = ets_increment(limiter.table, window_key)
  case count > limiter.config.max_requests {
    True -> {
      log.warning(
        "beacon.rate_limit",
        "Rate limited: " <> key,
      )
      RateLimited
    }
    False -> Allowed(remaining: limiter.config.max_requests - count)
  }
}

/// Reset the counter for a key (useful for testing).
pub fn reset(limiter: RateLimiter, key: String) -> Nil {
  ets_delete(limiter.table, key)
}

// --- ETS FFI ---

@external(erlang, "beacon_rate_limit_ffi", "new_table")
fn ets_new(name: String) -> EtsTable

@external(erlang, "beacon_rate_limit_ffi", "increment")
fn ets_increment(table: EtsTable, key: String) -> Int

@external(erlang, "beacon_rate_limit_ffi", "delete_key")
fn ets_delete(table: EtsTable, key: String) -> Nil

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn system_time_seconds() -> Int
