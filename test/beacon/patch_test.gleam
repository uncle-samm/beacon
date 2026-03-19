/// Tests for the JSON Patch operations module.
/// Verifies diffing, applying, and round-trip correctness.

import beacon/log
import beacon/patch
import gleam/string
import gleeunit/should

pub fn diff_identical_models_test() {
  log.configure()
  let json = "{\"count\":0}"
  let ops = patch.diff(json, json)
  patch.is_empty(ops) |> should.be_true
}

pub fn diff_single_field_change_test() {
  log.configure()
  let old = "{\"count\":0}"
  let new = "{\"count\":1}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  // Ops should contain a replace for /count
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("/count") |> should.be_true
}

pub fn diff_multiple_field_changes_test() {
  log.configure()
  let old = "{\"count\":0,\"name\":\"alice\"}"
  let new = "{\"count\":5,\"name\":\"bob\"}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("/count") |> should.be_true
  ops |> string.contains("/name") |> should.be_true
}

pub fn diff_array_append_test() {
  log.configure()
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[1,2,3,4,5]}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  // Should detect append (not full replace)
  ops |> string.contains("append") |> should.be_true
  ops |> string.contains("/items") |> should.be_true
}

pub fn diff_array_replace_test() {
  log.configure()
  // When elements change (not just appended), should be a replace
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[4,5,6]}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("replace") |> should.be_true
}

pub fn diff_field_added_test() {
  log.configure()
  let old = "{\"count\":0}"
  let new = "{\"count\":0,\"name\":\"new\"}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("/name") |> should.be_true
}

pub fn diff_field_removed_test() {
  log.configure()
  let old = "{\"count\":0,\"name\":\"old\"}"
  let new = "{\"count\":0}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("remove") |> should.be_true
  ops |> string.contains("/name") |> should.be_true
}

pub fn apply_replace_op_test() {
  log.configure()
  let model = "{\"count\":0}"
  let ops = "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":5}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> should.equal("{\"count\":5}")
}

pub fn apply_append_op_test() {
  log.configure()
  let model = "{\"items\":[1,2]}"
  let ops = "[{\"op\":\"append\",\"path\":\"/items\",\"value\":[3,4]}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  // Verify all original and appended elements are present
  result |> string.contains("[1,2,3,4]") |> should.be_true
}

pub fn apply_remove_op_test() {
  log.configure()
  let model = "{\"count\":0,\"name\":\"test\"}"
  let ops = "[{\"op\":\"remove\",\"path\":\"/name\"}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> string.contains("count") |> should.be_true
  result |> string.contains("name") |> should.be_false
}

pub fn apply_empty_ops_test() {
  log.configure()
  let model = "{\"count\":0}"
  let ops = "[]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> should.equal(model)
}

pub fn roundtrip_diff_apply_test() {
  log.configure()
  // Diff two models, apply the diff to the old model, should get the new model
  let old = "{\"count\":0,\"name\":\"alice\"}"
  let new = "{\"count\":5,\"name\":\"alice\"}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  // Verify exact key:value pairs, not just bare values
  result |> string.contains("\"count\":5") |> should.be_true
  result |> string.contains("\"name\":\"alice\"") |> should.be_true
}

pub fn roundtrip_append_test() {
  log.configure()
  let old = "{\"strokes\":[{\"x\":0}]}"
  let new = "{\"strokes\":[{\"x\":0},{\"x\":1},{\"x\":2}]}"
  let ops = patch.diff(old, new)
  // Should be an append
  ops |> string.contains("append") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  // Result should contain all three strokes
  result |> string.contains("\"x\":0") |> should.be_true
  result |> string.contains("\"x\":1") |> should.be_true
  result |> string.contains("\"x\":2") |> should.be_true
}

pub fn is_empty_true_test() {
  log.configure()
  patch.is_empty("[]") |> should.be_true
}

pub fn is_empty_false_test() {
  log.configure()
  patch.is_empty("[{\"op\":\"replace\",\"path\":\"/count\",\"value\":1}]")
  |> should.be_false
}

pub fn diff_no_change_single_field_test() {
  log.configure()
  let old = "{\"count\":5}"
  let new = "{\"count\":5}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_true
}

pub fn diff_nested_object_test() {
  log.configure()
  let old = "{\"player\":{\"x\":0,\"y\":0}}"
  let new = "{\"player\":{\"x\":10,\"y\":0}}"
  let ops = patch.diff(old, new)
  patch.is_empty(ops) |> should.be_false
  ops |> string.contains("/player/x") |> should.be_true
}

pub fn multiple_ops_apply_test() {
  log.configure()
  let model = "{\"count\":0,\"name\":\"old\"}"
  let ops =
    "[{\"op\":\"replace\",\"path\":\"/count\",\"value\":10},{\"op\":\"replace\",\"path\":\"/name\",\"value\":\"new\"}]"
  let assert Ok(result) = patch.apply_ops(model, ops)
  result |> string.contains("\"count\":10") |> should.be_true
  result |> string.contains("\"name\":\"new\"") |> should.be_true
}

// === Part 1: Optimization proof tests ===

pub fn append_not_replace_for_array_growth_test() {
  log.configure()
  // Appending to an array MUST produce "append" not "replace"
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[1,2,3,4,5]}"
  let ops = patch.diff(old, new)
  ops |> string.contains("\"op\":\"append\"") |> should.be_true
  ops |> string.contains("\"/items\"") |> should.be_true
  ops |> string.contains("replace") |> should.be_false
}

pub fn replace_for_modified_array_element_test() {
  log.configure()
  // Modifying an element (not just appending) MUST produce "replace"
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[1,99,3]}"
  let ops = patch.diff(old, new)
  ops |> string.contains("replace") |> should.be_true
  ops |> string.contains("append") |> should.be_false
}

pub fn patch_size_smaller_than_model_test() {
  log.configure()
  // A single field change on a large model should produce a tiny patch
  let old =
    "{\"count\":50,\"name\":\"alice\",\"items\":[1,2,3,4,5,6,7,8,9,10],\"active\":true,\"score\":999}"
  let new =
    "{\"count\":51,\"name\":\"alice\",\"items\":[1,2,3,4,5,6,7,8,9,10],\"active\":true,\"score\":999}"
  let ops = patch.diff(old, new)
  // Patch should be much smaller than the full model
  let ops_size = string.length(ops)
  let model_size = string.length(new)
  let assert True = ops_size < model_size
}

pub fn roundtrip_nested_objects_test() {
  log.configure()
  let old = "{\"player\":{\"pos\":{\"x\":0,\"y\":0},\"hp\":100},\"enemies\":[]}"
  let new =
    "{\"player\":{\"pos\":{\"x\":10,\"y\":5},\"hp\":95},\"enemies\":[{\"id\":1}]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"x\":10") |> should.be_true
  result |> string.contains("\"y\":5") |> should.be_true
  result |> string.contains("\"hp\":95") |> should.be_true
  result |> string.contains("\"id\":1") |> should.be_true
}

pub fn roundtrip_arrays_of_objects_test() {
  log.configure()
  let old =
    "{\"cards\":[{\"id\":1,\"title\":\"a\"},{\"id\":2,\"title\":\"b\"}]}"
  let new =
    "{\"cards\":[{\"id\":1,\"title\":\"a\"},{\"id\":2,\"title\":\"b\"},{\"id\":3,\"title\":\"c\"}]}"
  let ops = patch.diff(old, new)
  // Should be append
  ops |> string.contains("append") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"id\":3") |> should.be_true
  result |> string.contains("\"title\":\"c\"") |> should.be_true
}

pub fn roundtrip_mixed_types_test() {
  log.configure()
  let old = "{\"count\":0,\"name\":\"x\",\"active\":false,\"score\":1.5,\"tags\":[]}"
  let new =
    "{\"count\":7,\"name\":\"y\",\"active\":true,\"score\":3.14,\"tags\":[\"a\",\"b\"]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"count\":7") |> should.be_true
  result |> string.contains("\"name\":\"y\"") |> should.be_true
  result |> string.contains("\"active\":true") |> should.be_true
  result |> string.contains("\"score\":3.14") |> should.be_true
  result |> string.contains("\"a\"") |> should.be_true
  result |> string.contains("\"b\"") |> should.be_true
}

pub fn roundtrip_empty_to_populated_test() {
  log.configure()
  let old = "{\"items\":[]}"
  let new = "{\"items\":[{\"x\":1},{\"x\":2},{\"x\":3}]}"
  let ops = patch.diff(old, new)
  ops |> string.contains("append") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"x\":1") |> should.be_true
  result |> string.contains("\"x\":3") |> should.be_true
}

pub fn roundtrip_populated_to_empty_test() {
  log.configure()
  let old = "{\"items\":[1,2,3]}"
  let new = "{\"items\":[]}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("[]") |> should.be_true
}

pub fn roundtrip_deeply_nested_test() {
  log.configure()
  let old = "{\"a\":{\"b\":{\"c\":{\"d\":1}}}}"
  let new = "{\"a\":{\"b\":{\"c\":{\"d\":99}}}}"
  let ops = patch.diff(old, new)
  ops |> string.contains("/a/b/c/d") |> should.be_true
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"d\":99") |> should.be_true
}

pub fn roundtrip_string_with_special_chars_test() {
  log.configure()
  let old = "{\"msg\":\"hello\"}"
  let new = "{\"msg\":\"world with spaces & symbols!\"}"
  let ops = patch.diff(old, new)
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("world with spaces") |> should.be_true
}

pub fn diff_only_changed_field_test() {
  log.configure()
  // When only one of many fields changes, ops should reference ONLY that field
  let old = "{\"a\":1,\"b\":2,\"c\":3,\"d\":4,\"e\":5}"
  let new = "{\"a\":1,\"b\":2,\"c\":99,\"d\":4,\"e\":5}"
  let ops = patch.diff(old, new)
  ops |> string.contains("/c") |> should.be_true
  // Should NOT contain references to unchanged fields
  ops |> string.contains("/a") |> should.be_false
  ops |> string.contains("/b") |> should.be_false
  ops |> string.contains("/d") |> should.be_false
  ops |> string.contains("/e") |> should.be_false
  // Verify applying ops to old produces new
  let assert Ok(result) = patch.apply_ops(old, ops)
  result |> string.contains("\"c\":99") |> should.be_true
  result |> string.contains("\"a\":1") |> should.be_true
}
