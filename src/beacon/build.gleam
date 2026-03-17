/// Beacon build tool — compiles user's update+view to JavaScript for client-side execution.
///
/// Usage: `gleam run -m beacon/build`
///
/// Creates a temp JS-target project, copies user code + pure beacon modules,
/// compiles to JS, bundles with esbuild into priv/static/beacon_client.js.

import beacon/build/analyzer
import beacon/log
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Main entry point for the build tool.
pub fn main() {
  log.configure()
  log.info("beacon.build", "Starting client-side compilation")

  let arg = case get_args() {
    [a, ..] -> a
    [] -> "examples/src"
  }

  // If arg is a .gleam file, use it directly. Otherwise search the directory.
  case string.ends_with(arg, ".gleam") {
    True -> {
      case simplifile.read(arg) {
        Ok(source) -> {
          log.info("beacon.build", "Using specified module: " <> arg)
          compile_module(arg, source)
        }
        Error(_) -> log.error("beacon.build", "Cannot read file: " <> arg)
      }
    }
    False -> {
      case find_app_module(arg) {
        Ok(#(path, source)) -> {
          log.info("beacon.build", "Found app module: " <> path)
          compile_module(path, source)
        }
        Error(reason) -> log.error("beacon.build", reason)
      }
    }
  }
}

/// Compile a specific module to JavaScript.
fn compile_module(path: String, source: String) -> Nil {
  case analyzer.analyze(source) {
    Ok(analysis) -> {
      list.each(analysis.msg_variants, fn(v) {
        let label = case v.affects_model {
          True -> "MODEL"
          False -> "LOCAL"
        }
        log.info("beacon.build", "  " <> v.name <> " → " <> label)
      })

      // Generate beacon_codec.gleam — auto-discovered by the runtime at startup
      let module_name = extract_module_name(path)
      generate_codec_module(path, module_name, analysis)

      log.info("beacon.build", "Creating temp JS project...")
      case create_temp_project(path, source, analysis) {
        Ok(Nil) -> {
          log.info("beacon.build", "Compiling to JavaScript...")
          case compile_js() {
            Ok(Nil) -> {
              log.info("beacon.build", "Bundling with esbuild...")
              case bundle_js() {
                Ok(Nil) ->
                  log.info("beacon.build", "Done! priv/static/beacon_client.js updated")
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

  // Find the beacon package root — works whether we're in the beacon project
  // itself or in a downstream project that depends on beacon.
  let beacon_root = find_beacon_root()
  log.info("beacon.build", "Beacon root: " <> beacon_root)

  // Copy pure beacon modules
  copy_if_exists(
    beacon_root <> "/src/beacon/element.gleam",
    dir <> "/src/beacon/element.gleam",
  )
  copy_if_exists(
    beacon_root <> "/src/beacon/html.gleam",
    dir <> "/src/beacon/html.gleam",
  )
  copy_if_exists(
    beacon_root <> "/src/beacon/template/rendered.gleam",
    dir <> "/src/beacon/template/rendered.gleam",
  )

  // Copy the client handler registry
  case simplifile.create_directory_all(dir <> "/src/beacon_client") {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  copy_if_exists(
    beacon_root <> "/beacon_client/src/beacon_client/handler.gleam",
    dir <> "/src/beacon_client/handler.gleam",
  )
  copy_if_exists(
    beacon_root <> "/beacon_client/src/beacon_client_ffi.mjs",
    dir <> "/src/beacon_client_ffi.mjs",
  )

  // Write a client-side beacon.gleam with on_click/on_input that use the JS handler
  let beacon_gleam = generate_client_beacon()
  case simplifile.write(dir <> "/src/beacon.gleam", beacon_gleam) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Write client-side store stub (no-op implementations for JS target)
  let store_stub = generate_client_store_stub()
  case simplifile.write(dir <> "/src/beacon/store.gleam", store_stub) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Write the user's module as the app
  case simplifile.write(dir <> "/src/app.gleam", rewrite_user_module(user_source)) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Generate the entry point that wires update+view to the client runtime
  let entry = generate_entry_point(analysis, user_source)
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

/// Attach a mousedown handler with coordinates.
pub fn on_mousedown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mousedown\", handler_id: id)
}

/// Attach a mouseup handler.
pub fn on_mouseup(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"mouseup\", handler_id: id)
}

/// Attach a mousemove handler with coordinates.
pub fn on_mousemove(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mousemove\", handler_id: id)
}
"
}

/// Generate a client-side store stub — no-op implementations for JS target.
/// Provides Store/ListStore types and functions that compile to JS without
/// ETS, PubSub, or state_manager dependencies.
fn generate_client_store_stub() -> String {
  "/// Client-side store stub — no-op implementations for JS target.
/// Store operations that affect shared state are no-ops on the client;
/// the server handles actual persistence. This stub exists so that
/// make_init/make_update factory functions compile to JavaScript.

/// A key-value store (client-side stub).
pub type Store(value) {
  Store(topic: String)
}

/// Create a new store (stub).
pub fn new(_name: String) -> Store(value) {
  Store(topic: \"\")
}

/// Get a value (always returns Error on client).
pub fn get(_store: Store(value), _key: String) -> Result(value, Nil) {
  Error(Nil)
}

/// Set a value (no-op on client — server handles persistence).
pub fn put(_store: Store(value), _key: String, _value: value) -> Nil {
  Nil
}

/// Delete a value (no-op on client).
pub fn delete(_store: Store(value), _key: String) -> Nil {
  Nil
}

/// Count entries (always 0 on client).
pub fn count(_store: Store(value)) -> Int {
  0
}

/// Get the PubSub topic.
pub fn topic(store: Store(value)) -> String {
  store.topic
}

/// A list store (client-side stub).
pub type ListStore(value) {
  ListStore(topic: String)
}

/// Create a new list store (stub).
pub fn new_list(_name: String) -> ListStore(value) {
  ListStore(topic: \"\")
}

/// Append a value (no-op on client).
pub fn append(_store: ListStore(value), _key: String, _value: value) -> Nil {
  Nil
}

/// Get all values (always empty on client).
pub fn get_all(_store: ListStore(value), _key: String) -> List(value) {
  []
}

/// Delete all values for a key (no-op on client).
pub fn delete_all(_store: ListStore(value), _key: String) -> Nil {
  Nil
}

/// Get the PubSub topic for a list store.
pub fn list_topic(store: ListStore(value)) -> String {
  store.topic
}
"
}

/// Rewrite user module: strip server-only code for JS compilation.
/// Removes main/start functions. Keeps make_init/make_update (client-side
/// store stub provides compatible types). Keeps import beacon/store.
fn rewrite_user_module(source: String) -> String {
  // Strip pub fn main() or pub fn start() and everything after
  let stripped = case string.split(source, "pub fn main()") {
    [before, _] -> before
    _ -> source
  }
  let stripped = case string.split(stripped, "pub fn start()") {
    [before, _] -> before
    _ -> stripped
  }
  // Strip @external declarations (they're Erlang-only)
  let lines = string.split(stripped, "\n")
  let filtered =
    list.filter(lines, fn(line) {
      let trimmed = string.trim(line)
      case string.starts_with(trimmed, "@external(erlang") {
        True -> False
        False ->
          case string.starts_with(trimmed, "fn unique_int") {
            True -> False
            False -> True
          }
      }
    })
  string.join(filtered, "\n")
}


/// Generate the entry point module that wires user code to client runtime.
fn generate_entry_point(
  analysis: analyzer.Analysis,
  user_source: String,
) -> String {
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

  // Generate JSON decoder for Model (client-side model_sync)
  // Generate decoders for custom types referenced by Model fields
  let custom_decoder_fns =
    list.filter_map(analysis.model_fields, fn(f) {
      case f.type_name {
        "List" ->
          // Find the custom type definition for the inner type
          case
            list.find(analysis.custom_types, fn(ct) {
              ct.name == f.inner_type
            })
          {
            Ok(ct) -> Ok(generate_custom_decoder(ct))
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  let custom_decoders_code = string.join(custom_decoder_fns, "\n\n")

  let decode_fields =
    list.map(analysis.model_fields, fn(f) {
      let decoder = decoder_for_field(f, analysis.custom_types)
      "    use "
      <> f.name
      <> " <- decode.field(\""
      <> f.name
      <> "\", "
      <> decoder
      <> ")"
    })
  let decode_body = string.join(decode_fields, "\n")

  let model_constructor_args =
    list.map(analysis.model_fields, fn(f) {
      f.name <> ": " <> f.name
    })
  let constructor_call =
    "app.Model(" <> string.join(model_constructor_args, ", ") <> ")"

  // Determine if we need the store import for factory pattern
  let needs_store =
    !analysis.has_direct_init || !analysis.has_direct_update

  // Detect whether factory takes Store or ListStore by scanning source
  let store_constructor = case string.contains(user_source, "ListStore") {
    True -> "store.new_list(\"client_stub\")"
    False -> "store.new(\"client_stub\")"
  }

  // Generate init function
  let init_fn = case analysis.has_direct_init {
    True -> "pub fn init() -> app.Model {\n  app.init()\n}"
    False -> {
      // Factory pattern (make_init): call with stub store
      "pub fn init() -> app.Model {\n  let init_fn = app.make_init("
      <> store_constructor
      <> ")\n  init_fn()\n}"
    }
  }

  // Generate different code for apps with vs without Local type
  let #(update_fn_code, init_local_code, view_to_html_code) = case analysis.has_local {
    True -> {
      let upd = case analysis.has_direct_update {
        True ->
          "pub fn update(model: app.Model, local: app.Local, msg: app.Msg) -> #(app.Model, app.Local) {\n  app.update(model, local, msg)\n}"
        False ->
          // Factory pattern (make_update): call factory with stub store
          "pub fn update(model: app.Model, local: app.Local, msg: app.Msg) -> #(app.Model, app.Local) {\n  let update_fn = app.make_update("
          <> store_constructor
          <> ")\n  update_fn(model, local, msg)\n}"
      }
      #(
        upd,
        "pub fn init_local(model: app.Model) -> app.Local {\n  app.init_local(model)\n}",
        "pub fn view_to_html(model: app.Model, local: app.Local) -> String {\n  element.to_string(app.view(model, local))\n}",
      )
    }
    False -> {
      let upd = case analysis.has_direct_update {
        True ->
          "pub fn update(model: app.Model, local: Nil, msg: app.Msg) -> #(app.Model, Nil) {\n  #(app.update(model, msg), Nil)\n}"
        False ->
          "pub fn update(model: app.Model, local: Nil, _msg: app.Msg) -> #(app.Model, Nil) {\n  #(model, local)\n}"
      }
      #(
        upd,
        "pub fn init_local(_model: app.Model) -> Nil {\n  Nil\n}",
        "pub fn view_to_html(model: app.Model, _local: Nil) -> String {\n  element.to_string(app.view(model))\n}",
      )
    }
  }

  // Add store import if factory pattern is used
  let store_import = case needs_store {
    True -> "import beacon/store\n"
    False -> ""
  }

  "/// AUTO-GENERATED entry point for client-side execution.
import app
import beacon/element
import beacon_client/handler
import gleam/dynamic/decode
import gleam/json
" <> store_import <> "
/// Initialize Model.
" <> init_fn <> "

/// Initialize Local from Model.
" <> init_local_code <> "

/// Run update locally.
" <> update_fn_code <> "

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
" <> view_to_html_code <> "

/// Check if a Msg variant affects the Model (needs server sync).
pub fn msg_affects_model(msg: app.Msg) -> Bool {
  case msg {
" <> affects_model_body <> "
  }
}

/// Decode a JSON string into the user's Model type (for model_sync).
" <> custom_decoders_code <> "

pub fn decode_model(json_str: String) -> Result(app.Model, String) {
  let model_decoder = {
" <> decode_body <> "
    decode.success(" <> constructor_call <> ")
  }
  case json.parse(json_str, model_decoder) {
    Ok(model) -> Ok(model)
    Error(_) -> Error(\"Failed to decode model\")
  }
}
"
}

/// Compile the temp JS project.
fn compile_js() -> Result(Nil, String) {
  let result = run_command("cd build/beacon_client_app && gleam build 2>&1")
  case string.contains(result, "Compiled in") {
    True -> Ok(Nil)
    False -> {
      log.error(
        "beacon.build",
        "JS compilation failed. This usually means the user module "
          <> "references server-only code (stores, ETS, etc.) that can't "
          <> "compile to JavaScript. Check the error output below.",
      )
      Error("JS compilation failed:\n" <> result)
    }
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
    "import { initClientAfterBoot } from './build/dev/javascript/beacon_client_app/beacon_client_ffi.mjs';\nimport * as App from './build/dev/javascript/beacon_client_app/beacon_app_entry.mjs';\nwindow.BeaconApp = App;\ninitClientAfterBoot();\n"
  case simplifile.write("build/beacon_client_app/bundle_entry.mjs", entry_js) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }
  // Generate unique hash for cache busting
  let hash = run_command("date +%s | shasum | head -c 8")
  let filename = "beacon_client_" <> string.trim(hash) <> ".js"

  // Clean old beacon_client_*.js files
  let _ = run_command("rm -f priv/static/beacon_client_*.js 2>/dev/null")

  let result =
    run_command(
      "cd build/beacon_client_app && npx esbuild bundle_entry.mjs --bundle --format=iife --global-name=Beacon --outfile=../../priv/static/" <> filename <> " --minify 2>&1",
    )
  case string.contains(result, "Done") || string.contains(result, ".js") {
    True -> {
      // Write manifest so server knows the current filename
      case simplifile.write("priv/static/beacon_client.manifest", filename) {
        Ok(Nil) -> Nil
        Error(_) -> Nil
      }
      Ok(Nil)
    }
    False -> Error(result)
  }
}

/// Generate the decoder expression for a field type.
fn decoder_for_field(
  field: analyzer.TypeField,
  custom_types: List(analyzer.CustomTypeInfo),
) -> String {
  case field.type_name {
    "Int" -> "decode.int"
    "Float" -> "decode.float"
    "Bool" -> "decode.bool"
    "String" -> "decode.string"
    "List" ->
      case field.inner_type {
        "Int" -> "decode.list(decode.int)"
        "Float" -> "decode.list(decode.float)"
        "Bool" -> "decode.list(decode.bool)"
        "String" -> "decode.list(decode.string)"
        inner ->
          // Check if inner type is a known custom type
          case list.find(custom_types, fn(ct) { ct.name == inner }) {
            Ok(_) -> "decode.list(decode_" <> string.lowercase(inner) <> "())"
            Error(_) -> "decode.list(decode.dynamic)"
          }
      }
    _ -> "decode.dynamic"
  }
}

/// Generate a decoder function for a custom type (e.g., Stroke).
fn generate_custom_decoder(ct: analyzer.CustomTypeInfo) -> String {
  let fields =
    list.map(ct.fields, fn(f) {
      let decoder = case f.type_name {
        "Int" -> "decode.int"
        "Float" -> "decode.float"
        "Bool" -> "decode.bool"
        _ -> "decode.string"
      }
      "  use "
      <> f.name
      <> " <- decode.field(\""
      <> f.name
      <> "\", "
      <> decoder
      <> ")"
    })
  let constructor_args =
    list.map(ct.fields, fn(f) { f.name <> ": " <> f.name })
  "fn decode_"
  <> string.lowercase(ct.name)
  <> "() -> decode.Decoder(app."
  <> ct.name
  <> ") {\n"
  <> string.join(fields, "\n")
  <> "\n  decode.success(app."
  <> ct.name
  <> "("
  <> string.join(constructor_args, ", ")
  <> "))\n}"
}

/// Extract the module name from a file path (e.g., "src/canvas.gleam" → "canvas").
fn extract_module_name(path: String) -> String {
  path
  |> string.replace(".gleam", "")
  |> string.split("/")
  |> list.last
  |> result.unwrap("app")
}

/// Generate beacon_codec.gleam — fixed name, auto-discovered by the runtime.
/// No user imports needed. The runtime finds it via Erlang dynamic dispatch.
fn generate_codec_module(
  _path: String,
  module_name: String,
  analysis: analyzer.Analysis,
) -> Nil {
  let codec_path = "src/beacon_codec.gleam"

  // Generate encoder for each custom type used in Model fields
  let custom_encoders =
    list.filter_map(analysis.model_fields, fn(f) {
      case f.type_name {
        "List" ->
          case
            list.find(analysis.custom_types, fn(ct) {
              ct.name == f.inner_type
            })
          {
            Ok(ct) -> Ok(generate_type_encoder(module_name, ct))
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })

  // Model field encoders
  let model_field_encoders =
    list.map(analysis.model_fields, fn(f) {
      let encoder = case f.type_name {
        "Int" -> "json.int(model." <> f.name <> ")"
        "Float" -> "json.float(model." <> f.name <> ")"
        "Bool" -> "json.bool(model." <> f.name <> ")"
        "String" -> "json.string(model." <> f.name <> ")"
        "List" ->
          case
            list.find(analysis.custom_types, fn(ct) {
              ct.name == f.inner_type
            })
          {
            Ok(_) ->
              "json.array(model."
              <> f.name
              <> ", encode_"
              <> string.lowercase(f.inner_type)
              <> ")"
            Error(_) -> "json.array(model." <> f.name <> ", json.string)"
          }
        _ -> "json.string(model." <> f.name <> ")"
      }
      "    #(\"" <> f.name <> "\", " <> encoder <> ")"
    })

  let #(param_type, model_extract) = case analysis.has_local {
    True -> #(
      "#(" <> module_name <> ".Model, " <> module_name <> ".Local)",
      "  let model = state.0\n",
    )
    False -> #(module_name <> ".Model", "  let model = state\n")
  }

  let source =
    "/// AUTO-GENERATED by beacon/build — do not edit manually.
/// Re-run `gleam run -m beacon/build` to regenerate.

import "
    <> module_name
    <> "
import gleam/json

"
    <> string.join(custom_encoders, "\n\n")
    <> "\n\n/// Encode the Model to JSON for model_sync.
pub fn encode_model(state: "
    <> param_type
    <> ") -> String {\n"
    <> model_extract
    <> "  json.object([\n"
    <> string.join(model_field_encoders, ",\n")
    <> ",\n  ])\n  |> json.to_string\n}\n"

  case simplifile.write(codec_path, source) {
    Ok(Nil) ->
      log.info("beacon.build", "Generated codec: " <> codec_path)
    Error(_) ->
      log.warning("beacon.build", "Could not write: " <> codec_path)
  }
}

/// Generate an encoder function for a custom type.
fn generate_type_encoder(
  module_name: String,
  ct: analyzer.CustomTypeInfo,
) -> String {
  let field_encoders =
    list.map(ct.fields, fn(f) {
      let encoder = case f.type_name {
        "Int" -> "json.int(s." <> f.name <> ")"
        "Float" -> "json.float(s." <> f.name <> ")"
        "Bool" -> "json.bool(s." <> f.name <> ")"
        _ -> "json.string(s." <> f.name <> ")"
      }
      "    #(\"" <> f.name <> "\", " <> encoder <> ")"
    })
  "fn encode_"
  <> string.lowercase(ct.name)
  <> "(s: "
  <> module_name
  <> "."
  <> ct.name
  <> ") -> json.Json {\n  json.object([\n"
  <> string.join(field_encoders, ",\n")
  <> ",\n  ])\n}"
}

fn copy_if_exists(from: String, to: String) -> Nil {
  case simplifile.read(from) {
    Ok(contents) -> {
      case simplifile.write(to, contents) {
        Ok(Nil) -> Nil
        Error(_) -> Nil
      }
    }
    Error(_) -> {
      log.warning("beacon.build", "Could not copy: " <> from)
      Nil
    }
  }
}

/// Find the beacon package root directory.
/// Checks (in order):
///   1. CWD (we ARE the beacon project)
///   2. Path dependency via gleam.toml
///   3. Hex package in build/packages/beacon/
fn find_beacon_root() -> String {
  // 1. Are we in the beacon project itself?
  case simplifile.is_file("src/beacon/element.gleam") {
    Ok(True) -> "."
    _ ->
      // 2. Check gleam.toml for a path dependency
      case read_beacon_path_from_toml() {
        Ok(path) -> path
        Error(_) ->
          // 3. Hex dependency
          case simplifile.is_directory("build/packages/beacon") {
            Ok(True) -> "build/packages/beacon"
            _ -> {
              log.error(
                "beacon.build",
                "Cannot find beacon package source. "
                  <> "Ensure beacon is a dependency in gleam.toml.",
              )
              "."
            }
          }
      }
  }
}

/// Parse gleam.toml to find beacon path dependency.
/// Looks for: beacon = { path = "..." }
fn read_beacon_path_from_toml() -> Result(String, Nil) {
  case simplifile.read("gleam.toml") {
    Ok(contents) -> {
      // Simple parser: find line containing 'beacon' and 'path'
      let lines = string.split(contents, "\n")
      list.find_map(lines, fn(line) {
        case
          string.contains(line, "beacon")
          && string.contains(line, "path")
        {
          True -> {
            // Extract path value from: beacon = { path = ".." }
            case string.split(line, "\"") {
              [_, path, ..] -> Ok(path)
              _ -> Error(Nil)
            }
          }
          False -> Error(Nil)
        }
      })
    }
    Error(_) -> Error(Nil)
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
                      let has_update =
                        string.contains(source, "pub fn update")
                        || string.contains(source, "pub fn make_update")
                      let has_view = string.contains(source, "pub fn view")
                      let has_model = string.contains(source, "pub type Model")
                      let has_msg = string.contains(source, "pub type Msg")
                      let has_local = string.contains(source, "pub type Local")
                      case
                        has_update
                        && has_view
                        && has_model
                        && has_msg
                        && has_local
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
