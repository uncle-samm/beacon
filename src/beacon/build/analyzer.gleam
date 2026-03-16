/// Glance-based code analyzer for the build tool.
/// Parses user source code and classifies Msg variants.

import glance
import gleam/list

/// A field in a Model or Local type.
pub type TypeField {
  TypeField(
    /// The field name (e.g., "count").
    name: String,
    /// The field type name (e.g., "Int", "String", "Bool").
    type_name: String,
  )
}

/// Result of analyzing a user's app module.
pub type Analysis {
  Analysis(
    /// All Msg type variants with their classification.
    msg_variants: List(MsgVariant),
    /// Whether the module has a Local type.
    has_local: Bool,
    /// Fields of the Model type (for JSON codec generation).
    model_fields: List(TypeField),
    /// Whether the module has a direct `pub fn init` (vs make_init factory).
    has_direct_init: Bool,
    /// Whether the module has a direct `pub fn update` (vs make_update factory).
    has_direct_update: Bool,
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
      // Find update function (try "update" first, then "make_update")
      let has_direct_init = case find_function(module, "init") {
        Ok(_) -> True
        Error(_) -> False
      }
      let has_direct_update = case find_function(module, "update") {
        Ok(_) -> True
        Error(_) -> False
      }
      let update_fn = case find_function(module, "update") {
        Ok(f) -> Ok(f)
        Error(_) -> find_function(module, "make_update")
      }
      // Check for Local type
      let has_local = case find_custom_type(module, "Local") {
        Ok(_) -> True
        Error(_) -> False
      }

      // Extract Model fields for JSON codec generation
      let model_fields = case find_custom_type(module, "Model") {
        Ok(model_type) -> extract_fields(model_type)
        Error(_) -> []
      }

      case msg_type, update_fn {
        Ok(msg), Ok(func) -> {
          let variants = classify_variants(msg, func)
          Ok(Analysis(
            msg_variants: variants,
            has_local: has_local,
            model_fields: model_fields,
            has_direct_init: has_direct_init,
            has_direct_update: has_direct_update,
          ))
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

/// Extract labelled fields from a custom type's first variant.
fn extract_fields(custom_type: glance.CustomType) -> List(TypeField) {
  case custom_type.variants {
    [variant, ..] ->
      list.filter_map(variant.fields, fn(field) {
        case field {
          glance.LabelledVariantField(item: field_type, label: name) -> {
            let type_name = case field_type {
              glance.NamedType(name: n, ..) -> n
              _ -> "Unknown"
            }
            Ok(TypeField(name: name, type_name: type_name))
          }
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Classify each Msg variant based on the update function's case arms.
/// A variant affects the model if its case arm returns a modified model
/// (not just returning the input model unchanged).
fn classify_variants(
  msg_type: glance.CustomType,
  update_fn: glance.Function,
) -> List(MsgVariant) {
  // Get the model parameter name.
  // For direct update(model, local, msg), it's the first param.
  // For make_update(shared) -> fn(model, local, msg), it's the first param
  // of the INNER anonymous function.
  let model_param = case update_fn.body {
    // Factory pattern: body is fn(model, local, msg) { ... }
    [glance.Expression(glance.Fn(arguments: args, ..))] ->
      case args {
        [glance.FnParameter(name: glance.Named(name), ..), ..] -> name
        _ -> "model"
      }
    // Direct function: first param is model
    _ ->
      case update_fn.parameters {
        [first, ..] ->
          case first.name {
            glance.Named(name) -> name
            glance.Discarded(_) -> "model"
          }
        _ -> "model"
      }
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
/// Looks for a top-level `case msg { ... }` expression, or inside a nested
/// anonymous function (for make_update factory pattern).
fn extract_case_arms(
  func: glance.Function,
) -> List(glance.Clause) {
  case func.body {
    // Direct: pub fn update(...) { case msg { ... } }
    [glance.Expression(glance.Case(clauses: clauses, ..))] -> clauses
    // Factory: pub fn make_update(...) { fn(...) { case msg { ... } } }
    [glance.Expression(glance.Fn(body: body, ..))] ->
      case body {
        [glance.Expression(glance.Case(clauses: clauses, ..))] -> clauses
        _ -> []
      }
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
