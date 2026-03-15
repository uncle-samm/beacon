import beacon/error

pub fn transport_error_to_string_test() {
  let err = error.TransportError("connection refused")
  let result = error.to_string(err)
  let assert "TransportError: connection refused" = result
}

pub fn codec_error_to_string_test() {
  let err = error.CodecError("invalid JSON", "{bad")
  let result = error.to_string(err)
  let assert "CodecError: invalid JSON (raw: {bad)" = result
}

pub fn runtime_error_to_string_test() {
  let err = error.RuntimeError("update function panicked")
  let result = error.to_string(err)
  let assert "RuntimeError: update function panicked" = result
}

pub fn diff_error_to_string_test() {
  let err = error.DiffError("mismatched tree depth")
  let result = error.to_string(err)
  let assert "DiffError: mismatched tree depth" = result
}

pub fn render_error_to_string_test() {
  let err = error.RenderError("element_to_string failed")
  let result = error.to_string(err)
  let assert "RenderError: element_to_string failed" = result
}

pub fn router_error_to_string_test() {
  let err = error.RouterError("no route matched /unknown")
  let result = error.to_string(err)
  let assert "RouterError: no route matched /unknown" = result
}

pub fn effect_error_to_string_test() {
  let err = error.EffectError("side effect timed out")
  let result = error.to_string(err)
  let assert "EffectError: side effect timed out" = result
}

pub fn session_error_to_string_test() {
  let err = error.SessionError("token expired")
  let result = error.to_string(err)
  let assert "SessionError: token expired" = result
}

pub fn config_error_to_string_test() {
  let err = error.ConfigError("missing SECRET_KEY")
  let result = error.to_string(err)
  let assert "ConfigError: missing SECRET_KEY" = result
}
