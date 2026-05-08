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
process.send(subject, runtime.ClientJoined(conn_id: "test", token: ""))
process.sleep(50)
let selector = process.new_selector() |> process.select(transport_subject)
let assert Ok(transport.SendMount(payload: _)) =
  process.selector_receive(selector, 500)
```

Send events with `runtime.ClientEventReceived` and check for `SendModelSync` or `SendPatch`. Regression tests must also assert that normal post-mount updates do not send `SendMount`.

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

The harness starts the app, opens the page, clicks controls, asserts DOM
content, records WebSocket frame types, tracks DOM mutation buckets, catches
console/runtime errors from document start, and fails when an attempted example
server dies or times out.

Examples should double as integration coverage for counter, local-only state, server-state privacy, multi-file apps, routed apps, auth/API/cookie flow, and large model/patch behavior.
