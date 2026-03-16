/// Beacon build tool — compiles user's update+view to JavaScript for client-side execution.
///
/// Usage: `gleam run -m beacon/build`
///
/// Creates a temp JS-target project, copies user code + pure beacon modules,
/// compiles to JS, bundles with esbuild into priv/static/beacon_client.js.

import beacon/build/analyzer
import beacon/log
import gleam/list
import gleam/string
import simplifile

/// Main entry point for the build tool.
pub fn main() {
  log.configure()
  log.info("beacon.build", "Starting client-side compilation")

  let src_dir = case get_args() {
    [dir, ..] -> dir
    [] -> "src/beacon/examples"
  }

  case find_app_module(src_dir) {
    Ok(#(path, source)) -> {
      log.info("beacon.build", "Found app module: " <> path)
      case analyzer.analyze(source) {
        Ok(analysis) -> {
          // Log analysis
          list.each(analysis.msg_variants, fn(v) {
            let label = case v.affects_model {
              True -> "MODEL"
              False -> "LOCAL"
            }
            log.info("beacon.build", "  " <> v.name <> " → " <> label)
          })

          // Step 3: Create temp JS project
          log.info("beacon.build", "Creating temp JS project...")
          case create_temp_project(path, source, analysis) {
            Ok(Nil) -> {
              // Step 4: Compile to JS
              log.info("beacon.build", "Compiling to JavaScript...")
              case compile_js() {
                Ok(Nil) -> {
                  // Step 5: Bundle with esbuild
                  log.info("beacon.build", "Bundling with esbuild...")
                  case bundle_js() {
                    Ok(Nil) ->
                      log.info(
                        "beacon.build",
                        "Done! priv/static/beacon_client.js updated",
                      )
                    Error(reason) ->
                      log.error("beacon.build", "Bundle failed: " <> reason)
                  }
                }
                Error(reason) ->
                  log.error("beacon.build", "Compile failed: " <> reason)
              }
            }
            Error(reason) ->
              log.error("beacon.build", "Project creation failed: " <> reason)
          }
        }
        Error(reason) -> log.error("beacon.build", "Analysis failed: " <> reason)
      }
    }
    Error(reason) -> log.error("beacon.build", reason)
  }
}

/// Create the temporary JS-target project with user code + pure beacon modules.
fn create_temp_project(
  _user_path: String,
  user_source: String,
  analysis: analyzer.Analysis,
) -> Result(Nil, String) {
  let dir = "build/beacon_client_app"

  // Create directory structure
  case simplifile.create_directory_all(dir <> "/src/beacon") {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  case simplifile.create_directory_all(dir <> "/src/beacon/template") {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Write gleam.toml
  let toml =
    "name = \"beacon_client_app\"\nversion = \"0.1.0\"\ntarget = \"javascript\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\ngleam_json = \">= 3.1.0 and < 4.0.0\"\n"
  case simplifile.write(dir <> "/gleam.toml", toml) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Copy pure beacon modules
  copy_if_exists("src/beacon/element.gleam", dir <> "/src/beacon/element.gleam")
  copy_if_exists("src/beacon/html.gleam", dir <> "/src/beacon/html.gleam")
  copy_if_exists(
    "src/beacon/template/rendered.gleam",
    dir <> "/src/beacon/template/rendered.gleam",
  )

  // Copy the client handler registry
  case simplifile.create_directory_all(dir <> "/src/beacon_client") {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  copy_if_exists(
    "beacon_client/src/beacon_client/handler.gleam",
    dir <> "/src/beacon_client/handler.gleam",
  )
  copy_if_exists(
    "beacon_client/src/beacon_client_ffi.mjs",
    dir <> "/src/beacon_client_ffi.mjs",
  )

  // Write a client-side beacon.gleam with on_click/on_input that use the JS handler
  let beacon_gleam = generate_client_beacon()
  case simplifile.write(dir <> "/src/beacon.gleam", beacon_gleam) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Write the user's module as the app
  case simplifile.write(dir <> "/src/app.gleam", rewrite_user_module(user_source)) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Generate the entry point that wires update+view to the client runtime
  let entry = generate_entry_point(analysis)
  case simplifile.write(dir <> "/src/beacon_app_entry.gleam", entry) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  Ok(Nil)
}

/// Generate a client-side beacon.gleam with event helpers using JS handler registry.
fn generate_client_beacon() -> String {
  "/// Client-side beacon module — event helpers for JS target.
import beacon/element.{type Attr}
import beacon_client/handler

/// A node in the virtual DOM tree.
pub type Node(msg) = element.Node(msg)

/// Attach a click handler.
pub fn on_click(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"click\", handler_id: id)
}

/// Attach an input handler.
pub fn on_input(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"input\", handler_id: id)
}

/// Attach a submit handler.
pub fn on_submit(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"submit\", handler_id: id)
}

/// Attach a change handler.
pub fn on_change(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"change\", handler_id: id)
}
"
}

/// Rewrite user module: strip the main() function (server-only).
fn rewrite_user_module(source: String) -> String {
  // Remove pub fn main() and everything after it
  // The main function calls beacon.start() which is server-only
  case string.split(source, "pub fn main()") {
    [before, _] -> before
    _ -> source
  }
}

/// Generate the entry point module that wires user code to client runtime.
fn generate_entry_point(analysis: analyzer.Analysis) -> String {
  let affects_model_arms =
    list.map(analysis.msg_variants, fn(v) {
      let pattern = case v.affects_model {
        True -> "True"
        False -> "False"
      }
      "    app." <> v.name <> case string.contains(v.name, "(") {
        True -> ""
        False -> "(..)"
      }
        <> " -> "
        <> pattern
    })
  // Handle variants with arguments — use catch-all for simplicity
  let affects_model_body =
    string.join(affects_model_arms, "\n") <> "\n    _ -> True"

  "/// AUTO-GENERATED entry point for client-side execution.
import app
import beacon/element
import beacon_client/handler

/// Initialize Model.
pub fn init() -> app.Model {
  app.init()
}

/// Initialize Local from Model.
pub fn init_local(model: app.Model) -> app.Local {
  app.init_local(model)
}

/// Run update locally.
pub fn update(model: app.Model, local: app.Local, msg: app.Msg) -> #(app.Model, app.Local) {
  app.update(model, local, msg)
}

/// Start a render cycle (resets handler registry).
pub fn start_render() {
  handler.start_render()
}

/// Finish a render cycle (returns populated handler registry).
pub fn finish_render() {
  handler.finish_render()
}

/// Resolve a handler ID to a Msg value.
pub fn resolve_handler(registry, handler_id: String, data: String) {
  handler.resolve(registry, handler_id, data)
}

/// Render view to HTML string.
pub fn view_to_html(model: app.Model, local: app.Local) -> String {
  element.to_string(app.view(model, local))
}

/// Check if a Msg variant affects the Model (needs server sync).
pub fn msg_affects_model(msg: app.Msg) -> Bool {
  case msg {
" <> affects_model_body <> "
  }
}
"
}

/// Compile the temp JS project.
fn compile_js() -> Result(Nil, String) {
  let result = run_command("cd build/beacon_client_app && gleam build 2>&1")
  case string.contains(result, "Compiled in") {
    True -> Ok(Nil)
    False -> Error(result)
  }
}

/// Bundle compiled JS with esbuild.
fn bundle_js() -> Result(Nil, String) {
  // Ensure priv/static exists
  case simplifile.create_directory_all("priv/static") {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  // Create a tiny entry that imports both the FFI and user entry
  let entry_js =
    "import { initClient } from './build/dev/javascript/beacon_client_app/beacon_client_ffi.mjs';\nimport * as App from './build/dev/javascript/beacon_client_app/beacon_app_entry.mjs';\nwindow.BeaconApp = App;\ninitClient();\n"
  case simplifile.write("build/beacon_client_app/bundle_entry.mjs", entry_js) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  let result =
    run_command(
      "cd build/beacon_client_app && npx esbuild bundle_entry.mjs --bundle --format=iife --global-name=Beacon --outfile=../../priv/static/beacon_client.js --minify 2>&1",
    )
  case string.contains(result, "Done") || string.contains(result, ".js") {
    True -> Ok(Nil)
    False -> Error(result)
  }
}

fn copy_if_exists(from: String, to: String) -> Nil {
  case simplifile.read(from) {
    Ok(contents) -> {
      case simplifile.write(to, contents) {
        Ok(Nil) -> Nil
        Error(_) -> Nil
      }
    }
    Error(_) -> Nil
  }
}

/// Find a Gleam source file with Model, Msg, update, view.
fn find_app_module(dir: String) -> Result(#(String, String), String) {
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      let results =
        list.filter_map(entries, fn(entry) {
          let path = dir <> "/" <> entry
          case simplifile.is_directory(path) {
            Ok(True) -> {
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
                        && string.contains(source, "pub type Local")
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
        [] ->
          Error(
            "No module found with pub fn update + pub fn view + pub type Model",
          )
      }
    }
    Error(_) -> Error("Cannot read directory: " <> dir)
  }
}


@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)

@external(erlang, "beacon_build_ffi", "run_command")
fn run_command(cmd: String) -> String
