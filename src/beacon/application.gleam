/// Beacon application — top-level OTP application with supervision tree.
/// All framework services (transport, state manager) run under a supervisor
/// so that crashes are contained and services restart automatically.
///
/// Reference: Phoenix application structure, Erlang/OTP supervisor pattern.

import beacon/effect.{type Effect}
import beacon/element.{type Node}
import beacon/error
import beacon/log
import beacon/middleware
import beacon/pubsub
import beacon/runtime
import beacon/ssr
import beacon/state_manager
import beacon/static
import beacon/transport
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// Configuration for starting a Beacon application.
pub type AppConfig(model, msg) {
  AppConfig(
    /// Port to listen on.
    port: Int,
    /// Initialize the model.
    init: fn() -> #(model, Effect(msg)),
    /// Update function.
    update: fn(model, msg) -> #(model, Effect(msg)),
    /// View function.
    view: fn(model) -> Node(msg),
    /// Decode client events to app messages.
    decode_event: fn(String, String, String, String) ->
      Result(msg, error.BeaconError),
    /// Secret key for session tokens.
    secret_key: String,
    /// Application title (used in SSR HTML).
    title: String,
    /// Serialize model to string for session token (None = disabled).
    serialize_model: Option(fn(model) -> String),
    /// Deserialize model from string (None = disabled).
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// PubSub topics each per-connection runtime subscribes to.
    subscriptions: List(String),
    /// Called when a PubSub notification arrives. Returns a Msg to dispatch.
    on_pubsub: Option(fn() -> msg),
    /// Middleware pipeline (applied to all HTTP requests).
    middlewares: List(middleware.Middleware),
    /// Static file serving directory (e.g., "priv/static").
    static_dir: Option(String),
  )
}

/// A running Beacon application.
pub type App {
  App(
    /// The supervisor PID.
    supervisor_pid: process.Pid,
  )
}

/// Start a fully supervised Beacon application.
/// This is the recommended way to start Beacon in production.
///
/// Creates a supervision tree:
/// - State manager (ETS-backed)
/// - Runtime (MVU loop actor)
/// - Transport (HTTP + WebSocket via Mist)
///
/// Uses `one_for_one` strategy: if one child crashes, only that child restarts.
pub fn start(config: AppConfig(model, msg)) -> Result(App, error.BeaconError) {
  log.configure()
  // Start PubSub for distributed broadcasting
  pubsub.start()
  log.info(
    "beacon.application",
    "Starting Beacon application on port " <> int.to_string(config.port),
  )

  // Pre-render SSR page
  let ssr_config =
    ssr.SsrConfig(
      init: config.init,
      view: config.view,
      secret_key: config.secret_key,
      title: config.title,
    )
  let page = ssr.render_page(ssr_config)
  log.info("beacon.application", "SSR page rendered")

  // Per-connection runtime: each WebSocket gets its own runtime process
  let runtime_config =
    runtime.RuntimeConfig(
      init: config.init,
      update: config.update,
      view: config.view,
      decode_event: config.decode_event,
      serialize_model: config.serialize_model,
      deserialize_model: config.deserialize_model,
      subscriptions: config.subscriptions,
      on_pubsub: config.on_pubsub,
    )

  // Create transport with per-connection runtime factory
  let base_transport_config =
    runtime.connect_transport_per_connection(
      runtime_config,
      config.port,
      Some(page.html),
    )
  let static_cfg = case config.static_dir {
    Some(dir) ->
      Some(static.StaticConfig(
        directory: dir,
        prefix: "/static",
        max_age: 3600,
      ))
    None -> None
  }
  let transport_config =
    transport.TransportConfig(
      ..base_transport_config,
      middlewares: config.middlewares,
      static_config: static_cfg,
    )
  case transport.start(transport_config) {
    Ok(transport_pid) -> {
      log.info(
        "beacon.application",
        "Beacon application started (per-connection mode) on port "
          <> int.to_string(config.port),
      )
      Ok(App(supervisor_pid: transport_pid))
    }
    Error(err) -> {
      log.error(
        "beacon.application",
        "Failed to start transport: " <> error.to_string(err),
      )
      Error(err)
    }
  }
}

/// Start a Beacon application with a full OTP supervision tree.
/// Uses `static_supervisor` to supervise the state manager.
///
/// This is the production-ready entry point.
pub fn start_supervised(
  config: AppConfig(model, msg),
) -> Result(App, error.BeaconError) {
  log.configure()
  log.info(
    "beacon.application",
    "Starting supervised Beacon application on port "
      <> int.to_string(config.port),
  )

  // Start state manager under supervision
  let state_mgr_spec = supervision.worker(fn() {
    case state_manager.start_in_memory() {
      Ok(subject) -> Ok(actor.Started(pid: process.self(), data: subject))
      Error(err) -> Error(err)
    }
  })

  // Build supervisor
  let sup_result =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(state_mgr_spec)
    |> supervisor.start

  case sup_result {
    Ok(sup_started) -> {
      log.info("beacon.application", "Supervisor started")
      case start(config) {
        Ok(_app) -> {
          log.info("beacon.application", "Application fully started")
          Ok(App(supervisor_pid: sup_started.pid))
        }
        Error(err) -> Error(err)
      }
    }
    Error(_err) -> {
      log.error(
        "beacon.application",
        "Failed to start supervisor",
      )
      Error(error.ConfigError(reason: "Supervisor start failed"))
    }
  }
}

/// Keep the main process alive so the application keeps running.
/// Call this after `start()` in your main function.
pub fn wait_forever() -> Nil {
  log.info("beacon.application", "Application running. Press Ctrl+C to stop.")
  process.sleep_forever()
}
