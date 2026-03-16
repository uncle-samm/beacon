import beacon/handler

pub type TestMsg {
  Increment
  Decrement
  SetName(String)
}

pub fn register_and_resolve_simple_test() {
  handler.start_render()
  let id = handler.register_simple(Increment)
  let registry = handler.finish_render()
  let assert Ok(Increment) = handler.resolve(registry, id, "{}")
}

pub fn sequential_ids_test() {
  handler.start_render()
  let id0 = handler.register_simple(Increment)
  let id1 = handler.register_simple(Decrement)
  let registry = handler.finish_render()
  let assert "h0" = id0
  let assert "h1" = id1
  let assert Ok(Increment) = handler.resolve(registry, "h0", "{}")
  let assert Ok(Decrement) = handler.resolve(registry, "h1", "{}")
}

pub fn parameterized_handler_test() {
  handler.start_render()
  let id = handler.register_parameterized(SetName)
  let registry = handler.finish_render()
  let assert Ok(SetName("Alice")) =
    handler.resolve(registry, id, "{\"value\":\"Alice\"}")
}

pub fn unknown_handler_returns_error_test() {
  handler.start_render()
  let registry = handler.finish_render()
  let assert Error(_) = handler.resolve(registry, "h999", "{}")
}

pub fn fresh_registry_per_render_test() {
  // First render
  handler.start_render()
  let _id = handler.register_simple(Increment)
  let _r1 = handler.finish_render()
  // Second render — should start fresh
  handler.start_render()
  let id = handler.register_simple(Decrement)
  let r2 = handler.finish_render()
  let assert "h0" = id
  let assert Ok(Decrement) = handler.resolve(r2, "h0", "{}")
}

pub fn nested_render_safe_test() {
  // Outer render
  handler.start_render()
  let outer_id = handler.register_simple(Increment)
  // Inner render (component)
  handler.start_render()
  let inner_id = handler.register_simple(Decrement)
  let inner_reg = handler.finish_render()
  // Back to outer
  let outer_id2 = handler.register_simple(SetName("x"))
  let outer_reg = handler.finish_render()
  // Inner should have its own IDs
  let assert "h0" = inner_id
  let assert Ok(Decrement) = handler.resolve(inner_reg, "h0", "{}")
  // Outer should be preserved
  let assert "h0" = outer_id
  let assert "h1" = outer_id2
  let assert Ok(Increment) = handler.resolve(outer_reg, "h0", "{}")
}

pub fn deterministic_ids_same_tree_test() {
  // Two renders of the same structure → same IDs
  handler.start_render()
  let id_a1 = handler.register_simple(Increment)
  let id_a2 = handler.register_simple(Decrement)
  let _r1 = handler.finish_render()

  handler.start_render()
  let id_b1 = handler.register_simple(Increment)
  let id_b2 = handler.register_simple(Decrement)
  let _r2 = handler.finish_render()

  let assert True = id_a1 == id_b1
  let assert True = id_a2 == id_b2
}
