/// Auth helpers — login, logout, session-bound authentication.
/// Works with the session store and middleware context.

import beacon/log
import beacon/middleware
import beacon/session
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{None, Some}
import beacon/transport/server.{type Connection, type ResponseBody, Bytes}

/// Log in a user — creates a session and stores the user ID.
pub fn login(
  store: session.SessionStore,
  user_id: String,
) -> session.Session {
  let sess = session.create(store)
  let sess = session.set(store, sess, "user_id", user_id)
  log.info("beacon.auth", "User logged in: " <> user_id)
  sess
}

/// Log out — destroys the session.
pub fn logout(store: session.SessionStore, session_id: String) -> Nil {
  session.delete(store, session_id)
  log.info("beacon.auth", "Session logged out: " <> session_id)
}

/// Get the current user ID from a session.
pub fn current_user(sess: session.Session) -> Result(String, Nil) {
  case session.get_value(sess, "user_id") {
    Some(user_id) -> Ok(user_id)
    None -> Error(Nil)
  }
}

/// Auth middleware — rejects unauthenticated requests with 401.
/// Checks for a session cookie and validates it against the store.
pub fn require_auth(
  store: session.SessionStore,
) -> middleware.Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    let cookie_header = request.get_header(req, "cookie")
    let session_id = case cookie_header {
      Ok(cookies) -> extract_session_cookie(cookies)
      Error(Nil) -> None
    }
    case session_id {
      Some(id) -> {
        case session.get(store, id) {
          Some(sess) -> {
            case current_user(sess) {
              Ok(_user_id) -> next(req)
              Error(Nil) -> unauthorized_response()
            }
          }
          None -> unauthorized_response()
        }
      }
      None -> unauthorized_response()
    }
  }
}

/// CSRF middleware — validates CSRF token on state-changing requests.
/// Allows GET, HEAD, OPTIONS. Requires valid token on POST, PUT, DELETE, PATCH.
pub fn csrf_protection(
  store: session.SessionStore,
) -> middleware.Middleware {
  fn(
    req: Request(Connection),
    next: fn(Request(Connection)) -> Response(ResponseBody),
  ) -> Response(ResponseBody) {
    case req.method {
      http.Get | http.Head | http.Options -> next(req)
      _ -> {
        // For state-changing requests, validate CSRF token
        let csrf_header = request.get_header(req, "x-csrf-token")
        let cookie_header = request.get_header(req, "cookie")
        let session_id = case cookie_header {
          Ok(cookies) -> extract_session_cookie(cookies)
          Error(Nil) -> None
        }
        case csrf_header, session_id {
          Ok(token), Some(sid) -> {
            case session.get(store, sid) {
              Some(sess) -> {
                case session.get_value(sess, "csrf_token") {
                  Some(stored_token) if stored_token == token -> next(req)
                  _ -> forbidden_response("Invalid CSRF token")
                }
              }
              None -> forbidden_response("Invalid session")
            }
          }
          _, _ -> forbidden_response("Missing CSRF token")
        }
      }
    }
  }
}

/// Extract session ID from cookie header.
fn extract_session_cookie(cookies: String) -> option.Option(String) {
  extract_cookie_value(cookies, "beacon_session")
}

/// Parse a cookie header and extract a specific cookie value.
fn extract_cookie_value(
  header: String,
  name: String,
) -> option.Option(String) {
  let target = name <> "="
  case find_cookie(header, target) {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

@external(erlang, "beacon_auth_ffi", "find_cookie")
fn find_cookie(header: String, target: String) -> Result(String, Nil)

fn unauthorized_response() -> Response(ResponseBody) {
  response.new(401)
  |> response.set_body(
    Bytes(bytes_tree.from_string("Unauthorized")),
  )
}

fn forbidden_response(reason: String) -> Response(ResponseBody) {
  response.new(403)
  |> response.set_body(
    Bytes(bytes_tree.from_string("Forbidden: " <> reason)),
  )
}
