/// Error page rendering for Beacon.
/// Provides styled error pages for common HTTP errors.
///
/// Reference: Phoenix error views, LiveView error handling.

import beacon/element.{type Node}
import gleam/bytes_tree
import gleam/http/response.{type Response}
import gleam/int
import mist

/// Render a 404 Not Found error page.
pub fn not_found() -> Node(msg) {
  error_page(404, "Page Not Found", "The page you're looking for doesn't exist.")
}

/// Render a 500 Internal Server Error page.
pub fn internal_error(detail: String) -> Node(msg) {
  error_page(
    500,
    "Internal Server Error",
    "Something went wrong on our end. " <> detail,
  )
}

/// Render a generic error page with status code, title, and message.
pub fn error_page(
  status: Int,
  title: String,
  message: String,
) -> Node(msg) {
  element.el("div", [element.attr("class", "beacon-error")], [
    element.el("div", [element.attr("class", "beacon-error-content")], [
      element.el("h1", [element.attr("class", "beacon-error-status")], [
        element.text(int.to_string(status)),
      ]),
      element.el("h2", [element.attr("class", "beacon-error-title")], [
        element.text(title),
      ]),
      element.el("p", [element.attr("class", "beacon-error-message")], [
        element.text(message),
      ]),
      element.el("a", [element.attr("href", "/")], [
        element.text("Go back home"),
      ]),
    ]),
  ])
}

/// Render a development-mode error page with detailed error info.
/// Shows the error type, message, and a stack trace.
/// NEVER use this in production — it may expose internal details.
pub fn dev_error(
  error_type: String,
  message: String,
  details: String,
) -> Node(msg) {
  element.el("div", [element.attr("class", "beacon-dev-error")], [
    element.el("h1", [element.attr("style", "color: #e74c3c")], [
      element.text("Error: " <> error_type),
    ]),
    element.el("p", [], [element.text(message)]),
    element.el(
      "pre",
      [element.attr("style", "background:#1e1e1e;color:#ddd;padding:1rem;overflow-x:auto;border-radius:4px")],
      [element.text(details)],
    ),
    element.el("hr", [], []),
    element.el(
      "p",
      [element.attr("style", "color:#888;font-size:0.9em")],
      [element.text("This error page is only shown in development mode.")],
    ),
  ])
}

/// Convert an error page Node to a full HTTP response.
pub fn to_response(
  status: Int,
  page: Node(msg),
) -> Response(mist.ResponseData) {
  let html =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    <> "<title>Error " <> int.to_string(status) <> "</title>"
    <> "<style>"
    <> "body{font-family:system-ui,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#f5f5f5}"
    <> ".beacon-error{text-align:center}"
    <> ".beacon-error-status{font-size:6rem;margin:0;color:#e74c3c}"
    <> ".beacon-error-title{margin:0.5rem 0;color:#333}"
    <> ".beacon-error-message{color:#666;margin:1rem 0}"
    <> "a{color:#3498db;text-decoration:none}"
    <> "</style></head><body>"
    <> element.to_string(page)
    <> "</body></html>"
  response.new(status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}
