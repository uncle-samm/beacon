import beacon/log

/// Test that logging functions execute without crashing.
/// We can't easily capture log output in tests, but we can verify
/// that the functions don't panic — which confirms the logging
/// package integration works.

pub fn info_does_not_crash_test() {
  log.configure()
  log.info("log_test", "info message works")
}

pub fn debug_does_not_crash_test() {
  log.configure()
  log.debug("log_test", "debug message works")
}

pub fn warning_does_not_crash_test() {
  log.configure()
  log.warning("log_test", "warning message works")
}

pub fn error_does_not_crash_test() {
  log.configure()
  log.error("log_test", "error message works")
}
