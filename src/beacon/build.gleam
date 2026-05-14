/// Beacon build tool — builds the client runtime JS and generates the codec.
///
/// Usage: `gleam run -m beacon/build`
///
/// The client JS is the framework runtime (WS, event delegation, morphing).
/// User code runs ONLY on the server. This is the LiveView model.
/// No degraded build path — the build succeeds or fails loudly.
import beacon/build/analyzer
import beacon/log
import glance
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import simplifile

/// Build client JS for a specific source file.
/// Called by the example runner to auto-build before starting.
pub fn build_from_source(path: String) -> Nil {
  // Clean stale codec artifacts to prevent type mismatches between apps
  case clean_codec_artifacts() {
    Error(reason) -> log.error("beacon.build", reason)
    Ok(Nil) ->
      case simplifile.read(path) {
        Ok(source) -> {
          log.info("beacon.build", "Auto-building: " <> path)
          case compile_module(path, source) {
            Ok(Nil) -> Nil
            Error(reason) -> log.error("beacon.build", reason)
          }
        }
        Error(err) ->
          log.error(
            "beacon.build",
            "Cannot read " <> path <> ": " <> string.inspect(err),
          )
      }
  }
}

fn log_compile_result(result: Result(Nil, String)) -> Nil {
  case result {
    Ok(Nil) -> Nil
    Error(reason) -> log.error("beacon.build", reason)
  }
}

fn delete_path_if_exists(path: String) -> Result(Nil, String) {
  case simplifile.is_file(path) {
    Error(err) ->
      Error("Failed to inspect " <> path <> ": " <> string.inspect(err))
    Ok(True) -> delete_existing_path(path)
    Ok(False) -> {
      case simplifile.is_directory(path) {
        Error(err) ->
          Error("Failed to inspect " <> path <> ": " <> string.inspect(err))
        Ok(True) -> delete_existing_path(path)
        Ok(False) -> Ok(Nil)
      }
    }
  }
}

fn delete_existing_path(path: String) -> Result(Nil, String) {
  case simplifile.delete(path) {
    Ok(Nil) -> Ok(Nil)
    Error(err) ->
      Error("Failed to delete " <> path <> ": " <> string.inspect(err))
  }
}

fn clean_old_client_bundles(dir: String) -> Result(Nil, String) {
  case simplifile.get_files(dir) {
    Error(err) -> Error("Failed to list " <> dir <> ": " <> string.inspect(err))
    Ok(files) -> {
      let errors =
        list.filter_map(files, fn(f) {
          case
            string.contains(f, "beacon_client_") && string.ends_with(f, ".js")
          {
            False -> Error(Nil)
            True -> {
              case simplifile.delete(f) {
                Ok(Nil) -> Error(Nil)
                Error(err) ->
                  Ok(
                    "Failed to delete old bundle "
                    <> f
                    <> ": "
                    <> string.inspect(err),
                  )
              }
            }
          }
        })
      case errors {
        [] -> Ok(Nil)
        [first, ..] -> Error(first)
      }
    }
  }
}

fn optional_clean_generated_file(path: String) -> Result(Nil, String) {
  case simplifile.is_file(path) {
    Ok(False) -> Ok(Nil)
    Ok(True) -> delete_existing_path(path)
    Error(err) -> {
      log.error(
        "beacon.build",
        "Failed to inspect " <> path <> ": " <> string.inspect(err),
      )
      Error("Failed to inspect " <> path <> ": " <> string.inspect(err))
    }
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
          log_compile_result(compile_module(arg, source))
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
          log_compile_result(compile_module(path, source))
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
  source_root: String,
) -> Result(List(#(String, String, String)), String) {
  case glance.module(source) {
    Error(_) ->
      Error(
        "Failed to parse source for external module resolution in "
        <> source_root,
      )
    Ok(module) -> {
      let resolved =
        list.fold(module.imports, Ok([]), fn(acc_result, def) {
          case acc_result {
            Error(reason) -> Error(reason)
            Ok(acc) -> {
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
                True -> Ok(acc)
                False -> {
                  // Resolve to file path relative to the project's source root.
                  // For apps at src/app/model.gleam importing app/route,
                  // the file is at src/app/route.gleam.
                  let file_path = source_root <> "/" <> mod_path <> ".gleam"
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
                      Ok([#(alias, mod_path, ext_source), ..acc])
                    }
                    Error(_) -> {
                      // File doesn't exist — might be a hex package
                      log.debug(
                        "beacon.build",
                        "Could not read external module file for "
                          <> mod_path
                          <> " — likely a hex package, skipping",
                      )
                      Ok(acc)
                    }
                  }
                }
              }
            }
          }
        })
      case resolved {
        Ok(items) -> Ok(list.reverse(items))
        Error(reason) -> Error(reason)
      }
    }
  }
}

/// Resolve all transitive user-module sources reachable from a source file.
/// This follows imports recursively and preserves each module at most once.
pub fn resolve_transitive_external_sources(
  source: String,
  source_root: String,
) -> Result(List(#(String, String, String)), String) {
  case resolve_external_sources(source, source_root) {
    Error(reason) -> Error(reason)
    Ok(direct_sources) -> {
      case walk_external_sources(direct_sources, source_root, [], []) {
        Ok(#(sources, _seen)) -> Ok(sources)
        Error(reason) -> Error(reason)
      }
    }
  }
}

/// Resolve all transitive Beacon framework sources reachable from copied source text.
/// Only `beacon/*` imports are followed; the root `beacon` module is generated separately.
pub fn resolve_transitive_framework_sources(
  sources: List(String),
  beacon_root: String,
) -> Result(List(#(String, String, String)), String) {
  let direct_result =
    list.fold(sources, Ok([]), fn(acc_result, source) {
      case acc_result {
        Error(reason) -> Error(reason)
        Ok(acc) -> {
          case resolve_framework_sources(source, beacon_root) {
            Ok(resolved) -> Ok(list.append(resolved, acc))
            Error(reason) -> Error(reason)
          }
        }
      }
    })
  case direct_result {
    Error(reason) -> Error(reason)
    Ok(direct_sources) -> {
      case walk_framework_sources(direct_sources, beacon_root, [], []) {
        Ok(#(sources, _seen)) -> Ok(sources)
        Error(reason) -> Error(reason)
      }
    }
  }
}

fn walk_external_sources(
  pending: List(#(String, String, String)),
  source_root: String,
  seen: List(String),
  acc: List(#(String, String, String)),
) -> Result(#(List(#(String, String, String)), List(String)), String) {
  case pending {
    [] -> Ok(#(list.reverse(acc), seen))
    [ext, ..rest] -> {
      let #(alias, module_path, ext_source) = ext
      case list.contains(seen, module_path) {
        True -> walk_external_sources(rest, source_root, seen, acc)
        False -> {
          case resolve_external_sources(ext_source, source_root) {
            Error(reason) -> Error(reason)
            Ok(child_sources) ->
              walk_external_sources(
                list.append(child_sources, rest),
                source_root,
                [module_path, ..seen],
                [#(alias, module_path, ext_source), ..acc],
              )
          }
        }
      }
    }
  }
}

fn resolve_framework_sources(
  source: String,
  beacon_root: String,
) -> Result(List(#(String, String, String)), String) {
  case glance.module(source) {
    Error(_) -> Error("Failed to parse source while resolving Beacon imports")
    Ok(module) -> {
      let resolved =
        list.fold(module.imports, Ok([]), fn(acc_result, def) {
          case acc_result {
            Error(reason) -> Error(reason)
            Ok(acc) -> {
              let import_ = def.definition
              let mod_path = import_.module
              case string.starts_with(mod_path, "beacon/") {
                True -> {
                  let file_path = beacon_root <> "/src/" <> mod_path <> ".gleam"
                  case simplifile.read(file_path) {
                    Ok(ext_source) -> {
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
                      Ok([#(alias, mod_path, ext_source), ..acc])
                    }
                    Error(err) -> {
                      Error(
                        "Could not read framework module "
                        <> mod_path
                        <> ": "
                        <> string.inspect(err),
                      )
                    }
                  }
                }
                False -> Ok(acc)
              }
            }
          }
        })
      case resolved {
        Ok(items) -> Ok(list.reverse(items))
        Error(reason) -> Error(reason)
      }
    }
  }
}

fn walk_framework_sources(
  pending: List(#(String, String, String)),
  beacon_root: String,
  seen: List(String),
  acc: List(#(String, String, String)),
) -> Result(#(List(#(String, String, String)), List(String)), String) {
  case pending {
    [] -> Ok(#(list.reverse(acc), seen))
    [ext, ..rest] -> {
      let #(alias, module_path, ext_source) = ext
      case list.contains(seen, module_path) {
        True -> walk_framework_sources(rest, beacon_root, seen, acc)
        False -> {
          case resolve_framework_sources(ext_source, beacon_root) {
            Error(reason) -> Error(reason)
            Ok(child_sources) ->
              walk_framework_sources(
                list.append(child_sources, rest),
                beacon_root,
                [module_path, ..seen],
                [#(alias, module_path, ext_source), ..acc],
              )
          }
        }
      }
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

/// Resolve the root source directory for a Gleam file.
/// Examples:
/// - `src/app.gleam` -> `src`
/// - `src/app/model.gleam` -> `src`
/// - `examples/domains/src/app.gleam` -> `examples/domains/src`
pub fn source_root(path: String) -> String {
  let parts = string.split(path, "/")
  let root = source_root_parts(parts, [])
  case root {
    "" -> source_dir(path)
    _ -> root
  }
}

fn source_root_parts(parts: List(String), acc: List(String)) -> String {
  case parts {
    [] -> ""
    [part, ..rest] -> {
      let new_acc = [part, ..acc]
      case part {
        "src" -> string.join(list.reverse(new_acc), "/")
        _ -> source_root_parts(rest, new_acc)
      }
    }
  }
}

/// Compile a specific module — analyze, generate codec, build client JS.
/// Apps must produce a generated client-state bundle with view compiled to JS.
/// Unsupported app shapes log a structured error and startup aborts.
fn compile_module(path: String, source: String) -> Result(Nil, String) {
  // Resolve external module sources: imports + sibling files in same directory
  let base_dir = source_root(path)
  use import_sources <- result_try(resolve_transitive_external_sources(
    source,
    base_dir,
  ))
  use sibling_sources <- result_try(resolve_sibling_sources(path))
  let import_paths = list.map(import_sources, fn(s) { s.1 })
  let extra_siblings =
    list.filter(sibling_sources, fn(s) { !list.contains(import_paths, s.1) })
  let external_sources = list.append(import_sources, extra_siblings)
  case analyzer.analyze_multi(source, external_sources) {
    Ok(analysis) -> {
      list.each(analyzer.state_diagnostics(analysis), fn(line) {
        log.info("beacon.build", line)
      })
      list.each(analyzer.client_contract_report(source, analysis), fn(line) {
        log.info("beacon.build", line)
      })
      log.info("beacon.build", analyzer.client_contract_summary(analysis))
      list.each(analysis.msg_variants, fn(v) {
        let label = analyzer.msg_impact_label(analyzer.msg_impact(v))
        log.info("beacon.build", "  " <> v.name <> " → " <> label)
      })

      use Nil <- result_try(analyzer.validate_client_update_purity(source))
      use Nil <- result_try(validate_event_contract(analysis))

      // Generate beacon_codec.gleam — model encoder for state-over-the-wire
      let module_path = extract_module_path(path)
      use Nil <- result_try(write_contract_report(path, module_path, analysis))
      generate_codec_module(module_path, analysis, source)

      case can_build_enhanced_bundle(source, analysis) {
        Ok(True) -> {
          // Build enhanced bundle: view + decode_model compiled to JS
          // Required for state-over-the-wire — client renders view locally
          log.info("beacon.build", "Building enhanced bundle...")
          case build_enhanced_bundle(path, source, analysis) {
            Ok(Nil) -> {
              log.info("beacon.build", "Enhanced bundle ready")
              Ok(Nil)
            }
            Error(reason) -> {
              Error(
                "Enhanced build FAILED: "
                <> reason
                <> " — no client JS will be produced. Fix the build error above.",
              )
            }
          }
        }
        Ok(False) -> Error(unsupported_client_bundle_shape_message())
        Error(reason) -> Error(reason)
      }
    }
    Error(reason) -> Error("Analysis failed: " <> reason)
  }
}

fn result_try(
  result: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> Error(reason)
  }
}

/// Analyze the app module: find it, resolve imports, run analyzer.
/// Shared helper for generate_codec() and try_enhanced_bundle().
/// Resolves external sources two ways:
/// 1. Import-based: follows `import` statements from the primary file
/// 2. Sibling scan: reads all .gleam files in the same directory (catches
///    ServerState, Msg, etc. in separate files not imported by the model file)
fn analyze_app(
  dir: String,
) -> Result(#(String, String, analyzer.Analysis), String) {
  case find_app_module(dir) {
    Ok(#(path, source)) -> {
      let base_dir = source_root(path)
      use import_sources <- result_try(resolve_transitive_external_sources(
        source,
        base_dir,
      ))
      // Also scan sibling files in the same directory as the primary file.
      // This catches ServerState/Msg in separate files not imported by model.gleam.
      use sibling_sources <- result_try(resolve_sibling_sources(path))
      // Merge: import sources take priority (they have correct aliases from imports)
      let import_paths = list.map(import_sources, fn(s) { s.1 })
      let extra_siblings =
        list.filter(sibling_sources, fn(s) { !list.contains(import_paths, s.1) })
      let all_external = list.append(import_sources, extra_siblings)
      case analyzer.analyze_multi(source, all_external) {
        Ok(analysis) -> Ok(#(path, source, analysis))
        Error(reason) -> Error("Analysis failed: " <> reason)
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Read all .gleam files in the same directory as the given file path,
/// excluding the file itself. Returns #(alias, module_path, source) triples.
fn resolve_sibling_sources(
  primary_path: String,
) -> Result(List(#(String, String, String)), String) {
  let root_dir = source_root(primary_path)
  let dir = case string.split(primary_path, "/") |> list.reverse {
    [_, ..rest] -> string.join(list.reverse(rest), "/")
    _ -> "."
  }
  let primary_filename = case string.split(primary_path, "/") |> list.last {
    Ok(f) -> f
    Error(_) -> primary_path
  }
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      let resolved =
        list.fold(entries, Ok([]), fn(acc_result, entry) {
          case acc_result {
            Error(reason) -> Error(reason)
            Ok(acc) -> {
              case
                string.ends_with(entry, ".gleam")
                && entry != primary_filename
                && entry != "beacon_codec.gleam"
              {
                True -> {
                  let file_path = dir <> "/" <> entry
                  case simplifile.read(file_path) {
                    Ok(source) -> {
                      // Derive alias from filename: "server_state.gleam" -> "server_state"
                      let alias = string.replace(entry, ".gleam", "")
                      // Preserve the real module path relative to the source root so
                      // generated imports stay valid for nested app directories.
                      let module_path =
                        string.replace(file_path, root_dir <> "/", "")
                        |> string.replace(".gleam", "")
                      Ok([#(alias, module_path, source), ..acc])
                    }
                    Error(err) ->
                      Error(
                        "Failed to read sibling module "
                        <> file_path
                        <> ": "
                        <> string.inspect(err),
                      )
                  }
                }
                False -> Ok(acc)
              }
            }
          }
        })
      case resolved {
        Ok(items) -> Ok(list.reverse(items))
        Error(reason) -> Error(reason)
      }
    }
    Error(err) ->
      Error(
        "Failed to read sibling module directory "
        <> dir
        <> ": "
        <> string.inspect(err),
      )
  }
}

/// Generate beacon_codec.gleam (server-side model encoder).
/// Independent of client JS bundling — just the codec.
pub fn generate_codec() -> Result(Nil, String) {
  case analyze_app("src") {
    Ok(#(path, source, analysis)) -> {
      let module_path = extract_module_path(path)
      generate_codec_module(module_path, analysis, source)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Try to build the required client JS bundle (view + update compiled to JS).
/// Unsupported app shapes return Error so callers can abort startup.
pub fn try_enhanced_bundle() -> Result(Nil, String) {
  case analyze_app("src") {
    Ok(#(path, source, analysis)) -> {
      case can_build_enhanced_bundle(source, analysis) {
        Ok(True) -> build_enhanced_bundle(path, source, analysis)
        Ok(False) -> Error(unsupported_client_bundle_shape_message())
        Error(reason) -> Error(reason)
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Determine whether the app shape supports an enhanced client bundle.
/// Current codegen requires client-visible Model, Msg, and view. For
/// app_with_server, update stays server-only and is intentionally omitted.
pub fn can_build_enhanced_bundle(
  source: String,
  analysis: analyzer.Analysis,
) -> Result(Bool, String) {
  use Nil <- result_try(analyzer.validate_client_update_purity(source))
  use Nil <- result_try(validate_event_contract(analysis))
  case analyzer.extract_client_source(source) {
    Ok(client_source) -> {
      let has_model = string.contains(client_source, "pub type Model")
      let has_msg = !list.is_empty(analysis.msg_variants)
      let has_view = string.contains(client_source, "pub fn view")
      let has_client_update = string.contains(client_source, "pub fn update")
      let update_required = analysis.has_local && !analysis.has_server
      Ok(
        has_model
        && has_msg
        && has_view
        && { !update_required || has_client_update },
      )
    }
    Error(reason) -> Error("Client source extraction failed: " <> reason)
  }
}

fn validate_event_contract(analysis: analyzer.Analysis) -> Result(Nil, String) {
  let unsupported =
    client_event_variants(analysis)
    |> list.flat_map(fn(variant) {
      variant.fields
      |> list.filter_map(fn(field) {
        case event_field_supported(field, analysis) {
          True -> Error(Nil)
          False ->
            Ok(variant.name <> "." <> field.name <> ": " <> field.type_name)
        }
      })
    })
  case unsupported {
    [] -> Ok(Nil)
    fields ->
      Error(
        "Unsupported generated event contract. Beacon no longer decodes events by server-rendering views; every Msg payload must have a generated JSON codec. Unsupported fields: "
        <> string.join(fields, ", "),
      )
  }
}

fn client_event_variants(
  analysis: analyzer.Analysis,
) -> List(analyzer.MsgVariant) {
  case analysis.client_msg_variants {
    [] -> analysis.msg_variants
    variants -> variants
  }
}

fn event_field_supported(
  field: analyzer.TypeField,
  analysis: analyzer.Analysis,
) -> Bool {
  case field.type_name {
    "Msg" if field.module != "" -> True
    "Int" | "Float" | "Bool" | "String" -> True
    "Option" ->
      case field.inner_type {
        "Int" | "Float" | "Bool" | "String" -> True
        inner ->
          case
            find_custom_type(analysis.custom_types, inner, field.inner_module)
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
    "List" ->
      case field.inner_type {
        "Int" | "Float" | "Bool" | "String" -> True
        inner ->
          case
            find_custom_type(analysis.custom_types, inner, field.inner_module)
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
    _ ->
      case find_enum_type(analysis.enum_types, field.type_name, field.module) {
        Ok(_) -> True
        Error(_) ->
          case
            find_custom_type(
              analysis.custom_types,
              field.type_name,
              field.module,
            )
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
  }
}

fn find_external_msg_type(
  analysis: analyzer.Analysis,
  module_name: String,
) -> Result(analyzer.MsgTypeInfo, Nil) {
  list.find(analysis.external_msg_types, fn(msg_type) {
    msg_type.module == module_name
  })
}

fn unsupported_client_bundle_shape_message() -> String {
  "Unsupported app shape for client-state rendering. Beacon requires generated client-visible Model, Msg, update, and view code so SSR is only the first render and live updates are state sync/patch messages. Move those definitions into a supported client-visible module shape or extend the AST/codegen path before starting this app."
}

fn write_contract_report(
  source_path: String,
  module_path: String,
  analysis: analyzer.Analysis,
) -> Result(Nil, String) {
  use Nil <- result_try(case simplifile.create_directory_all("build") {
    Ok(Nil) -> Ok(Nil)
    Error(err) ->
      Error(
        "Failed to create build directory for contract report: "
        <> string.inspect(err),
      )
  })
  let contract =
    json.object([
      #("source", json.string(source_path)),
      #("module", json.string(module_path)),
      #("rendering", json.string("ssr-first-then-client-state")),
      #("model", fields_json(analysis.model_fields)),
      #("local", fields_json(analysis.local_fields)),
      #("server", fields_json(analysis.server_fields)),
      #("has_local", json.bool(analysis.has_local)),
      #("has_server", json.bool(analysis.has_server)),
      #("messages", msg_variants_json(analysis.msg_variants)),
      #("client_messages", msg_variants_json(client_event_variants(analysis))),
      #(
        "external_messages",
        json.array(analysis.external_msg_types, fn(info) {
          json.object([
            #("module", json.string(info.module)),
            #("variants", msg_variants_json(info.variants)),
          ])
        }),
      ),
      #(
        "generated_codecs",
        json.array(
          [
            "encode_model",
            "decode_model",
            "decode_event",
            "encode_msg",
            "render_model",
          ],
          json.string,
        ),
      ),
      #("summary", json.string(analyzer.client_contract_summary(analysis))),
      #("skipped_server_state", json.bool(analysis.has_server)),
    ])
    |> json.to_string
  case simplifile.write("build/beacon_contract.json", contract) {
    Ok(Nil) -> {
      log.info(
        "beacon.build",
        "Generated contract report: build/beacon_contract.json",
      )
      Ok(Nil)
    }
    Error(err) ->
      Error(
        "Failed to write build/beacon_contract.json: " <> string.inspect(err),
      )
  }
}

fn fields_json(fields: List(analyzer.TypeField)) -> json.Json {
  json.array(fields, fn(field) {
    json.object([
      #("name", json.string(field.name)),
      #("type", json.string(field.type_name)),
      #("inner_type", json.string(field.inner_type)),
      #("module", json.string(field.module)),
      #("inner_module", json.string(field.inner_module)),
    ])
  })
}

fn msg_variants_json(variants: List(analyzer.MsgVariant)) -> json.Json {
  json.array(variants, fn(variant) {
    json.object([
      #("name", json.string(variant.name)),
      #("fields", fields_json(variant.fields)),
      #("affects_model", json.bool(variant.affects_model)),
      #("affects_local", json.bool(variant.affects_local)),
      #(
        "impact",
        json.string(analyzer.msg_impact_label(analyzer.msg_impact(variant))),
      ),
    ])
  })
}

/// Create all required directories for the enhanced build.
/// Returns early with an error if any directory creation fails.
fn create_build_directories(dir: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(dir <> "/src/beacon") {
    Error(err) ->
      Error(
        "Failed to create " <> dir <> "/src/beacon: " <> string.inspect(err),
      )
    Ok(Nil) ->
      case simplifile.create_directory_all(dir <> "/src/beacon/template") {
        Error(err) ->
          Error(
            "Failed to create "
            <> dir
            <> "/src/beacon/template: "
            <> string.inspect(err),
          )
        Ok(Nil) ->
          case simplifile.create_directory_all(dir <> "/src/beacon_client") {
            Error(err) ->
              Error(
                "Failed to create "
                <> dir
                <> "/src/beacon_client: "
                <> string.inspect(err),
              )
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

  use client_source <- result_try(case analyzer.extract_client_source(source) {
    Ok(client_source) -> Ok(client_source)
    Error(reason) -> Error("Source extraction failed: " <> reason)
  })
  use Nil <- result_try(delete_path_if_exists(dir))
  use Nil <- result_try(case create_build_directories(dir) {
    Ok(Nil) -> Ok(Nil)
    Error(reason) -> Error("Directory setup failed: " <> reason)
  })

  let toml =
    "name = \"beacon_client_app\"\nversion = \"0.1.0\"\ntarget = \"javascript\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\ngleam_json = \">= 3.1.0 and < 4.0.0\"\n"
  use Nil <- result_try(case simplifile.write(dir <> "/gleam.toml", toml) {
    Ok(Nil) -> Ok(Nil)
    Error(err) -> Error("Failed to write gleam.toml: " <> string.inspect(err))
  })
  use Nil <- result_try(
    case simplifile.write(dir <> "/src/app.gleam", client_source) {
      Ok(Nil) -> Ok(Nil)
      Error(err) -> Error("Failed to write app.gleam: " <> string.inspect(err))
    },
  )

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

  let app_base_dir = source_root(path)
  use import_sources <- result_try(resolve_transitive_external_sources(
    source,
    app_base_dir,
  ))
  use sibling_sources <- result_try(resolve_sibling_sources(path))
  let import_paths = list.map(import_sources, fn(s) { s.1 })
  let extra_siblings =
    list.filter(sibling_sources, fn(s) { !list.contains(import_paths, s.1) })
  let external_sources = list.append(import_sources, extra_siblings)
  use client_sources <- result_try(client_external_sources(external_sources))
  use Nil <- result_try(write_client_external_sources(client_sources, dir))
  use framework_sources <- result_try(resolve_transitive_framework_sources(
    [client_source, ..list.map(client_sources, fn(ext) { ext.2 })],
    beacon_root,
  ))
  list.each(framework_sources, fn(ext) {
    let #(_alias, module_path, _source_text) = ext
    copy_module_source(
      beacon_root <> "/src/" <> module_path <> ".gleam",
      dir <> "/src/" <> module_path <> ".gleam",
    )
  })
  use Nil <- result_try(write_client_log_shim(dir))

  use Nil <- result_try(
    case simplifile.write(dir <> "/src/beacon.gleam", generate_js_beacon()) {
      Ok(Nil) -> Ok(Nil)
      Error(err) ->
        Error("Failed to write beacon.gleam: " <> string.inspect(err))
    },
  )

  let has_client_update = string.contains(client_source, "pub fn update(")
  let entry = generate_entry_point(analysis, source, has_client_update)
  use Nil <- result_try(
    case simplifile.write(dir <> "/src/beacon_app_entry.gleam", entry) {
      Ok(Nil) -> Ok(Nil)
      Error(err) ->
        Error("Failed to write entry point: " <> string.inspect(err))
    },
  )

  case run_program(dir, "gleam", ["build"]) {
    Error(compile_result) -> Error("JS compilation failed:\n" <> compile_result)
    Ok(_compile_result) -> {
      use Nil <- result_try(
        case simplifile.create_directory_all("priv/static") {
          Ok(Nil) -> Ok(Nil)
          Error(err) ->
            Error("Failed to create priv/static: " <> string.inspect(err))
        },
      )
      let entry_js =
        "import { initClientAfterBoot } from './build/dev/javascript/beacon_client_app/beacon_client_ffi.mjs';\nimport * as App from './build/dev/javascript/beacon_client_app/beacon_app_entry.mjs';\nwindow.BeaconApp = App;\ninitClientAfterBoot();\n"
      use Nil <- result_try(
        case simplifile.write(dir <> "/bundle_entry.mjs", entry_js) {
          Ok(Nil) -> Ok(Nil)
          Error(err) ->
            Error("Failed to write bundle entry: " <> string.inspect(err))
        },
      )
      let hash = generate_safe_hash()
      let filename = "beacon_client_" <> hash <> ".js"
      use Nil <- result_try(clean_old_client_bundles("priv/static"))
      case
        run_program(dir, "npx", [
          "esbuild",
          "bundle_entry.mjs",
          "--bundle",
          "--format=iife",
          "--global-name=Beacon",
          "--outfile=../../priv/static/" <> filename,
          "--minify",
        ])
      {
        Error(result) -> Error("esbuild failed:\n" <> result)
        Ok(_result) -> {
          case
            simplifile.write("priv/static/beacon_client.manifest", filename)
          {
            Ok(Nil) -> Ok(Nil)
            Error(err) ->
              Error("Failed to write manifest: " <> string.inspect(err))
          }
        }
      }
    }
  }
}

fn write_client_log_shim(dir: String) -> Result(Nil, String) {
  case simplifile.write(dir <> "/src/beacon/log.gleam", generate_js_log()) {
    Ok(Nil) -> Ok(Nil)
    Error(err) ->
      Error("Failed to write client log shim: " <> string.inspect(err))
  }
}

fn generate_js_log() -> String {
  "/// Client-side logging shim for generated JS bundles.
import gleam/io

pub fn debug(module: String, message: String) -> Nil {
  write(\"DEBUG\", module, message)
}

pub fn info(module: String, message: String) -> Nil {
  write(\"INFO\", module, message)
}

pub fn warning(module: String, message: String) -> Nil {
  write(\"WARN\", module, message)
}

pub fn error(module: String, message: String) -> Nil {
  write(\"ERROR\", module, message)
}

fn write(level: String, module: String, message: String) -> Nil {
  io.println(level <> \" [\" <> module <> \"] \" <> message)
}
"
}

fn client_external_sources(
  external_sources: List(#(String, String, String)),
) -> Result(List(#(String, String, String)), String) {
  case external_sources {
    [] -> Ok([])
    [source, ..rest] -> {
      let #(alias, module_path, source_text) = source
      let client_source = case analyzer.has_server_boundary(source_text) {
        True -> {
          case analyzer.extract_client_source(source_text) {
            Ok(extracted) -> Ok(extracted)
            Error(reason) ->
              Error(
                "Failed to extract client source for "
                <> module_path
                <> ": "
                <> reason,
              )
          }
        }
        False -> Ok(source_text)
      }

      case client_source {
        Error(reason) -> Error(reason)
        Ok(text) -> {
          case client_external_sources(rest) {
            Error(reason) -> Error(reason)
            Ok(rest_sources) ->
              Ok([#(alias, module_path, text), ..rest_sources])
          }
        }
      }
    }
  }
}

fn write_client_external_sources(
  sources: List(#(String, String, String)),
  dir: String,
) -> Result(Nil, String) {
  case sources {
    [] -> Ok(Nil)
    [source, ..rest] -> {
      let #(_alias, module_path, source_text) = source
      case
        write_module_source_text(
          dir <> "/src/" <> module_path <> ".gleam",
          source_text,
        )
      {
        Error(reason) -> Error(reason)
        Ok(Nil) -> write_client_external_sources(rest, dir)
      }
    }
  }
}

fn write_module_source_text(path: String, source: String) -> Result(Nil, String) {
  let target_dir = case string.split(path, "/") |> list.reverse {
    [_, ..rest] ->
      case list.reverse(rest) {
        [] -> ""
        parts -> string.join(parts, "/")
      }
    _ -> ""
  }

  let make_dir = case target_dir {
    "" -> Ok(Nil)
    d -> simplifile.create_directory_all(d)
  }

  case make_dir {
    Error(err) ->
      Error(
        "Failed to create directory for " <> path <> ": " <> string.inspect(err),
      )
    Ok(Nil) -> {
      case simplifile.write(path, source) {
        Ok(Nil) -> Ok(Nil)
        Error(err) ->
          Error("Failed to write " <> path <> ": " <> string.inspect(err))
      }
    }
  }
}

/// Clean stale codec artifacts to prevent type mismatches between apps.
/// Uses simplifile to avoid shell injection risks from rm commands.
fn clean_codec_artifacts() -> Result(Nil, String) {
  let artefacts_dir = "build/dev/erlang/beacon/_gleam_artefacts"
  let artefact_cleanup = case simplifile.is_directory(artefacts_dir) {
    Error(err) ->
      Error(
        "Failed to inspect codec artefacts directory "
        <> artefacts_dir
        <> ": "
        <> string.inspect(err),
      )
    Ok(False) -> Ok(Nil)
    Ok(True) -> {
      case simplifile.get_files(artefacts_dir) {
        Error(err) ->
          Error(
            "Failed to list codec artefacts directory "
            <> artefacts_dir
            <> ": "
            <> string.inspect(err),
          )
        Ok(files) -> {
          let errors =
            list.filter_map(files, fn(f) {
              case string.contains(f, "beacon_codec") {
                False -> Error(Nil)
                True -> {
                  case simplifile.delete(f) {
                    Ok(Nil) -> Error(Nil)
                    Error(err) ->
                      Ok(
                        "Failed to delete codec artifact "
                        <> f
                        <> ": "
                        <> string.inspect(err),
                      )
                  }
                }
              }
            })
          case errors {
            [] -> Ok(Nil)
            [first, ..] -> Error(first)
          }
        }
      }
    }
  }

  case artefact_cleanup {
    Error(reason) -> Error(reason)
    Ok(Nil) -> {
      case
        optional_clean_generated_file(
          "build/dev/erlang/beacon/ebin/beacon_codec.beam",
        )
      {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> Error(reason)
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
          log.error(
            "beacon.build",
            "Failed to write " <> to <> ": " <> string.inspect(err),
          )
      }
    }
    Error(err) ->
      log.warning(
        "beacon.build",
        "Could not copy " <> from <> ": " <> string.inspect(err),
      )
  }
}

fn copy_module_source(from: String, to: String) -> Nil {
  let target_dir = case string.split(to, "/") |> list.reverse {
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
      case simplifile.create_directory_all(d) {
        Ok(Nil) -> Nil
        Error(err) ->
          log.warning(
            "beacon.build",
            "Failed to create directory " <> d <> ": " <> string.inspect(err),
          )
      }
    }
  }
  copy_file(from, to)
}

/// Generate the JS-target beacon.gleam with event helpers using beacon_client/handler.
fn generate_js_beacon() -> String {
  "/// Client-side beacon module — event helpers for JS target.
import beacon/element.{type Attr}
import beacon_client/handler
import gleam/option.{None}

/// A node in the virtual DOM tree.
pub type Node(msg) = element.Node(msg)

pub fn on_click(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"click\", handler_id: id, debounce_ms: None)
}

pub fn on_input(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"input\", handler_id: id, debounce_ms: None)
}

pub fn on_submit(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"submit\", handler_id: id, debounce_ms: None)
}

pub fn on_submit_local(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"submit-local\", handler_id: id, debounce_ms: None)
}

pub fn on_change(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"change\", handler_id: id, debounce_ms: None)
}

pub fn on_mousedown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mousedown\", handler_id: id, debounce_ms: None)
}

pub fn on_mouseup(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mouseup\", handler_id: id, debounce_ms: None)
}

pub fn on_mousemove(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"mousemove\", handler_id: id, debounce_ms: None)
}

pub fn on_keydown(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"keydown\", handler_id: id, debounce_ms: None)
}

pub fn on_dragstart(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"dragstart\", handler_id: id, debounce_ms: None)
}

pub fn on_dragover(msg: msg) -> Attr {
  let id = handler.register_simple(msg)
  element.EventAttr(event_name: \"dragover\", handler_id: id, debounce_ms: None)
}

pub fn on_drop(callback: fn(String) -> msg) -> Attr {
  let id = handler.register_parameterized(callback)
  element.EventAttr(event_name: \"drop\", handler_id: id, debounce_ms: None)
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
              "decode.list(" <> decoder_name(ct.module, ct.name) <> "())"
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
      "    \"" <> string.lowercase(v) <> "\" -> " <> variant_prefix <> "." <> v
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
          case
            find_custom_type(
              analysis.custom_types,
              f.inner_type,
              f.inner_module,
            )
          {
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
    list.map(used_enum_types(analysis), fn(et) { generate_enum_decoder(et) })

  let custom_decoders_code =
    string.join(list.append(custom_decoder_fns, enum_decoder_fns), "\n\n")

  // Generate model decoder
  let decode_fields =
    list.map(analysis.model_fields, fn(f) {
      let decoder =
        decoder_for_field(f, analysis.custom_types, analysis.enum_types)
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
      let default_val = default_client_value_for_field(f, analysis)
      f.name <> ": " <> default_val
    })
  let default_model =
    "app.Model(" <> string.join(default_model_args, ", ") <> ")"

  // Generate external module imports for the entry point
  let entry_ext_imports = generate_external_imports(analysis, source, False)
  let entry_ext_imports_section = case entry_ext_imports {
    "" -> ""
    imports -> imports <> "\n"
  }
  let option_import = case analysis_uses_option(analysis) {
    True -> "import gleam/option\n"
    False -> ""
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
" <> option_import <> entry_ext_imports_section <> "
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
" <> generate_client_encode_msg(analysis) <> "
" <> generate_local_decoder(analysis, source) <> "
"
}

fn analysis_uses_option(analysis: analyzer.Analysis) -> Bool {
  list.any(analysis.model_fields, fn(f) { f.type_name == "Option" })
  || list.any(analysis.local_fields, fn(f) { f.type_name == "Option" })
  || list.any(analysis.msg_variants, fn(v) {
    list.any(v.fields, fn(f) { f.type_name == "Option" })
  })
}

fn default_client_value_for_field(
  field: analyzer.TypeField,
  analysis: analyzer.Analysis,
) -> String {
  case field.type_name {
    "Int" -> "0"
    "Float" -> "0.0"
    "Bool" -> "False"
    "String" -> "\"\""
    "List" -> "[]"
    _ ->
      case find_enum_type(analysis.enum_types, field.type_name, field.module) {
        Ok(enum_type) -> default_client_enum_value(enum_type)
        Error(_) ->
          case
            find_custom_type(
              analysis.custom_types,
              field.type_name,
              field.module,
            )
          {
            Ok(custom_type) ->
              default_client_custom_value(custom_type, analysis)
            Error(_) -> {
              log.warning(
                "beacon.build",
                "Unknown type '"
                  <> field.type_name
                  <> "' for field '"
                  <> field.name
                  <> "' — using string placeholder in init stub",
              )
              "\"\""
            }
          }
      }
  }
}

fn default_client_enum_value(enum_type: analyzer.EnumTypeInfo) -> String {
  let prefix = case enum_type.module {
    "" -> "app"
    mod -> mod
  }
  case enum_type.variants {
    [first, ..] -> prefix <> "." <> first
    [] -> prefix <> ".Unknown"
  }
}

fn default_client_custom_value(
  custom_type: analyzer.CustomTypeInfo,
  analysis: analyzer.Analysis,
) -> String {
  let qualified = qualify_type_client(custom_type.module, custom_type.name)
  let args =
    list.map(custom_type.fields, fn(field) {
      field.name <> ": " <> default_client_value_for_field(field, analysis)
    })
  qualified <> "(" <> string.join(args, ", ") <> ")"
}

/// Generate the client-side encode_model function.
/// For non-Local apps: encode_model(model, _local) encodes only Model fields.
/// For Local apps: encode_model(model, local) encodes both Model and Local fields,
/// matching the server's model_sync JSON format exactly.
fn generate_client_encode_model(
  analysis: analyzer.Analysis,
  _source: String,
) -> String {
  let model_fields = generate_client_encoder_fields(analysis)
  let custom_encoders_code = generate_client_custom_encoders(analysis)
  case analysis.has_local {
    False -> custom_encoders_code <> "
/// Encode model to JSON string for patch diffing.
pub fn encode_model(model: app.Model, _local: Nil) -> String {
  json.object([
" <> model_fields <> "
  ])
  |> json.to_string
}
"
    True -> {
      let local_fields = analysis.local_fields
      // Build local field encoders using the same infrastructure as model fields
      // Need to create a temporary analysis-like context for Local fields
      let local_field_strs =
        generate_field_encoders(local_fields, "local", analysis)
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

/// Generate client-side Msg encoding for the mandatory event contract.
/// The browser resolves the DOM handler locally, encodes the resulting Msg,
/// and the server decodes that JSON instead of re-rendering view handlers.
fn generate_client_encode_msg(analysis: analyzer.Analysis) -> String {
  let nested =
    analysis.external_msg_types
    |> list.map(fn(msg_type) {
      generate_client_msg_encoder_fn(
        "client_encode_msg_" <> msg_type.module,
        msg_type.module,
        msg_type.module <> ".Msg",
        msg_type.variants,
        analysis,
        False,
      )
    })
    |> string.join("\n")
  let top =
    generate_client_msg_encoder_fn(
      "encode_msg",
      "app",
      "app.Msg",
      client_event_variants(analysis),
      analysis,
      uses_client_msg_allowlist(analysis),
    )

  "\n" <> nested <> "\n" <> top <> "\n"
}

fn generate_client_msg_encoder_fn(
  fn_name: String,
  constructor_prefix: String,
  msg_type: String,
  variants: List(analyzer.MsgVariant),
  analysis: analyzer.Analysis,
  add_forbidden_arm: Bool,
) -> String {
  let arms =
    list.map(variants, fn(variant) {
      let args =
        variant.fields
        |> list.index_map(fn(_field, idx) { "arg" <> int.to_string(idx) })
      let pattern = case args {
        [] -> constructor_prefix <> "." <> variant.name
        _ ->
          constructor_prefix
          <> "."
          <> variant.name
          <> "("
          <> string.join(args, ", ")
          <> ")"
      }
      let arg_entries =
        variant.fields
        |> list.index_map(fn(field, idx) {
          let arg_name = "arg" <> int.to_string(idx)
          "      #(\""
          <> arg_name
          <> "\", "
          <> client_event_json_expr(arg_name, field, analysis)
          <> ")"
        })
      let entries =
        list.append(
          ["      #(\"tag\", json.string(\"" <> variant.name <> "\"))"],
          arg_entries,
        )
      "    "
      <> pattern
      <> " -> json.object([\n"
      <> string.join(entries, ",\n")
      <> "\n    ])"
    })
  let all_arms = case add_forbidden_arm {
    True ->
      list.append(arms, [
        "    _ -> json.object([\n      #(\"tag\", json.string(\"__forbidden_client_msg\"))\n    ])",
      ])
    False -> arms
  }

  "pub fn "
  <> fn_name
  <> "(msg: "
  <> msg_type
  <> ") -> String {\n  let payload = case msg {\n"
  <> string.join(all_arms, "\n")
  <> "\n  }\n  json.to_string(payload)\n}\n"
}

fn uses_client_msg_allowlist(analysis: analyzer.Analysis) -> Bool {
  case analysis.client_msg_variants {
    [] -> False
    variants ->
      list.length(variants) != list.length(analysis.msg_variants)
      || list.any(analysis.msg_variants, fn(msg_variant) {
        !list.any(variants, fn(client_variant) {
          client_variant.name == msg_variant.name
        })
      })
  }
}

fn client_event_json_expr(
  value: String,
  field: analyzer.TypeField,
  analysis: analyzer.Analysis,
) -> String {
  case field.type_name {
    "Msg" if field.module != "" ->
      "json.string(client_encode_msg_" <> field.module <> "(" <> value <> "))"
    "Int" -> "json.int(" <> value <> ")"
    "Float" -> "json.float(" <> value <> ")"
    "Bool" -> "json.bool(" <> value <> ")"
    "String" -> "json.string(" <> value <> ")"
    "Option" -> {
      let inner_encoder = case field.inner_type {
        "Int" -> "json.int(v)"
        "Float" -> "json.float(v)"
        "Bool" -> "json.bool(v)"
        "String" -> "json.string(v)"
        inner ->
          case find_enum_type(analysis.enum_types, inner, field.inner_module) {
            Ok(et) ->
              "json.string(client_"
              <> encoder_name(et.module, et.name)
              <> "(v))"
            Error(_) ->
              case
                find_custom_type(
                  analysis.custom_types,
                  inner,
                  field.inner_module,
                )
              {
                Ok(ct) -> "client_" <> encoder_name(ct.module, ct.name) <> "(v)"
                Error(_) -> "json.string(v)"
              }
          }
      }
      "case "
      <> value
      <> " { option.Some(v) -> "
      <> inner_encoder
      <> "\n        option.None -> json.null() }"
    }
    "List" ->
      case field.inner_type {
        "Int" -> "json.array(" <> value <> ", json.int)"
        "Float" -> "json.array(" <> value <> ", json.float)"
        "Bool" -> "json.array(" <> value <> ", json.bool)"
        "String" -> "json.array(" <> value <> ", json.string)"
        inner ->
          case
            find_custom_type(analysis.custom_types, inner, field.inner_module)
          {
            Ok(ct) ->
              "json.array("
              <> value
              <> ", client_"
              <> encoder_name(ct.module, ct.name)
              <> ")"
            Error(_) -> "json.array(" <> value <> ", fn(_) { json.null() })"
          }
      }
    _ ->
      case find_enum_type(analysis.enum_types, field.type_name, field.module) {
        Ok(et) ->
          "json.string(client_"
          <> encoder_name(et.module, et.name)
          <> "("
          <> value
          <> "))"
        Error(_) ->
          case
            find_custom_type(
              analysis.custom_types,
              field.type_name,
              field.module,
            )
          {
            Ok(ct) ->
              "client_"
              <> encoder_name(ct.module, ct.name)
              <> "("
              <> value
              <> ")"
            Error(_) -> "json.string(\"<unsupported>\")"
          }
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
              case
                find_custom_type(analysis.custom_types, inner, f.inner_module)
              {
                Ok(ct) ->
                  "json.array("
                  <> accessor
                  <> ", client_"
                  <> encoder_name(ct.module, ct.name)
                  <> ")"
                Error(_) ->
                  "json.array(" <> accessor <> ", fn(_) { json.null() })"
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
              case
                find_custom_type(analysis.custom_types, f.type_name, f.module)
              {
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
          case
            find_custom_type(
              analysis.custom_types,
              f.inner_type,
              f.inner_module,
            )
          {
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
    list.map(used_enum_types(analysis), fn(et) {
      let qualified = qualify_type_client(et.module, et.name)
      let variant_prefix = case et.module {
        "" -> "app"
        mod -> mod
      }
      let fn_name = "client_" <> encoder_name(et.module, et.name)
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
  _source: String,
) -> String {
  case analysis.has_local {
    False -> ""
    True -> {
      let local_fields = analysis.local_fields
      let decode_fields =
        list.map(local_fields, fn(f) {
          let decoder =
            decoder_for_field(f, analysis.custom_types, analysis.enum_types)
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
pub fn build_base_client() -> Result(Nil, String) {
  let beacon_root = find_beacon_root()
  let dir = "build/beacon_client_base"
  // The beacon_client package has a pre-built JS output tree
  let bc_js = beacon_root <> "/beacon_client/build/dev/javascript"

  // Clean and recreate build directory
  use Nil <- result_try(delete_path_if_exists(dir))
  use Nil <- result_try(case simplifile.create_directory_all(dir) {
    Ok(Nil) -> Ok(Nil)
    Error(err) ->
      Error("Failed to create " <> dir <> ": " <> string.inspect(err))
  })

  // Ensure beacon_client is built (JS target)
  use bc_build_result <- result_try(
    case
      run_program(beacon_root <> "/beacon_client", "gleam", [
        "build",
        "--target",
        "javascript",
      ])
    {
      Ok(output) -> Ok(output)
      Error(reason) -> Error("beacon_client JS build failed:\n" <> reason)
    },
  )
  log.debug("beacon.build", "beacon_client build: " <> bc_build_result)

  // Resolve absolute path for the entry point import
  use abs_bc_path <- result_try(absolute_path(bc_js))

  // Create entry point — just import the client module.
  // It auto-boots via the data-beacon-auto script attribute detection.
  let entry_js =
    "import '" <> abs_bc_path <> "/beacon_client/beacon_client_ffi.mjs';\n"
  case simplifile.write(dir <> "/entry.mjs", entry_js) {
    Error(err) -> Error("Failed to write entry: " <> string.inspect(err))
    Ok(Nil) -> {
      // Create priv/static
      case simplifile.create_directory_all("priv/static") {
        Error(err) ->
          Error("Failed to create priv/static: " <> string.inspect(err))
        Ok(Nil) -> {
          let hash = generate_safe_hash()
          let filename = "beacon_client_" <> hash <> ".js"
          // Clean old bundles before writing new one.
          case clean_old_client_bundles("priv/static") {
            Error(reason) -> Error(reason)
            Ok(Nil) -> {
              case
                run_program(dir, "npx", [
                  "esbuild",
                  "entry.mjs",
                  "--bundle",
                  "--format=iife",
                  "--outfile=../../priv/static/" <> filename,
                  "--minify",
                ])
              {
                Ok(_result) -> {
                  case
                    simplifile.write(
                      "priv/static/beacon_client.manifest",
                      filename,
                    )
                  {
                    Ok(Nil) -> {
                      log.info(
                        "beacon.build",
                        "Base client JS built: " <> filename,
                      )
                      Ok(Nil)
                    }
                    Error(err) ->
                      Error("Failed to write manifest: " <> string.inspect(err))
                  }
                }
                Error(result) ->
                  Error("esbuild failed for base client:\n" <> result)
              }
            }
          }
        }
      }
    }
  }
}

/// Called automatically by beacon.start() when no manifest exists.
pub fn auto_build() -> Result(Nil, String) {
  case find_app_module("src") {
    Ok(#(path, source)) -> {
      log.info("beacon.build", "Found app module: " <> path)
      compile_module(path, source)
    }
    Error(reason) ->
      Error(
        "No app module found in src/: "
        <> reason
        <> " — no client JS will be produced. "
        <> "Ensure your app has pub type Model (for codec-only mode) or pub type Model + pub type Msg + pub fn update + pub fn view in one file (for enhanced bundle).",
      )
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
  case
    list.find(custom_types, fn(ct) { ct.name == name && ct.module == module })
  {
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
  case
    list.find(enum_types, fn(ct) { ct.name == name && ct.module == module })
  {
    Ok(et) -> Ok(et)
    Error(_) ->
      case module {
        "" -> list.find(enum_types, fn(et) { et.name == name })
        _ -> Error(Nil)
      }
  }
}

fn used_enum_types(analysis: analyzer.Analysis) -> List(analyzer.EnumTypeInfo) {
  list.filter(analysis.enum_types, fn(enum_type) {
    list.any(analysis.model_fields, fn(field) {
      field_references_enum(field, enum_type, "")
    })
    || list.any(analysis.local_fields, fn(field) {
      field_references_enum(field, enum_type, "")
    })
    || list.any(analysis.custom_types, fn(custom_type) {
      list.any(custom_type.fields, fn(field) {
        field_references_enum(field, enum_type, custom_type.module)
      })
    })
  })
}

fn field_references_enum(
  field: analyzer.TypeField,
  enum_type: analyzer.EnumTypeInfo,
  owner_module: String,
) -> Bool {
  { field.type_name == enum_type.name && field.module == enum_type.module }
  || {
    field.inner_type == enum_type.name && field.inner_module == enum_type.module
  }
  || {
    field.type_name == enum_type.name
    && field.module == ""
    && owner_module == enum_type.module
  }
  || {
    field.inner_type == enum_type.name
    && field.inner_module == ""
    && owner_module == enum_type.module
  }
}

/// Generate import statements for external modules used in the analysis.
pub fn generate_external_imports(
  analysis: analyzer.Analysis,
  _source: String,
  include_server_fields: Bool,
) -> String {
  let local_fields = analysis.local_fields
  let initial_fields =
    list.append(analysis.model_fields, case include_server_fields {
      True -> list.append(analysis.server_fields, local_fields)
      False -> local_fields
    })

  let modules_from_fields =
    collect_external_modules_from_fields(
      initial_fields,
      analysis.custom_types,
      [],
    )
    |> list.unique

  let modules_with_server = case analysis.has_server, analysis.server_module {
    True, mod if mod != "" ->
      case list.contains(modules_from_fields, mod) {
        True -> modules_from_fields
        False -> [mod, ..modules_from_fields]
      }
    _, _ -> modules_from_fields
  }

  let enum_modules =
    list.filter_map(analysis.enum_types, fn(et) {
      case et.module {
        "" -> Error(Nil)
        mod -> Ok(mod)
      }
    })
    |> list.unique

  let modules_to_import =
    list.unique(list.append(modules_with_server, enum_modules))

  list.filter_map(modules_to_import, fn(alias) {
    case list.find(analysis.imported_modules, fn(im) { im.alias == alias }) {
      Ok(im) -> Ok("import " <> im.module_path <> " as " <> im.alias)
      Error(_) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn collect_external_modules_from_fields(
  fields: List(analyzer.TypeField),
  custom_types: List(analyzer.CustomTypeInfo),
  seen_types: List(String),
) -> List(String) {
  case fields {
    [] -> []
    [field, ..rest] -> {
      let field_aliases =
        collect_external_modules_from_field(field, custom_types, seen_types)
      let rest_aliases =
        collect_external_modules_from_fields(rest, custom_types, seen_types)
      list.unique(list.append(field_aliases, rest_aliases))
    }
  }
}

fn collect_external_modules_from_field(
  field: analyzer.TypeField,
  custom_types: List(analyzer.CustomTypeInfo),
  seen_types: List(String),
) -> List(String) {
  let direct_aliases =
    list.filter_map([field.module, field.inner_module], fn(mod) {
      case mod {
        "" -> Error(Nil)
        _ -> Ok(mod)
      }
    })

  case field.type_name {
    "List" ->
      case
        find_custom_type(custom_types, field.inner_type, field.inner_module)
      {
        Ok(ct) ->
          list.unique(list.append(
            direct_aliases,
            collect_external_modules_from_custom_type(
              ct,
              custom_types,
              seen_types,
            ),
          ))
        Error(_) -> direct_aliases
      }
    "Option" ->
      case
        find_custom_type(custom_types, field.inner_type, field.inner_module)
      {
        Ok(ct) ->
          list.unique(list.append(
            direct_aliases,
            collect_external_modules_from_custom_type(
              ct,
              custom_types,
              seen_types,
            ),
          ))
        Error(_) -> direct_aliases
      }
    _ ->
      case find_custom_type(custom_types, field.type_name, field.module) {
        Ok(ct) ->
          list.unique(list.append(
            direct_aliases,
            collect_external_modules_from_custom_type(
              ct,
              custom_types,
              seen_types,
            ),
          ))
        Error(_) -> direct_aliases
      }
  }
}

fn collect_external_modules_from_custom_type(
  ct: analyzer.CustomTypeInfo,
  custom_types: List(analyzer.CustomTypeInfo),
  seen_types: List(String),
) -> List(String) {
  let key = ct.module <> "|" <> ct.name
  case list.contains(seen_types, key) {
    True -> []
    False -> {
      let next_seen = [key, ..seen_types]
      let nested_aliases =
        collect_external_modules_from_fields(ct.fields, custom_types, next_seen)
      case ct.module {
        "" -> nested_aliases
        mod -> list.unique([mod, ..nested_aliases])
      }
    }
  }
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
    "Option" -> {
      // Option(T) -> case val { Some(v) -> encode(v), None -> json.null() }
      let inner_encoder = case f.inner_type {
        "Int" -> "json.int(v)"
        "Float" -> "json.float(v)"
        "Bool" -> "json.bool(v)"
        "String" -> "json.string(v)"
        inner ->
          case find_enum_type(analysis.enum_types, inner, f.inner_module) {
            Ok(et) ->
              "json.string(" <> encoder_name(et.module, et.name) <> "(v))"
            Error(_) ->
              case
                find_custom_type(analysis.custom_types, inner, f.inner_module)
              {
                Ok(ct) -> encoder_name(ct.module, ct.name) <> "(v)"
                Error(_) -> "json.string(v)"
              }
          }
      }
      "case "
      <> accessor
      <> " { option.Some(v) -> "
      <> inner_encoder
      <> "\n      option.None -> json.null() }"
    }
    "List" ->
      case f.inner_type {
        "Int" -> "json.array(" <> accessor <> ", json.int)"
        "Float" -> "json.array(" <> accessor <> ", json.float)"
        "Bool" -> "json.array(" <> accessor <> ", json.bool)"
        "String" -> "json.array(" <> accessor <> ", json.string)"
        "" -> {
          // Unknown inner type (e.g., tuples, complex generics)
          log.warning(
            "beacon.build",
            "List field '"
              <> f.name
              <> "' has unknown inner type — using string.inspect",
          )
          "json.array("
          <> accessor
          <> ", fn(x) { json.string(gleam_string.inspect(x)) })"
        }
        inner ->
          case find_custom_type(analysis.custom_types, inner, f.inner_module) {
            Ok(ct) ->
              "json.array("
              <> accessor
              <> ", "
              <> encoder_name(ct.module, ct.name)
              <> ")"
            Error(_) -> {
              log.warning(
                "beacon.build",
                "List field '"
                  <> f.name
                  <> "' has unresolved inner type '"
                  <> inner
                  <> "' — using string.inspect",
              )
              "json.array("
              <> accessor
              <> ", fn(x) { json.string(gleam_string.inspect(x)) })"
            }
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
            Ok(ct) -> encoder_name(ct.module, ct.name) <> "(" <> accessor <> ")"
            Error(_) -> {
              log.warning(
                "beacon.build",
                "Unknown type '"
                  <> f.type_name
                  <> "' for field '"
                  <> f.name
                  <> "' — using string.inspect (may not round-trip correctly)",
              )
              "json.string(gleam_string.inspect(" <> accessor <> "))"
            }
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
          case
            find_custom_type(
              analysis.custom_types,
              f.inner_type,
              f.inner_module,
            )
          {
            Ok(ct) -> Ok(generate_type_encoder(module_name, ct, analysis))
            Error(_) -> Error(Nil)
          }
        "Option" ->
          // Option(CustomType) needs an encoder for the inner type
          case
            find_custom_type(
              analysis.custom_types,
              f.inner_type,
              f.inner_module,
            )
          {
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
    list.map(used_enum_types(analysis), fn(et) {
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
      let local_fields = analysis.local_fields
      list.map(local_fields, fn(f) {
        let encoder = generate_server_field_encoder("local", f, analysis)
        "    #(\"" <> f.name <> "\", " <> encoder <> ")"
      })
    }
    False -> []
  }

  // Qualified server type name: uses actual module/type from analysis
  let qualified_server_type = case analysis.server_module {
    "" -> module_name <> "." <> analysis.server_type_name
    mod -> mod <> "." <> analysis.server_type_name
  }

  let #(param_type, model_extract) = case
    analysis.has_local,
    analysis.has_server
  {
    True, _ -> #(
      "#(" <> module_name <> ".Model, " <> module_name <> ".Local)",
      "  let model = state.0\n  let local = state.1\n",
    )
    _, True -> #(
      "#(" <> module_name <> ".Model, " <> qualified_server_type <> ")",
      "  let model = state.0\n",
    )
    False, False -> #(module_name <> ".Model", "  let model = state\n")
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

  let all_field_encoders =
    list.flatten([
      model_field_encoders,
      local_field_encoders,
      computed_field_encoders,
    ])

  // Generate server-side custom type decoders (for decode_model)
  let server_custom_decoders = case analysis.has_server {
    True -> []
    False ->
      list.filter_map(analysis.model_fields, fn(f) {
        case f.type_name {
          "List" ->
            case
              find_custom_type(
                analysis.custom_types,
                f.inner_type,
                f.inner_module,
              )
            {
              Ok(ct) ->
                Ok(generate_server_custom_decoder(
                  module_name,
                  ct,
                  analysis.enum_types,
                ))
              Error(_) -> Error(Nil)
            }
          _ ->
            case
              find_custom_type(analysis.custom_types, f.type_name, f.module)
            {
              Ok(ct) ->
                Ok(generate_server_custom_decoder(
                  module_name,
                  ct,
                  analysis.enum_types,
                ))
              Error(_) -> Error(Nil)
            }
        }
      })
      |> list.unique
  }

  // Generate server-side enum decoders (for decode_model)
  let server_enum_decoders = case analysis.has_server {
    True -> []
    False ->
      list.map(used_enum_types(analysis), fn(et) {
        generate_server_enum_decoder(module_name, et)
      })
  }

  // Generate import statements for external modules
  let ext_imports = generate_external_imports(analysis, source, True)
  let ext_imports_section = case ext_imports {
    "" -> ""
    imports -> imports <> "\n"
  }

  let body =
    string.join(custom_encoders, "\n\n")
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
    <> generate_server_render_model(
      module_name,
      param_type,
      model_extract,
      analysis,
    )
    <> generate_server_decode_model(module_name, analysis, source)
    <> generate_server_decode_event(module_name, analysis)
    <> generate_substate_encoders(module_name, analysis)

  let optional_imports =
    [
      #("decode.", "import gleam/dynamic/decode"),
      #("option.", "import gleam/option"),
      #("gleam_string.", "import gleam/string as gleam_string"),
    ]
    |> list.filter_map(fn(import_) {
      let #(needle, import_line) = import_
      case string.contains(body, needle) {
        True -> Ok(import_line)
        False -> Error(Nil)
      }
    })

  let imports =
    string.join(
      list.append(
        ["import " <> module_path],
        list.append(
          case ext_imports_section {
            "" -> []
            imports -> [string.trim(imports)]
          },
          ["import beacon/element", "import gleam/json", ..optional_imports],
        ),
      ),
      "\n",
    )

  let source_text = "/// AUTO-GENERATED by beacon/build — do not edit manually.
/// Re-run `gleam run -m beacon/build` to regenerate.

" <> imports <> "\n\n" <> body

  case simplifile.write(codec_path, source_text) {
    Ok(Nil) -> log.info("beacon.build", "Generated codec: " <> codec_path)
    Error(err) ->
      log.error(
        "beacon.build",
        "Failed to write codec " <> codec_path <> ": " <> string.inspect(err),
      )
  }
}

fn generate_server_render_model(
  module_name: String,
  param_type: String,
  model_extract: String,
  analysis: analyzer.Analysis,
) -> String {
  let view_call = case analysis.has_local {
    True -> module_name <> ".view(model, local)"
    False -> module_name <> ".view(model)"
  }
  "\n/// Render the model with the same generated server contract used for SSR.\npub fn render_model(state: "
  <> param_type
  <> ") -> String {\n"
  <> model_extract
  <> "  "
  <> view_call
  <> "\n  |> element.to_string\n}\n"
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
      // For Local/Server apps, encoders take the tuple and extract model
      let sub_qualified_server = case analysis.server_module {
        "" -> module_name <> "." <> analysis.server_type_name
        mod -> mod <> "." <> analysis.server_type_name
      }
      let #(param_type, model_extract) = case
        analysis.has_local,
        analysis.has_server
      {
        True, _ -> #(
          "#(" <> module_name <> ".Model, " <> module_name <> ".Local)",
          "  let model = state.0\n",
        )
        _, True -> #(
          "#(" <> module_name <> ".Model, " <> sub_qualified_server <> ")",
          "  let model = state.0\n",
        )
        False, False -> #(module_name <> ".Model", "  let model = state\n")
      }
      let param_name = case analysis.has_local, analysis.has_server {
        _, True -> "state"
        True, _ -> "state"
        False, False -> "state"
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
      let substate_field_names = list.map(substates, fn(s) { s.field_name })
      let flat_fields =
        list.filter(analysis.model_fields, fn(f) {
          !list.contains(substate_field_names, f.name)
        })
      let flat_encoders =
        list.map(flat_fields, fn(f) {
          let encoder = generate_server_field_encoder("model", f, analysis)
          "    #(\"" <> f.name <> "\", " <> encoder <> "),"
        })
      let flat_fn = case flat_encoders {
        [] ->
          "\npub fn encode_flat_fields(_state: "
          <> param_type
          <> ") -> String {\n  json.object([])\n  |> json.to_string\n}\n"
        _ ->
          "\npub fn encode_flat_fields("
          <> param_name
          <> ": "
          <> param_type
          <> ") -> String {\n"
          <> model_extract
          <> "  json.object([\n"
          <> string.join(flat_encoders, "\n")
          <> "\n  ])\n  |> json.to_string\n}\n"
      }

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
  _source: String,
) -> String {
  // Model decoder fields
  let model_decode_fields =
    list.map(analysis.model_fields, fn(f) {
      let decoder =
        server_decoder_for_field(f, analysis.custom_types, analysis.enum_types)
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

  case analysis.has_local, analysis.has_server {
    _, True -> {
      // Server state cannot be reconstructed from client JSON.
      // app_with_server runs all events server-side, so decode_model is not used.
      let decode_server_type = case analysis.server_module {
        "" -> module_name <> "." <> analysis.server_type_name
        mod -> mod <> "." <> analysis.server_type_name
      }
      "\n/// Decode is not supported for app_with_server — Server state cannot be reconstructed from client JSON.\npub fn decode_model(_json_str: String) -> Result(#("
      <> module_name
      <> ".Model, "
      <> decode_server_type
      <> "), String) {\n"
      <> "  Error(\"decode_model not supported for app_with_server\")\n"
      <> "}\n"
    }

    False, False ->
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

    True, _ -> {
      // Also decode Local fields and return the tuple #(Model, Local)
      let local_fields = analysis.local_fields
      let local_decode_fields =
        list.map(local_fields, fn(f) {
          let decoder =
            server_decoder_for_field(
              f,
              analysis.custom_types,
              analysis.enum_types,
            )
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
        _ ->
          module_name
          <> ".Local("
          <> string.join(local_constructor_args, ", ")
          <> ")"
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

fn generate_server_decode_event(
  module_name: String,
  analysis: analyzer.Analysis,
) -> String {
  let nested_decoders =
    analysis.external_msg_types
    |> list.map(fn(msg_type) {
      generate_server_decode_msg_fn(
        "decode_msg_" <> msg_type.module,
        msg_type.module,
        msg_type.module <> ".Msg",
        msg_type.variants,
        analysis,
      )
    })
    |> string.join("\n")
  let top_decoder =
    generate_server_decode_msg_fn(
      "decode_msg",
      module_name,
      module_name <> ".Msg",
      client_event_variants(analysis),
      analysis,
    )

  "\n/// Decode the generated client event contract. Live event decoding never\n/// renders the server view or reads the handler registry.\npub fn decode_event(_name: String, _handler_id: String, data: String, _target_path: String) -> Result("
  <> module_name
  <> ".Msg, String) {\n"
  <> "  let envelope_decoder = {\n"
  <> "    use msg_json <- decode.field(\"__beacon_msg\", decode.string)\n"
  <> "    decode.success(msg_json)\n"
  <> "  }\n"
  <> "  case json.parse(data, envelope_decoder) {\n"
  <> "    Ok(msg_json) -> decode_msg(msg_json)\n"
  <> "    Error(_) -> Error(\"Client event missing generated Beacon message envelope\")\n"
  <> "  }\n"
  <> "}\n\n"
  <> nested_decoders
  <> "\n"
  <> top_decoder
}

fn generate_server_decode_msg_fn(
  fn_name: String,
  constructor_prefix: String,
  msg_type: String,
  variants: List(analyzer.MsgVariant),
  analysis: analyzer.Analysis,
) -> String {
  let arms =
    list.map(variants, fn(variant) {
      let decode_fields =
        variant.fields
        |> list.index_map(fn(field, idx) {
          let arg_name = "arg" <> int.to_string(idx)
          let decoder = server_event_decoder_for_field(field, analysis)
          "      use "
          <> arg_name
          <> " <- decode.field(\""
          <> arg_name
          <> "\", "
          <> decoder
          <> ")"
        })
      let constructor_args =
        variant.fields
        |> list.index_map(fn(field, idx) {
          let arg_name = "arg" <> int.to_string(idx)
          case
            find_enum_type(analysis.enum_types, field.type_name, field.module)
          {
            Ok(et) ->
              "server_"
              <> decoder_name(et.module, et.name)
              <> "_value("
              <> arg_name
              <> ")"
            Error(_) -> arg_name
          }
        })
      let constructor =
        constructor_prefix
        <> "."
        <> variant.name
        <> case constructor_args {
          [] -> ""
          _ -> "(" <> string.join(constructor_args, ", ") <> ")"
        }
      "    \""
      <> variant.name
      <> "\" -> {\n"
      <> "      let msg_decoder = {\n"
      <> string.join(decode_fields, "\n")
      <> case decode_fields {
        [] -> ""
        _ -> "\n"
      }
      <> "      decode.success("
      <> constructor
      <> ")\n"
      <> "      }\n"
      <> "      case json.parse(json_str, msg_decoder) {\n"
      <> "        Ok(msg) -> Ok(msg)\n"
      <> "        Error(_) -> Error(\"Generated Beacon message payload did not match tag "
      <> variant.name
      <> "\")\n"
      <> "      }\n"
      <> "    }"
    })

  "fn "
  <> fn_name
  <> "(json_str: String) -> Result("
  <> msg_type
  <> ", String) {\n"
  <> "  let tag_decoder = {\n"
  <> "    use tag <- decode.field(\"tag\", decode.string)\n"
  <> "    decode.success(tag)\n"
  <> "  }\n"
  <> "  case json.parse(json_str, tag_decoder) {\n"
  <> "    Ok(tag) -> {\n"
  <> "      case tag {\n"
  <> string.join(arms, "\n")
  <> "\n"
  <> "        _ -> Error(\"Unknown generated Beacon message tag \" <> tag)\n"
  <> "      }\n"
  <> "    }\n"
  <> "    Error(_) -> Error(\"Generated Beacon message payload missing tag\")\n"
  <> "  }\n"
  <> "}\n"
}

fn server_event_decoder_for_field(
  field: analyzer.TypeField,
  analysis: analyzer.Analysis,
) -> String {
  case field.type_name {
    "Msg" if field.module != "" -> {
      let placeholder = default_msg_value(field.module, analysis)
      "decode.then(decode.string, fn(raw) {\n"
      <> "        case decode_msg_"
      <> field.module
      <> "(raw) {\n"
      <> "          Ok(msg) -> decode.success(msg)\n"
      <> "          Error(reason) -> decode.failure("
      <> placeholder
      <> ", reason)\n"
      <> "        }\n"
      <> "      })"
    }
    _ ->
      server_decoder_for_field(
        field,
        analysis.custom_types,
        analysis.enum_types,
      )
  }
}

fn default_msg_value(module_name: String, analysis: analyzer.Analysis) -> String {
  case find_external_msg_type(analysis, module_name) {
    Ok(info) ->
      case info.variants {
        [variant, ..] ->
          module_name
          <> "."
          <> variant.name
          <> case variant.fields {
            [] -> ""
            fields ->
              "("
              <> string.join(
                list.map(fields, fn(field) {
                  default_event_value(field, analysis)
                }),
                ", ",
              )
              <> ")"
          }
        [] -> module_name <> ".Msg"
      }
    Error(_) -> module_name <> ".Msg"
  }
}

fn default_event_value(
  field: analyzer.TypeField,
  analysis: analyzer.Analysis,
) -> String {
  case field.type_name {
    "Int" -> "0"
    "Float" -> "0.0"
    "Bool" -> "False"
    "String" -> "\"\""
    "List" -> "[]"
    "Option" -> "option.None"
    "Msg" if field.module != "" -> default_msg_value(field.module, analysis)
    _ ->
      case find_enum_type(analysis.enum_types, field.type_name, field.module) {
        Ok(et) -> default_client_enum_value(et)
        Error(_) -> "\"\""
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
    "Option" ->
      case field.inner_type {
        "Int" -> "decode.optional(decode.int)"
        "Float" -> "decode.optional(decode.float)"
        "Bool" -> "decode.optional(decode.bool)"
        "String" -> "decode.optional(decode.string)"
        inner ->
          case find_custom_type(custom_types, inner, field.inner_module) {
            Ok(ct) ->
              "decode.optional(server_"
              <> decoder_name(ct.module, ct.name)
              <> "())"
            Error(_) -> "decode.optional(decode.string)"
          }
      }
    "List" ->
      case field.inner_type {
        "Int" -> "decode.list(decode.int)"
        "Float" -> "decode.list(decode.float)"
        "Bool" -> "decode.list(decode.bool)"
        "String" -> "decode.list(decode.string)"
        inner ->
          case find_custom_type(custom_types, inner, field.inner_module) {
            Ok(ct) ->
              "decode.list(server_" <> decoder_name(ct.module, ct.name) <> "())"
            Error(_) -> "decode.list(decode.dynamic)"
          }
      }
    _ ->
      case find_enum_type(enum_types, field.type_name, field.module) {
        Ok(_) -> "decode.string"
        Error(_) ->
          case find_custom_type(custom_types, field.type_name, field.module) {
            Ok(ct) -> "server_" <> decoder_name(ct.module, ct.name) <> "()"
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
        "Option" ->
          case f.inner_type {
            "Int" -> "decode.optional(decode.int)"
            "Float" -> "decode.optional(decode.float)"
            "Bool" -> "decode.optional(decode.bool)"
            _ -> "decode.optional(decode.string)"
          }
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
      "    \"" <> string.lowercase(v) <> "\" -> " <> variant_prefix <> "." <> v
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
      // Reuse the same encoder logic as top-level Model fields
      let encoder = generate_server_field_encoder("s", f, analysis)
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
        case string.contains(line, "beacon") && string.contains(line, "path") {
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
  // Two-pass search:
  // 1. Entrypoint app module: full app module that actually starts Beacon.
  // 2. Full app module: update + view + Model + Msg in one file.
  // 3. Model-only module: pub type Model in any file (app_with_server, multi-file)
  //    The codec only needs Model fields — the analyzer handles cross-file resolution.
  let all_files = collect_gleam_files(dir)
  let entrypoint_match =
    list.find(all_files, fn(pair) {
      let #(_path, source) = pair
      is_full_app_source(source) && is_beacon_entrypoint_source(source)
    })
  case entrypoint_match {
    Ok(found) -> Ok(found)
    Error(Nil) -> {
      let full_match =
        list.find(all_files, fn(pair) {
          let #(_path, source) = pair
          is_full_app_source(source)
        })
      case full_match {
        Ok(found) -> Ok(found)
        Error(Nil) -> {
          // Pass 3: file with pub type Model (codec-only — enough for encode_model)
          let model_match =
            list.find(all_files, fn(pair) {
              let #(_path, source) = pair
              string.contains(source, "pub type Model")
            })
          case model_match {
            Ok(found) -> {
              log.info(
                "beacon.build",
                "Found Model type (codec-only mode) in: " <> { found.0 },
              )
              Ok(found)
            }
            Error(Nil) -> Error("No module found with pub type Model")
          }
        }
      }
    }
  }
}

fn is_full_app_source(source: String) -> Bool {
  let has_update =
    string.contains(source, "pub fn update")
    || string.contains(source, "pub fn make_update")
  let has_view = string.contains(source, "pub fn view")
  let has_model = string.contains(source, "pub type Model")
  let has_msg = string.contains(source, "pub type Msg")
  has_update && has_view && has_model && has_msg
}

fn is_beacon_entrypoint_source(source: String) -> Bool {
  string.contains(source, "beacon.app(")
  || string.contains(source, "beacon.app_with")
  || string.contains(source, "beacon.start(")
}

/// Recursively collect all .gleam files in a directory, skipping beacon/.
fn collect_gleam_files(dir: String) -> List(#(String, String)) {
  case simplifile.read_directory(dir) {
    Ok(entries) ->
      list.flat_map(entries, fn(entry) {
        let path = dir <> "/" <> entry
        case simplifile.is_directory(path) {
          Ok(True) ->
            case entry {
              "beacon" -> []
              _ -> collect_gleam_files(path)
            }
          _ ->
            case
              string.ends_with(entry, ".gleam") && entry != "beacon_codec.gleam"
            {
              True ->
                case simplifile.read(path) {
                  Ok(source) -> [#(path, source)]
                  Error(err) -> {
                    log.error(
                      "beacon.build",
                      "Failed to read " <> path <> ": " <> string.inspect(err),
                    )
                    []
                  }
                }
              False -> []
            }
        }
      })
    Error(err) -> {
      log.warning(
        "beacon.build",
        "Failed to read directory: "
          <> dir
          <> " ("
          <> string.inspect(err)
          <> ")",
      )
      []
    }
  }
}

/// Run `gleam build` to compile newly generated source files (e.g., beacon_codec.gleam).
/// Returns the build output.
pub fn run_gleam_build() -> String {
  case run_program(".", "gleam", ["build"]) {
    Ok(output) -> output
    Error(reason) -> reason
  }
}

/// Validate that a string contains only hexadecimal characters (0-9, a-f, A-F).
/// Used to sanitize shell command interpolation of hash outputs.
fn is_hex_string(s: String) -> Bool {
  s
  |> string.to_graphemes()
  |> list.all(fn(c) {
    case c {
      "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
      "a" | "b" | "c" | "d" | "e" | "f" -> True
      "A" | "B" | "C" | "D" | "E" | "F" -> True
      _ -> False
    }
  })
}

/// Generate a safe hash string for cache-busting filenames.
/// Returns a validated hex string.
fn generate_safe_hash() -> String {
  let raw = string.trim(do_generate_safe_hash())
  // Supported build hosts produce a non-empty hexadecimal digest here.
  let assert True = is_hex_string(raw) && raw != ""
  raw
}

@external(erlang, "beacon_codegen_ffi", "get_args")
fn get_args() -> List(String)

@external(erlang, "beacon_build_ffi", "run_program")
fn run_program(
  cwd: String,
  program: String,
  args: List(String),
) -> Result(String, String)

@external(erlang, "beacon_build_ffi", "absolute_path")
fn absolute_path(path: String) -> Result(String, String)

@external(erlang, "beacon_build_ffi", "generate_safe_hash")
fn do_generate_safe_hash() -> String

/// Return True when any provided source path is newer than the manifest.
///
/// Directories are checked recursively for source files. Missing manifests or
/// unreadable source paths are stale, forcing the normal build path to run and
/// report the real build error instead of serving an old bundle.
@external(erlang, "beacon_build_ffi", "is_any_source_newer_than")
pub fn is_any_source_newer_than(
  manifest_path: String,
  source_paths: List(String),
) -> Bool

/// Return True when the app's local client bundle manifest is missing or older
/// than one of the provided source paths. The FFI also checks Beacon's client
/// runtime source when it is available from the current checkout.
@external(erlang, "beacon_build_ffi", "is_any_source_newer_than_manifest")
pub fn is_any_source_newer_than_manifest(source_paths: List(String)) -> Bool
