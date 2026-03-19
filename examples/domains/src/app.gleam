/// Multi-file domain example — demonstrates importing types from domain modules.
/// Model references auth.User and List(items.Item) from separate files.

import beacon
import beacon/html
import domains/auth
import domains/items
import gleam/int
import gleam/list

pub type Model {
  Model(
    user: auth.User,
    items: List(items.Item),
    next_id: Int,
    input: String,
  )
}

pub type Msg {
  SetInput(String)
  AddItem
  ToggleItem(Int)
  SetRole(String)
}

pub fn init() -> Model {
  Model(
    user: auth.User(name: "Alice", email: "alice@example.com", role: auth.Member),
    items: [
      items.Item(id: 1, name: "Buy groceries", done: False),
      items.Item(id: 2, name: "Write tests", done: True),
    ],
    next_id: 3,
    input: "",
  )
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SetInput(text) -> Model(..model, input: text)
    AddItem -> {
      let new_item = items.Item(id: model.next_id, name: model.input, done: False)
      Model(
        ..model,
        items: list.append(model.items, [new_item]),
        next_id: model.next_id + 1,
        input: "",
      )
    }
    ToggleItem(id) -> {
      let updated =
        list.map(model.items, fn(item) {
          case item.id == id {
            True -> items.Item(..item, done: !item.done)
            False -> item
          }
        })
      Model(..model, items: updated)
    }
    SetRole(role_str) -> {
      let role = case role_str {
        "admin" -> auth.Admin
        "guest" -> auth.Guest
        _ -> auth.Member
      }
      Model(..model, user: auth.User(..model.user, role: role))
    }
  }
}

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div([html.class("domains-app")], [
    html.h1([], [html.text("Multi-File Domains")]),
    // User info
    html.div([html.class("user-info")], [
      html.h2([], [html.text("User: " <> model.user.name)]),
      html.p([], [html.text("Email: " <> model.user.email)]),
      html.p([], [
        html.text("Role: " <> role_to_string(model.user.role)),
      ]),
      html.select([beacon.on_change(SetRole)], [
        html.option([html.value("member")], [html.text("Member")]),
        html.option([html.value("admin")], [html.text("Admin")]),
        html.option([html.value("guest")], [html.text("Guest")]),
      ]),
    ]),
    // Items list
    html.div([html.class("items")], [
      html.h2([], [
        html.text(
          "Items ("
          <> int.to_string(list.length(model.items))
          <> ")",
        ),
      ]),
      html.div([], list.map(model.items, view_item)),
      html.div([html.class("add-item")], [
        html.input([
          html.type_("text"),
          html.value(model.input),
          beacon.on_input(SetInput),
          html.placeholder("New item..."),
        ]),
        html.button([beacon.on_click(AddItem)], [html.text("Add")]),
      ]),
    ]),
  ])
}

fn view_item(item: items.Item) -> beacon.Node(Msg) {
  let style = case item.done {
    True -> "text-decoration: line-through; opacity: 0.6;"
    False -> ""
  }
  html.div(
    [
      html.style(style),
      beacon.on_click(ToggleItem(item.id)),
      html.class("item"),
    ],
    [
      html.text(
        case item.done {
          True -> "[x] "
          False -> "[ ] "
        }
        <> item.name,
      ),
    ],
  )
}

fn role_to_string(role: auth.Role) -> String {
  case role {
    auth.Admin -> "Admin"
    auth.Member -> "Member"
    auth.Guest -> "Guest"
  }
}

pub fn main() {
  beacon.app(init, update, view)
  |> beacon.title("Beacon Domains")
  |> beacon.start(8080)
}
