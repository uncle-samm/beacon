/// Rendered struct — LiveView-style template representation.
/// Splits a rendered view into static parts (sent once) and dynamic parts
/// (sent on every update, only if changed).
///
/// Reference: LiveView's Rendered struct with static/dynamic splitting,
/// fingerprint-based change detection, and integer-keyed JSON wire format.

import gleam/crypto
import gleam/int
import gleam/json
import gleam/list

/// A rendered template split into static and dynamic parts.
pub type Rendered {
  Rendered(
    /// A fingerprint uniquely identifying the template structure.
    /// If fingerprints match between renders, only dynamic diffs are sent.
    fingerprint: Int,
    /// Static HTML strings that never change between renders.
    /// These are sent once on initial render.
    statics: List(String),
    /// Dynamic values that may change on each render.
    /// Indexed by position (0, 1, 2, ...).
    dynamics: List(String),
  )
}

/// Build a Rendered struct from a list of static/dynamic fragments.
/// A template like `<h1>{title}</h1><p>{body}</p>` becomes:
///   statics: ["<h1>", "</h1><p>", "</p>"]
///   dynamics: [title, body]
pub fn build(
  statics: List(String),
  dynamics: List(String),
) -> Rendered {
  let fingerprint = compute_fingerprint(statics)
  Rendered(fingerprint: fingerprint, statics: statics, dynamics: dynamics)
}

/// Compute a diff between an old and new Rendered struct.
/// If fingerprints match, returns only changed dynamic positions.
/// If fingerprints differ, returns the full new Rendered.
pub fn diff(old: Rendered, new: Rendered) -> RenderedDiff {
  case old.fingerprint == new.fingerprint {
    True -> {
      // Same template structure — find changed dynamic positions
      let changes = diff_dynamics(old.dynamics, new.dynamics, 0)
      case changes {
        [] -> NoDiff
        _ -> DynamicDiff(changes: changes)
      }
    }
    False -> {
      // Template structure changed — send full render
      FullRender(rendered: new)
    }
  }
}

/// The result of diffing two Rendered structs.
pub type RenderedDiff {
  /// Nothing changed.
  NoDiff
  /// Only some dynamic positions changed. Each entry is (index, new_value).
  DynamicDiff(changes: List(#(Int, String)))
  /// Template structure changed — full re-render needed.
  FullRender(rendered: Rendered)
}

/// Encode a Rendered struct to the initial mount JSON format.
/// Format: {"s": ["static1", "static2", ...], "0": "dynamic0", "1": "dynamic1", ...}
/// Reference: LiveView wire format.
pub fn to_mount_json(rendered: Rendered) -> json.Json {
  let statics_field = #("s", json.array(rendered.statics, json.string))
  let dynamic_fields =
    list.index_map(rendered.dynamics, fn(value, index) {
      #(int.to_string(index), json.string(value))
    })
  json.object([statics_field, ..dynamic_fields])
}

/// Encode a RenderedDiff to JSON for the wire.
/// For DynamicDiff: {"0": "new_value", "2": "other_new_value"}
/// For FullRender: same as to_mount_json
/// For NoDiff: empty object
pub fn diff_to_json(rendered_diff: RenderedDiff) -> json.Json {
  case rendered_diff {
    NoDiff -> json.object([])
    DynamicDiff(changes) -> {
      let fields =
        list.map(changes, fn(change) {
          let #(index, value) = change
          #(int.to_string(index), json.string(value))
        })
      json.object(fields)
    }
    FullRender(rendered) -> to_mount_json(rendered)
  }
}

/// Encode a RenderedDiff to a JSON string.
pub fn diff_to_json_string(rendered_diff: RenderedDiff) -> String {
  diff_to_json(rendered_diff) |> json.to_string
}

/// Reconstruct the full HTML from a Rendered struct by zipping statics and dynamics.
/// Reference: LiveView's Rendered.toString() in the client.
pub fn to_html(rendered: Rendered) -> String {
  zip_statics_dynamics(rendered.statics, rendered.dynamics, "")
}

// --- Internal ---

/// Compute a fingerprint from static template parts.
/// Uses a hash of concatenated statics to uniquely identify the template structure.
fn compute_fingerprint(statics: List(String)) -> Int {
  let combined = list.fold(statics, "", fn(acc, s) { acc <> "|" <> s })
  let hash =
    crypto.hash(crypto.Sha256, <<combined:utf8>>)
  // Take first 8 bytes as an integer for a compact fingerprint
  case hash {
    <<a:int-size(64), _rest:bits>> -> a
    _ -> 0
  }
}

/// Find dynamic positions that changed between old and new.
fn diff_dynamics(
  old: List(String),
  new: List(String),
  index: Int,
) -> List(#(Int, String)) {
  case old, new {
    [], [] -> []
    [old_val, ..old_rest], [new_val, ..new_rest] -> {
      case old_val == new_val {
        True -> diff_dynamics(old_rest, new_rest, index + 1)
        False -> [
          #(index, new_val),
          ..diff_dynamics(old_rest, new_rest, index + 1)
        ]
      }
    }
    // New has more dynamics — all are "changed"
    [], [new_val, ..new_rest] -> [
      #(index, new_val),
      ..diff_dynamics([], new_rest, index + 1)
    ]
    // Old has more dynamics — shouldn't happen if fingerprints match
    [_, ..old_rest], [] -> diff_dynamics(old_rest, [], index + 1)
  }
}

/// Zip static and dynamic parts into a single HTML string.
/// statics: ["<h1>", "</h1>"] dynamics: ["Hello"] → "<h1>Hello</h1>"
fn zip_statics_dynamics(
  statics: List(String),
  dynamics: List(String),
  acc: String,
) -> String {
  case statics, dynamics {
    [], [] -> acc
    [s], [] -> acc <> s
    [s, ..s_rest], [d, ..d_rest] ->
      zip_statics_dynamics(s_rest, d_rest, acc <> s <> d)
    [s, ..s_rest], [] -> zip_statics_dynamics(s_rest, [], acc <> s)
    [], [d, ..d_rest] -> zip_statics_dynamics([], d_rest, acc <> d)
  }
}
