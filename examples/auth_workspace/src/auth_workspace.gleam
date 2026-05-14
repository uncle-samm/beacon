import auth_workspace/app
import beacon
import beacon/api
import beacon/auth
import beacon/effect
import beacon/route
import beacon/session
import beacon/transport/server.{type Connection, type ResponseBody}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn main() {
  let store = session.new_store("auth_workspace_sessions")
  let auth_config = auth.dev_session_config()

  beacon.app_with_server(app.init, app.init_server, update, app.view)
  |> beacon.title("Auth Workspace")
  |> beacon.secret_key("auth-workspace-session-secret-key-32-chars")
  |> beacon.route_pages(auth_pages())
  |> beacon.api_routes(api_handler(store, auth_config))
  |> beacon.ws_auth(auth.protect_ws(store, auth_config))
  |> beacon.ws_init(init_from_request(store, auth_config))
  |> beacon.dev_mode(True)
  |> beacon.start(8080)
}

fn auth_pages() -> List(route.Page(#(app.Model, app.Server), app.Msg)) {
  [
    auth_page("/"),
    auth_page("/login"),
    auth_page("/app"),
    auth_page("/settings"),
    auth_page("/admin"),
  ]
}

fn auth_page(pattern: String) -> route.Page(#(app.Model, app.Server), app.Msg) {
  route.page(
    pattern,
    fn(r: route.Route) { app.RouteChanged(r.path) },
    fn(state: #(app.Model, app.Server), _route) {
      let #(model, _server) = state
      app.view(model)
    },
  )
}

fn update(
  model: app.Model,
  server: app.Server,
  msg: app.Msg,
) -> #(app.Model, app.Server, effect.Effect(app.Msg)) {
  case msg {
    app.RefreshSession -> {
      let audit_count = list.length(server.audit_entries)
      #(
        app.Model(
          ..model,
          status: "Session "
            <> server.session_id
            <> " has "
            <> int.to_string(audit_count)
            <> " private audit entries",
        ),
        app.Server(..server, audit_entries: [
          "refresh-session",
          ..server.audit_entries
        ]),
        effect.none(),
      )
    }
    app.AdminAudit -> {
      case model.role == "admin" {
        True -> #(
          app.update(model, msg),
          app.Server(..server, audit_entries: [
            "admin-audit",
            ..server.audit_entries
          ]),
          effect.none(),
        )
        False -> #(
          app.update(model, msg),
          app.Server(
            ..server,
            denied_admin_events: server.denied_admin_events + 1,
          ),
          effect.none(),
        )
      }
    }
    _ -> #(app.update(model, msg), server, effect.none())
  }
}

fn api_handler(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(Request(Connection)) -> Option(response.Response(ResponseBody)) {
  api.routes([
    api.post("/api/login", fn(req) { handle_login(req, store, config) }),
    api.get("/api/me", auth.protect_api(store, config, handle_me)),
    api.post(
      "/api/profile",
      auth.protect_api_with_csrf(store, config, fn(req, sess, user_id) {
        handle_profile(req, store, sess, user_id)
      }),
    ),
    api.post(
      "/api/logout",
      auth.protect_api_with_csrf(store, config, fn(_req, sess, _user_id) {
        auth.logout_response(store, sess, api.text(200, "Logged out"), config)
      }),
    ),
  ])
}

fn handle_login(
  req: Request(Connection),
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> response.Response(ResponseBody) {
  case api.read_form(req, 4096) {
    Ok(fields) -> {
      case api.form_field(fields, "csrf"), api.form_field(fields, "username") {
        Ok(csrf), Ok(username) if csrf == app.login_csrf_token -> {
          let safe_user = normalize_user(username)
          let login = auth.create_login(store, safe_user)
          let sess = login.session
          let sess = session.set(store, sess, "role", role_for_user(safe_user))
          let _sess =
            session.set(
              store,
              sess,
              "display_name",
              display_name_for_user(safe_user),
            )
          api.json_value(
            200,
            json.object([
              #("ok", json.bool(True)),
              #("csrf", json.string(login.csrf_token)),
            ]),
          )
          |> auth.with_session_cookie(sess, config)
        }
        _, _ -> api.text(403, "Invalid login CSRF token")
      }
    }
    Error(reason) -> api.text(400, reason)
  }
}

fn handle_me(
  _req: Request(Connection),
  sess: session.Session,
  user: String,
) -> response.Response(ResponseBody) {
  let role = session_value(sess, "role", "user")
  api.json_value(
    200,
    json.object([
      #("user", json.string(user)),
      #("role", json.string(role)),
    ]),
  )
}

fn handle_profile(
  req: Request(Connection),
  store: session.SessionStore,
  sess: session.Session,
  _user_id: String,
) -> response.Response(ResponseBody) {
  case api.read_form(req, 4096) {
    Error(reason) -> api.text(400, reason)
    Ok(fields) -> {
      case api.form_field(fields, "display_name") {
        Ok(display_name) -> {
          let _sess = session.set(store, sess, "display_name", display_name)
          api.json_value(200, json.object([#("ok", json.bool(True))]))
        }
        Error(reason) -> api.text(400, reason)
      }
    }
  }
}

fn init_from_request(
  store: session.SessionStore,
  config: auth.SessionConfig,
) -> fn(Request(Connection)) -> #(app.Model, app.Server) {
  auth.init_from_session(
    store,
    config,
    fn(req) { #(app.Model(..app.init(), route: req.path), app.init_server()) },
    fn(req, sess, _user_id) {
      let user = session_value(sess, "user_id", "")
      let role = session_value(sess, "role", "user")
      let display_name = session_value(sess, "display_name", user)
      let csrf_token = session_value(sess, "csrf_token", "")
      #(
        app.authenticated_model(req.path, user, role, display_name, csrf_token),
        app.Server(
          session_id: sess.id,
          csrf_token: csrf_token,
          private_audit_key: "server-only-audit-key",
          audit_entries: ["session-restored"],
          denied_admin_events: 0,
        ),
      )
    },
  )
}

fn session_value(sess: session.Session, key: String, default: String) -> String {
  case session.get_value(sess, key) {
    Some(value) -> value
    None -> default
  }
}

fn normalize_user(username: String) -> String {
  case string.trim(username) {
    "" -> "guest"
    user -> user
  }
}

fn role_for_user(username: String) -> String {
  case username {
    "ada" -> "admin"
    _ -> "user"
  }
}

fn display_name_for_user(username: String) -> String {
  case username {
    "ada" -> "Ada Lovelace"
    _ -> username
  }
}
