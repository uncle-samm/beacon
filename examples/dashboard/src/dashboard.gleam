/// Live Dashboard — demonstrates:
/// - Server-push with effect.every() (no client events needed)
/// - Real BEAM runtime metrics via beacon/debug
/// - Auto-updating UI without any user interaction
/// - Sparkline rendering with SVG

import beacon
import beacon/debug
import beacon/effect
import beacon/html
import gleam/float
import gleam/int
import gleam/list

// --- Types ---

pub type Model {
  Model(
    process_count: Int,
    memory_mb: Float,
    uptime_seconds: Int,
    /// History for sparklines (last 30 samples)
    process_history: List(Int),
    memory_history: List(Float),
    tick_count: Int,
  )
}

pub type Msg {
  RefreshStats
}

const max_history = 30

// --- Init ---

pub fn init() -> #(Model, effect.Effect(Msg)) {
  let stats = debug.stats()
  #(
    Model(
      process_count: stats.process_count,
      memory_mb: int.to_float(stats.memory_bytes)
        /. 1_048_576.0,
      uptime_seconds: stats.uptime_seconds,
      process_history: [stats.process_count],
      memory_history: [
        int.to_float(stats.memory_bytes) /. 1_048_576.0,
      ],
      tick_count: 0,
    ),
    // Start server-push timer — refreshes every second
    effect.every(1000, fn() { RefreshStats }),
  )
}

// --- Update ---

pub fn update(
  model: Model,
  msg: Msg,
) -> #(Model, effect.Effect(Msg)) {
  case msg {
    RefreshStats -> {
      let stats = debug.stats()
      let mem = int.to_float(stats.memory_bytes) /. 1_048_576.0
      let proc_history =
        list.append(model.process_history, [stats.process_count])
        |> take_last(max_history)
      let mem_history =
        list.append(model.memory_history, [mem])
        |> take_last(max_history)
      #(
        Model(
          process_count: stats.process_count,
          memory_mb: mem,
          uptime_seconds: stats.uptime_seconds,
          process_history: proc_history,
          memory_history: mem_history,
          tick_count: model.tick_count + 1,
        ),
        effect.none(),
      )
    }
  }
}

fn take_last(items: List(a), n: Int) -> List(a) {
  let len = list.length(items)
  case len > n {
    True -> list.drop(items, len - n)
    False -> items
  }
}

// --- View ---

pub fn view(model: Model) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "font-family:system-ui;max-width:800px;margin:2rem auto;padding:0 1rem",
      ),
    ],
    [
      html.h1([], [html.text("Live Dashboard")]),
      html.p([html.style("color:#666")], [
        html.text(
          "Auto-refreshes every second — no client interaction needed. Tick #"
          <> int.to_string(model.tick_count),
        ),
      ]),
      // Metric cards
      html.div(
        [
          html.style(
            "display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin:1.5rem 0",
          ),
        ],
        [
          metric_card(
            "Processes",
            int.to_string(model.process_count),
            "#4CAF50",
          ),
          metric_card(
            "Memory",
            float_to_str(model.memory_mb, 1) <> " MB",
            "#2196F3",
          ),
          metric_card(
            "Uptime",
            format_uptime(model.uptime_seconds),
            "#FF9800",
          ),
        ],
      ),
      // Sparklines
      html.div([html.style("display:grid;grid-template-columns:1fr 1fr;gap:1rem")], [
        sparkline_card(
          "Process Count",
          model.process_history |> list.map(int.to_float),
          "#4CAF50",
        ),
        sparkline_card("Memory (MB)", model.memory_history, "#2196F3"),
      ]),
    ],
  )
}

fn metric_card(
  label: String,
  value: String,
  color: String,
) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "background:#f8f9fa;border-radius:8px;padding:1.5rem;border-left:4px solid "
        <> color,
      ),
    ],
    [
      html.div([html.style("color:#666;font-size:0.85rem;margin-bottom:0.5rem")], [
        html.text(label),
      ]),
      html.div([html.style("font-size:1.8rem;font-weight:bold;color:#333")], [
        html.text(value),
      ]),
    ],
  )
}

fn sparkline_card(
  label: String,
  values: List(Float),
  color: String,
) -> beacon.Node(Msg) {
  html.div(
    [
      html.style(
        "background:#f8f9fa;border-radius:8px;padding:1rem",
      ),
    ],
    [
      html.div([html.style("color:#666;font-size:0.85rem;margin-bottom:0.5rem")], [
        html.text(label),
      ]),
      render_sparkline(values, color, 350, 60),
    ],
  )
}

fn render_sparkline(
  values: List(Float),
  color: String,
  width: Int,
  height: Int,
) -> beacon.Node(Msg) {
  let w = int.to_string(width)
  let h = int.to_string(height)
  case values {
    [] | [_] ->
      html.element(
        "svg",
        [
          html.attribute("viewBox", "0 0 " <> w <> " " <> h),
          html.attribute("width", w),
          html.attribute("height", h),
        ],
        [],
      )
    _ -> {
      let min_val =
        list.fold(values, 999_999_999.0, fn(acc, v) {
          case v <. acc {
            True -> v
            False -> acc
          }
        })
      let max_val =
        list.fold(values, 0.0, fn(acc, v) {
          case v >. acc {
            True -> v
            False -> acc
          }
        })
      let range = case max_val -. min_val <. 1.0 {
        True -> 1.0
        False -> max_val -. min_val
      }
      let len = list.length(values)
      let step = int.to_float(width) /. int.to_float(len - 1)
      let points =
        list.index_map(values, fn(v, i) {
          let x = int.to_float(i) *. step
          let y =
            int.to_float(height)
            -. { { v -. min_val } /. range *. int.to_float(height - 4) }
            -. 2.0
          float_to_str(x, 1) <> "," <> float_to_str(y, 1)
        })
      let points_str = string_join(points, " ")
      html.element(
        "svg",
        [
          html.attribute("viewBox", "0 0 " <> w <> " " <> h),
          html.attribute("width", w),
          html.attribute("height", h),
        ],
        [
          html.element(
            "polyline",
            [
              html.attribute("points", points_str),
              html.attribute("fill", "none"),
              html.attribute("stroke", color),
              html.attribute("stroke-width", "2"),
            ],
            [],
          ),
        ],
      )
    }
  }
}

fn format_uptime(seconds: Int) -> String {
  let h = seconds / 3600
  let m = { seconds % 3600 } / 60
  let s = seconds % 60
  int.to_string(h)
  <> "h "
  <> int.to_string(m)
  <> "m "
  <> int.to_string(s)
  <> "s"
}

fn float_to_str(f: Float, _decimals: Int) -> String {
  let whole = float.truncate(f)
  let frac = float.truncate({ f -. int.to_float(whole) } *. 10.0)
  let frac = case frac < 0 {
    True -> -frac
    False -> frac
  }
  int.to_string(whole) <> "." <> int.to_string(frac)
}

fn string_join(items: List(String), sep: String) -> String {
  case items {
    [] -> ""
    [x] -> x
    [x, ..rest] -> x <> sep <> string_join(rest, sep)
  }
}

// --- Start ---

pub fn main() {
  start()
}

pub fn start() {
  beacon.app_with_effects(init, update, view)
  |> beacon.title("Live Dashboard")
  |> beacon.start(8080)
}
