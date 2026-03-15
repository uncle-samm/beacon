import beacon/template/rendered

// --- Build tests ---

pub fn build_creates_rendered_test() {
  let r = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let assert ["<h1>", "</h1>"] = r.statics
  let assert ["Hello"] = r.dynamics
  let assert True = r.fingerprint != 0
}

pub fn build_fingerprint_deterministic_test() {
  let r1 = rendered.build(["<h1>", "</h1>"], ["A"])
  let r2 = rendered.build(["<h1>", "</h1>"], ["B"])
  // Same statics → same fingerprint
  let assert True = r1.fingerprint == r2.fingerprint
}

pub fn build_different_statics_different_fingerprint_test() {
  let r1 = rendered.build(["<h1>", "</h1>"], ["A"])
  let r2 = rendered.build(["<p>", "</p>"], ["A"])
  // Different statics → different fingerprint
  let assert True = r1.fingerprint != r2.fingerprint
}

// --- to_html tests ---

pub fn to_html_simple_test() {
  let r = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let assert "<h1>Hello</h1>" = rendered.to_html(r)
}

pub fn to_html_multiple_dynamics_test() {
  let r =
    rendered.build(
      ["<h1>", "</h1><p>", "</p>"],
      ["Title", "Body"],
    )
  let assert "<h1>Title</h1><p>Body</p>" = rendered.to_html(r)
}

pub fn to_html_no_dynamics_test() {
  let r = rendered.build(["<h1>Static</h1>"], [])
  let assert "<h1>Static</h1>" = rendered.to_html(r)
}

pub fn to_html_empty_test() {
  let r = rendered.build([], [])
  let assert "" = rendered.to_html(r)
}

// --- Diff tests ---

pub fn diff_no_change_test() {
  let old = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let new = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let assert rendered.NoDiff = rendered.diff(old, new)
}

pub fn diff_one_dynamic_changed_test() {
  let old = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let new = rendered.build(["<h1>", "</h1>"], ["World"])
  let assert rendered.DynamicDiff(changes: [#(0, "World")]) =
    rendered.diff(old, new)
}

pub fn diff_multiple_dynamics_only_changed_sent_test() {
  let old =
    rendered.build(
      ["<h1>", "</h1><p>", "</p>"],
      ["Title", "Old Body"],
    )
  let new =
    rendered.build(
      ["<h1>", "</h1><p>", "</p>"],
      ["Title", "New Body"],
    )
  // Only index 1 changed
  let assert rendered.DynamicDiff(changes: [#(1, "New Body")]) =
    rendered.diff(old, new)
}

pub fn diff_all_dynamics_changed_test() {
  let old =
    rendered.build(
      ["<h1>", "</h1><p>", "</p>"],
      ["Old Title", "Old Body"],
    )
  let new =
    rendered.build(
      ["<h1>", "</h1><p>", "</p>"],
      ["New Title", "New Body"],
    )
  let assert rendered.DynamicDiff(changes: [
    #(0, "New Title"),
    #(1, "New Body"),
  ]) = rendered.diff(old, new)
}

pub fn diff_structure_changed_full_render_test() {
  let old = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let new = rendered.build(["<p>", "</p>"], ["Hello"])
  let assert rendered.FullRender(..) = rendered.diff(old, new)
}

// --- JSON encoding tests ---

pub fn mount_json_format_test() {
  let r = rendered.build(["<h1>", "</h1>"], ["Hello"])
  let json_str = rendered.to_mount_json(r) |> json_to_string()
  let assert True = str_contains(json_str, "\"s\":")
  let assert True = str_contains(json_str, "\"0\":\"Hello\"")
}

pub fn diff_json_no_diff_test() {
  let json_str = rendered.diff_to_json_string(rendered.NoDiff)
  let assert "{}" = json_str
}

pub fn diff_json_dynamic_diff_test() {
  let diff =
    rendered.DynamicDiff(changes: [#(0, "World"), #(2, "Changed")])
  let json_str = rendered.diff_to_json_string(diff)
  let assert True = str_contains(json_str, "\"0\":\"World\"")
  let assert True = str_contains(json_str, "\"2\":\"Changed\"")
}

// --- Helpers ---

fn str_contains(haystack: String, needle: String) -> Bool {
  do_str_contains(haystack, needle)
}

@external(erlang, "beacon_test_ffi", "string_contains")
fn do_str_contains(haystack: String, needle: String) -> Bool

@external(erlang, "gleam@json", "to_string")
fn json_to_string(json: json.Json) -> String

import gleam/json
