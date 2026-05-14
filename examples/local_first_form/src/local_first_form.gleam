import beacon
import beacon/html
import beacon/log
import gleam/dynamic/decode
import gleam/int
import gleam/json

pub type Model {
  Model(saved_query: String, saved_filter: String, submissions: Int)
}

pub type Local {
  Local(draft: String, filter: String, menu_open: Bool)
}

pub type Msg {
  UpdateDraft(String)
  SelectFilter(String)
  ToggleMenu
  SubmitSearch(String)
}

pub fn init() -> Model {
  Model(saved_query: "", saved_filter: "all", submissions: 0)
}

pub fn init_local(model: Model) -> Local {
  Local(draft: model.saved_query, filter: model.saved_filter, menu_open: False)
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    UpdateDraft(value) -> #(model, Local(..local, draft: value))
    SelectFilter(value) -> #(model, Local(..local, filter: value))
    ToggleMenu -> #(model, Local(..local, menu_open: !local.menu_open))
    SubmitSearch(fields_json) -> {
      case
        form_field(fields_json, "draft_query"),
        form_field(fields_json, "filter")
      {
        Ok(query), Ok(filter) -> #(
          Model(
            saved_query: query,
            saved_filter: filter,
            submissions: model.submissions + 1,
          ),
          Local(..local, menu_open: False),
        )
        Error(reason), _ | _, Error(reason) -> {
          log.warning("local_first_form", "Invalid submit: " <> reason)
          #(model, local)
        }
      }
    }
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  html.main(
    [
      html.style(
        "font-family:system-ui;max-width:760px;margin:32px auto;padding:0 16px;",
      ),
    ],
    [
      html.h1([], [html.text("Local First Form")]),
      html.p([], [
        html.text(
          "Draft controls are local. Submit is the server-authoritative model update.",
        ),
      ]),
      html.form(
        [
          beacon.on_submit_local(SubmitSearch),
          html.style("display:grid;gap:12px;margin:20px 0;"),
        ],
        [
          html.label([], [
            html.text("Draft query"),
            html.input([
              html.attribute("data-testid", "draft-input"),
              html.type_("text"),
              html.value(local.draft),
              html.attribute("name", "draft_query"),
              html.placeholder("Type without server traffic"),
              beacon.on_input(UpdateDraft),
            ]),
          ]),
          html.label([], [
            html.text("Filter"),
            html.select(
              [
                html.attribute("data-testid", "filter-select"),
                html.value(local.filter),
                html.attribute("name", "filter"),
                beacon.on_input(SelectFilter),
              ],
              [
                option("all", "All", local.filter),
                option("open", "Open", local.filter),
                option("closed", "Closed", local.filter),
              ],
            ),
          ]),
          html.button([html.type_("button"), beacon.on_click(ToggleMenu)], [
            html.text("Toggle options"),
          ]),
          case local.menu_open {
            True ->
              html.div(
                [
                  html.attribute("data-testid", "local-menu"),
                  html.style("border:1px solid #d0d7de;padding:10px;"),
                ],
                [
                  html.text("Preview: " <> preview(local.draft, local.filter)),
                ],
              )
            False -> html.span([], [])
          },
          html.button([html.type_("submit")], [html.text("Save search")]),
        ],
      ),
      html.section([], [
        html.h2([], [html.text("Current local draft")]),
        html.p([html.attribute("data-testid", "local-preview")], [
          html.text(preview(local.draft, local.filter)),
        ]),
      ]),
      html.section([], [
        html.h2([], [html.text("Saved model")]),
        html.p([html.attribute("data-testid", "saved-query")], [
          html.text(model.saved_query),
        ]),
        html.p([html.attribute("data-testid", "saved-filter")], [
          html.text(model.saved_filter),
        ]),
        html.p([html.attribute("data-testid", "submission-count")], [
          html.text("Submissions: " <> int.to_string(model.submissions)),
        ]),
      ]),
    ],
  )
}

fn option(value: String, label: String, selected: String) -> beacon.Node(Msg) {
  let attrs = case value == selected {
    True -> [html.value(value), html.attribute("selected", "selected")]
    False -> [html.value(value)]
  }
  html.option(attrs, [html.text(label)])
}

fn preview(draft: String, filter: String) -> String {
  "\"" <> draft <> "\" in " <> filter
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

pub fn main() {
  beacon.app_with_local(init, init_local, update, view)
  |> beacon.title("Local First Form")
  |> beacon.start(8080)
}
