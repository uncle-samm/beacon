/// Glance-based code analyzer for the build tool.
/// Parses user source code and classifies Msg variants.

import glance
import gleam/list

/// Result of analyzing a user's app module.
pub type Analysis {
  Analysis(
    /// All Msg type variants with their classification.
    msg_variants: List(MsgVariant),
    /// Whether the module has a Local type.
    has_local: Bool,
  )
}

/// A single Msg variant with its model-impact classification.
pub type MsgVariant {
  MsgVariant(
    /// The variant name (e.g., "Increment", "SetInput").
    name: String,
    /// True if this variant's update branch modifies Model.
    affects_model: Bool,
  )
}

/// Analyze a Gleam source string.
/// Returns the Msg variants with model-impact classification.
pub fn analyze(source: String) -> Result(Analysis, String) {
  case glance.module(source) {
    Ok(module) -> {
      // Find Msg type
      let msg_type = find_custom_type(module, "Msg")
      // Find update function
      let update_fn = find_function(module, "update")
      // Check for Local type
      let has_local = case find_custom_type(module, "Local") {
        Ok(_) -> True
        Error(_) -> False
      }

      case msg_type, update_fn {
        Ok(msg), Ok(func) -> {
          let variants = classify_variants(msg, func)
          Ok(Analysis(msg_variants: variants, has_local: has_local))
        }
        Error(r), _ -> Error(r)
        _, Error(r) -> Error(r)
      }
    }
    Error(_) -> Error("Failed to parse source")
  }
}

/// Find a custom type by name in a module.
fn find_custom_type(
  module: glance.Module,
  name: String,
) -> Result(glance.CustomType, String) {
  case
    list.find(module.custom_types, fn(def) {
      def.definition.name == name
    })
  {
    Ok(def) -> Ok(def.definition)
    Error(Nil) -> Error("Type '" <> name <> "' not found")
  }
}

/// Find a public function by name.
fn find_function(
  module: glance.Module,
  name: String,
) -> Result(glance.Function, String) {
  case
    list.find(module.functions, fn(def) {
      def.definition.name == name && def.definition.publicity == glance.Public
    })
  {
    Ok(def) -> Ok(def.definition)
    Error(Nil) -> Error("Public function '" <> name <> "' not found")
  }
}

/// Classify each Msg variant based on the update function's case arms.
/// A variant affects the model if its case arm returns a modified model
/// (not just returning the input model unchanged).
fn classify_variants(
  msg_type: glance.CustomType,
  update_fn: glance.Function,
) -> List(MsgVariant) {
  // Get the model parameter name (first param of update)
  let model_param = case update_fn.parameters {
    [first, ..] -> {
      case first.name {
        glance.Named(name) -> name
        glance.Discarded(_) -> "model"
      }
    }
    _ -> "model"
  }

  // Extract variant names from the Msg type
  let variant_names =
    list.map(msg_type.variants, fn(variant) { variant.name })

  // Try to analyze the case expression in update
  let case_arms = extract_case_arms(update_fn)

  // For each variant, check if its case arm modifies the model
  list.map(variant_names, fn(name) {
    let affects = case find_arm_for_variant(case_arms, name) {
      Ok(body) -> body_modifies_model(body, model_param)
      Error(Nil) -> True
    }
    MsgVariant(name: name, affects_model: affects)
  })
}

/// Extract case arms from the update function body.
/// Looks for a top-level `case msg { ... }` expression.
fn extract_case_arms(
  func: glance.Function,
) -> List(glance.Clause) {
  case func.body {
    [glance.Expression(glance.Case(clauses: clauses, ..))] -> clauses
    _ -> []
  }
}

/// Find the case arm that matches a specific variant name.
fn find_arm_for_variant(
  arms: List(glance.Clause),
  variant_name: String,
) -> Result(glance.Expression, Nil) {
  list.find_map(arms, fn(clause) {
    // Check if any pattern in this clause matches the variant
    let matches =
      list.any(clause.patterns, fn(pattern_group) {
        list.any(pattern_group, fn(pattern) {
          pattern_matches_variant(pattern, variant_name)
        })
      })
    case matches {
      True -> Ok(clause.body)
      False -> Error(Nil)
    }
  })
}

/// Check if a pattern matches a specific variant name.
fn pattern_matches_variant(
  pattern: glance.Pattern,
  variant_name: String,
) -> Bool {
  case pattern {
    glance.PatternVariant(constructor: ctor, ..) -> ctor == variant_name
    _ -> False
  }
}

/// Check if a case arm body modifies the model parameter.
/// Heuristic: if the body constructs a new Model (contains "Model(" or
/// a record update "Model(..") it modifies the model.
/// If it just returns the model variable unchanged, it doesn't.
fn body_modifies_model(
  body: glance.Expression,
  model_param: String,
) -> Bool {
  case body {
    // #(Model(..model, ...), local) — tuple with model constructor
    glance.Tuple(elements: [first, ..], ..) ->
      expression_constructs_new(first, model_param)
    // Model(..model, ...) — direct model constructor (simple update)
    glance.Call(function: glance.Variable(name: name, ..), ..)
      if name != model_param
    -> True
    // Just returning the model variable unchanged
    glance.Variable(name: name, ..) if name == model_param -> False
    // Anything else — assume it modifies (conservative)
    _ -> True
  }
}

/// Check if an expression constructs a new value (not just passing through the variable).
fn expression_constructs_new(
  expr: glance.Expression,
  model_param: String,
) -> Bool {
  case expr {
    // Variable reference to model → unchanged
    glance.Variable(name: name, ..) if name == model_param -> False
    // Anything else (constructor, function call, etc.) → new value
    _ -> True
  }
}
