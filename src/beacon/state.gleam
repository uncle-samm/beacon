/// Beacon's state management module.
/// Implements Reflex-inspired dirty-var tracking: after an update, only
/// the changed model fields are identified, and only dependent view subtrees
/// need re-rendering.
///
/// Reference: Reflex.dev dirty-var tracking, computed var caching,
/// Architecture doc section 3.

import gleam/dict.{type Dict}
import gleam/list

/// Tracks which fields have changed between two model states.
/// The dirty set contains the names of fields that were modified.
pub type DirtySet =
  List(String)

/// A field comparison function.
/// Given a field name, returns True if the field changed between old and new model.
pub type FieldComparator(model) =
  fn(model, model) -> DirtySet

/// Compare two models and return the set of dirty (changed) field names.
/// This is a generic function that takes a list of field extractors.
pub fn compute_dirty_fields(
  old: model,
  new: model,
  field_checks: List(#(String, fn(model) -> String)),
) -> DirtySet {
  list.filter_map(field_checks, fn(check) {
    let #(field_name, extractor) = check
    case extractor(old) == extractor(new) {
      True -> Error(Nil)
      False -> Ok(field_name)
    }
  })
}

/// A computed variable — derived from base model fields, cached, and only
/// recomputed when its dependencies change.
///
/// Reference: Reflex computed vars with `@rx.var` and dependency tracking.
pub type ComputedVar(model, value) {
  ComputedVar(
    /// The name of this computed variable.
    name: String,
    /// The fields this computed var depends on.
    dependencies: List(String),
    /// The function that computes the value from the model.
    compute: fn(model) -> value,
  )
}

/// A cache for computed variable values, keyed by variable name.
pub type ComputedCache =
  Dict(String, String)

/// Check if a computed variable needs recomputing based on the dirty set.
pub fn needs_recompute(
  computed: ComputedVar(model, value),
  dirty: DirtySet,
) -> Bool {
  // If any dependency is in the dirty set, needs recompute
  list.any(computed.dependencies, fn(dep) { list.contains(dirty, dep) })
}

/// Update the computed cache based on dirty fields.
/// Only recomputes values whose dependencies intersect with the dirty set.
pub fn update_computed_cache(
  cache: ComputedCache,
  model: model,
  computed_vars: List(ComputedVar(model, String)),
  dirty: DirtySet,
) -> ComputedCache {
  list.fold(computed_vars, cache, fn(acc, cv) {
    case needs_recompute(cv, dirty) {
      True -> {
        let new_value = cv.compute(model)
        dict.insert(acc, cv.name, new_value)
      }
      False -> acc
    }
  })
}

/// Create a new computed variable.
pub fn computed(
  name: String,
  dependencies: List(String),
  compute: fn(model) -> String,
) -> ComputedVar(model, String) {
  ComputedVar(name: name, dependencies: dependencies, compute: compute)
}

/// Get a value from the computed cache, or compute it fresh if not cached.
pub fn get_computed(
  cache: ComputedCache,
  name: String,
  model: model,
  compute: fn(model) -> String,
) -> #(String, ComputedCache) {
  case dict.get(cache, name) {
    Ok(value) -> #(value, cache)
    Error(Nil) -> {
      let value = compute(model)
      let new_cache = dict.insert(cache, name, value)
      #(value, new_cache)
    }
  }
}
