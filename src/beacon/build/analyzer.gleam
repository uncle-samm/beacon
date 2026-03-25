/// Glance-based code analyzer for the build tool.
/// Parses user source code and classifies Msg variants.
/// Also validates purity and extracts pure code for JS compilation.

import beacon/log
import glance
import gleam/list
import gleam/option
import gleam/string

/// A field in a Model or Local type.
pub type TypeField {
  TypeField(
    /// The field name (e.g., "count").
    name: String,
    /// The field type name (e.g., "Int", "String", "Bool", "List").
    type_name: String,
    /// For generic types like List(Stroke), the inner type name.
    inner_type: String,
    /// Module qualifier for the type (e.g., "auth" for auth.AuthState). Empty = local.
    module: String,
    /// Module qualifier for the inner type (e.g., "card" for List(card.Card)). Empty = local.
    inner_module: String,
  )
}

/// A custom type with its fields (for JSON codec generation).
pub type CustomTypeInfo {
  CustomTypeInfo(
    /// The type name (e.g., "Stroke").
    name: String,
    /// The type's fields.
    fields: List(TypeField),
    /// Module this type comes from (e.g., "auth"). Empty = local to the app module.
    module: String,
  )
}

/// A substate — a Model field whose type is a custom record type.
/// The framework tracks and diffs these independently for efficiency.
/// When a substate's JSON hasn't changed, its diff is skipped entirely.
pub type SubstateInfo {
  SubstateInfo(
    /// The field name in Model (e.g., "cards").
    field_name: String,
    /// The type name (e.g., "Card" for List(Card), or "Settings" for Settings).
    type_name: String,
    /// Whether this is a List of the type (true) or a single instance (false).
    is_list: Bool,
    /// Module this type comes from (e.g., "auth"). Empty = local.
    module: String,
  )
}

/// An enum type — custom type with multiple variants, no fields (e.g., Column { Todo; Doing; Done }).
/// Encoded as strings in JSON, decoded back to the enum type.
pub type EnumTypeInfo {
  EnumTypeInfo(
    /// The type name (e.g., "Column").
    name: String,
    /// The variant names (e.g., ["Todo", "Doing", "Done"]).
    variants: List(String),
    /// Module this type comes from (e.g., "auth"). Empty = local.
    module: String,
  )
}

/// A computed field — a server-side derived value from Model.
/// Detected automatically: public functions with signature fn(Model) -> T.
/// Computed values are included in model_sync JSON but NOT in client encode_model.
pub type ComputedField {
  ComputedField(
    /// The function name (e.g., "subtotal", "total").
    name: String,
    /// The return type name (e.g., "Int", "String", "Float", "Bool").
    return_type: String,
  )
}

/// An imported module resolved from user source imports.
pub type ImportedModule {
  ImportedModule(
    /// The module path as used in the import (e.g., "domains/auth").
    module_path: String,
    /// The alias used to reference it (e.g., "auth" for `import domains/auth`).
    alias: String,
  )
}

/// Result of analyzing a user's app module.
pub type Analysis {
  Analysis(
    /// All Msg type variants with their classification.
    msg_variants: List(MsgVariant),
    /// Whether the module has a Local type.
    has_local: Bool,
    /// Whether the module has a Server type (private server-side state).
    has_server: Bool,
    /// Module alias of the Server type (empty string if in primary file, e.g. "server_state").
    server_module: String,
    /// Type name of the Server type (e.g. "Server" or "ServerState").
    server_type_name: String,
    /// Fields of the Server type (never sent to client).
    server_fields: List(TypeField),
    /// Fields of the Model type (for JSON codec generation).
    model_fields: List(TypeField),
    /// Whether the module has a direct `pub fn init` (vs make_init factory).
    has_direct_init: Bool,
    /// Whether the module has a direct `pub fn update` (vs make_update factory).
    has_direct_update: Bool,
    /// All custom types found in the module (for nested decoder generation).
    custom_types: List(CustomTypeInfo),
    /// Enum types — custom types with multiple variants, no fields.
    enum_types: List(EnumTypeInfo),
    /// Substates — Model fields that are custom record types, tracked independently.
    substates: List(SubstateInfo),
    /// Computed fields — @computed pub fn functions, server-side derived values.
    computed_fields: List(ComputedField),
    /// External modules imported by the user app (for multi-file analysis).
    imported_modules: List(ImportedModule),
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

      // Check for Server type (private server-side state)
      let #(has_server, server_module_alias, server_type_name, server_fields) =
        case find_custom_type(module, "Server") {
          Ok(server_type) -> #(True, "", "Server", extract_fields(server_type))
          Error(_) -> #(False, "", "Server", [])
        }

      // Extract Model fields for JSON codec generation
      let model_fields = case find_custom_type(module, "Model") {
        Ok(model_type) -> extract_fields(model_type)
        Error(_) -> {
          log.debug(
            "beacon.analyzer",
            "No Model type found — this module may not be an app component",
          )
          []
        }
      }

      // Extract ALL custom types for nested decoder generation
      let custom_types =
        list.filter_map(module.custom_types, fn(def) {
          let name = def.definition.name
          // Skip Model, Local, Msg, Server — we handle those specially
          case name == "Model" || name == "Local" || name == "Msg" || name == "Server" {
            True -> Error(Nil)
            False -> {
              let fields = extract_fields(def.definition)
              case fields {
                [] -> Error(Nil)
                _ -> Ok(CustomTypeInfo(name: name, fields: fields, module: ""))
              }
            }
          }
        })

      // Extract enum types (multiple variants, no fields — e.g., Column { Todo; Doing; Done })
      let enum_types =
        list.filter_map(module.custom_types, fn(def) {
          let ct = def.definition
          // Skip Model, Local, Msg
          case ct.name == "Model" || ct.name == "Local" || ct.name == "Msg" {
            True -> Error(Nil)
            False -> {
              // An enum type has multiple variants, ALL with zero fields
              let all_fieldless =
                list.all(ct.variants, fn(v) {
                  list.is_empty(v.fields)
                })
              case all_fieldless && list.length(ct.variants) >= 2 {
                True -> {
                  let variant_names = list.map(ct.variants, fn(v) { v.name })
                  Ok(EnumTypeInfo(
                    name: ct.name,
                    variants: variant_names,
                    module: "",
                  ))
                }
                False -> Error(Nil)
              }
            }
          }
        })

      // Detect substates: Model fields whose types are custom record types.
      // These are tracked independently for efficient per-substate diffing.
      let substates =
        list.filter_map(model_fields, fn(f) {
          case f.type_name {
            "List" ->
              case
                list.find(custom_types, fn(ct) {
                  ct.name == f.inner_type && ct.module == f.inner_module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.inner_type,
                    is_list: True,
                    module: f.inner_module,
                  ))
                Error(_) -> Error(Nil)
              }
            _ ->
              case
                list.find(custom_types, fn(ct) {
                  ct.name == f.type_name && ct.module == f.module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.type_name,
                    is_list: False,
                    module: f.module,
                  ))
                Error(_) -> Error(Nil)
              }
          }
        })

      // Detect computed fields — pub fn that takes exactly 1 param of type Model
      // and returns a known type. Excludes view (returns Node), update (takes 2+ params),
      // init (takes 0 params), and server_only_functions.
      let computed_excluded = ["view", "init", "init_local", "init_server",
        "update", "start", "main", "on_update", "make_update", "make_init",
        "make_on_update"]
      let computed_fields =
        list.filter_map(module.functions, fn(def) {
          let func = def.definition
          // Must be public
          case func.publicity {
            glance.Public -> {
              // Must not be in excluded list
              case list.contains(computed_excluded, func.name) {
                True -> Error(Nil)
                False -> {
                  // Must take exactly 1 parameter of type Model
                  case func.parameters {
                    [glance.FunctionParameter(type_: option.Some(glance.NamedType(name: "Model", ..)), ..)] -> {
                      // Extract return type — must not be Node (that's view)
                      let return_type = case func.return {
                        option.Some(glance.NamedType(name: name, ..)) ->
                          case name {
                            // Node return = view-like, not computed
                            "Node" -> Error(Nil)
                            _ -> Ok(name)
                          }
                        _ -> Ok("String")
                      }
                      case return_type {
                        Ok(rt) -> Ok(ComputedField(name: func.name, return_type: rt))
                        Error(Nil) -> Error(Nil)
                      }
                    }
                    _ -> Error(Nil)
                  }
                }
              }
            }
            _ -> Error(Nil)
          }
        })

      // Classify Msg variants if both Msg type and update function are present.
      // When either is missing (multi-file apps where Msg/update are in separate files),
      // succeed with empty msg_variants — the codec only needs Model fields.
      let variants = case msg_type, update_fn {
        Ok(msg), Ok(func) -> classify_variants(msg, func)
        _, _ -> {
          log.debug(
            "beacon.analyzer",
            "No Msg type or update function in this file — codec-only analysis",
          )
          []
        }
      }
      Ok(Analysis(
        msg_variants: variants,
        has_local: has_local,
        has_server: has_server,
        server_module: server_module_alias,
        server_type_name: server_type_name,
        server_fields: server_fields,
        model_fields: model_fields,
        has_direct_init: has_direct_init,
        has_direct_update: has_direct_update,
        custom_types: custom_types,
        enum_types: enum_types,
        substates: substates,
        computed_fields: computed_fields,
        imported_modules: [],
      ))
    }
    Error(_) -> Error("Failed to parse source")
  }
}

/// Analyze a multi-file app: main source + external module sources.
/// Each external source is a #(alias, module_path, source_text) triple where:
/// - alias is the module qualifier (e.g., "auth" for `import domains/auth`)
/// - module_path is the import path (e.g., "domains/auth")
/// - source_text is the file contents
/// Extracts types from external modules and merges them into the analysis.
pub fn analyze_multi(
  source: String,
  external_sources: List(#(String, String, String)),
) -> Result(Analysis, String) {
  case analyze(source) {
    Error(reason) -> Error(reason)
    Ok(analysis) -> {
      // Parse each external source and extract types tagged with the module alias
      let #(ext_custom_types, ext_enum_types, imported_modules) =
        list.fold(external_sources, #([], [], []), fn(acc, ext) {
          let #(alias, module_path, ext_source) = ext
          case glance.module(ext_source) {
            Error(_) -> acc
            Ok(ext_module) -> {
              let #(cts, ets, ims) = acc
              let im =
                ImportedModule(
                  module_path: module_path,
                  alias: alias,
                )
              let ext_cts =
                list.filter_map(ext_module.custom_types, fn(def) {
                  let ct = def.definition
                  // Skip non-public types
                  case ct.publicity {
                    glance.Public -> {
                      let fields = extract_fields(ct)
                      case fields {
                        [] -> Error(Nil)
                        _ ->
                          Ok(CustomTypeInfo(
                            name: ct.name,
                            fields: fields,
                            module: alias,
                          ))
                      }
                    }
                    _ -> Error(Nil)
                  }
                })
              let ext_ets =
                list.filter_map(ext_module.custom_types, fn(def) {
                  let ct = def.definition
                  case ct.publicity {
                    glance.Public -> {
                      let all_fieldless =
                        list.all(ct.variants, fn(v) {
                          list.is_empty(v.fields)
                        })
                      case all_fieldless && list.length(ct.variants) >= 2 {
                        True -> {
                          let variant_names =
                            list.map(ct.variants, fn(v) { v.name })
                          Ok(EnumTypeInfo(
                            name: ct.name,
                            variants: variant_names,
                            module: alias,
                          ))
                        }
                        False -> Error(Nil)
                      }
                    }
                    _ -> Error(Nil)
                  }
                })
              #(
                list.append(cts, ext_cts),
                list.append(ets, ext_ets),
                [im, ..ims],
              )
            }
          }
        })

      // Merge external types into analysis
      let all_custom_types =
        list.append(analysis.custom_types, ext_custom_types)
      let all_enum_types = list.append(analysis.enum_types, ext_enum_types)

      // Re-detect substates with the full type set (including external types)
      let substates =
        list.filter_map(analysis.model_fields, fn(f) {
          case f.type_name {
            "List" ->
              case
                list.find(all_custom_types, fn(ct) {
                  ct.name == f.inner_type && ct.module == f.inner_module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.inner_type,
                    is_list: True,
                    module: f.inner_module,
                  ))
                Error(_) -> Error(Nil)
              }
            _ ->
              case
                list.find(all_custom_types, fn(ct) {
                  ct.name == f.type_name && ct.module == f.module
                })
              {
                Ok(_) ->
                  Ok(SubstateInfo(
                    field_name: f.name,
                    type_name: f.type_name,
                    is_list: False,
                    module: f.module,
                  ))
                Error(_) -> Error(Nil)
              }
          }
        })

      // Check external sources for Server type (multi-file apps may have it in a separate module)
      let #(has_server, server_module_alias, server_type_name, server_fields) =
        case analysis.has_server {
          True -> #(True, analysis.server_module, analysis.server_type_name, analysis.server_fields)
          False -> {
          // Search external modules for a type named "Server" or "ServerState"
          let ext_server =
            list.find_map(external_sources, fn(ext) {
              let #(alias, _module_path, ext_source) = ext
              case glance.module(ext_source) {
                Error(_) -> Error(Nil)
                Ok(ext_module) -> {
                  // Look for Server or ServerState type
                  let server_type =
                    list.find(ext_module.custom_types, fn(def) {
                      let name = def.definition.name
                      { name == "Server" || name == "ServerState" }
                      && def.definition.publicity == glance.Public
                    })
                  case server_type {
                    Ok(def) ->
                      Ok(#(alias, def.definition.name, extract_fields(def.definition)))
                    Error(Nil) -> Error(Nil)
                  }
                }
              }
            })
          case ext_server {
            Ok(#(srv_alias, srv_type_name, fields)) -> {
              log.info(
                "beacon.analyzer",
                "Found " <> srv_type_name <> " type in external module: " <> srv_alias,
              )
              #(True, srv_alias, srv_type_name, fields)
            }
            Error(Nil) -> #(False, "", "Server", [])
          }
        }
      }

      Ok(Analysis(
        ..analysis,
        has_server: has_server,
        server_module: server_module_alias,
        server_type_name: server_type_name,
        server_fields: server_fields,
        custom_types: all_custom_types,
        enum_types: all_enum_types,
        substates: substates,
        imported_modules: imported_modules,
      ))
    }
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
            let #(type_name, inner, mod_val, inner_mod_val) = case field_type {
              glance.NamedType(name: n, module: mod, parameters: params, ..) ->
                case params {
                  [glance.NamedType(name: inner_name, module: inner_mod, ..)] -> {
                    let m = case mod {
                      option.Some(m) -> m
                      option.None -> {
                        log.debug("beacon.build.analyzer", "No module qualifier for type field '" <> name <> "'")
                        ""
                      }
                    }
                    let im = case inner_mod {
                      option.Some(im) -> im
                      option.None -> {
                        log.debug("beacon.build.analyzer", "No inner module qualifier for type field '" <> name <> "'")
                        ""
                      }
                    }
                    #(n, inner_name, m, im)
                  }
                  _ -> {
                    let m = case mod {
                      option.Some(m) -> m
                      option.None -> {
                        log.debug("beacon.build.analyzer", "No module qualifier for type field '" <> name <> "'")
                        ""
                      }
                    }
                    #(n, "", m, "")
                  }
                }
              _ -> #("Unknown", "", "", "")
            }
            Ok(TypeField(
              name: name,
              type_name: type_name,
              inner_type: inner,
              module: mod_val,
              inner_module: inner_mod_val,
            ))
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
    // Block { let x = ...; #(model, local) } — check last statement
    glance.Block(statements: stmts, ..) ->
      case last_expression(stmts) {
        Ok(last) -> body_modifies_model(last, model_param)
        Error(Nil) -> True
      }
    // case x { ... } — check if ALL arms don't modify model
    glance.Case(clauses: clauses, ..) ->
      list.any(clauses, fn(clause) {
        body_modifies_model(clause.body, model_param)
      })
    // Anything else — assume it modifies (conservative)
    _ -> True
  }
}

/// Get the last Expression from a list of Statements.
fn last_expression(stmts: List(glance.Statement)) -> Result(glance.Expression, Nil) {
  case list.last(stmts) {
    Ok(glance.Expression(expr)) -> Ok(expr)
    _ -> Error(Nil)
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

// ===== Purity Validation =====
// Walks the Glance AST to verify a module is safe to compile to JavaScript.
// No regex — all checks are proper AST analysis.

/// A purity violation found during AST analysis.
pub type PurityError {
  /// Module imports a server-only module.
  ServerImport(module_path: String)
  /// Function has @external(erlang, ...) annotation.
  ErlangExternal(function_name: String)
}

/// Validate that a source module is pure Gleam (safe to compile to JS).
/// Walks the Glance AST — no regex, no string matching on source.
///
/// Returns Ok(Nil) if the module is pure, or Error with a clear message.
pub fn validate_purity(source: String) -> Result(Nil, String) {
  case glance.module(source) {
    Error(_) -> Error("Failed to parse source for purity validation")
    Ok(module) -> {
      let errors = find_purity_errors(module)
      case errors {
        [] -> Ok(Nil)
        _ -> Error(format_purity_errors(errors))
      }
    }
  }
}

/// Walk the AST and collect all purity violations.
fn find_purity_errors(module: glance.Module) -> List(PurityError) {
  let import_errors = check_imports(module)
  let external_errors = check_externals(module)
  list.append(import_errors, external_errors)
}

/// Check all imports for server-only modules.
fn check_imports(module: glance.Module) -> List(PurityError) {
  list.filter_map(module.imports, fn(def) {
    let import_ = def.definition
    case is_server_only_import(import_.module) {
      True -> Ok(ServerImport(module_path: import_.module))
      False -> Error(Nil)
    }
  })
}

/// Check if an import is safe for JS compilation.
/// Uses an allowlist — only known-pure modules are kept.
fn is_server_only_import(module_path: String) -> Bool {
  !is_safe_import(module_path)
}

/// Allowlist of imports safe for JS compilation.
fn is_safe_import(module_path: String) -> Bool {
  // Known server-only modules — explicit blocklist
  case is_known_server_import(module_path) {
    True -> False
    False ->
      // beacon framework modules that are pure Gleam
      module_path == "beacon"
      || module_path == "beacon/html"
      || module_path == "beacon/element"
      // gleam stdlib — all pure (except erlang/otp, caught above)
      || string.starts_with(module_path, "gleam/")
      // User domain modules — assumed pure (will be validated individually)
      || is_user_module(module_path)
  }
}

/// Check if a module path is a known server-only import.
fn is_known_server_import(module_path: String) -> Bool {
  string.starts_with(module_path, "gleam/erlang")
  || string.starts_with(module_path, "gleam/otp")
  || string.starts_with(module_path, "gleam/http")
  || module_path == "mist"
  || string.starts_with(module_path, "mist/")
  || { string.starts_with(module_path, "beacon/")
  && module_path != "beacon/html"
  && module_path != "beacon/element" }
}

/// Check if a module path looks like a user-defined module.
/// User modules don't start with known framework/stdlib prefixes.
fn is_user_module(module_path: String) -> Bool {
  !string.starts_with(module_path, "gleam/")
  && !string.starts_with(module_path, "beacon")
  && !string.starts_with(module_path, "mist")
  && !string.starts_with(module_path, "wisp")
  && !string.starts_with(module_path, "simplifile")
  && !string.starts_with(module_path, "glance")
}

/// Check all function definitions for @external(erlang, ...) annotations.
fn check_externals(module: glance.Module) -> List(PurityError) {
  list.filter_map(module.functions, fn(def) {
    let has_erlang_external =
      list.any(def.attributes, fn(attr) {
        case attr {
          glance.Attribute(name: "external", arguments: [first, ..]) ->
            is_erlang_target(first)
          _ -> False
        }
      })
    case has_erlang_external {
      True -> Ok(ErlangExternal(function_name: def.definition.name))
      False -> Error(Nil)
    }
  })
}

/// Check if an expression represents the "erlang" target atom.
fn is_erlang_target(expr: glance.Expression) -> Bool {
  case expr {
    glance.Variable(name: "erlang", ..) -> True
    glance.String(value: "erlang", ..) -> True
    _ -> False
  }
}

/// Format purity errors into a clear, actionable message.
fn format_purity_errors(errors: List(PurityError)) -> String {
  let messages =
    list.map(errors, fn(err) {
      case err {
        ServerImport(path) ->
          "  - imports server-only module '" <> path <> "'"
        ErlangExternal(name) ->
          "  - function '" <> name <> "' has @external(erlang, ...) annotation"
      }
    })
  "Module is not pure Gleam (cannot compile to JS for LOCAL events):\n"
  <> string.join(messages, "\n")
  <> "\n\nTo fix: move server-only code (stores, effects, PubSub) to on_update()."
}

// ===== AST Extraction + Source Emission =====
// Extracts pure types/functions from user source using Glance AST byte offsets.
// No source reconstruction — slices original source text using Span positions.
// This preserves exact formatting and is reliable without glance_printer.

/// Names of server-only functions to skip during extraction.
/// For state-over-the-wire, the client only needs view + types + helpers.
/// update runs on the server — not compiled to JS.
const server_only_functions = [
  "start", "main", "on_update", "make_update", "make_init",
  "make_on_update", "init_server",
]

/// Names of functions that MUST be extracted even if they reference server code.
/// view is always needed. init/init_local may fail to compile if they use
/// server-only code — the entry point generates stubs for those.
const always_extract_functions = [
  "view", "init_local",
]

/// Extract pure client code from a source module.
/// Returns the extracted Gleam source string containing only:
/// - Safe imports (beacon, beacon/html, beacon/element, gleam/*)
/// - All type definitions (Model, Local, Msg, custom types)
/// - Pure functions (init, init_local, update, view, helpers)
///
/// Skips: server-only imports, @external(erlang) functions, start/main/on_update.
/// The source must pass validate_purity() first.
pub fn extract_client_source(source: String) -> Result(String, String) {
  case glance.module(source) {
    Error(_) -> Error("Failed to parse source for extraction")
    Ok(module) -> {
      let source_bytes = string_to_bytes(source)

      // Collect safe imports
      let import_texts =
        list.filter_map(module.imports, fn(def) {
          let import_ = def.definition
          case is_server_only_import(import_.module) {
            True -> Error(Nil)
            False -> Ok(slice_source(source_bytes, import_.location))
          }
        })

      // Collect all type definitions (Model, Local, Msg, custom types)
      // Exclude Server type — it is private server-side state, never sent to client
      let type_texts =
        list.filter_map(module.custom_types, fn(def) {
          case def.definition.name == "Server" {
            True -> Error(Nil)
            False -> Ok(slice_source(source_bytes, def.definition.location))
          }
        })

      // Collect type aliases
      let alias_texts =
        list.map(module.type_aliases, fn(def) {
          slice_source(source_bytes, def.definition.location)
        })

      // Collect pure functions (skip server-only, skip @external(erlang),
      // skip functions that reference server-only APIs in their body)
      let function_texts =
        list.filter_map(module.functions, fn(def) {
          let func = def.definition
          // Skip server-only functions by name
          case list.contains(server_only_functions, func.name) {
            True -> Error(Nil)
            False -> {
              let func_text = slice_source(source_bytes, func.location)
              // Always extract view/init/init_local — client needs them
              case list.contains(always_extract_functions, func.name) {
                True -> Ok(func_text)
                False -> {
                  // Skip computed fields — pub fn(Model) -> T (not Node return)
                  let is_computed = case func.publicity, func.parameters {
                    glance.Public, [glance.FunctionParameter(type_: option.Some(glance.NamedType(name: "Model", ..)), ..)] ->
                      case func.return {
                        option.Some(glance.NamedType(name: "Node", ..)) -> False
                        _ -> True
                      }
                    _, _ -> False
                  }
                  case is_computed {
                    True -> Error(Nil)
                    False -> {
                      // Skip functions with @external(erlang) annotations
                      let has_erlang_external =
                        list.any(def.attributes, fn(attr) {
                          case attr {
                            glance.Attribute(name: "external", arguments: [first, ..]) ->
                              is_erlang_target(first)
                            _ -> False
                          }
                        })
                      case has_erlang_external {
                        True -> Error(Nil)
                        False ->
                          // Skip if the body references server-only modules
                          case function_references_server_code(func_text) {
                            True -> Error(Nil)
                            False -> Ok(func_text)
                          }
                      }
                    }
                  }
                }
              }
            }
          }
        })

      // Collect constants — filtered to prevent leaking server-side secrets.
      // Rules (in order):
      // 1. Skip if constant name starts with "server_" (server-only by convention)
      // 2. Skip if constant body references server-only modules
      // 3. Skip if constant is not referenced by any extracted function
      let constant_texts =
        list.filter_map(module.constants, fn(def) {
          let const_name = def.definition.name
          // Rule 1: skip server_ prefixed constants
          case string.starts_with(const_name, "server_") {
            True -> Error(Nil)
            False -> {
              let const_text = slice_source(source_bytes, def.definition.location)
              // Rule 2: skip if body references server-only code
              case function_references_server_code(const_text) {
                True -> Error(Nil)
                False -> {
                  // Rule 3: skip if not referenced by any extracted function
                  let is_referenced =
                    list.any(function_texts, fn(ft) {
                      string.contains(ft, const_name)
                    })
                  case is_referenced {
                    True -> Ok(const_text)
                    False -> Error(Nil)
                  }
                }
              }
            }
          }
        })

      // Assemble the client module
      let parts =
        list.flatten([
          import_texts,
          [""],
          type_texts,
          alias_texts,
          [""],
          constant_texts,
          [""],
          function_texts,
        ])
        |> list.filter(fn(s) { !string.is_empty(string.trim(s)) })

      Ok(string.join(parts, "\n\n"))
    }
  }
}

/// Check if a function body references server-only code.
/// Checks if the function text references any module that was skipped
/// from the safe imports list, or uses known server-only patterns.
fn function_references_server_code(func_text: String) -> Bool {
  // Check for common server-only module references
  string.contains(func_text, "store.")
  || string.contains(func_text, "effect.")
  || string.contains(func_text, "pubsub.")
  || string.contains(func_text, "process.")
  || string.contains(func_text, "mist.")
  || string.contains(func_text, "request.")
  || string.contains(func_text, "response.")
  || string.contains(func_text, "middleware.")
  || string.contains(func_text, "bytes_tree.")
  || string.contains(func_text, "message.user(")
  || string.contains(func_text, "message.assistant(")
  || string.contains(func_text, "agent.new(")
  || string.contains(func_text, "run.generate(")
  || string.contains(func_text, "run.stream(")
  || string.contains(func_text, "envoy.get(")
  || string.contains(func_text, "openrouter.")
  || string.contains(func_text, "Agent(")
  // Known server-only function calls
  || string.contains(func_text, "unique_int(")
  || string.contains(func_text, "abs_int(")
  || string.contains(func_text, "timer.sleep")
  || string.contains(func_text, "sleep(")
}

/// Slice a portion of the source using byte offsets from a Span.
fn slice_source(source_bytes: List(Int), span: glance.Span) -> String {
  let glance.Span(start: start, end: end) = span
  source_bytes
  |> list.drop(start)
  |> list.take(end - start)
  |> bytes_to_string()
}

/// Convert a string to a list of byte values.
/// We need this because Glance Span uses byte offsets, not character offsets.
@external(erlang, "beacon_build_ffi", "string_to_bytes")
fn string_to_bytes(s: String) -> List(Int)

/// Convert a list of byte values back to a string.
@external(erlang, "beacon_build_ffi", "bytes_to_string")
fn bytes_to_string(bytes: List(Int)) -> String
