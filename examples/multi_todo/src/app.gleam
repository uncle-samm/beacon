/// Multi-file Todo — demonstrates external types with Local state.
/// TodoItem and Filter types live in domains/task.gleam.

import beacon
import beacon/html
import domains/task
import gleam/int
import gleam/list
import gleam/string

pub type Model {
  Model(
    todos: List(task.TodoItem),
    input: String,
    next_id: Int,
  )
}

pub type Local {
  Local(filter: task.Filter)
}

pub type Msg {
  SetInput(String)
  AddTodo
  ToggleTodo(Int)
  DeleteTodo(Int)
  SetFilter(String)
  ClearCompleted
}

pub fn init() -> Model {
  Model(
    todos: [
      task.TodoItem(id: 1, text: "Learn Gleam", completed: True),
      task.TodoItem(id: 2, text: "Build with Beacon", completed: False),
      task.TodoItem(id: 3, text: "Ship it", completed: False),
    ],
    input: "",
    next_id: 4,
  )
}

pub fn init_local(_model: Model) -> Local {
  Local(filter: task.All)
}

pub fn update(model: Model, local: Local, msg: Msg) -> #(Model, Local) {
  case msg {
    SetInput(text) -> #(Model(..model, input: text), local)
    AddTodo -> {
      let text = string.trim(model.input)
      case string.is_empty(text) {
        True -> #(model, local)
        False -> {
          let item =
            task.TodoItem(id: model.next_id, text: text, completed: False)
          #(
            Model(
              todos: list.append(model.todos, [item]),
              next_id: model.next_id + 1,
              input: "",
            ),
            local,
          )
        }
      }
    }
    ToggleTodo(id) -> {
      let todos =
        list.map(model.todos, fn(t) {
          case t.id == id {
            True -> task.TodoItem(..t, completed: !t.completed)
            False -> t
          }
        })
      #(Model(..model, todos: todos), local)
    }
    DeleteTodo(id) ->
      #(
        Model(..model, todos: list.filter(model.todos, fn(t) { t.id != id })),
        local,
      )
    SetFilter(f) -> {
      let filter = case f {
        "active" -> task.Active
        "completed" -> task.Completed
        _ -> task.All
      }
      #(model, Local(filter: filter))
    }
    ClearCompleted ->
      #(
        Model(
          ..model,
          todos: list.filter(model.todos, fn(t) { !t.completed }),
        ),
        local,
      )
  }
}

pub fn view(model: Model, local: Local) -> beacon.Node(Msg) {
  let visible = case local.filter {
    task.All -> model.todos
    task.Active -> list.filter(model.todos, fn(t) { !t.completed })
    task.Completed -> list.filter(model.todos, fn(t) { t.completed })
  }
  let remaining = list.count(model.todos, fn(t) { !t.completed })

  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:600px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Multi-File Todo")]),
      html.p([html.style("color:#666")], [
        html.text("TodoItem + Filter types from domains/task.gleam"),
      ]),
      // Add form
      html.div([html.style("display:flex;gap:8px;margin:1rem 0")], [
        html.input([
          html.type_("text"),
          html.placeholder("What needs to be done?"),
          html.value(model.input),
          beacon.on_input(SetInput),
          html.style(
            "flex:1;padding:10px;border:1px solid #ddd;border-radius:6px",
          ),
        ]),
        html.button(
          [
            beacon.on_click(AddTodo),
            html.style(
              "padding:10px 20px;background:#4CAF50;color:white;border:none;border-radius:6px;cursor:pointer",
            ),
          ],
          [html.text("Add")],
        ),
      ]),
      // Filter buttons
      html.div([html.style("display:flex;gap:8px;margin-bottom:1rem")], [
        filter_button("All", "all", local.filter, task.All),
        filter_button("Active", "active", local.filter, task.Active),
        filter_button("Completed", "completed", local.filter, task.Completed),
        html.button(
          [
            beacon.on_click(ClearCompleted),
            html.style(
              "margin-left:auto;padding:8px 16px;background:#f44336;color:white;border:none;border-radius:6px;cursor:pointer",
            ),
          ],
          [html.text("Clear Done")],
        ),
      ]),
      // Items
      html.div([], list.map(visible, view_item)),
      // Footer
      html.p([html.style("color:#999;margin-top:1rem")], [
        html.text(int.to_string(remaining) <> " items remaining"),
      ]),
    ],
  )
}

fn filter_button(
  label: String,
  value: String,
  current: task.Filter,
  this: task.Filter,
) -> beacon.Node(Msg) {
  let bg = case current == this {
    True -> "background:#1976d2;color:white"
    False -> "background:#eee;color:#333"
  }
  html.button(
    [
      beacon.on_click(SetFilter(value)),
      html.style(
        "padding:8px 16px;border:none;border-radius:6px;cursor:pointer;" <> bg,
      ),
    ],
    [html.text(label)],
  )
}

fn view_item(item: task.TodoItem) -> beacon.Node(Msg) {
  let style = case item.completed {
    True -> "text-decoration:line-through;opacity:0.5"
    False -> ""
  }
  html.div(
    [
      html.style(
        "display:flex;align-items:center;gap:12px;padding:12px;border-bottom:1px solid #eee",
      ),
    ],
    [
      html.span(
        [
          beacon.on_click(ToggleTodo(item.id)),
          html.style("cursor:pointer;font-size:20px"),
        ],
        [
          html.text(case item.completed {
            True -> "☑"
            False -> "☐"
          }),
        ],
      ),
      html.span([html.style(style <> ";flex:1")], [html.text(item.text)]),
      html.button(
        [
          beacon.on_click(DeleteTodo(item.id)),
          html.style(
            "background:none;border:none;color:#ccc;cursor:pointer;font-size:18px",
          ),
        ],
        [html.text("x")],
      ),
    ],
  )
}

pub fn main() {
  beacon.app_with_local(init, init_local, update, view)
  |> beacon.title("Multi-File Todo")
  |> beacon.start(8080)
}
