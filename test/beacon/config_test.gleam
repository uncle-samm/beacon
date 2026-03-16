import beacon/config

pub fn get_env_missing_test() {
  let assert option.None = config.get_env("BEACON_TEST_NONEXISTENT_VAR")
}

pub fn get_env_or_default_test() {
  let assert "fallback" = config.get_env_or("BEACON_TEST_NONEXISTENT_VAR", "fallback")
}

pub fn get_env_int_default_test() {
  let assert 8080 = config.get_env_int("BEACON_TEST_NONEXISTENT_VAR", 8080)
}

pub fn port_default_test() {
  // PORT env var unlikely to be set in test
  let port = config.port()
  let assert True = port > 0
}

pub fn secret_key_has_default_test() {
  let key = config.secret_key()
  let assert True = key != ""
}

import gleam/option
