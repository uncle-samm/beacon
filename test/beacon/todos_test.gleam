import beacon/effect
import beacon/element
import beacon/examples/todos
import beacon/form
import gleam/list

// --- Model tests ---

pub fn init_empty_test() {
  let #(model, eff) = todos.init()
  let assert [] = model.todos
  let assert 1 = model.next_id
  let assert True = effect.is_none(eff)
}

pub fn add_item_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "Buy milk")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let assert [item] = model.todos
  let assert "Buy milk" = item.text
  let assert False = item.completed
  let assert 1 = item.id
  let assert 2 = model.next_id
}

pub fn add_empty_item_shows_error_test() {
  let #(model, _) = todos.init()
  let #(model, _) = todos.update(model, todos.AddTodo)
  let assert [] = model.todos
  // Form should have validation error
  let assert True = has_form_errors(model)
}

pub fn add_whitespace_only_shows_error_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "   ")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let assert [] = model.todos
}

pub fn toggle_item_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "Test")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let #(model, _) = todos.update(model, todos.ToggleTodo(id: 1))
  let assert [item] = model.todos
  let assert True = item.completed
}

pub fn toggle_item_twice_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "Test")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let #(model, _) = todos.update(model, todos.ToggleTodo(id: 1))
  let #(model, _) = todos.update(model, todos.ToggleTodo(id: 1))
  let assert [item] = model.todos
  let assert False = item.completed
}

pub fn delete_item_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "Test")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let #(model, _) = todos.update(model, todos.DeleteTodo(id: 1))
  let assert [] = model.todos
}

pub fn clear_completed_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "A")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let model = set_input(model, "B")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let #(model, _) = todos.update(model, todos.ToggleTodo(id: 1))
  let #(model, _) = todos.update(model, todos.ClearCompleted)
  let assert [item] = model.todos
  let assert "B" = item.text
}

pub fn set_filter_test() {
  let #(model, _) = todos.init()
  let #(model, _) = todos.update(model, todos.SetFilter(todos.Active))
  let assert todos.Active = model.filter
}

pub fn update_input_test() {
  let #(model, _) = todos.init()
  let #(model, _) = todos.update(model, todos.UpdateInput(value: "hello"))
  let assert "hello" = get_input(model)
}

pub fn multiple_items_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "A")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let model = set_input(model, "B")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let model = set_input(model, "C")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let assert 3 = list.length(model.todos)
  let assert 4 = model.next_id
}

// --- View tests ---

pub fn view_renders_title_test() {
  let #(model, _) = todos.init()
  let html = element.to_string(todos.view(model))
  let assert True = str_contains(html, "Beacon Todos")
}

pub fn view_renders_input_test() {
  let #(model, _) = todos.init()
  let html = element.to_string(todos.view(model))
  let assert True = str_contains(html, "What needs to be done?")
}

pub fn view_renders_items_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "Buy milk")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let html = element.to_string(todos.view(model))
  let assert True = str_contains(html, "Buy milk")
}

pub fn view_renders_item_count_test() {
  let #(model, _) = todos.init()
  let model = set_input(model, "A")
  let #(model, _) = todos.update(model, todos.AddTodo)
  let html = element.to_string(todos.view(model))
  let assert True = str_contains(html, "1 item(s) left")
}

pub fn view_renders_filter_buttons_test() {
  let #(model, _) = todos.init()
  let html = element.to_string(todos.view(model))
  let assert True = str_contains(html, "All")
  let assert True = str_contains(html, "Active")
  let assert True = str_contains(html, "Completed")
}

// --- Event decoding tests ---

pub fn decode_add_todo_test() {
  let assert Ok(todos.AddTodo) =
    todos.decode_event("click", "add_todo", "{}", "0")
}

pub fn decode_toggle_test() {
  let assert Ok(todos.ToggleTodo(id: 5)) =
    todos.decode_event("click", "toggle_5", "{}", "0")
}

pub fn decode_delete_test() {
  let assert Ok(todos.DeleteTodo(id: 3)) =
    todos.decode_event("click", "delete_3", "{}", "0")
}

pub fn decode_filter_test() {
  let assert Ok(todos.SetFilter(todos.Active)) =
    todos.decode_event("click", "filter_active", "{}", "0")
}

pub fn decode_clear_completed_test() {
  let assert Ok(todos.ClearCompleted) =
    todos.decode_event("click", "clear_completed", "{}", "0")
}

pub fn decode_update_input_test() {
  let assert Ok(todos.UpdateInput(value: "hello")) =
    todos.decode_event("input", "update_input", "{\"value\":\"hello\"}", "0")
}

pub fn decode_unknown_handler_test() {
  let assert Error(_) =
    todos.decode_event("click", "unknown", "{}", "0")
}

// --- Helpers ---

fn set_input(model: todos.Model, value: String) -> todos.Model {
  let #(m, _) = todos.update(model, todos.UpdateInput(value: value))
  m
}

fn get_input(model: todos.Model) -> String {
  form.get_value(model.input_form, "new_todo")
}

fn has_form_errors(model: todos.Model) -> Bool {
  form.has_errors(model.input_form)
}

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool
