import beacon/lint
import gleam/list

pub fn clean_code_no_violations_test() {
  let source =
    "
pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [] = violations
}

pub fn todo_detected_test() {
  let source =
    "
pub fn incomplete() {
  todo
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert "no-todo" = v.rule
  let assert True = str_contains(v.message, "todo")
}

pub fn panic_detected_test() {
  let source =
    "
pub fn bad() {
  panic
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert "no-panic" = v.rule
  let assert True = str_contains(v.message, "panic")
}

pub fn todo_in_nested_expression_test() {
  let source =
    "
pub fn nested() {
  case True {
    True -> todo
    False -> \"ok\"
  }
}
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert "no-todo" = v.rule
}

pub fn multiple_violations_test() {
  let source =
    "
pub fn bad1() { todo }
pub fn bad2() { panic }
"
  let violations = lint.lint_source("test.gleam", source)
  let assert 2 = list.length(violations)
}

pub fn private_functions_also_checked_test() {
  let source =
    "
fn helper() { todo }
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [_v] = violations
}

pub fn violation_includes_function_name_test() {
  let source =
    "
pub fn my_function() { todo }
"
  let violations = lint.lint_source("test.gleam", source)
  let assert [v] = violations
  let assert True = str_contains(v.message, "my_function")
}

pub fn violation_includes_file_path_test() {
  let source =
    "
pub fn bad() { todo }
"
  // Use a non-key-module path to avoid the logging rule
  let violations = lint.lint_source("src/beacon/other.gleam", source)
  let assert [v] = violations
  let assert "src/beacon/other.gleam" = v.file
}

pub fn violation_to_string_format_test() {
  let v =
    lint.Violation(
      file: "src/test.gleam",
      location: "byte 10-20",
      rule: "no-todo",
      message: "Found todo",
    )
  let result = lint.violation_to_string(v)
  let assert True = str_contains(result, "src/test.gleam")
  let assert True = str_contains(result, "no-todo")
  let assert True = str_contains(result, "Found todo")
}

pub fn public_fn_without_log_in_key_module_test() {
  let source =
    "
pub fn handle() { Nil }
"
  let violations =
    lint.lint_source("src/beacon/transport.gleam", source)
  let assert [v] = violations
  let assert "public-fn-must-log" = v.rule
}

pub fn public_fn_with_log_passes_test() {
  let source =
    "
import beacon/log
pub fn handle() { log.info(\"mod\", \"msg\") }
"
  let violations =
    lint.lint_source("src/beacon/runtime.gleam", source)
  let assert [] = violations
}

pub fn private_fn_not_checked_for_log_test() {
  let source =
    "
fn helper() { Nil }
"
  let violations =
    lint.lint_source("src/beacon/transport.gleam", source)
  let assert [] = violations
}

pub fn non_key_module_not_checked_for_log_test() {
  let source =
    "
pub fn handle() { Nil }
"
  let violations =
    lint.lint_source("src/beacon/form.gleam", source)
  let assert [] = violations
}

pub fn invalid_source_no_crash_test() {
  let source = "this is not valid gleam @@@"
  let violations = lint.lint_source("bad.gleam", source)
  // Should not crash, just return empty
  let assert [] = violations
}

// --- Helper ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
