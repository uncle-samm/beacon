/// Static file serving — serves files from a directory with proper MIME types,
/// cache headers, and directory traversal prevention.
///
/// Reference: Phoenix static serving, Mist file responses.

import beacon/log
import gleam/bytes_tree
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/string
import mist
import simplifile

/// Configuration for static file serving.
pub type StaticConfig {
  StaticConfig(
    /// Directory to serve files from (e.g., "priv/static").
    directory: String,
    /// URL path prefix (e.g., "/static").
    prefix: String,
    /// Cache-Control max-age in seconds (0 = no cache).
    max_age: Int,
  )
}

/// Default static config.
pub fn default_config() -> StaticConfig {
  StaticConfig(
    directory: "priv/static",
    prefix: "/static",
    max_age: 3600,
  )
}

/// Try to serve a static file for the given path.
/// Returns Ok(Response) if a file was found and served,
/// Error(Nil) if the path doesn't match the static prefix.
/// Supports If-None-Match for 304 Not Modified responses.
pub fn serve(
  config: StaticConfig,
  path: String,
) -> Result(Response(mist.ResponseData), Nil) {
  serve_with_etag_check(config, path, "")
}

/// Serve a static file with ETag/If-None-Match support.
/// If `if_none_match` matches the file's ETag, returns 304.
pub fn serve_with_etag_check(
  config: StaticConfig,
  path: String,
  if_none_match: String,
) -> Result(Response(mist.ResponseData), Nil) {
  // Check if path starts with the prefix
  case string.starts_with(path, config.prefix) {
    False -> Error(Nil)
    True -> {
      let relative = string.drop_start(path, string.length(config.prefix))
      // Security: reject directory traversal attempts
      case contains_traversal(relative) {
        True -> {
          log.warning(
            "beacon.static",
            "Directory traversal attempt blocked: " <> path,
          )
          Ok(
            response.new(403)
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string("Forbidden")),
            ),
          )
        }
        False -> {
          let file_path = config.directory <> relative
          serve_file(file_path, config.max_age, if_none_match)
        }
      }
    }
  }
}

/// Serve a single file from the filesystem.
/// If `if_none_match` matches the file's ETag, returns 304 Not Modified.
fn serve_file(
  path: String,
  max_age: Int,
  if_none_match: String,
) -> Result(Response(mist.ResponseData), Nil) {
  case simplifile.read_bits(path) {
    Ok(contents) -> {
      let mime = mime_type(path)
      let size = bit_array_size(contents)
      let etag = "\"" <> int.to_string(size) <> "\""
      let cache_control = case max_age {
        0 -> "no-cache"
        _ -> "public, max-age=" <> int.to_string(max_age)
      }
      // Check If-None-Match for 304
      case if_none_match == etag {
        True -> {
          log.debug("beacon.static", "304 Not Modified: " <> path)
          Ok(
            response.new(304)
            |> response.set_header("etag", etag)
            |> response.set_header("cache-control", cache_control)
            |> response.set_body(mist.Bytes(bytes_tree.new())),
          )
        }
        False -> {
          log.debug(
            "beacon.static",
            "Serving: " <> path <> " (" <> mime <> ")",
          )
          Ok(
            response.new(200)
            |> response.set_header("content-type", mime)
            |> response.set_header("cache-control", cache_control)
            |> response.set_header("etag", etag)
            |> response.set_body(
              mist.Bytes(bytes_tree.from_bit_array(contents)),
            ),
          )
        }
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Check if a path contains directory traversal sequences.
pub fn contains_traversal(path: String) -> Bool {
  string.contains(path, "..")
  || string.contains(path, "\\")
}

/// Determine MIME type from file extension.
pub fn mime_type(path: String) -> String {
  let ext = file_extension(path)
  case ext {
    "html" | "htm" -> "text/html; charset=utf-8"
    "css" -> "text/css; charset=utf-8"
    "js" | "mjs" -> "application/javascript; charset=utf-8"
    "json" -> "application/json; charset=utf-8"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "svg" -> "image/svg+xml"
    "ico" -> "image/x-icon"
    "webp" -> "image/webp"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "txt" -> "text/plain; charset=utf-8"
    "xml" -> "application/xml"
    "pdf" -> "application/pdf"
    "zip" -> "application/zip"
    "wasm" -> "application/wasm"
    _ -> "application/octet-stream"
  }
}

/// Extract file extension from a path.
fn file_extension(path: String) -> String {
  case string.split(path, ".") {
    [] -> ""
    parts -> {
      case list.last(parts) {
        Ok(ext) -> string.lowercase(ext)
        Error(Nil) -> ""
      }
    }
  }
}

/// Generate a fingerprinted filename for cache busting.
/// "app.js" with content hash → "app-abc123.js"
pub fn fingerprint(path: String, contents: BitArray) -> String {
  let hash = int.to_string(bit_array_size(contents))
  let ext = file_extension(path)
  let base = case string.split(path, "." <> ext) {
    [name, ..] -> name
    _ -> path
  }
  base <> "-" <> hash <> "." <> ext
}

/// Serve static files with immutable cache (for fingerprinted assets).
/// Fingerprinted assets can be cached forever since the URL changes on content change.
pub fn serve_immutable(
  config: StaticConfig,
  path: String,
) -> Result(Response(mist.ResponseData), Nil) {
  let immutable_config = StaticConfig(..config, max_age: 31_536_000)
  serve_with_etag_check(immutable_config, path, "")
}

@external(erlang, "erlang", "byte_size")
fn bit_array_size(bits: BitArray) -> Int
