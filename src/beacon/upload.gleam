/// File upload handling — multipart form data parsing, size limits, type validation.

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

@external(erlang, "beacon_upload_ffi", "write_file")
fn write_file(path: String, data: BitArray) -> Result(Nil, Nil)
