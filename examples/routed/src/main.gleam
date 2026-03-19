/// Routed example — demonstrates file-based routing with beacon.router().
///
/// Route files:
///   src/routes/index.gleam       → /          (counter with state)
///   src/routes/about.gleam       → /about     (static page)
///   src/routes/settings.gleam    → /settings  (form with input)
///   src/routes/stats.gleam       → /stats     (state isolation demo)

import beacon

pub fn main() {
  beacon.router()
  |> beacon.router_title("Beacon Routed")
  |> beacon.start_router(8080)
}
