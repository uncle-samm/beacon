import beacon/upload
import gleam/option.{None, Some}

fn test_file() -> upload.UploadedFile {
  upload.UploadedFile(
    filename: "test.png",
    content_type: "image/png",
    data: <<0, 1, 2, 3, 4>>,
    size: 5,
  )
}

pub fn validate_ok_test() {
  let config = upload.default_config()
  let assert Ok(_) = upload.validate(test_file(), config)
}

pub fn validate_too_large_test() {
  let config = upload.default_config() |> upload.with_max_size(3)
  let assert Error(upload.FileTooLarge(max: 3, actual: 5)) =
    upload.validate(test_file(), config)
}

pub fn validate_type_allowed_test() {
  let config =
    upload.default_config()
    |> upload.with_allowed_types(["image/png", "image/jpeg"])
  let assert Ok(_) = upload.validate(test_file(), config)
}

pub fn validate_type_not_allowed_test() {
  let config =
    upload.default_config()
    |> upload.with_allowed_types(["application/pdf"])
  let assert Error(upload.TypeNotAllowed(..)) =
    upload.validate(test_file(), config)
}

pub fn extension_test() {
  let assert Some("png") = upload.extension("photo.png")
  let assert Some("jpg") = upload.extension("my.photo.jpg")
  let assert None = upload.extension("noext")
}

pub fn format_size_test() {
  let assert "500 B" = upload.format_size(500)
  let assert "1 KB" = upload.format_size(1024)
  let assert "5 MB" = upload.format_size(5_242_880)
}

pub fn save_file_test() {
  // Create temp directory
  let dir = "/tmp/beacon_upload_test"
  let _ = make_dir(dir)
  let file = test_file()
  let assert Ok(path) = upload.save(file, dir)
  let assert True = path == dir <> "/test.png"
  // Clean up
  let _ = delete_file(path)
}

pub fn sanitize_traversal_test() {
  let file = upload.UploadedFile(
    filename: "../../../etc/passwd",
    content_type: "text/plain",
    data: <<>>,
    size: 0,
  )
  let dir = "/tmp/beacon_upload_test"
  let _ = make_dir(dir)
  let assert Ok(path) = upload.save(file, dir)
  // Should NOT contain ".." — sanitized to underscores
  let assert True = !contains(path, "..")
}

fn make_dir(path: String) -> Result(Nil, Nil) {
  do_make_dir(path)
}

@external(erlang, "beacon_test_ffi", "ensure_dir")
fn do_make_dir(path: String) -> Result(Nil, Nil)

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Result(Nil, Nil)

fn contains(haystack: String, needle: String) -> Bool {
  case do_contains(haystack, needle) {
    True -> True
    False -> False
  }
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_contains(haystack: String, needle: String) -> Bool
