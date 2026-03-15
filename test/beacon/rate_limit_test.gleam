import beacon/rate_limit
import gleam/int

pub fn allowed_within_limit_test() {
  let limiter =
    rate_limit.new(
      "test_allow_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 5, window_seconds: 60),
    )
  let assert rate_limit.Allowed(remaining: 4) =
    rate_limit.check(limiter, "127.0.0.1")
}

pub fn rate_limited_over_limit_test() {
  let limiter =
    rate_limit.new(
      "test_limit_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 3, window_seconds: 60),
    )
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "10.0.0.1")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "10.0.0.1")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "10.0.0.1")
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "10.0.0.1")
}

pub fn different_keys_independent_test() {
  let limiter =
    rate_limit.new(
      "test_keys_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 2, window_seconds: 60),
    )
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "ip_a")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "ip_a")
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "ip_a")
  // Different key should still be allowed
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "ip_b")
}

pub fn remaining_decreases_test() {
  let limiter =
    rate_limit.new(
      "test_rem_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 5, window_seconds: 60),
    )
  let assert rate_limit.Allowed(remaining: 4) =
    rate_limit.check(limiter, "test_ip")
  let assert rate_limit.Allowed(remaining: 3) =
    rate_limit.check(limiter, "test_ip")
  let assert rate_limit.Allowed(remaining: 2) =
    rate_limit.check(limiter, "test_ip")
}

fn unique_id() -> String {
  int.to_string(do_unique())
}

@external(erlang, "erlang", "unique_integer")
fn do_unique() -> Int
