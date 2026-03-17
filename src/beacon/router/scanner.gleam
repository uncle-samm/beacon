/// Route file scanner — scans a directory for route files and parses them.
/// Follows the Squirrel pattern: scan conventional locations, parse with Glance,
/// extract relevant information.
///
/// Reference: Squirrel (scan SQL files), SvelteKit (scan src/routes/),
/// TanStack Router (generate routeTree).

import beacon/error
import beacon/log
import glance
import gleam/list
import gleam/string
import simplifile

/// A discovered route definition from a source file.
pub type RouteDefinition {
  RouteDefinition(
    /// Path segments for this route (e.g., ["blog", ":slug"]).
    path_segments: List(String),
    /// The module name (e.g., "routes/blog/[slug]").
    module_name: String,
    /// The source file path.
    file_path: String,
    /// Whether the module exports a `loader` function.
    has_loader: Bool,
    /// Whether the module exports an `action` function.
    has_action: Bool,
    /// Whether the module exports a `view` function.
    has_view: Bool,
  )
}

/// Scan a routes directory and return all discovered route definitions.
pub fn scan_routes(
  routes_dir: String,
) -> Result(List(RouteDefinition), error.BeaconError) {
  log.info("beacon.router.scanner", "Scanning routes in: " <> routes_dir)
  case simplifile.is_directory(routes_dir) {
    Ok(True) -> {
      case scan_directory(routes_dir, routes_dir) {
        Ok(routes) -> {
          log.info(
            "beacon.router.scanner",
            "Found " <> int_to_string(list.length(routes)) <> " route(s)",
          )
          Ok(routes)
        }
        Error(err) -> Error(err)
      }
    }
    Ok(False) -> {
      log.warning(
        "beacon.router.scanner",
        "Routes directory not found: " <> routes_dir,
      )
      Ok([])
    }
    Error(file_err) -> {
      log.error(
        "beacon.router.scanner",
        "Cannot access routes directory: " <> routes_dir <> " — " <> string.inspect(file_err),
      )
      Error(error.RouterError(
        reason: "Cannot access routes directory: " <> routes_dir,
      ))
    }
  }
}

/// Recursively scan a directory for .gleam route files.
fn scan_directory(
  dir: String,
  base_dir: String,
) -> Result(List(RouteDefinition), error.BeaconError) {
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      let results =
        list.filter_map(entries, fn(entry) {
          let full_path = dir <> "/" <> entry
          case simplifile.is_directory(full_path) {
            Ok(True) -> {
              // Recurse into subdirectory
              case scan_directory(full_path, base_dir) {
                Ok(sub_routes) -> Ok(sub_routes)
                Error(err) -> {
                  log.warning("beacon.router.scanner", "Skipping " <> full_path <> ": " <> error.to_string(err))
                  Error(Nil)
                }
              }
            }
            Ok(False) -> {
              // Check if it's a .gleam file
              case string.ends_with(entry, ".gleam") {
                True -> {
                  case scan_file(full_path, base_dir) {
                    Ok(route) -> Ok([route])
                    Error(err) -> {
                      log.warning("beacon.router.scanner", "Skipping " <> full_path <> ": " <> error.to_string(err))
                      Error(Nil)
                    }
                  }
                }
                False -> Error(Nil)
              }
            }
            Error(err) -> {
              log.warning("beacon.router.scanner", "Cannot stat " <> full_path <> ": " <> string.inspect(err))
              Error(Nil)
            }
          }
        })
      Ok(list.flatten(results))
    }
    Error(file_err) -> {
      log.error(
        "beacon.router.scanner",
        "Cannot read directory: " <> dir <> " — " <> string.inspect(file_err),
      )
      Error(error.RouterError(reason: "Cannot read directory: " <> dir))
    }
  }
}

/// Scan a single .gleam file and extract route information.
fn scan_file(
  file_path: String,
  base_dir: String,
) -> Result(RouteDefinition, error.BeaconError) {
  log.debug("beacon.router.scanner", "Scanning file: " <> file_path)
  case simplifile.read(file_path) {
    Ok(source) -> {
      case glance.module(source) {
        Ok(module) -> {
          let segments = file_path_to_segments(file_path, base_dir)
          let module_name = file_path_to_module_name(file_path, base_dir)
          let public_fns = extract_public_function_names(module)

          Ok(RouteDefinition(
            path_segments: segments,
            module_name: module_name,
            file_path: file_path,
            has_loader: list.contains(public_fns, "loader"),
            has_action: list.contains(public_fns, "action"),
            has_view: list.contains(public_fns, "view"),
          ))
        }
        Error(parse_err) -> {
          log.error(
            "beacon.router.scanner",
            "Failed to parse " <> file_path <> ": " <> string.inspect(parse_err),
          )
          Error(error.RouterError(
            reason: "Failed to parse route file: " <> file_path,
          ))
        }
      }
    }
    Error(file_err) -> {
      log.error(
        "beacon.router.scanner",
        "Cannot read file: " <> file_path <> " — " <> string.inspect(file_err),
      )
      Error(error.RouterError(reason: "Cannot read file: " <> file_path))
    }
  }
}

/// Extract names of all public functions from a parsed module.
pub fn extract_public_function_names(module: glance.Module) -> List(String) {
  list.filter_map(module.functions, fn(def) {
    let func = def.definition
    case func.publicity {
      glance.Public -> Ok(func.name)
      glance.Private -> Error(Nil)
    }
  })
}

/// Convert a file path relative to the routes directory into URL path segments.
/// e.g., "src/routes/blog/[slug].gleam" with base "src/routes" → ["blog", ":slug"]
/// e.g., "src/routes/index.gleam" with base "src/routes" → []
pub fn file_path_to_segments(
  file_path: String,
  base_dir: String,
) -> List(String) {
  // Remove base_dir prefix and .gleam extension
  let relative = remove_prefix(file_path, base_dir <> "/")
  let without_ext = remove_suffix(relative, ".gleam")

  // Split on "/"
  let parts = string.split(without_ext, "/")

  // Process each part
  let segments =
    list.filter_map(parts, fn(part) {
      case part {
        // "index" is the root of its directory — not a segment
        "index" -> Error(Nil)
        // Dynamic segments: [slug] → :slug
        _ -> Ok(parse_segment(part))
      }
    })

  segments
}

/// Convert a file path to a Gleam module name.
/// e.g., "src/routes/blog/[slug].gleam" → "routes/blog/[slug]"
pub fn file_path_to_module_name(
  file_path: String,
  base_dir: String,
) -> String {
  let relative = remove_prefix(file_path, base_dir <> "/")
  remove_suffix(relative, ".gleam")
}

/// Parse a path segment, converting [param] to :param.
pub fn parse_segment(segment: String) -> String {
  case string.starts_with(segment, "["), string.ends_with(segment, "]") {
    True, True -> {
      // Dynamic segment: [slug] → :slug
      let inner =
        segment
        |> remove_prefix("[")
        |> remove_suffix("]")
      ":" <> inner
    }
    _, _ -> segment
  }
}

// --- String helpers ---

fn remove_prefix(s: String, prefix: String) -> String {
  case string.starts_with(s, prefix) {
    True -> string.drop_start(s, string.length(prefix))
    False -> s
  }
}

fn remove_suffix(s: String, suffix: String) -> String {
  case string.ends_with(s, suffix) {
    True -> string.drop_end(s, string.length(suffix))
    False -> s
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String
