/// Environment-based configuration for Beacon apps.
/// Reads from environment variables with fallback defaults.

import gleam/int
import gleam/option.{type Option, None, Some}

/// Get an environment variable, returning None if not set.
pub fn get_env(name: String) -> Option(String) {
  case env_get(name) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

/// Get an environment variable with a default fallback.
pub fn get_env_or(name: String, default: String) -> String {
  case env_get(name) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

/// Get an integer environment variable with a default.
pub fn get_env_int(name: String, default: Int) -> Int {
  case env_get(name) {
    Ok(value) -> {
      case int.parse(value) {
        Ok(n) -> n
        Error(Nil) -> default
      }
    }
    Error(Nil) -> default
  }
}

/// Get the port from PORT env var, defaulting to 8080.
pub fn port() -> Int {
  get_env_int("PORT", 8080)
}

/// Get the secret key from SECRET_KEY env var.
pub fn secret_key() -> String {
  get_env_or("SECRET_KEY", "beacon-dev-secret-change-in-production")
}

/// Check if running in production mode.
pub fn is_production() -> Bool {
  case get_env("BEACON_ENV") {
    Some("production") | Some("prod") -> True
    _ -> False
  }
}

@external(erlang, "beacon_config_ffi", "get_env")
fn env_get(name: String) -> Result(String, Nil)
