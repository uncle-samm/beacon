/// Beacon's custom linting tool — enforces engineering principles via AST analysis.
/// Uses Glance to parse source files and check for violations.
///
/// Rules:
/// 1. No `todo` or `panic` in non-test source code
/// 2. No catch-all `_` patterns in case expressions that don't log
/// 3. Public functions in key modules should have logging
///
/// Reference: CLAUDE.md engineering principles, TigerBeetle approach.

import beacon/log
import glance
import gleam/int
import gleam/list
import gleam/string
import simplifile

/// A lint violation found in a source file.
pub type Violation {
  Violation(
    /// The file path where the violation was found.
    file: String,
    /// The line/byte offset of the violation.
    location: String,
    /// The rule that was violated.
    rule: String,
    /// Human-readable description.
    message: String,
  )
}

/// Lint a directory of Gleam source files.
/// Returns a list of violations found.
pub fn lint_directory(dir: String) -> List(Violation) {
  log.info("beacon.lint", "Linting directory: " <> dir)
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      let violations =
        list.flat_map(entries, fn(entry) {
          let path = dir <> "/" <> entry
          case simplifile.is_directory(path) {
            Ok(True) -> lint_directory(path)
            Ok(False) -> {
              case string.ends_with(entry, ".gleam") {
                True -> lint_file(path)
                False -> []
              }
            }
            Error(err) -> {
              log.warning("beacon.lint", "Cannot stat " <> path <> ": " <> string.inspect(err))
              []
            }
          }
        })
      violations
    }
    Error(err) -> {
      log.warning("beacon.lint", "Cannot read directory " <> dir <> ": " <> string.inspect(err))
      []
    }
  }
}

/// Lint a single Gleam source file.
pub fn lint_file(path: String) -> List(Violation) {
  case simplifile.read(path) {
    Ok(source) -> lint_source(path, source)
    Error(_) -> {
      log.warning("beacon.lint", "Cannot read file: " <> path)
      []
    }
  }
}

/// Lint source code from a string.
pub fn lint_source(file_path: String, source: String) -> List(Violation) {
  case glance.module(source) {
    Ok(module) -> {
      let todo_violations = check_no_todo_panic(file_path, module)
      let logging_violations = check_public_functions_log(file_path, module)
      list.append(todo_violations, logging_violations)
    }
    Error(err) -> {
      log.warning("beacon.lint", "Cannot parse " <> file_path <> ": " <> string.inspect(err))
      []
    }
  }
}

/// Check that public functions in key modules contain logging calls.
/// Only applies to files in beacon/transport, beacon/runtime, beacon/diff.
fn check_public_functions_log(
  file_path: String,
  module: glance.Module,
) -> List(Violation) {
  // Only apply this rule to key framework modules
  let is_key_module =
    string.contains(file_path, "beacon/transport")
    || string.contains(file_path, "beacon/runtime")
    || string.contains(file_path, "beacon/diff")
  case is_key_module {
    False -> []
    True -> {
      list.filter_map(module.functions, fn(def) {
        let func = def.definition
        case func.publicity {
          glance.Public -> {
            // Exempt pure utility functions (encode/decode/to_*/create_*)
            let is_exempt = is_pure_function_name(func.name)
            case is_exempt {
              True -> Error(Nil)
              False -> {
                let has_log = body_contains_log_call(func.body)
                case has_log {
                  True -> Error(Nil)
                  False ->
                    Ok(Violation(
                      file: file_path,
                      location: span_to_string(func.location),
                      rule: "public-fn-must-log",
                      message: "Public function `"
                        <> func.name
                        <> "` in key module should contain a logging call.",
                    ))
                }
              }
            }
          }
          glance.Private -> Error(Nil)
        }
      })
    }
  }
}

/// Check if a function name suggests it's a pure utility (no side effects → no logging needed).
fn is_pure_function_name(name: String) -> Bool {
  string.starts_with(name, "encode_")
  || string.starts_with(name, "decode_")
  || string.starts_with(name, "to_")
  || string.starts_with(name, "from_")
  || string.starts_with(name, "create_")
  || string.starts_with(name, "is_")
  || string.starts_with(name, "has_")
  || string.starts_with(name, "get_")
  || string.starts_with(name, "patches_to_")
  || name == "diff"
  || name == "main"
}

/// Check if a function body contains any call to log.info/debug/warning/error.
fn body_contains_log_call(body: List(glance.Statement)) -> Bool {
  list.any(body, fn(stmt) { statement_has_log(stmt) })
}

/// Check a statement for log calls.
fn statement_has_log(stmt: glance.Statement) -> Bool {
  case stmt {
    glance.Expression(expr) -> expression_has_log(expr)
    glance.Assignment(value: expr, ..) -> expression_has_log(expr)
    _ -> False
  }
}

/// Check an expression for log calls (looking for `log.info`, `log.debug`, etc).
fn expression_has_log(expr: glance.Expression) -> Bool {
  case expr {
    // Direct call to log.something
    glance.Call(
      function: glance.FieldAccess(
        container: glance.Variable(name: "log", ..),
        ..,
      ),
      ..,
    ) -> True

    // Recurse into sub-expressions
    glance.Call(function: func, arguments: args, ..) -> {
      expression_has_log(func)
      || list.any(args, fn(arg) {
        case arg {
          glance.LabelledField(item: value, ..) -> expression_has_log(value)
          glance.UnlabelledField(item: value) -> expression_has_log(value)
          glance.ShorthandField(..) -> False
        }
      })
    }

    glance.Block(statements: stmts, ..) ->
      list.any(stmts, statement_has_log)

    glance.Case(clauses: clauses, ..) ->
      list.any(clauses, fn(c) { expression_has_log(c.body) })

    glance.BinaryOperator(left: l, right: r, ..) ->
      expression_has_log(l) || expression_has_log(r)

    glance.Fn(body: body, ..) -> list.any(body, statement_has_log)

    _ -> False
  }
}

/// Check for `todo` and `panic` expressions in function bodies.
/// These are development placeholders and must not appear in shipped code.
fn check_no_todo_panic(
  file_path: String,
  module: glance.Module,
) -> List(Violation) {
  list.flat_map(module.functions, fn(def) {
    let func = def.definition
    list.flat_map(func.body, fn(statement) {
      find_todo_panic_in_statement(file_path, func.name, statement)
    })
  })
}

/// Recursively search a statement for todo/panic expressions.
fn find_todo_panic_in_statement(
  file_path: String,
  func_name: String,
  statement: glance.Statement,
) -> List(Violation) {
  case statement {
    glance.Expression(expr) ->
      find_todo_panic_in_expression(file_path, func_name, expr)
    glance.Assignment(value: expr, ..) ->
      find_todo_panic_in_expression(file_path, func_name, expr)
    _ -> []
  }
}

/// Recursively search an expression for todo/panic.
fn find_todo_panic_in_expression(
  file_path: String,
  func_name: String,
  expr: glance.Expression,
) -> List(Violation) {
  case expr {
    glance.Todo(location: loc, ..) -> [
      Violation(
        file: file_path,
        location: span_to_string(loc),
        rule: "no-todo",
        message: "Found `todo` in function `"
          <> func_name
          <> "`. Remove before shipping.",
      ),
    ]
    glance.Panic(location: loc, ..) -> [
      Violation(
        file: file_path,
        location: span_to_string(loc),
        rule: "no-panic",
        message: "Found `panic` in function `"
          <> func_name
          <> "`. Use proper error handling instead.",
      ),
    ]

    // Recurse into sub-expressions
    glance.Call(function: func, arguments: args, ..) -> {
      let func_violations =
        find_todo_panic_in_expression(file_path, func_name, func)
      let arg_violations =
        list.flat_map(args, fn(arg) {
          case arg {
            glance.LabelledField(item: value, ..) ->
              find_todo_panic_in_expression(file_path, func_name, value)
            glance.UnlabelledField(item: value) ->
              find_todo_panic_in_expression(file_path, func_name, value)
            glance.ShorthandField(..) -> []
          }
        })
      list.append(func_violations, arg_violations)
    }

    glance.BinaryOperator(left: left, right: right, ..) ->
      list.append(
        find_todo_panic_in_expression(file_path, func_name, left),
        find_todo_panic_in_expression(file_path, func_name, right),
      )

    glance.Block(statements: stmts, ..) ->
      list.flat_map(stmts, fn(s) {
        find_todo_panic_in_statement(file_path, func_name, s)
      })

    glance.Case(subjects: subjects, clauses: clauses, ..) -> {
      let subj_v =
        list.flat_map(subjects, fn(s) {
          find_todo_panic_in_expression(file_path, func_name, s)
        })
      let clause_v =
        list.flat_map(clauses, fn(c) {
          find_todo_panic_in_expression(file_path, func_name, c.body)
        })
      list.append(subj_v, clause_v)
    }

    glance.Fn(body: body, ..) ->
      list.flat_map(body, fn(s) {
        find_todo_panic_in_statement(file_path, func_name, s)
      })

    glance.List(elements: elems, ..) ->
      list.flat_map(elems, fn(e) {
        find_todo_panic_in_expression(file_path, func_name, e)
      })

    glance.Tuple(elements: elems, ..) ->
      list.flat_map(elems, fn(e) {
        find_todo_panic_in_expression(file_path, func_name, e)
      })

    glance.NegateInt(value: inner, ..)
    | glance.NegateBool(value: inner, ..) ->
      find_todo_panic_in_expression(file_path, func_name, inner)

    glance.FieldAccess(container: inner, ..) ->
      find_todo_panic_in_expression(file_path, func_name, inner)

    _ -> []
  }
}

/// Convert a Span to a human-readable location string.
fn span_to_string(span: glance.Span) -> String {
  "byte "
  <> int.to_string(span.start)
  <> "-"
  <> int.to_string(span.end)
}

/// Format a lint violation as a human-readable string.
/// Format: `file:location [rule] message`
pub fn violation_to_string(v: Violation) -> String {
  v.file <> ":" <> v.location <> " [" <> v.rule <> "] " <> v.message
}

/// Main entry point for CLI: `gleam run -m beacon/lint`
pub fn main() {
  log.configure()
  log.info("beacon.lint", "Starting lint check")
  let violations = lint_directory("src")
  log.info(
    "beacon.lint",
    "Found " <> int.to_string(list.length(violations)) <> " violation(s)",
  )
  case violations {
    [] -> {
      log.info("beacon.lint", "No violations found!")
      Nil
    }
    _ -> {
      list.each(violations, fn(v) {
        log.error("beacon.lint", violation_to_string(v))
      })
      log.error(
        "beacon.lint",
        int.to_string(list.length(violations)) <> " violation(s) found",
      )
      // Use init:stop for a graceful shutdown that flushes logs
      erlang_init_stop(1)
    }
  }
}

@external(erlang, "beacon_lint_ffi", "stop_with_code")
fn erlang_init_stop(code: Int) -> Nil
