import beacon
import beacon/html
import gleam/int
import gleam/list

pub const login_csrf_token = "auth-workspace-login-csrf"

const server_audit_key = "auth_workspace_server_audit_key_must_not_ship"

pub type Model {
  Model(
    route: String,
    authenticated: Bool,
    user: String,
    role: String,
    display_name: String,
    csrf_token: String,
    status: String,
    saved_profiles: Int,
    admin_events: Int,
  )
}

pub type Server {
  Server(
    session_id: String,
    csrf_token: String,
    private_audit_key: String,
    audit_entries: List(String),
    denied_admin_events: Int,
  )
}

pub type Msg {
  RouteChanged(String)
  SetDisplayName(String)
  SaveProfile
  RefreshSession
  AdminAudit
}

pub fn init() -> Model {
  Model(
    route: "/login",
    authenticated: False,
    user: "",
    role: "",
    display_name: "",
    csrf_token: "",
    status: "Sign in to open the workspace",
    saved_profiles: 0,
    admin_events: 0,
  )
}

pub fn init_server() -> Server {
  Server(
    session_id: "",
    csrf_token: "",
    private_audit_key: server_audit_key,
    audit_entries: [],
    denied_admin_events: 0,
  )
}

pub fn authenticated_model(
  route: String,
  user: String,
  role: String,
  display_name: String,
  csrf_token: String,
) -> Model {
  Model(
    route: route,
    authenticated: True,
    user: user,
    role: role,
    display_name: display_name,
    csrf_token: csrf_token,
    status: "Session loaded for " <> user,
    saved_profiles: 0,
    admin_events: 0,
  )
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    RouteChanged(path) -> Model(..model, route: normalize_route(path))
    SetDisplayName(name) -> Model(..model, display_name: name)
    SaveProfile ->
      Model(
        ..model,
        saved_profiles: model.saved_profiles + 1,
        status: "Profile saved for " <> model.display_name,
      )
    RefreshSession ->
      Model(..model, status: "Session refreshed for " <> model.user)
    AdminAudit ->
      case model.role == "admin" {
        True ->
          Model(
            ..model,
            admin_events: model.admin_events + 1,
            status: "Admin audit event recorded",
          )
        False -> Model(..model, status: "Admin action denied")
      }
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.main(
    [
      html.style(
        "font-family:system-ui;max-width:860px;margin:32px auto;padding:0 16px;line-height:1.45;",
      ),
      html.attribute("data-testid", "auth-root"),
    ],
    [
      html.h1([], [html.text("Auth Workspace")]),
      case model.authenticated {
        False -> login_view(model)
        True -> workspace_view(model)
      },
    ],
  )
}

fn login_view(model: Model) -> beacon.Node(Msg) {
  html.section(
    [
      html.attribute("data-testid", "login-panel"),
      html.style("border:1px solid #d0d7de;border-radius:6px;padding:16px;"),
    ],
    [
      html.h2([], [html.text("Sign in")]),
      html.p([html.attribute("data-testid", "auth-status")], [
        html.text(model.status),
      ]),
      html.form(
        [
          html.attribute("method", "post"),
          html.attribute("action", "/api/login"),
          html.style("display:grid;gap:10px;max-width:360px;"),
        ],
        [
          html.input([
            html.type_("hidden"),
            html.name("csrf"),
            html.value(login_csrf_token),
          ]),
          html.label([], [html.text("Username")]),
          html.input([
            html.name("username"),
            html.value("ada"),
            html.attribute("data-testid", "login-username"),
          ]),
          html.button([html.type_("submit")], [html.text("Sign in")]),
        ],
      ),
    ],
  )
}

fn workspace_view(model: Model) -> beacon.Node(Msg) {
  html.div([], [
    nav_view(model),
    html.p([html.attribute("data-testid", "auth-status")], [
      html.text(model.status),
    ]),
    case model.route {
      "/admin" -> admin_view(model)
      "/settings" -> settings_view(model)
      "/app" | "/" -> app_view(model)
      _ -> not_found_view(model)
    },
  ])
}

fn nav_view(model: Model) -> beacon.Node(Msg) {
  html.nav(
    [
      html.style("display:flex;gap:12px;align-items:center;margin:16px 0;"),
      html.attribute("data-testid", "auth-nav"),
    ],
    [
      html.a([html.href("/app")], [html.text("App")]),
      html.a([html.href("/settings")], [html.text("Settings")]),
      html.a([html.href("/admin")], [html.text("Admin")]),
      html.span([], [html.text(model.user <> " (" <> model.role <> ")")]),
    ],
  )
}

fn app_view(model: Model) -> beacon.Node(Msg) {
  html.section(
    [html.attribute("data-testid", "workspace-home")],
    [
      html.h2([], [html.text("Workspace")]),
      html.p([], [html.text("Welcome, " <> model.display_name)]),
      html.p([], [
        html.text(
          "Profiles saved: " <> int.to_string(model.saved_profiles),
        ),
      ]),
      html.button([beacon.on_click(RefreshSession)], [
        html.text("Refresh session summary"),
      ]),
    ],
  )
}

fn settings_view(model: Model) -> beacon.Node(Msg) {
  html.section(
    [html.attribute("data-testid", "settings-panel")],
    [
      html.h2([], [html.text("Settings")]),
      html.label([], [html.text("Display name")]),
      html.input([
        html.value(model.display_name),
        beacon.on_input(fn(value) { SetDisplayName(value) }),
        html.attribute("data-testid", "display-name-input"),
      ]),
      html.button([beacon.on_click(SaveProfile)], [
        html.text("Save profile"),
      ]),
      html.p([], [
        html.text("CSRF token is available to API clients, not as a session cookie."),
      ]),
    ],
  )
}

fn admin_view(model: Model) -> beacon.Node(Msg) {
  case model.role == "admin" {
    False ->
      html.section([html.attribute("data-testid", "admin-denied")], [
        html.h2([], [html.text("Forbidden")]),
        html.p([], [html.text("This route requires the admin role.")]),
      ])
    True ->
      html.section([html.attribute("data-testid", "admin-panel")], [
        html.h2([], [html.text("Admin")]),
        html.p([], [
          html.text("Audit events: " <> int.to_string(model.admin_events)),
        ]),
        html.button([beacon.on_click(AdminAudit)], [
          html.text("Record audit event"),
        ]),
      ])
  }
}

fn not_found_view(_model: Model) -> beacon.Node(Msg) {
  html.section([html.attribute("data-testid", "not-found")], [
    html.h2([], [html.text("Not found")]),
    html.p([], [html.text("The requested workspace route does not exist.")]),
  ])
}

fn normalize_route(path: String) -> String {
  case list.contains(["/", "/app", "/login", "/settings", "/admin"], path) {
    True -> path
    False -> "/missing"
  }
}
