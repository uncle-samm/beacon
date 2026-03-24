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
import beacon/route
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
    /// If None, uses the handler registry (automatic via on_click/on_input).
    decode_event: Option(fn(String, String, String, String) ->
      Result(msg, error.BeaconError)),
    /// Secret key for session tokens.
    secret_key: String,
    /// Application title (used in SSR HTML).
    title: String,
    /// Serialize model to string for session token (None = disabled).
    serialize_model: Option(fn(model) -> String),
    /// Deserialize model from string (None = disabled).
    deserialize_model: Option(fn(String) -> Result(model, String)),
    /// PubSub topics each per-connection runtime subscribes to.
    /// Middleware pipeline (applied to all HTTP requests).
    middlewares: List(middleware.Middleware),
    /// Static file serving directory (e.g., "priv/static").
    static_dir: Option(String),
    /// Route patterns for URL matching.
    route_patterns: List(route.RoutePattern),
    /// Called when URL changes — produces a Msg for the update loop.
    on_route_change: Option(fn(route.Route) -> msg),
    /// Dynamic subscription function: model → list of topics.
    dynamic_subscriptions: Option(fn(model) -> List(String)),
    /// Topic-aware notification handler for dynamic subscriptions.
    on_notify: Option(fn(String) -> msg),
    /// Configurable security limits for the transport layer.
    security_limits: transport.SecurityLimits,
    /// Optional: extra HTML to inject into `<head>` (stylesheets, meta tags, etc.).
    /// Example: `Some("<link rel=\"stylesheet\" href=\"/static/styles.css\">")`
    head_html: Option(String),
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
/// - Transport (HTTP + WebSocket via beacon/transport/server)
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

  // SSR rendering: route-aware (per-request) or static (pre-rendered once)
  let ssr_config =
    ssr.SsrConfig(
      init: config.init,
      view: config.view,
      secret_key: config.secret_key,
      title: config.title,
      head_html: config.head_html,
    )

  // When routes are configured, render per-request so each URL gets
  // route-specific HTML (e.g. /login renders the login page).
  // Otherwise, pre-render once at startup.
  let #(page_html, ssr_factory) = case
    config.route_patterns,
    config.on_route_change
  {
    [_, ..], Some(_) -> {
      log.info("beacon.application", "Route-aware SSR enabled")
      let factory = fn(path: String) {
        let page =
          ssr.render_page_for_path(
            ssr_config,
            path,
            config.route_patterns,
            config.on_route_change,
            config.update,
          )
        page.html
      }
      #(None, Some(factory))
    }
    _, _ -> {
      let page = ssr.render_page(ssr_config)
      log.info("beacon.application", "SSR page rendered (static)")
      #(Some(page.html), None)
    }
  }

  // Per-connection runtime: each WebSocket gets its own runtime process
  let runtime_config =
    runtime.RuntimeConfig(
      init: config.init,
      update: config.update,
      view: config.view,
      decode_event: config.decode_event,
      serialize_model: config.serialize_model,
      deserialize_model: config.deserialize_model,
      route_patterns: config.route_patterns,
      on_route_change: config.on_route_change,
      dynamic_subscriptions: config.dynamic_subscriptions,
      on_notify: config.on_notify,
    )

  // Create transport with per-connection runtime factory
  let base_transport_config =
    runtime.connect_transport_per_connection(
      runtime_config,
      config.port,
      page_html,
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
      security_limits: config.security_limits,
      ssr_factory: ssr_factory,
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
  // Trap exit signals for graceful shutdown
  trap_exit()
  wait_for_shutdown()
}

/// Wait for shutdown signal, then drain connections.
fn wait_for_shutdown() -> Nil {
  case receive_shutdown_signal(60_000) {
    True -> {
      log.info("beacon.application", "Shutdown signal received, draining connections...")
      // Give in-flight requests time to complete
      let timeout = shutdown_timeout()
      log.info(
        "beacon.application",
        "Draining for " <> int.to_string(timeout) <> "ms...",
      )
      process.sleep(timeout)
      log.info("beacon.application", "Shutdown complete.")
    }
    False -> wait_for_shutdown()
  }
}

/// Get shutdown timeout from env or default 5 seconds.
fn shutdown_timeout() -> Int {
  case get_env_int("BEACON_SHUTDOWN_TIMEOUT") {
    Ok(ms) -> ms
    Error(reason) -> {
      log.debug("beacon.application", "BEACON_SHUTDOWN_TIMEOUT not set: " <> reason <> ", using 5000ms")
      5000
    }
  }
}

@external(erlang, "beacon_application_ffi", "trap_exit")
fn trap_exit() -> Nil

@external(erlang, "beacon_application_ffi", "receive_shutdown_signal")
fn receive_shutdown_signal(timeout: Int) -> Bool

@external(erlang, "beacon_application_ffi", "get_env_int")
fn get_env_int(name: String) -> Result(Int, String)
