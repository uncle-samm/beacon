/// File upload handling — multipart form data parsing, size limits, type validation.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// An uploaded file.
pub type UploadedFile {
  UploadedFile(
    /// Original filename from the client.
    filename: String,
    /// MIME content type (e.g., "image/png").
    content_type: String,
    /// File contents as bytes.
    data: BitArray,
    /// File size in bytes.
    size: Int,
  )
}

/// Upload configuration.
pub type UploadConfig {
  UploadConfig(
    /// Maximum file size in bytes (default 10MB).
    max_size: Int,
    /// Allowed MIME types (empty = allow all).
    allowed_types: List(String),
  )
}

/// Upload validation result.
pub type UploadError {
  /// File exceeds max size.
  FileTooLarge(max: Int, actual: Int)
  /// File type not allowed.
  TypeNotAllowed(content_type: String, allowed: List(String))
  /// No file provided.
  NoFile
  /// Parse error.
  ParseError(reason: String)
}

/// Default upload config: 10MB max, all types allowed.
pub fn default_config() -> UploadConfig {
  UploadConfig(max_size: 10_485_760, allowed_types: [])
}

/// Create config with a specific max size.
pub fn with_max_size(config: UploadConfig, bytes: Int) -> UploadConfig {
  UploadConfig(..config, max_size: bytes)
}

/// Create config with allowed MIME types.
pub fn with_allowed_types(
  config: UploadConfig,
  types: List(String),
) -> UploadConfig {
  UploadConfig(..config, allowed_types: types)
}

/// Validate an uploaded file against the config.
pub fn validate(
  file: UploadedFile,
  config: UploadConfig,
) -> Result(UploadedFile, UploadError) {
  // Check size
  case file.size > config.max_size {
    True -> Error(FileTooLarge(max: config.max_size, actual: file.size))
    False -> {
      // Check type
      case config.allowed_types {
        [] -> Ok(file)
        types -> {
          case list.contains(types, file.content_type) {
            True -> Ok(file)
            False ->
              Error(TypeNotAllowed(
                content_type: file.content_type,
                allowed: types,
              ))
          }
        }
      }
    }
  }
}

/// Save an uploaded file to disk.
pub fn save(file: UploadedFile, directory: String) -> Result(String, String) {
  let safe_name = sanitize_filename(file.filename)
  let path = directory <> "/" <> safe_name
  case write_file(path, file.data) {
    Ok(Nil) -> Ok(path)
    Error(_) -> Error("Failed to save file: " <> path)
  }
}

/// Get the file extension from a filename.
pub fn extension(filename: String) -> Option(String) {
  case string.split(filename, ".") {
    [_] -> None
    parts ->
      case list.last(parts) {
        Ok(ext) -> Some(string.lowercase(ext))
        Error(Nil) -> None
      }
  }
}

/// Format file size for display.
pub fn format_size(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1_048_576 -> int.to_string(b / 1024) <> " KB"
    b -> int.to_string(b / 1_048_576) <> " MB"
  }
}

/// Sanitize a filename — remove directory traversal and special characters.
fn sanitize_filename(name: String) -> String {
  name
  |> string.replace("..", "_")
  |> string.replace("/", "_")
  |> string.replace("\\", "_")
  |> string.replace(" ", "_")
}

/// Parse a multipart/form-data body into a list of uploaded files.
/// Extracts file parts based on Content-Disposition headers.
pub fn parse_multipart(
  body: BitArray,
  content_type: String,
) -> Result(List(UploadedFile), UploadError) {
  case string.contains(content_type, "multipart/form-data") {
    False -> Error(ParseError(reason: "Not multipart/form-data"))
    True -> {
      case extract_boundary(content_type) {
        Ok(boundary) -> {
          let files = parse_parts(body, boundary)
          Ok(files)
        }
        Error(Nil) -> Error(ParseError(reason: "No boundary in content type"))
      }
    }
  }
}

/// Extract the boundary string from a content-type header.
fn extract_boundary(content_type: String) -> Result(String, Nil) {
  case string.split(content_type, "boundary=") {
    [_, boundary_part] -> {
      // Trim any trailing parameters
      let boundary = case string.split(boundary_part, ";") {
        [b, ..] -> string.trim(b)
        _ -> string.trim(boundary_part)
      }
      Ok(boundary)
    }
    _ -> Error(Nil)
  }
}

/// Parse multipart body parts using binary boundary scanning.
/// Does NOT convert to string — preserves binary file data intact.
fn parse_parts(body: BitArray, boundary: String) -> List(UploadedFile) {
  let separator = <<"--":utf8, boundary:utf8>>
  let parts = binary_split(body, separator)
  list.filter_map(parts, fn(part) {
    parse_single_part_binary(part)
  })
}

/// Parse a single multipart part from binary data.
/// Splits headers (text) from body (binary) at the \r\n\r\n boundary.
fn parse_single_part_binary(part: BitArray) -> Result(UploadedFile, Nil) {
  let header_separator = <<"\r\n\r\n":utf8>>
  case binary_split_once(part, header_separator) {
    Ok(#(header_bytes, body_bytes)) -> {
      // Headers are always text — safe to convert to string
      case bit_array.to_string(header_bytes) {
        Ok(headers) -> {
          case
            string.contains(headers, "filename=")
            && string.contains(headers, "Content-Disposition")
          {
            True -> {
              let filename =
                extract_header_value(headers, "filename=\"", "\"")
              let content_type_val =
                extract_header_value(headers, "Content-Type: ", "\r\n")
              // Trim trailing \r\n before the next boundary
              let data = trim_trailing_crlf(body_bytes)
              let size = bit_array_size(data)
              Ok(UploadedFile(
                filename: filename,
                content_type: content_type_val,
                data: data,
                size: size,
              ))
            }
            False -> Error(Nil)
          }
        }
        Error(Nil) -> Error(Nil)
      }
    }
    Error(Nil) -> Error(Nil)
  }
}

/// Extract a value from headers between start and end markers.
fn extract_header_value(
  headers: String,
  start: String,
  end: String,
) -> String {
  case string.split(headers, start) {
    [_, rest] -> {
      case string.split(rest, end) {
        [value, ..] -> value
        _ -> "unknown"
      }
    }
    _ -> "unknown"
  }
}

@external(erlang, "beacon_upload_ffi", "write_file")
fn write_file(path: String, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "beacon_upload_ffi", "binary_split")
fn binary_split(data: BitArray, separator: BitArray) -> List(BitArray)

@external(erlang, "beacon_upload_ffi", "binary_split_once")
fn binary_split_once(
  data: BitArray,
  separator: BitArray,
) -> Result(#(BitArray, BitArray), Nil)

@external(erlang, "beacon_upload_ffi", "trim_trailing_crlf")
fn trim_trailing_crlf(data: BitArray) -> BitArray

@external(erlang, "erlang", "byte_size")
fn bit_array_size(data: BitArray) -> Int
