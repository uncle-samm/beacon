import beacon/state
import gleam/dict
import gleam/int
import gleam/list

// --- Test model ---

pub type TestModel {
  TestModel(name: String, count: Int, active: Bool)
}

fn test_field_checks() -> List(#(String, fn(TestModel) -> String)) {
  [
    #("name", fn(m: TestModel) { m.name }),
    #("count", fn(m: TestModel) { int.to_string(m.count) }),
    #("active", fn(m: TestModel) {
      case m.active {
        True -> "true"
        False -> "false"
      }
    }),
  ]
}

// --- Dirty field tracking tests ---

pub fn no_changes_empty_dirty_test() {
  let model = TestModel(name: "Alice", count: 0, active: True)
  let dirty = state.compute_dirty_fields(model, model, test_field_checks())
  let assert [] = dirty
}

pub fn one_field_changed_test() {
  let old = TestModel(name: "Alice", count: 0, active: True)
  let new = TestModel(name: "Bob", count: 0, active: True)
  let dirty = state.compute_dirty_fields(old, new, test_field_checks())
  let assert ["name"] = dirty
}

pub fn multiple_fields_changed_test() {
  let old = TestModel(name: "Alice", count: 0, active: True)
  let new = TestModel(name: "Bob", count: 5, active: True)
  let dirty = state.compute_dirty_fields(old, new, test_field_checks())
  let assert True = list.contains(dirty, "name")
  let assert True = list.contains(dirty, "count")
  let assert False = list.contains(dirty, "active")
}

pub fn all_fields_changed_test() {
  let old = TestModel(name: "Alice", count: 0, active: True)
  let new = TestModel(name: "Bob", count: 5, active: False)
  let dirty = state.compute_dirty_fields(old, new, test_field_checks())
  let assert 3 = list.length(dirty)
}

// --- Computed variable tests ---

pub fn needs_recompute_when_dependency_dirty_test() {
  let cv =
    state.computed("greeting", ["name"], fn(m: TestModel) {
      "Hello, " <> m.name
    })
  let assert True = state.needs_recompute(cv, ["name"])
}

pub fn no_recompute_when_dependency_clean_test() {
  let cv =
    state.computed("greeting", ["name"], fn(m: TestModel) {
      "Hello, " <> m.name
    })
  let assert False = state.needs_recompute(cv, ["count"])
}

pub fn no_recompute_when_empty_dirty_test() {
  let cv =
    state.computed("greeting", ["name"], fn(m: TestModel) {
      "Hello, " <> m.name
    })
  let assert False = state.needs_recompute(cv, [])
}

pub fn recompute_with_multiple_dependencies_test() {
  let cv =
    state.computed("summary", ["name", "count"], fn(m: TestModel) {
      m.name <> ": " <> int.to_string(m.count)
    })
  // If either dependency is dirty, should recompute
  let assert True = state.needs_recompute(cv, ["count"])
  let assert True = state.needs_recompute(cv, ["name"])
  let assert False = state.needs_recompute(cv, ["active"])
}

// --- Computed cache tests ---

pub fn update_cache_recomputes_dirty_test() {
  let model = TestModel(name: "Alice", count: 5, active: True)
  let cv =
    state.computed("greeting", ["name"], fn(m: TestModel) {
      "Hello, " <> m.name
    })
  let cache = dict.new()
  let new_cache =
    state.update_computed_cache(cache, model, [cv], ["name"])
  let assert Ok("Hello, Alice") = dict.get(new_cache, "greeting")
}

pub fn update_cache_skips_clean_test() {
  let model = TestModel(name: "Alice", count: 5, active: True)
  let cv =
    state.computed("greeting", ["name"], fn(m: TestModel) {
      "Hello, " <> m.name
    })
  let cache = dict.from_list([#("greeting", "Hello, OLD")])
  let new_cache =
    state.update_computed_cache(cache, model, [cv], ["count"])
  // "name" not dirty, so cache should keep old value
  let assert Ok("Hello, OLD") = dict.get(new_cache, "greeting")
}

pub fn get_computed_from_cache_test() {
  let model = TestModel(name: "Alice", count: 0, active: True)
  let cache = dict.from_list([#("greeting", "Hello, Cached")])
  let #(value, _) =
    state.get_computed(cache, "greeting", model, fn(_m: TestModel) {
      "Hello, Computed"
    })
  let assert "Hello, Cached" = value
}

pub fn get_computed_computes_when_missing_test() {
  let model = TestModel(name: "Alice", count: 0, active: True)
  let cache = dict.new()
  let #(value, new_cache) =
    state.get_computed(cache, "greeting", model, fn(m: TestModel) {
      "Hello, " <> m.name
    })
  let assert "Hello, Alice" = value
  let assert Ok("Hello, Alice") = dict.get(new_cache, "greeting")
}
