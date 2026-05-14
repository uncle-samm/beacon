# Testing

Run all tests: `gleam test`

## Unit Testing Update Functions

Test `update` as a pure function -- no framework needed:

```gleam
pub fn increment_test() {
  let model = Model(count: 0)
  let #(new_model, _effect) = update(model, Increment)
  let assert Model(count: 1) = new_model
}
```

## Runtime Tests

Start a runtime actor, connect a fake transport subject, send messages, verify responses:

```gleam
let assert Ok(subject) = runtime.start(counter_config())
let transport_subject = process.new_subject()
process.send(subject, runtime.ClientConnected(
  conn_id: "test", subject: transport_subject,
))
process.sleep(20)
process.send(subject, runtime.ClientJoined(conn_id: "test", token: "", path: "/"))
process.sleep(50)
let selector = process.new_selector() |> process.select(transport_subject)
let assert Ok(transport.SendModelSync(model_json: _, ..)) =
  process.selector_receive(selector, 500)
```

Send events with `runtime.ClientEventReceived` and check for `SendModelSync` or `SendPatch`. Regression tests must also assert that live join and normal post-mount updates do not send `SendMount`.

Client-sent `ops` are untrusted. Runtime tests should send malicious ops and assert the server-computed update wins.

## Transport Tests

Verify encode/decode round-trips for the wire protocol:

```gleam
pub fn decode_heartbeat_test() {
  let assert Ok(transport.ClientHeartbeat) =
    transport.decode_client_message("{\"type\":\"heartbeat\"}")
}
```

Security transport tests cover origin validation, rate limiting, WebSocket message/buffer caps, and HTTP pre-upgrade limits.

## Simulation Tests

Load test with real WebSocket connections using `beacon/sim`:

```gleam
let port = test_app.unique_port()
let assert Ok(_) = test_app.start_counter_app(port)
let mt = metrics.new()
let result = pool.run(pool.PoolConfig(
  concurrency: 100, host: "localhost", port: port,
  scenario: scenario.counter(20), stagger_ms: 5, metrics: mt,
))
report.assert_clean_passed(report.generate("test", result, ...))
```

Scenarios: `counter(n)`, `connect_disconnect()`, `malformed()`, `flood(n)`, `draw(n)`, `reconnect(n)`, `patch_efficiency(n)`, `server_push(ms)`, `corrupt()`.

## Stress Tests

`beacon/stress` opens real WebSocket connections and can send real join/event
frames on every connection. Use `events_per_connection` to test game-like or
high-frequency model traffic, not only idle socket capacity.

```gleam
stress.StressConfig(
  connections: 100,
  host: "localhost",
  port: 8080,
  hold_duration_ms: 1000,
  events_per_connection: 10,
)
```

Measured local baseline on May 8, 2026 with `examples/counter` running:

```sh
gleam run -m counter              # in examples/counter
gleam run -m beacon/stress        # in the repository root
```

Result: 100/100 WebSocket connections succeeded, 1,000 event frames attempted,
process count moved 44 -> 146 -> 46, memory delta was +1468KB, and final memory
was reported around 47MB.

## Example and CDP Tests (Browser)

End-to-end tests run through Chrome DevTools Protocol. The repeatable entrypoints are:

```sh
make browser-canonical  # contract examples, desktop + mobile
make browser-all        # every example slice in test_all_cdp.py
```

Use `make browser-canonical-desktop`, `make browser-canonical-mobile`,
`make browser-all-desktop`, or `make browser-all-mobile` for a narrower
viewport loop. You can also run one example directly:

```sh
PYTHONUNBUFFERED=1 .venv/bin/python test_all_cdp.py auth_workspace --viewport desktop
```

The full browser matrix supports deterministic sharding for container-level CI
parallelism:

```sh
BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_SHARD=1/4 make browser-all-shard
BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_SHARD=2/4 make browser-all-shard
BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_SHARD=3/4 make browser-all-shard
BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_SHARD=4/4 make browser-all-shard
```

Use separate containers for parallel shards so each shard can use the default
CDP and app ports inside its own network namespace. The local Docker runner
builds `Dockerfile.ci`, creates the project-local `.venv` in the image, and
runs one shard per container:

```sh
make browser-all-docker-shards
BEACON_CDP_TOTAL_SHARDS=23 BEACON_CDP_VIEWPORTS=desktop BEACON_CDP_PARALLEL=5 make browser-all-docker-shards
```

Useful Docker runner knobs:

- `BEACON_CDP_SHARDS="1,6,11"` runs a selected shard list from the configured
  total. This is intended for multi-VM runners.
- `BEACON_CDP_PREBUILD_EXAMPLES=1` bakes `gleam build` output for the root
  package and every example into `Dockerfile.ci`, avoiding per-shard first
  compile latency.
- `BEACON_CDP_SKIP_DOCKER_BUILD=1` reuses an existing image and fails if it is
  missing. Use this only for warmed images, such as forked Boxd workers.
- `BEACON_CDP_SERVER_TIMEOUT=90` controls the per-example startup timeout in
  seconds.

On the 10 CPU / 16 GB local development host, `BEACON_CDP_PARALLEL=5` is the
measured stable setting. Higher local concurrency was faster but not reliable:
10-way finished in 5:32 with shard failures, and 7-way finished in 7:29 with
server startup timeouts under host pressure. CI can still run one shard per job
because each job has its own runner/container budget.

For Boxd-style VM fanout, prepare one base VM by syncing the repo, then build a
warmed image once:

```sh
BEACON_CDP_DOCKER_IMAGE=beacon-cdp:boxd BEACON_CDP_PREBUILD_EXAMPLES=1 \
  BEACON_CDP_TOTAL_SHARDS=23 BEACON_CDP_SHARDS=1 BEACON_CDP_PARALLEL=1 \
  sh scripts/run_cdp_shards_docker.sh
```

Fork the warmed VM and run non-overlapping shard lists with
`BEACON_CDP_SKIP_DOCKER_BUILD=1`, for example:

```sh
BEACON_CDP_DOCKER_IMAGE=beacon-cdp:boxd BEACON_CDP_SKIP_DOCKER_BUILD=1 \
  BEACON_CDP_TOTAL_SHARDS=23 BEACON_CDP_SHARDS="1,6,11,16,21" \
  BEACON_CDP_PARALLEL=2 sh scripts/run_cdp_shards_docker.sh
```

The harness starts the app, opens the page, clicks controls, asserts DOM
content, verifies each example's `build/beacon_contract.json`, prints the
contract summary, records WebSocket frame types, tracks DOM mutation buckets,
catches console/runtime errors from document start, and fails when an attempted
example server dies or times out. Server shutdown is process-group scoped by
default so parallel shards do not kill unrelated `gleam run` processes; set
`BEACON_CDP_KILL_PORT=1` only when deliberately cleaning up a stuck local port.

Examples should double as integration coverage for counter, local-only state,
server-state privacy, multi-file apps, routed apps, auth/API/cookie flow, patch
resync, and large model/patch behavior.

Measured full-browser baseline on May 8, 2026 after regenerating all example
bundles:

```sh
BEACON_CDP_VIEWPORTS=desktop PYTHONUNBUFFERED=1 scripts/run_all_cdp.sh
BEACON_CDP_VIEWPORTS=mobile PYTHONUNBUFFERED=1 scripts/run_all_cdp.sh
```

Results: desktop passed 415 checks with 0 failures; mobile passed 424 checks
with 0 failures. The harness asserted generated contracts, no post-SSR HTML
mounts for normal updates, WebSocket state updates, no empty-root flicker
samples, bounded DOM mutation buckets, bounded layout shift, reconnect behavior,
and mobile horizontal overflow on monitored examples.
