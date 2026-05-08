import beacon
import beacon/effect
import beacon/html
import gleam/int
import gleam/list

const server_signing_key = "beacon_private_session_signing_key_must_not_ship"

pub type Model {
  Model(
    user: String,
    public_balance: Int,
    approved_actions: Int,
    last_public_event: String,
  )
}

pub type Server {
  Server(signing_key: String, audit_entries: List(String), denied_attempts: Int)
}

pub type Msg {
  ApproveTransfer
  DenyTransfer
  RefreshPublicSummary
}

pub fn init() -> Model {
  Model(
    user: "Ada",
    public_balance: 1200,
    approved_actions: 0,
    last_public_event: "Session opened",
  )
}

pub fn init_server() -> Server {
  Server(
    signing_key: server_signing_key,
    audit_entries: ["session-created"],
    denied_attempts: 0,
  )
}

pub fn update(
  model: Model,
  server: Server,
  msg: Msg,
) -> #(Model, Server, effect.Effect(Msg)) {
  case msg {
    ApproveTransfer -> {
      let audit =
        "approved-transfer-" <> int.to_string(model.approved_actions + 1)
      #(
        Model(
          ..model,
          public_balance: model.public_balance - 25,
          approved_actions: model.approved_actions + 1,
          last_public_event: "Transfer approved",
        ),
        Server(..server, audit_entries: [audit, ..server.audit_entries]),
        effect.none(),
      )
    }

    DenyTransfer -> #(
      Model(..model, last_public_event: "Transfer denied"),
      Server(..server, denied_attempts: server.denied_attempts + 1),
      effect.none(),
    )

    RefreshPublicSummary -> #(
      Model(
        ..model,
        last_public_event: "Public summary refreshed after "
          <> int.to_string(list.length(server.audit_entries))
          <> " audited server events",
      ),
      server,
      effect.none(),
    )
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.main(
    [
      html.style(
        "font-family:system-ui;max-width:760px;margin:32px auto;padding:0 16px;",
      ),
    ],
    [
      html.h1([], [html.text("Private Session")]),
      html.section(
        [
          html.style(
            "border:1px solid #d0d7de;border-radius:6px;padding:16px;margin-bottom:16px;",
          ),
        ],
        [
          html.h2([], [html.text("Public account")]),
          html.p([html.attribute("data-testid", "session-user")], [
            html.text("User: " <> model.user),
          ]),
          html.p([html.attribute("data-testid", "session-balance")], [
            html.text(
              "Visible balance: " <> int.to_string(model.public_balance),
            ),
          ]),
          html.p([html.attribute("data-testid", "session-approved-actions")], [
            html.text(
              "Approved actions: " <> int.to_string(model.approved_actions),
            ),
          ]),
          html.p([html.attribute("data-testid", "session-last-event")], [
            html.text(model.last_public_event),
          ]),
        ],
      ),
      html.section([html.style("display:flex;gap:8px;flex-wrap:wrap;")], [
        html.button([beacon.on_click(ApproveTransfer)], [
          html.text("Approve transfer"),
        ]),
        html.button([beacon.on_click(DenyTransfer)], [
          html.text("Deny transfer"),
        ]),
        html.button([beacon.on_click(RefreshPublicSummary)], [
          html.text("Refresh public summary"),
        ]),
      ]),
      html.p(
        [
          html.attribute("data-testid", "privacy-assertion"),
          html.style("color:#57606a;"),
        ],
        [
          html.text(
            "The signing key and audit entries are server-only and are not available to view.",
          ),
        ],
      ),
    ],
  )
}

pub fn main() {
  beacon.app_with_server(init, init_server, update, view)
  |> beacon.title("Private Session")
  |> beacon.start(8080)
}
