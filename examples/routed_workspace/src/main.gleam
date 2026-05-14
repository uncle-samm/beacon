import beacon
import beacon/effect
import beacon/html
import beacon/log
import beacon/route
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list

pub type Model {
  Model(
    path: String,
    open_tickets: Int,
    deploys: Int,
    incidents: Int,
    cards: List(Card),
    next_id: Int,
    display_name: String,
    role: String,
    saved_version: Int,
  )
}

pub type Card {
  Card(id: Int, title: String, lane: String)
}

pub type Local {
  Local(
    inspector_open: Bool,
    selected_tab: String,
    draft: String,
    filter: String,
    compact: Bool,
    draft_name: String,
    draft_role: String,
    menu_open: Bool,
  )
}

pub type Msg {
  RouteChanged(String)
  ToggleInspector
  SelectTab(String)
  ShipDeploy
  ResolveIncident
  SetDraft(String)
  SetFilter(String)
  ToggleCompact
  AddCard(String)
  Advance(Int)
  SetDraftName(String)
  SetDraftRole(String)
  ToggleMenu
  SaveProfile(String)
}

pub fn init() -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      path: "/",
      open_tickets: 7,
      deploys: 3,
      incidents: 1,
      cards: [
        Card(id: 1, title: "Add browser conformance checks", lane: "doing"),
        Card(id: 2, title: "Verify server-private state", lane: "todo"),
        Card(id: 3, title: "Document native browser workflow", lane: "done"),
      ],
      next_id: 4,
      display_name: "Ada",
      role: "owner",
      saved_version: 1,
    ),
    effect.none(),
  )
}

pub fn init_local(model: Model) -> Local {
  Local(
    inspector_open: False,
    selected_tab: "health",
    draft: "",
    filter: "all",
    compact: False,
    draft_name: model.display_name,
    draft_role: model.role,
    menu_open: False,
  )
}

pub fn update(
  model: Model,
  local: Local,
  _server: Nil,
  msg: Msg,
) -> #(Model, Local, Nil) {
  let #(model, local) = case msg {
    RouteChanged(path) -> #(Model(..model, path: path), local)
    ToggleInspector -> #(
      model,
      Local(..local, inspector_open: !local.inspector_open),
    )
    SelectTab(tab) -> #(model, Local(..local, selected_tab: tab))
    ShipDeploy -> #(Model(..model, deploys: model.deploys + 1), local)
    ResolveIncident -> {
      let incidents = case model.incidents > 0 {
        True -> model.incidents - 1
        False -> 0
      }
      #(Model(..model, incidents: incidents), local)
    }
    SetDraft(text) -> #(model, Local(..local, draft: text))
    SetFilter(filter) -> #(model, Local(..local, filter: filter))
    ToggleCompact -> #(model, Local(..local, compact: !local.compact))
    AddCard(fields_json) -> {
      let title = case form_field(fields_json, "card_title") {
        Ok(value) -> value
        Error(reason) -> {
          log.warning("routed_workspace", "Invalid card submit: " <> reason)
          ""
        }
      }
      case title == "" {
        True -> #(model, local)
        False -> {
          let card = Card(id: model.next_id, title: title, lane: "todo")
          #(
            Model(
              ..model,
              cards: [card, ..model.cards],
              next_id: model.next_id + 1,
            ),
            Local(..local, draft: ""),
          )
        }
      }
    }
    Advance(id) -> #(
      Model(..model, cards: list.map(model.cards, advance_card(_, id))),
      local,
    )
    SetDraftName(name) -> #(model, Local(..local, draft_name: name))
    SetDraftRole(role) -> #(model, Local(..local, draft_role: role))
    ToggleMenu -> #(model, Local(..local, menu_open: !local.menu_open))
    SaveProfile(fields_json) -> {
      case
        form_field(fields_json, "display_name"),
        form_field(fields_json, "role")
      {
        Ok(name), Ok(role) -> #(
          Model(
            ..model,
            display_name: name,
            role: role,
            saved_version: model.saved_version + 1,
          ),
          local,
        )
        Error(reason), _ | _, Error(reason) -> {
          log.warning("routed_workspace", "Invalid profile submit: " <> reason)
          #(model, local)
        }
      }
    }
  }
  #(model, local, Nil)
}

fn advance_card(card: Card, id: Int) -> Card {
  case card.id == id {
    False -> card
    True -> {
      let next_lane = case card.lane {
        "todo" -> "doing"
        "doing" -> "done"
        _ -> "done"
      }
      Card(..card, lane: next_lane)
    }
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  // Invariant: `model.path` is initialized to "/" and later updated only from
  // `route_pages()` entries through RouteChanged.
  let assert Ok(page) =
    route.dispatch_view(pages(), #(model, local, Nil), model.path)
  page
}

fn overview_view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div([], [
    html.section(
      [
        html.style(
          "display:grid;gap:12px;grid-template-columns:repeat(3,minmax(0,1fr));",
        ),
      ],
      [
        metric("Open tickets", int.to_string(model.open_tickets)),
        metric("Deploys today", int.to_string(model.deploys)),
        metric("Active incidents", int.to_string(model.incidents)),
      ],
    ),
    html.section(
      [html.style("margin-top:20px;display:flex;gap:8px;flex-wrap:wrap;")],
      [
        html.button([beacon.on_click(ShipDeploy)], [html.text("Ship deploy")]),
        html.button([beacon.on_click(ResolveIncident)], [
          html.text("Resolve incident"),
        ]),
        html.button([beacon.on_click(ToggleInspector)], [
          html.text("Toggle inspector"),
        ]),
      ],
    ),
    html.section([html.style("margin-top:20px;")], [
      html.div([html.style("display:flex;gap:8px;margin-bottom:12px;")], [
        tab_button("health", local.selected_tab),
        tab_button("activity", local.selected_tab),
        tab_button("risks", local.selected_tab),
      ]),
      html.p([html.attribute("data-testid", "selected-tab")], [
        html.text("Selected tab: " <> local.selected_tab),
      ]),
      case local.inspector_open {
        True ->
          html.div(
            [
              html.attribute("data-testid", "local-inspector"),
              html.style(
                "border:1px solid #d0d7de;padding:12px;border-radius:6px;",
              ),
            ],
            [
              html.strong([], [html.text("Inspector")]),
              html.p([], [
                html.text(
                  "Local UI state should change without WebSocket traffic.",
                ),
              ]),
            ],
          )
        False ->
          html.span(
            [html.attribute("data-testid", "local-inspector-closed")],
            [],
          )
      },
    ]),
  ])
}

fn pipeline_view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div([], [
    html.form(
      [
        beacon.on_submit_local(AddCard),
        html.style(
          "display:flex;gap:8px;align-items:center;margin-bottom:16px;",
        ),
      ],
      [
        html.input([
          html.type_("text"),
          html.value(local.draft),
          html.attribute("name", "card_title"),
          html.placeholder("New card title"),
          beacon.on_input(SetDraft),
          html.attribute("data-testid", "card-draft"),
        ]),
        html.button([html.type_("submit")], [html.text("Add card")]),
      ],
    ),
    html.div(
      [
        html.style(
          "display:flex;gap:8px;align-items:center;margin-bottom:16px;",
        ),
      ],
      [
        html.select(
          [
            beacon.on_change(SetFilter),
            html.attribute("data-testid", "lane-filter"),
          ],
          [
            option("all", local.filter, "All lanes"),
            option("todo", local.filter, "Todo"),
            option("doing", local.filter, "Doing"),
            option("done", local.filter, "Done"),
          ],
        ),
        html.button([beacon.on_click(ToggleCompact)], [
          html.text(case local.compact {
            True -> "Comfortable"
            False -> "Compact"
          }),
        ]),
        html.span([html.attribute("data-testid", "pipeline-local-state")], [
          html.text(
            "Filter: "
            <> local.filter
            <> " / compact: "
            <> bool_text(local.compact),
          ),
        ]),
      ],
    ),
    html.section(
      [
        html.style(
          "display:grid;gap:12px;grid-template-columns:repeat(3,minmax(0,1fr));",
        ),
      ],
      [
        lane("todo", model.cards, local),
        lane("doing", model.cards, local),
        lane("done", model.cards, local),
      ],
    ),
  ])
}

fn settings_view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.div([], [
    html.form(
      [
        beacon.on_submit_local(SaveProfile),
        html.style("display:grid;gap:12px;max-width:460px;"),
      ],
      [
        html.label([], [
          html.text("Display name"),
          html.input([
            html.type_("text"),
            html.value(local.draft_name),
            html.attribute("name", "display_name"),
            beacon.on_input(SetDraftName),
            html.attribute("data-testid", "draft-name"),
          ]),
        ]),
        html.label([], [
          html.text("Role"),
          html.select(
            [
              beacon.on_change(SetDraftRole),
              html.attribute("data-testid", "draft-role"),
              html.attribute("name", "role"),
            ],
            [
              option("owner", local.draft_role, "Owner"),
              option("operator", local.draft_role, "Operator"),
              option("viewer", local.draft_role, "Viewer"),
            ],
          ),
        ]),
        html.div([html.style("display:flex;gap:8px;")], [
          html.button([html.type_("submit")], [html.text("Save profile")]),
          html.button([html.type_("button"), beacon.on_click(ToggleMenu)], [
            html.text("Toggle menu"),
          ]),
        ]),
      ],
    ),
    html.section(
      [
        html.style(
          "margin-top:20px;border:1px solid #d0d7de;border-radius:6px;padding:12px;",
        ),
      ],
      [
        html.h2([], [html.text("Saved profile")]),
        html.p([html.attribute("data-testid", "saved-profile")], [
          html.text(
            model.display_name
            <> " / "
            <> model.role
            <> " / v"
            <> int.to_string(model.saved_version),
          ),
        ]),
        html.p([html.attribute("data-testid", "settings-local-state")], [
          html.text("Draft: " <> local.draft_name <> " / " <> local.draft_role),
        ]),
        case local.menu_open {
          True ->
            html.div([html.attribute("data-testid", "settings-menu")], [
              html.text("Local actions menu is open"),
            ])
          False ->
            html.span(
              [html.attribute("data-testid", "settings-menu-closed")],
              [],
            )
        },
      ],
    ),
  ])
}

fn lane(name: String, cards: List(Card), local: Local) -> beacon.Node(Msg) {
  let visible =
    list.filter(cards, fn(card) {
      card.lane == name && { local.filter == "all" || local.filter == name }
    })
  html.div(
    [
      html.style(
        "border:1px solid #d0d7de;border-radius:6px;padding:12px;min-height:180px;",
      ),
    ],
    [
      html.h2([], [
        html.text(name <> " (" <> int.to_string(list.length(visible)) <> ")"),
      ]),
      ..list.map(visible, fn(card) { card_view(card, local.compact) })
    ],
  )
}

fn card_view(card: Card, compact: Bool) -> beacon.Node(Msg) {
  let padding = case compact {
    True -> "6px"
    False -> "12px"
  }
  html.article(
    [
      html.style(
        "border:1px solid #d8dee4;border-radius:6px;padding:"
        <> padding
        <> ";margin-bottom:8px;",
      ),
    ],
    [
      html.strong([], [html.text(card.title)]),
      html.p([html.style("margin:4px 0;color:#57606a;")], [
        html.text("Card #" <> int.to_string(card.id) <> " in " <> card.lane),
      ]),
      html.button([beacon.on_click(Advance(card.id))], [html.text("Advance")]),
    ],
  )
}

fn tab_button(tab: String, selected: String) -> beacon.Node(Msg) {
  let weight = case tab == selected {
    True -> "700"
    False -> "400"
  }
  html.button(
    [beacon.on_click(SelectTab(tab)), html.style("font-weight:" <> weight)],
    [html.text(tab)],
  )
}

fn option(value: String, selected: String, label: String) -> beacon.Node(Msg) {
  let attrs = case value == selected {
    True -> [
      html.attribute("value", value),
      html.attribute("selected", "selected"),
    ]
    False -> [html.attribute("value", value)]
  }
  html.option(attrs, [html.text(label)])
}

fn form_field(fields_json: String, field: String) -> Result(String, String) {
  let decoder = {
    use value <- decode.field(field, decode.string)
    decode.success(value)
  }
  case json.parse(fields_json, decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("missing string field `" <> field <> "`")
  }
}

fn metric(label: String, value: String) -> beacon.Node(Msg) {
  html.div(
    [html.style("border:1px solid #d0d7de;border-radius:6px;padding:12px;")],
    [
      html.p([html.style("margin:0;color:#57606a;")], [html.text(label)]),
      html.h2([html.style("margin:4px 0 0;")], [html.text(value)]),
    ],
  )
}

fn shell(path: String, children: List(beacon.Node(Msg))) -> beacon.Node(Msg) {
  let title = case path {
    "/pipeline" -> "Pipeline"
    "/settings" -> "Settings"
    _ -> "Overview"
  }
  html.main(
    [
      html.style(
        "font-family:system-ui;max-width:1040px;margin:32px auto;padding:0 16px;",
      ),
    ],
    [
      html.nav([html.style("display:flex;gap:12px;margin-bottom:24px;")], [
        html.a([html.href("/")], [html.text("Overview")]),
        html.a([html.href("/pipeline")], [html.text("Pipeline")]),
        html.a([html.href("/settings")], [html.text("Settings")]),
      ]),
      html.h1([], [html.text(title)]),
      ..children
    ],
  )
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

pub fn main() {
  beacon.app(init, init_local, beacon.no_server, update, view)
  |> beacon.title("Beacon Routed Workspace")
  |> beacon.route_pages(pages())
  |> beacon.start(8080)
}

fn pages() -> List(route.Page(#(Model, Local, Nil), Msg)) {
  [
    route.page(
      "/",
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Local, Nil), route) {
        let #(model, local, _server) = state
        shell(route.path, [overview_view(model, local)])
      },
    ),
    route.page(
      "/pipeline",
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Local, Nil), route) {
        let #(model, local, _server) = state
        shell(route.path, [pipeline_view(model, local)])
      },
    ),
    route.page(
      "/settings",
      fn(r: route.Route) { RouteChanged(r.path) },
      fn(state: #(Model, Local, Nil), route) {
        let #(model, local, _server) = state
        shell(route.path, [settings_view(model, local)])
      },
    ),
  ]
}
