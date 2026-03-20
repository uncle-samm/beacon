/// Beacon build tool — builds the client runtime JS and generates the codec.
///
/// Usage: `gleam run -m beacon/build`
///
/// The client JS is the framework runtime (WS, event delegation, morphing).
/// User code runs ONLY on the server. This is the LiveView model.
/// No fallbacks — the build succeeds or fails loudly.

import beacon/build/analyzer
import beacon/log
import glance
import gleam/list
import gleam/option
import gleam/string
import simplifile

/// Build client JS for a specific source file.
/// Called by the example runner to auto-build before starting.
pub fn build_from_source(path: String) -> Nil {
  // Clean stale codec artifacts to prevent type mismatches between apps
  let _ =
    run_command(
      "rm -f build/dev/erlang/beacon/_gleam_artefacts/beacon_codec* build/dev/erlang/beacon/ebin/beacon_codec.beam 2>/dev/null",
    )
  case simplifile.read(path) {
    Ok(source) -> {
      log.info("beacon.build", "Auto-building: " <> path)
      compile_module(path, source)
    }
    Error(err) ->
      log.error(
        "beacon.build",
        "Cannot read " <> path <> ": " <> string.inspect(err),
      )
  }
}

/// Main entry point for the build tool.
pub fn main() {
  log.configure()
  log.info("beacon.build", "Starting client build")

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
        Error(err) ->
          log.error(
            "beacon.build",
            "Cannot read file " <> arg <> ": " <> string.inspect(err),
          )
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

/// Resolve external module sources from user app imports.
/// Filters to user modules only (skips gleam/, beacon/, etc.).
/// Returns #(alias, module_path, source_text) triples for each resolved import.
fn resolve_external_sources(
  source: String,
  base_dir: String,
) -> List(#(String, String, String)) {
  case glance.module(source) {
    Error(_) -> {
      log.warning(
        "beacon.build",
        "Failed to parse source for external module resolution in "
          <> base_dir,
      )
      []
    }
    Ok(module) -> {
      list.filter_map(module.imports, fn(def) {
        let import_ = def.definition
        let mod_path = import_.module
        // Skip framework/stdlib imports — only follow user modules
        case
          string.starts_with(mod_path, "gleam/")
          || string.starts_with(mod_path, "beacon")
          || mod_path == "simplifile"
          || mod_path == "glance"
          || mod_path == "mist"
          || mod_path == "wisp"
        {
          True -> Error(Nil)
          False -> {
            // Resolve to file path: base_dir/src/<mod_path>.gleam
            // For apps at src/app.gleam importing domains/auth,
            // the file is at src/domains/auth.gleam
            let file_path = base_dir <> "/" <> mod_path <> ".gleam"
            case simplifile.read(file_path) {
              Ok(ext_source) -> {
                // The alias is the last segment of the module path
                // (e.g., "domains/auth" → "auth")
                let alias = case import_.alias {
                  option.Some(glance.Named(name)) -> name
                  option.Some(glance.Discarded(name)) -> name
                  option.None -> {
                    case string.split(mod_path, "/") |> list.last {
                      Ok(name) -> name
                      Error(_) -> mod_path
                    }
                  }
                }
                log.info(
                  "beacon.build",
                  "Resolved external module: "
                    <> mod_path
                    <> " (alias: "
                    <> alias
                    <> ")",
                )
                Ok(#(alias, mod_path, ext_source))
              }
              Error(_) -> {
                // File doesn't exist — might be a hex package
                log.debug(
                  "beacon.build",
                  "Could not read external module file for "
                    <> mod_path
                    <> " — likely a hex package, skipping",
                )
                Error(Nil)
              }
            }
          }
        }
      })
    }
  }
}

/// Extract the source directory (parent of the file) for import resolution.
fn source_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] ->
      case list.reverse(rest) {
        [] -> "."
        parts -> string.join(parts, "/")
      }
    _ -> "."
  }
}

/// Compile a specific module — analyze, generate codec, build client JS.
/// State-over-the-wire: ALL apps get an enhanced bundle with view compiled to JS.
/// The server sends model JSON; the client renders the view locally.
fn compile_module(path: String, source: String) -> Nil {
  // Resolve external module sources for multi-file analysis
  let base_dir = source_dir(path)
  let external_sources = resolve_external_sources(source, base_dir)
  case analyzer.analyze_multi(source, external_sources) {
    Ok(analysis) -> {
      list.each(analysis.msg_variants, fn(v) {
        let label = case v.affects_model {
          True -> "MODEL"
          False -> "LOCAL"
        }
        log.info("beacon.build", "  " <> v.name <> " → " <> label)
      })

      // Generate beacon_codec.gleam — model encoder for state-over-the-wire
      let module_path = extract_module_path(path)
      generate_codec_module(module_path, analysis, source)

      // Build enhanced bundle: view + decode_model compiled to JS
      // Required for state-over-the-wire — client renders view locally
      log.info("beacon.build", "Building enhanced bundle...")
      case build_enhanced_bundle(path, source, analysis) {
        Ok(Nil) ->
          log.info("beacon.build", "Enhanced bundle ready")
        Error(reason) -> {
          // Enhanced build failed — do NOT fall back to runtime-only bundle.
          // SSR HTML still works; user just won't have interactivity until they fix the build.
          log.error(
            "beacon.build",
            "Enhanced build FAILED: " <> reason
            <> " — no client JS will be produced. Fix the build error above.",
          )
        }
      }
    }
    Error(reason) -> log.error("beacon.build", "Analysis failed: " <> reason)
  }
}

/// Create all required directories for the enhanced build.
/// Returns early with an error if any directory creation fails.
fn create_build_directories(dir: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(dir <> "/src/beacon") {
    Error(err) ->
      Error("Failed to create " <> dir <> "/src/beacon: " <> string.inspect(err))
    Ok(Nil) ->
      case simplifile.create_directory_all(dir <> "/src/beacon/template") {
        Error(err) ->
          Error("Failed to create " <> dir <> "/src/beacon/template: " <> string.inspect(err))
        Ok(Nil) ->
          case simplifile.create_directory_all(dir <> "/src/beacon_client") {
            Error(err) ->
              Error("Failed to create " <> dir <> "/src/beacon_client: " <> string.inspect(err))
            Ok(Nil) -> Ok(Nil)
          }
      }
  }
}

/// Build an enhanced JS bundle with user's pure update/view compiled to JS.
/// This enables LOCAL events to run client-side without server round-trips.
fn build_enhanced_bundle(
  path: String,
  source: String,
  analysis: analyzer.Analysis,
) -> Result(Nil, String) {
  let beacon_root = find_beacon_root()
  let dir = "build/beacon_client_app"

  // Step 1: Extract pure client source from AST
  case analyzer.extract_client_source(source) {
    Error(reason) -> Error("Source extraction failed: " <> reason)
    Ok(client_source) -> {
      // Step 2: Create temp JS project structure
      let _ = run_command("rm -rf '" <> dir <> "' 2>/dev/null")
      case create_build_directories(dir) {
        Error(reason) -> Error("Directory setup failed: " <> reason)
        Ok(Nil) -> {

      // gleam.toml
      let toml =
        "name = \"beacon_client_app\"\nversion = \"0.1.0\"\ntarget = \"javascript\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\ngleam_json = \">= 3.1.0 and < 4.0.0\"\n"
      case simplifile.write(dir <> "/gleam.toml", toml) {
        Error(err) -> Error("Failed to write gleam.toml: " <> string.inspect(err))
        Ok(Nil) -> {

      // Step 3: Write extracted pure source as app.gleam
      case simplifile.write(dir <> "/src/app.gleam", client_source) {
        Error(err) -> Error("Failed to write app.gleam: " <> string.inspect(err))
        Ok(Nil) -> {

      // Step 4: Copy pure beacon modules
      copy_file(
        beacon_root <> "/src/beacon/element.gleam",
        dir <> "/src/beacon/element.gleam",
      )
      copy_file(
        beacon_root <> "/src/beacon/html.gleam",
        dir <> "/src/beacon/html.gleam",
      )
      copy_file(
        beacon_root <> "/src/beacon/template/rendered.gleam",
        dir <> "/src/beacon/template/rendered.gleam",
      )

      // Step 5: Copy beacon_client handler + FFI + patch module
      copy_file(
        beacon_root <> "/beacon_client/src/beacon_client/handler.gleam",
        dir <> "/src/beacon_client/handler.gleam",
      )
      copy_file(
        beacon_root <> "/beacon_client/src/beacon_client/patch.mjs",
        dir <> "/src/beacon_client/patch.mjs",
      )
      copy_file(
        beacon_root <> "/beacon_client/src/beacon_client_ffi.mjs",
        dir <> "/src/beacon_client_ffi.mjs",
      )

      // Step 5.5: Copy external domain module files (for multi-file apps)
      let app_base_dir = source_dir(path)
      list.each(analysis.imported_modules, fn(im) {
        let src_path = app_base_dir <> "/" <> im.module_path <> ".gleam"
        // Create target directory if needed
        let target_dir = case string.split(im.module_path, "/") |> list.reverse {
          [_, ..rest] ->
            case list.reverse(rest) {
              [] -> ""
              parts -> string.join(parts, "/")
            }
          _ -> ""
        }
        case target_dir {
          "" -> Nil
          d -> {
            let _ = simplifile.create_directory_all(dir <> "/src/" <> d)
            Nil
          }
        }
        copy_file(src_path, dir <> "/src/" <> im.module_path <> ".gleam")
      })

      // Step 6: Generate JS beacon.gleam (event helpers using beacon_client/handler)
      case simplifile.write(dir <> "/src/beacon.gleam", generate_js_beacon()) {
        Error(err) -> Error("Failed to write beacon.gleam: " <> string.inspect(err))
        Ok(Nil) -> {

      // Step 7: Generate beacon_app_entry.gleam
      // Check if update was extracted (pure update → LOCAL + optimistic)
      let has_client_update = string.contains(client_source, "pub fn update(")
      let entry = generate_entry_point(analysis, source, has_client_update)
      case simplifile.write(dir <> "/src/beacon_app_entry.gleam", entry) {
        Error(err) -> Error("Failed to write entry point: " <> string.inspect(err))
        Ok(Nil) -> {

      // Step 8: Compile JS project
      let compile_result =
        run_command("cd '" <> dir <> "' && gleam build 2>&1")
      case string.contains(compile_result, "Compiled in") {
        False ->
          Error("JS compilation failed:\n" <> compile_result)
        True -> {
          // Step 9: Bundle with esbuild
          case simplifile.create_directory_all("priv/static") {
            Error(err) ->
              Error("Failed to create priv/static: " <> string.inspect(err))
            Ok(Nil) -> {

          // Entry point that sets window.BeaconApp
          let entry_js =
            "import { initClientAfterBoot } from './build/dev/javascript/beacon_client_app/beacon_client_ffi.mjs';\nimport * as App from './build/dev/javascript/beacon_client_app/beacon_app_entry.mjs';\nwindow.BeaconApp = App;\ninitClientAfterBoot();\n"
          case simplifile.write(dir <> "/bundle_entry.mjs", entry_js) {
            Error(err) -> Error("Failed to write bundle entry: " <> string.inspect(err))
            Ok(Nil) -> {

          let hash = run_command("date +%s | shasum | head -c 8")
          let filename = "beacon_client_" <> string.trim(hash) <> ".js"
          let _ = run_command("rm -f priv/static/beacon_client_*.js 2>/dev/null")

          let result =
            run_command(
              "cd '" <> dir <> "' && npx esbuild bundle_entry.mjs --bundle --format=iife --global-name=Beacon --outfile=../../priv/static/" <> filename <> " --minify 2>&1",
            )
          case string.contains(result, "Done") || string.contains(result, ".js") {
            True -> {
              case simplifile.write("priv/static/beacon_client.manifest", filename) {
                Ok(Nil) -> Ok(Nil)
                Error(err) -> Error("Failed to write manifest: " <> string.inspect(err))
              }
            }
            False -> Error("esbuild failed:\n" <> result)
          }
          }
          }
          }
          }
        }
      }
      }
      }
      }
      }
      }
      }
      }
      }
      }
      }
    }
  }
}

/// Copy a file, logging on failure.
fn copy_file(from: String, to: String) -> Nil {
  case simplifile.read(from) {
    Ok(contents) -> {
      case simplifile.write(to, contents) {
        Ok(Nil) -> Nil
        Error(err) ->
          log.error("beacon.build", "Failed to write " <> to <> ": " <> string.inspect(err))
      }
    }
    Error(err) ->
      log.warning("beacon.build", "Could not copy " <> from <> ": " <> string.inspect(err))
  }
}

/// Generate the JS-target beacon.gleam with event helpers using beacon_client/handler.
/// This is a REAL implementation, not a stub — same API, JS-compatible handler.
fn generate_js_beacon() -> String {
  "/// Client-side beacon module — event helpers for JS target.
import beacon/element.{type Attr}
import beacon_client/handler

/// A node in the virtual DOM tree.
pub type Node(msg) = element.Node(msg)

pub fn on_click(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"click\", handler_id: id)
}

pub fn on_input(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"input\", handler_id: id)
}

pub fn on_submit(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"submit\", handler_id: id)
}

pub fn on_change(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"change\", handler_id: id)
}

pub fn on_mousedown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mousedown\", handler_id: id)
}

pub fn on_mouseup(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"mouseup\", handler_id: id)
}

pub fn on_mousemove(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mousemove\", handler_id: id)
}

pub fn on_keydown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"keydown\", handler_id: id)
}

pub fn on_dragstart(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"dragstart\", handler_id: id)
}

pub fn on_dragover(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"dragover\", handler_id: id)
}

pub fn on_drop(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"drop\", handler_id: id)
}
"
}

/// Generate a decoder expression for a field type (client-side entry point).
fn decoder_for_field(
  field: analyzer.TypeField,
  custom_types: List(analyzer.CustomTypeInfo),
  enum_types: List(analyzer.EnumTypeInfo),
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
          case find_custom_type(custom_types, inner, field.inner_module) {
            Ok(ct) ->
              "decode.list("
              <> decoder_name(ct.module, ct.name)
              <> "())"
            Error(_) -> "decode.list(decode.dynamic)"
          }
      }
    _ ->
      // Check if it's an enum type → decode as string
      case find_enum_type(enum_types, field.type_name, field.module) {
        Ok(_) -> "decode.string"
        Error(_) ->
          // Check if it's a custom record type → use its decoder
          case find_custom_type(custom_types, field.type_name, field.module) {
            Ok(ct) -> decoder_name(ct.module, ct.name) <> "()"
            Error(_) -> "decode.dynamic"
          }
      }
  }
}

/// Generate a decoder function for a custom type (e.g., Card).
fn generate_custom_decoder(
  ct: analyzer.CustomTypeInfo,
  enum_types: List(analyzer.EnumTypeInfo),
) -> String {
  let qualified = qualify_type_client(ct.module, ct.name)
  let fn_name = decoder_name(ct.module, ct.name)
  let fields =
    list.map(ct.fields, fn(f) {
      let decoder = case f.type_name {
        "Int" -> "decode.int"
        "Float" -> "decode.float"
        "Bool" -> "decode.bool"
        "String" -> "decode.string"
        _ ->
          // Check if it's an enum type → use string decoder + converter
          case find_enum_type(enum_types, f.type_name, f.module) {
            Ok(_) -> "decode.string"
            Error(_) -> "decode.string"
          }
      }
      "  use "
      <> f.name
      <> " <- decode.field(\""
      <> f.name
      <> "\", "
      <> decoder
      <> ")"
    })
  // For enum fields, convert the decoded string to the enum variant
  let constructor_args =
    list.map(ct.fields, fn(f) {
      case find_enum_type(enum_types, f.type_name, f.module) {
        Ok(et) ->
          f.name
          <> ": "
          <> decoder_name(et.module, et.name)
          <> "_value("
          <> f.name
          <> ")"
        Error(_) -> f.name <> ": " <> f.name
      }
    })
  "fn "
  <> fn_name
  <> "() -> decode.Decoder("
  <> qualified
  <> ") {\n"
  <> string.join(fields, "\n")
  <> "\n  decode.success("
  <> qualified
  <> "("
  <> string.join(constructor_args, ", ")
  <> "))\n}"
}

/// Generate a decoder function for an enum type (e.g., "todo" → Column.Todo).
fn generate_enum_decoder(et: analyzer.EnumTypeInfo) -> String {
  let qualified = qualify_type_client(et.module, et.name)
  let variant_prefix = case et.module {
    "" -> "app"
    mod -> mod
  }
  let fn_name = decoder_name(et.module, et.name)
  let arms =
    list.map(et.variants, fn(v) {
      "    \""
      <> string.lowercase(v)
      <> "\" -> "
      <> variant_prefix
      <> "."
      <> v
    })
  let first_variant = case et.variants {
    [first, ..] -> variant_prefix <> "." <> first
    [] -> variant_prefix <> ".Unknown"
  }
  "fn "
  <> fn_name
  <> "_value(s: String) -> "
  <> qualified
  <> " {\n  case s {\n"
  <> string.join(arms, "\n")
  <> "\n    _ -> "
  <> first_variant
  <> "\n  }\n}"
}

/// Generate the entry point for state-over-the-wire.
/// Client needs: view_to_html, decode_model, handler registry.
/// Does NOT include update (runs on server only).
fn generate_entry_point(
  analysis: analyzer.Analysis,
  source: String,
  has_client_update: Bool,
) -> String {
  // Generate custom type decoders — deduplicated.
  // Collect all custom type names referenced by Model fields,
  // then generate one decoder per unique type.
  let needed_types =
    list.filter_map(analysis.model_fields, fn(f) {
      case f.type_name {
        "List" ->
          case find_custom_type(analysis.custom_types, f.inner_type, f.inner_module) {
            Ok(ct) -> Ok(ct)
            Error(_) -> Error(Nil)
          }
        _ ->
          case find_custom_type(analysis.custom_types, f.type_name, f.module) {
            Ok(ct) -> Ok(ct)
            Error(_) -> Error(Nil)
          }
      }
    })
    |> list.unique
  let custom_decoder_fns =
    list.map(needed_types, fn(ct) {
      generate_custom_decoder(ct, analysis.enum_types)
    })

  // Generate enum decoders
  let enum_decoder_fns =
    list.map(analysis.enum_types, fn(et) {
      generate_enum_decoder(et)
    })

  let custom_decoders_code =
    string.join(
      list.append(custom_decoder_fns, enum_decoder_fns),
      "\n\n",
    )

  // Generate model decoder
  let decode_fields =
    list.map(analysis.model_fields, fn(f) {
      let decoder = decoder_for_field(f, analysis.custom_types, analysis.enum_types)
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
      // For enum fields, convert the decoded string to the enum variant
      case find_enum_type(analysis.enum_types, f.type_name, f.module) {
        Ok(et) ->
          f.name
          <> ": "
          <> decoder_name(et.module, et.name)
          <> "_value("
          <> f.name
          <> ")"
        Error(_) -> f.name <> ": " <> f.name
      }
    })
  let constructor_call =
    "app.Model(" <> string.join(model_constructor_args, ", ") <> ")"

  // Determine view/init_local signatures based on has_local
  // init_local tries app.init_local if available, otherwise returns stub
  let #(init_local_fn, view_fn) = case analysis.has_local {
    True -> #(
      "pub fn init_local(model: app.Model) -> app.Local {\n  case True {\n    True -> app.init_local(model)\n    _ -> app.init_local(model)\n  }\n}",
      "pub fn view_to_html(model: app.Model, local: app.Local) -> String {\n  element.to_string(app.view(model, local))\n}",
    )
    False -> #(
      "pub fn init_local(_model: app.Model) -> Nil {\n  Nil\n}",
      "pub fn view_to_html(model: app.Model, _local: Nil) -> String {\n  element.to_string(app.view(model))\n}",
    )
  }

  // Generate default model constructor with zero/empty values for init stub
  let default_model_args =
    list.map(analysis.model_fields, fn(f) {
      let default_val = case f.type_name {
        "Int" -> "0"
        "Float" -> "0.0"
        "Bool" -> "False"
        "String" -> "\"\""
        "List" -> "[]"
        _ ->
          case find_enum_type(analysis.enum_types, f.type_name, f.module) {
            Ok(et) -> {
              let prefix = case et.module {
                "" -> "app"
                mod -> mod
              }
              case et.variants {
                [first, ..] -> prefix <> "." <> first
                [] -> prefix <> ".Unknown"
              }
            }
            Error(_) -> {
              log.error(
                "beacon.build",
                "Unknown type '"
                  <> f.type_name
                  <> "' for field '"
                  <> f.name
                  <> "' — no enum found, defaulting to json.null in init stub",
              )
              "json.null"
            }
          }
      }
      f.name <> ": " <> default_val
    })
  let default_model =
    "app.Model(" <> string.join(default_model_args, ", ") <> ")"

  // Generate external module imports for the entry point
  let entry_ext_imports = generate_external_imports(analysis, "")
  let entry_ext_imports_section = case entry_ext_imports {
    "" -> ""
    imports -> imports <> "\n"
  }

  // State-over-the-wire: client only needs view + decode_model + handler registry.
  // init() returns a stub model — the real model comes from server via model_sync.
  "/// AUTO-GENERATED entry point for state-over-the-wire.
/// Client renders view locally from server-sent model JSON.
import app
import beacon/element
import beacon_client/handler
import gleam/dynamic/decode
import gleam/json
" <> entry_ext_imports_section <> "
/// Stub init — the real model comes from server via model_sync.
pub fn init() -> app.Model {
  " <> default_model <> "
}

" <> init_local_fn <> "

pub fn start_render() {
  handler.start_render()
}

pub fn finish_render() {
  handler.finish_render()
}

pub fn resolve_handler(registry, handler_id: String, data: String) {
  handler.resolve(registry, handler_id, data)
}

" <> view_fn <> "
" <> generate_update_and_classifier(analysis, has_client_update) <> "
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

" <> generate_client_encode_model(analysis, source) <> "
" <> generate_local_decoder(analysis, source) <> "
"
}

/// Generate the client-side encode_model function.
/// For non-Local apps: encode_model(model, _local) encodes only Model fields.
/// For Local apps: encode_model(model, local) encodes both Model and Local fields,
/// matching the server's model_sync JSON format exactly.
fn generate_client_encode_model(
  analysis: analyzer.Analysis,
  source: String,
) -> String {
  let model_fields = generate_client_encoder_fields(analysis)
  let custom_encoders_code = generate_client_custom_encoders(analysis)
  case analysis.has_local {
    False ->
      custom_encoders_code <> "
/// Encode model to JSON string for patch diffing.
pub fn encode_model(model: app.Model, _local: Nil) -> String {
  json.object([
" <> model_fields <> "
  ])
  |> json.to_string
}
"
    True -> {
      let local_fields = case find_local_fields(source) {
        Ok(fields) -> fields
        Error(_) -> {
          log.debug(
            "beacon.build",
            "Could not extract Local fields from source — using empty field list for encoder",
          )
          []
        }
      }
      // Build local field encoders using the same infrastructure as model fields
      // Need to create a temporary analysis-like context for Local fields
      let local_field_strs = generate_field_encoders(local_fields, "local", analysis)
      let all_fields = model_fields <> "\n" <> local_field_strs
      custom_encoders_code <> "
/// Encode model+local to JSON for patch diffing.
/// Matches server model_sync format (both Model and Local fields).
pub fn encode_model(model: app.Model, local: app.Local) -> String {
  json.object([
" <> all_fields <> "
  ])
  |> json.to_string
}
"
    }
  }
}

/// Generate JSON encoder field expressions for the client-side encode_model.
/// Uses `app.Model` field accessors with `json.*` encoders.
/// Prefix is "model" or "local" depending on where the fields come from.
fn generate_client_encoder_fields(analysis: analyzer.Analysis) -> String {
  generate_field_encoders(analysis.model_fields, "model", analysis)
}

/// Generate field encoder expressions for a list of fields.
fn generate_field_encoders(
  fields: List(analyzer.TypeField),
  prefix: String,
  analysis: analyzer.Analysis,
) -> String {
  let field_strs =
    list.map(fields, fn(f) {
      let accessor = prefix <> "." <> f.name
      let encoder = case f.type_name {
        "Int" -> "json.int(" <> accessor <> ")"
        "Float" -> "json.float(" <> accessor <> ")"
        "Bool" -> "json.bool(" <> accessor <> ")"
        "String" -> "json.string(" <> accessor <> ")"
        "List" ->
          case f.inner_type {
            "Int" -> "json.array(" <> accessor <> ", json.int)"
            "Float" -> "json.array(" <> accessor <> ", json.float)"
            "Bool" -> "json.array(" <> accessor <> ", json.bool)"
            "String" -> "json.array(" <> accessor <> ", json.string)"
            inner ->
              case find_custom_type(analysis.custom_types, inner, f.inner_module) {
                Ok(ct) ->
                  "json.array("
                  <> accessor
                  <> ", client_"
                  <> encoder_name(ct.module, ct.name)
                  <> ")"
                Error(_) -> "json.array(" <> accessor <> ", fn(_) { json.null() })"
              }
          }
        _ ->
          case find_enum_type(analysis.enum_types, f.type_name, f.module) {
            Ok(et) ->
              "json.string(client_"
              <> encoder_name(et.module, et.name)
              <> "("
              <> accessor
              <> "))"
            Error(_) ->
              case find_custom_type(analysis.custom_types, f.type_name, f.module) {
                Ok(ct) ->
                  "client_"
                  <> encoder_name(ct.module, ct.name)
                  <> "("
                  <> accessor
                  <> ")"
                Error(_) -> "json.string(\"<unsupported>\")"
              }
          }
      }
      "    #(\"" <> f.name <> "\", " <> encoder <> "),"
    })
  string.join(field_strs, "\n")
}

/// Generate client-side encoder functions for custom types used in Model/Local fields.
fn generate_client_custom_encoders(analysis: analyzer.Analysis) -> String {
  // Collect all custom types referenced by Model or Local fields
  let all_fields = analysis.model_fields
  let needed_types =
    list.filter_map(all_fields, fn(f) {
      case f.type_name {
        "List" ->
          case find_custom_type(analysis.custom_types, f.inner_type, f.inner_module) {
            Ok(ct) -> Ok(ct)
            Error(_) -> Error(Nil)
          }
        _ ->
          case find_custom_type(analysis.custom_types, f.type_name, f.module) {
            Ok(ct) -> Ok(ct)
            Error(_) -> Error(Nil)
          }
      }
    })
    |> list.unique
  let type_encoders =
    list.map(needed_types, fn(ct) {
      let qualified = qualify_type_client(ct.module, ct.name)
      let fn_name = "client_" <> encoder_name(ct.module, ct.name)
      let field_encoders =
        list.map(ct.fields, fn(f) {
          let encoder = case f.type_name {
            "Int" -> "json.int(s." <> f.name <> ")"
            "Float" -> "json.float(s." <> f.name <> ")"
            "Bool" -> "json.bool(s." <> f.name <> ")"
            "String" -> "json.string(s." <> f.name <> ")"
            _ ->
              case find_enum_type(analysis.enum_types, f.type_name, f.module) {
                Ok(et) ->
                  "json.string(client_"
                  <> encoder_name(et.module, et.name)
                  <> "(s."
                  <> f.name
                  <> "))"
                Error(_) -> "json.string(s." <> f.name <> ")"
              }
          }
          "    #(\"" <> f.name <> "\", " <> encoder <> "),"
        })
      "fn "
      <> fn_name
      <> "(s: "
      <> qualified
      <> ") -> json.Json {\n  json.object([\n"
      <> string.join(field_encoders, "\n")
      <> "\n  ])\n}"
    })
  let enum_encoders =
    list.map(analysis.enum_types, fn(et) {
      let qualified = qualify_type_client(et.module, et.name)
      let variant_prefix = case et.module {
        "" -> "app"
        mod -> mod
      }
      let fn_name = "client_" <> encoder_name(et.module, et.name)
      let arms =
        list.map(et.variants, fn(v) {
          "    " <> variant_prefix <> "." <> v <> " -> \"" <> string.lowercase(v) <> "\""
        })
      "fn "
      <> fn_name
      <> "(value: "
      <> qualified
      <> ") -> String {\n  case value {\n"
      <> string.join(arms, "\n")
      <> "\n  }\n}"
    })
  string.join(list.append(type_encoders, enum_encoders), "\n\n")
}

/// Generate update + msg_affects_model if update was extracted (pure).
/// These enable LOCAL events and optimistic MODEL updates on the client.
fn generate_update_and_classifier(
  analysis: analyzer.Analysis,
  has_client_update: Bool,
) -> String {
  case has_client_update {
    False -> ""
    True -> {
      // Generate update function
      let update_fn = case analysis.has_local {
        True ->
          "pub fn update(model: app.Model, local: app.Local, msg: app.Msg) -> #(app.Model, app.Local) {\n  app.update(model, local, msg)\n}"
        False ->
          "pub fn update(model: app.Model, local: Nil, msg: app.Msg) -> #(app.Model, Nil) {\n  #(app.update(model, msg), Nil)\n}"
      }

      // Generate msg_affects_model classifier
      let affects_model_arms =
        list.map(analysis.msg_variants, fn(v) {
          let pattern = case v.affects_model {
            True -> "True"
            False -> "False"
          }
          "    app."
          <> v.name
          <> case string.contains(v.name, "(") {
            True -> ""
            False -> "(..)"
          }
          <> " -> "
          <> pattern
        })
      let affects_model_body =
        string.join(affects_model_arms, "\n") <> "\n    _ -> True"

      "
" <> update_fn <> "

pub fn msg_affects_model(msg: app.Msg) -> Bool {
  case msg {
" <> affects_model_body <> "
  }
}
"
    }
  }
}

/// Generate decode_local function for apps with Local type.
/// Returns empty string if no Local type.
fn generate_local_decoder(
  analysis: analyzer.Analysis,
  source: String,
) -> String {
  case analysis.has_local {
    False -> ""
    True -> {
      let local_fields = case find_local_fields(source) {
        Ok(fields) -> fields
        Error(_) -> {
          log.debug(
            "beacon.build",
            "Could not extract Local fields from source — using empty field list for local decoder",
          )
          []
        }
      }
      let decode_fields =
        list.map(local_fields, fn(f) {
          let decoder = decoder_for_field(f, analysis.custom_types, analysis.enum_types)
          "    use "
          <> f.name
          <> " <- decode.field(\""
          <> f.name
          <> "\", "
          <> decoder
          <> ")"
        })
      let local_args =
        list.map(local_fields, fn(f) {
          case find_enum_type(analysis.enum_types, f.type_name, f.module) {
            Ok(et) ->
              f.name
              <> ": "
              <> decoder_name(et.module, et.name)
              <> "_value("
              <> f.name
              <> ")"
            Error(_) -> f.name <> ": " <> f.name
          }
        })
      let local_constructor = case local_args {
        [] -> "app.Local"
        _ -> "app.Local(" <> string.join(local_args, ", ") <> ")"
      }

      "
pub fn decode_local(json_str: String) -> Result(app.Local, String) {
  let local_decoder = {
" <> string.join(decode_fields, "\n") <> "
    decode.success(" <> local_constructor <> ")
  }
  case json.parse(json_str, local_decoder) {
    Ok(local) -> Ok(local)
    Error(_) -> Error(\"Failed to decode local\")
  }
}"
    }
  }
}

/// Auto-build: find the app module in src/ and build enhanced bundle.
/// Build the base client JS for routed apps (no app-specific codec/view).
/// This bundles only the core runtime: WebSocket, morphing, event delegation.
/// Each route will render server-side; the client does HTML morphing only.
pub fn build_base_client() -> Nil {
  let beacon_root = find_beacon_root()
  let dir = "build/beacon_client_base"
  // The beacon_client package has a pre-built JS output tree
  let bc_js = beacon_root <> "/beacon_client/build/dev/javascript"

  // Clean
  let _ = run_command("rm -rf '" <> dir <> "' 2>/dev/null")
  let _ = run_command("mkdir -p '" <> dir <> "'")

  // Ensure beacon_client is built (JS target)
  let bc_build_result =
    run_command("cd '" <> beacon_root <> "/beacon_client' && gleam build --target javascript 2>&1")
  log.debug("beacon.build", "beacon_client build: " <> bc_build_result)

  // Resolve absolute path for the entry point import
  let abs_bc_js = run_command("cd '" <> bc_js <> "' && pwd")
  let abs_bc_path = string.trim(abs_bc_js)

  // Create entry point — just import the client module.
  // It auto-boots via the data-beacon-auto script attribute detection.
  let entry_js =
    "import '"
    <> abs_bc_path
    <> "/beacon_client/beacon_client_ffi.mjs';\n"
  case simplifile.write(dir <> "/entry.mjs", entry_js) {
    Error(err) -> {
      log.error(
        "beacon.build",
        "Failed to write entry: " <> string.inspect(err),
      )
    }
    Ok(Nil) -> {
      // Create priv/static
      case simplifile.create_directory_all("priv/static") {
        Error(err) -> {
          log.error(
            "beacon.build",
            "Failed to create priv/static: " <> string.inspect(err),
          )
        }
        Ok(Nil) -> {
          let hash = run_command("date +%s | shasum | head -c 8")
          let filename = "beacon_client_" <> string.trim(hash) <> ".js"
          let _ = run_command("rm -f priv/static/beacon_client_*.js 2>/dev/null")
          let result =
            run_command(
              "cd '" <> dir <> "' && npx esbuild entry.mjs --bundle --format=iife --outfile=../../priv/static/" <> filename <> " --minify 2>&1",
            )
          case string.contains(result, "Done") || string.contains(result, ".js") {
            True -> {
              case simplifile.write("priv/static/beacon_client.manifest", filename) {
                Ok(Nil) -> {
                  log.info(
                    "beacon.build",
                    "Base client JS built: " <> filename,
                  )
                }
                Error(err) ->
                  log.error(
                    "beacon.build",
                    "Failed to write manifest: " <> string.inspect(err),
                  )
              }
            }
            False ->
              log.error(
                "beacon.build",
                "esbuild failed for base client:\n" <> result,
              )
          }
        }
      }
    }
  }
}

/// Called automatically by beacon.start() when no manifest exists.
pub fn auto_build() -> Nil {
  case find_app_module("src") {
    Ok(#(path, source)) -> {
      log.info("beacon.build", "Found app module: " <> path)
      compile_module(path, source)
    }
    Error(reason) -> {
      // No app module found — error loudly, do NOT fall back to runtime-only bundle
      log.error(
        "beacon.build",
        "No app module found in src/: " <> reason
        <> " — no client JS will be produced. "
        <> "Ensure your app has pub type Model, pub type Msg, pub fn update, and pub fn view.",
      )
    }
  }
}

// ===== Codec Generation =====

/// Qualify a type name for the server-side codec.
/// Local types use `module_name.TypeName`, external types use `alias.TypeName`.
fn qualify_type_server(
  module_name: String,
  type_module: String,
  type_name: String,
) -> String {
  case type_module {
    "" -> module_name <> "." <> type_name
    mod -> mod <> "." <> type_name
  }
}

/// Qualify a type name for the client-side entry point.
/// Local types use `app.TypeName`, external types use `alias.TypeName`.
fn qualify_type_client(type_module: String, type_name: String) -> String {
  case type_module {
    "" -> "app." <> type_name
    mod -> mod <> "." <> type_name
  }
}

/// Generate a function name prefix for external types to avoid collisions.
/// Local: "encode_card", External: "encode_auth_card".
fn encoder_name(type_module: String, type_name: String) -> String {
  case type_module {
    "" -> "encode_" <> string.lowercase(type_name)
    mod -> "encode_" <> mod <> "_" <> string.lowercase(type_name)
  }
}

/// Generate a decoder function name for custom types.
/// Local: "decode_card", External: "decode_auth_card".
fn decoder_name(type_module: String, type_name: String) -> String {
  case type_module {
    "" -> "decode_" <> string.lowercase(type_name)
    mod -> "decode_" <> mod <> "_" <> string.lowercase(type_name)
  }
}

/// Find the module of a custom type by name and module.
/// First tries exact match on both name and module; falls back to name-only for backward compat.
fn find_custom_type(
  custom_types: List(analyzer.CustomTypeInfo),
  name: String,
  module: String,
) -> Result(analyzer.CustomTypeInfo, Nil) {
  case list.find(custom_types, fn(ct) { ct.name == name && ct.module == module }) {
    Ok(ct) -> Ok(ct)
    Error(_) ->
      // Backward compat: if module is empty, try any matching name
      case module {
        "" -> list.find(custom_types, fn(ct) { ct.name == name })
        _ -> Error(Nil)
      }
  }
}

/// Find an enum type by name and module.
fn find_enum_type(
  enum_types: List(analyzer.EnumTypeInfo),
  name: String,
  module: String,
) -> Result(analyzer.EnumTypeInfo, Nil) {
  case list.find(enum_types, fn(ct) { ct.name == name && ct.module == module }) {
    Ok(et) -> Ok(et)
    Error(_) ->
      case module {
        "" -> list.find(enum_types, fn(et) { et.name == name })
        _ -> Error(Nil)
      }
  }
}

/// Generate import statements for external modules used in the analysis.
fn generate_external_imports(
  analysis: analyzer.Analysis,
  base_import: String,
) -> String {
  // Collect all unique module aliases referenced by model fields
  let modules_from_fields =
    list.filter_map(analysis.model_fields, fn(f) {
      case f.module {
        "" ->
          case f.inner_module {
            "" -> Error(Nil)
            mod -> Ok(mod)
          }
        mod -> Ok(mod)
      }
    })
    |> list.unique

  // Find the full module paths from imported_modules
  list.filter_map(modules_from_fields, fn(alias) {
    case
      list.find(analysis.imported_modules, fn(im) { im.alias == alias })
    {
      Ok(im) -> Ok("import " <> base_import <> im.module_path)
      Error(_) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

/// Generate a server-side encoder expression for a single field.
/// Used by both model and local field encoders.
fn generate_server_field_encoder(
  prefix: String,
  f: analyzer.TypeField,
  analysis: analyzer.Analysis,
) -> String {
  let accessor = prefix <> "." <> f.name
  case f.type_name {
    "Int" -> "json.int(" <> accessor <> ")"
    "Float" -> "json.float(" <> accessor <> ")"
    "Bool" -> "json.bool(" <> accessor <> ")"
    "String" -> "json.string(" <> accessor <> ")"
    "List" ->
      case f.inner_type {
        "Int" -> "json.array(" <> accessor <> ", json.int)"
        "Float" -> "json.array(" <> accessor <> ", json.float)"
        "Bool" -> "json.array(" <> accessor <> ", json.bool)"
        "String" -> "json.array(" <> accessor <> ", json.string)"
        inner ->
          case find_custom_type(analysis.custom_types, inner, f.inner_module) {
            Ok(ct) ->
              "json.array("
              <> accessor
              <> ", "
              <> encoder_name(ct.module, ct.name)
              <> ")"
            Error(_) -> "json.array(" <> accessor <> ", json.string)"
          }
      }
    _ ->
      // Check if it's an enum type
      case find_enum_type(analysis.enum_types, f.type_name, f.module) {
        Ok(et) ->
          "json.string("
          <> encoder_name(et.module, et.name)
          <> "("
          <> accessor
          <> "))"
        Error(_) ->
          // Check if it's a custom record type
          case find_custom_type(analysis.custom_types, f.type_name, f.module) {
            Ok(ct) ->
              encoder_name(ct.module, ct.name)
              <> "("
              <> accessor
              <> ")"
            Error(_) -> "json.string(" <> accessor <> ")"
          }
      }
  }
}

/// Extract the Gleam module import path from a file path.
/// e.g., "src/beacon/examples/kanban.gleam" → "beacon/examples/kanban"
/// e.g., "src/canvas.gleam" → "canvas"
fn extract_module_path(path: String) -> String {
  path
  |> string.replace(".gleam", "")
  |> string.replace("src/", "")
}

/// Extract just the short module name (last path segment).
/// In Gleam, `import beacon/examples/kanban` makes the module
/// accessible as `kanban.Model`, not `beacon/examples/kanban.Model`.
fn module_short_name(module_path: String) -> String {
  module_path
  |> string.split("/")
  |> list.last
  |> fn(r) {
    case r {
      Ok(name) -> name
      Error(_) -> module_path
    }
  }
}

/// Generate beacon_codec.gleam — auto-discovered by the runtime at startup.
fn generate_codec_module(
  module_path: String,
  analysis: analyzer.Analysis,
  source: String,
) -> Nil {
  let codec_path = "src/beacon_codec.gleam"
  // In Gleam, `import beacon/examples/kanban` makes it accessible as `kanban`
  let module_name = module_short_name(module_path)

  // Generate encoder for each custom type used in Model fields
  // Handles both List(CustomType) and direct CustomType fields
  let custom_encoders =
    list.filter_map(analysis.model_fields, fn(f) {
      case f.type_name {
        "List" ->
          case find_custom_type(analysis.custom_types, f.inner_type, f.inner_module) {
            Ok(ct) -> Ok(generate_type_encoder(module_name, ct, analysis))
            Error(_) -> Error(Nil)
          }
        _ ->
          // Direct custom type field (e.g., food: Point)
          case find_custom_type(analysis.custom_types, f.type_name, f.module) {
            Ok(ct) -> Ok(generate_type_encoder(module_name, ct, analysis))
            Error(_) -> Error(Nil)
          }
      }
    })
    |> list.unique

  // Generate encoders for enum types used in Model fields or custom type fields
  let enum_encoders =
    list.map(analysis.enum_types, fn(et) {
      generate_enum_encoder(module_name, et)
    })

  // Model field encoders
  let model_field_encoders =
    list.map(analysis.model_fields, fn(f) {
      let encoder = generate_server_field_encoder("model", f, analysis)
      "    #(\"" <> f.name <> "\", " <> encoder <> ")"
    })

  // For apps with Local, extract Local fields too
  let local_field_encoders = case analysis.has_local {
    True -> {
      let local_fields = case find_local_fields(source) {
        Ok(fields) -> fields
        Error(_) -> {
          log.debug(
            "beacon.build",
            "Could not extract Local fields from source — using empty field list for server encoder",
          )
          []
        }
      }
      list.map(local_fields, fn(f) {
        let encoder = generate_server_field_encoder("local", f, analysis)
        "    #(\"" <> f.name <> "\", " <> encoder <> ")"
      })
    }
    False -> []
  }

  let #(param_type, model_extract) = case analysis.has_local {
    True -> #(
      "#(" <> module_name <> ".Model, " <> module_name <> ".Local)",
      "  let model = state.0\n  let local = state.1\n",
    )
    False -> #(module_name <> ".Model", "  let model = state\n")
  }

  // Computed field encoders — @computed functions called server-side, results included in model_sync
  let computed_field_encoders =
    list.map(analysis.computed_fields, fn(cf) {
      let encoder = case cf.return_type {
        "Int" -> "json.int(" <> module_name <> "." <> cf.name <> "(model))"
        "Float" -> "json.float(" <> module_name <> "." <> cf.name <> "(model))"
        "Bool" -> "json.bool(" <> module_name <> "." <> cf.name <> "(model))"
        _ -> "json.string(" <> module_name <> "." <> cf.name <> "(model))"
      }
      "    #(\"" <> cf.name <> "\", " <> encoder <> ")"
    })

  let all_field_encoders = list.flatten([model_field_encoders, local_field_encoders, computed_field_encoders])

  // Generate server-side custom type decoders (for decode_model)
  let server_custom_decoders =
    list.filter_map(analysis.model_fields, fn(f) {
      case f.type_name {
        "List" ->
          case find_custom_type(analysis.custom_types, f.inner_type, f.inner_module) {
            Ok(ct) -> Ok(generate_server_custom_decoder(module_name, ct, analysis.enum_types))
            Error(_) -> Error(Nil)
          }
        _ ->
          case find_custom_type(analysis.custom_types, f.type_name, f.module) {
            Ok(ct) -> Ok(generate_server_custom_decoder(module_name, ct, analysis.enum_types))
            Error(_) -> Error(Nil)
          }
      }
    })
    |> list.unique

  // Generate server-side enum decoders (for decode_model)
  let server_enum_decoders =
    list.map(analysis.enum_types, fn(et) {
      generate_server_enum_decoder(module_name, et)
    })

  // Generate import statements for external modules
  let base_import_dir = case string.split(module_path, "/") |> list.reverse {
    [_, ..rest] ->
      case list.reverse(rest) {
        [] -> ""
        parts -> string.join(parts, "/") <> "/"
      }
    _ -> ""
  }
  let ext_imports = generate_external_imports(analysis, base_import_dir)
  let ext_imports_section = case ext_imports {
    "" -> ""
    imports -> imports <> "\n"
  }

  let source =
    "/// AUTO-GENERATED by beacon/build — do not edit manually.
/// Re-run `gleam run -m beacon/build` to regenerate.

import "
    <> module_path
    <> "\n"
    <> ext_imports_section
    <> "import gleam/dynamic/decode
import gleam/json

"
    <> string.join(custom_encoders, "\n\n")
    <> "\n\n"
    <> string.join(enum_encoders, "\n\n")
    <> "\n\n"
    <> string.join(server_custom_decoders, "\n\n")
    <> "\n\n"
    <> string.join(server_enum_decoders, "\n\n")
    <> "\n\n/// Encode the Model to JSON for model_sync.
pub fn encode_model(state: "
    <> param_type
    <> ") -> String {\n"
    <> model_extract
    <> "  json.object([\n"
    <> string.join(all_field_encoders, ",\n")
    <> ",\n  ])\n  |> json.to_string\n}\n"
    <> generate_server_decode_model(module_name, analysis, source)
    <> generate_substate_encoders(module_name, analysis)

  case simplifile.write(codec_path, source) {
    Ok(Nil) ->
      log.info("beacon.build", "Generated codec: " <> codec_path)
    Error(err) ->
      log.error(
        "beacon.build",
        "Failed to write codec " <> codec_path <> ": " <> string.inspect(err),
      )
  }
}

/// Generate per-substate encoder functions + substate_names + encode_flat_fields.
/// These enable the runtime to diff substates independently, skipping unchanged ones.
fn generate_substate_encoders(
  module_name: String,
  analysis: analyzer.Analysis,
) -> String {
  case analysis.substates {
    [] -> ""
    substates -> {
      // For Local apps, encoders take the tuple #(Model, Local) and extract model
      let #(param_type, model_extract) = case analysis.has_local {
        True -> #(
          "#(" <> module_name <> ".Model, " <> module_name <> ".Local)",
          "  let model = state.0\n",
        )
        False -> #(module_name <> ".Model", "  let model = state\n")
      }
      let param_name = case analysis.has_local {
        True -> "state"
        False -> "state"
      }
      // Generate encode_substate_<name> for each substate
      let substate_fns =
        list.map(substates, fn(s) {
          let enc_fn_name = encoder_name(s.module, s.type_name)
          let encoder_fn = case s.is_list {
            True ->
              "  json.array(model."
              <> s.field_name
              <> ", "
              <> enc_fn_name
              <> ")\n  |> json.to_string"
            False ->
              "  "
              <> enc_fn_name
              <> "(model."
              <> s.field_name
              <> ")\n  |> json.to_string"
          }
          "\npub fn encode_substate_"
          <> s.field_name
          <> "("
          <> param_name
          <> ": "
          <> param_type
          <> ") -> String {\n"
          <> model_extract
          <> encoder_fn
          <> "\n}\n"
        })

      // Generate substate_names()
      let names_list =
        list.map(substates, fn(s) { "\"" <> s.field_name <> "\"" })
      let names_fn =
        "\npub fn substate_names() -> List(String) {\n  ["
        <> string.join(names_list, ", ")
        <> "]\n}\n"

      // Generate encode_flat_fields — only the NON-substate fields
      let substate_field_names =
        list.map(substates, fn(s) { s.field_name })
      let flat_fields =
        list.filter(analysis.model_fields, fn(f) {
          !list.contains(substate_field_names, f.name)
        })
      let flat_encoders =
        list.map(flat_fields, fn(f) {
          let encoder = generate_server_field_encoder("model", f, analysis)
          "    #(\"" <> f.name <> "\", " <> encoder <> "),"
        })
      let flat_fn =
        "\npub fn encode_flat_fields("
        <> param_name
        <> ": "
        <> param_type
        <> ") -> String {\n"
        <> model_extract
        <> "  json.object([\n"
        <> string.join(flat_encoders, "\n")
        <> "\n  ])\n  |> json.to_string\n}\n"

      string.join(substate_fns, "") <> names_fn <> flat_fn
    }
  }
}

/// Generate the server-side decode_model function.
/// For non-Local apps: returns Result(module.Model, String)
/// For Local apps: returns Result(#(module.Model, module.Local), String) — the full state tuple.
fn generate_server_decode_model(
  module_name: String,
  analysis: analyzer.Analysis,
  source: String,
) -> String {
  // Model decoder fields
  let model_decode_fields =
    list.map(analysis.model_fields, fn(f) {
      let decoder = server_decoder_for_field(f, analysis.custom_types, analysis.enum_types)
      "    use "
      <> f.name
      <> " <- decode.field(\""
      <> f.name
      <> "\", "
      <> decoder
      <> ")"
    })
  let model_decode_body = string.join(model_decode_fields, "\n")

  let model_constructor_args =
    list.map(analysis.model_fields, fn(f) {
      case find_enum_type(analysis.enum_types, f.type_name, f.module) {
        Ok(et) ->
          f.name
          <> ": server_"
          <> decoder_name(et.module, et.name)
          <> "_value("
          <> f.name
          <> ")"
        Error(_) -> f.name <> ": " <> f.name
      }
    })
  let model_constructor =
    module_name <> ".Model(" <> string.join(model_constructor_args, ", ") <> ")"

  case analysis.has_local {
    False ->
      "\n/// Decode a Model from JSON string (for applying client patches).\npub fn decode_model(json_str: String) -> Result("
      <> module_name
      <> ".Model, String) {\n"
      <> "  let model_decoder = {\n"
      <> model_decode_body
      <> "\n    decode.success("
      <> model_constructor
      <> ")\n  }\n"
      <> "  case json.parse(json_str, model_decoder) {\n"
      <> "    Ok(model) -> Ok(model)\n"
      <> "    Error(_) -> Error(\"Failed to decode model\")\n"
      <> "  }\n}\n"

    True -> {
      // Also decode Local fields and return the tuple #(Model, Local)
      let local_fields = case find_local_fields(source) {
        Ok(fields) -> fields
        Error(_) -> {
          log.debug(
            "beacon.build",
            "Could not extract Local fields from source — using empty field list for server decoder",
          )
          []
        }
      }
      let local_decode_fields =
        list.map(local_fields, fn(f) {
          let decoder = server_decoder_for_field(f, analysis.custom_types, analysis.enum_types)
          "    use "
          <> f.name
          <> " <- decode.field(\""
          <> f.name
          <> "\", "
          <> decoder
          <> ")"
        })
      let local_decode_body = string.join(local_decode_fields, "\n")
      let local_constructor_args =
        list.map(local_fields, fn(f) {
          case find_enum_type(analysis.enum_types, f.type_name, f.module) {
            Ok(et) ->
              f.name
              <> ": server_"
              <> decoder_name(et.module, et.name)
              <> "_value("
              <> f.name
              <> ")"
            Error(_) -> f.name <> ": " <> f.name
          }
        })
      let local_constructor = case local_constructor_args {
        [] -> module_name <> ".Local"
        _ -> module_name <> ".Local(" <> string.join(local_constructor_args, ", ") <> ")"
      }

      "\n/// Decode a #(Model, Local) from JSON string (for applying client patches).\npub fn decode_model(json_str: String) -> Result(#("
      <> module_name
      <> ".Model, "
      <> module_name
      <> ".Local), String) {\n"
      <> "  let state_decoder = {\n"
      <> model_decode_body
      <> "\n"
      <> local_decode_body
      <> "\n    decode.success(#("
      <> model_constructor
      <> ", "
      <> local_constructor
      <> "))\n  }\n"
      <> "  case json.parse(json_str, state_decoder) {\n"
      <> "    Ok(state) -> Ok(state)\n"
      <> "    Error(_) -> Error(\"Failed to decode model+local\")\n"
      <> "  }\n}\n"
    }
  }
}

/// Like decoder_for_field but uses server_decode_ prefix for custom types.
fn server_decoder_for_field(
  field: analyzer.TypeField,
  custom_types: List(analyzer.CustomTypeInfo),
  enum_types: List(analyzer.EnumTypeInfo),
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
          case find_custom_type(custom_types, inner, field.inner_module) {
            Ok(ct) ->
              "decode.list(server_"
              <> decoder_name(ct.module, ct.name)
              <> "())"
            Error(_) -> "decode.list(decode.dynamic)"
          }
      }
    _ ->
      case find_enum_type(enum_types, field.type_name, field.module) {
        Ok(_) -> "decode.string"
        Error(_) ->
          case find_custom_type(custom_types, field.type_name, field.module) {
            Ok(ct) ->
              "server_"
              <> decoder_name(ct.module, ct.name)
              <> "()"
            Error(_) -> "decode.dynamic"
          }
      }
  }
}

/// Generate a server-side decoder function for a custom record type.
/// Used in the codec's decode_model function.
fn generate_server_custom_decoder(
  module_name: String,
  ct: analyzer.CustomTypeInfo,
  enum_types: List(analyzer.EnumTypeInfo),
) -> String {
  let qualified = qualify_type_server(module_name, ct.module, ct.name)
  let fn_name = "server_" <> decoder_name(ct.module, ct.name)
  let fields =
    list.map(ct.fields, fn(f) {
      let decoder = case f.type_name {
        "Int" -> "decode.int"
        "Float" -> "decode.float"
        "Bool" -> "decode.bool"
        "String" -> "decode.string"
        _ ->
          case find_enum_type(enum_types, f.type_name, f.module) {
            Ok(_) -> "decode.string"
            Error(_) -> "decode.string"
          }
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
    list.map(ct.fields, fn(f) {
      case find_enum_type(enum_types, f.type_name, f.module) {
        Ok(et) ->
          f.name
          <> ": server_"
          <> decoder_name(et.module, et.name)
          <> "_value("
          <> f.name
          <> ")"
        Error(_) -> f.name <> ": " <> f.name
      }
    })
  "fn "
  <> fn_name
  <> "() -> decode.Decoder("
  <> qualified
  <> ") {\n"
  <> string.join(fields, "\n")
  <> "\n  decode.success("
  <> qualified
  <> "("
  <> string.join(constructor_args, ", ")
  <> "))\n}"
}

/// Generate a server-side enum decoder for the codec.
fn generate_server_enum_decoder(
  module_name: String,
  et: analyzer.EnumTypeInfo,
) -> String {
  let qualified = qualify_type_server(module_name, et.module, et.name)
  let variant_prefix = case et.module {
    "" -> module_name
    mod -> mod
  }
  let fn_name = "server_" <> decoder_name(et.module, et.name)
  let arms =
    list.map(et.variants, fn(v) {
      "    \""
      <> string.lowercase(v)
      <> "\" -> "
      <> variant_prefix
      <> "."
      <> v
    })
  let first_variant = case et.variants {
    [first, ..] -> variant_prefix <> "." <> first
    [] -> variant_prefix <> ".Unknown"
  }
  "fn "
  <> fn_name
  <> "_value(s: String) -> "
  <> qualified
  <> " {\n  case s {\n"
  <> string.join(arms, "\n")
  <> "\n    _ -> "
  <> first_variant
  <> "\n  }\n}"
}

/// Generate an encoder function for an enum type (e.g., Column → "todo").
fn generate_enum_encoder(
  module_name: String,
  et: analyzer.EnumTypeInfo,
) -> String {
  let qualified = qualify_type_server(module_name, et.module, et.name)
  // For variants, we need the module prefix (e.g., "kanban.Todo" or "auth.Active")
  let variant_prefix = case et.module {
    "" -> module_name
    mod -> mod
  }
  let fn_name = encoder_name(et.module, et.name)
  let arms =
    list.map(et.variants, fn(v) {
      "    "
      <> variant_prefix
      <> "."
      <> v
      <> " -> \""
      <> string.lowercase(v)
      <> "\""
    })
  "fn "
  <> fn_name
  <> "(value: "
  <> qualified
  <> ") -> String {\n  case value {\n"
  <> string.join(arms, "\n")
  <> "\n  }\n}"
}

/// Generate an encoder function for a custom type.
fn generate_type_encoder(
  module_name: String,
  ct: analyzer.CustomTypeInfo,
  analysis: analyzer.Analysis,
) -> String {
  let qualified = qualify_type_server(module_name, ct.module, ct.name)
  let fn_name = encoder_name(ct.module, ct.name)
  let field_encoders =
    list.map(ct.fields, fn(f) {
      let encoder = case f.type_name {
        "Int" -> "json.int(s." <> f.name <> ")"
        "Float" -> "json.float(s." <> f.name <> ")"
        "Bool" -> "json.bool(s." <> f.name <> ")"
        "String" -> "json.string(s." <> f.name <> ")"
        _ ->
          // Check if it's an enum type
          case find_enum_type(analysis.enum_types, f.type_name, f.module) {
            Ok(et) ->
              "json.string("
              <> encoder_name(et.module, et.name)
              <> "(s."
              <> f.name
              <> "))"
            Error(_) ->
              // Try encoding as enum via encode_<type> function (backward compat)
              "json.string(encode_"
              <> string.lowercase(f.type_name)
              <> "(s."
              <> f.name
              <> "))"
          }
      }
      "    #(\"" <> f.name <> "\", " <> encoder <> ")"
    })
  "fn "
  <> fn_name
  <> "(s: "
  <> qualified
  <> ") -> json.Json {\n  json.object([\n"
  <> string.join(field_encoders, ",\n")
  <> ",\n  ])\n}"
}

// ===== Helpers =====

/// Find the beacon package root directory.
fn find_beacon_root() -> String {
  case simplifile.is_file("src/beacon/element.gleam") {
    Ok(True) -> "."
    _ ->
      case read_beacon_path_from_toml() {
        Ok(path) -> path
        Error(_) ->
          case simplifile.is_directory("build/packages/beacon") {
            Ok(True) -> "build/packages/beacon"
            _ -> {
              log.error(
                "beacon.build",
                "FATAL: Cannot find beacon package source. "
                  <> "Checked ./src/beacon/element.gleam, gleam.toml path dep, "
                  <> "and build/packages/beacon. "
                  <> "Ensure beacon is a dependency in gleam.toml. "
                  <> "Build will likely fail.",
              )
              "."
            }
          }
      }
  }
}

/// Parse gleam.toml to find beacon path dependency.
fn read_beacon_path_from_toml() -> Result(String, Nil) {
  case simplifile.read("gleam.toml") {
    Ok(contents) -> {
      let lines = string.split(contents, "\n")
      list.find_map(lines, fn(line) {
        case
          string.contains(line, "beacon")
          && string.contains(line, "path")
        {
          True -> {
            case string.split(line, "\"") {
              [_, path, ..] -> Ok(path)
              _ -> Error(Nil)
            }
          }
          False -> Error(Nil)
        }
      })
    }
    Error(err) -> {
      log.error(
        "beacon.build",
        "Failed to read gleam.toml: " <> string.inspect(err),
      )
      Error(Nil)
    }
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
                      let has_model =
                        string.contains(source, "pub type Model")
                      let has_msg = string.contains(source, "pub type Msg")
                      case has_update && has_view && has_model && has_msg {
                        True -> Ok(#(path, source))
                        False -> Error(Nil)
                      }
                    }
                    Error(err) -> {
                      log.error(
                        "beacon.build",
                        "Failed to read " <> path <> ": " <> string.inspect(err),
                      )
                      Error(Nil)
                    }
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

/// Extract Local type fields from source using the analyzer.
fn find_local_fields(source: String) -> Result(List(analyzer.TypeField), Nil) {
  case glance.module(source) {
    Ok(module) -> {
      case
        list.find(module.custom_types, fn(def) {
          def.definition.name == "Local"
        })
      {
        Ok(def) -> Ok(extract_type_fields(def.definition))
        Error(Nil) -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Extract fields from a custom type (reuses analyzer logic).
fn extract_type_fields(
  custom_type: glance.CustomType,
) -> List(analyzer.TypeField) {
  case custom_type.variants {
    [variant, ..] ->
      list.filter_map(variant.fields, fn(field) {
        case field {
          glance.LabelledVariantField(item: field_type, label: name) -> {
            let #(type_name, inner, mod_val, inner_mod_val) = case field_type {
              glance.NamedType(name: n, module: mod, parameters: params, ..) ->
                case params {
                  [glance.NamedType(name: inner_name, module: inner_mod, ..)] -> {
                    let m = case mod {
                      option.Some(m) -> m
                      option.None -> {
                        log.debug("beacon.build", "No module qualifier for type field '" <> name <> "'")
                        ""
                      }
                    }
                    let im = case inner_mod {
                      option.Some(im) -> im
                      option.None -> {
                        log.debug("beacon.build", "No inner module qualifier for type field '" <> name <> "'")
                        ""
                      }
                    }
                    #(n, inner_name, m, im)
                  }
                  _ -> {
                    let m = case mod {
                      option.Some(m) -> m
                      option.None -> {
                        log.debug("beacon.build", "No module qualifier for type field '" <> name <> "'")
                        ""
                      }
                    }
                    #(n, "", m, "")
                  }
                }
              _ -> #("Unknown", "", "", "")
            }
            Ok(analyzer.TypeField(
              name: name,
              type_name: type_name,
              inner_type: inner,
              module: mod_val,
              inner_module: inner_mod_val,
            ))
          }
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Run `gleam build` to compile newly generated source files (e.g., beacon_codec.gleam).
/// Returns the build output.
pub fn run_gleam_build() -> String {
  run_command("gleam build 2>&1")
}

@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)

@external(erlang, "beacon_build_ffi", "run_command")
fn run_command(cmd: String) -> String
