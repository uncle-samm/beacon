/// Beacon's Server-Side Rendering module.
/// Implements LiveView's "dead render" pattern: on HTTP GET, render the full
/// HTML page with the initial view, inject the client JS, and embed a signed
/// session token for state recovery on WebSocket connect.
///
/// Reference: LiveView two-phase mount (dead render → live mount),
/// Leptos SSR modes.

import beacon/effect.{type Effect}
import beacon/element.{type Node}
import beacon/log
import beacon/route
import gleam/option.{type Option, None, Some}
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/http/response.{type Response}
import gleam/json
import gleam/string
import beacon/transport/server.{type ResponseBody, Bytes}
import simplifile

/// Configuration for server-side rendering.
pub type SsrConfig(model, msg) {
  SsrConfig(
    /// Initialize the model (same as RuntimeConfig.init).
    init: fn() -> #(model, Effect(msg)),
    /// The view function (same as RuntimeConfig.view).
    view: fn(model) -> Node(msg),
    /// Secret key for signing session tokens.
    secret_key: String,
    /// Application title for the HTML page.
    title: String,
  )
}

/// A rendered page ready to be sent as an HTTP response.
pub type RenderedPage {
  RenderedPage(
    /// The full HTML string including doctype, head, body, scripts.
    html: String,
    /// The signed session token embedded in the page.
    session_token: String,
  )
}

/// Render the initial page for an HTTP request.
/// This is the "dead render" — produces full HTML without WebSocket.
///
/// Steps (following LiveView's pattern):
/// 1. Run init() to get the initial model
/// 2. Call view(model) to get the Element tree
/// 3. Render Element tree to HTML string
/// 4. Sign a session token containing model identity info
/// 5. Wrap in full HTML document with JS client injected
pub fn render_page(config: SsrConfig(model, msg)) -> RenderedPage {
  log.debug("beacon.ssr", "Rendering dead page")

  // Step 1: Initialize model
  let #(model, _initial_effects) = config.init()
  // Note: initial effects are NOT executed during dead render.
  // They will run when the WebSocket connects (live mount).
  // This matches LiveView's behavior: expensive data loading
  // can be deferred to the live mount phase.

  // Step 2: Render view
  let view_tree = config.view(model)
  let view_html = element.to_string(view_tree)

  // Step 3: Create session token
  let token = create_session_token(config.secret_key)

  // Step 4: Build full HTML document
  let html = build_html_document(config.title, view_html, token)

  log.debug("beacon.ssr", "Dead render complete")
  RenderedPage(html: html, session_token: token)
}

/// Render a page for a specific URL path (route-aware SSR).
/// Runs init, then dispatches on_route_change if routes are configured.
/// This ensures each URL gets route-specific SSR HTML.
pub fn render_page_for_path(
  config: SsrConfig(model, msg),
  path: String,
  route_patterns: List(route.RoutePattern),
  on_route_change: Option(fn(route.Route) -> msg),
  update: fn(model, msg) -> #(model, Effect(msg)),
) -> RenderedPage {
  log.debug("beacon.ssr", "Rendering for path: " <> path)

  // Step 1: Initialize model
  let #(model, _effects) = config.init()

  // Step 2: Apply route change if configured
  let model = case on_route_change {
    Some(make_msg) -> {
      let matched_route = case route.match_path(route_patterns, path) {
        Some(r) -> r
        None -> route.from_path(path)
      }
      let msg = make_msg(matched_route)
      let #(new_model, _effects) = update(model, msg)
      new_model
    }
    None -> model
  }

  // Step 3: Render view with route-specific model
  let view_tree = config.view(model)
  let view_html = element.to_string(view_tree)

  // Step 4: Create session token
  let token = create_session_token(config.secret_key)

  // Step 5: Build HTML
  let html = build_html_document(config.title, view_html, token)

  log.debug("beacon.ssr", "Route-aware render complete for: " <> path)
  RenderedPage(html: html, session_token: token)
}

/// Convert a RenderedPage to an HTTP response.
pub fn to_response(page: RenderedPage) -> Response(ResponseBody) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(Bytes(bytes_tree.from_string(page.html)))
}

/// Create a signed session token.
/// The token contains a timestamp for expiration checking.
/// Reference: LiveView signs session tokens with Phoenix.Token.
pub fn create_session_token(secret_key: String) -> String {
  let timestamp = erlang_system_time_seconds()
  let payload =
    json.object([
      #("ts", json.int(timestamp)),
      #("v", json.int(1)),
    ])
    |> json.to_string
  let secret = bit_array.from_string(secret_key)
  let message = bit_array.from_string(payload)
  crypto.sign_message(message, secret, crypto.Sha256)
}

/// Maximum token lifetime: 24 hours. Any max_age_seconds above this is capped.
/// Prevents misconfiguration from creating long-lived tokens.
const max_token_lifetime_seconds = 86_400

/// Verify a session token and extract the payload.
/// Returns Ok(timestamp) if valid, Error otherwise.
/// max_age_seconds is capped at 24 hours (86400s) to prevent long-lived tokens.
pub fn verify_session_token(
  token: String,
  secret_key: String,
  max_age_seconds: Int,
) -> Result(Int, String) {
  // Cap the max age to prevent misconfigured long-lived tokens
  let capped_max_age = case max_age_seconds > max_token_lifetime_seconds {
    True -> max_token_lifetime_seconds
    False -> max_age_seconds
  }
  let secret = bit_array.from_string(secret_key)
  case crypto.verify_signed_message(token, secret) {
    Ok(payload_bits) -> {
      case bit_array.to_string(payload_bits) {
        Ok(payload_str) -> {
          case parse_token_payload(payload_str) {
            Ok(timestamp) -> {
              let now = erlang_system_time_seconds()
              let age = now - timestamp
              case age > capped_max_age {
                True -> Error("Session token expired")
                False -> Ok(timestamp)
              }
            }
            Error(reason) -> Error(reason)
          }
        }
        Error(Nil) -> Error("Invalid token payload encoding")
      }
    }
    Error(Nil) -> Error("Invalid or tampered session token")
  }
}

/// Parse the token JSON payload to extract the timestamp.
fn parse_token_payload(payload_str: String) -> Result(Int, String) {
  let decoder = {
    use ts <- decode.field("ts", decode.int)
    decode.success(ts)
  }
  case json.parse(payload_str, decoder) {
    Ok(ts) -> Ok(ts)
    Error(_) -> Error("Failed to parse token payload")
  }
}

/// Build a full HTML document with the view, JS client, and session token.
fn build_html_document(
  title: String,
  view_html: String,
  session_token: String,
) -> String {
  string.concat([
    "<!DOCTYPE html>",
    "<html><head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>",
    escape_html(title),
    "</title>",
    "<style>",
    "body{font-family:system-ui,sans-serif;max-width:600px;margin:2rem auto}",
    "button{font-size:1.5rem;padding:.5rem 1.5rem;margin:.25rem;cursor:pointer}",
    ".counter{text-align:center}",
    "</style>",
    "</head><body>",
    // TODO: The session token is embedded in a data attribute, which is readable
    // by any JS on the page (XSS risk). The proper fix is to use an HTTP-only cookie
    // for the session token, which requires refactoring the WebSocket join flow.
    // Mitigations: token has a short max_age (capped at 24h), is cryptographically
    // signed, and CSP restricts script sources to 'self'.
    "<div id=\"beacon-app\" data-beacon-token=\"",
    session_token,
    "\">",
    view_html,
    "</div>",
    "<script src=\"/",
    client_js_filename(),
    "\" data-beacon-auto></script>",
    "</body></html>",
  ])
}

/// Get the current client JS filename from the build manifest.
/// The manifest is created by `gleam run -m beacon/build`.
fn client_js_filename() -> String {
  case simplifile.read("priv/static/beacon_client.manifest") {
    Ok(name) -> string.trim(name)
    Error(err) -> {
      log.error(
        "beacon.ssr",
        "FATAL: No beacon_client.manifest: "
          <> string.inspect(err)
          <> " — client JS not built. Run `gleam run -m beacon/build`.",
      )
      "MISSING_CLIENT_JS_RUN_BEACON_BUILD"
    }
  }
}

/// Escape HTML special characters in text content.
fn escape_html(text: String) -> String {
  text
  |> do_replace("&", "&amp;")
  |> do_replace("<", "&lt;")
  |> do_replace(">", "&gt;")
  |> do_replace("\"", "&quot;")
}

@external(erlang, "beacon_element_ffi", "string_replace")
fn do_replace(subject: String, pattern: String, replacement: String) -> String

@external(erlang, "beacon_ssr_ffi", "system_time_seconds")
fn erlang_system_time_seconds() -> Int

import gleam/dynamic/decode
