/// Beacon build tool — compiles user's update+view to JavaScript for client-side execution.
///
/// Usage: `gleam run -m beacon/build`
///
/// What it does:
/// 1. Scans user source files with Glance to find Model, Local, Msg, update, view
/// 2. Classifies each Msg variant as model-changing or local-only
/// 3. Generates JSON codecs and msg_affects_model() function
/// 4. Creates a temporary JS-target project in build/beacon_client/
/// 5. Copies pure Gleam modules + user code, compiles to JS
/// 6. Bundles output into priv/static/beacon_client.js

import beacon/build/analyzer
import beacon/log
import gleam/list
import gleam/string
import simplifile

/// Main entry point for the build tool.
pub fn main() {
  log.configure()
  log.info("beacon.build", "Starting client-side compilation")

  // Step 1: Find user source files
  // In a real user project, scan "src". For framework development, scan examples.
  let src_dir = case get_args() {
    [dir, ..] -> dir
    [] -> "src/beacon/examples"
  }
  case find_app_module(src_dir) {
    Ok(#(path, source)) -> {
      log.info("beacon.build", "Found app module: " <> path)
      // Step 2: Analyze with Glance
      case analyzer.analyze(source) {
        Ok(analysis) -> {
          log.info(
            "beacon.build",
            "Found " <> int_str(list.length(analysis.msg_variants)) <> " Msg variants",
          )
          list.each(analysis.msg_variants, fn(v) {
            let label = case v.affects_model {
              True -> "MODEL"
              False -> "LOCAL"
            }
            log.info(
              "beacon.build",
              "  " <> v.name <> " → " <> label,
            )
          })
          log.info("beacon.build", "Analysis complete. Client JS compilation is a future milestone.")
          Nil
        }
        Error(reason) -> {
          log.error("beacon.build", "Analysis failed: " <> reason)
          Nil
        }
      }
    }
    Error(reason) -> {
      log.error("beacon.build", reason)
      Nil
    }
  }
}

/// Find a Gleam source file that exports an `update` function.
fn find_app_module(dir: String) -> Result(#(String, String), String) {
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      let results =
        list.filter_map(entries, fn(entry) {
          let path = dir <> "/" <> entry
          case simplifile.is_directory(path) {
            Ok(True) -> {
              // Skip framework internal directories
              case entry {
                "beacon" -> Error(Nil)
                _ ->
                  case find_app_module(path) {
                    Ok(found) -> Ok(found)
                    Error(_) -> Error(Nil)
                  }
              }
            }
            _ -> {
              case string.ends_with(entry, ".gleam") {
                True -> {
                  case simplifile.read(path) {
                    Ok(source) -> {
                      case
                        string.contains(source, "pub fn update")
                        && string.contains(source, "pub fn view")
                        && string.contains(source, "pub type Model")
                        && string.contains(source, "pub type Msg")
                      {
                        True -> Ok(#(path, source))
                        False -> Error(Nil)
                      }
                    }
                    Error(_) -> Error(Nil)
                  }
                }
                False -> Error(Nil)
              }
            }
          }
        })
      case results {
        [first, ..] -> Ok(first)
        [] -> Error("No module found with pub fn update + pub fn view + pub type Model")
      }
    }
    Error(_) -> Error("Cannot read directory: " <> dir)
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_str(n: Int) -> String

@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)
