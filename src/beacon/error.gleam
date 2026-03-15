/// Beacon's error types module.
/// All errors carry enough context to diagnose failures without a debugger.
/// Per TigerBeetle approach: crash early with clear messages, never swallow errors.

/// Top-level error type for the Beacon framework.
/// Each variant carries contextual information about what went wrong and where.
pub type BeaconError {
  /// A WebSocket transport error occurred.
  TransportError(reason: String)

  /// Failed to encode or decode a message on the wire.
  CodecError(reason: String, raw: String)

  /// An error in the MVU runtime loop (init, update, or view).
  RuntimeError(reason: String)

  /// An error in the VDOM diff engine.
  DiffError(reason: String)

  /// An error during server-side rendering.
  RenderError(reason: String)

  /// A route matching or code generation error.
  RouterError(reason: String)

  /// An effect failed to execute.
  EffectError(reason: String)

  /// Session-related error (token expired, state not found, etc).
  SessionError(reason: String)

  /// Configuration or initialization error.
  ConfigError(reason: String)
}

/// Convert a BeaconError to a human-readable string for logging.
pub fn to_string(error: BeaconError) -> String {
  case error {
    TransportError(reason) -> "TransportError: " <> reason
    CodecError(reason, raw) ->
      "CodecError: " <> reason <> " (raw: " <> raw <> ")"
    RuntimeError(reason) -> "RuntimeError: " <> reason
    DiffError(reason) -> "DiffError: " <> reason
    RenderError(reason) -> "RenderError: " <> reason
    RouterError(reason) -> "RouterError: " <> reason
    EffectError(reason) -> "EffectError: " <> reason
    SessionError(reason) -> "SessionError: " <> reason
    ConfigError(reason) -> "ConfigError: " <> reason
  }
}
